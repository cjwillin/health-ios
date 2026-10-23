import Foundation

/// Diagnostics poster: one JSON line to {base}/ingest/v2/diag per wake, sync
/// outcome or error. Carries counts and HTTP statuses ONLY — never health
/// values, never credentials. Failures are swallowed: diagnostics must never
/// crash the app or cause a loop (no retries here, by design).
protocol DiagPosting: AnyObject {
    func post(level: DiagEntry.Level, event: String, detail: [String: DiagValue]) async
}

final class DiagClient: DiagPosting {
    private let transport: UploadTransporting
    private let currentConfig: () -> SyncConfig?

    init(transport: UploadTransporting, currentConfig: @escaping () -> SyncConfig?) {
        self.transport = transport
        self.currentConfig = currentConfig
    }

    func post(level: DiagEntry.Level, event: String, detail: [String: DiagValue]) async {
        guard let config = currentConfig() else { return }
        let entry = DiagEntry(level: level, event: event, detail: detail)
        guard let body = try? JSONEncoder().encode(entry) else { return }
        _ = try? await transport.post(
            url: config.baseURL.appendingPathComponent("ingest/v2/diag"),
            headers: UploadHeaders.forConfig(config),
            body: body
        )
    }
}
