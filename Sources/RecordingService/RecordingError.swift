import AVFoundation

public enum RecordingError: LocalizedError {
    case permissionDenied(mediaType: AVMediaType)
    case setupFailed(reason: String)
    case deviceNotFound(mediaType: AVMediaType)
    case inputOutputError(reason: String)
    case recordingInProgress
    case recordingFailed(underlyingError: Error?)
    case fileSystemError(reason: String)
    case sessionNotRunning
    case unknown(reason: String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let mediaType):
            return "Permission for \(mediaType.rawValue) was denied. Please enable it in Settings."
        case .setupFailed(let reason):
            return "Session setup failed: \(reason)"
        case .deviceNotFound(let mediaType):
            return "Could not find a suitable device for \(mediaType.rawValue)."
        case .inputOutputError(let reason):
            return "Error with input/output: \(reason)"
        case .recordingInProgress:
            return "Recording is already in progress."
        case .recordingFailed(let underlyingError):
            return "Recording failed: \(underlyingError?.localizedDescription ?? "Unknown reason")"
        case .fileSystemError(let reason):
            return "File system error: \(reason)"
        case .sessionNotRunning:
            return "The capture session is not running. Ensure setupSession() and startCaptureSession() are called."
        case .unknown(let reason):
            return "An unknown error occurred: \(reason)"
        }
    }
}
