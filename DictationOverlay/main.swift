import Cocoa
import SwiftUI

// MARK: - Overlay State

enum OverlayState: String, Codable {
    case recording
    case processing
    case result
    case error
    case hidden
}

class OverlayViewModel: ObservableObject {
    @Published var state: OverlayState = .hidden
    @Published var statusText: String = ""
    @Published var resultText: String = ""
    @Published var isLLM: Bool = false
    @Published var waveformLevels: [CGFloat] = Array(repeating: 0.05, count: 40)

    func showRecording() {
        state = .recording
        statusText = "Recording..."
        resultText = ""
        waveformLevels = Array(repeating: 0.05, count: 40)
    }

    func updateWaveform(_ levels: [CGFloat]) {
        waveformLevels = levels
    }

    func showProcessing() {
        state = .processing
        statusText = "Processing..."
    }

    func showResult(_ text: String, isLLM: Bool) {
        state = .result
        self.isLLM = isLLM
        statusText = isLLM ? "LLM Response" : "Transcribed"
        resultText = String(text.prefix(200))
        if text.count > 200 {
            resultText += "..."
        }
    }

    func showError(_ message: String) {
        state = .error
        statusText = "Error"
        resultText = message
    }

    func hide() {
        state = .hidden
    }
}

// MARK: - Tokyo Night Colors

struct TokyoNight {
    static let bg = Color(red: 0.10, green: 0.11, blue: 0.15)
    static let fg = Color(red: 0.66, green: 0.70, blue: 0.84)
    static let red = Color(red: 0.96, green: 0.45, blue: 0.51)
    static let green = Color(red: 0.45, green: 0.82, blue: 0.56)
    static let yellow = Color(red: 0.88, green: 0.74, blue: 0.45)
    static let magenta = Color(red: 0.73, green: 0.56, blue: 0.94)
    static let cyan = Color(red: 0.49, green: 0.85, blue: 0.86)
}

// MARK: - Waveform View

struct WaveformView: View {
    let levels: [CGFloat]
    let barWidth: CGFloat = 4
    let barSpacing: CGFloat = 2
    let maxHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<levels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barGradient)
                    .frame(width: barWidth, height: barHeight(for: levels[index]))
            }
        }
        .frame(height: maxHeight)
    }

    var barGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [TokyoNight.cyan, TokyoNight.magenta]),
            startPoint: .bottom,
            endPoint: .top
        )
    }

    func barHeight(for level: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 4
        let normalized = min(max(level, 0), 1)
        return minHeight + (maxHeight - minHeight) * normalized
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var statusColor: Color {
        switch viewModel.state {
        case .recording: return TokyoNight.red
        case .processing: return TokyoNight.yellow
        case .result: return viewModel.isLLM ? TokyoNight.magenta : TokyoNight.green
        case .error: return TokyoNight.red
        case .hidden: return TokyoNight.fg
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Recording indicator
                if viewModel.state == .recording {
                    Circle()
                        .fill(TokyoNight.red)
                        .frame(width: 12, height: 12)
                }

                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusColor)

                Spacer()
            }

            // Waveform when recording
            if viewModel.state == .recording {
                WaveformView(levels: viewModel.waveformLevels)
                    .animation(.easeOut(duration: 0.05), value: viewModel.waveformLevels)
            }

            if !viewModel.resultText.isEmpty {
                Text(viewModel.resultText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(TokyoNight.cyan)
                    .lineLimit(3)
            }
        }
        .padding(15)
        .frame(width: 400, alignment: .leading)
        .background(TokyoNight.bg.opacity(0.95))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Overlay Window Controller

class OverlayWindowController {
    var window: NSWindow?
    let viewModel = OverlayViewModel()
    var positionTimer: Timer?
    var followMouse: Bool = true  // Auto-follow mouse while visible

    init() {
        setupWindow()
    }

    func setupWindow() {
        let contentView = OverlayView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 120)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.level = .floating
        window?.hasShadow = true
        window?.ignoresMouseEvents = true
        window?.contentView = hostingView
        window?.isReleasedWhenClosed = false
    }

    func positionAtMouse() {
        guard let window = window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screenFrame = NSScreen.main?.frame ?? .zero
        let windowWidth = window.frame.width
        let windowHeight = window.frame.height
        let padding: CGFloat = 15

        // Default: center horizontally above the mouse
        var x = mouseLocation.x - windowWidth / 2
        var y = mouseLocation.y + padding

        // Check if there's room above
        let roomAbove = screenFrame.maxY - mouseLocation.y - padding
        let roomBelow = mouseLocation.y - screenFrame.minY - padding
        let roomRight = screenFrame.maxX - mouseLocation.x - padding
        let roomLeft = mouseLocation.x - screenFrame.minX - padding

        if roomAbove >= windowHeight {
            // Position above (preferred)
            y = mouseLocation.y + padding
            x = mouseLocation.x - windowWidth / 2
        } else if roomBelow >= windowHeight {
            // Position below
            y = mouseLocation.y - windowHeight - padding
            x = mouseLocation.x - windowWidth / 2
        } else if roomRight >= windowWidth {
            // Position to the right
            x = mouseLocation.x + padding
            y = mouseLocation.y - windowHeight / 2
        } else if roomLeft >= windowWidth {
            // Position to the left
            x = mouseLocation.x - windowWidth - padding
            y = mouseLocation.y - windowHeight / 2
        } else {
            // Fallback: position below anyway
            y = mouseLocation.y - windowHeight - padding
            x = mouseLocation.x - windowWidth / 2
        }

        // Keep horizontally on screen
        if x < screenFrame.minX + padding {
            x = screenFrame.minX + padding
        }
        if x + windowWidth > screenFrame.maxX - padding {
            x = screenFrame.maxX - windowWidth - padding
        }

        // Keep vertically on screen
        if y < screenFrame.minY + padding {
            y = screenFrame.minY + padding
        }
        if y + windowHeight > screenFrame.maxY - padding {
            y = screenFrame.maxY - windowHeight - padding
        }

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        positionAtMouse()
        window?.orderFront(nil)
        startPositionTimer()
    }

    func hide() {
        stopPositionTimer()
        window?.orderOut(nil)
    }

    func startPositionTimer() {
        stopPositionTimer()
        if followMouse {
            positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updatePosition()
            }
        }
    }

    func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    func updatePosition() {
        if window?.isVisible == true {
            positionAtMouse()
        }
    }
}

// MARK: - Command Handler

struct Command: Codable {
    let action: String
    let text: String?
    let isLLM: Bool?
    let levels: [Double]?
}

class CommandHandler {
    let overlayController: OverlayWindowController

    init(overlayController: OverlayWindowController) {
        self.overlayController = overlayController
    }

    func handleCommand(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let command = try? JSONDecoder().decode(Command.self, from: data) else {
            fputs("Invalid command: \(jsonString)\n", stderr)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch command.action {
            case "show_recording":
                self.overlayController.viewModel.showRecording()
                self.overlayController.show()

            case "show_processing":
                self.overlayController.viewModel.showProcessing()

            case "show_result":
                let text = command.text ?? ""
                let isLLM = command.isLLM ?? false
                self.overlayController.viewModel.showResult(text, isLLM: isLLM)

            case "show_error":
                let message = command.text ?? "Unknown error"
                self.overlayController.viewModel.showError(message)

            case "hide":
                self.overlayController.hide()
                self.overlayController.viewModel.hide()

            case "update_position":
                self.overlayController.updatePosition()

            case "update_waveform":
                if let levels = command.levels {
                    let cgLevels = levels.map { CGFloat($0) }
                    self.overlayController.viewModel.updateWaveform(cgLevels)
                }

            case "quit":
                NSApplication.shared.terminate(nil)

            default:
                fputs("Unknown action: \(command.action)\n", stderr)
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayController: OverlayWindowController!
    var commandHandler: CommandHandler!
    var stdinSource: DispatchSourceRead?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayController = OverlayWindowController()
        commandHandler = CommandHandler(overlayController: overlayController)

        // Read commands from stdin
        setupStdinReader()

        // Signal ready
        print("READY")
        fflush(stdout)
    }

    func setupStdinReader() {
        let stdin = FileHandle.standardInput

        stdinSource = DispatchSource.makeReadSource(fileDescriptor: stdin.fileDescriptor, queue: .global())

        stdinSource?.setEventHandler { [weak self] in
            let data = stdin.availableData
            if data.isEmpty {
                // EOF - stdin closed, quit
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return
            }

            if let string = String(data: data, encoding: .utf8) {
                // Handle each line as a command
                let lines = string.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    self?.commandHandler.handleCommand(String(line))
                }
            }
        }

        stdinSource?.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stdinSource?.cancel()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
