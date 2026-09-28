import Foundation

/// Calls `onChange` when entries are added to or removed from a directory.
///
/// If the directory doesn't exist yet (the emulator creates its discovery folder on first
/// launch), it retries every few seconds until it does.
final class DirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: Timer?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    isolated deinit {
        source?.cancel()
        retryTimer?.invalidate()
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The folder itself went away: start over (and wait for it to come back).
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.source?.cancel()
                    self.source = nil
                    self.start()
                }
                self.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        onChange()
    }
}
