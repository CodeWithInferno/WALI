import Darwin
import Dispatch
import Foundation

/// Event-driven observation of Apple replacing either private store file.
/// Directory descriptors survive atomic file replacement and avoid polling.
@MainActor
public final class LockScreenStoreMonitor {
    public var onChange: (@MainActor () -> Void)?

    private let directories: [URL]
    private var sources: [any DispatchSourceFileSystemObject] = []

    public init(directories: [URL]) {
        self.directories = Array(Set(directories.map(\.standardizedFileURL)))
    }

    public func start() {
        guard sources.isEmpty else { return }
        for directory in directories {
            let descriptor = Darwin.open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.onChange?()
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
    }

    public func stop() {
        let active = sources
        sources.removeAll(keepingCapacity: false)
        for source in active { source.cancel() }
        onChange = nil
    }
}
