import AppKit
import SwiftUI

final class HistoryWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = HistoryView()
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 400, height: 300)
            window.center()
            window.title = "Transcription History"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = TranscriptionHistory.shared.getEntries()
    @State private var searchText = ""
    @State private var showClearConfirm = false

    var filtered: [HistoryEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search transcriptions…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Clear History") {
                    showClearConfirm = true
                }
                .foregroundColor(.red)
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: entries.isEmpty ? "clock" : "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(entries.isEmpty ? "No transcriptions yet." : "No results for \"\(searchText)\".")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered) { entry in
                        HistoryEntryRow(entry: entry)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Text("\(entries.count) transcription\(entries.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 400, minHeight: 300)
        .onReceive(NotificationCenter.default.publisher(for: TranscriptionHistory.changedNotification)) { _ in
            entries = TranscriptionHistory.shared.getEntries()
        }
        .confirmationDialog("Clear all transcription history?", isPresented: $showClearConfirm) {
            Button("Clear History", role: .destructive) {
                TranscriptionHistory.shared.clear()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct HistoryEntryRow: View {
    let entry: HistoryEntry
    @State private var copied = false
    @State private var expanded = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                if entry.isLLM {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                        .foregroundColor(.purple)
                }
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button(copied ? "Copied!" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(entry.text)
                .font(.system(size: 12))
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if entry.text.count > 200 || entry.text.filter({ $0 == "\n" }).count > 3 {
                Button(expanded ? "Show less" : "Show more…") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if entry.text.count > 200 { expanded.toggle() } }
    }
}
