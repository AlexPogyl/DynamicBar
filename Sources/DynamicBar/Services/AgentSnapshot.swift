import Foundation

/// Снимок состояния агента — всё, что показывает вкладка «Агент».
///
/// Формат совпадает с тем, что пишет `scripts/agent/dsh-collector.mjs`, и
/// описан в README. Любой другой агент может отдать такой же JSON — панель
/// не знает, откуда он взялся.
struct AgentSnapshot: Codable, Equatable {
    struct Collector: Codable, Equatable {
        var version: String?
        var tookMs: Int?
        var warnings: [String]?
    }

    struct Session: Codable, Equatable, Identifiable {
        var id: String
        var project: String?
        var title: String?
        var task: String?
        var tool: String?
        var startedAt: Double?
        var lastEventAt: Double?
        var status: String?
    }

    struct Activity: Codable, Equatable {
        var dshRunning: Bool?
        var status: String?
        var sessions: [Session]?
    }

    struct Today: Codable, Equatable {
        var date: String?
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var billable: Int?
        var total: Int?
        var sessions: Int?
    }

    struct Wallet: Codable, Equatable, Identifiable {
        var currency: String
        var total: Double?
        var granted: Double?
        var toppedUp: Double?

        var id: String { currency }
    }

    struct Balance: Codable, Equatable {
        var available: Bool?
        var at: Double?
        var wallets: [Wallet]?
        var rub: Double?
        var walletRub: [String: Double]?
        var rates: [String: Double]?
        var ratesAt: Double?
        var ratesDate: String?
        var ratesSource: String?
        var converted: [String: Double]?
    }

    var schemaVersion: Int?
    var updatedAt: Double?
    var collector: Collector?
    var agent: Activity?
    var today: Today?
    var balance: Balance?

    /// Версия схемы, которую понимает эта сборка приложения.
    static let supportedSchemaVersion = 1

    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        return Date(timeIntervalSince1970: updatedAt / 1000)
    }

    var status: AgentActivityStatus {
        AgentActivityStatus(raw: agent?.status)
    }

    var sessions: [Session] {
        agent?.sessions ?? []
    }

    func wallet(_ code: String) -> Wallet? {
        balance?.wallets?.first { $0.currency == code }
    }

    /// Сколько всего денег на счетах, в рублях. Считает сборщик: у приложения
    /// нет курсов, чтобы пересчитать самому.
    var rubTotal: Double? { balance?.rub }
}

/// Состояние агента, приведённое к четырём понятным значениям.
enum AgentActivityStatus: String {
    case working
    case waiting
    case idle
    case off
    case unknown

    init(raw: String?) {
        self = AgentActivityStatus(rawValue: raw ?? "") ?? .unknown
    }

    var title: String {
        switch self {
        case .working: return "Работает"
        case .waiting: return "Ждёт"
        case .idle: return "Простаивает"
        case .off: return "Выключен"
        case .unknown: return "Нет данных"
        }
    }

    var explanation: String {
        switch self {
        case .working: return "Агент выполняет шаги прямо сейчас"
        case .waiting: return "Ход открыт, но агент давно не отвечал"
        case .idle: return "Запущен и ждёт задачи"
        case .off: return "Процесс dsh не запущен"
        case .unknown: return "Сборщик ещё не присылал состояние"
        }
    }

    /// Имя цвета, а не Color: так значение можно проверить в тестах.
    var colorName: String {
        switch self {
        case .working: return "green"
        case .waiting: return "yellow"
        case .idle: return "gray"
        case .off: return "red"
        case .unknown: return "gray"
        }
    }
}

/// Валюты, которые умеет показывать вкладка.
enum AgentCurrency: String, CaseIterable, Identifiable, Codable {
    case rub
    case cny
    case usd
    case eur

    var id: String { rawValue }

    /// Код в снимке и в ответе ЦБ.
    var code: String {
        switch self {
        case .rub: return "RUB"
        case .cny: return "CNY"
        case .usd: return "USD"
        case .eur: return "EUR"
        }
    }

    var symbol: String {
        switch self {
        case .rub: return "₽"
        case .cny: return "¥"
        case .usd: return "$"
        case .eur: return "€"
        }
    }

    var title: String {
        switch self {
        case .rub: return "Рубли"
        case .cny: return "Юани"
        case .usd: return "Доллары"
        case .eur: return "Евро"
        }
    }
}

/// Как показывать токены за сегодня.
enum AgentTokenMode: String, CaseIterable, Identifiable, Codable {
    /// Одна цифра — input + output, то есть то, что списывается с баланса
    /// заметнее всего.
    case single
    /// Разбивка по категориям, включая кэш.
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Одной цифрой"
        case .detailed: return "По отдельности"
        }
    }

    var explanation: String {
        switch self {
        case .single:
            return "Крупно — input + output за сегодня (то, за что списываются деньги), мелко — остальное."
        case .detailed:
            return "Четыре строки: input, output, чтение кэша и запись кэша."
        }
    }
}

/// Откуда вкладка берёт данные.
enum AgentSourceKind: String, CaseIterable, Identifiable, Codable {
    /// Самый удобный путь: если на машине есть DSH и Node — запускать
    /// встроенный сборщик, иначе читать готовый файл.
    case auto
    /// Готовый JSON, который пишет кто-то другой.
    case file
    /// Любая команда, печатающая JSON в stdout.
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .file: return "Файл"
        case .command: return "Команда"
        }
    }
}

/// Форматирование чисел для вкладки. Вынесено отдельно от вида, чтобы
/// проверялось тестами без графики.
enum AgentFormat {
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        formatter.decimalSeparator = ","
        return formatter
    }()

    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.decimalSeparator = ","
        return formatter
    }()

    static func tokens(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: max(0, value))) ?? String(value)
    }

    /// Сумма в валюте: «26,67 ¥».
    static func money(_ value: Double, _ currency: AgentCurrency) -> String {
        let number = moneyFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "\(number) \(currency.symbol)"
    }

    /// Без символа — для случаев, когда валюта подписана рядом.
    static func amount(_ value: Double) -> String {
        moneyFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// «1 сессия», «2 сессии», «5 сессий».
    static func sessions(_ count: Int) -> String {
        let remainder100 = count % 100
        let remainder10 = count % 10
        if remainder100 >= 11 && remainder100 <= 14 { return "\(count) сессий" }
        switch remainder10 {
        case 1: return "\(count) сессия"
        case 2, 3, 4: return "\(count) сессии"
        default: return "\(count) сессий"
        }
    }

    /// «12 с назад», «5 мин назад», «2 ч назад».
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
        if seconds < 5 { return "только что" }
        if seconds < 60 { return "\(seconds) с назад" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) мин назад" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) ч назад" }
        return "\(hours / 24) дн назад"
    }

    /// «3 мин 20 с» — длительность сессии.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) с" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) мин" }
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }
}
