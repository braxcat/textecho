import AppKit
import SwiftUI

enum OverlayState {
    case hidden
    case recording
    case processing
    case result(isLLM: Bool)
    case error
}

final class OverlayViewModel: ObservableObject {
    @Published var state: OverlayState = .hidden
    @Published var statusText: String = ""
    @Published var resultText: String = ""
    @Published var waveform: [Double] = Array(repeating: 0.05, count: 40)

    func showRecording(isLLM: Bool) {
        state = .recording
        statusText = isLLM ? "Recording (LLM)…" : "Recording…"
        resultText = ""
        waveform = Array(repeating: 0.05, count: 40)
    }

    func showProcessing(isLLM: Bool) {
        state = .processing
        statusText = isLLM ? "Processing (LLM)…" : "Transcribing…"
    }

    func showResult(_ text: String, isLLM: Bool) {
        state = .result(isLLM: isLLM)
        statusText = isLLM ? "LLM Response" : "Transcribed"
        resultText = text
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

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    private let width: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if case .recording = viewModel.state {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .shadow(color: .red.opacity(0.5), radius: 4)
                }

                Text(viewModel.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(statusColor)

                Spacer()
            }

            if case .recording = viewModel.state {
                WaveformView(levels: viewModel.waveform)
                    .frame(height: 50)
            }

            if !viewModel.resultText.isEmpty {
                Text(viewModel.resultText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.9))
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.75), Color.black.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .recording:
            return .red
        case .processing:
            return .yellow
        case .result(let isLLM):
            return isLLM ? .purple : .green
        case .error:
            return .red
        case .hidden:
            return .white
        }
    }
}

struct WaveformView: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(colors: [Color.cyan, Color.purple], startPoint: .bottom, endPoint: .top)
                    )
                    .frame(width: 4, height: barHeight(level: levels[index]))
            }
        }
    }

    private func barHeight(level: Double) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 70
        let normalized = min(max(level, 0.0), 1.0)
        let boosted = min(max(pow(normalized, 0.6) * 1.2, 0.0), 1.0)
        return minHeight + (maxHeight - minHeight) * CGFloat(boosted)
    }
}

final class OverlayWindowController {
    private let viewModel = OverlayViewModel()
    private var window: NSWindow?
    private var followTimer: Timer?

    init() {
        setupWindow()
    }

    func showRecording(isLLM: Bool) {
        DispatchQueue.main.async {
            self.viewModel.showRecording(isLLM: isLLM)
            self.show()
        }
    }

    func showProcessing(isLLM: Bool) {
        DispatchQueue.main.async {
            self.viewModel.showProcessing(isLLM: isLLM)
            self.show()
        }
    }

    func showResult(_ text: String, isLLM: Bool) {
        DispatchQueue.main.async {
            self.viewModel.showResult(text, isLLM: isLLM)
            self.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.hide()
            }
        }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async {
            self.viewModel.showError(message)
            self.show()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.stopFollow()
            self.window?.orderOut(nil)
            self.viewModel.hide()
        }
    }

    func updateWaveform(_ levels: [Double]) {
        DispatchQueue.main.async {
            self.viewModel.waveform = levels.map { min(max($0 * 1.6, 0.0), 1.0) }
        }
    }

    private func setupWindow() {
        let hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 140)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        self.window = window
    }

    private func show() {
        positionNearMouse()
        window?.orderFront(nil)
        startFollow()
    }

    private func startFollow() {
        stopFollow()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.positionNearMouse()
        }
    }

    private func stopFollow() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func positionNearMouse() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.main?.frame ?? .zero
        let width = window.frame.width
        let height = window.frame.height
        let padding: CGFloat = 16

        var x = mouse.x - width / 2
        var y = mouse.y + padding

        if y + height > screen.maxY - padding {
            y = mouse.y - height - padding
        }

        if x < screen.minX + padding { x = screen.minX + padding }
        if x + width > screen.maxX - padding { x = screen.maxX - width - padding }
        if y < screen.minY + padding { y = screen.minY + padding }

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
