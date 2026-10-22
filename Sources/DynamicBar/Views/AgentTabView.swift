import SwiftUI

/// Вкладка «Агент»: токены за сегодня, баланс и чем занят агент прямо сейчас.
///
/// Данные приходят снимком от сборщика (см. `AgentStore`). Вкладка ничего не
/// знает про DeepSeek Harness: если снимок отдаёт другой агент, показывается
/// то же самое.
struct AgentTabView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.25)

            if let snapshot = store.snapshot {
                content(snapshot)
            } else if case .failed(let message) = store.phase {
                failure(message)
            } else {
                loading
            }
        }
    }

    // MARK: - Шапка

    private var toolbar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text("Агент")
                .font(.system(size: 12, weight: .semibold))

            if let snapshot = store.snapshot {
                Text(snapshot.status.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Text(store.sourceLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if !store.isRefreshing, let date = store.lastRefresh {
                    Text("· обновлено \(AgentFormat.age(date))")
                        .font(.system(size: 10))
                        .foregroundStyle(isStale ? Color.orange : Color.secondary)
                }
            } else {
                Text("нет данных")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }

            IconButton(symbol: "arrow.clockwise", help: "Обновить сейчас") {
                store.refresh()
            }
            IconButton(symbol: "gearshape", help: "Настройки агента") {
                appState.requestSettings()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch store.snapshot?.status ?? .unknown {
        case .working: return .green
        case .waiting: return .yellow
        case .idle: return .gray
        case .off: return .red
        case .unknown: return .gray
        }
    }

    private var isStale: Bool {
        guard let date = store.lastRefresh else { return false }
        return Date().timeIntervalSince(date) > 60
    }

    // MARK: - Данные

    private func content(_ snapshot: AgentSnapshot) -> some View {
        VStack(spacing: 10) {
            if case .failed(let message) = store.phase {
                warning(message)
            }

            statusCard(snapshot)

            HStack(alignment: .top, spacing: 10) {
                balanceCard(snapshot)
                tokensCard(snapshot)
            }

            sessionsCard(snapshot)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func statusCard(_ snapshot: AgentSnapshot) -> some View {
        let session = snapshot.sessions.first
        let title = session?.title?.isEmpty == false ? session?.title : session?.project
        let task = session?.task

        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.status.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let session, let project = session.project, project != title {
                        Text(project)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let tool = session?.tool {
                        Label(tool, systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(title ?? snapshot.status.explanation)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let task, !task.isEmpty {
                    Text(task)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func balanceCard(_ snapshot: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cardTitle("Баланс", trailing: snapshot.balance?.ratesDate.map { "курс ЦБ · \($0)" })

            if snapshot.rubTotal != nil, snapshot.balance?.available != false {
                ForEach(orderedCurrencies) { currency in
                    HStack(spacing: 6) {
                        Text(currency.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .leading)
                        Text(amount(for: currency, in: snapshot))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("Ключ API не найден или баланс недоступен")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func tokensCard(_ snapshot: AgentSnapshot) -> some View {
        let today = snapshot.today
        let billable = today?.billable ?? ((today?.input ?? 0) + (today?.output ?? 0))

        return VStack(alignment: .leading, spacing: 6) {
            cardTitle("Токены за сегодня", trailing: today?.sessions.map { AgentFormat.sessions($0) })

            if store.tokenMode == .single {
                Text(AgentFormat.tokens(billable))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("input \(AgentFormat.tokens(today?.input ?? 0)) · output \(AgentFormat.tokens(today?.output ?? 0))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("кэш \(AgentFormat.tokens(today?.cacheRead ?? 0))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                tokenRow("input", today?.input)
                tokenRow("output", today?.output)
                tokenRow("чтение кэша", today?.cacheRead)
                tokenRow("запись кэша", today?.cacheWrite)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func sessionsCard(_ snapshot: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Сессии")
                    .font(.system(size: 11, weight: .semibold))
                Text(snapshot.agent?.dshRunning == false ? "dsh не запущен" : "\(snapshot.sessions.count) активных")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if snapshot.sessions.isEmpty {
                Text("Нет активных сессий")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(snapshot.sessions) { session in
                            sessionRow(session)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(cardBackground)
    }

    private func sessionRow(_ session: AgentSnapshot.Session) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: AgentActivityStatus(raw: session.status)))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.project ?? "без проекта")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let title = session.title, !title.isEmpty {
                        Text("· \(title)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let task = session.task, !task.isEmpty {
                    Text(task)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            if let tool = session.tool {
                Text(tool)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(AgentFormat.age(session.lastEventAt.map { Date(timeIntervalSince1970: $0 / 1000) }))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Пустые состояния

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Читаю данные агента…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Агент не подключён")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Обновить") { store.refresh() }
                    .controlSize(.small)
                Button("Настройки") { appState.requestSettings() }
                    .controlSize(.small)
                Button("Как подключить") {
                    if let url = URL(string: "https://github.com/AlexPogyl/DynamicBar#вкладка-агент") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }

            Text("Если DeepSeek Harness установлен, нужен только Node: сборщик уже внутри приложения.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func warning(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Мелочи

    private var orderedCurrencies: [AgentCurrency] {
        AgentCurrency.allCases.filter { store.currencies.contains($0) }
    }

    private func amount(for currency: AgentCurrency, in snapshot: AgentSnapshot) -> String {
        let value: Double?
        switch currency {
        case .cny: value = snapshot.wallet("CNY")?.total
        case .usd: value = snapshot.wallet("USD")?.total
        case .rub: value = snapshot.balance?.rub
        case .eur: value = snapshot.balance?.converted?["EUR"]
        }
        return AgentFormat.amount(value ?? 0)
    }

    private func tokenRow(_ title: String, _ value: Int?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(AgentFormat.tokens(value ?? 0))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    private func cardTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.055))
    }

    private func color(for status: AgentActivityStatus) -> Color {
        switch status {
        case .working: return .green
        case .waiting: return .yellow
        case .idle: return .gray
        case .off: return .red
        case .unknown: return .gray
        }
    }
}
