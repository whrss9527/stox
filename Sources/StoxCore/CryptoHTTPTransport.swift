import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 每个 provider 复用一个 session，限制应用累计响应缓冲；不是事后才检查完整 Data。
final class CryptoHTTPTransport: @unchecked Sendable {
    private let delegate = Receiver()
    private let session: URLSession

    init(configuration: URLSessionConfiguration, timeout: TimeInterval) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = min(configuration.httpMaximumConnectionsPerHost, 4)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task.taskIdentifier, continuation: continuation)
                box.install(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func install(_ task: URLSessionDataTask) {
            lock.lock(); self.task = task; let shouldCancel = cancelled; lock.unlock()
            if shouldCancel { task.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; lock.unlock()
            task?.cancel()
        }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        static let limit = 2_000_000
        private struct Pending {
            let continuation: CheckedContinuation<(Data, URLResponse), Error>
            var data = Data()
            var response: URLResponse?
            var failure: Error?
        }
        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        func register(_ id: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            lock.lock(); pending[id] = Pending(continuation: continuation); lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            let tooLarge = response.expectedContentLength > Int64(Self.limit)
            pending[dataTask.taskIdentifier]?.response = response
            if tooLarge { pending[dataTask.taskIdentifier]?.failure = URLError(.dataLengthExceedsMaximum) }
            lock.unlock()
            completionHandler(tooLarge ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            var cancel = false
            if var value = pending[dataTask.taskIdentifier], value.failure == nil {
                if data.count > Self.limit - value.data.count {
                    value.failure = URLError(.dataLengthExceedsMaximum)
                    cancel = true
                } else {
                    value.data.append(data)
                }
                pending[dataTask.taskIdentifier] = value
            }
            lock.unlock()
            if cancel { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); let value = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
            guard let value else { return }
            if let error = value.failure ?? error { value.continuation.resume(throwing: error) }
            else if let response = value.response { value.continuation.resume(returning: (value.data, response)) }
            else { value.continuation.resume(throwing: ProviderError.emptyResponse) }
        }
    }
}
