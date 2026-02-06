import AVFoundation

enum MicrophoneHelper {
    static func requestIfNeeded() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
