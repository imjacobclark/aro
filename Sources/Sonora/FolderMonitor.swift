import CoreServices
import Foundation

final class FolderMonitor: @unchecked Sendable {
    private final class CallbackBox {
        let handler: @Sendable () -> Void

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }
    }

    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?

    init?(url: URL, handler: @escaping @Sendable () -> Void) {
        callbackBox = CallbackBox(handler: handler)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = {
            _, contextInfo, _, _, _, _ in
            guard let contextInfo else {
                return
            }

            let box = Unmanaged<CallbackBox>
                .fromOpaque(contextInfo)
                .takeUnretainedValue()
            box.handler()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(
            stream,
            DispatchQueue(label: "com.sonora.folder-monitor.\(UUID().uuidString)")
        )

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func stop() {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
