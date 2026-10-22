import AppKit
import Combine
import Foundation

/// Данные вкладки «Агент»: токены, баланс, активность.
///
/// Источник не зашит в приложение. Есть три пути, и все три дают один и тот же
/// JSON: встроенный сборщик DSH, файл, который пишет кто-то другой, и любая
/// команда, печатающая снимок в stdout. Поэтому вкладка одинаково работает и
/// у автора проекта, и у того, кто клонировал репозиторий и подключил своего
/// агента.
final class AgentStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    // MARK: - Наблюдаемое состояние

    @Published private(set) var snapshot: AgentSnapshot?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastTookMilliseconds: Int?
    @Published private(set) var sourceLabel: String = ""
    @Published private(set) var isRefreshing = false

    // MARK: - Настройки

    @Published var source: AgentSourceKind {
        didSet {
            guard source != oldValue else { return }
            defaults.set(source.rawValue, forKey: Key.source)
            scheduleImmediateRefresh()
        }
    }

    @Published var filePath: String {
        didSet {
            guard filePath != oldValue else { return }
            defaults.set(filePath, forKey: Key.filePath)
            scheduleImmediateRefresh()
        }
    }

    @Published var command: String {
        didSet {
            guard command != oldValue else { return }
            defaults.set(command, forKey: Key.command)
            scheduleImmediateRefresh()
        }
    }

    @Published var currencies: Set<AgentCurrency> {
        didSet {
            guard currencies != oldValue else { return }
            defaults.set(currencies.map(\.rawValue).sorted().joined(separator: ","), forKey: Key.currencies)
        }
    }

    @Published var tokenMode: AgentTokenMode {
        didSet {
            guard tokenMode != oldValue else { return }
            defaults.set(tokenMode.rawValue, forKey: Key.tokenMode)
        }
    }

    // MARK: - Служебное

    private enum Key {
        static let source = "agentSource"
        static let filePath = "agentFilePath"
        static let command = "agentCommand"
        static let currencies = "agentCurrencies"
        static let tokenMode = "agentTokenMode"
        static let nodePath = "agentNodePath"
    }

    /// Заводские значения должны совпадать с тем, что пишет сборщик.
    static var defaultFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/dynamicbar/dsh.json").path
    }

    static var defaultCommand: String {
        "node \(defaultCollectorPath) --json"
    }

    static var defaultCollectorPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DynamicBar/dsh-collector.mjs").path
    }

    static var dshHome: String {
        if let value = ProcessInfo.processInfo.environment["DSH_HOME"], !value.isEmpty {
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path
    }

    private let defaults: UserDefaults
    private weak var appState: AppState?
    private var selectedTabSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var panelVisible = false
    private var refreshQueued = false
    private let processLock = NSLock()
    private var activeProcess: Process?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.source = AgentSourceKind(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .auto
        self.filePath = defaults.string(forKey: Key.filePath) ?? Self.defaultFilePath
        self.command = defaults.string(forKey: Key.command) ?? ""
        self.tokenMode = AgentTokenMode(rawValue: defaults.string(forKey: Key.tokenMode) ?? "") ?? .single
        let stored = (defaults.string(forKey: Key.currencies) ?? "")
            .split(separator: ",")
            .compactMap { AgentCurrency(rawValue: String($0)) }
        self.currencies = stored.isEmpty ? [.cny, .rub] : Set(stored)
    }

    // MARK: - Жизненный цикл

    /// Подписывается на панель: пока вкладка не видна, сборщик не запускается.
    /// Иначе приложение каждые четыре секунды дёргало бы Node просто так.
    func attach(appState: AppState) {
        self.appState = appState

        selectedTabSubscription = appState.$selectedTab
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateActivity() }

        observers.append(NotificationCenter.default.addObserver(
            forName: .dynamicBarPanelDidShow, object: nil, queue: .main
        ) { [weak self] _ in
            self?.panelVisible = true
            self?.updateActivity()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .dynamicBarPanelDidHide, object: nil, queue: .main
        ) { [weak self] _ in
            self?.panelVisible = false
            self?.updateActivity()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        timer?.invalidate()
    }

    private var isOnScreen: Bool {
        panelVisible && appState?.selectedTab == .agent
    }

    private func updateActivity() {
        if isOnScreen {
            if timer == nil {
                let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                    self?.refresh()
                }
                timer.tolerance = 0.6
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            refresh()
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
            cancelActiveProcess()
        }
    }

    private func scheduleImmediateRefresh() {
        guard isOnScreen else { return }
        refresh()
    }

    // MARK: - Обновление

    func refresh() {
        guard !isRefreshing else { return }

        let plan: Plan
        do {
            plan = try makePlan()
        } catch {
            apply(error: error.localizedDescription)
            return
        }

        isRefreshing = true
        if snapshot == nil { phase = .loading }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.execute(plan, processLock: self.processLock) { [weak self] process in
                self?.store(process: process)
            }
            DispatchQueue.main.async {
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.phase = .ready
                    self.lastRefresh = Date()
                    self.lastTookMilliseconds = snapshot.collector?.tookMs
                    self.sourceLabel = plan.label
                case .failure(let error):
                    self.apply(error: error.message)
                }
            }
        }
    }

    /// Синхронная загрузка: нужна диагностике и проверкам, где ждать таймер
    /// неудобно. На экране не используется — там `refresh()`.
    func loadSynchronously() throws -> AgentSnapshot {
        let plan = try makePlan()
        switch Self.execute(plan, processLock: processLock, register: { _ in }) {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }

    private func apply(error: String) {
        if snapshot == nil {
            phase = .failed(error)
        } else {
            // Старые данные лучше пустого экрана: показываем их и сообщаем,
            // что последнее обновление не удалось.
            phase = .failed(error)
        }
    }

    private func store(process: Process?) {
        processLock.lock()
        activeProcess = process
        processLock.unlock()
    }

    private func cancelActiveProcess() {
        processLock.lock()
        let process = activeProcess
        activeProcess = nil
        processLock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - План

    enum Plan {
        case collector(node: String, script: String, dshHome: String)
        case file(URL)
        case command(String)

        var label: String {
            switch self {
            case .collector: return "сборщик DSH"
            case .file: return "файл"
            case .command: return "команда"
            }
        }
    }

    enum AgentError: LocalizedError {
        case noSource
        case nodeMissing
        case collectorMissing
        case process(String)
        case decode(String)
        case empty

        var message: String {
            switch self {
            case .noSource:
                return "Нет источника данных: не найден ни сборщик DSH, ни файл. Укажите файл или команду в настройках."
            case .nodeMissing:
                return "Не найден Node. Установите Node или выберите «Файл»/«Команда» в настройках."
            case .collectorMissing:
                return "В сборке нет файла сборщика (dsh-collector.mjs)."
            case .process(let text):
                return text
            case .decode(let text):
                return "Не удалось разобрать JSON: \(text)"
            case .empty:
                return "Источник вернул пустой ответ."
            }
        }

        var localizedDescription: String { message }
    }

    private func makePlan() throws -> Plan {
        switch source {
        case .file:
            return .file(URL(fileURLWithPath: expanded(filePath)))
        case .command:
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AgentError.noSource }
            return .command(trimmed)
        case .auto:
            let home = Self.dshHome
            let hasDSH = FileManager.default.fileExists(atPath: home)
            if hasDSH, let node = Self.nodePath(), let script = Self.collectorPath() {
                return .collector(node: node, script: script, dshHome: home)
            }
            let path = expanded(filePath)
            if FileManager.default.fileExists(atPath: path) {
                return .file(URL(fileURLWithPath: path))
            }
            if hasDSH && Self.nodePath() == nil { throw AgentError.nodeMissing }
            if hasDSH && Self.collectorPath() == nil { throw AgentError.collectorMissing }
            throw AgentError.noSource
        }
    }

    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Пути

    /// Node в GUI-приложении не виден через PATH: у него урезанное окружение.
    /// Поэтому ищем по известным местам установки, а переменную окружения
    /// уважаем как явное указание.
    static func nodePath() -> String? {
        if let override = UserDefaults.standard.string(forKey: Key.nodePath),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: (override as NSString).expandingTildeInPath) {
            return (override as NSString).expandingTildeInPath
        }
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/opt/local/bin/node",
            "/usr/bin/node",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return nil
    }

    /// Сборщик лежит внутри .app. Копия в Application Support нужна для
    /// сборок, запущенных не из бандла (например, `swift run`).
    static func collectorPath() -> String? {
        let candidates = [
            Bundle.main.url(forResource: "dsh-collector", withExtension: "mjs")?.path,
            defaultCollectorPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Данные для оффскрин-рендера и скриншотов README: сеть и процессы
    /// не трогаются, цифры всегда одни и те же.
    func applyPreviewSample() {
        let now = Date().timeIntervalSince1970 * 1000
        let snapshot = AgentSnapshot(
            schemaVersion: 1,
            updatedAt: now,
            collector: .init(version: "1.0.0", tookMs: 142, warnings: []),
            agent: .init(
                dshRunning: true,
                status: "working",
                sessions: [
                    .init(
                        id: "session-preview-1",
                        project: "DynamicBar",
                        title: "Вкладка «Агент»",
                        task: "Сделать вкладку с токенами, балансом и активностью агента",
                        tool: "bash",
                        startedAt: now - 26 * 60_000,
                        lastEventAt: now - 3_000,
                        status: "working"
                    ),
                    .init(
                        id: "session-preview-2",
                        project: "витжеты",
                        title: "Виджет статуса агента",
                        task: "Сделай виджет для этого мака",
                        tool: "present",
                        startedAt: now - 120 * 60_000,
                        lastEventAt: now - 9 * 60_000,
                        status: "idle"
                    ),
                ]
            ),
            today: .init(
                date: "2026-10-22",
                input: 146_661,
                output: 71_770,
                cacheRead: 5_022_592,
                cacheWrite: 0,
                billable: 218_431,
                total: 5_241_023,
                sessions: 2
            ),
            balance: .init(
                available: true,
                at: now,
                wallets: [
                    .init(currency: "CNY", total: 26.67, granted: 0, toppedUp: 26.67),
                    .init(currency: "USD", total: 0, granted: 0, toppedUp: 0),
                ],
                rub: 323.93,
                walletRub: ["CNY": 323.93, "USD": 0],
                rates: ["USD": 81.126, "EUR": 91.136, "CNY": 12.146],
                ratesAt: now,
                ratesDate: "22.10.2026",
                ratesSource: "ЦБ РФ",
                converted: ["CNY": 26.67, "USD": 3.99, "EUR": 3.55]
            )
        )
        self.snapshot = snapshot
        self.phase = .ready
        self.lastRefresh = Date()
        self.lastTookMilliseconds = 142
        self.sourceLabel = "сборщик DSH"
    }

    // MARK: - Выполнение

    private static func execute(
        _ plan: Plan,
        processLock: NSLock,
        register: @escaping (Process?) -> Void
    ) -> Result<AgentSnapshot, AgentError> {
        let data: Data
        switch plan {
        case .collector(let node, let script, let dshHome):
            do {
                data = try run(
                    executable: node,
                    arguments: [script, "--json", "--dsh-home", dshHome],
                    timeout: 20,
                    processLock: processLock,
                    register: register
                )
            } catch let error as AgentError {
                return .failure(error)
            } catch {
                return .failure(.process(error.localizedDescription))
            }
        case .file(let url):
            do {
                data = try Data(contentsOf: url)
            } catch {
                return .failure(.process("Не удалось прочитать \(url.path): \(error.localizedDescription)"))
            }
        case .command(let command):
            do {
                data = try run(
                    executable: "/bin/sh",
                    arguments: ["-c", command],
                    timeout: 20,
                    processLock: processLock,
                    register: register
                )
            } catch let error as AgentError {
                return .failure(error)
            } catch {
                return .failure(.process(error.localizedDescription))
            }
        }

        guard !data.isEmpty else { return .failure(.empty) }

        do {
            let snapshot = try JSONDecoder().decode(AgentSnapshot.self, from: data)
            if let version = snapshot.schemaVersion, version > AgentSnapshot.supportedSchemaVersion {
                return .failure(.decode("снимок версии \(version), а приложение понимает \(AgentSnapshot.supportedSchemaVersion). Обновите DynamicBar."))
            }
            return .success(snapshot)
        } catch {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            return .failure(.decode("\(error.localizedDescription). Ответ: \(snippet)"))
        }
    }

    private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        processLock: NSLock,
        register: @escaping (Process?) -> Void
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw AgentError.process("Не удалось запустить \(executable): \(error.localizedDescription)")
        }
        register(process)

        // Читаем stdout параллельно: иначе процесс повиснет, если вывод
        // не поместится в буфер канала.
        var stdoutData = Data()
        let stdoutQueue = DispatchQueue(label: "com.dynamicbar.agent.stdout")
        let done = DispatchSemaphore(value: 0)
        stdoutQueue.async {
            stdoutData = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(30_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(120_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        register(nil)
        _ = done.wait(timeout: .now() + 3)

        if process.terminationStatus != 0 {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AgentError.process(message.isEmpty
                ? "Команда завершилась с кодом \(process.terminationStatus)"
                : message)
        }

        return stdoutData
    }
}
