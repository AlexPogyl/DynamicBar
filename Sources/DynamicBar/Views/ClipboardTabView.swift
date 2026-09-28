import SwiftUI

struct ClipboardTabView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool
    /// The text field only exists after an explicit click. If it were always
    /// present, SwiftUI would focus it as soon as the panel becomes key, which
    /// would make a plain hover steal keyboard focus from the frontmost app.
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.25)

            if store.filtered.isEmpty {
                EmptyStateView(
                    symbol: "doc.on.clipboard",
                    title: store.items.isEmpty ? "История пуста" : "Ничего не найдено",
                    subtitle: store.items.isEmpty ? "Скопируйте что-нибудь — запись появится здесь.\nПароли и «concealed» данные пропускаются." : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.filtered) { item in
                            ClipboardRow(item: item, store: store, appState: appState)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            if isSearching || !store.searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Поиск в истории", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onChange(of: searchFocused) { focused in
                        // An .accessory app must be active for keystrokes to land.
                        if focused { appState.requestActivation() }
                    }
                    .onExitCommand { endSearch() }
            } else {
                Button(action: beginSearch) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Поиск в истории")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Нажмите, чтобы искать в истории")
            }

            if !store.searchText.isEmpty || isSearching {
                IconButton(symbol: "xmark.circle.fill", help: "Сбросить поиск") { endSearch() }
            }
            Text("\(store.items.count)/\(ClipboardStore.maxItems)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            IconButton(symbol: "trash", help: "Очистить историю") {
                store.clearAll()
                appState.showToast("История очищена")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func beginSearch() {
        isSearching = true
        // Both calls happen inside the click, so the focus guard allows them.
        appState.requestActivation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            searchFocused = true
        }
    }

    private func endSearch() {
        store.searchText = ""
        searchFocused = false
        isSearching = false
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    @ObservedObject var store: ClipboardStore
    @ObservedObject var appState: AppState
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .top, spacing: 8) {
                if item.isImage {
                    thumbnail
                } else {
                    Image(systemName: item.isPinned ? "pin.fill" : (item.isURL ? "link" : "text.alignleft"))
                        .font(.system(size: 10))
                        .foregroundStyle(item.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 14)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if item.isImage {
                        Text(item.imageDescription)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let size = item.imageSizeDescription {
                            Text(size)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(item.firstLine)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if let secondary = item.secondaryPreview {
                            Text(secondary)
                                .font(.system(size: 10.5))
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.relativeDate)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    if isHovering {
                        HStack(spacing: 6) {
                            Image(systemName: "pin")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .onTapGesture { store.togglePin(item) }
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .onTapGesture { store.remove(item) }
                        }
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
            Button(item.isPinned ? "Снять закрепление" : "Закрепить") { store.togglePin(item) }
            Divider()
            Button("Удалить") { store.remove(item) }
        }
    }

    private var thumbnail: some View {
        Group {
            if let image = store.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 44, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.top, 1)
    }

    private func copy() {
        store.copyToPasteboard(item)
        appState.showToast("Скопировано")
    }
}
