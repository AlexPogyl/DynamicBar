import AppKit
import Combine
import CoreAudio
import AudioToolbox

/// Системная громкость и mute через CoreAudio.
///
/// Плеерную громкость система через Now Playing не отдаёт, поэтому ползунок
/// управляет громкостью вывода — это то же, что делают клавиши F11/F12.
/// Разрешений не требует: это публичные свойства устройства вывода.
final class SystemVolume: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var available = false

    /// Пока пользователь тянет ползунок, внешние обновления не применяем —
    /// иначе значение дёргалось бы под курсором.
    var isDragging = false

    private var deviceID: AudioDeviceID = 0
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "com.dynamicbar.volume")
    private var refreshTimer: Timer?

    init() {
        available = resolveDevice() && read()
        installListeners()
    }

    deinit {
        removeListeners()
    }

    // MARK: - Устройство

    @discardableResult
    private func resolveDevice() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else {
            Log.error("volume: default output device unavailable (status \(status))")
            return false
        }
        deviceID = device
        return true
    }

    // MARK: - Адреса свойств

    private var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Чтение

    @discardableResult
    func refresh() -> Bool {
        resolveDevice()
        return read()
    }

    private func read() -> Bool {
        guard deviceID != 0 else { return false }
        var ok = false

        var volumeAddress = self.volumeAddress
        if AudioObjectHasProperty(deviceID, &volumeAddress) {
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &value) == noErr {
                if !isDragging, abs(level - value) > 0.001 { level = value }
                ok = true
            }
        }

        var muteAddress = self.muteAddress
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &value) == noErr {
                let muted = value != 0
                if isMuted != muted { isMuted = muted }
                ok = true
            }
        }

        if available != ok { available = ok }
        return ok
    }

    // MARK: - Запись

    func setLevel(_ newValue: Float) {
        guard deviceID != 0 else { return }
        let clamped = min(max(newValue, 0), 1)
        level = clamped
        var value = Float32(clamped)
        var address = volumeAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status != noErr { Log.error("volume: could not set level (status \(status))") }
        // Выставление громкости само снимает mute — так же ведут себя клавиши.
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != 0 else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = muteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status == noErr { isMuted = muted } else { Log.error("volume: could not set mute (status \(status))") }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    // MARK: - Наблюдение

    private func installListeners() {
        guard deviceID != 0 else { return }
        let addresses = [volumeAddress, muteAddress]
        for address in addresses {
            var mutableAddress = address
            guard AudioObjectHasProperty(deviceID, &mutableAddress) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.read() }
            }
            if AudioObjectAddPropertyListenerBlock(deviceID, &mutableAddress, listenerQueue, block) == noErr {
                listeners.append((address, block))
            }
        }

        // Смена устройства вывода: перечитываем всё заново.
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.removeListeners()
                if self.resolveDevice() {
                    self.installListeners()
                }
                self.read()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, listenerQueue, deviceBlock) == noErr {
            listeners.append((deviceAddress, deviceBlock))
        }
    }

    private func removeListeners() {
        guard !listeners.isEmpty else { return }
        for (address, block) in listeners {
            var mutableAddress = address
            // Слушатель устройства висит на системном объекте, остальные — на устройстве.
            let object = address.mSelector == kAudioHardwarePropertyDefaultOutputDevice
                ? AudioObjectID(kAudioObjectSystemObject)
                : deviceID
            AudioObjectRemovePropertyListenerBlock(object, &mutableAddress, listenerQueue, block)
        }
        listeners.removeAll()
    }
}
