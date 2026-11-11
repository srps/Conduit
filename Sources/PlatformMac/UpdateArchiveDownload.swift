// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Downloads to disk with a resource deadline and byte ceiling, including
/// unknown-length responses. URLSession retains normal system proxy/CA policy.
private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let lock = NSLock()
    private var failure: (any Error)?
    private var completion: (@Sendable (Result<Void, any Error>) -> Void)?

    init(destination: URL, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        self.destination = destination; self.completion = completion
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, UpdateArchiveDownload.allowed(url) else {
            lock.withLock { failure = UpdatePreflightError("update_redirect_rejected") }
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > UpdatePreflightLimits.archiveBytes || totalBytesExpectedToWrite > UpdatePreflightLimits.archiveBytes {
            lock.withLock { failure = UpdatePreflightError("update_download_limit") }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let url = response.url, UpdateArchiveDownload.allowed(url) else {
                throw UpdatePreflightError("update_download_response_invalid")
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= UpdatePreflightLimits.archiveBytes else { throw UpdatePreflightError("update_download_limit") }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { lock.withLock { failure = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: (Result<Void, any Error>, (@Sendable (Result<Void, any Error>) -> Void)?) = lock.withLock {
            defer { completion = nil }
            if let failure = failure ?? error { return (.failure(failure), completion) }
            return (.success(()), completion)
        }
        result.1?(result.0)
    }
}

package enum UpdateArchiveDownload {
    package static func allowed(_ url: URL) -> Bool {
        if url.scheme == "https", url.host != nil, url.user == nil, url.password == nil { return true }
        #if DEBUG
        // Headless E2E fixtures never need a trusted production certificate.
        return url.scheme == "http" && ["127.0.0.1", "::1"].contains(url.host ?? "") && url.user == nil && url.password == nil
        #else
        return false
        #endif
    }

    package static func fetch(_ url: URL, to destination: URL) async throws {
        guard allowed(url) else { throw UpdatePreflightError("update_url_rejected") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = UpdatePreflightLimits.downloadTimeout
        // At most one task/download/session per preflight; no shared cache.
        let taskBox = DownloadTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let delegate = UpdateDownloadDelegate(destination: destination) { continuation.resume(with: $0) }
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                taskBox.start(task)
                session.finishTasksAndInvalidate()
            }
        } onCancel: { taskBox.cancel() }
    }

    private final class DownloadTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        func start(_ task: URLSessionDownloadTask) {
            lock.withLock {
                self.task = task
                task.resume()
                if cancelled { task.cancel() }
            }
        }
        func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    }
}
