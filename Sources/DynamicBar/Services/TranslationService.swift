import AppKit
import Combine
import Foundation

/// Источник перевода.
enum TranslationProvider: String, CaseIterable, Identifiable {
    /// Яндекс.Облако. Нужен API-ключ: без него сервис отвечает 405.
    case yandex
    /// Открытый endpoint Google — работает без ключа, но он неофициальный.
    case google
    /// Встроенный переводчик macOS. Без ключа и без интернета, но системе
    /// нужно один раз скачать языковой пакет.
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yandex: return "Яндекс"
        case .google: return "Google"
        case .builtIn: return "Встроенный (macOS)"
        }
    }

    var shortTitle: String {
        switch self {
        case .yandex: return "Яндекс"
        case .google: return "Google"
        case .builtIn: return "macOS"
        }
    }

    var needsKey: Bool { self == .yandex }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "Английский"
        case .russian: return "Русский"
        }
    }

    var shortTitle: String { self == .english ? "EN" : "RU" }
}

/// Перевод английский ↔ русский.
///
/// Порядок источников задаёт пользователь, но если выбран Яндекс без ключа,
/// сервис честно скажет об этом, а не сделает вид, что переводит.
final class TranslationService: ObservableObject {
    @Published var provider: TranslationProvider {
        didSet { defaults.set(provider.rawValue, forKey: Key.provider) }
    }

    @Published var source: TranslationLanguage = .english
    @Published var target: TranslationLanguage = .russian

    @Published var input: String = ""
    @Published private(set) var output: String = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String = ""

    /// Определять направление по письменности ввода: кириллица → RU→EN.
    @Published var autoDirection: Bool {
        didSet { defaults.set(autoDirection, forKey: Key.autoDirection) }
    }

    @Published var yandexAPIKey: String {
        didSet { defaults.set(yandexAPIKey, forKey: Key.yandexKey) }
    }
    @Published var yandexFolderID: String {
        didSet { defaults.set(yandexFolderID, forKey: Key.yandexFolder) }
    }

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    private enum Key {
        static let provider = "translationProvider"
        static let autoDirection = "translationAutoDirection"
        static let yandexKey = "translationYandexKey"
        static let yandexFolder = "translationYandexFolder"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.provider) ?? ""
        provider = TranslationProvider(rawValue: stored) ?? .google
        autoDirection = defaults.object(forKey: Key.autoDirection) as? Bool ?? true
        yandexAPIKey = defaults.string(forKey: Key.yandexKey) ?? ""
        yandexFolderID = defaults.string(forKey: Key.yandexFolder) ?? ""
    }

    // MARK: - Направление

    func swapLanguages() {
        let previousSource = source
        source = target
        target = previousSource
        // Результат предыдущего перевода становится входом: так удобнее
        // проверять обратный перевод.
        if !output.isEmpty {
            input = output
            output = ""
        }
        translate()
    }

    /// Кириллица против латиницы — этого достаточно, чтобы понять направление.
    private func detectDirectionIfNeeded() {
        guard autoDirection else { return }
        let text = input
        guard !text.isEmpty else { return }
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 }
            else if (0x0041...0x007A).contains(scalar.value) { latin += 1 }
        }
        guard cyrillic + latin > 0 else { return }
        if cyrillic > latin, source != .russian {
            source = .russian
            target = .english
        } else if latin > cyrillic, source != .english {
            source = .english
            target = .russian
        }
    }

    // MARK: - Перевод

    func translate() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            output = ""
            errorMessage = nil
            statusMessage = ""
            return
        }

        detectDirectionIfNeeded()

        task?.cancel()
        let languageSource = source
        let languageTarget = target
        let chosen = provider
        let key = yandexAPIKey
        let folder = yandexFolderID

        isTranslating = true
        errorMessage = nil
        statusMessage = ""

        // Тело задачи выполняется на главном акторе: сетевые вызовы внутри
        // приостанавливают его, а не блокируют, поэтому публикуемые свойства
        // меняются там, где их ждёт SwiftUI.
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: String
                switch chosen {
                case .google:
                    result = try await Self.googleTranslate(text, from: languageSource, to: languageTarget)
                case .yandex:
                    guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw TranslationError.missingKey
                    }
                    result = try await Self.yandexTranslate(text, from: languageSource,
                                                           to: languageTarget, key: key, folder: folder)
                case .builtIn:
                    result = try await Self.builtInTranslate(text, from: languageSource, to: languageTarget)
                }
                guard !Task.isCancelled else { return }
                self.output = result
                self.isTranslating = false
                self.statusMessage = "\(chosen.title) · \(languageSource.shortTitle) → \(languageTarget.shortTitle)"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.isTranslating = false
                self.statusMessage = ""
                self.errorMessage = (error as? TranslationError)?.message ?? error.localizedDescription
                if chosen != .google, self.provider == chosen {
                    // Не подменяем выбор пользователя молча — только сообщаем.
                    Log.error("translate: \(chosen.rawValue) failed: \(self.errorMessage ?? "")")
                }
            }
        }
    }

    func clear() {
        task?.cancel()
        input = ""
        output = ""
        errorMessage = nil
        statusMessage = ""
    }

    // MARK: - Google

    private static func googleTranslate(_ text: String, from: TranslationLanguage, to: TranslationLanguage) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: from.rawValue),
            URLQueryItem(name: "tl", value: to.rawValue),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        let data = try await fetch(components.url!, method: "GET", headers: [:], body: nil)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw TranslationError.badResponse
        }
        let translated = segments.compactMap { segment -> String? in
            guard let part = segment as? [Any], let piece = part.first as? String else { return nil }
            return piece
        }.joined()
        guard !translated.isEmpty else { throw TranslationError.badResponse }
        return translated
    }

    // MARK: - Яндекс

    private static func yandexTranslate(_ text: String,
                                        from: TranslationLanguage,
                                        to: TranslationLanguage,
                                        key: String,
                                        folder: String) async throws -> String {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespaces)
        if trimmedFolder.isEmpty {
            // Старый API v1: хватает одного ключа.
            var components = URLComponents(string: "https://translate.yandex.net/api/v1.5/tr.json/translate")!
            components.queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "lang", value: "\(from.rawValue)-\(to.rawValue)"),
                URLQueryItem(name: "format", value: "plain"),
                URLQueryItem(name: "text", value: text),
            ]
            let data = try await fetch(components.url!, method: "GET", headers: [:], body: nil)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let texts = root["text"] as? [String] else {
                throw TranslationError.badResponse
            }
            let joined = texts.joined()
            guard !joined.isEmpty else { throw TranslationError.badResponse }
            return joined
        }

        // API v2 Яндекс.Облака: ключ и идентификатор каталога.
        let url = URL(string: "https://translate.api.cloud.yandex.net/translate/v2/translate")!
        let body: [String: Any] = [
            "folderId": trimmedFolder,
            "texts": [text],
            "sourceLanguageCode": from.rawValue,
            "targetLanguageCode": to.rawValue,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await fetch(url, method: "POST",
                                   headers: ["Authorization": "Api-Key \(key)",
                                             "Content-Type": "application/json"],
                                   body: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = root["translations"] as? [[String: Any]],
              let first = translations.first?["text"] as? String, !first.isEmpty else {
            throw TranslationError.badResponse
        }
        return first
    }

    // MARK: - Встроенный переводчик macOS

    private static func builtInTranslate(_ text: String,
                                         from: TranslationLanguage,
                                         to: TranslationLanguage) async throws -> String {
        guard #available(macOS 15.0, *) else { throw TranslationError.unavailableSystem }
        return try await BuiltInTranslator.shared.translate(text, from: from.rawValue, to: to.rawValue)
    }

    // MARK: - Сеть

    private static func fetch(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Яндекс на неверный ключ отвечает 401/403, на отсутствующий — 405.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw TranslationError.invalidKey
            }
            if http.statusCode == 405 {
                throw TranslationError.missingKey
            }
            throw TranslationError.http(http.statusCode)
        }
        return data
    }
}

extension TranslationService {
    /// Прямой вызов источника — используется диагностикой `--translatestest`,
    /// чтобы проверять перевод без интерфейса.
    static func perform(_ text: String,
                        provider: TranslationProvider,
                        from: TranslationLanguage,
                        to: TranslationLanguage,
                        key: String = "",
                        folder: String = "") async throws -> String {
        switch provider {
        case .google:
            return try await googleTranslate(text, from: from, to: to)
        case .yandex:
            guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { throw TranslationError.missingKey }
            return try await yandexTranslate(text, from: from, to: to, key: key, folder: folder)
        case .builtIn:
            guard #available(macOS 15.0, *) else { throw TranslationError.unavailableSystem }
            return try await BuiltInTranslator.shared.translate(text, from: from.rawValue, to: to.rawValue)
        }
    }
}

enum TranslationError: Error {
    case missingKey
    case needsLanguagePack
    case invalidKey
    case badResponse
    case unavailableSystem
    case http(Int)

    var message: String {
        switch self {
        case .missingKey:
            return "Нужен API-ключ Яндекс.Облака — добавьте его в настройках вкладки."
        case .needsLanguagePack:
            return "Встроенному переводчику нужен языковой пакет: разрешите его загрузку в системном запросе и повторите."
        case .invalidKey:
            return "Яндекс отклонил ключ. Проверьте ключ и идентификатор каталога."
        case .badResponse:
            return "Сервис вернул неожиданный ответ."
        case .unavailableSystem:
            return "Встроенный переводчик требует macOS 15 или новее."
        case .http(let code):
            return "Сервис ответил кодом \(code)."
        }
    }
}
