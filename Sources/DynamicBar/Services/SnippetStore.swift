import Foundation
import Combine

/// A reusable text snippet.
struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var date: Date

    init(id: UUID = UUID(), title: String, body: String, date: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.date = date
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }
}

/// Snippets are stored as a plain JSON file in Application Support.
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let storeURL = AppPaths.file("snippets.json")
    private let saveQueue = DispatchQueue(label: "com.dynamicbar.snippets.save")

    init() {
        load()
        if snippets.isEmpty {
            seed()
        }
    }

    func add(title: String, body: String) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        snippets.insert(Snippet(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: trimmedBody), at: 0)
        persist()
    }

    func update(_ snippet: Snippet, title: String, body: String) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        snippets[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippets[index].body = trimmedBody
        snippets[index].date = Date()
        persist()
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = snippets
        let url = storeURL
        saveQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.error("snippets persist failed: \(error)")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
            Log.info("snippets loaded: \(snippets.count)")
        } catch {
            Log.error("snippets decode failed: \(error)")
        }
    }

    private func seed() {
        snippets = [
            Snippet(title: "Email signature", body: "Best regards,\nAlex"),
            Snippet(title: "Meeting link", body: "https://meet.google.com/"),
        ]
        persist()
    }
}
