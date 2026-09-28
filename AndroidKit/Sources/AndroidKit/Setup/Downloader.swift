import CryptoKit
import Foundation
import Synchronization

public enum Checksum: Sendable, Equatable {
    case sha1(String)
    case sha256(String)
}

public enum DownloadError: Error, Sendable, Equatable, LocalizedError {
    case httpStatus(Int)
    case checksumMismatch(file: String)

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(code): "The download failed (HTTP \(code))."
        case let .checksumMismatch(file): "\(file) didn't match its checksum, so it may be damaged. Try again."
        }
    }
}

/// Downloads a file with progress, verifying its checksum before handing it over.
public struct Downloader: Sendable {
    public init() {}

    /// Downloads `url` to a temporary file and returns its location; the caller moves or deletes it.
    /// Cancelling the calling task cancels the download.
    /// - Parameter expectedSize: used for progress when the server doesn't send a length
    ///   (Google's SDK server often doesn't).
    public func download(
        _ url: URL,
        expectedSize: Int64? = nil,
        checksum: Checksum?,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void
    ) async throws -> URL {
        let delegate = DownloadDelegate(expectedSize: expectedSize ?? 0, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let file: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation.withLock { $0 = continuation }
                var request = URLRequest(url: url)
                request.setValue("Andyman", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                delegate.task.withLock { $0 = task }
                task.resume()
            }
        } onCancel: {
            delegate.task.withLock { $0?.cancel() }
        }

        if let checksum {
            let matches = try await Task.detached { try Self.verify(file, checksum) }.value
            guard matches else {
                try? FileManager.default.removeItem(at: file)
                throw DownloadError.checksumMismatch(file: url.lastPathComponent)
            }
        }
        return file
    }

    /// Hashes a file in chunks (archives can be gigabytes).
    static func verify(_ file: URL, _ checksum: Checksum) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            switch checksum {
            case .sha1: sha1.update(data: chunk)
            case .sha256: sha256.update(data: chunk)
            }
        }
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
            digest.map { String(format: "%02x", $0) }.joined()
        }
        switch checksum {
        case let .sha1(expected): return hex(sha1.finalize()) == expected.lowercased()
        case let .sha256(expected): return hex(sha256.finalize()) == expected.lowercased()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedSize: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    let continuation = Mutex<CheckedContinuation<URL, any Error>?>(nil)
    let task = Mutex<URLSessionDownloadTask?>(nil)

    init(expectedSize: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    private func resume(_ result: Result<URL, any Error>) {
        continuation.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        progress(totalBytesWritten, max(total, totalBytesWritten))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            resume(.failure(DownloadError.httpStatus(http.statusCode)))
            return
        }
        // The file is deleted when this method returns, so move it somewhere stable first.
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "download-\(UUID().uuidString)-\(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            resume(.success(destination))
        } catch {
            resume(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            resume(.failure(CancellationError()))
        } else {
            resume(.failure(error))
        }
    }
}
