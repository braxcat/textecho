import AVFoundation

enum MicrophoneHelper {
    static func requestIfNeeded() {
        // AVCaptureDevice.requestAccess is for camera/capture APIs.
        // For AVAudioEngine, we need to briefly access the input node to trigger the prompt.
        // First try the standard API, then force a mic access if needed.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    // If denied via AVCaptureDevice, try triggering via AVAudioEngine
                    triggerAudioEnginePermission()
                }
            }
            // Also trigger AVAudioEngine access to ensure the permission dialog appears
            triggerAudioEnginePermission()
        } else if status == .denied || status == .restricted {
            // Permission was previously denied - user must fix in System Settings
            return
        }
    }

    /// Briefly access AVAudioEngine.inputNode to trigger macOS microphone permission dialog
    private static func triggerAudioEnginePermission() {
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AVAudioEngine()
            // Accessing inputNode triggers the permission prompt on macOS
            _ = engine.inputNode.inputFormat(forBus: 0)
        }
    }

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
