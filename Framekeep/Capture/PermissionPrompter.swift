import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum PermissionPrompter {
    static func screenGranted() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    @discardableResult
    static func requestScreen() -> Bool {
        if #available(macOS 11.0, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }

    static func openScreenRecordingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for raw in candidates {
            guard let url = URL(string: raw), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    static func microphoneGranted() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        default:
            return false
        }
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func currentState() -> CapturePermissionState {
        CapturePermissionState(
            screenGranted: screenGranted(),
            microphoneGranted: microphoneGranted()
        )
    }
}
