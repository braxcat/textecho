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
                        Text("TextEcho supports two activation modes:")
                        Text("")
                        Text("Toggle mode: Press the hotkey once to start recording, press again to stop.")
                        Text("Hold mode: Hold the hotkey to record, release to stop and transcribe.")
                        Text("")
                        Text("1. Place your cursor where you want text to appear")
                        Text("2. Activate recording with your chosen method (keyboard, mouse, Caps Lock, or pedal)")
                        Text("3. Speak clearly")
                        Text("4. Stop recording — text is transcribed and pasted automatically")
                        Text("")
                        Text("Silence auto-stop: Recording stops automatically after a configurable period of silence (default 2.5 seconds).")
                    }
                }

                // Activation Methods
                helpSection(title: "Activation Methods") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enable one or more methods in Settings:")
                            .font(.system(size: 12))
                        shortcutRow(keys: "Caps Lock", action: "Toggle recording on/off")
                        shortcutRow(keys: "Mouse button", action: "Toggle or hold (configurable button)")
                        shortcutRow(keys: "Keyboard shortcut", action: "Toggle or hold (default: Ctrl+Opt+Z)")
                        shortcutRow(keys: "Stream Deck Pedal", action: "Push-to-talk (hold)")
                    }
                }

                // Keyboard Shortcuts
                helpSection(title: "Keyboard Shortcuts") {
                    VStack(alignment: .leading, spacing: 6) {
                        shortcutRow(keys: "Ctrl + Shift + shortcut", action: "Record with LLM processing")
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

                // Transcription History
                helpSection(title: "Transcription History") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TextEcho saves your transcriptions so you can review and re-copy them later.")
                        Text("")
                        Text("Access history from the menu bar or via the History window. Recent transcriptions appear in the menu bar for quick re-copy. Configure the maximum number of entries (10-1000) in Settings.")
                        Text("")
                        Text("History is stored locally at ~/.textecho_history.json with restricted file permissions (owner-only read/write).")
                    }
                }

                // Themes
                helpSection(title: "Themes") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Customize the recording overlay's appearance in Settings.")
                        Text("")
                        Text("Built-in presets:")
                        Text("  TextEcho — bright cyan-blue (the original look)")
                        Text("  Cyber — teal-green cyberpunk")
                        Text("  Classic — clean grey")
                        Text("  Ocean — deep blue")
                        Text("  Sunset — warm orange-red")
                        Text("")
                        Text("Custom themes: Pick the Theme preset dropdown, choose \"Custom\", then use the color pickers to set background, text, accent, and waveform colors.")
                        Text("")
                        Text("Save your custom theme: Click \"Save Current…\" to name and save it. Your themes are stored at ~/.textecho_themes.json and appear in the preset picker alongside the built-ins. You can delete custom themes but not built-in ones.")
                    }
                }

                // Model Management
                helpSection(title: "Model Management") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Download, switch, and delete transcription models from Settings > Transcription Model.")
                        Text("")
                        Text("Model Memory: Configure how long the model stays in RAM after your last transcription. Options: Never unload (instant, uses ~1.6GB), 1 hour, 4 hours, 8 hours, or a custom duration.")
                        Text("")
                        Text("Default is Never — the model stays loaded for instant transcription. Change this in Settings if you need to free RAM.")
                    }
                }

                // Idle Timeout
                helpSection(title: "Idle Timeout") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The idle timeout controls how long the transcription model stays loaded in memory after your last transcription.")
                        Text("")
                        Text("When the model is loaded, transcription is instant — no startup delay. But it uses ~1.6GB of RAM (for Large V3 Turbo). If you don't dictate for a while, the model can unload to free that memory. The next transcription will take a few seconds while the model reloads.")
                        Text("")
                        Text("Presets in Settings > Model Memory:")
                        Text("  Never — model stays loaded permanently (best for frequent use)")
                        Text("  1 hour — unloads after 1 hour of inactivity")
                        Text("  4 hours — good balance for regular use throughout the day")
                        Text("  8 hours — unloads overnight if you leave the app running")
                        Text("  Custom — set any duration in seconds")
                        Text("")
                        Text("Recommendation: If you dictate throughout the day, leave it on Never. If you only dictate occasionally, set it to 1 or 4 hours to save RAM when you're not using it.")
                    }
                }

                // Settings
                helpSection(title: "Settings") {
                    VStack(alignment: .leading, spacing: 4) {
                        settingRow(name: "Activation", desc: "Enable Caps Lock, mouse, keyboard, or pedal triggers (toggle or hold mode)")
                        settingRow(name: "Transcription Model", desc: "Active model, download/delete models, idle timeout")
                        settingRow(name: "Silence Duration", desc: "Seconds of silence before auto-stop (default: 2.5)")
                        settingRow(name: "Silence Threshold", desc: "RMS level below which audio is silence (default: 0.015)")
                        settingRow(name: "Theme", desc: "Choose a preset or create custom colors for the overlay")
                        settingRow(name: "History", desc: "Enable/disable transcription history, menu bar display, max entries")
                        settingRow(name: "Overlay Position", desc: "Fixed position or follow cursor")
                    }
                }

                // Troubleshooting
                helpSection(title: "Troubleshooting") {
                    VStack(alignment: .leading, spacing: 6) {
                        troubleRow(issue: "Hotkeys don't work", fix: "Check Accessibility permission in System Settings. If you rebuilt the app, you may need to re-grant it.")
                        troubleRow(issue: "No audio captured", fix: "Check Microphone permission. Make sure your mic is selected in System Settings > Sound.")
                        troubleRow(issue: "Model not loading", fix: "Check internet connection for first download. Models are cached locally after first download.")
                        troubleRow(issue: "Transcription is gibberish", fix: "Try the large-v3 model in Settings for better accuracy. Speak clearly and reduce background noise.")
                        troubleRow(issue: "App uses too much memory", fix: "Set idle timeout in Settings > Transcription Model > Model Memory, or switch to the smaller base.en model.")
                    }
                }

                helpSection(title: "More Information") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full documentation, source code, and issue tracker:")
                        Button("Open on GitHub") {
                            if let url = URL(string: "https://github.com/braxcat/textecho") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 12))
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
