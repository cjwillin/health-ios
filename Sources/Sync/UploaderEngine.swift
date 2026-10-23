import Foundation

/// Produces the next payload to upload plus the new per-type HealthKit
/// anchors. Implementations must be idempotent per call; the engine persists
/// anchors only after a confirmed HTTP 200, so a failed sync re-collects with
/// the SAME stored anchors and re-sends everything (including deletions).
protocol SyncSourceProviding: AnyObject {
    func collectPayload(storedAnchors: [String: Data]) async throws -> (payload: SyncPayload, newAnchors: [String: Data])
}

enum RetryBackoff {
    static let maxAttempts = 5
    static let maxDelay: TimeInterval = 60
    static let jitterSeconds = 0.5

    /// Exponential backoff between attempts: 1s, 2s, 4s, 8s (+ jitter in
    /// [0, jitterSeconds)). Pure so tests can pin the sequence.
    static func delay(retryIndex: Int, jitter: Double) -> TimeInterval {
        let base = min(maxDelay, pow(2.0, Double(max(0, retryIndex))))
        return base + max(0, jitter)
    }
}

enum UploadOutcome: Equatable {
    case success(status: Int)
    case gateOff                    // 404: server ingest gate off — wait, never hot-loop
    case authRejected(status: Int)  // 401/403: credentials rejected
    case badRequest(status: Int)    // 400: payload rejected, retrying cannot help
    case transportExhausted         // network/5xx/429 until maxAttempts reached
}

/// The v2 uploader engine. One sync = collect payload via provider (anchored
/// queries + today's cumulative buckets) -> POST {base}/ingest/v2 with
/// Cloudflare Access headers -> on 200 persist anchors -> post one diag line.
@MainActor
final class UploaderEngine: ObservableObject {
    /// 404 (gate off) cooldown: do not hit the server again for half an hour.
    static let gateOffCooldown: TimeInterval = 30 * 60

    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastHTTPResult = "not synced yet"

    private let provider: SyncSourceProviding
    private let transport: UploadTransporting
    private let anchorStore: AnchorStoring
    private let diag: DiagPosting
    private let currentConfig: () -> SyncConfig?
    private let sleeper: (TimeInterval) async -> Void
    private let jitter: () -> Double
    private var gateOffUntil = Date.distantPast

    init(provider: SyncSourceProviding,
         transport: UploadTransporting,
         anchorStore: AnchorStoring,
         diag: DiagPosting,
         currentConfig: @escaping () -> SyncConfig?,
         sleeper: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         jitter: @escaping () -> Double = { Double.random(in: 0 ..< RetryBackoff.jitterSeconds) }) {
        self.provider = provider
        self.transport = transport
        self.anchorStore = anchorStore
        self.diag = diag
        self.currentConfig = currentConfig
        self.sleeper = sleeper
        self.jitter = jitter
    }

    var isConfigured: Bool { currentConfig() != nil }

    /// Trigger names used in the wake diag line: "background_wake",
    /// "app_open", "manual_test".
    func syncNow(trigger: String) async {
        guard let config = currentConfig() else {
            lastHTTPResult = "not configured — open Upload settings"
            return
        }
        let now = Date()
        guard now >= gateOffUntil else {
            await diag.post(level: .info, event: "skip_gate_off", detail: ["trigger": .string(trigger)])
            return
        }
        await diag.post(level: .info, event: "wake", detail: ["trigger": .string(trigger)])
        do {
            let storedAnchors = anchorStore.allAnchors()
            let (payload, newAnchors) = try await provider.collectPayload(storedAnchors: storedAnchors)
            let body = try WireFormats.encoder.encode(payload)
            let outcome = await uploadWithRetry(config: config, body: body)
            switch outcome {
            case .success(let status):
                anchorStore.replaceAll(newAnchors)
                lastSyncAt = Date()
                lastHTTPResult = "HTTP \(status) at \(Self.timeText(Date()))"
                await diag.post(level: .info, event: "sync_ok", detail: Self.countsDetail(payload, http: status))
            case .gateOff:
                gateOffUntil = Date().addingTimeInterval(Self.gateOffCooldown)
                lastHTTPResult = "HTTP 404 — ingest gate off; retrying after \(Int(Self.gateOffCooldown / 60)) min"
                await diag.post(level: .warn, event: "gate_off", detail: Self.countsDetail(payload, http: 404))
            case .authRejected(let status):
                lastHTTPResult = "HTTP \(status) — credentials rejected (check Upload settings)"
                await diag.post(level: .error, event: "auth_error", detail: ["http": .int(status)])
            case .badRequest(let status):
                lastHTTPResult = "HTTP \(status) — payload rejected by server"
                await diag.post(level: .error, event: "bad_request", detail: ["http": .int(status)])
            case .transportExhausted:
                lastHTTPResult = "gave up after \(RetryBackoff.maxAttempts) attempts (transport/server errors)"
                await diag.post(level: .error, event: "sync_exhausted", detail: ["attempts": .int(RetryBackoff.maxAttempts)])
            }
        } catch {
            lastHTTPResult = "sync failed: \(Self.shortError(error))"
            await diag.post(level: .error, event: "sync_error", detail: ["reason": .string(Self.shortError(error))])
        }
    }

    // MARK: - Upload with retries

    private func uploadWithRetry(config: SyncConfig, body: Data) async -> UploadOutcome {
        for attempt in 0 ..< RetryBackoff.maxAttempts {
            var retryable = false
            do {
                let result = try await transport.post(
                    url: config.baseURL.appendingPathComponent("ingest/v2"),
                    headers: UploadHeaders.forConfig(config),
                    body: body
                )
                switch result.status {
                case 200 ... 299:
                    return .success(status: result.status)
                case 404:
                    return .gateOff
                case 401, 403:
                    return .authRejected(status: result.status)
                case 400:
                    return .badRequest(status: result.status)
                default:
                    retryable = true // 429 / 5xx: back off and retry
                }
            } catch {
                retryable = true // transport error: back off and retry
            }
            if retryable, attempt < RetryBackoff.maxAttempts - 1 {
                await sleeper(RetryBackoff.delay(retryIndex: attempt, jitter: jitter()))
            }
        }
        return .transportExhausted
    }

    // MARK: - Diag + text helpers (counts/statuses only, no health values)

    static func countsDetail(_ payload: SyncPayload, http: Int) -> [String: DiagValue] {
        [
            "samples": .int(payload.samples?.count ?? 0),
            "buckets": .int(payload.buckets?.count ?? 0),
            "http": .int(http),
        ]
    }

    static func shortError(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

