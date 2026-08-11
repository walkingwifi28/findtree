import Foundation
import CoreServices

public struct FileSystemChange: Sendable, Equatable {
    public let path: String
    public let flags: FSEventStreamEventFlags
    public let eventID: FSEventStreamEventId

    public init(path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId) {
        self.path = path
        self.flags = flags
        self.eventID = eventID
    }
}

public final class FSEventWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable ([FileSystemChange]) -> Void

    private let rootPath: String
    private let sinceWhen: FSEventStreamEventId
    private let latency: CFTimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "findtree.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(
        rootPath: String,
        sinceWhen: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency: CFTimeInterval = 1.0,
        handler: @escaping Handler
    ) {
        self.rootPath = PathUtilities.canonicalExisting(rootPath)
        self.sinceWhen = sinceWhen
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathArray = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var changes: [FileSystemChange] = []
            changes.reserveCapacity(Int(count))

            for index in 0..<Int(count) {
                guard index < pathArray.count, let path = pathArray[index] as? String else { continue }
                changes.append(
                    FileSystemChange(
                        path: path,
                        flags: flags[index],
                        eventID: ids[index]
                    )
                )
            }

            if !changes.isEmpty {
                watcher.handler(changes)
            }
        }

        // Let FSEvents coalesce short bursts instead of immediately waking FindTree for
        // every cache/temp-file write. FileEvents still gives us item-level paths.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootPath] as CFArray,
            sinceWhen,
            latency,
            flags
        ) else {
            throw FSEventWatcherError.couldNotCreateStream
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
            throw FSEventWatcherError.couldNotStartStream
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Only events that make the event-history cursor itself unreliable require a root rebuild.
    /// `MustScanSubDirs`/dropped-event flags are handled by refreshing the event's subtree rather
    /// than rescanning the entire indexed root.
    public static func eventRequiresFullRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        let idsWrapped = FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        return flags & (idsWrapped | rootChanged) != 0
    }
}

public enum FSEventWatcherError: Error, CustomStringConvertible {
    case couldNotCreateStream
    case couldNotStartStream

    public var description: String {
        switch self {
        case .couldNotCreateStream:
            return "Could not create FSEvents stream"
        case .couldNotStartStream:
            return "Could not start FSEvents stream"
        }
    }
}
