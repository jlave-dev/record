import Darwin
import Foundation

// A stalled transcription worker must never block the capture queue forever.
// A partial frame failure is terminal: the caller must stop forwarding frames.
public final class AudioPipeWriter {
    private let handle: FileHandle

    public init(handle: FileHandle) throws {
        self.handle = handle
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0,
              fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CaptureCoreError.message("Could not configure the live audio pipe.")
        }
    }

    public func write(_ data: Data, timeout: TimeInterval = 1) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard ContinuousClock.now < deadline else {
                    throw CaptureCoreError.message("Live transcription stopped consuming audio.")
                }
                let count = Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    Thread.sleep(forTimeInterval: 0.01)
                } else {
                    throw CaptureCoreError.message("Live audio pipe failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }
}
