import Foundation
import os

// MARK: - Downloading a File (FR03)

/// A file a download finished, moved where it waits for its import.
struct FeedDownloadedFile: Sendable {
    /// Where the file is now.
    var file: URL
    /// The MIME type the server gave it.
    var mimeType: String?
    /// The address it came from, after any redirects.
    var finalURL: URL
}

/// Why a download did not finish, with the resume data a later download can
/// go on from, when the server allows that: the request was a GET of a file
/// that has not changed, whose server sends an ETag or Last-Modified date
/// and serves byte ranges, and the system still keeps the part downloaded.
struct FeedTransferFailure: Error, Sendable {
    /// Why the download stopped.
    var error: FeedFetchError
    /// Where a later download can go on from, if anywhere.
    var resumeData: Data?
}

/// One download's transfer, which quitting can stop while keeping what it
/// downloaded (FR03). Cancelling the task that awaits the download forgets
/// that part, as the listener's Cancel means to; `stopKeepingResumeData()`
/// keeps it as resume data instead, which a later download goes on from.
///
/// Every stored property is a constant: the download task, once the
/// transfer has started, is kept behind an unfair lock, since the transfer
/// starts in the download's own task.
final class FeedTransferHandle: Sendable {
    /// The transfer's download task, once it has started.
    private let task = OSAllocatedUnfairLock<URLSessionDownloadTask?>(initialState: nil)

    /// A handle on a transfer that has not started.
    init() {}

    /// Names `downloadTask` as the transfer's task.
    func attach(_ downloadTask: URLSessionDownloadTask) {
        task.withLock { $0 = downloadTask }
    }

    /// Forgets the transfer's task once the transfer has ended, so stopping
    /// finds nothing left to stop.
    func detach() {
        task.withLock { $0 = nil }
    }

    /// Stops the transfer, keeping what it downloaded: the resume data the
    /// server allows, or nil when it allows none, or the transfer never
    /// started or has ended. The download awaiting the transfer then fails
    /// as cancelled.
    func stopKeepingResumeData() async -> Data? {
        guard let running = task.withLock({ $0 }) else { return nil }
        return await running.cancelByProducingResumeData()
    }
}

extension FeedNetwork {
    /// Downloads the file at `url` into `destination` with
    /// `downloadSession`, or goes on from `resumeData` where a download
    /// stopped. `progress` hears the bytes written and the bytes expected (or
    /// -1), on the session's queue, as they arrive. Redirects are followed
    /// to http and https addresses only, and an answer other than a success
    /// fails. Cancelling the task that awaits this stops the download;
    /// `handle`, when given, can stop it keeping its resume data instead.
    /// - Throws: `FeedTransferFailure`.
    func download(
        _ url: URL,
        resumingFrom resumeData: Data?,
        to destination: URL,
        discretionary: Bool,
        handle: FeedTransferHandle? = nil,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws -> FeedDownloadedFile {
        let host = FeedHost.of(url)
        guard FeedTransport.isWebAddress(url) else {
            throw FeedTransferFailure(error: .notAWebAddress, resumeData: nil)
        }
        guard reachability.isOnline() else {
            throw FeedTransferFailure(error: .offline, resumeData: resumeData)
        }
        let task = resumeData.map { downloadSession.downloadTask(withResumeData: $0) }
            ?? downloadSession.downloadTask(with: request(for: url, discretionary: discretionary))
        handle?.attach(task)
        defer { handle?.detach() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FeedDownloadedFile, Error>) in
                task.delegate = FeedDownloadTaskDelegate(
                    destination: destination,
                    host: host,
                    progress: progress,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One download task's delegate: it passes progress on, moves the finished
/// file to its destination before the session deletes it, follows
/// redirects only to http and https addresses, and resumes the download
/// that waits for it once, when the task completes, with the file or why it
/// failed and the resume data to go on from.
///
/// Every stored property is a constant: what the task reports is kept in
/// `state`, behind an unfair lock, since URLSession calls the delegate on a
/// queue of its own.
private final class FeedDownloadTaskDelegate: NSObject, URLSessionDownloadDelegate {
    /// What the task has reported so far.
    private struct State {
        var moved = false
        var failure: FeedFetchError?
        var mimeType: String?
        var finalURL: URL?
    }

    /// Where the finished file goes.
    private let destination: URL
    /// The host a failure names.
    private let host: String
    /// Hears the bytes written and expected.
    private let progress: @Sendable (Int64, Int64) -> Void
    /// The download waiting for the task.
    private let continuation: CheckedContinuation<FeedDownloadedFile, Error>
    /// What the task has reported, guarded by its lock.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A delegate moving the finished file to `destination`.
    init(
        destination: URL,
        host: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        continuation: CheckedContinuation<FeedDownloadedFile, Error>
    ) {
        self.destination = destination
        self.host = host
        self.progress = progress
        self.continuation = continuation
    }

    /// Passes the bytes written so far on.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// Moves the finished file to its destination, which must happen before
    /// this returns, unless the server answered with an error, whose body is
    /// no file of the item's.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response as? HTTPURLResponse
        let finalHost = response?.url.map(FeedHost.of) ?? host
        if let failure = FeedFetchError.from(status: response?.statusCode ?? 0, host: finalHost) {
            state.withLock { $0.failure = failure }
            return
        }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            state.withLock {
                $0.moved = true
                $0.mimeType = response?.mimeType
                $0.finalURL = response?.url
            }
        } catch {
            state.withLock { $0.failure = .connectionFailed(host: finalHost, reason: error.localizedDescription) }
        }
    }

    /// Follows a redirect only to an http or https address.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, FeedTransport.isWebAddress(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Resumes the download with the file, or why it failed and where to go
    /// on from.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = state.withLock { $0 }
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            continuation.resume(throwing: FeedTransferFailure(error: .from(error, host: host), resumeData: resumeData))
        } else if let failure = finished.failure {
            continuation.resume(throwing: FeedTransferFailure(error: failure, resumeData: nil))
        } else if finished.moved {
            continuation.resume(returning: FeedDownloadedFile(
                file: destination,
                mimeType: finished.mimeType,
                finalURL: finished.finalURL ?? task.originalRequest?.url ?? destination
            ))
        } else {
            continuation.resume(throwing: FeedTransferFailure(
                error: .connectionFailed(host: host, reason: "the download ended without a file"),
                resumeData: nil
            ))
        }
    }
}
