import Foundation

/// Persists HealthKit anchors across syncs. The engine only advances anchors
/// after a confirmed HTTP 200, so a failed sync re-sends the same data.
protocol AnchorStoring: AnyObject {
    func allAnchors() -> [String: Data]
    func replaceAll(_ anchors: [String: Data])
}

/// JSON file in Application Support: {"anchors":{"heart_rate":"<base64 HKQueryAnchor
/// archive>", ...}}. Values are opaque `Data`; conversion to/from HKQueryAnchor
/// lives in HealthKitSyncSource.
final class JSONAnchorStore: AnchorStoring {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "JSONAnchorStore")

    /// `directory` is injectable so tests can use a temp folder.
    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        fileURL = base.appendingPathComponent("anchors.json")
    }

    static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("SyncAnchors", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func allAnchors() -> [String: Data] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            var result: [String: Data] = [:]
            for (key, base64) in decoded {
                if let value = Data(base64Encoded: base64) {
                    result[key] = value
                }
            }
            return result
        }
    }

    func replaceAll(_ anchors: [String: Data]) {
        queue.sync {
            var encoded: [String: String] = [:]
            for (key, data) in anchors {
                encoded[key] = data.base64EncodedString()
            }
            if let payload = try? JSONEncoder().encode(["anchors": encoded]) {
                try? payload.write(to: fileURL, options: .atomic)
            }
        }
    }
}
