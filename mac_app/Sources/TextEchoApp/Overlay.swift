import AppKit
import SwiftUI

enum OverlayState: Equatable {
    case hidden
    case recording
    case processing
    case loadingModel
    case downloading
    case result(isLLM: Bool)
    case error

    static func == (lhs: OverlayState, rhs: OverlayState) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden), (.recording, .recording), (.processing, .processing),
             (.loadingModel, .loadingModel), (.downloading, .downloading), (.error, .error):
            return true
        case (.result(let a), .result(let b)):
            return a == b
        default:
            return false
        }
    }
}

final class OverlayViewModel: ObservableObject {
    @Published var state: OverlayState = .hidden
    @Published var statusText: String = ""
    @Published var resultText: String = ""
    @Published var waveform: [Double] = Array(repeating: 0.0, count: 40)
    @Published var appearTrigger: Bool = false

    func showRecording(isLLM: Bool) {
        state = .recording
        statusText = isLLM ? "RECORDING // LLM" : "RECORDING"
        resultText = ""
        waveform = Array(repeating: 0.0, count: 40)
    }

    func showProcessing(isLLM: Bool) {
        state = .processing
        statusText = isLLM ? "PROCESSING // LLM" : "TRANSCRIBING"
    }

    func showResult(_ text: String, isLLM: Bool) {
        state = .result(isLLM: isLLM)
        statusText = isLLM ? "LLM RESPONSE" : "TRANSCRIBED"
        resultText = text
    }

    func showLoadingModel() {
        state = .loadingModel
        statusText = "LOADING MODEL"
        resultText = ""
    }

    func showDownloading() {
        state = .downloading
        statusText = "DOWNLOADING MODEL"
        resultText = "This only happens once."
    }

    func showError(_ message: String) {
        state = .error
        statusText = "ERROR"
        resultText = message
    }

    func hide() {
        state = .hidden
    }
}

// MARK: - Color palette (Artificer Cyber)

struct OverlayTheme {
    static var current: OverlayTheme { OverlayTheme() }

    let recording: Color
    let processing: Color
    let success: Color
    let error: Color
    let loading: Color
    let waveform: Color
    let bgDark: Color
    let bgLight: Color

    /// Matrix green for logo — derived from success color brightened
    var logoGreen: Color { success }

    init() {
        let cfg = AppConfig.shared.model
        recording = Color(hex: cfg.colorRecording) ?? Color(red: 0.0, green: 1.0, blue: 0.88)
        processing = Color(hex: cfg.colorProcessing) ?? Color(red: 0.54, green: 0.36, blue: 0.96)
        success = Color(hex: cfg.colorSuccess) ?? Color(red: 0.3, green: 0.85, blue: 0.65)
        error = Color(hex: cfg.colorError) ?? Color(red: 1.0, green: 0.2, blue: 0.2)
        loading = Color(hex: cfg.colorLoading) ?? Color(red: 1.0, green: 0.76, blue: 0.0)
        waveform = Color(hex: cfg.colorWaveform) ?? Color(red: 0.3, green: 0.6, blue: 0.9)
        bgDark = Color(hex: cfg.colorBgDark) ?? Color(red: 0.04, green: 0.04, blue: 0.1)
        bgLight = Color(hex: cfg.colorBgLight) ?? Color(red: 0.06, green: 0.06, blue: 0.14)
    }

    /// Named presets
    static let presets: [String: [String: String]] = [
        "textecho": [
            "colorRecording": "#00E6FF",
            "colorProcessing": "#8A5CF6",
            "colorSuccess": "#4DD9A6",
            "colorError": "#FF3333",
            "colorLoading": "#FFC200",
            "colorWaveform": "#00E6FF",
            "colorBgDark": "#0A0A1A",
            "colorBgLight": "#0F0F24",
        ],
        "cyber": [
            "colorRecording": "#00FFE0",
            "colorProcessing": "#8A5CF6",
            "colorSuccess": "#4DD9A6",
            "colorError": "#FF3333",
            "colorLoading": "#FFC200",
            "colorWaveform": "#4D99E6",
            "colorBgDark": "#0A0A1A",
            "colorBgLight": "#0F0F24",
        ],
        "classic": [
            "colorRecording": "#4A90D9",
            "colorProcessing": "#7B68EE",
            "colorSuccess": "#50C878",
            "colorError": "#DC3545",
            "colorLoading": "#FFB347",
            "colorWaveform": "#6495ED",
            "colorBgDark": "#1A1A2E",
            "colorBgLight": "#16213E",
        ],
        "ocean": [
            "colorRecording": "#00CED1",
            "colorProcessing": "#4169E1",
            "colorSuccess": "#20B2AA",
            "colorError": "#FF6B6B",
            "colorLoading": "#48D1CC",
            "colorWaveform": "#5F9EA0",
            "colorBgDark": "#0B132B",
            "colorBgLight": "#1C2541",
        ],
        "sunset": [
            "colorRecording": "#FF6B35",
            "colorProcessing": "#D63384",
            "colorSuccess": "#FFC107",
            "colorError": "#DC3545",
            "colorLoading": "#FF8C42",
            "colorWaveform": "#E85D75",
            "colorBgDark": "#1A0A0A",
            "colorBgLight": "#2D1B1B",
        ],
    ]
}

// MARK: - User theme presets (persisted to ~/.textecho_themes.json)

final class UserThemePresets {
    static let shared = UserThemePresets()

    private let fileURL: URL
    private(set) var presets: [String: [String: String]] = [:]

    private static let reservedNames: Set<String> = ["textecho", "cyber", "classic", "ocean", "sunset", "custom"]

    private init() {
        fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".textecho_themes.json")
        load()
    }

    func save(name: String, colors: [String: String]) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !Self.reservedNames.contains(key) else { return }
        presets[key] = colors
        persist()
    }

    func delete(name: String) {
        let key = name.lowercased()
        guard !Self.reservedNames.contains(key) else { return }
        presets.removeValue(forKey: key)
        persist()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            presets = [:]
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if let decoded = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
                presets = decoded
            }
        } catch {
            presets = [:]
        }
    }

    func isReserved(_ name: String) -> Bool {
        Self.reservedNames.contains(name.lowercased())
    }

    private func persist() {
        do {
            let data = try JSONSerialization.data(withJSONObject: presets, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
            // Set file permissions to 0600 (owner read/write only)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Silent failure — non-critical
        }
    }
}

// MARK: - Color hex parsing

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let rgb = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(components.redComponent * 255))
        let g = Int(round(components.greenComponent * 255))
        let b = Int(round(components.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Legacy alias for compatibility
private struct CyberColors {
    static let cyan = Color(red: 0.0, green: 1.0, blue: 0.88)       // #00FFE0
    static let magenta = Color(red: 1.0, green: 0.0, blue: 0.4)     // #FF0066
    static let purple = Color(red: 0.54, green: 0.36, blue: 0.96)   // #8A5CF6
    static let green = Color(red: 0.2, green: 1.0, blue: 0.2)       // #33FF33 matrix green
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.0)      // #FFC200
    static let red = Color(red: 1.0, green: 0.2, blue: 0.2)         // #FF3333
    static let bgDark = Color(red: 0.04, green: 0.04, blue: 0.1)    // #0A0A1A
    static let bgMid = Color(red: 0.06, green: 0.06, blue: 0.14)    // #0F0F24
    static let borderGlow = Color(red: 0.0, green: 0.8, blue: 0.7)  // #00CCB3
}

// MARK: - Main overlay view

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowIntensity: Double = 0.4
    @State private var popScale: CGFloat = 0.92
    @State private var popOpacity: Double = 0.0

    private let width: CGFloat = 420

    /// Friendly model name for display
    private static var modelBadge: String {
        let configName = AppConfig.shared.model.whisperModel
        if let info = WhisperKitTranscriber.availableModelList.first(where: { $0.name == configName }) {
            return info.displayName.uppercased()
        }
        // Fallback: strip prefix and clean up
        return configName
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top accent line
            Rectangle()
                .fill(accentGradient)
                .frame(height: 2)
                .shadow(color: accentColor.opacity(0.6), radius: 6)

            VStack(alignment: .leading, spacing: 10) {
                // Status row with logo
                HStack(spacing: 8) {
                    statusIndicator

                    Text(viewModel.statusText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(accentColor)
                        .tracking(1.5)

                    Spacer()

                    // Logo: silver TEXT + neon green ECHO
                    HStack(spacing: 3) {
                        Text("TEXT")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(Color(white: 0.7))
                        Text("ECHO")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(theme.success.opacity(0.8))
                            .shadow(color: theme.success.opacity(0.3), radius: 4)
                    }
                    .tracking(1.5)
                }

                // Waveform (recording state)
                if case .recording = viewModel.state {
                    CyberWaveformView(levels: viewModel.waveform, waveformColor: theme.waveform, recordingColor: theme.recording)
                        .frame(height: 64)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Scanner bar (processing or loading model state)
                if case .processing = viewModel.state {
                    ScannerBarView(barColor: theme.processing)
                        .frame(height: 4)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                }
                if case .loadingModel = viewModel.state {
                    ScannerBarView(barColor: theme.loading)
                        .frame(height: 4)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                }

                // Result text — expands to show full transcription
                if !viewModel.resultText.isEmpty {
                    Text(viewModel.resultText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(resultTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Bottom bar: model badge
                HStack(spacing: 0) {
                    Spacer()
                    Text("WHISPER // \(Self.modelBadge)")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.success.opacity(0.3))
                        .tracking(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        }
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(borderOverlay)
        .shadow(color: accentColor.opacity(0.15), radius: 20, x: 0, y: 8)
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
        .scaleEffect(popScale)
        .opacity(popOpacity)
        .onAppear { startAnimations() }
        .onChange(of: viewModel.appearTrigger) { _ in
            popScale = 0.92
            popOpacity = 0.0
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                popScale = 1.0
                popOpacity = 1.0
            }
        }
    }

    // MARK: - Status indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch viewModel.state {
        case .recording:
            Circle()
                .fill(Color(red: 0.0, green: 0.9, blue: 1.0))
                .frame(width: 8, height: 8)
                .scaleEffect(pulseScale)
                .shadow(color: Color(red: 0.0, green: 0.9, blue: 1.0).opacity(0.7), radius: 6)
        case .processing:
            Circle()
                .fill(CyberColors.purple)
                .frame(width: 8, height: 8)
                .opacity(glowIntensity)
                .shadow(color: CyberColors.purple.opacity(0.5), radius: 4)
        case .loadingModel:
            Circle()
                .fill(CyberColors.amber)
                .frame(width: 8, height: 8)
                .opacity(glowIntensity)
                .shadow(color: CyberColors.amber.opacity(0.6), radius: 4)
        case .downloading:
            Circle()
                .fill(CyberColors.amber)
                .frame(width: 8, height: 8)
                .shadow(color: CyberColors.amber.opacity(0.5), radius: 4)
        case .result:
            Circle()
                .fill(Color(red: 0.3, green: 0.85, blue: 0.65))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 0.3, green: 0.85, blue: 0.65).opacity(0.5), radius: 4)
        case .error:
            Circle()
                .fill(CyberColors.red)
                .frame(width: 8, height: 8)
                .shadow(color: CyberColors.red.opacity(0.5), radius: 4)
        case .hidden:
            EmptyView()
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            // Base dark gradient
            LinearGradient(
                colors: [theme.bgDark, theme.bgLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle noise/texture overlay
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.08)

            // Accent glow from top
            LinearGradient(
                colors: [accentColor.opacity(0.06), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                LinearGradient(
                    colors: [
                        accentColor.opacity(0.3),
                        accentColor.opacity(0.08),
                        theme.processing.opacity(0.15),
                        accentColor.opacity(0.2)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    // MARK: - Colors

    private var theme: OverlayTheme { OverlayTheme.current }

    private var accentColor: Color {
        switch viewModel.state {
        case .recording: return theme.recording
        case .processing: return theme.processing
        case .loadingModel: return theme.loading
        case .downloading: return theme.loading
        case .result(let isLLM): return isLLM ? theme.processing : theme.success
        case .error: return theme.error
        case .hidden: return theme.success
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.3)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var resultTextColor: Color {
        switch viewModel.state {
        case .result(let isLLM): return isLLM ? theme.processing.opacity(0.9) : theme.success.opacity(0.9)
        case .error: return theme.error.opacity(0.9)
        default: return theme.success.opacity(0.9)
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        // Pulse animation for recording indicator
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            pulseScale = 1.4
        }
        // Glow animation for processing
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            glowIntensity = 1.0
        }
    }
}

// MARK: - Cyberpunk waveform

struct CyberWaveformView: View {
    let levels: [Double]
    var waveformColor: Color = Color(red: 0.3, green: 0.6, blue: 0.9)
    var recordingColor: Color = Color(red: 0.0, green: 0.9, blue: 1.0)
    private let silenceThreshold: Double = 0.005
    @State private var pulseOpacity: Double = 0.4

    var body: some View {
        ZStack(alignment: .center) {
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = levels[index]
                    let isActive = level >= silenceThreshold
                    let barColor = barGradient(index: index, active: isActive)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: 6, height: barHeight(level: level, active: isActive))
                        .shadow(color: isActive ? waveformColor.opacity(0.5) : .clear, radius: 4)
                        .animation(.easeOut(duration: 0.06), value: level)
                }
            }

            // Vertical force-field line at center
            GeometryReader { geo in
                let lineX = geo.size.width / 2
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                recordingColor.opacity(0),
                                recordingColor.opacity(pulseOpacity),
                                recordingColor,
                                recordingColor.opacity(pulseOpacity),
                                recordingColor.opacity(0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2)
                    .shadow(color: recordingColor.opacity(0.8), radius: 6)
                    .position(x: lineX, y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulseOpacity = 1.0
                }
            }
        }
    }

    private func barGradient(index: Int, active: Bool) -> LinearGradient {
        let progress = Double(index) / Double(max(levels.count - 1, 1))
        let startColor = active
            ? waveformColor
            : waveformColor.opacity(0.12)
        let endColor = active
            ? waveformColor.opacity(0.8)
            : waveformColor.opacity(0.08)

        return LinearGradient(
            colors: [
                interpolateColor(startColor, endColor, progress),
                interpolateColor(startColor, endColor, progress).opacity(active ? 0.75 : 0.1)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func interpolateColor(_ a: Color, _ b: Color, _ t: Double) -> Color {
        // Simple visual blend via opacity layering
        return t < 0.5 ? a : b
    }

    private func barHeight(level: Double, active: Bool) -> CGFloat {
        guard active else { return 3 }
        let maxHeight: CGFloat = 60
        let minActive: CGFloat = 6
        let amplifiedLevel = min(level * 5.0, 1.0) // keep quiet-but-valid speech visibly active
        let normalized = min(max(amplifiedLevel, 0.0), 1.0)
        let scaled = pow(normalized, 0.5) // more responsive to quiet sounds
        return minActive + (maxHeight - minActive) * CGFloat(scaled)
    }
}

// MARK: - Scanner bar (processing animation)

struct ScannerBarView: View {
    var barColor: Color = Color(red: 0.54, green: 0.36, blue: 0.96)
    @State private var offset: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * 0.3
            let travel = geo.size.width + barWidth

            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [.clear, barColor.opacity(0.8), barColor, barColor.opacity(0.8), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: barWidth)
                .shadow(color: barColor.opacity(0.6), radius: 8)
                .offset(x: -barWidth + travel * offset)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        offset = 1.0
                    }
                }
        }
        .clipped()
    }
}

// MARK: - Window controller

final class OverlayWindowController: NSObject, NSWindowDelegate {
    private let viewModel = OverlayViewModel()
    private var window: NSWindow?
    private var followTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        setupWindow()
    }

    func showRecording(isLLM: Bool) {
        DispatchQueue.main.async {
            self.cancelAutoHide()
            self.window?.orderOut(nil)  // hide first so previous state doesn't flash through
            self.viewModel.showRecording(isLLM: isLLM)
            self.show()
        }
    }

    func showProcessing(isLLM: Bool) {
        DispatchQueue.main.async {
            self.cancelAutoHide()
            self.viewModel.showProcessing(isLLM: isLLM)
            self.show()
        }
    }

    func showResult(_ text: String, isLLM: Bool) {
        DispatchQueue.main.async {
            self.viewModel.showResult(text, isLLM: isLLM)
            self.show()
            // Quick flash: 1.5s base + 0.5s per 50 chars, max 4s
            let displayTime = min(1.5 + Double(text.count) / 100.0, 4.0)
            self.autoHide(after: displayTime)
        }
    }

    // Show at the same bottom-middle position as recording/processing overlays.
    func showLoadingModel() {
        DispatchQueue.main.async {
            self.cancelAutoHide()
            self.viewModel.showLoadingModel()
            self.show()
        }
    }

    // Show near cursor briefly when user triggers while model is still loading
    func showLoadingModelBlocked() {
        DispatchQueue.main.async {
            self.cancelAutoHide()
            self.viewModel.showLoadingModel()
            self.show()
            self.autoHide(after: 2.0)
        }
    }

    func showDownloading() {
        DispatchQueue.main.async {
            self.cancelAutoHide()
            self.viewModel.showDownloading()
            self.show()
        }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async {
            self.viewModel.showError(message)
            self.show()
            self.autoHide(after: 5.0)
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.cancelAutoHide()
            self.stopFollow()
            self.window?.orderOut(nil)
            self.viewModel.hide()
        }
    }

    func updateWaveform(_ levels: [Double]) {
        DispatchQueue.main.async {
            self.viewModel.waveform = levels
        }
    }

    // MARK: - Auto-hide with cancellation

    private func autoHide(after seconds: Double) {
        cancelAutoHide()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func cancelAutoHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: - Window setup

    private func setupWindow() {
        let hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        // Allow SwiftUI to resize the hosting view dynamically
        hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.required, for: .vertical)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false // we handle shadows in SwiftUI
        window.ignoresMouseEvents = true
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.delegate = self
        self.window = window
    }

    // Reposition whenever SwiftUI expands/shrinks the window (e.g. waveform → result text)
    // so the top edge stays pinned and content grows downward.
    func windowDidResize(_ notification: Notification) {
        guard !shouldFollowCursor else { return }
        positionBottomMiddle()
    }

    private func show() {
        positionOverlay()
        window?.orderFrontRegardless()
        viewModel.appearTrigger.toggle()
        if shouldFollowCursor {
            startFollow()
        } else {
            stopFollow()
        }
    }

    private var shouldFollowCursor: Bool {
        AppConfig.shared.model.overlayPositionMode == 1
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

    private func positionOverlay() {
        if shouldFollowCursor {
            positionNearMouse()
        } else {
            positionBottomMiddle()
        }
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

    private func positionBottomMiddle() {
        guard let window else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let width = window.frame.width
        let height = window.frame.height
        let padding: CGFloat = 16
        let x = screen.midX - width / 2

        // Anchor the TOP edge at a fixed position so the overlay only grows downward.
        // This prevents the top from jumping when content changes height
        // (waveform → scanner bar → result text).
        let anchorTopY = screen.minY + (screen.height * 0.26)
        var y = anchorTopY - height
        y = max(screen.minY + padding, min(y, screen.maxY - height - padding))

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionAtTopCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let width = window.frame.width
        let height = window.frame.height
        let padding: CGFloat = 8
        let x = screen.frame.midX - width / 2
        let y = screen.visibleFrame.maxY - height - padding
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
