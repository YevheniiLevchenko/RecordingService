import AVFoundation
import Photos

public enum RecordingMode {
    case video
    case audio
}

public protocol RecordingServiceDelegate: AnyObject {
    func recordingDidStart(service: RecordingServiceProtocol)
    func recordingDidStop(service: RecordingServiceProtocol, url: URL?, error: RecordingError?)
    func recordingServiceFailed(service: RecordingServiceProtocol, error: RecordingError)
    func recordingSessionInterrupted(service: RecordingServiceProtocol, reason: AVCaptureSession.InterruptionReason?)
    func recordingSessionInterruptionEnded(service: RecordingServiceProtocol)
}

public protocol RecordingServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var delegate: RecordingServiceDelegate? { get set }
    var currentMode: RecordingMode { get }
    
    func setupSession() async throws
    func startCaptureSession(completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    func stopCaptureSession()
    func startRecording(fileName: String) throws
    func stopRecording()
    func getCaptureSession() -> AVCaptureSession?
    func teardownSession()
}

public final class RecordingService: NSObject, RecordingServiceProtocol, @unchecked Sendable {
    
    public var isRecording: Bool = false
    public weak var delegate: RecordingServiceDelegate?
    public private(set) var currentMode: RecordingMode
    
    var captureSession: AVCaptureSession!
    var movieFileOutput: AVCaptureMovieFileOutput?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var activeRecordingURL: URL?
    /// Queue for all session-related operations
    private let sessionQueue = DispatchQueue(label: "recorder.service.session.queue", qos: .userInitiated)
    
    /// Initialize with `session` and `fileOutput` for testing purposes only
    init(
        mode: RecordingMode,
        delegate: RecordingServiceDelegate? = nil,
        session: AVCaptureSession? = nil,
        fileOutput: AVCaptureMovieFileOutput? = nil
    ) {
        self.currentMode = mode
        self.delegate = delegate
        self.captureSession = session
        self.movieFileOutput = fileOutput
        super.init()
    }
    
    public func getCaptureSession() -> AVCaptureSession? {
        return captureSession
    }
    
    public func setupSession() async throws {
        // Check and Request Permissions
        try await checkAndRequestPermissions()
        
        // Configure AVAudioSession (application-wide audio settings)
        try configureAudioSession()
        
        // Create and Configure AVCaptureSession on the dedicated queue
        try await sessionQueue.perform { [weak self] in
            guard let self else { throw RecordingError.unknown(reason: "Self became nil during setup.") }
            
            captureSession = AVCaptureSession()
            // Start configuration
            captureSession.beginConfiguration()
            
            
            switch currentMode {
            case .video:
                // Apply session preset
                if captureSession.canSetSessionPreset(.hd1920x1080) {
                    captureSession.sessionPreset = .hd1920x1080
                } else if captureSession.canSetSessionPreset(.high) {
                    captureSession.sessionPreset = .high
                }
                
                // Add input based on mode
                try self.addVideoInput()
                try self.addAudioInput()
            case .audio:
                if captureSession.canSetSessionPreset(.high) { // A reasonable preset for audio quality
                    captureSession.sessionPreset = .high
                }
                // Add input based on mode
                try self.addAudioInput()
            }
            
            // Add Output
            /// Using `AVCaptureMovieFileOutput` for both modes for simplicity.
            /// For audio-only, it will create a movie file (.mp4 or .mov) with only an audio track.
            let output = AVCaptureMovieFileOutput()
            if self.captureSession.canAddOutput(output) {
                self.captureSession.addOutput(output)
                self.movieFileOutput = output
                
                // Optional: Configure video stabilization for video mode
                if self.currentMode == .video,
                   let connection = output.connection(with: .video),
                   connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            } else {
                throw RecordingError.inputOutputError(reason: "Cannot add movie file output to the session.")
            }
            
            // Commit configuration
            self.captureSession.commitConfiguration()
            self.addSessionObservers()
        }
    }
    
    public func startCaptureSession(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let session = self.captureSession, !session.isRunning else {
                if self.captureSession == nil {
                    let error = RecordingError.setupFailed(reason: "Session not initialized. Call setupSession() first.")
                    completion(.failure(error))
                    self.delegate?.recordingServiceFailed(service: self, error: error)
                    return
                }
                completion(.failure(RecordingError.setupFailed(reason: "Session is already running")))
                return
            }
            session.startRunning()
            completion(.success(Void()))
        }
    }
    
    public func stopCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession, session.isRunning else { return }
            session.stopRunning()
        }
    }
    
    public func startRecording(fileName: String) throws {
        guard let captureSession, captureSession.isRunning else {
            throw RecordingError.sessionNotRunning
        }
        
        guard let movieFileOutput else {
            throw RecordingError.inputOutputError(reason: "Movie file output is not configured.")
        }
        
        guard !movieFileOutput.isRecording else {
            throw RecordingError.recordingInProgress
        }
        
        // Perform recording start on the session queue
        try sessionQueue.sync { [weak self] in
            guard let self else { throw RecordingError.unknown(reason: "Self became nil before starting recording.") }
            
            let outputDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileExtension = currentMode == .video ? "mp4" : "m4a" // .m4a is common for audio in mp4 container
            let uniqueFileName = "\(fileName)-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
            let outputURL = outputDirectory.appendingPathComponent(uniqueFileName)
            activeRecordingURL = outputURL
            
            // Set orientation for video recording
            if
                currentMode == .video,
                let connection = movieFileOutput.connection(with: .video),
                let device = videoDeviceInput?.device
            {
                let rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: nil
                )
                let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
                connection.videoRotationAngle = rotationAngle
            }
            
            movieFileOutput.startRecording(to: outputURL, recordingDelegate: self)
        }
    }
    
    public func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let movieFileOutput = self?.movieFileOutput, movieFileOutput.isRecording else {
                return
            }
            movieFileOutput.stopRecording()
            // isRecording will be set to false in the delegate callback `didFinishRecordingTo`
        }
    }
    
    public func teardownSession() {
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession else { return }
            
            self?.removeSessionObservers()
            
            if session.isRunning {
                session.stopRunning()
            }
            
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            
            self?.videoDeviceInput = nil
            self?.audioDeviceInput = nil
            self?.movieFileOutput = nil
            self?.captureSession = nil
        }
    }
    
    // MARK: - Permissions
    private func checkAndRequestPermissions() async throws {
        // Audio Permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break // Already authorized
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .audio)) {
                throw RecordingError.permissionDenied(mediaType: .audio)
            }
        default: // .denied, .restricted
            throw RecordingError.permissionDenied(mediaType: .audio)
        }
        
        // Video Permission (only if in video mode)
        if currentMode == .video {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break // Already authorized
            case .notDetermined:
                if !(await AVCaptureDevice.requestAccess(for: .video)) {
                    throw RecordingError.permissionDenied(mediaType: .video)
                }
            default: // .denied, .restricted
                throw RecordingError.permissionDenied(mediaType: .video)
            }
        }
    }
    
    // MARK: - AVAudioSession Configuration
    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            throw RecordingError.setupFailed(reason: "Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Input/Output Setup
    /// Must be called on sessionQueue
    private func addAudioInput() throws {
        guard let session = captureSession else {
            throw RecordingError.setupFailed(reason: "Capture session not initialized for audio input.")
        }
        
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw RecordingError.deviceNotFound(mediaType: .audio)
        }
        
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
                self.audioDeviceInput = audioInput
            } else {
                throw RecordingError.inputOutputError(reason: "Cannot add audio input to the session.")
            }
        } catch {
            throw RecordingError.inputOutputError(reason: "Failed to create audio input: \(error.localizedDescription)")
        }
    }
    
    private func addVideoInput(position: AVCaptureDevice.Position = .back) throws { // Default to back camera
        guard let session = captureSession else {
            throw RecordingError.setupFailed(reason: "Capture session not initialized for video input.")
        }
        
        // More robust device discovery (e.g., .builtInWideAngleCamera)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera],
            mediaType: .video,
            position: position
        )
        
        guard let videoDevice = discoverySession.devices.first else { // Prefers wide angle if multiple found
            throw RecordingError.deviceNotFound(mediaType: .video)
        }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
                videoDeviceInput = videoInput
            } else {
                throw RecordingError.inputOutputError(reason: "Cannot add video input to the session.")
            }
            
            // Configure device frame rate
            try videoDevice.lockForConfiguration()
            videoDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 30)
            videoDevice.unlockForConfiguration()
        } catch {
            throw RecordingError.inputOutputError(reason: "Failed to create video input: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Session Observers
    private func addSessionObservers() {
        guard let session = captureSession else { return }
        if #available(iOS 17.0, *) {
            // Use the modern API names on iOS 17+
            NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
            NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
            NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        } else {
            // Use the older, raw-value based names on older iOS versions
            NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: NSNotification.Name("AVCaptureSessionRuntimeErrorNotification"), object: session)
            NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: NSNotification.Name("AVCaptureSessionWasInterruptedNotification"), object: session)
            NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: NSNotification.Name("AVCaptureSessionInterruptionEndedNotification"), object: session)
        }
    }
    
    private func removeSessionObservers() {
        if #available(iOS 17.0, *) {
            NotificationCenter.default.removeObserver(self, name: AVCaptureSession.runtimeErrorNotification, object: captureSession)
            NotificationCenter.default.removeObserver(self, name: AVCaptureSession.wasInterruptedNotification, object: captureSession)
            NotificationCenter.default.removeObserver(self, name: AVCaptureSession.interruptionEndedNotification, object: captureSession)
        } else {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("AVCaptureSessionRuntimeErrorNotification"), object: captureSession)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("AVCaptureSessionWasInterruptedNotification"), object: captureSession)
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name("AVCaptureSessionInterruptionEndedNotification"), object: captureSession)
        }
    }
    
    @objc private func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        let recordingError = RecordingError.recordingFailed(underlyingError: error)
        // If actively recording, stop and report error, otherwise report general service failure.
        if isRecording {
            delegate?.recordingDidStop(service: self, url: self.activeRecordingURL, error: recordingError)
            isRecording = false
        } else {
            delegate?.recordingServiceFailed(service: self, error: recordingError)
        }
    }
    
    @objc private func sessionWasInterrupted(notification: NSNotification) {
        guard
            let reasonValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue.intValue)
        else {
            return
        }
        delegate?.recordingSessionInterrupted(service: self, reason: reason)
    }
    
    @objc private func sessionInterruptionEnded(notification: NSNotification) {
        delegate?.recordingSessionInterruptionEnded(service: self)
        // Client might need to decide whether to re-start recording or session.
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension RecordingService: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // This callback is on an arbitrary queue. Dispatch to main for UI updates or state changes.
        delegate?.recordingDidStart(service: self)
    }
    
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let finalURL = activeRecordingURL ?? outputFileURL // Prefer the URL we initiated with
        activeRecordingURL = nil // Clear active URL
        
        let recordingError: RecordingError? = if let error {
            .recordingFailed(underlyingError: error)
        } else {
            nil
        }
        
        delegate?.recordingDidStop(service: self, url: finalURL, error: recordingError)
    }
}

// MARK: - DispatchQueue Extension for synchronous throwing tasks
@available(iOS 17.0, *)
extension DispatchQueue {
    // Helper to perform throwing tasks synchronously on the queue
    // Useful for sessionQueue operations that need to throw back to an async context.
    func perform<T>(group: DispatchGroup? = nil, qos: DispatchQoS = .default, flags: DispatchWorkItemFlags = [], execute work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.async(group: group, qos: qos, flags: flags) {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
