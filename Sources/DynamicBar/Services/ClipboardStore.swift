import AppKit
import Combine
import CryptoKit

/// Одна запись в истории буфера: текст или изображение.
struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    var id: UUID
    var kind: Kind
    var text: String
    var date: Date
    var isPinned: Bool

    /// Имя файла в папке изображений (только для `kind == .image`).
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageBytes: Int?
    /// SHA-256 содержимого — по нему распознаётся повторная копия.
    var imageDigest: String?

    init(id: UUID = UUID(), text: String, date: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.kind = .text
        self.text = text
        self.date = date
        self.isPinned = isPinned
    }

    init(id: UUID = UUID(),
         imageFile: String,
         width: Int,
         height: Int,
         bytes: Int,
         digest: String,
         date: Date = Date()) {
        self.id = id
        self.kind = .image
        self.text = ""
        self.date = date
        self.isPinned = false
        self.imageFile = imageFile
        self.imageWidth = width
        self.imageHeight = height
        self.imageBytes = bytes
        self.imageDigest = digest
    }

    // MARK: - Codable с обратной совместимостью

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, date, isPinned
        case imageFile, imageWidth, imageHeight, imageBytes, imageDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // Записи, сохранённые до появления картинок, поля `kind` не имеют.
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        imageFile = try container.decodeIfPresent(String.self, forKey: .imageFile)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        imageBytes = try container.decodeIfPresent(Int.self, forKey: .imageBytes)
        imageDigest = try container.decodeIfPresent(String.self, forKey: .imageDigest)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(date, forKey: .date)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(imageFile, forKey: .imageFile)
        try container.encodeIfPresent(imageWidth, forKey: .imageWidth)
        try container.encodeIfPresent(imageHeight, forKey: .imageHeight)
        try container.encodeIfPresent(imageBytes, forKey: .imageBytes)
        try container.encodeIfPresent(imageDigest, forKey: .imageDigest)
    }

    // MARK: - Производные

    var isImage: Bool { kind == .image }

    /// Ключ для распознавания повторов.
    var dedupKey: String {
        switch kind {
        case .image: return "img:\(imageDigest ?? id.uuidString)"
        case .text: return "txt:\(normalized)"
        }
    }

    var normalized: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var firstLine: String {
        normalized.components(separatedBy: .newlines).first ?? normalized
    }

    var lineCount: Int {
        max(1, normalized.components(separatedBy: .newlines).count)
    }

    var characterCount: Int { normalized.count }

    var isURL: Bool {
        guard kind == .text else { return false }
        guard let url = URL(string: firstLine), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    /// Вторая строка списка: остаток многострочной записи или хвост длинной
    /// строки. Первую строку не повторяет.
    var secondaryPreview: String? {
        guard kind == .text else { return nil }
        let lines = normalized.components(separatedBy: .newlines)
        if lines.count > 1 {
            let rest = lines.dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return rest.isEmpty ? nil : rest
        }
        if normalized.count > 90 {
            return "…" + String(normalized.dropFirst(90))
        }
        return nil
    }

    var imageDescription: String {
        guard let width = imageWidth, let height = imageHeight else { return "Изображение" }
        return "Изображение \(width) × \(height)"
    }

    var imageSizeDescription: String? {
        guard let bytes = imageBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    var relativeDate: String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 10 { return "только что" }
        if seconds < 60 { return "\(Int(seconds)) сек назад" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) ч назад" }
        return "\(Int(seconds / 86_400)) дн назад"
    }
}

/// Опрашивает `NSPasteboard.general` и ведёт ограниченную историю текста и
/// изображений.
///
/// Правила приватности (как в Maccy/Cyclop):
///  * всё, что помечено `org.nspasteboard.ConcealedType` (менеджеры паролей),
///    игнорируется,
///  * `org.nspasteboard.TransientType` / `AutoGeneratedType` игнорируются,
///  * известные маркеры менеджеров паролей игнорируются,
///  * то, что скопировал сам DynamicBar, повторно не записывается.
final class ClipboardStore: ObservableObject {
    static let maxItems = 40
    /// Больше 12 МБ в историю не берём: это уже не «картинка», а файл.
    static let maxImageBytes = 12 * 1024 * 1024
    /// Предел стороны для миниатюры в списке.
    private static let thumbnailMaxSide: CGFloat = 320

    @Published private(set) var items: [ClipboardItem] = []
    @Published var searchText: String = ""
    @Published private(set) var lastSkippedConcealed: Date?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let storeURL = AppPaths.file("clipboard.json")
    private let saveQueue = DispatchQueue(label: "com.dynamicbar.clipboard.save")
    private let imageQueue = DispatchQueue(label: "com.dynamicbar.clipboard.images", qos: .utility)

    /// Миниатюры держим в памяти: список перерисовывается часто, а диск — нет.
    private var thumbnails: [UUID: NSImage] = [:]

    private static let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "net.antelle.keeweb",
        "com.apple.pasteboard.promised",
    ]

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        try? FileManager.default.createDirectory(at: AppPaths.imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Жизненный цикл

    func start() {
        stop()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        cleanupImageFiles()
        Log.info("ClipboardStore started (history=\(items.count), max=\(Self.maxItems))")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Опрос буфера

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let types = pasteboard.types, !types.isEmpty else { return }

        for type in types where Self.ignoredTypes.contains(type.rawValue) {
            lastSkippedConcealed = Date()
            Log.debug("clipboard: skipped (type \(type.rawValue))")
            return
        }

        if types.contains(.tiff) || types.contains(.png) {
            captureImage()
            return
        }

        guard let string = pasteboard.string(forType: .string) else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100_000 else { return }
        add(trimmed)
    }

    private func captureImage() {
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return }
        guard data.count <= Self.maxImageBytes else {
            Log.debug("clipboard: image skipped (\(data.count) bytes > limit)")
            return
        }
        guard let image = NSImage(data: data) else { return }

        let pixels = Self.pixelSize(of: data) ?? Self.pixelSize(of: image)
        guard pixels.width >= 8, pixels.height >= 8 else { return }

        guard let png = Self.pngData(from: image), png.count <= Self.maxImageBytes else { return }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()

        let fileName = "\(UUID().uuidString).png"
        let url = AppPaths.imagesDirectory.appendingPathComponent(fileName)
        do {
            try png.write(to: url, options: [.atomic])
        } catch {
            Log.error("clipboard: could not store image (\(error))")
            return
        }
        addImage(fileName: fileName, width: pixels.width, height: pixels.height, bytes: png.count, digest: digest)
    }

    // MARK: - Изменения

    func add(_ text: String) {
        insert(ClipboardItem(text: text))
    }

    func addImage(fileName: String, width: Int, height: Int, bytes: Int, digest: String) {
        insert(ClipboardItem(imageFile: fileName, width: width, height: height, bytes: bytes, digest: digest))
    }

    private func insert(_ item: ClipboardItem) {
        var newItems = items
        // Повтор не дублируется, а поднимается наверх.
        if let index = newItems.firstIndex(where: { $0.dedupKey == item.dedupKey }) {
            var existing = newItems.remove(at: index)
            existing.date = Date()
            newItems.insert(existing, at: 0)
            // Новый файл оказался копией уже сохранённого — убираем лишний.
            if let orphan = item.imageFile, orphan != existing.imageFile {
                removeImageFile(named: orphan)
            }
        } else {
            newItems.insert(item, at: 0)
        }
        if newItems.count > Self.maxItems {
            for dropped in newItems[Self.maxItems...] where dropped.isImage {
                thumbnails[dropped.id] = nil
            }
            newItems = Array(newItems.prefix(Self.maxItems))
        }
        items = newItems
        persist()
        cleanupImageFiles()
        Log.debug("clipboard: captured \(item.isImage ? "image" : "text") (total \(items.count))")
    }

    /// Кладёт запись обратно в системный буфер, не записывая её заново.
    func copyToPasteboard(_ item: ClipboardItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let image = fullImage(for: item) else {
                Log.error("clipboard: image file for \(item.id) is gone")
                return
            }
            pasteboard.writeObjects([image])
        }
        lastChangeCount = pasteboard.changeCount
        bump(item)
    }

    /// Обычное текстовое копирование — используется сниппетами и заметками.
    func copyToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func bump(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var newItems = items
        var moved = newItems.remove(at: index)
        moved.date = Date()
        newItems.insert(moved, at: 0)
        items = newItems
        persist()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        persist()
        cleanupImageFiles()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        persist()
    }

    func clearAll() {
        items.filter { !$0.isPinned }.forEach { thumbnails[$0.id] = nil }
        items.removeAll { !$0.isPinned }
        persist()
        cleanupImageFiles()
    }

    func clearEverything() {
        items.forEach { thumbnails[$0.id] = nil }
        items.removeAll()
        persist()
        cleanupImageFiles()
    }

    var filtered: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { item in
            if item.isImage { return "изображение".contains(query) || "картинка".contains(query) }
            return item.text.lowercased().contains(query)
        }
    }

    // MARK: - Изображения

    /// Миниатюра для списка: полноразмерный PNG декодировать на каждую строку
    /// слишком дорого.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.isImage else { return nil }
        if let cached = thumbnails[item.id] { return cached }
        guard let url = imageURL(for: item), let image = NSImage(contentsOf: url) else { return nil }
        let thumb = Self.downscaled(image, maxSide: Self.thumbnailMaxSide)
        thumbnails[item.id] = thumb
        return thumb
    }

    private func fullImage(for item: ClipboardItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data) { return image }
        return NSImage(contentsOf: url)
    }

    private func imageURL(for item: ClipboardItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        return AppPaths.imagesDirectory.appendingPathComponent(file)
    }

    private func removeImageFile(named name: String) {
        try? FileManager.default.removeItem(at: AppPaths.imagesDirectory.appendingPathComponent(name))
    }

    /// Удаляет файлы, на которые больше никто не ссылается. Вытесненные
    /// записи не должны оставлять за собой мегабайты.
    private func cleanupImageFiles() {
        let referenced = Set(items.compactMap(\.imageFile))
        let directory = AppPaths.imagesDirectory
        imageQueue.async {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            var removed = 0
            for file in files where file.hasSuffix(".png") && !referenced.contains(file) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                removed += 1
            }
            if removed > 0 { Log.debug("clipboard: removed \(removed) orphaned image file(s)") }
        }
    }

    // MARK: - Вспомогательное

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    private static func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (Int(image.size.width), Int(image.size.height))
    }

    private static func downscaled(_ image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxSide || size.height > maxSide, size.width > 0, size.height > 0 else { return image }
        let scale = min(maxSide / size.width, maxSide / size.height)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1)
        result.unlockFocus()
        return result
    }

    // MARK: - Хранение

    private func persist() {
        let snapshot = items
        let url = storeURL
        saveQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.error("clipboard persist failed: \(error)")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            items = try JSONDecoder().decode([ClipboardItem].self, from: data)
            // Записи о картинках, чьи файлы пропали, показывать нельзя.
            let before = items.count
            items.removeAll { item in
                guard item.isImage, let file = item.imageFile else { return false }
                return !FileManager.default.fileExists(atPath: AppPaths.imagesDirectory.appendingPathComponent(file).path)
            }
            if items.count != before {
                Log.info("clipboard history: dropped \(before - items.count) image(s) with missing files")
            }
            Log.info("clipboard history loaded: \(items.count) items")
        } catch {
            Log.error("clipboard history decode failed: \(error)")
        }
    }
}
