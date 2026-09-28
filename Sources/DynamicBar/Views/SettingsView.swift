import SwiftUI

/// Окно настроек: порядок вкладок, их видимость и поведение панели.
struct SettingsView: View {
    @ObservedObject var tabSettings: TabSettings
    @ObservedObject var appState: AppState
    @ObservedObject var translation: TranslationService

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var draggingID: String?

    /// Высота строки списка; по ней считается, куда переехала вкладка.
    fileprivate static let rowHeight: CGFloat = 46
    fileprivate static let listSpace = "tabsListSpace"

    var body: some View {
        // Окно настроек не должно быть выше экрана. Весь текст — в одной
        // прокрутке: внутренние прокручиваемые области тут только мешали бы,
        // потому что колесо мыши упиралось бы в них.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tabsSection
                Divider()
                panelSection
                Divider()
                translatorSection
            }
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Вкладки

    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Вкладки панели")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(tabSettings.visibleCount) из \(tabSettings.entries.count) видно")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("Стрелки меняют порядок вкладок в шапке панели. Переключатель скрывает вкладку — она исчезнет из шапки, но настройки останутся.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // VStack, а не List и не отдельный ScrollView: строки List рисует
            // AppKit-таблицей, которая не попадает в оффскрин-рендер, а своя
            // прокрутка внутри общей только перехватывала бы колесо мыши.
            VStack(spacing: 2) {
                ForEach(tabSettings.entries) { entry in
                    TabSettingsRow(
                        entry: entry,
                        tabSettings: tabSettings,
                        appState: appState,
                        rowHeight: Self.rowHeight,
                        draggingID: $draggingID
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(height: Self.rowHeight, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(draggingID == entry.id
                                  ? Color.accentColor.opacity(0.22)
                                  : Color.primary.opacity(0.05))
                    )
                    .opacity(draggingID == entry.id ? 0.9 : 1)
                    .zIndex(draggingID == entry.id ? 1 : 0)
                }
            }
            .padding(.vertical, 2)
            .coordinateSpace(name: Self.listSpace)

            HStack {
                Button("Сбросить порядок и видимость") {
                    tabSettings.reset()
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(16)
    }

    // MARK: - Панель

    private var panelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Панель")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Где появляется")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { appState.placement },
                    set: { appState.setPlacement($0) }
                )) {
                    ForEach(PanelPlacement.allCases, id: \.self) { placement in
                        Text(placement.shortTitle).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(appState.placement == .screenTop
                     ? "Панель выезжает от самой кромки и на время перекрывает строку меню."
                     : "Строка меню остаётся видимой, панель начинается сразу под ней.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Анимация появления")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { appState.animationStyle },
                    set: { appState.setAnimationStyle($0) }
                )) {
                    ForEach(AnimationStyle.allCases, id: \.self) { style in
                        Text(style.shortTitle).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(appState.animationStyle == .spring
                     ? "Пружина с лёгким перелётом — как в системных панелях."
                     : "Панель появляется и исчезает мгновенно: меньше нагрузки на слабом железе.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Toggle("Открывать при наведении на верхний центр", isOn: Binding(
                get: { appState.hoverEnabled },
                set: { appState.setHoverEnabled($0) }
            ))
            .font(.system(size: 12))
            // Хотя бы один способ добраться до настроек должен остаться.
            .disabled(!appState.canDisableHover)
            .help(appState.canDisableHover
                  ? "Наведение на верхний центр экрана"
                  : "Сначала включите иконку в строке меню — иначе настройки станут недоступны")

            Toggle("Показывать иконку в строке меню", isOn: Binding(
                get: { appState.showMenuBarIcon },
                set: { appState.setShowMenuBarIcon($0) }
            ))
            .font(.system(size: 12))
            .disabled(!appState.canHideMenuBarIcon)
            .help(appState.canHideMenuBarIcon
                  ? "Если спрятать, настройки останутся доступны через шестерёнку в панели"
                  : "Сначала включите открытие наведением — иначе настройки станут недоступны")

            if !appState.showMenuBarIcon {
                Label("Иконка скрыта. Настройки открываются шестерёнкой в шапке панели.",
                      systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Ширина зоны наведения")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(appState.hotspotWidth)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $appState.hotspotWidth, in: 120...420, step: 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Высота зоны наведения")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(appState.hotspotHeight)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $appState.hotspotHeight, in: 8...48, step: 2)
            }

            Divider()

            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    _ = LaunchAtLogin.setEnabled(newValue)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            ))
            .font(.system(size: 12))

            HStack {
                Button("Открыть журнал") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
                }
                .controlSize(.small)
                Button("Папка данных") {
                    NSWorkspace.shared.open(AppPaths.supportDirectory)
                }
                .controlSize(.small)
                Spacer()
                Text("DynamicBar 1.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }
}

extension SettingsView {
    /// Настройки переводчика: источник и ключ Яндекса.
    var translatorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Переводчик")
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: $translation.provider) {
                ForEach(TranslationProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(explanation)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if translation.provider == .yandex {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API-ключ Яндекс.Облака")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    SecureField("AQVN…", text: $translation.yandexAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Text("Идентификатор каталога (можно оставить пустым — тогда используется старый API v1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("b1g…", text: $translation.yandexFolderID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Toggle("Определять направление по тексту", isOn: $translation.autoDirection)
                .font(.system(size: 12))
        }
        .padding(16)
    }

    private var explanation: String {
        switch translation.provider {
        case .yandex:
            return "Яндекс требует ключ: без него сервис отвечает «Session is invalid». Ключ и каталог берутся в консоли Yandex Cloud, сервисный аккаунт с ролью ai.translate.user."
        case .google:
            return "Работает без ключа и регистрации. Это открытый endpoint Google, а не официальный API — он может перестать отвечать."
        case .builtIn:
            return "Встроенный переводчик macOS: без ключа и без интернета. При первом переводе система предложит скачать языковой пакет."
        }
    }
}

/// Одна строка списка вкладок.
private struct TabSettingsRow: View {
    let entry: TabSettings.Entry
    @ObservedObject var tabSettings: TabSettings
    @ObservedObject var appState: AppState
    let rowHeight: CGFloat
    @Binding var draggingID: String?

    @State private var isHovering = false

    private var tab: PanelTab? { PanelTab(rawValue: entry.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(isHovering ? .secondary : .tertiary)
                .help("Перетащите, чтобы изменить порядок")

            if let tab {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(entry.visible ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(tab.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            IconButton(symbol: "chevron.up", help: "Выше") {
                tabSettings.move(PanelTab(rawValue: entry.id)!, by: -1)
            }
            .disabled(!tabSettings.canMove(PanelTab(rawValue: entry.id)!, by: -1))

            IconButton(symbol: "chevron.down", help: "Ниже") {
                tabSettings.move(PanelTab(rawValue: entry.id)!, by: 1)
            }
            .disabled(!tabSettings.canMove(PanelTab(rawValue: entry.id)!, by: 1))

            Toggle("", isOn: Binding(
                get: { entry.visible },
                set: { newValue in
                    guard let tab else { return }
                    tabSettings.setVisible(newValue, for: tab)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // Последнюю видимую вкладку скрыть нельзя.
            .disabled(entry.visible && tabSettings.visibleCount <= 1)
            .help(entry.visible ? "Скрыть вкладку" : "Показать вкладку")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            hovering ? NSCursor.openHand.set() : NSCursor.arrow.set()
        }
        // Живая перестановка: как только курсор переходит на соседнюю строку,
        // вкладка меняется местами с ней. Отдельного «призрака» нет — строка
        // едет сама, и вид остаётся читаемым.
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(SettingsView.listSpace))
                .onChanged { value in
                    guard let tab else { return }
                    draggingID = entry.id
                    NSCursor.closedHand.set()
                    let raw = Int((value.location.y / rowHeight).rounded(.down))
                    let target = max(0, min(tabSettings.entries.count - 1, raw))
                    guard let from = tabSettings.index(of: tab), target != from else { return }
                    tabSettings.move(tab, to: target)
                }
                .onEnded { _ in
                    draggingID = nil
                    NSCursor.arrow.set()
                }
        )
    }
}
