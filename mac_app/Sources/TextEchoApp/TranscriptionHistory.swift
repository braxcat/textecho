import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id: UUID
    let text: String
    let date: Date
    let isLLM: Bool

    init(text: String, date: Date = Date(), isLLM: Bool = false) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.isLLM = isLLM
    }
}

final class TranscriptionHistory {
    static let shared = TranscriptionHistory()
    static let changedNotification = Notification.Name("TextEchoHistoryChanged")

    private let fileURL: URL
    private var entries: [HistoryEntry] = []
    private let queue = DispatchQueue(label: "textecho.history")

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        fileURL = home.appendingPathComponent(".textecho_history.json")
        load()
    }

    func add(text: String, isLLM: Bool = false) {
        guard AppConfig.shared.model.historyEnabled else { return }
        guard !text.isEmpty else { return }
        queue.async {
            let entry = HistoryEntry(text: text, isLLM: isLLM)
            self.entries.insert(entry, at: 0)
            let max = AppConfig.shared.model.maxHistoryCount
            if self.entries.count > max {
                self.entries = Array(self.entries.prefix(max))
            }
            self.save()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
    }

    func getEntries() -> [HistoryEntry] {
        queue.sync { entries }
    }

    func clear() {
        queue.async {
            self.entries = []
            self.save()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }
}
