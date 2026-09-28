import SwiftUI

/// Вкладка «Переводчик»: английский ↔ русский.
struct TranslatorTabView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var service: TranslationService

    @FocusState private var inputFocused: Bool
    @State private var debounceWork: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)
            columns
            Divider().opacity(0.25)
            statusBar
        }
        .onChange(of: service.input) { _ in scheduleTranslate() }
    }

    // MARK: - Шапка

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Переводчик")
                .font(.system(size: 12, weight: .semibold))

            Picker("", selection: $service.provider) {
                ForEach(TranslationProvider.allCases) { provider in
                    Text(provider.shortTitle).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .onChange(of: service.provider) { _ in translateNow() }

            Spacer()

            Button(action: { service.swapLanguages() }) {
                HStack(spacing: 5) {
                    Text(service.source.shortTitle)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9))
                    Text(service.target.shortTitle)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help("Поменять направление перевода")

            IconButton(symbol: "arrow.clockwise", help: "Перевести заново") { translateNow() }
            IconButton(symbol: "xmark.circle", help: "Очистить") { service.clear() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Колонки

    private var columns: some View {
        HStack(spacing: 0) {
            editor(
                text: $service.input,
                placeholder: service.source == .english ? "Type English text…" : "Введите текст по-русски…",
                editable: true
            )
            Divider().opacity(0.25)
            editor(
                text: .constant(service.output),
                placeholder: service.isTranslating ? "Перевожу…" : "Перевод появится здесь",
                editable: false
            )
        }
        .frame(maxHeight: .infinity)
    }

    private func editor(text: Binding<String>, placeholder: String, editable: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .disabled(!editable)
                .focused($inputFocused)
                .onChange(of: inputFocused) { focused in
                    if focused, editable { appState.requestActivation() }
                }

            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if editable {
                appState.requestActivation()
                inputFocused = true
            }
        }
    }

    // MARK: - Строка состояния

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error = service.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if !service.statusMessage.isEmpty {
                Label(service.statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if service.provider == .yandex, service.yandexAPIKey.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Ввести ключ Яндекса") { appState.requestSettings() }
                    .controlSize(.small)
            }

            if !service.output.isEmpty {
                IconButton(symbol: "doc.on.doc", help: "Скопировать перевод") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(service.output, forType: .string)
                    appState.showToast("Перевод скопирован")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var hint: String {
        if service.provider == .yandex, service.yandexAPIKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Яндекс работает только с API-ключом — он вводится в настройках"
        }
        if service.autoDirection {
            return "Направление определяется по тексту · \(service.source.shortTitle) → \(service.target.shortTitle)"
        }
        return "\(service.source.title) → \(service.target.title)"
    }

    // MARK: - Действия

    /// Переводим не на каждую букву: пауза 0.7 с после набора.
    private func scheduleTranslate() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { service.translate() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func translateNow() {
        debounceWork?.cancel()
        service.translate()
    }
}
