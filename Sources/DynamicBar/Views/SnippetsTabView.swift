import SwiftUI

struct SnippetsTabView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: SnippetStore
    @ObservedObject var clipboard: ClipboardStore

    @State private var draftTitle: String = ""
    @State private var draftBody: String = ""
    @State private var editingID: UUID?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)

            if appState.isEditingText {
                editor
            } else if store.snippets.isEmpty {
                EmptyStateView(symbol: "text.badge.plus", title: "Нет сниппетов", subtitle: "Нажмите +, чтобы добавить первый")
            } else {
                list
            }
        }
        // The panel can leave edit mode from the outside (Esc, auto-hide).
        .onChange(of: appState.isEditingText) { editing in
            if !editing { clearDraft() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Сниппеты")
                .font(.system(size: 12, weight: .semibold))
            Text("\(store.snippets.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            if !appState.isEditingText {
                IconButton(symbol: "plus", help: "Добавить сниппет") { beginAdd() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.snippets) { snippet in
                    SnippetRow(snippet: snippet, appState: appState, store: store, clipboard: clipboard) {
                        beginEdit(snippet)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Название", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($titleFocused)

            TextEditor(text: $draftBody)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 120)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Text("\(draftBody.count) символов")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Отмена") { cancelEdit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(editingID == nil ? "Добавить" : "Сохранить") { commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func beginAdd() {
        draftTitle = ""
        draftBody = ""
        editingID = nil
        appState.isEditingText = true
        // Text entry needs real keyboard focus → briefly activate the accessory app.
        appState.requestActivation()
        focusTitleSoon()
    }

    private func beginEdit(_ snippet: Snippet) {
        draftTitle = snippet.title
        draftBody = snippet.body
        editingID = snippet.id
        appState.isEditingText = true
        appState.requestActivation()
        focusTitleSoon()
    }

    private func focusTitleSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            titleFocused = true
        }
    }

    private func commit() {
        if let editingID, let existing = store.snippets.first(where: { $0.id == editingID }) {
            store.update(existing, title: draftTitle, body: draftBody)
        } else {
            store.add(title: draftTitle, body: draftBody)
        }
        cancelEdit()
        appState.showToast("Сохранено")
    }

    private func cancelEdit() {
        appState.isEditingText = false
        clearDraft()
    }

    private func clearDraft() {
        editingID = nil
        draftTitle = ""
        draftBody = ""
        titleFocused = false
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    @ObservedObject var appState: AppState
    @ObservedObject var store: SnippetStore
    @ObservedObject var clipboard: ClipboardStore
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(snippet.body)
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if isHovering {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .onTapGesture { onEdit() }
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .onTapGesture { store.remove(snippet) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Копировать") { copy() }
            Button("Изменить") { onEdit() }
            Divider()
            Button("Удалить") { store.remove(snippet) }
        }
    }

    private func copy() {
        clipboard.copyToPasteboard(snippet.body)
        appState.showToast("Скопировано")
    }
}
