import AppKit
import SwiftUI

final class HelpWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = HelpView()
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 480, height: 400)
            window.center()
            window.title = "TextEcho Help"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Getting Started
                helpSection(title: "Getting Started") {
                    Text("TextEcho is a menu bar dictation app that transcribes your speech and pastes it wherever your cursor is. On first launch, grant Accessibility and Microphone permissions, then choose a transcription model to download.")
                }

                // How to Dictate
                helpSection(title: "How to Dictate") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Place your cursor where you want text to appear")
                        Text("2. Hold the dictation hotkey (default: Ctrl+D) or middle-click")
                        Text("3. Speak clearly")
                        Text("4. Release the key — text is transcribed and pasted automatically")
                        Text("")
                        Text("Silence auto-stop: Recording stops automatically after a configurable period of silence (default 2.5 seconds).")
                    }
                }

                // Keyboard Shortcuts
                helpSection(title: "Keyboard Shortcuts") {
                    VStack(alignment: .leading, spacing: 6) {
                        shortcutRow(keys: "Ctrl + D (hold)", action: "Record and transcribe")
                        shortcutRow(keys: "Ctrl + Shift + D (hold)", action: "Record with LLM processing")
                        shortcutRow(keys: "Middle mouse (hold)", action: "Record and transcribe")
                        shortcutRow(keys: "Ctrl + Middle mouse (hold)", action: "Record with LLM processing")
                        shortcutRow(keys: "Cmd + Option + Space", action: "Open Settings")
                        shortcutRow(keys: "Cmd + Option + 1-9", action: "Save clipboard to register")
                        shortcutRow(keys: "Cmd + Option + 0", action: "Clear all registers")
                        shortcutRow(keys: "Esc", action: "Cancel recording")
                    }
                }

                // Stream Deck Pedal
                helpSection(title: "Stream Deck Pedal") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TextEcho supports the Elgato Stream Deck Pedal for hands-free push-to-talk.")
                        Text("")
                        Text("1. Connect the Stream Deck Pedal via USB")
                        Text("2. Enable pedal support in Settings")
                        Text("3. Choose which pedal (left, center, or right) to use")
                        Text("4. Press and hold the pedal to record, release to transcribe")
                    }
                }

                // Settings
                helpSection(title: "Settings") {
                    VStack(alignment: .leading, spacing: 4) {
                        settingRow(name: "Mouse Button", desc: "Which mouse button triggers recording (default: middle)")
                        settingRow(name: "Dictation Key", desc: "Which keyboard key triggers recording (default: D)")
                        settingRow(name: "Modifiers", desc: "Which modifier keys must be held (default: Ctrl)")
                        settingRow(name: "Silence Duration", desc: "Seconds of silence before auto-stop (default: 2.5)")
                        settingRow(name: "Silence Threshold", desc: "RMS level below which audio is silence (default: 0.015)")
                        settingRow(name: "Sample Rate", desc: "Audio recording sample rate in Hz (default: 16000)")
                        settingRow(name: "Transcription Model", desc: "Which Whisper model to use for transcription")
                    }
                }

                // Troubleshooting
                helpSection(title: "Troubleshooting") {
                    VStack(alignment: .leading, spacing: 6) {
                        troubleRow(issue: "Hotkeys don't work", fix: "Check Accessibility permission in System Settings. If you rebuilt the app, you may need to re-grant it.")
                        troubleRow(issue: "No audio captured", fix: "Check Microphone permission. Make sure your mic is selected in System Settings > Sound.")
                        troubleRow(issue: "Model not loading", fix: "Check internet connection for first download. Models are cached locally after first download.")
                        troubleRow(issue: "Transcription is gibberish", fix: "Try the large-v3 model in Settings for better accuracy. Speak clearly and reduce background noise.")
                        troubleRow(issue: "App uses too much memory", fix: "The model auto-unloads after 1 hour of idle. You can also switch to the smaller base.en model.")
                    }
                }

                // Model Selection
                helpSection(title: "Model Selection") {
                    VStack(alignment: .leading, spacing: 6) {
                        modelRow(name: "Large V3 Turbo", size: "~1.6 GB", desc: "Best balance of speed and quality. Recommended for most users.")
                        modelRow(name: "Large V3", size: "~3 GB", desc: "Highest transcription quality, but slower. Use when accuracy matters most.")
                        modelRow(name: "Base (English)", size: "~140 MB", desc: "Very fast, smallest download. Good for clear speech in quiet environments.")
                    }
                }

                // LLM Module
                helpSection(title: "LLM Module (Optional)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TextEcho can optionally process transcriptions through a local LLM (large language model) for summarization, translation, or reformatting.")
                        Text("")
                        Text("To install the LLM module:")
                        Text("  1. Rebuild with: ./build_native_app.sh --with-llm")
                        Text("  2. Set a GGUF model path in Settings")
                        Text("  3. Enable LLM in Settings")
                        Text("  4. Use Ctrl+Shift+D to record with LLM processing")
                        Text("")
                        Text("Requires Python 3.12 and a compatible GGUF model file.")
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    // MARK: - Section builders

    private func helpSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
            content()
                .font(.system(size: 12))
        }
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(4)
                .fixedSize()

            Text(action)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func settingRow(name: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(name):")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 130, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func troubleRow(issue: String, fix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue)
                .font(.system(size: 12, weight: .semibold))
            Text(fix)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func modelRow(name: String, size: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                Text(size)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
