import SwiftUI

/// Вкладка «Музыка». Данные приходят из системного Now Playing через
/// perl-хелпер, поэтому название, исполнитель, обложка и позиция живые.
/// Громкость — системная: плеерную macOS через Now Playing не отдаёт.
struct MusicTabView: View {
    @ObservedObject var nowPlaying: NowPlayingService
    @ObservedObject var volume: SystemVolume

    @State private var scrubHover = false
    /// Пока идёт перетаскивание, полоса следует за курсором, а не за часами.
    @State private var scrubbing: Double?
    /// То же для громкости.
    @State private var volumeDraft: Float?

    private let artworkSide: CGFloat = 124
    private let textColumnWidth: CGFloat = 380

    var body: some View {
        Group {
            if nowPlaying.hasTrack {
                player
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: - Пустое состояние

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            Text(nowPlaying.detectedPlayerApp.isEmpty
                 ? "Ничего не воспроизводится"
                 : "Играет: \(nowPlaying.detectedPlayerApp)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(emptyExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            transportControls
                .padding(.top, 12)

            volumeRow
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyExplanation: String {
        if nowPlaying.helperActive {
            return "Включите музыку в любом плеере или в браузере — панель подхватит её автоматически."
        }
        if nowPlaying.frameworkAvailable {
            return """
            Системный Now Playing недоступен: macOS отдаёт его только доверенным процессам. \
            Проверьте, что в бандле есть libdynamicbarmedia.dylib и доступен /usr/bin/perl.
            """
        }
        return "Системный Now Playing недоступен на этой версии macOS."
    }

    // MARK: - Плеер

    private var player: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Обложка и текст центрируются как один блок: раньше строка была
            // прижата влево и справа оставалась пустота.
            HStack(alignment: .center, spacing: 20) {
                artwork
                metadata
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.28), value: nowPlaying.title)

            transportControls
                .padding(.top, 18)

            volumeRow
                .padding(.top, 14)

            Spacer(minLength: 0)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(nowPlaying.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .help(nowPlaying.title)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let source = sourceLine {
                HStack(spacing: 4) {
                    if let icon = nowPlaying.sourceAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 13, height: 13)
                    }
                    Text(source)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                scrubber(at: context.date)
            }

            Spacer(minLength: 8)
        }
        .frame(width: textColumnWidth, height: artworkSide, alignment: .leading)
    }

    /// Система часто повторяет название в поле альбома — показывать
    /// «Исполнитель — Название» дважды выглядит как ошибка.
    private var subtitle: String {
        var parts: [String] = []
        if !nowPlaying.artist.isEmpty { parts.append(nowPlaying.artist) }
        if !nowPlaying.album.isEmpty, nowPlaying.album != nowPlaying.title { parts.append(nowPlaying.album) }
        return parts.joined(separator: " — ")
    }

    private var sourceLine: String? {
        guard !nowPlaying.sourceAppName.isEmpty else { return nil }
        switch nowPlaying.metadataSource {
        case .helper, .systemNowPlaying: return nowPlaying.sourceAppName
        case .windowTitle: return "\(nowPlaying.sourceAppName) — название из заголовка окна"
        case .none: return nil
        }
    }

    // MARK: - Обложка

    /// Обложки приходят любого размера, поэтому квадратность — вопрос
    /// пропорции, а не точных пикселей: 300×301 квадратная для глаза.
    private func isSquare(_ image: NSImage) -> Bool {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return true }
        return abs(size.width / size.height - 1) < 0.02
    }

    private var artwork: some View {
        ZStack {
            if let image = nowPlaying.artwork {
                Color.primary.opacity(0.06)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isSquare(image) ? .fill : .fit)
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: artworkSide, height: artworkSide)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        .animation(.easeInOut(duration: 0.28), value: nowPlaying.artwork)
    }

    // MARK: - Полоса прогресса

    private func progressValue(at date: Date) -> Double {
        if let scrubbing { return scrubbing }
        return nowPlaying.progress(at: date)
    }

    private func scrubber(at date: Date) -> some View {
        let value = progressValue(at: date)
        let position = nowPlaying.duration > 0 ? value * nowPlaying.duration : nowPlaying.position(at: date)
        let enabled = nowPlaying.canSeek

        return HStack(spacing: 8) {
            Text(formatTime(position))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: max(0, width * value))
                }
                .frame(height: scrubHover && enabled ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    scrubHover = hovering
                    if enabled {
                        hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard enabled, width > 0 else { return }
                            scrubbing = min(max(drag.location.x / width, 0), 1)
                        }
                        .onEnded { drag in
                            guard enabled, width > 0 else { return }
                            let target = min(max(drag.location.x / width, 0), 1) * nowPlaying.duration
                            nowPlaying.seek(to: target)
                            scrubbing = nil
                        }
                )
            }
            .frame(height: 14)

            Text(formatTime(nowPlaying.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
        .opacity(nowPlaying.duration > 0 ? 1 : 0.45)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        guard total >= 3600 else { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Громкость

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button(action: { volume.toggleMute() }) {
                Image(systemName: muteSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(volume.isMuted ? Color.secondary : Color.primary)
            .help(volume.isMuted ? "Включить звук" : "Выключить звук")
            .disabled(!volume.available)

            VolumeSlider(
                value: Binding(
                    get: { volumeDraft ?? volume.level },
                    set: { newValue in
                        volumeDraft = newValue
                        volume.isDragging = true
                        volume.setLevel(newValue)
                    }
                ),
                onRelease: {
                    volumeDraft = nil
                    volume.isDragging = false
                }
            )
            .frame(width: 220)

            Text("\(Int(((volumeDraft ?? volume.level) * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(volume.available ? 1 : 0.4)
        .help("Громкость системы")
    }

    private var muteSymbol: String {
        if volume.isMuted || volume.level <= 0.001 { return "speaker.slash.fill" }
        if volume.level < 0.34 { return "speaker.wave.1.fill" }
        if volume.level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Кнопки управления

    private var transportControls: some View {
        HStack(spacing: 26) {
            TransportButton(
                symbol: "backward.fill",
                size: 20,
                help: "Предыдущий трек",
                enabled: nowPlaying.canSkip
            ) {
                nowPlaying.previous()
            }

            TransportButton(
                symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                size: 26,
                help: nowPlaying.isPlaying ? "Пауза" : "Играть",
                prominent: true
            ) {
                nowPlaying.togglePlayPause()
            }

            TransportButton(
                symbol: "forward.fill",
                size: 20,
                help: "Следующий трек",
                enabled: nowPlaying.canSkip
            ) {
                nowPlaying.next()
            }
        }
    }
}

/// Ползунок громкости, который сообщает о моменте отпускания — иначе внешние
/// обновления дёргали бы значение под курсором.
private struct VolumeSlider: View {
    @Binding var value: Float
    let onRelease: () -> Void

    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: isHovering ? 6 : 4)
                Capsule()
                    .fill(Color.primary.opacity(0.65))
                    .frame(width: max(0, width * CGFloat(min(max(value, 0), 1))), height: isHovering ? 6 : 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                hovering ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        value = Float(min(max(drag.location.x / width, 0), 1))
                    }
                    .onEnded { _ in onRelease() }
            )
        }
        .frame(height: 16)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var help: String = ""
    var prominent: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: prominent ? 54 : 42, height: prominent ? 54 : 42)
                .background(
                    Circle().fill(isHovering && enabled
                                  ? Color.accentColor.opacity(0.24)
                                  : Color.primary.opacity(prominent ? 0.10 : 0.06))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.accentColor : Color.primary)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
