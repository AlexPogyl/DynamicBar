import Foundation
import Combine

/// Свободная заметка. В отличие от сниппета это длинный текст, который
/// редактируется на месте и сохраняется сам.
struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, updatedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Первая непустая строка — заголовок в списке.
    var title: String {
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return "Пустая заметка" }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    var preview: String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return "" }
        let rest = lines.dropFirst().joined(separator: " ")
        return rest.count > 80 ? String(rest.prefix(80)) + "…" : rest
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var updatedLabel: String {
        let seconds = Date().timeIntervalSince(updatedAt)
        if seconds < 60 { return "только что" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) ч назад" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: updatedAt)
    }
}

/// Заметки хранятся одним JSON-файлом в Application Support.
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?

    private let storeURL = AppPaths.file("notes.json")
    private let saveQueue = DispatchQueue(label: "com.dynamicbar.notes.save")

    var selected: Note? {
        guard let selectedID else { return nil }
        return notes.first { $0.id == selectedID }
    }

    init() {
        load()
        if selectedID == nil { selectedID = notes.first?.id }
    }

    // MARK: - Изменения

    @discardableResult
    func add() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        selectedID = note.id
        persist()
        return note
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
        // Заметка с правкой поднимается наверх, но выделение не меняется:
        // иначе редактор «прыгал» бы под курсором.
        let moved = notes.remove(at: index)
        notes.insert(moved, at: 0)
        persist()
    }

    func remove(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if selectedID == note.id { selectedID = notes.first?.id }
        persist()
    }

    /// Убирает пустые заметки — они появляются, если пользователь нажал «+»
    /// и передумал.
    func discardEmptyNotes() {
        let before = notes.count
        notes.removeAll { $0.isEmpty && $0.id != selectedID }
        if notes.count != before { persist() }
    }

    func select(_ note: Note) {
        selectedID = note.id
    }

    // MARK: - Хранение

    private func persist() {
        let snapshot = notes
        let url = storeURL
        saveQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.error("notes persist failed: \(error)")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            notes = try JSONDecoder().decode([Note].self, from: data)
            Log.info("notes loaded: \(notes.count)")
        } catch {
            Log.error("notes decode failed: \(error)")
        }
    }
}
