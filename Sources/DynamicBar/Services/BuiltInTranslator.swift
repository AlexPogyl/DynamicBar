import AppKit
import SwiftUI
import Translation

/// Встроенный переводчик macOS.
///
/// `TranslationSession` выдаётся только модификатором `.translationTask`, то
/// есть ему нужен настоящий вид в настоящем окне. Поэтому держим крошечное
/// невидимое окно: пользователь его не видит, а система считает вид живым и
/// выполняет задачу.
///
/// Класс изолирован на главном акторе: `NSWindow` и `NSHostingView` нельзя
/// создавать на фоновом потоке — это не «не рекомендуется», а мгновенный
/// `SIGABRT`. Вызов снаружи сам прыгает на главный актор через `await`.
@available(macOS 15.0, *)
@MainActor
final class BuiltInTranslator {
    static let shared = BuiltInTranslator()

    final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        @Published var pending: Pending?
    }

    struct Pending {
        let id: UUID
        let text: String
        let completion: (Result<String, Error>) -> Void
    }

    private let model = Model()
    private var window: NSWindow?
    private var current: CheckedContinuation<String, Error>?
    private var currentID: UUID?

    private init() {}

    func translate(_ text: String, from: String, to: String) async throws -> String {
        ensureWindow()

        // Предыдущий запрос отменяем: пользователь мог уже напечатать другое.
        if let current {
            self.current = nil
            currentID = nil
            current.resume(throwing: CancellationError())
        }

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            current = continuation
            currentID = id

            model.pending = Pending(id: id, text: text) { [weak self] result in
                // Продолжение можно возобновить ровно один раз. Поздний ответ
                // от прошлого запроса обязан быть отброшен, иначе это второй
                // resume и падение процесса.
                guard let self, self.currentID == id, let continuation = self.current else { return }
                self.current = nil
                self.currentID = nil
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            model.configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: from),
                target: Locale.Language(identifier: to)
            )

            // Если языковой пакет не установлен, система показывает запрос на
            // загрузку. Ждать его бесконечно нельзя: без ограничения вызов
            // висит молча, и вкладка выглядит сломанной.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                guard let self, self.currentID == id, let continuation = self.current else { return }
                self.current = nil
                self.currentID = nil
                Log.error("built-in translator: no answer in \(Int(Self.timeout))s — language pack missing?")
                continuation.resume(throwing: TranslationError.needsLanguagePack)
            }
        }
    }

    /// Сколько ждём систему, прежде чем сообщить про языковой пакет.
    private static let timeout: TimeInterval = 45

    private func ensureWindow() {
        if let window {
            window.orderFrontRegardless()
            return
        }
        let hosting = NSHostingView(rootView: HostView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 2, height: 2)

        let window = PassthroughWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        window.orderFrontRegardless()
        self.window = window
        Log.info("built-in translator: hosting window created")
    }
}

@available(macOS 15.0, *)
private final class PassthroughWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@available(macOS 15.0, *)
private struct HostView: View {
    @ObservedObject var model: BuiltInTranslator.Model

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .translationTask(model.configuration) { session in
                guard let pending = model.pending else { return }
                do {
                    let response = try await session.translate(pending.text)
                    pending.completion(.success(response.targetText))
                } catch {
                    pending.completion(.failure(error))
                }
            }
    }
}
