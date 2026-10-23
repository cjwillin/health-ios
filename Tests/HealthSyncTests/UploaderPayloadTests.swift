import XCTest
import HealthKit
@testable import HealthSync

// Authoritative CI tests for the v2 uploader. No real HealthKit is used:
// the payload source is a fake, HTTP is stubbed via URLProtocol, and anchors
// live in a temp-directory JSON store.

// MARK: - URLProtocol stub

private final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var recordedRequests: [Recorded] = []
    private static var responder: ((URLRequest) -> (Int, Data))?

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
        responder = nil
    }

    static func setResponder(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        responder = handler
    }

    static func requests() -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.currentResponder()
        let (status, body) = handler(request)
        Self.record(Self.body(of: request), url: request.url, headers: request.allHTTPHeaderFields ?? [:])
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        if let response = response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func currentResponder() -> (URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        return responder ?? { _ in (500, Data()) }
    }

    private static func record(_ body: Data, url: URL?, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(Recorded(url: url ?? URL(fileURLWithPath: "/"), headers: headers, body: body))
    }

    /// URLSession hands the body over as a stream inside URLProtocol.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Fakes

private final class FakeSyncSource: SyncSourceProviding {
    private(set) var anchorsSeen: [[String: Data]] = []
    private var payloads: [SyncPayload]
    private var anchorsToReturn: [[String: Data]]

    init(payloads: [SyncPayload], anchorsToReturn: [[String: Data]]) {
        self.payloads = payloads
        self.anchorsToReturn = anchorsToReturn
    }

    func collectPayload(storedAnchors: [String: Data]) async throws -> (payload: SyncPayload, newAnchors: [String: Data]) {
        anchorsSeen.append(storedAnchors)
        let payload = payloads.count > 1 ? payloads.removeFirst() : payloads[0]
        let anchors = anchorsToReturn.isEmpty ? [:] : anchorsToReturn.removeFirst()
        return (payload, anchors)
    }
}

private final class MemoryAnchors: AnchorStoring {
    private(set) var stored: [String: Data] = [:]
    func allAnchors() -> [String: Data] { stored }
    func replaceAll(_ anchors: [String: Data]) { stored = anchors }
}

private final class RecorderDiag: DiagPosting {
    struct Entry {
        let level: DiagEntry.Level
        let event: String
        let detail: [String: DiagValue]
    }

    private(set) var entries: [Entry] = []
    func post(level: DiagEntry.Level, event: String, detail: [String: DiagValue]) async {
        entries.append(Entry(level: level, event: event, detail: detail))
    }
    var events: [String] { entries.map { $0.event } }
}

private final class DelayBox {
    var delays: [TimeInterval] = []
}

// MARK: - Tests

final class UploaderPayloadTests: XCTestCase {
    private let testBase = URL(string: "https://ingest.example.com")!
    private let testId = "ci-access-id"
    private let testSecretValue = "ci-access-value"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Helpers

    @MainActor
    private func makeEngine(config: SyncConfig?,
                            provider: FakeSyncSource,
                            anchors: AnchorStoring,
                            diag: RecorderDiag,
                            delays: DelayBox) -> UploaderEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = NetworkTransport(session: URLSession(configuration: configuration))
        return UploaderEngine(
            provider: provider,
            transport: transport,
            anchorStore: anchors,
            diag: diag,
            currentConfig: { config },
            sleeper: { seconds in delays.delays.append(seconds) },
            jitter: { 0 }
        )
    }

    private func hourly(_ firstHours: [Double?]) -> [Double?] {
        Array(firstHours) + Array(repeating: nil, count: max(0, BucketMath.hoursPerDay - firstHours.count))
    }

    // MARK: Exact wire payload

    @MainActor
    func testExactUploadPayloadHeadersAndEndpoint() async {
        StubURLProtocol.setResponder { _ in (200, Data("{\"ok\":true}".utf8)) }

        let provider = FakeSyncSource(
            payloads: [Self.fullPayload()],
            anchorsToReturn: [["heart_rate": Data([1, 2, 3])]]
        )
        let diag = RecorderDiag()
        let engine = makeEngine(
            config: SyncConfig(baseURL: testBase, credentials: UploadCredentials(clientId: testId, clientSecret: testSecretValue)),
            provider: provider,
            anchors: MemoryAnchors(),
            diag: diag,
            delays: DelayBox()
        )

        await engine.syncNow(trigger: "unit_test")

        let requests = StubURLProtocol.requests()
        XCTAssertEqual(requests.count, 1, "one successful sync posts exactly once")
        guard let request = requests.first else { return }
        XCTAssertEqual(request.url.absoluteString, "https://ingest.example.com/ingest/v2")
        XCTAssertEqual(request.headers["CF-Access-Client-Id"], testId)
        XCTAssertEqual(request.headers["CF-Access-Client-Secret"], testSecretValue)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let expected: [String: Any] = [
            "date": "2026-10-23",
            "buckets": [
                ["type": "steps", "values": [NSNull(), NSNull(), 123.0, 456.0]],
                ["type": "active_energy", "values": [0.0, 10.5]],
                ["type": "basal_energy", "values": [1.25, 2.5]],
                ["type": "distance", "values": [NSNull(), 850.5]],
                ["type": "daylight", "values": [NSNull(), 12.0]],
                ["type": "flights", "values": [0.0, 3.0]],
            ],
            "samples": [
                ["type": "heart_rate",
                 "uuid": "11111111-1111-1111-1111-111111111111",
                 "start": "2026-10-23T07:12:00-06:00",
                 "end": "2026-10-23T07:12:30-06:00",
                 "value": "72",
                 "unit": "count/min"],
                ["type": "hrv_sdms",
                 "uuid": "22222222-2222-2222-2222-222222222222",
                 "start": "2026-10-23T03:00:00-06:00",
                 "end": "2026-10-23T03:00:00-06:00",
                 "value": "45.5",
                 "unit": "ms"],
                ["type": "sleep_stage",
                 "uuid": "33333333-3333-3333-3333-333333333333",
                 "start": "2026-10-23T01:14:00-06:00",
                 "end": "2026-10-23T02:05:00-06:00",
                 "value": "asleep_core"],
                ["type": "workout",
                 "uuid": "44444444-4444-4444-4444-444444444444",
                 "start": "2026-10-23T06:00:00-06:00",
                 "end": "2026-10-23T06:31:12-06:00",
                 "duration_min": 31.2,
                 "kcal": 312.0],
            ],
            "deleted": [
                ["type": "heart_rate", "uuid": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"],
            ],
        ]

        let parsed = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        XCTAssertNotNil(parsed, "body must be valid JSON")
        XCTAssertNotNil(engine.lastSyncAt)
        XCTAssertTrue(engine.lastHTTPResult.hasPrefix("HTTP 200"), "got: \(engine.lastHTTPResult)")
        XCTAssertEqual(parsed as NSDictionary?, expected as NSDictionary,
                       "payload must match the v2 wire contract exactly")
        XCTAssertEqual(diag.entries.last?.event, "sync_ok")
        XCTAssertEqual(diag.entries.last?.detail["samples"], .int(4))
        XCTAssertEqual(diag.entries.last?.detail["buckets"], .int(6))
        XCTAssertEqual(diag.entries.last?.detail["http"], .int(200))
    }

    @MainActor
    func testEmptyArraysAreOmittedFromPayload() async {
        StubURLProtocol.setResponder { _ in (200, Data("{\"ok\":true}".utf8)) }
        let provider = FakeSyncSource(
            payloads: [SyncPayload(date: "2026-10-23", buckets: nil, samples: nil, deleted: nil)],
            anchorsToReturn: []
        )
        let engine = makeEngine(
            config: SyncConfig(baseURL: testBase, credentials: UploadCredentials(clientId: testId, clientSecret: testSecretValue)),
            provider: provider,
            anchors: MemoryAnchors(),
            diag: RecorderDiag(),
            delays: DelayBox()
        )

        await engine.syncNow(trigger: "unit_test")

        let requests = StubURLProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(String(data: requests.first?.body ?? Data(), encoding: .utf8),
                       "{\"date\":\"2026-10-23\"}",
                       "empty buckets/samples/deleted must be omitted, not sent as []")
    }

    // MARK: Anchor persistence across syncs

    @MainActor
    func testAnchorsPersistAcrossSyncsAndAcrossStoreInstances() async {
        StubURLProtocol.setResponder { _ in (200, Data("{\"ok\":true}".utf8)) }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploader-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let heartAnchor = Data([1, 2, 3])
        let firstProvider = FakeSyncSource(
            payloads: [Self.fullPayload()],
            anchorsToReturn: [["heart_rate": heartAnchor]]
        )
        let firstEngine = makeEngine(
            config: SyncConfig(baseURL: testBase, credentials: UploadCredentials(clientId: testId, clientSecret: testSecretValue)),
            provider: firstProvider,
            anchors: JSONAnchorStore(directory: tempDirectory),
            diag: RecorderDiag(),
            delays: DelayBox()
        )

        await firstEngine.syncNow(trigger: "unit_test")
        XCTAssertEqual(firstProvider.anchorsSeen.first, [:], "first sync starts with no stored anchors")
        XCTAssertTrue(firstEngine.lastHTTPResult.hasPrefix("HTTP 200"), "got: \(firstEngine.lastHTTPResult)")

        // A NEW engine + NEW store instance over the same directory must see
        // the persisted anchor on the next sync.
        let secondProvider = FakeSyncSource(
            payloads: [Self.fullPayload()],
            anchorsToReturn: [["heart_rate": Data([9])]]
        )
        let secondEngine = makeEngine(
            config: SyncConfig(baseURL: testBase, credentials: UploadCredentials(clientId: testId, clientSecret: testSecretValue)),
            provider: secondProvider,
            anchors: JSONAnchorStore(directory: tempDirectory),
            diag: RecorderDiag(),
            delays: DelayBox()
        )
        await secondEngine.syncNow(trigger: "unit_test")
        XCTAssertEqual(secondProvider.anchorsSeen.first?["heart_rate"], heartAnchor,
                       "second sync must resume from the persisted anchor")
        XCTAssertTrue(secondEngine.lastHTTPResult.hasPrefix("HTTP 200"), "got: \(secondEngine.lastHTTPResult)")

        let reopenedStore = JSONAnchorStore(directory: tempDirectory)
        XCTAssertEqual(reopenedStore.allAnchors()["heart_rate"], Data([9]),
                       "anchor file must survive store re-creation")
    }

    @MainActor
    func testFailedSyncKeepsAnchorsAndResendsSameData() async {
        StubURLProtocol.setResponder { _ in (503, Data()) }

        let anchorsStore = MemoryAnchors()
        let delayedAnchor = ["heart_rate": Data([7])]
        let provider = FakeSyncSource(
            payloads: [Self.fullPayload()],
            anchorsToReturn: [delayedAnchor, delayedAnchor]
        )
        let diag = RecorderDiag()
        let delays = DelayBox()
        let engine = makeEngine(
            config: SyncConfig(baseURL: testBase, credentials: UploadCredentials(clientId: testId, clientSecret: testSecretValue)),
            provider: provider,
            anchors: anchorsStore,
            diag: diag,
            delays: delays
        )

        await engine.syncNow(trigger: "unit_test")

        XCTAssertEqual(StubURLProtocol.requests().count, RetryBackoff.maxAttempts,
                       "retries stop at maxAttempts")
        XCTAssertEqual(delays.delays, [1, 2, 4, 8],
                       "exponential backoff 1s/2s/4s/8s between the 5 attempts")
        XCTAssertTrue(anchorsStore.stored.isEmpty, "anchors must NOT advance after failure")
        XCTAssertTrue(engine.lastHTTPResult.contains("gave up"))
        XCTAssertEqual(diag.events.last, "sync_exhausted")

        // Server recovers: the SAME anchors must be collected again and only
        // now persisted.
        StubURLProtocol.setResponder { _ in (200, Data("{\"ok\":true}".utf8)) }
        await engine.syncNow(trigger: "unit_test")
        XCTAssertEqual(provider.anchorsSeen.last, [:],
                       "retry after failure re-collects with the old (empty) anchors")
        XCTAssertEqual(anchorsStore.stored["heart_rate"], Data([7]))
    }

    // MARK: 404 gate off — never hot-loop

    @MainActor
    func testGateOff404DoesNotRetryOrHotLoop() async {
        StubURLProtocol.setResponder { _ in (404, Data()) }

        let provider = FakeSyncSource(
            payloads: [Self.fullPayload()],
            anchorsToReturn: []
        )
        let diag = RecorderDiag()
        let delays = DelayBox()
        let engine = makeEngine(
            config: SyncConfig(baseURL: testBase, credentials: UploadCredentials(clientId: testId, clientSecret: testSecretValue)),
            provider: provider,
            anchors: MemoryAnchors(),
            diag: diag,
            delays: delays
        )

        await engine.syncNow(trigger: "unit_test")

        XCTAssertEqual(StubURLProtocol.requests().count, 1, "404 must not be retried immediately")
        XCTAssertTrue(delays.delays.isEmpty, "no backoff sleeps after a 404")
        XCTAssertEqual(diag.events, ["wake", "gate_off"])
        XCTAssertTrue(engine.lastHTTPResult.contains("404"))

        // An immediate second sync must skip the server entirely (cooldown).
        await engine.syncNow(trigger: "unit_test")
        XCTAssertEqual(StubURLProtocol.requests().count, 1, "no request during the gate-off cooldown")
        XCTAssertEqual(diag.events.last, "skip_gate_off")
    }

    @MainActor
    func testUnconfiguredEngineDoesNotTouchNetwork() async {
        let provider = FakeSyncSource(payloads: [Self.fullPayload()], anchorsToReturn: [])
        let engine = makeEngine(config: nil, provider: provider, anchors: MemoryAnchors(),
                                diag: RecorderDiag(), delays: DelayBox())
        await engine.syncNow(trigger: "unit_test")
        XCTAssertTrue(StubURLProtocol.requests().isEmpty)
        XCTAssertTrue(provider.anchorsSeen.isEmpty)
        XCTAssertTrue(engine.lastHTTPResult.contains("not configured"))
    }

    // MARK: Bucket math (cumulative, nulls before first data)

    func testCumulativeBucketsNullsBeforeFirstDataThenFillForward() {
        let values = BucketMath.cumulative24(perHour: hourly([nil, 100, 50, nil, 25]))
        XCTAssertEqual(values.count, BucketMath.hoursPerDay)
        XCTAssertNil(values[0], "hour before first data must be null")
        XCTAssertEqual(values[1], 100)
        XCTAssertEqual(values[2], 150, "cumulative from local midnight")
        XCTAssertEqual(values[3], 150, "gap hour carries the latest cumulative value")
        XCTAssertEqual(values[4], 175)
        XCTAssertEqual(values[23], 175, "tail carries the latest cumulative value")
        for hour in 1 ..< BucketMath.hoursPerDay {
            guard let previous = values[hour - 1], let current = values[hour] else { continue }
            XCTAssertLessThanOrEqual(previous, current, "cumulative series is non-decreasing")
        }
    }

    func testCumulativeBucketsEmptyDayIsAllNull() {
        let values = BucketMath.cumulative24(perHour: hourly(Array(repeating: nil, count: 24)))
        XCTAssertEqual(values.count, BucketMath.hoursPerDay)
        XCTAssertTrue(values.allSatisfy { $0 == nil })
    }

    // MARK: Wire formatting

    func testISO8601TimestampsCarryTimezoneOffset() {
        let mountain = TimeZone(secondsFromGMT: -21_600)!
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(WireFormats.iso8601(date, timeZone: mountain), "1969-12-31T18:00:00-06:00")
        XCTAssertEqual(WireFormats.dayString(for: date, timeZone: mountain), "1969-12-31")
    }

    func testNumberStringFormatting() {
        XCTAssertEqual(WireFormats.numberString(72), "72")
        XCTAssertEqual(WireFormats.numberString(31.25), "31.25")
        XCTAssertEqual(WireFormats.numberString(0.5), "0.5")
        XCTAssertEqual(WireFormats.numberString(1234.5), "1234.5")
    }

    // MARK: Sleep stage mapping (pure enum logic — no HealthKit data)

    func testSleepStageWireMapping() {
        XCTAssertEqual(HealthKitSyncSource.wireStage(HKCategoryValueSleepAnalysis.asleepCore.rawValue), "asleep_core")
        XCTAssertEqual(HealthKitSyncSource.wireStage(HKCategoryValueSleepAnalysis.asleepDeep.rawValue), "asleep_deep")
        XCTAssertEqual(HealthKitSyncSource.wireStage(HKCategoryValueSleepAnalysis.asleepREM.rawValue), "asleep_rem")
        XCTAssertEqual(HealthKitSyncSource.wireStage(HKCategoryValueSleepAnalysis.awake.rawValue), "awake")
        XCTAssertEqual(HealthKitSyncSource.wireStage(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue), "asleep_unspecified")
        XCTAssertNil(HealthKitSyncSource.wireStage(HKCategoryValueSleepAnalysis.inBed.rawValue),
                     "in-bed samples are not representable on the wire")
    }

    // MARK: Fixtures

    private static func fullPayload() -> SyncPayload {
        SyncPayload(
            date: "2026-10-23",
            buckets: [
                BucketSeriesDTO(type: "steps", values: [nil, nil, 123, 456]),
                BucketSeriesDTO(type: "active_energy", values: [0, 10.5]),
                BucketSeriesDTO(type: "basal_energy", values: [1.25, 2.5]),
                BucketSeriesDTO(type: "distance", values: [nil, 850.5]),
                BucketSeriesDTO(type: "daylight", values: [nil, 12]),
                BucketSeriesDTO(type: "flights", values: [0, 3]),
            ],
            samples: [
                SampleDTO(type: "heart_rate",
                          uuid: "11111111-1111-1111-1111-111111111111",
                          start: "2026-10-23T07:12:00-06:00",
                          end: "2026-10-23T07:12:30-06:00",
                          value: "72",
                          unit: "count/min",
                          durationMin: nil,
                          kcal: nil),
                SampleDTO(type: "hrv_sdms",
                          uuid: "22222222-2222-2222-2222-222222222222",
                          start: "2026-10-23T03:00:00-06:00",
                          end: "2026-10-23T03:00:00-06:00",
                          value: "45.5",
                          unit: "ms",
                          durationMin: nil,
                          kcal: nil),
                SampleDTO(type: "sleep_stage",
                          uuid: "33333333-3333-3333-3333-333333333333",
                          start: "2026-10-23T01:14:00-06:00",
                          end: "2026-10-23T02:05:00-06:00",
                          value: "asleep_core",
                          unit: nil,
                          durationMin: nil,
                          kcal: nil),
                SampleDTO(type: "workout",
                          uuid: "44444444-4444-4444-4444-444444444444",
                          start: "2026-10-23T06:00:00-06:00",
                          end: "2026-10-23T06:31:12-06:00",
                          value: nil,
                          unit: nil,
                          durationMin: 31.2,
                          kcal: 312),
            ],
            deleted: [
                DeletedDTO(type: "heart_rate", uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            ]
        )
    }
}
