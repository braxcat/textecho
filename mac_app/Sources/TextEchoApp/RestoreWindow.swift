import AppKit
import SwiftUI

final class RestoreWindowController {
    private var window: NSWindow?
    private let onRestore: () -> Void

    init(onRestore: @escaping () -> Void) {
        self.onRestore = onRestore
    }

    func show() {
        if window == nil {
            let view = RestoreView(onRestore: onRestore)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "TextEcho"
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

struct RestoreView: View {
    let onRestore: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Menu bar icon is hidden")
                .font(.system(size: 14, weight: .semibold))

            Text("Click below to show the TextEcho menu bar icon again.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Show Menu Bar Icon") {
                onRestore()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}
