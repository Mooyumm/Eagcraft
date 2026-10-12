import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO

typealias RemoteImageLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum LibraryImportDisposition: Equatable {
    case imported
    case addedToFolder
    case alreadyInFolder
}

struct LibraryImportResult {
    let item: LibraryItem
    let disposition: LibraryImportDisposition
}

enum ImagePaletteExtractor {
    nonisolated static func extract(from url: URL, maximumColors: Int = 8) -> [AssetPaletteColor] {
        guard maximumColors > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { return [] }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ), let raw = context.data else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pixels = raw.bindMemory(to: UInt8.self, capacity: height * bytesPerRow)
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        var visiblePixelCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                guard pixels[offset + 3] >= 32 else { continue }
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let key = (red >> 5) << 6 | (green >> 5) << 3 | (blue >> 5)
                var bucket = buckets[key] ?? (count: 0, red: 0, green: 0, blue: 0)
                bucket.count += 1
                bucket.red += red
                bucket.green += green
                bucket.blue += blue
                buckets[key] = bucket
                visiblePixelCount += 1
            }
        }
        guard visiblePixelCount > 0 else { return [] }

        let candidates = buckets.values.sorted { $0.count > $1.count }
        var selected: [(color: [Int], count: Int)] = []
        for bucket in candidates where bucket.count > 0 {
            let color = [bucket.red / bucket.count, bucket.green / bucket.count, bucket.blue / bucket.count]
            let sufficientlyDifferent = selected.allSatisfy { existing in
                let red = color[0] - existing.color[0]
                let green = color[1] - existing.color[1]
                let blue = color[2] - existing.color[2]
                return red * red + green * green + blue * blue >= 34 * 34
            }
            guard sufficientlyDifferent else { continue }
            selected.append((color, bucket.count))
            if selected.count == maximumColors { break }
        }

        return selected.map {
            AssetPaletteColor(color: $0.color, ratio: Double($0.count) / Double(visiblePixelCount))
        }
    }
}

enum LibraryManagementError: LocalizedError {
    case invalidLibrary
    case libraryAlreadyExists
    case cannotMergeCurrentLibrary
    case invalidEagleLibrary
    case exportDestinationNotEmpty
    case exportDestinationIsFile

    var errorDescription: String? {
        switch self {
        case .invalidLibrary: "所选文件夹不是有效的灵感资源库"
        case .libraryAlreadyExists: "这个位置已经存在资源库"
        case .cannotMergeCurrentLibrary: "不能把当前资源库合并到自身"
        case .invalidEagleLibrary: "所选文件夹不是有效的 Eagle 资源库"
        case .exportDestinationNotEmpty: "导出位置已存在文件，请选择新的位置"
        case .exportDestinationIsFile: "导出位置被同名文件占用，请更换名称"
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var folders: [String] = []
    @Published private(set) var referenceFolders: [String] = []
    @Published private(set) var smartFolders: [SmartFolder] = []
    @Published private(set) var folderDetails: [FolderDetails] = []
    @Published private(set) var lastSelection: SidebarSelection = .folder("文字设计")
    @Published private(set) var eagleExtras: EagleLibraryExtras?
    @Published private(set) var libraryURL: URL
    @Published private(set) var recentLibraryURLs: [URL] = []
    @Published private(set) var favoriteStyles: [String] = []
    @Published private(set) var duplicateStatus = "导入时自动检查完全重复的图片"
    @Published private(set) var folderUsage = FolderUsageLedger()
    private(set) var saveRevision: UInt64 = 0

    private let fileManager = FileManager.default
    private var rootURL: URL
    private var assetsURL: URL
    private var thumbnailsURL: URL
    private var incomingURL: URL
    private var indexURL: URL
    private let remoteImageLoader: RemoteImageLoader
    private let persistsLibrarySelection: Bool
    private let folderUsageDefaults: UserDefaults?
    private let folderUsageKey: String

    private static let activeLibraryPathKey = "EagleReplica.activeLibraryPath"
    private static let recentLibraryPathsKey = "EagleReplica.recentLibraryPaths"
    private static let exactDedupMigrationFilename = ".exact-dedup-v1"

    init(
        rootURL customRootURL: URL? = nil,
        folderUsageDefaults: UserDefaults? = nil,
        remoteImageLoader: @escaping RemoteImageLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultRoot = support.appendingPathComponent("EagleReplica/Library", isDirectory: true)
        let customRootURL = customRootURL ?? ProcessInfo.processInfo.environment["EAGLE_LIBRARY_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        persistsLibrarySelection = customRootURL == nil
        if let customRootURL {
            rootURL = customRootURL
        } else if let savedPath = UserDefaults.standard.string(forKey: Self.activeLibraryPathKey),
                  fileManager.fileExists(atPath: savedPath) {
            rootURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            rootURL = defaultRoot
        }
        libraryURL = rootURL
        assetsURL = rootURL.appendingPathComponent("assets", isDirectory: true)
        thumbnailsURL = rootURL.appendingPathComponent("thumbnails", isDirectory: true)
        incomingURL = rootURL.appendingPathComponent("incoming", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("index.json")
        // 使用频次只保存在本机，并且按素材库路径分开记录。用自定义目录打开资源库时
        // （测试和隔离运行）默认不落盘，避免污染用户真实的使用统计。
        let usageDefaults = folderUsageDefaults ?? (persistsLibrarySelection ? .standard : nil)
        self.folderUsageDefaults = usageDefaults
        self.folderUsageKey = Self.folderUsageStorageKey(for: rootURL)
        self.remoteImageLoader = remoteImageLoader
        try? fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: incomingURL, withIntermediateDirectories: true)
        load()
        restoreFolderUsage()
        if persistsLibrarySelection { restoreRecentLibraries() }
    }

    var libraryDisplayName: String {
        let name = libraryURL.deletingPathExtension().lastPathComponent
        return name == "Library" ? "小羊的灵感库" : name
    }

    var configuredTrashRetentionDays: Int {
        let stored = UserDefaults.standard.object(forKey: TrashRetentionPolicy.defaultsKey) as? Int
        return TrashRetentionPolicy.normalizedDays(stored ?? TrashRetentionPolicy.defaultDays)
    }

    func createLibrary(at url: URL) throws {
        let resolved = url.standardizedFileURL
        try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        let index = resolved.appendingPathComponent("index.json")
        guard !fileManager.fileExists(atPath: index.path) else {
            throw LibraryManagementError.libraryAlreadyExists
        }
        for name in ["assets", "thumbnails", "incoming"] {
            try fileManager.createDirectory(at: resolved.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        let empty = LibraryIndex(
            folders: [], items: [], smartFolders: [], folderDetails: [], lastSelection: .section(.all)
        )
        let data = try JSONEncoder.library.encode(empty)
        try data.write(to: index, options: .atomic)
        try openLibrary(at: resolved)
    }

    func openLibrary(at url: URL) throws {
        let resolved = url.standardizedFileURL
        let candidateIndex = resolved.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: candidateIndex),
              (try? JSONDecoder.library.decode(LibraryIndex.self, from: data)) != nil else {
            throw LibraryManagementError.invalidLibrary
        }
        save()
        configureRoot(resolved)
        load()
        rememberActiveLibrary()
    }

    func reloadLibrary() { load() }

    @discardableResult
    func mergeLibrary(at url: URL) throws -> Int {
        let sourceRoot = url.standardizedFileURL
        guard sourceRoot != rootURL.standardizedFileURL else { throw LibraryManagementError.cannotMergeCurrentLibrary }
        let sourceIndexURL = sourceRoot.appendingPathComponent("index.json")
        let data = try Data(contentsOf: sourceIndexURL)
        let source = try JSONDecoder.library.decode(LibraryIndex.self, from: data)

        for folder in source.folders where !folders.contains(folder) { folders.append(folder) }
        for folder in source.referenceFolders ?? [] where !referenceFolders.contains(folder) {
            referenceFolders.append(folder)
        }
        for details in source.folderDetails ?? [] where !folderDetails.contains(where: { $0.name == details.name }) {
            folderDetails.append(details)
        }
        for smart in source.smartFolders ?? [] where !smartFolders.contains(where: { $0.id == smart.id }) {
            smartFolders.append(smart)
        }
        favoriteStyles = orderedUniqueStyles(favoriteStyles + (source.favoriteStyles ?? []))
        var digestIndex = exactDigestIndex()
        var imported = 0
        for sourceItem in source.items {
            var item = sourceItem
            let sourceURL = sourceItem.storedFilename.map {
                sourceRoot.appendingPathComponent("assets").appendingPathComponent($0)
            } ?? imageURL(for: sourceItem)
            let digest = sourceURL.flatMap { Self.exactDigest(at: $0) }
            if let digest, let existingIndex = digestIndex[digest] {
                Self.mergeMetadata(into: &items[existingIndex], from: sourceItem)
                continue
            }
            let oldID = item.id
            item.id = UUID()
            if let filename = sourceItem.storedFilename {
                let sourceAsset = sourceRoot.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: sourceAsset.path) else { continue }
                let ext = sourceAsset.pathExtension.isEmpty ? sourceItem.format : sourceAsset.pathExtension
                let newFilename = UUID().uuidString + "." + ext
                try fileManager.copyItem(at: sourceAsset, to: assetsURL.appendingPathComponent(newFilename))
                item.storedFilename = newFilename
                let sourceThumbnail = sourceRoot.appendingPathComponent("thumbnails", isDirectory: true)
                    .appendingPathComponent(oldID.uuidString + ".jpg")
                if fileManager.fileExists(atPath: sourceThumbnail.path) {
                    try? fileManager.copyItem(
                        at: sourceThumbnail,
                        to: thumbnailsURL.appendingPathComponent(item.id.uuidString + ".jpg")
                    )
                }
            }
            items.append(item)
            if let digest { digestIndex[digest] = items.count - 1 }
            imported += 1
        }
        save()
        return imported
    }

    private func orderedUniqueStyles(_ values: [String]) -> [String] { Array(Set(values)).sorted() }

    func visibleItems(for selection: SidebarSelection, searchText: String, filter: AssetFilter, sort: LibrarySort) -> [LibraryItem] {
        var result = items.filter { item in
            let locationMatches: Bool
            switch selection {
            case .folder(let folder):
                locationMatches = !item.isTrashed && item.allFolders.contains(folder)
            case .referenceFolder(let folder):
                locationMatches = !item.isTrashed && item.allReferenceFolders.contains(folder)
            case .smartFolder(let id):
                locationMatches = !item.isTrashed && smartFolders.first(where: { $0.id == id })?.matches(item) == true
            case .tag(let tag):
                locationMatches = !item.isTrashed && item.allTags.contains {
                    $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
            case .section(let section):
                switch section {
                case .all: locationMatches = !item.isTrashed
                case .uncategorized: locationMatches = !item.isTrashed && item.folder.isEmpty
                case .untagged: locationMatches = !item.isTrashed && item.allTags.isEmpty
                case .recent: locationMatches = !item.isTrashed && item.lastOpenedAt != nil
                case .random: locationMatches = !item.isTrashed
                case .community: locationMatches = !item.isTrashed && !item.machineTags.isEmpty
                case .tags: locationMatches = false
                case .trash: locationMatches = item.isTrashed
                }
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty
                || item.name.localizedCaseInsensitiveContains(query)
                || item.note.localizedCaseInsensitiveContains(query)
                || item.allTags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            let filterMatches: Bool
            switch filter {
            case .all: filterMatches = true
            case .tagged: filterMatches = !item.allTags.isEmpty
            case .rated: filterMatches = item.rating > 0
            case .landscape: filterMatches = item.width >= item.height
            case .portrait: filterMatches = item.height > item.width
            }
            return locationMatches && searchMatches && filterMatches
        }
        if selection == .section(.random) { return result.sorted { $0.id.uuidString < $1.id.uuidString } }
        if selection == .section(.recent) {
            return result.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        }
        switch sort {
        case .addedNewest: result.sort { $0.createdAt > $1.createdAt }
        case .addedOldest: result.sort { $0.createdAt < $1.createdAt }
        case .nameAscending: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .fileSize: result.sort { $0.fileSize > $1.fileSize }
        }
        return result
    }

    func count(in selection: SidebarSelection) -> Int {
        visibleItems(for: selection, searchText: "", filter: .all, sort: .addedNewest).count
    }

    func details(for folder: String) -> FolderDetails {
        folderDetails.first(where: { $0.name == folder }) ?? FolderDetails(name: folder)
    }

    func totalSize(in folder: String) -> Int64 {
        items.lazy.filter { !$0.isTrashed && $0.allFolders.contains(folder) }.reduce(0) { $0 + $1.fileSize }
    }

    var tagCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items where !item.isTrashed {
            for tag in Set(item.tags) { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func renameTag(_ oldName: String, to proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        for index in items.indices where items[index].tags.contains(oldName) {
            items[index].tags = Array(Set(items[index].tags.map { $0 == oldName ? newName : $0 }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            items[index].modifiedAt = Date()
        }
        if lastSelection == .tag(oldName) { lastSelection = .tag(newName) }
        save()
    }

    func deleteTag(_ tag: String) {
        for index in items.indices where items[index].tags.contains(tag) {
            items[index].tags.removeAll { $0 == tag }
            items[index].modifiedAt = Date()
        }
        if lastSelection == .tag(tag) { lastSelection = .section(.tags) }
        save()
    }

    func updateFolderNote(_ folder: String, note: String) {
        guard let index = folderDetails.firstIndex(where: { $0.name == folder }) else { return }
        folderDetails[index].note = note
        save()
    }

    func imageURL(for item: LibraryItem, thumbnail: Bool = false) -> URL? {
        if let resource = item.bundledResource { return resourceBundle.url(forResource: resource, withExtension: "png") }
        guard let storedFilename = item.storedFilename else { return nil }
        if thumbnail {
            let thumb = thumbnailsURL.appendingPathComponent(item.id.uuidString + ".jpg")
            if fileManager.fileExists(atPath: thumb.path) { return thumb }
        }
        let original = assetsURL.appendingPathComponent(storedFilename)
        return fileManager.fileExists(atPath: original.path) ? original : nil
    }

    @discardableResult
    func importFile(
        at sourceURL: URL,
        folder: String,
        metadata: WebImageMetadata? = nil,
        preferredExtension: String? = nil,
        allowDuplicate: Bool = false
    ) throws -> LibraryItem {
        try performImportFile(at: sourceURL, folder: folder, metadata: metadata, preferredExtension: preferredExtension, deduplicate: !allowDuplicate).item
    }

    func importFileResult(
        at sourceURL: URL,
        folder: String,
        metadata: WebImageMetadata? = nil,
        preferredExtension: String? = nil
    ) throws -> LibraryImportResult {
        try performImportFile(at: sourceURL, folder: folder, metadata: metadata, preferredExtension: preferredExtension, deduplicate: true)
    }

    private func performImportFile(
        at sourceURL: URL,
        folder: String,
        metadata: WebImageMetadata?,
        preferredExtension: String?,
        deduplicate: Bool
    ) throws -> LibraryImportResult {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: sourceURL) else { throw CocoaError(.fileReadCorruptFile) }
        if deduplicate,
           let digest = Self.exactDigest(at: sourceURL),
           let existingIndex = exactDigestIndex()[digest] {
            if items[existingIndex].fileSize <= 0 {
                let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
                items[existingIndex].fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                items[existingIndex].format = Self.normalizedImageExtension(preferredExtension ?? sourceURL.pathExtension)
                    ?? items[existingIndex].format
            }
            let alreadyInFolder = Self.belongs(items[existingIndex], to: folder)
            if !alreadyInFolder, !folder.isEmpty {
                var memberships = items[existingIndex].additionalFolders ?? []
                if folder != items[existingIndex].folder, !memberships.contains(folder) { memberships.append(folder) }
                items[existingIndex].additionalFolders = memberships
            }
            items[existingIndex].isTrashed = false
            items[existingIndex].trashedAt = nil
            if items[existingIndex].sourceURL?.isEmpty != false { items[existingIndex].sourceURL = metadata?.sourceURL }
            if items[existingIndex].note.isEmpty { items[existingIndex].note = metadata?.pageTitle ?? "" }
            items[existingIndex].modifiedAt = Date()
            let existing = items[existingIndex]
            if !alreadyInFolder, !folder.isEmpty { recordFolderImported(folder) }
            save()
            NotificationCenter.default.post(name: .libraryDidImportAsset, object: existing)
            return LibraryImportResult(item: existing, disposition: alreadyInFolder ? .alreadyInFolder : .addedToFolder)
        }
        let format = Self.normalizedImageExtension(preferredExtension ?? sourceURL.pathExtension) ?? "jpg"
        let storedFilename = UUID().uuidString + "." + format
        let destination = assetsURL.appendingPathComponent(storedFilename)
        let id = UUID()
        let thumbnailURL = thumbnailsURL.appendingPathComponent(id.uuidString + ".jpg")
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            try makeThumbnail(from: image, at: thumbnailURL)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.removeItem(at: thumbnailURL)
            throw error
        }
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let pixels = pixelSize(of: image)
        let palette = ImagePaletteExtractor.extract(from: destination)
        let item = LibraryItem(
            id: id,
            name: metadata?.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? sourceURL.deletingPathExtension().lastPathComponent,
            note: metadata?.pageTitle ?? "",
            width: pixels.width, height: pixels.height, storedFilename: storedFilename,
            bundledResource: nil, fileSize: size, format: format, folder: folder,
            sourceURL: metadata?.sourceURL, tags: [], rating: 0, colorLabel: nil, createdAt: Date(),
            modifiedAt: Date(), lastOpenedAt: nil, isTrashed: false, palette: palette, keepDuplicate: !deduplicate
        )
        items.insert(item, at: 0)
        if !folder.isEmpty { recordFolderImported(folder) }
        save()
        NotificationCenter.default.post(name: .libraryDidImportAsset, object: item)
        return LibraryImportResult(item: item, disposition: .imported)
    }

    @discardableResult
    func importImageData(
        _ data: Data,
        folder: String,
        metadata: WebImageMetadata? = nil,
        preferredExtension: String? = nil,
        allowDuplicate: Bool = false
    ) throws -> LibraryItem {
        let detected = Self.detectImageExtension(data: data)
        let format = Self.normalizedImageExtension(preferredExtension) ?? detected ?? "jpg"
        let temporary = incomingURL.appendingPathComponent(UUID().uuidString + "." + format)
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }
        return try importFile(at: temporary, folder: folder, metadata: metadata, preferredExtension: format, allowDuplicate: allowDuplicate)
    }

    func importImageDataResult(
        _ data: Data,
        folder: String,
        metadata: WebImageMetadata? = nil,
        preferredExtension: String? = nil
    ) throws -> LibraryImportResult {
        let detected = Self.detectImageExtension(data: data)
        let format = Self.normalizedImageExtension(preferredExtension) ?? detected ?? "jpg"
        let temporary = incomingURL.appendingPathComponent(UUID().uuidString + "." + format)
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }
        return try importFileResult(at: temporary, folder: folder, metadata: metadata, preferredExtension: format)
    }

    func importRemote(_ metadata: WebImageMetadata, folder: String) async throws -> LibraryItem {
        let downloaded = try await downloadRemoteImage(metadata)
        return try importImageData(downloaded.data, folder: folder, metadata: metadata, preferredExtension: downloaded.format)
    }

    func importRemoteResult(_ metadata: WebImageMetadata, folder: String) async throws -> LibraryImportResult {
        let downloaded = try await downloadRemoteImage(metadata)
        return try importImageDataResult(downloaded.data, folder: folder, metadata: metadata, preferredExtension: downloaded.format)
    }

    func downloadRemoteImage(_ metadata: WebImageMetadata) async throws -> (data: Data, format: String) {
        guard let url = URL(string: metadata.imageURL) else { throw LibraryImportError.invalidURL }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw LibraryImportError.unsupportedURLScheme
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 35)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.2", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if let source = metadata.sourceURL, let sourceURL = URL(string: source), ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") {
            request.setValue(source, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await remoteImageLoader(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LibraryImportError.serverStatus(http.statusCode)
        }
        if response.expectedContentLength > 80 * 1024 * 1024 || data.count > 80 * 1024 * 1024 {
            throw LibraryImportError.fileTooLarge
        }
        guard !data.isEmpty else { throw LibraryImportError.emptyResponse }
        guard NSImage(data: data) != nil else { throw LibraryImportError.unsupportedImage }

        let responseExtension = Self.extensionForMIMEType(response.mimeType)
        let urlExtension = Self.normalizedImageExtension(url.pathExtension)
        let format = responseExtension ?? Self.detectImageExtension(data: data) ?? urlExtension ?? "jpg"
        return (data, format)
    }

    /// Finds an existing asset that is either byte-identical or visually near-identical.
    /// This is intentionally a read-only preflight so the caller can ask before importing.
    func visualDuplicate(for data: Data) -> (item: LibraryItem, distance: Float)? {
        let digest = Self.exactDigest(data: data)
        if let index = exactDigestIndex()[digest] { return (items[index], 0) }
        return DuplicateScanner.mostSimilarItem(to: data, among: items, store: self)
    }

    /// Reuses the existing asset while merging the requested folder/source metadata.
    func reuseExistingItem(_ id: UUID, folder: String, metadata: WebImageMetadata?) -> LibraryImportResult? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let alreadyInFolder = Self.belongs(items[index], to: folder)
        if !alreadyInFolder, !folder.isEmpty {
            var memberships = items[index].additionalFolders ?? []
            if folder != items[index].folder, !memberships.contains(folder) { memberships.append(folder) }
            items[index].additionalFolders = memberships
        }
        items[index].isTrashed = false
        items[index].trashedAt = nil
        if items[index].sourceURL?.isEmpty != false { items[index].sourceURL = metadata?.sourceURL }
        if items[index].note.isEmpty { items[index].note = metadata?.pageTitle ?? "" }
        items[index].modifiedAt = Date()
        let item = items[index]
        if !alreadyInFolder, !folder.isEmpty { recordFolderImported(folder) }
        save()
        NotificationCenter.default.post(name: .libraryDidImportAsset, object: item)
        return LibraryImportResult(item: item, disposition: alreadyInFolder ? .alreadyInFolder : .addedToFolder)
    }

    /// Applies a user-confirmed visual duplicate decision. The oldest item in each
    /// group is retained and receives the other items' folders, tags and metadata.
    @discardableResult
    func mergeConfirmedDuplicateGroups(_ groups: [DuplicateGroup]) -> Int {
        var removed = 0
        for group in groups {
            let orderedIDs = group.items.sorted { $0.createdAt < $1.createdAt }.map(\.id)
            guard let keeperID = orderedIDs.first,
                  var keeperIndex = items.firstIndex(where: { $0.id == keeperID }) else { continue }
            for duplicateID in orderedIDs.dropFirst() {
                guard let duplicateIndex = items.firstIndex(where: { $0.id == duplicateID }) else { continue }
                let duplicate = items[duplicateIndex]
                Self.mergeMetadata(into: &items[keeperIndex], from: duplicate)
                // Preserve original bytes until the merged metadata is saved.
                items.remove(at: duplicateIndex)
                removed += 1
                guard let refreshed = items.firstIndex(where: { $0.id == keeperID }) else { break }
                keeperIndex = refreshed
            }
        }
        if removed > 0 {
            rebuildAISmartFolders(persist: false)
            save()
        }
        return removed
    }

    private static func belongs(_ item: LibraryItem, to folder: String) -> Bool {
        if folder.isEmpty { return item.folder.isEmpty }
        return item.folder == folder || (item.additionalFolders ?? []).contains(folder)
    }

    @discardableResult
    func importEagleLibrary(at sourceRoot: URL) throws -> Int {
        let didAccess = sourceRoot.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceRoot.stopAccessingSecurityScopedResource() } }
        let metadataURL = sourceRoot.appendingPathComponent("metadata.json")
        let imagesRoot = sourceRoot.appendingPathComponent("images", isDirectory: true)
        guard let rootData = try? Data(contentsOf: metadataURL),
              let root = try? JSONDecoder().decode(EagleRootRecord.self, from: rootData),
              fileManager.fileExists(atPath: imagesRoot.path) else {
            throw LibraryManagementError.invalidEagleLibrary
        }

        // Import is also the repair point for libraries created by older builds,
        // which could contain byte-for-byte duplicate assets.
        _ = consolidateExactDuplicates()

        var folderIDToName: [String: String] = [:]
        let flattened = Self.flattenEagleFolders(root.folders)
        for entry in flattened {
            let folder = entry.folder
            let displayName = entry.path
            folderIDToName[folder.id] = displayName
            if !folders.contains(displayName) { folders.append(displayName) }
            if let index = folderDetails.firstIndex(where: { $0.name == displayName }) {
                if folderDetails[index].note.isEmpty { folderDetails[index].note = folder.description }
                folderDetails[index].eagleID = folder.id
                folderDetails[index].parentEagleID = entry.parentID
                folderDetails[index].childEagleIDs = folder.children.map(\.id)
                folderDetails[index].tags = folder.tags
                folderDetails[index].password = folder.password
                folderDetails[index].passwordTips = folder.passwordTips
                folderDetails[index].modifiedAt = Self.date(milliseconds: folder.modificationTime)
            } else {
                folderDetails.append(FolderDetails(
                    name: displayName,
                    note: folder.description,
                    createdAt: Self.date(milliseconds: folder.modificationTime),
                    eagleID: folder.id,
                    parentEagleID: entry.parentID,
                    childEagleIDs: folder.children.map(\.id),
                    tags: folder.tags,
                    password: folder.password,
                    passwordTips: folder.passwordTips,
                    modifiedAt: Self.date(milliseconds: folder.modificationTime)
                ))
            }
        }

        let directories = try fileManager.contentsOfDirectory(
            at: imagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "info" }
        var digestToItemIndex = exactDigestIndex()
        var imported = 0
        for directory in directories {
            let itemMetadataURL = directory.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: itemMetadataURL),
                  let record = try? JSONDecoder().decode(EagleItemRecord.self, from: data),
                  !items.contains(where: { $0.eagleID == record.id }) else { continue }
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let original = files.first(where: {
                $0.lastPathComponent != "metadata.json" && !$0.deletingPathExtension().lastPathComponent.hasSuffix("_thumbnail")
            }) else { continue }

            let ext = Self.normalizedImageExtension(record.ext) ?? Self.normalizedImageExtension(original.pathExtension) ?? "jpg"
            let mappedFolders = record.folders.compactMap { folderIDToName[$0] }
            let id = UUID()
            var item = LibraryItem(
                id: id,
                name: record.name,
                note: record.annotation,
                width: record.width,
                height: record.height,
                storedFilename: nil,
                bundledResource: nil,
                fileSize: record.size,
                format: ext,
                folder: mappedFolders.first ?? "",
                sourceURL: record.url.nilIfEmpty,
                tags: record.tags,
                rating: 0,
                colorLabel: nil,
                createdAt: Self.date(milliseconds: record.btime),
                modifiedAt: Self.date(milliseconds: record.mtime),
                lastOpenedAt: nil,
                isTrashed: record.isDeleted,
                eagleID: record.id,
                additionalFolders: Array(mappedFolders.dropFirst()),
                palette: record.palettes,
                noThumbnail: record.noThumbnail,
                trashedAt: record.isDeleted ? Date() : nil
            )

            if let digest = Self.exactDigest(at: original),
               let existingIndex = digestToItemIndex[digest] {
                Self.mergeMetadata(into: &items[existingIndex], from: item)
                continue
            }

            let storedFilename = UUID().uuidString + "." + ext
            let destination = assetsURL.appendingPathComponent(storedFilename)
            try fileManager.copyItem(at: original, to: destination)
            if let thumbnail = files.first(where: { $0.deletingPathExtension().lastPathComponent.hasSuffix("_thumbnail") }),
               let image = NSImage(contentsOf: thumbnail) {
                try? makeThumbnail(from: image, at: thumbnailsURL.appendingPathComponent(id.uuidString + ".jpg"))
            } else if let image = NSImage(contentsOf: original) {
                try? makeThumbnail(from: image, at: thumbnailsURL.appendingPathComponent(id.uuidString + ".jpg"))
            }
            item.storedFilename = storedFilename
            if item.palette?.isEmpty != false {
                item.palette = ImagePaletteExtractor.extract(from: destination)
            }
            items.append(item)
            if let digest = Self.exactDigest(at: destination) { digestToItemIndex[digest] = items.count - 1 }
            imported += 1
        }

        let tagsData = try? Data(contentsOf: sourceRoot.appendingPathComponent("tags.json"))
        let savedFiltersData = try? Data(contentsOf: sourceRoot.appendingPathComponent("saved-filters.json"))
        eagleExtras = EagleLibraryExtras(
            metadataJSON: rootData,
            tagsJSON: tagsData,
            savedFiltersJSON: savedFiltersData,
            applicationVersion: root.applicationVersion
        )
        save()
        return imported
    }

    private func exactDigestIndex() -> [String: Int] {
        var result: [String: Int] = [:]
        for index in items.indices {
            guard let url = imageURL(for: items[index]),
                  let digest = Self.exactDigest(at: url),
                  result[digest] == nil else { continue }
            result[digest] = index
        }
        return result
    }

    @discardableResult
    private func consolidateExactDuplicates() -> Int {
        var working = items
        var keeperByDigest: [String: Int] = [:]
        var duplicateIndices: [Int] = []

        for index in working.indices {
            guard working[index].keepDuplicate != true else { continue }
            guard let url = imageURL(for: working[index]),
                  let digest = Self.exactDigest(at: url) else { continue }
            if let keeperIndex = keeperByDigest[digest] {
                Self.mergeMetadata(into: &working[keeperIndex], from: working[index])
                // Keep the old bytes for recovery until the merged index is durable.
                // Orphan cleanup must never precede a successful metadata save.
                duplicateIndices.append(index)
            } else {
                keeperByDigest[digest] = index
            }
        }

        for index in duplicateIndices.reversed() { working.remove(at: index) }
        if !duplicateIndices.isEmpty { items = working }
        return duplicateIndices.count
    }

    private func removeStoredFiles(for item: LibraryItem, preserving keeper: LibraryItem) {
        if let filename = item.storedFilename, filename != keeper.storedFilename {
            try? fileManager.removeItem(at: assetsURL.appendingPathComponent(filename))
        }
        try? fileManager.removeItem(at: thumbnailsURL.appendingPathComponent(item.id.uuidString + ".jpg"))
    }

    private static func mergeMetadata(into existing: inout LibraryItem, from incoming: LibraryItem) {
        let folders = orderedUnique(existing.allFolders + incoming.allFolders)
        if existing.folder.isEmpty { existing.folder = folders.first ?? "" }
        existing.additionalFolders = folders.filter { !$0.isEmpty && $0 != existing.folder }
        existing.tags = orderedUnique(existing.tags + incoming.tags)
        existing.aiTags = orderedUnique(existing.machineTags + incoming.machineTags)
        let references = orderedUnique(existing.allReferenceFolders + incoming.allReferenceFolders)
        if existing.referenceFolder?.isEmpty != false { existing.referenceFolder = references.first }
        existing.additionalReferenceFolders = references.filter { $0 != existing.referenceFolder }
        if existing.aiPrompt == nil { existing.aiPrompt = incoming.aiPrompt }
        let mergedChat = (existing.chatMessages + incoming.chatMessages)
            .reduce(into: [UUID: AIChatMessage]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.createdAt < $1.createdAt }
        if !mergedChat.isEmpty { existing.aiChatMessages = Array(mergedChat.suffix(200)) }
        if existing.aiGeneratedName == nil { existing.aiGeneratedName = incoming.aiGeneratedName }
        if existing.isManuallyNamed != true { existing.isManuallyNamed = incoming.isManuallyNamed }
        if existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { existing.name = incoming.name }
        if existing.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { existing.note = incoming.note }
        if existing.sourceURL?.isEmpty != false { existing.sourceURL = incoming.sourceURL }
        if existing.eagleID == nil { existing.eagleID = incoming.eagleID }
        if existing.width <= 0 { existing.width = incoming.width }
        if existing.height <= 0 { existing.height = incoming.height }
        existing.fileSize = max(existing.fileSize, incoming.fileSize)
        existing.rating = max(existing.rating, incoming.rating)
        if existing.colorLabel == nil { existing.colorLabel = incoming.colorLabel }
        if existing.palette?.isEmpty != false { existing.palette = incoming.palette }
        if existing.noThumbnail == nil { existing.noThumbnail = incoming.noThumbnail }
        existing.createdAt = min(existing.createdAt, incoming.createdAt)
        existing.modifiedAt = max(existing.modifiedAt, incoming.modifiedAt)
        if let incomingOpened = incoming.lastOpenedAt {
            existing.lastOpenedAt = max(existing.lastOpenedAt ?? .distantPast, incomingOpened)
        }
        existing.isTrashed = existing.isTrashed && incoming.isTrashed
        existing.trashedAt = existing.isTrashed
            ? min(existing.trashedAt ?? existing.modifiedAt, incoming.trashedAt ?? incoming.modifiedAt)
            : nil
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func exactDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return exactDigest(data: data)
    }

    private static func exactDigest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func exportEagleLibrary(to destinationRoot: URL) throws {
        let didAccess = destinationRoot.startAccessingSecurityScopedResource()
        defer { if didAccess { destinationRoot.stopAccessingSecurityScopedResource() } }
        if fileManager.fileExists(atPath: destinationRoot.path) {
            let values = try destinationRoot.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw LibraryManagementError.exportDestinationIsFile }
            let contents = (try? fileManager.contentsOfDirectory(atPath: destinationRoot.path)) ?? []
            guard contents.isEmpty else { throw LibraryManagementError.exportDestinationNotEmpty }
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let imagesRoot = destinationRoot.appendingPathComponent("images", isDirectory: true)
        try fileManager.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot.appendingPathComponent("backup", isDirectory: true), withIntermediateDirectories: true)

        for index in folderDetails.indices where folderDetails[index].eagleID == nil {
            folderDetails[index].eagleID = Self.makeEagleID()
        }
        var folderIDByName: [String: String] = [:]
        for details in folderDetails { folderIDByName[details.name] = details.eagleID ?? Self.makeEagleID() }
        let eagleFolders = Self.makeEagleFolderTree(details: folderDetails, orderedNames: folders)

        var mtimes: [String: Int64] = [:]
        var exportedCount = 0
        for index in items.indices {
            guard let source = imageURL(for: items[index]) else { continue }
            if items[index].eagleID == nil { items[index].eagleID = Self.makeEagleID() }
            let eagleID = items[index].eagleID ?? Self.makeEagleID()
            let infoDirectory = imagesRoot.appendingPathComponent(eagleID + ".info", isDirectory: true)
            try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
            let ext = Self.normalizedImageExtension(items[index].format) ?? Self.normalizedImageExtension(source.pathExtension) ?? "jpg"
            let safeName = Self.safeFilename(items[index].name)
            let exportedOriginal = infoDirectory.appendingPathComponent(safeName).appendingPathExtension(ext)
            try fileManager.copyItem(at: source, to: exportedOriginal)
            let thumbnailURL = infoDirectory.appendingPathComponent(safeName + "_thumbnail.png")
            let madeThumbnail = (try? Self.makeEagleThumbnail(from: source, at: thumbnailURL)) != nil
            let attributes = try fileManager.attributesOfItem(atPath: exportedOriginal.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? items[index].fileSize
            let btime = Self.milliseconds(items[index].createdAt)
            let mtime = Self.milliseconds(items[index].modifiedAt)
            let folderIDs = items[index].allFolders.compactMap { folderIDByName[$0] }
            let record = EagleItemRecord(
                id: eagleID,
                name: items[index].name,
                size: size,
                btime: btime,
                mtime: mtime,
                ext: ext,
                tags: items[index].tags,
                folders: folderIDs,
                isDeleted: items[index].isTrashed,
                url: items[index].sourceURL ?? "",
                annotation: items[index].note,
                modificationTime: mtime,
                height: items[index].height,
                width: items[index].width,
                lastModified: mtime,
                palettes: items[index].palette ?? [],
                noThumbnail: madeThumbnail ? nil : true
            )
            try Self.writeJSON(record, to: infoDirectory.appendingPathComponent("metadata.json"))
            mtimes[eagleID] = mtime
            exportedCount += 1
        }
        mtimes["all"] = Int64(exportedCount)

        let now = Self.milliseconds(Date())
        let root = EagleRootRecord(
            folders: eagleFolders,
            modificationTime: now,
            applicationVersion: eagleExtras?.applicationVersion ?? "4.0.0"
        )
        try Self.writeEagleRoot(root, preserved: eagleExtras?.metadataJSON, to: destinationRoot.appendingPathComponent("metadata.json"))
        let allTags = Array(Set(items.flatMap(\.tags))).sorted()
        try Self.writeEagleTags(eagleExtras?.tagsJSON, allTags: allTags, to: destinationRoot.appendingPathComponent("tags.json"))
        let fallbackFilters = try JSONSerialization.data(withJSONObject: [], options: [.prettyPrinted])
        try Self.writePreservedJSON(eagleExtras?.savedFiltersJSON, fallback: fallbackFilters, to: destinationRoot.appendingPathComponent("saved-filters.json"))
        let mtimeData = try JSONSerialization.data(withJSONObject: mtimes, options: [.prettyPrinted, .sortedKeys])
        try mtimeData.write(to: destinationRoot.appendingPathComponent("mtime.json"), options: .atomic)
        save()
    }

    func incomingDirectory() -> URL { incomingURL }

    func update(_ id: UUID, _ change: (inout LibraryItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasTrashed = items[index].isTrashed
        let previous = items[index]
        change(&items[index])
        let current = items[index]
        let now = Date()
        applyTrashTransition(at: index, wasTrashed: wasTrashed, now: now)
        items[index].modifiedAt = now
        save()
        recordFolderGains(Self.folderGains(from: previous, to: current))
    }

    func update(_ ids: Set<UUID>, _ change: (inout LibraryItem) -> Void) {
        guard !ids.isEmpty else { return }
        let now = Date()
        var gained: [String] = []
        for index in items.indices where ids.contains(items[index].id) {
            let wasTrashed = items[index].isTrashed
            let previous = items[index]
            change(&items[index])
            applyTrashTransition(at: index, wasTrashed: wasTrashed, now: now)
            items[index].modifiedAt = now
            gained.append(contentsOf: Self.folderGains(from: previous, to: items[index]))
        }
        save()
        recordFolderGains(gained)
    }

    private func applyTrashTransition(at index: Int, wasTrashed: Bool, now: Date) {
        if items[index].isTrashed {
            if !wasTrashed || items[index].trashedAt == nil { items[index].trashedAt = now }
        } else {
            items[index].trashedAt = nil
        }
    }

    /// Writes AI results and refreshes AI-maintained smart folders in one save.
    func updateAITags(_ id: UUID, tags: [String]) {
        updateAIAnalysis(id, tags: tags, prompt: nil, generatedName: nil)
    }

    func appendAIChatMessage(_ message: AIChatMessage, to itemID: UUID) {
        update(itemID) { item in
            var messages = item.chatMessages
            messages.append(message)
            item.aiChatMessages = Array(messages.suffix(200))
        }
    }

    func clearAIChat(for itemID: UUID) {
        update(itemID) { $0.aiChatMessages = [] }
    }

    /// Updates either half of AI analysis without overwriting an already-generated
    /// value that the current request was not responsible for.
    func updateAIAnalysis(_ id: UUID, tags: [String]?, prompt: String?, generatedName: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let tags { items[index].aiTags = tags }
        if let prompt { items[index].aiPrompt = prompt }
        if let generatedName, items[index].aiGeneratedName == nil {
            items[index].aiGeneratedName = generatedName
            if !items[index].hasManualName { items[index].name = generatedName }
        }
        items[index].modifiedAt = Date()
        rebuildAISmartFolders(persist: false)
        save()
    }

    /// Human naming is accepted only after the mandatory first AI naming pass.
    /// Once set, subsequent AI analysis can never replace this title.
    @discardableResult
    func updateManualName(_ id: UUID, name: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].hasCompletedAINaming else { return false }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        items[index].name = value
        items[index].isManuallyNamed = true
        items[index].modifiedAt = Date()
        save()
        return true
    }

    /// Creates virtual folders for the most common AI tags. Assets are referenced by
    /// rules, not copied or moved, so one image may safely appear in several groups.
    func rebuildAISmartFolders(minimumItemCount: Int = 3, maximumFolderCount: Int = 8) {
        rebuildAISmartFolders(
            minimumItemCount: minimumItemCount,
            maximumFolderCount: maximumFolderCount,
            persist: true
        )
    }

    private func rebuildAISmartFolders(
        minimumItemCount: Int = 3,
        maximumFolderCount: Int = 8,
        persist: Bool
    ) {
        struct Frequency {
            var displayName: String
            var itemIDs: Set<UUID>
        }

        var frequencies: [String: Frequency] = [:]
        for item in items where !item.isTrashed {
            var itemKeys: Set<String> = []
            for rawTag in item.machineTags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { continue }
                let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard itemKeys.insert(key).inserted else { continue }
                if frequencies[key] == nil {
                    frequencies[key] = Frequency(displayName: tag, itemIDs: [])
                }
                frequencies[key]?.itemIDs.insert(item.id)
            }
        }

        let desired = frequencies.values
            .filter { $0.itemIDs.count >= max(1, minimumItemCount) }
            .sorted {
                if $0.itemIDs.count != $1.itemIDs.count { return $0.itemIDs.count > $1.itemIDs.count }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            .prefix(max(0, maximumFolderCount))
            .map(\.displayName)

        let desiredKeys = Set(desired.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })
        // Two offline Macs can derive the same category independently. Keep
        // one stable identity instead of displaying duplicate AI folders.
        var generatedKeeper: [String: UUID] = [:]
        for folder in smartFolders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if let tag = folder.aiGeneratedTag {
                let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if generatedKeeper[key] == nil { generatedKeeper[key] = folder.id }
            }
        }
        smartFolders.removeAll { folder in
            guard let tag = folder.aiGeneratedTag else { return false }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !desiredKeys.contains(key) || generatedKeeper[key] != folder.id
        }

        for tag in desired {
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rule = SmartFolderRule(field: .aiTag, operation: .equals, value: tag)
            if let index = smartFolders.firstIndex(where: {
                guard let existing = $0.aiGeneratedTag else { return false }
                return existing.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
            }) {
                smartFolders[index].name = "AI · \(tag)"
                smartFolders[index].matchMode = .all
                var stableRule = rule
                stableRule.id = smartFolders[index].rules.first?.id ?? rule.id
                smartFolders[index].rules = [stableRule]
                smartFolders[index].aiGeneratedTag = tag
            } else {
                let hex = SHA256.hash(data: Data(("ai-folder/" + key).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
                let parts = [8, 4, 4, 4, 12]
                var offset = hex.startIndex
                let stableID = parts.map { length -> String in
                    let end = hex.index(offset, offsetBy: length)
                    defer { offset = end }
                    return String(hex[offset..<end])
                }.joined(separator: "-")
                var stableRule = rule
                stableRule.id = UUID(uuidString: stableID)!
                smartFolders.append(SmartFolder(
                    id: UUID(uuidString: stableID)!,
                    name: "AI · \(tag)",
                    matchMode: .all,
                    rules: [stableRule],
                    aiGeneratedTag: tag
                ))
            }
        }
        if persist { save() }
    }

    func markOpened(_ id: UUID) { update(id) { $0.lastOpenedAt = Date() } }

    /// Backfills palettes for legacy assets and Eagle records that did not contain one.
    func ensurePalette(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }),
              item.palette?.isEmpty != false,
              let url = imageURL(for: item) else { return }
        let palette = await Task.detached(priority: .utility) {
            ImagePaletteExtractor.extract(from: url)
        }.value
        guard !palette.isEmpty,
              let index = items.firstIndex(where: { $0.id == id }),
              items[index].palette?.isEmpty != false else { return }
        items[index].palette = palette
        save()
    }

    /// Adds assets to a folder without removing any of their existing folder memberships.
    /// Uncategorized assets use the destination as their primary folder; categorized assets
    /// receive it as an additional folder, matching Eagle's multi-folder behavior.
    @discardableResult
    func addToFolder(_ ids: Set<UUID>, folder: String) -> Int {
        let destination = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ids.isEmpty, folders.contains(destination) else { return 0 }

        var changedCount = 0
        for index in items.indices where ids.contains(items[index].id) {
            var changed = false
            if !items[index].allFolders.contains(destination) {
                if items[index].folder.isEmpty {
                    items[index].folder = destination
                } else {
                    var additional = items[index].additionalFolders ?? []
                    additional.append(destination)
                    items[index].additionalFolders = additional.uniqued()
                }
                changed = true
            }
            if items[index].isTrashed {
                items[index].isTrashed = false
                items[index].trashedAt = nil
                changed = true
            }
            if changed {
                items[index].modifiedAt = Date()
                changedCount += 1
            }
        }
        if changedCount > 0 {
            recordFolderImported(destination)
            save()
        }
        return changedCount
    }

    func move(_ id: UUID, to folder: String) {
        update(id) { $0.folder = folder; $0.additionalFolders = []; $0.isTrashed = false }
    }

    func assignReferenceFolder(_ id: UUID, to folder: String?) {
        let resolved = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.referenceFolder = resolved?.isEmpty == false ? resolved : nil; $0.additionalReferenceFolders = [] }
    }
    func trash(_ id: UUID) {
        update(id) { $0.isTrashed = true }
        rebuildAISmartFolders()
    }
    func restore(_ id: UUID) {
        update(id) { $0.isTrashed = false }
        rebuildAISmartFolders()
    }

    @discardableResult
    func purgeExpiredTrash(retentionDays: Int? = nil, now: Date = Date()) -> Int {
        let days = TrashRetentionPolicy.normalizedDays(retentionDays ?? configuredTrashRetentionDays)
        let expiredIDs = Set(items.compactMap { item -> UUID? in
            guard item.isTrashed, let trashedAt = item.trashedAt else { return nil }
            return TrashRetentionPolicy.isExpired(
                trashedAt: trashedAt,
                retentionDays: days,
                now: now
            ) ? item.id : nil
        })
        guard !expiredIDs.isEmpty else { return 0 }
        permanentlyDelete(expiredIDs)
        return expiredIDs.count
    }

    func permanentlyDelete(_ id: UUID) {
        permanentlyDelete([id])
    }

    func permanentlyDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            if let filename = item.storedFilename,
               !items.contains(where: { !ids.contains($0.id) && $0.storedFilename == filename }) {
                try? fileManager.removeItem(at: assetsURL.appendingPathComponent(filename))
            }
            try? fileManager.removeItem(at: thumbnailsURL.appendingPathComponent(item.id.uuidString + ".jpg"))
        }
        items.removeAll { ids.contains($0.id) }
        rebuildAISmartFolders(persist: false)
        save()
    }

    func addFolder(named proposedName: String = "新建文件夹") -> String {
        var name = proposedName
        var suffix = 2
        while folders.contains(name) { name = "\(proposedName) \(suffix)"; suffix += 1 }
        folders.append(name)
        folderDetails.append(FolderDetails(name: name))
        save()
        return name
    }

    func addReferenceFolder(named proposedName: String = "新建参考文件夹") -> String {
        var name = proposedName
        var suffix = 2
        while referenceFolders.contains(name) { name = "\(proposedName) \(suffix)"; suffix += 1 }
        referenceFolders.append(name)
        save()
        return name
    }

    @discardableResult
    func renameReferenceFolder(_ oldName: String, to proposedName: String) -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = referenceFolders.firstIndex(of: oldName) else { return oldName }
        if name != oldName, referenceFolders.contains(name) { return oldName }
        referenceFolders[index] = name
        for itemIndex in items.indices where items[itemIndex].allReferenceFolders.contains(oldName) {
            if items[itemIndex].referenceFolder == oldName { items[itemIndex].referenceFolder = name }
            items[itemIndex].additionalReferenceFolders = items[itemIndex].additionalReferenceFolders?.map { $0 == oldName ? name : $0 }
        }
        if lastSelection == .referenceFolder(oldName) { lastSelection = .referenceFolder(name) }
        save()
        return name
    }

    func deleteReferenceFolder(_ name: String) {
        referenceFolders.removeAll { $0 == name }
        for index in items.indices where items[index].allReferenceFolders.contains(name) {
            if items[index].referenceFolder == name { items[index].referenceFolder = nil }
            items[index].additionalReferenceFolders?.removeAll { $0 == name }
        }
        if lastSelection == .referenceFolder(name) { lastSelection = .section(.all) }
        save()
    }

    @discardableResult
    func renameFolder(_ oldName: String, to proposedName: String) -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(of: oldName) else { return oldName }
        if name != oldName, folders.contains(name) { return oldName }
        folders[index] = name
        if let detailsIndex = folderDetails.firstIndex(where: { $0.name == oldName }) {
            folderDetails[detailsIndex].name = name
        }
        for itemIndex in items.indices where items[itemIndex].folder == oldName { items[itemIndex].folder = name }
        for itemIndex in items.indices {
            items[itemIndex].additionalFolders = items[itemIndex].additionalFolders?.map { $0 == oldName ? name : $0 }
        }
        if lastSelection == .folder(oldName) { lastSelection = .folder(name) }
        folderUsage.rename(oldName, to: name)
        persistFolderUsage()
        save()
        return name
    }

    func deleteFolder(_ name: String) {
        folders.removeAll { $0 == name }
        folderDetails.removeAll { $0.name == name }
        for index in items.indices where items[index].folder == name { items[index].folder = "" }
        for index in items.indices { items[index].additionalFolders?.removeAll { $0 == name } }
        if lastSelection == .folder(name) { lastSelection = .section(.uncategorized) }
        folderUsage.remove(name)
        persistFolderUsage()
        save()
    }

    /// Reorders reference folders independently from style folders.
    @discardableResult
    func reorderReferenceFolder(_ draggedFolder: String, over targetFolder: String) -> Bool {
        guard draggedFolder != targetFolder,
              let sourceIndex = referenceFolders.firstIndex(of: draggedFolder),
              let targetIndex = referenceFolders.firstIndex(of: targetFolder) else { return false }

        let folder = referenceFolders.remove(at: sourceIndex)
        referenceFolders.insert(folder, at: min(targetIndex, referenceFolders.count))
        save()
        return true
    }

    /// Reorders a folder when its sidebar drag enters another folder row.
    /// The target row becomes the insertion point, matching native macOS list reordering.
    @discardableResult
    func reorderFolder(_ draggedFolder: String, over targetFolder: String) -> Bool {
        guard draggedFolder != targetFolder,
              let sourceIndex = folders.firstIndex(of: draggedFolder),
              let targetIndex = folders.firstIndex(of: targetFolder) else { return false }

        let folder = folders.remove(at: sourceIndex)
        folders.insert(folder, at: min(targetIndex, folders.count))

        let detailsByName = Dictionary(uniqueKeysWithValues: folderDetails.map { ($0.name, $0) })
        folderDetails = folders.compactMap { detailsByName[$0] }
        save()
        return true
    }

    // MARK: - 文件夹使用频次（只影响采集框里的排序）

    /// 采集框里文件夹的显示顺序：常用的排在前面。
    ///
    /// 侧栏仍然使用 `folders` 的手动顺序，两者互不影响。没有使用记录时，
    /// 这里返回的就是原始的手动顺序。
    var foldersByUsage: [String] {
        FolderUsageLedger.ordered(folders, by: folderUsage)
    }

    func usageScore(for folder: String) -> Int { folderUsage.score(for: folder) }

    /// 进入文件夹算一次使用。
    func recordFolderOpened(_ folder: String) {
        recordFolderUsage(folder, weight: FolderUsageLedger.openedWeight)
    }

    /// 把素材放进文件夹算一次使用。
    func recordFolderImported(_ folder: String) {
        recordFolderUsage(folder, weight: FolderUsageLedger.importedWeight)
    }

    private func recordFolderUsage(_ folder: String, weight: Int) {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, folders.contains(name) else { return }
        folderUsage.record(name, weight: weight)
        persistFolderUsage()
    }

    /// 一次批量操作里新增的文件夹归属，每个文件夹只计一次分，
    /// 避免一次拖入几十张素材就把某个文件夹直接顶到最前。
    private func recordFolderGains(_ gained: [String]) {
        for folder in Set(gained) { recordFolderUsage(folder, weight: FolderUsageLedger.importedWeight) }
    }

    private static func folderGains(from previous: LibraryItem, to current: LibraryItem) -> [String] {
        let before = Set(previous.allFolders)
        return current.allFolders.filter { !before.contains($0) }
    }

    private func persistFolderUsage() {
        guard let folderUsageDefaults,
              let data = try? JSONEncoder().encode(folderUsage) else { return }
        folderUsageDefaults.set(data, forKey: folderUsageKey)
    }

    private func restoreFolderUsage() {
        if let folderUsageDefaults,
           let data = folderUsageDefaults.data(forKey: folderUsageKey),
           let ledger = try? JSONDecoder().decode(FolderUsageLedger.self, from: data) {
            folderUsage = ledger
        }
        folderUsage.prune(keeping: Set(folders))
    }

    private static func folderUsageStorageKey(for libraryURL: URL) -> String {
        let digest = SHA256.hash(data: Data(libraryURL.standardizedFileURL.path.utf8))
        return "EagleReplica.folderUsage." + digest.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func addSmartFolder(_ smartFolder: SmartFolder) -> SmartFolder {
        var folder = smartFolder
        if folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { folder.name = "新建智能文件夹" }
        smartFolders.append(folder)
        save()
        return folder
    }

    func updateSmartFolder(_ smartFolder: SmartFolder) {
        guard let index = smartFolders.firstIndex(where: { $0.id == smartFolder.id }) else { return }
        smartFolders[index] = smartFolder
        save()
    }

    func deleteSmartFolder(_ id: UUID) {
        smartFolders.removeAll { $0.id == id }
        if lastSelection == .smartFolder(id) { lastSelection = .section(.all) }
        save()
    }

    func reveal(_ item: LibraryItem) {
        guard let url = imageURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reveal(_ items: [LibraryItem]) {
        let urls = items.compactMap { imageURL(for: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openSource(_ item: LibraryItem) {
        guard let raw = item.sourceURL, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    func rememberSelection(_ selection: SidebarSelection) {
        if case .folder(let folder) = selection { recordFolderOpened(folder) }
        guard selection != lastSelection else { return }
        lastSelection = selection
        save()
    }

    private func configureRoot(_ url: URL) {
        rootURL = url
        libraryURL = url
        assetsURL = url.appendingPathComponent("assets", isDirectory: true)
        thumbnailsURL = url.appendingPathComponent("thumbnails", isDirectory: true)
        incomingURL = url.appendingPathComponent("incoming", isDirectory: true)
        indexURL = url.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: incomingURL, withIntermediateDirectories: true)
    }

    private func restoreRecentLibraries() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.recentLibraryPathsKey) ?? []
        let urls = saved.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("index.json").path) }
        recentLibraryURLs = [libraryURL] + urls.filter { $0 != libraryURL }
        if recentLibraryURLs.count > 8 { recentLibraryURLs = Array(recentLibraryURLs.prefix(8)) }
    }

    private func rememberActiveLibrary() {
        guard persistsLibrarySelection else { return }
        UserDefaults.standard.set(libraryURL.path, forKey: Self.activeLibraryPathKey)
        recentLibraryURLs.removeAll { $0.standardizedFileURL == libraryURL.standardizedFileURL }
        recentLibraryURLs.insert(libraryURL, at: 0)
        if recentLibraryURLs.count > 8 { recentLibraryURLs = Array(recentLibraryURLs.prefix(8)) }
        UserDefaults.standard.set(recentLibraryURLs.map(\.path), forKey: Self.recentLibraryPathsKey)
    }

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder.library.decode(LibraryIndex.self, from: data) {
            folders = index.folders
            referenceFolders = index.referenceFolders ?? []
            favoriteStyles = index.favoriteStyles ?? Array(StyleFavoritesStorage.decode(
                UserDefaults.standard.string(forKey: "EagleReplica.styleLibrary.favoriteStyles") ?? "[]"
            )).sorted()
            items = index.items
            smartFolders = index.smartFolders ?? []
            eagleExtras = index.eagleExtras
            let persistedDetails = index.folderDetails ?? []
            folderDetails = folders.map { folder in
                persistedDetails.first(where: { $0.name == folder }) ?? FolderDetails(name: folder)
            }
            lastSelection = validatedSelection(index.lastSelection)
        } else {
            folders = ["照片素材", "文字设计", "配色", "插画设计", "油画风", "拼贴画"]
            referenceFolders = []
            favoriteStyles = []
            folderDetails = folders.map { FolderDetails(name: $0) }
            eagleExtras = nil
            seedExamples()
            save()
        }
        performExactDuplicateMigrationIfNeeded()
        normalizeAndPurgeTrash()
        rebuildAISmartFolders(persist: true)
    }

    private func normalizeAndPurgeTrash(now: Date = Date()) {
        var changed = false
        for index in items.indices {
            if items[index].isTrashed, items[index].trashedAt == nil {
                // Legacy indexes did not record a trash-entry date. Grant them
                // a full retention window instead of deleting on upgrade.
                items[index].trashedAt = now
                changed = true
            } else if !items[index].isTrashed, items[index].trashedAt != nil {
                items[index].trashedAt = nil
                changed = true
            }
        }
        let removed = purgeExpiredTrash(now: now)
        if changed, removed == 0 { save() }
    }

    private func performExactDuplicateMigrationIfNeeded() {
        let marker = rootURL.appendingPathComponent(Self.exactDedupMigrationFilename)
        checkExactDuplicates()
        _ = fileManager.createFile(atPath: marker.path, contents: Data())
    }

    @discardableResult
    func checkExactDuplicates() -> Int {
        let removed = consolidateExactDuplicates()
        duplicateStatus = removed > 0 ? "已合并 \(removed) 张完全重复的素材，并保留分类与标签" : "检查完成，没有完全重复的素材"
        if removed > 0 { save() }
        return removed
    }

    func setFavoriteStyles(_ names: [String]) {
        favoriteStyles = Array(Set(names)).sorted()
        save()
    }

    func syncSnapshot() throws -> Data {
        try JSONEncoder.library.encode(LibraryIndex(
            folders: folders, referenceFolders: referenceFolders, items: items,
            smartFolders: smartFolders, folderDetails: folderDetails,
            lastSelection: lastSelection, eagleExtras: eagleExtras, favoriteStyles: favoriteStyles
        ))
    }

    func applySyncSnapshot(_ data: Data) throws {
        var index = try JSONDecoder.library.decode(LibraryIndex.self, from: data)
        index.lastSelection = lastSelection
        let encoded = try JSONEncoder.library.encode(index)
        let current = try syncSnapshot()
        guard current != encoded else { return }
        let backup = rootURL.appendingPathComponent("sync-backups", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        try current.write(to: backup.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        try encoded.write(to: indexURL, options: .atomic)
        load()
        saveRevision += 1
    }

    private func seedExamples() {
        let resources = ["poster-1", "poster-2", "poster-3", "poster-4"]
        let names = ["收藏到 Arata Art", "收藏到 Arata Art", "收藏到 Arata Art", "Pinterest"]
        let dimensions = [(960, 1200), (1050, 1421), (1080, 1421), (736, 1029)]
        items = resources.indices.map { index in
            LibraryItem(
                id: UUID(), name: names[index], note: "", width: dimensions[index].0, height: dimensions[index].1,
                storedFilename: nil, bundledResource: resources[index], fileSize: 0, format: "jpg",
                folder: "文字设计", sourceURL: nil, tags: [], rating: 0, colorLabel: nil,
                createdAt: Date().addingTimeInterval(TimeInterval(-index * 60)), modifiedAt: Date(),
                lastOpenedAt: nil, isTrashed: false
            )
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.library.encode(LibraryIndex(
            folders: folders,
            referenceFolders: referenceFolders,
            items: items,
            smartFolders: smartFolders,
            folderDetails: folderDetails,
            lastSelection: lastSelection,
            eagleExtras: eagleExtras,
            favoriteStyles: favoriteStyles
        )) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
            saveRevision += 1
            NotificationCenter.default.post(name: .libraryDidSave, object: self)
        } catch {
            duplicateStatus = "资源库保存失败：\(error.localizedDescription)"
        }
    }

    private func validatedSelection(_ selection: SidebarSelection?) -> SidebarSelection {
        guard let selection else { return folders.contains("文字设计") ? .folder("文字设计") : .section(.all) }
        switch selection {
        case .section:
            return selection
        case .folder(let folder):
            return folders.contains(folder) ? selection : .section(.all)
        case .referenceFolder(let folder):
            return referenceFolders.contains(folder) ? selection : .section(.all)
        case .smartFolder(let id):
            return smartFolders.contains(where: { $0.id == id }) ? selection : .section(.all)
        case .tag(let tag):
            return items.contains(where: { !$0.isTrashed && $0.tags.contains(tag) }) ? selection : .section(.tags)
        }
    }

    private static func flattenEagleFolders(
        _ folders: [EagleFolderRecord],
        parentID: String? = nil,
        parentPath: String? = nil
    ) -> [FlattenedEagleFolder] {
        folders.flatMap { folder in
            let path = parentPath.map { "\($0) / \(folder.name)" } ?? folder.name
            return [FlattenedEagleFolder(folder: folder, parentID: parentID, path: path)]
                + flattenEagleFolders(folder.children, parentID: folder.id, parentPath: path)
        }
    }

    private static func makeEagleFolderTree(details: [FolderDetails], orderedNames: [String]) -> [EagleFolderRecord] {
        let knownIDs = Set(details.compactMap(\.eagleID))
        func children(of parentID: String?) -> [EagleFolderRecord] {
            orderedNames.compactMap { name in
                guard let detail = details.first(where: { $0.name == name }) else { return nil }
                let effectiveParent = detail.parentEagleID.flatMap { knownIDs.contains($0) ? $0 : nil }
                guard effectiveParent == parentID else { return nil }
                let id = detail.eagleID ?? makeEagleID()
                return EagleFolderRecord(
                    id: id,
                    name: name.components(separatedBy: " / ").last ?? name,
                    description: detail.note,
                    children: children(of: id),
                    modificationTime: milliseconds(detail.modifiedAt ?? detail.createdAt),
                    tags: detail.tags ?? [],
                    password: detail.password ?? "",
                    passwordTips: detail.passwordTips ?? ""
                )
            }
        }
        return children(of: nil)
    }

    private static func makeEagleID() -> String {
        "M" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    }

    private static func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\u{0}")
        let components = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let resolved = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? "未命名素材" : String(resolved.prefix(180))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func makeEagleThumbnail(from source: URL, at destination: URL) throws {
        guard let image = NSImage(contentsOf: source) else { throw CocoaError(.fileReadCorruptFile) }
        let maxSide: CGFloat = 640
        let ratio = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: destination, options: .atomic)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func writeEagleRoot(_ root: EagleRootRecord, preserved: Data?, to url: URL) throws {
        let generatedData = try JSONEncoder().encode(root)
        guard let generated = try JSONSerialization.jsonObject(with: generatedData) as? [String: Any] else {
            throw CocoaError(.fileWriteUnknown)
        }
        var output = (preserved.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        for (key, value) in generated { output[key] = value }
        if output["smartFolders"] == nil { output["smartFolders"] = [] }
        if output["quickAccess"] == nil { output["quickAccess"] = [] }
        if output["tagsGroups"] == nil { output["tagsGroups"] = [] }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func writeEagleTags(_ preserved: Data?, allTags: [String], to url: URL) throws {
        var output = (preserved.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let preservedHistory = output["historyTags"] as? [String] ?? []
        output["historyTags"] = Array(Set(preservedHistory + allTags)).sorted()
        if output["starredTags"] == nil { output["starredTags"] = [] }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func writePreservedJSON(_ preserved: Data?, fallback: Data, to url: URL) throws {
        let data: Data
        if let preserved, (try? JSONSerialization.jsonObject(with: preserved)) != nil {
            data = preserved
        } else {
            data = fallback
        }
        try data.write(to: url, options: .atomic)
    }

    private func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        let rep = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        return (max(1, rep?.pixelsWide ?? Int(image.size.width)), max(1, rep?.pixelsHigh ?? Int(image.size.height)))
    }

    private func makeThumbnail(from image: NSImage, at url: URL) throws {
        let maxSide: CGFloat = 720
        let ratio = min(1, maxSide / max(image.size.width, image.size.height))
        let target = NSSize(width: max(1, image.size.width * ratio), height: max(1, image.size.height * ratio))
        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        thumbnail.unlockFocus()
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try jpeg.write(to: url, options: .atomic)
    }

    nonisolated static func normalizedImageExtension(_ value: String?) -> String? {
        guard var value = value?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix(".") { value.removeFirst() }
        if value == "jpeg" { value = "jpg" }
        let allowed = ["jpg", "png", "gif", "webp", "tif", "tiff", "heic", "heif", "avif", "bmp"]
        return allowed.contains(value) ? value : nil
    }

    nonisolated static func extensionForMIMEType(_ mimeType: String?) -> String? {
        switch mimeType?.lowercased().split(separator: ";").first.map(String.init) {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/tiff": "tiff"
        case "image/heic", "image/heif": "heic"
        case "image/avif": "avif"
        case "image/bmp": "bmp"
        default: nil
        }
    }

    nonisolated static func detectImageExtension(data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if bytes.starts(with: [0x42, 0x4D]) { return "bmp" }
        return nil
    }

    var tutorialImageURL: URL? {
        resourceBundle.url(forResource: "tutorial-orange", withExtension: "png")
    }

    @discardableResult
    func importTutorialImage() throws -> LibraryImportResult {
        guard let url = tutorialImageURL else { throw CocoaError(.fileNoSuchFile) }
        return try importFileResult(at: url, folder: "")
    }

    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }
}

private struct EagleRootRecord: Codable {
    var folders: [EagleFolderRecord]
    var modificationTime: Int64
    var applicationVersion: String

    private enum CodingKeys: String, CodingKey { case folders, modificationTime, applicationVersion }

    init(folders: [EagleFolderRecord], modificationTime: Int64, applicationVersion: String) {
        self.folders = folders
        self.modificationTime = modificationTime
        self.applicationVersion = applicationVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folders = try values.decodeIfPresent([EagleFolderRecord].self, forKey: .folders) ?? []
        modificationTime = try values.decodeIfPresent(Int64.self, forKey: .modificationTime) ?? 0
        applicationVersion = try values.decodeIfPresent(String.self, forKey: .applicationVersion) ?? ""
    }
}

private struct EagleFolderRecord: Codable {
    var id: String
    var name: String
    var description: String
    var children: [EagleFolderRecord]
    var modificationTime: Int64
    var tags: [String]
    var password: String
    var passwordTips: String

    private enum CodingKeys: String, CodingKey {
        case id, name, description, children, modificationTime, tags, password, passwordTips
    }

    init(
        id: String,
        name: String,
        description: String,
        children: [EagleFolderRecord],
        modificationTime: Int64,
        tags: [String],
        password: String,
        passwordTips: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.children = children
        self.modificationTime = modificationTime
        self.tags = tags
        self.password = password
        self.passwordTips = passwordTips
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "未命名文件夹"
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        children = try values.decodeIfPresent([EagleFolderRecord].self, forKey: .children) ?? []
        modificationTime = try values.decodeIfPresent(Int64.self, forKey: .modificationTime) ?? 0
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        passwordTips = try values.decodeIfPresent(String.self, forKey: .passwordTips) ?? ""
    }
}

private struct EagleItemRecord: Codable {
    var id: String
    var name: String
    var size: Int64
    var btime: Int64
    var mtime: Int64
    var ext: String
    var tags: [String]
    var folders: [String]
    var isDeleted: Bool
    var url: String
    var annotation: String
    var modificationTime: Int64
    var height: Int
    var width: Int
    var lastModified: Int64
    var palettes: [AssetPaletteColor]
    var noThumbnail: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, size, btime, mtime, ext, tags, folders, isDeleted, url, annotation
        case modificationTime, height, width, lastModified, palettes, noThumbnail
    }

    init(
        id: String, name: String, size: Int64, btime: Int64, mtime: Int64, ext: String,
        tags: [String], folders: [String], isDeleted: Bool, url: String, annotation: String,
        modificationTime: Int64, height: Int, width: Int, lastModified: Int64,
        palettes: [AssetPaletteColor], noThumbnail: Bool?
    ) {
        self.id = id; self.name = name; self.size = size; self.btime = btime; self.mtime = mtime
        self.ext = ext; self.tags = tags; self.folders = folders; self.isDeleted = isDeleted
        self.url = url; self.annotation = annotation; self.modificationTime = modificationTime
        self.height = height; self.width = width; self.lastModified = lastModified
        self.palettes = palettes; self.noThumbnail = noThumbnail
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "未命名素材"
        size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        btime = try values.decodeIfPresent(Int64.self, forKey: .btime) ?? 0
        mtime = try values.decodeIfPresent(Int64.self, forKey: .mtime) ?? btime
        ext = try values.decodeIfPresent(String.self, forKey: .ext) ?? ""
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
        isDeleted = try values.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        annotation = try values.decodeIfPresent(String.self, forKey: .annotation) ?? ""
        modificationTime = try values.decodeIfPresent(Int64.self, forKey: .modificationTime) ?? mtime
        height = try values.decodeIfPresent(Int.self, forKey: .height) ?? 0
        width = try values.decodeIfPresent(Int.self, forKey: .width) ?? 0
        lastModified = try values.decodeIfPresent(Int64.self, forKey: .lastModified) ?? mtime
        palettes = try values.decodeIfPresent([AssetPaletteColor].self, forKey: .palettes) ?? []
        noThumbnail = try values.decodeIfPresent(Bool.self, forKey: .noThumbnail)
    }
}

private struct FlattenedEagleFolder {
    var folder: EagleFolderRecord
    var parentID: String?
    var path: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
}

private extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
