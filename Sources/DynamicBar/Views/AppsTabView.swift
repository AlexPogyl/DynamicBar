import AppKit
import SwiftUI

/// Вкладка «Приложения»: иконки запущенных приложений и закреплённых
/// приложений, файлов и ссылок. Без подписей — только иконки.
struct AppsTabView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: AppsStore
    @ObservedObject var monitor: RunningAppsMonitor

    @State private var isAddingLink = false
    @State private var linkDraft = ""
    @FocusState private var linkFocused: Bool

    private let iconSide: CGFloat = 36
    private let cellSide: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)

            if isAddingLink {
                linkField
                Divider().opacity(0.25)
            }

            if store.pinned.isEmpty && monitor.applications.isEmpty {
                EmptyStateView(
                    symbol: "square.grid.2x2",
                    title: "Нет запущенных приложений",
                    subtitle: "Закрепите нужные через + или правый клик по иконке"
                )
            } else {
                grid
            }
        }
    }

    // MARK: - Шапка

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Приложения")
                .font(.system(size: 12, weight: .semibold))
            Text("\(store.pinned.count) закреплено · \(monitor.entries.count) запущено")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Обновить список") {
                monitor.refresh()
            }
            Menu {
                Button("Добавить ссылку…") { beginAddingLink() }
                Button("Добавить файл или приложение…") { addFile() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .foregroundStyle(.secondary)
            .help("Добавить файл или ссылку")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var linkField: some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("example.com", text: $linkDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($linkFocused)
                .onChange(of: linkFocused) { focused in
                    if focused { appState.requestActivation() }
                }
                .onSubmit { commitLink() }
            Button("Добавить") { commitLink() }
                .controlSize(.small)
                .disabled(linkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            IconButton(symbol: "xmark", help: "Отмена") { cancelLink() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Сетка

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cellSide, maximum: cellSide), spacing: 6)],
                spacing: 6
            ) {
                ForEach(store.pinned) { item in
                    PinnedCell(
                        item: item,
                        icon: store.icon(for: item),
                        isRunning: store.runningApplication(for: item) != nil,
                        side: iconSide,
                        cell: cellSide,
                        open: { open(item) },
                        unpin: { store.remove(item) },
                        moveUp: { store.move(item, by: -1) },
                        moveDown: { store.move(item, by: 1) }
                    )
                }

                ForEach(monitor.entries) { entry in
                    RunningCell(
                        entry: entry,
                        side: iconSide,
                        cell: cellSide,
                        open: { openRunning(entry) },
                        pin: { if let app = entry.application { store.pin(app) } }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Действия

    private func beginAddingLink() {
        isAddingLink = true
        linkDraft = ""
        appState.isEditingText = true
        appState.requestActivation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { linkFocused = true }
    }

    private func cancelLink() {
        isAddingLink = false
        linkDraft = ""
        linkFocused = false
        appState.isEditingText = false
    }

    private func commitLink() {
        guard store.addLink(linkDraft) else { return }
        cancelLink()
        appState.showToast("Ссылка добавлена")
    }

    private func addFile() {
        appState.requestActivation()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить"
        panel.message = "Выберите файл или приложение"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if store.addFile(url) {
            appState.showToast("Добавлено: \(url.lastPathComponent)")
        }
    }

    private func open(_ item: PinnedItem) {
        Log.info("apps: клик по закреплённому «\(item.title)» (\(item.kind.rawValue))")
        switch item.kind {
        case .link:
            guard let raw = item.url, let url = URL(string: raw) else { return }
            NSWorkspace.shared.open(url)
            appState.requestHide()
        case .file:
            guard let path = item.path else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            appState.requestHide()
        case .application:
            // Закрытое закреплённое приложение запускаем — так решил
            // пользователь, иначе иконка была бы мёртвой.
            if let running = store.runningApplication(for: item) {
                activate(running)
            } else {
                appState.requestHide()
                AppActivator.launch(bundleID: item.bundleID ?? "", path: item.path, reason: "pinned")
            }
        }
    }

    /// Панель скрывается сразу: приложение уже поднимается, и ждать, пока
    /// уедет панель, незачем — иначе клик ощущается вялым.
    /// Приложение из сетки: запущенное поднимаем, демонстрационное — просто
    /// показываем тостом (в демо-режиме кликать нечего).
    private func openRunning(_ entry: AppEntry) {
        // Пишем до ветвления: иначе по журналу нельзя понять, дошёл ли клик
        // до обработчика вообще.
        Log.info("apps: клик по «\(entry.name)», запущено=\(entry.application != nil)")
        guard let application = entry.application else {
            appState.showToast("Демонстрационный режим")
            return
        }
        activate(application)
    }

    private func activate(_ application: NSRunningApplication) {
        appState.requestHide()
        AppActivator.bringToFront(application, reason: "apps-tab")
    }
}

// MARK: - Ячейки

private struct CellChrome<Content: View>: View {
    let side: CGFloat
    let cell: CGFloat
    let dimmed: Bool
    let content: Content
    @State private var isHovering = false

    init(side: CGFloat, cell: CGFloat, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.side = side
        self.cell = cell
        self.dimmed = dimmed
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: side, height: side)
            .opacity(dimmed ? 0.35 : 1)
            .padding(6)
            .frame(width: cell, height: cell)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
    }
}

private struct RunningCell: View {
    let entry: AppEntry
    let side: CGFloat
    let cell: CGFloat
    let open: () -> Void
    let pin: () -> Void

    var body: some View {
        Button(action: open) {
            CellChrome(side: side, cell: cell) {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                }
            }
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .contextMenu {
            Button("Открыть") { open() }
            if entry.application != nil { Button("Закрепить") { pin() } }
            if let url = entry.application?.bundleURL {
                Divider()
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}

private struct PinnedCell: View {
    let item: PinnedItem
    let icon: NSImage?
    let isRunning: Bool
    let side: CGFloat
    let cell: CGFloat
    let open: () -> Void
    let unpin: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottom) {
                CellChrome(side: side, cell: cell) {
                    if let icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else if item.kind == .link {
                        Image(systemName: "link")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.tint)
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                // Точка под иконкой: закрытое закреплённое приложение видно
                // сразу, без подписи.
                Circle()
                    .fill(isRunning ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35))
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 3)
            }
        }
        .buttonStyle(.plain)
        .help(item.title)
        .contextMenu {
            Button("Открыть") { open() }
            if let url = item.url, let link = URL(string: url) {
                Button("Скопировать ссылку") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Выше") { moveUp() }
            Button("Ниже") { moveDown() }
            Divider()
            Button("Убрать") { unpin() }
        }
    }
}
