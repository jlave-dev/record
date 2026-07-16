import Darwin
import CoreGraphics
import Foundation

public enum CaptureAction: String, Codable {
    case start
    case apps
    case doctor
    case setup
}

public enum CaptureStatus: String, Codable {
    case starting
    case recording
    case stopping
    case stopped
    case failed

    public var isActive: Bool {
        self == .starting || self == .recording || self == .stopping
    }
}

public struct CaptureRequest: Codable {
    public let action: CaptureAction
    public let token: String
    public let app: String?
    public let outputDir: String?
    public let width: Int?
    public let height: Int?
    public let responsePath: String?

    public init(action: CaptureAction, token: String, app: String? = nil, outputDir: String? = nil, width: Int? = nil, height: Int? = nil, responsePath: String? = nil) {
        self.action = action
        self.token = token
        self.app = app
        self.outputDir = outputDir
        self.width = width
        self.height = height
        self.responsePath = responsePath
    }
}

public struct CaptureState: Codable {
    public var schemaVersion = 2
    public let token: String
    public var status: CaptureStatus
    public var pid: Int32?
    public let requestedApp: String
    public var appName: String?
    public var bundleID: String?
    public let outputDir: String
    public let outputPath: String
    public let metadataPath: String
    public var width: Int?
    public var height: Int?
    public var startedAt: String?
    public var stoppedAt: String?
    public var error: String?

    public init(token: String, status: CaptureStatus, requestedApp: String, outputDir: String, outputPath: String, metadataPath: String) {
        self.token = token
        self.status = status
        self.requestedApp = requestedApp
        self.outputDir = outputDir
        self.outputPath = outputPath
        self.metadataPath = metadataPath
    }
}

public struct CaptureMetadata: Encodable {
    public let schemaVersion = 2
    public let artifactType = "capture_recording"
    public let appName: String
    public let bundleID: String
    public let outputPath: String
    public let metadataPath: String
    public let width: Int
    public let height: Int
    public let codec = "h264"
    public let container = "mp4"
    public let capturesApplicationAudio = true
    public let startedAt: String
    public let stoppedAt: String

    public init(appName: String, bundleID: String, outputPath: String, metadataPath: String, width: Int, height: Int, startedAt: String, stoppedAt: String) {
        self.appName = appName
        self.bundleID = bundleID
        self.outputPath = outputPath
        self.metadataPath = metadataPath
        self.width = width
        self.height = height
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }
}

public struct AppDescriptor: Codable, Equatable {
    public let name: String
    public let bundleID: String
    public let processID: Int32

    public init(name: String, bundleID: String, processID: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.processID = processID
    }
}

public enum CaptureCoreError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

public enum CapturePaths {
    public static var controlDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/capture-native", isDirectory: true)
    }

    public static var state: URL { controlDir.appendingPathComponent("state.json") }
    public static var stop: URL { controlDir.appendingPathComponent("stop") }

    public static func request(token: String) -> URL {
        controlDir.appendingPathComponent("request-\(token).json")
    }

    public static func response(token: String) -> URL {
        controlDir.appendingPathComponent("response-\(token).json")
    }

    public static func ensureControlDir() throws {
        try FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

public func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value) + Data([0x0a])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
}

public func nowISO8601() -> String {
    ISO8601DateFormatter().string(from: Date())
}

public func timestampForPath() -> String {
    nowISO8601().replacingOccurrences(of: ":", with: "-")
}

public func expandPath(_ path: String) -> URL {
    if path == "~" { return FileManager.default.homeDirectoryForCurrentUser }
    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path).standardizedFileURL
}

public func resolveApp(_ input: String, from apps: [AppDescriptor]) -> AppDescriptor? {
    let wanted = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !wanted.isEmpty else { return nil }

    let exact = apps.filter {
        $0.bundleID.lowercased() == wanted || $0.name.lowercased() == wanted
    }
    if exact.count == 1 { return exact[0] }

    let partial = apps.filter {
        $0.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(Substring(wanted)) ||
        $0.name.lowercased().contains(wanted)
    }
    return partial.count == 1 ? partial[0] : nil
}

public func recordingDimensions(sourceWidth: Double, sourceHeight: Double, requestedWidth: Int?, requestedHeight: Int?) throws -> (width: Int, height: Int) {
    guard sourceWidth > 0, sourceHeight > 0 else {
        throw CaptureCoreError.message("Capture source has invalid dimensions.")
    }
    if let requestedWidth, requestedWidth <= 0 { throw CaptureCoreError.message("Width must be a positive integer.") }
    if let requestedHeight, requestedHeight <= 0 { throw CaptureCoreError.message("Height must be a positive integer.") }

    let ratio = sourceWidth / sourceHeight
    var width = Double(requestedWidth ?? 0)
    var height = Double(requestedHeight ?? 0)

    if requestedWidth == nil && requestedHeight == nil {
        let scale = min(1, 2560 / sourceWidth, 1440 / sourceHeight)
        width = sourceWidth * scale
        height = sourceHeight * scale
    } else if requestedWidth == nil {
        width = height * ratio
    } else if requestedHeight == nil {
        height = width / ratio
    }

    func even(_ value: Double) -> Int {
        max(2, Int(value.rounded()) / 2 * 2)
    }
    return (even(width), even(height))
}

public func bestOverlappingDisplayIndex(for frame: CGRect, displayFrames: [CGRect]) -> Int? {
    guard let index = displayFrames.indices.max(by: {
        frame.intersection(displayFrames[$0]).area < frame.intersection(displayFrames[$1]).area
    }), frame.intersection(displayFrames[index]).area > 0 else { return nil }
    return index
}

public func localCaptureRect(for frame: CGRect, in displayFrame: CGRect) -> CGRect? {
    let clipped = frame.intersection(displayFrame)
    guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
    return CGRect(
        x: clipped.minX - displayFrame.minX,
        y: clipped.minY - displayFrame.minY,
        width: clipped.width,
        height: clipped.height
    )
}

public func isZoomWindowShareMarker(_ marker: CGRect, inside sharedFrame: CGRect) -> Bool {
    marker.width >= 40 && marker.width <= 120 &&
        marker.height >= 10 && marker.height <= 40 &&
        marker.minX >= sharedFrame.minX && marker.maxX <= sharedFrame.minX + 120 &&
        marker.minY >= sharedFrame.minY && marker.maxY <= sharedFrame.minY + 90
}

public func bestMatchingWindowIndex(for frame: CGRect, windowFrames: [CGRect], minimumOverlap: CGFloat = 0.8) -> Int? {
    guard let index = windowFrames.indices.max(by: {
        frame.intersectionOverUnion(windowFrames[$0]) < frame.intersectionOverUnion(windowFrames[$1])
    }), frame.intersectionOverUnion(windowFrames[index]) >= minimumOverlap else { return nil }
    return index
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func intersectionOverUnion(_ other: CGRect) -> CGFloat {
        let intersectionArea = intersection(other).area
        let unionArea = area + other.area - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

public func processExists(_ pid: Int32?) -> Bool {
    guard let pid, pid > 0 else { return false }
    return Darwin.kill(pid, 0) == 0 || errno == EPERM
}
