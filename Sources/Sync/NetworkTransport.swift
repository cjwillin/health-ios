import Foundation

struct HTTPResult {
    let status: Int
    let body: Data?
}

/// Raw HTTP POST used for both the ingest and diag endpoints. The shared
/// session is replaceable so tests can install a URLProtocol stub.
protocol UploadTransporting: AnyObject {
    func post(url: URL, headers: [String: String], body: Data) async throws -> HTTPResult
}

final class NetworkTransport: UploadTransporting {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResult(status: status, body: data)
    }
}

/// Wire headers. Values come from the keychain at call time and are never
/// logged anywhere.
enum UploadHeaders {
    static func forConfig(_ config: SyncConfig) -> [String: String] {
        [
            "Content-Type": "application/json",
            "CF-Access-Client-Id": config.credentials.clientId,
            "CF-Access-Client-Secret": config.credentials.clientSecret,
        ]
    }
}
