import AppKit
import AVFoundation
import SwiftUI

final class SetupWizardController {
    private var window: NSWindow?
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func show() {
        if window == nil {
            let view = SetupWizardView(onClose: onClose)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "TextEcho Setup"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

struct SetupWizardView: View {
    @State private var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted()
    @State private var micStatus: AVAuthorizationStatus = MicrophoneHelper.authorizationStatus()

    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Finish Setup")
                    .font(.system(size: 16, weight: .semibold))

                Text("TextEcho needs Accessibility and Microphone permissions to listen for shortcuts and record audio. After granting permissions, restart the app.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("Accessibility")
                    Spacer()
                    statusBadge(accessibilityTrusted)
                }

                Button("Open Accessibility Settings") {
                    openSystemPreferences(anchor: "Privacy_Accessibility")
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    statusBadge(micStatus == .authorized)
                }

                Button("Open Microphone Settings") {
                    openSystemPreferences(anchor: "Privacy_Microphone")
                }

                Divider()

                Text("After granting permissions")
                    .font(.system(size: 13, weight: .semibold))

                Button("Restart TextEcho") {
                    restartApp()
                }

                Button("I’ve granted permissions") {
                    refreshStatus()
                    if accessibilityTrusted && micStatus == .authorized {
                        onClose()
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 460)
        .onAppear {
            refreshStatus()
        }
    }

    private func statusBadge(_ ok: Bool) -> some View {
        Text(ok ? "Granted" : "Missing")
            .font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(ok ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .cornerRadius(6)
    }

    private func refreshStatus() {
        accessibilityTrusted = AccessibilityHelper.isTrusted()
        micStatus = MicrophoneHelper.authorizationStatus()
    }

    private func openSystemPreferences(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartApp() {
        let appURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appURL.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
