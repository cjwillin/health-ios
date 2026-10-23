import Foundation

// MARK: - v2 wire format (normative — the server is coded against EXACTLY this)
// POST {base}/ingest/v2. Type strings, key names and shapes below are the
// contract; do not rename.

/// Cumulative-from-local-midnight per hour, index 0 = hour 00. `nil` values
/// encode as JSON null (used before the first data hour of the day).
struct BucketSeriesDTO: Codable, Equatable {
    let type: String
    let values: [Double?]
}

/// One HealthKit sample. Quantity samples carry `value` (string) + `unit`;
/// sleep_stage carries `value` (stage string); workout carries `duration_min`
/// and `kcal` instead. Optional fields are omitted from JSON when nil.
struct SampleDTO: Codable, Equatable {
    let type: String
    let uuid: String
    let start: String
    let end: String
    let value: String?
    let unit: String?
    let durationMin: Double?
    let kcal: Double?

    enum CodingKeys: String, CodingKey {
        case type, uuid, start, end, value, unit
        case durationMin = "duration_min"
        case kcal
    }
}

struct DeletedDTO: Codable, Equatable {
    let type: String
    let uuid: String
}

/// One payload per sync. Empty parts are omitted (optional arrays encode with
/// encodeIfPresent, so `nil` drops the key entirely).
struct SyncPayload: Codable, Equatable {
    let date: String
    let buckets: [BucketSeriesDTO]?
    let samples: [SampleDTO]?
    let deleted: [DeletedDTO]?
}

/// Response 200 body: {"ok":true,...}
struct UploadResponseBody: Decodable {
    let ok: Bool
}

struct UploadResponse {
    let status: Int
    let bodyOK: Bool
}

// MARK: - Connection settings

struct UploadCredentials: Equatable {
    let clientId: String
    let clientSecret: String
}

struct SyncConfig: Equatable {
    let baseURL: URL
    let credentials: UploadCredentials
}

// MARK: - Diagnostics line (POST {base}/ingest/v2/diag)
// Counts and statuses only — never health values.

struct DiagEntry: Encodable, Equatable {
    enum Level: String, Encodable {
        case info
        case warn
        case error
    }

    let level: Level
    let event: String
    let detail: [String: DiagValue]
}

enum DiagValue: Encodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        }
    }
}

// MARK: - Formatting helpers

enum WireFormats {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    /// ISO8601 WITH timezone offset, e.g. "2026-10-23T07:12:00-06:00".
    static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Plain local calendar day, e.g. "2026-10-23".
    static func dayString(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }

    /// Compact wire numeric string: "72", "31.25" — no trailing zeros,
    /// no exponent for sane magnitudes.
    static func numberString(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}
