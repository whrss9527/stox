import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 简单的 HTTP GET：行情、搜索和检查更新共用。
enum HTTP {
    static let userAgent = "Mozilla/5.0 (Macintosh) Stox/1.0"

    static func get(
        _ url: URL,
        session: URLSession,
        timeout: TimeInterval,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await load(request, session: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ProviderError.emptyResponse }
        return data
    }

    private static func load(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: ProviderError.emptyResponse)
                }
            }.resume()
        }
        #else
        return try await session.data(for: request)
        #endif
    }
}
