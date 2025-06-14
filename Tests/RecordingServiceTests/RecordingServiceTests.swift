import XCTest
import AVFoundation

@testable import RecordingService

extension RecordingError: Equatable {
    public static func == (lhs: RecordingError, rhs: RecordingError) -> Bool {
        String("\(lhs)") == String("\(rhs)")
    }
}

// MARK: - Mock Recording Service Delegate
/// This mock object acts as a "spy" to record every call made to the RecordingServiceDelegate.
final class MockRecordingServiceDelegate: RecordingServiceDelegate {

    // Expectations for asynchronous testing
    var recordingDidStartExpectation: XCTestExpectation?
    var recordingDidStopExpectation: XCTestExpectation?
    var recordingServiceFailedExpectation: XCTestExpectation?
    var sessionInterruptedExpectation: XCTestExpectation?
    var sessionInterruptionEndedExpectation: XCTestExpectation?

    // Properties to store the results of delegate calls
    private(set) var didStartCallCount = 0
    private(set) var didStopInfo: (url: URL?, error: RecordingError?)?
    private(set) var didFailError: RecordingError?
    private(set) var interruptionReason: AVCaptureSession.InterruptionReason?
    private(set) var interruptionEndedCallCount = 0

    func recordingDidStart(service: RecordingServiceProtocol) {
        didStartCallCount += 1
        recordingDidStartExpectation?.fulfill()
    }

    func recordingDidStop(service: RecordingServiceProtocol, url: URL?, error: RecordingError?) {
        didStopInfo = (url, error)
        recordingDidStopExpectation?.fulfill()
    }

    func recordingServiceFailed(service: RecordingServiceProtocol, error: RecordingError) {
        didFailError = error
        recordingServiceFailedExpectation?.fulfill()
    }

    func recordingSessionInterrupted(service: RecordingServiceProtocol, reason: AVCaptureSession.InterruptionReason?) {
        self.interruptionReason = reason
        sessionInterruptedExpectation?.fulfill()
    }

    func recordingSessionInterruptionEnded(service: RecordingServiceProtocol) {
        interruptionEndedCallCount += 1
        sessionInterruptionEndedExpectation?.fulfill()
    }
}

// MARK: - Mock AVFoundation Classes
/// Create mock subclasses of AVFoundation objects to control their behavior during tests.
final class MockAVCaptureSession: AVCaptureSession {
    var _isRunning = false
    override var isRunning: Bool { return _isRunning }
    
    var startRunningCallCount = 0
    var stopRunningCallCount = 0

    override func startRunning() {
        _isRunning = true
        startRunningCallCount += 1
    }

    override func stopRunning() {
        _isRunning = false
        stopRunningCallCount += 1
    }
    
    // We don't need real implementations for these in most tests
    override func canAddInput(_ input: AVCaptureInput) -> Bool { return true }
    override func addInput(_ input: AVCaptureInput) {}
    override func canAddOutput(_ output: AVCaptureOutput) -> Bool { return true }
    override func addOutput(_ output: AVCaptureOutput) {}
    override func beginConfiguration() {}
    override func commitConfiguration() {}
    override func removeInput(_ input: AVCaptureInput) {}
    override func removeOutput(_ output: AVCaptureOutput) {}
}

final class MockAVCaptureMovieFileOutput: AVCaptureMovieFileOutput {
    var _isRecording = false
    override var isRecording: Bool { return _isRecording }

    var startRecordingCallCount = 0
    var stopRecordingCallCount = 0
    var shouldFailOnStop = false // Control whether stopRecording produces an error
    
    weak var recordingDelegate: AVCaptureFileOutputRecordingDelegate?
    var lastOutputFileURL: URL?

    override func startRecording(to outputFileURL: URL, recordingDelegate delegate: AVCaptureFileOutputRecordingDelegate) {
        
        _isRecording = true
        startRecordingCallCount += 1
        self.recordingDelegate = delegate
        self.lastOutputFileURL = outputFileURL
        
        // Simulate the framework calling the delegate back immediately
        delegate.fileOutput?(self, didStartRecordingTo: outputFileURL, from: [])
    }

    override func stopRecording() {
        _isRecording = false
        stopRecordingCallCount += 1
        
        // Simulate the framework calling the delegate back
        let error = shouldFailOnStop ? NSError(domain: "TestError", code: 123, userInfo: nil) : nil
        if let lastOutputFileURL = lastOutputFileURL {
             recordingDelegate?.fileOutput(self, didFinishRecordingTo: lastOutputFileURL, from: [], error: error)
        }
    }
}

extension Recorder {
    // Testing purposes only
    convenience init(mode: RecordingMode, delegate: RecordingServiceDelegate? = nil) {
        self.init(
            mode: mode,
            delegate: delegate,
            session: AVCaptureSession(),
            fileOutput: AVCaptureMovieFileOutput()
        )
    }
}


// MARK: - Main Test Class
final class RecordingServiceTests: XCTestCase {

    var service: Recorder!
    var mockDelegate: MockRecordingServiceDelegate!
    var mockSession: MockAVCaptureSession!
    var mockFileOutput: MockAVCaptureMovieFileOutput!

    override func setUp() {
        super.setUp()
        mockDelegate = MockRecordingServiceDelegate()
        mockSession = MockAVCaptureSession()
        mockFileOutput = MockAVCaptureMovieFileOutput()
        
        service = Recorder(
            mode: .video,
            delegate: mockDelegate,
            session: mockSession,
            fileOutput: mockFileOutput
        )
    }

    override func tearDown() {
        service = nil
        mockDelegate = nil
        mockSession = nil
        mockFileOutput = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testSetsCorrectVideoMode() {
        // Given
        let videoService = Recorder(mode: .video)
        // Then
        XCTAssertEqual(videoService.currentMode, .video)
    }

    func testSetsCorrectAudioMode() {
        // Given
        let audioService = Recorder(mode: .audio)
        // Then
        XCTAssertEqual(audioService.currentMode, .audio)
    }

    // MARK: - State and Error Handling Tests

    func testStartRecordingWhenSessionNotRunning() {
        // Given
        mockSession._isRunning = false
        // Then
        XCTAssertThrowsError(try service.startRecording(fileName: "test")) { error in
            XCTAssertEqual(error as? RecordingError, .sessionNotRunning)
        }
    }

    func testStartRecordingWhenAlreadyRecording() {
        // GIVEN
        mockSession._isRunning = true

        // WHEN
        XCTAssertNoThrow(try service.startRecording(fileName: "first_test_recording"), "The first call to startRecording should not throw an error.")
        XCTAssertTrue(mockFileOutput.isRecording, "Precondition failed: The mock file output should be in a recording state.")

        // THEN
        XCTAssertThrowsError(try service.startRecording(fileName: "second_test_recording")) { error in
            XCTAssertEqual(error as? RecordingError, .recordingInProgress)
        }
    }
    
    func testStartCaptureSessionWhenNotInitialize() {
        // Given
        let expectation = XCTestExpectation(description: "startCaptureSession should fail")
        mockDelegate.recordingServiceFailedExpectation = expectation
        service.stopCaptureSession()
        service.captureSession = nil
        
        // When
        service.startCaptureSession { result in
            // Then
            guard case .failure(let error) = result,
                  let recordingError = error as? RecordingError else {
                XCTFail("Expected a failure result with a RecordingError")
                return
            }
            XCTAssertEqual(recordingError, .setupFailed(reason: "Session not initialized. Call setupSession() first."))
        }
        
        // Then
        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(mockDelegate.didFailError)
    }

    // MARK: - Happy Path Tests

    func testStartRecordingSuccessCallsDelegateAndUpdatesState() throws {
        // GIVEN
        mockSession._isRunning = true
        
        let expectation = XCTestExpectation(description: "recordingDidStart should be called")
        mockDelegate.recordingDidStartExpectation = expectation

        // WHEN
        try service.startRecording(fileName: "success_test")

        // THEN
        wait(for: [expectation], timeout: 1.0)

        // Verify that the service correctly interacted with the mocks.
        XCTAssertEqual(mockDelegate.didStartCallCount, 1)
        XCTAssertEqual(mockFileOutput.startRecordingCallCount, 1)
        XCTAssertTrue(mockFileOutput.isRecording)
    }

    func testStopRecordingSuccessCallsDelegateWithURL() throws {
        // GIVEN
        mockSession._isRunning = true
        
        // WHEN
        try service.startRecording(fileName: "test")

        let expectation = XCTestExpectation(description: "recordingDidStop should be called")
        mockDelegate.recordingDidStopExpectation = expectation

        service.stopRecording()

        // THEN
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(mockFileOutput.stopRecordingCallCount, 1)
        XCTAssertNotNil(mockDelegate.didStopInfo, "Delegate should have received stop information.")
        XCTAssertNotNil(mockDelegate.didStopInfo?.url, "A URL should be present on success.")
        XCTAssertNil(mockDelegate.didStopInfo?.error, "Error should be nil on success.")
        XCTAssertFalse(service.isRecording, "Service should no longer be in a recording state.")
    }
    // MARK: - Failure Path Tests

    func testStopRecording_WithError_CallsDelegateWithError() throws {
        // GIVEN
        mockSession._isRunning = true

        // WHEN
        try service.startRecording(fileName: "test")
        mockFileOutput.shouldFailOnStop = true
        
        let expectation = XCTestExpectation(description: "recordingDidStop should be called with an error")
        mockDelegate.recordingDidStopExpectation = expectation
        
        service.stopRecording()
        
        // THEN
        wait(for: [expectation], timeout: 1.0)
        
        XCTAssertNotNil(mockDelegate.didStopInfo, "Delegate should have received stop information.")
        XCTAssertNotNil(mockDelegate.didStopInfo?.error, "An error should be present.")
        XCTAssertFalse(service.isRecording, "Service should no longer be in a recording state even on failure.")
    }
}
