import SwiftUI

/// Корень выезжающей панели.
struct PanelRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var notes: NoteStore
    @ObservedObject var apps: AppsStore
    @ObservedObject var runningApps: RunningAppsMonitor
    @ObservedObject var translation: TranslationService
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var volume: SystemVolume
    @ObservedObject var tabSettings: TabSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.35)
            footer
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tabSettings.orderedVisibleTabs) { tabs in
            // Вкладку, которую только что скрыли, нельзя оставить выбранной:
            // панель показала бы пустоту.
            if !tabs.contains(appState.selectedTab), let first = tabs.first {
                appState.selectedTab = first
                appState.isEditingText = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Шесть подписанных вкладок в шапку не влезают и переносились на
            // две строки, поэтому при нехватке места остаются только иконки
            // (с подсказкой). Решение считается по ширине панели, а не по
            // фактическому layout: иначе на него влияло бы содержимое вкладки
            // — поле поиска в «Буфере» отбирало ширину у шапки.
            tabRow(compact: useCompactTabs)

            Spacer(minLength: 8)

            // Подпись «закреплено» занимала место и переносилась на две строки,
            // когда вкладок шесть. Состояние и так видно по залитой булавке.
            IconButton(symbol: appState.isPinned ? "pin.fill" : "pin",
                       help: appState.isPinned ? "Панель закреплена — открепить" : "Закрепить панель") {
                appState.setPinned(!appState.isPinned)
            }
            .foregroundStyle(appState.isPinned ? Color.accentColor : Color.secondary)

            // Шестерёнка между пином и крестиком. Нужна не только для удобства:
            // если иконка в строке меню скрыта, это единственный путь к
            // настройкам, кроме зоны наведения.
            IconButton(symbol: "gearshape", help: "Настройки (⌘,)") {
                appState.requestSettings()
            }

            IconButton(symbol: "xmark", help: "Закрыть (Esc)") {
                appState.requestHide()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Хватает ли места подписям. Оценка по числу символов: шрифт системный,
    /// кириллица почти моноширинная при 12 pt.
    private var useCompactTabs: Bool {
        let tabs = tabSettings.orderedVisibleTabs
        guard !tabs.isEmpty else { return false }
        let width = appState.panelWidth
        // 40 pt на вкладку — иконка, отступы и поля; 7.2 pt на символ при 12 pt.
        let labels = tabs.reduce(CGFloat(0)) { $0 + CGFloat($1.title.count) * 7.2 + 40 }
        let spacing = CGFloat(tabs.count - 1) * 4
        // Справа булавка, шестерёнка и крестик плюс поля шапки.
        let reserved: CGFloat = 145
        return labels + spacing > width - reserved
    }

    private func tabRow(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(tabSettings.orderedVisibleTabs) { tab in
                TabButton(
                    tab: tab,
                    isSelected: appState.selectedTab == tab,
                    compact: compact,
                    action: {
                        appState.selectedTab = tab
                        appState.isEditingText = false
                    }
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch appState.selectedTab {
        case .clipboard:
            ClipboardTabView(appState: appState, store: clipboard)
        case .snippets:
            SnippetsTabView(appState: appState, store: snippets, clipboard: clipboard)
        case .notes:
            NotesTabView(appState: appState, store: notes, clipboard: clipboard)
        case .apps:
            AppsTabView(appState: appState, store: apps, monitor: runningApps)
        case .translator:
            TranslatorTabView(appState: appState, service: translation)
        case .music:
            MusicTabView(nowPlaying: nowPlaying, volume: volume)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let toast = appState.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("DynamicBar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .animation(.easeInOut(duration: 0.15), value: appState.toast)
    }

    private var hint: String {
        if appState.isEditingText { return "Esc — отмена · текст сохраняется кнопкой справа" }
        switch appState.selectedTab {
        case .clipboard: return "Клик — скопировать обратно · правый клик — закрепить или удалить"
        case .snippets: return "Клик — скопировать · + — добавить · правый клик — изменить"
        case .notes: return "Текст сохраняется сам · + — новая заметка"
        case .apps: return "Клик — открыть · правый клик — закрепить или убрать"
        case .translator: return "Перевод идёт по мере набора текста"
        case .music: return "Управление идёт через системный плеер"
        }
    }
}

// MARK: - Small components

struct TabButton: View {
    let tab: PanelTab
    let isSelected: Bool
    var compact: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .semibold))
                if !compact {
                    Text(tab.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Color.primary.opacity(0.08) : Color.clear))
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(compact ? tab.title : "")
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
