import SwiftUI

/// Вкладка «Заметки»: список слева, редактор справа, автосохранение.
struct NotesTabView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: NoteStore
    @ObservedObject var clipboard: ClipboardStore

    @State private var draft: String = ""
    @State private var saveWork: DispatchWorkItem?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)

            if store.notes.isEmpty {
                EmptyStateView(
                    symbol: "note.text",
                    title: "Заметок пока нет",
                    subtitle: "Нажмите + — текст сохраняется сам, по мере набора"
                )
            } else {
                HStack(spacing: 0) {
                    sidebar
                    Divider().opacity(0.25)
                    editor
                }
            }
        }
        .onChange(of: store.selectedID) { _ in
            saveWork?.cancel()
            draft = store.selected?.text ?? ""
        }
        .onAppear {
            draft = store.selected?.text ?? ""
        }
    }

    // MARK: - Шапка

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Заметки")
                .font(.system(size: 12, weight: .semibold))
            Text("\(store.notes.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            if let note = store.selected {
                IconButton(symbol: "doc.on.doc", help: "Скопировать текст заметки") {
                    clipboard.copyToPasteboard(note.text)
                    appState.showToast("Скопировано")
                }
                IconButton(symbol: "trash", help: "Удалить заметку") {
                    store.remove(note)
                    appState.showToast("Заметка удалена")
                }
            }
            IconButton(symbol: "plus", help: "Новая заметка") { beginNewNote() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Список

    private var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.notes) { note in
                    NoteRow(
                        note: note,
                        isSelected: note.id == store.selectedID,
                        onSelect: {
                            saveNow()
                            store.select(note)
                        },
                        onDelete: {
                            if note.id == store.selectedID { saveWork?.cancel() }
                            store.remove(note)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 208)
    }

    // MARK: - Редактор

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.selected != nil {
                TextEditor(text: $draft)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .focused($editorFocused)
                    .onChange(of: editorFocused) { focused in
                        // Набор текста требует активности приложения: панель
                        // намеренно её не забирает.
                        if focused { appState.requestActivation() }
                    }
                    .onChange(of: draft) { newValue in
                        scheduleSave(newValue)
                    }

                Divider().opacity(0.25)
                HStack(spacing: 8) {
                    Text("\(draft.count) символов")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(saveStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            } else {
                EmptyStateView(symbol: "text.cursor", title: "Выберите заметку")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var saveStatus: String {
        if saveWork != nil { return "сохраняю…" }
        return "сохранено"
    }

    // MARK: - Действия

    private func beginNewNote() {
        saveNow()
        _ = store.add()
        draft = ""
        appState.isEditingText = true
        appState.requestActivation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            editorFocused = true
        }
    }

    /// Сохранение с задержкой: печатать быстро, а на диск писать редко.
    private func scheduleSave(_ text: String) {
        guard let id = store.selectedID else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem {
            store.update(id, text: text)
            saveWork = nil
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        if let id = store.selectedID, store.selected?.text != draft {
            store.update(id, text: draft)
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(note.isEmpty ? .tertiary : .primary)
                    if !note.preview.isEmpty {
                        Text(note.preview)
                            .font(.system(size: 10))
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                    Text(note.updatedLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 2)

                if isHovering {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .onTapGesture(perform: onDelete)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.20)
                          : (isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
