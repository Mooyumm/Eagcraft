import AppKit
import Combine
import CryptoKit
import Foundation

/// A field-level last-writer-wins map. Lamport revisions avoid relying on the
/// clocks of two Macs. Deletions remain as tombstones, so an offline Mac cannot
/// recreate an item merely by uploading its old copy of the library.
nonisolated struct LibrarySyncState: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var revision: UInt64
        var writer: String
        var value: Data?
    }
    var schema = 1
    var entries: [String: Entry] = [:]

    mutating func record(_ current: [String: Data], comparedTo baseline: [String: Data], writer: String) {
        let changed = Set(current.keys).union(baseline.keys).filter { current[$0] != baseline[$0] }
        guard !changed.isEmpty else { return }
        let revision = (entries.values.map(\.revision).max() ?? 0) + 1
        for key in changed { entries[key] = Entry(revision: revision, writer: writer, value: current[key]) }
    }

    mutating func merge(_ other: Self) {
        for (key, candidate) in other.entries {
            if let existing = entries[key],
               existing.revision > candidate.revision ||
                (existing.revision == candidate.revision && existing.writer >= candidate.writer) { continue }
            entries[key] = candidate
        }
    }

    var values: [String: Data] { entries.compactMapValues(\.value) }
}

nonisolated enum LibrarySyncCodec {
    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    static func token(_ string: String) -> String { Data(string.utf8).base64EncodedString() }

    static func flatten(_ data: Data) throws -> [String: Data] {
        guard let index = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var result: [String: Data] = [:]
        for collection in ["folders", "referenceFolders", "favoriteStyles"] {
            result[collection + "Order"] = try encode(index[collection] as? [String] ?? [])
            for name in index[collection] as? [String] ?? [] {
                result[collection + "/" + token(name)] = try encode(name)
            }
        }
        for collection in ["items", "smartFolders", "folderDetails"] {
            for object in index[collection] as? [[String: Any]] ?? [] {
                guard let id = object[collection == "folderDetails" ? "name" : "id"] as? String else { continue }
                let prefix = collection + "/" + token(id) + "/"
                result[prefix + "exists"] = try encode(true)
                for (field, value) in object {
                    if field == "aiChatMessages", let messages = value as? [[String: Any]] {
                        for message in messages {
                            if let messageID = message["id"] as? String {
                                result[prefix + "chat/" + messageID] = try encode(message)
                            }
                        }
                    } else {
                        result[prefix + "field/" + field] = try encode(value)
                    }
                }
            }
        }
        if let extras = index["eagleExtras"] { result["eagleExtras"] = try encode(extras) }
        return result
    }

    static func expand(_ values: [String: Data]) throws -> Data {
        var index: [String: Any] = [:]
        for collection in ["folders", "referenceFolders", "favoriteStyles"] {
            let names = try values.keys.sorted().filter { $0.hasPrefix(collection + "/") }.map {
                try JSONSerialization.jsonObject(with: values[$0]!, options: .fragmentsAllowed)
            } as? [String] ?? []
            let order = try values[collection + "Order"].map { try JSONSerialization.jsonObject(with: $0) as? [String] ?? [] } ?? []
            index[collection] = order.filter { names.contains($0) } + names.filter { !order.contains($0) }
        }
        for collection in ["items", "smartFolders", "folderDetails"] {
            let roots = values.keys.filter { $0.hasPrefix(collection + "/") && $0.hasSuffix("/exists") }.sorted()
            var objects: [[String: Any]] = []
            for root in roots {
                let prefix = String(root.dropLast("exists".count))
                var object: [String: Any] = [:]
                var chat: [[String: Any]] = []
                for key in values.keys where key.hasPrefix(prefix) {
                    let suffix = String(key.dropFirst(prefix.count))
                    let value = try JSONSerialization.jsonObject(with: values[key]!, options: .fragmentsAllowed)
                    if suffix.hasPrefix("field/") { object[String(suffix.dropFirst(6))] = value }
                    if suffix.hasPrefix("chat/"), let message = value as? [String: Any] { chat.append(message) }
                }
                if !chat.isEmpty {
                    object["aiChatMessages"] = chat.sorted {
                        ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "")
                    }
                }
                objects.append(object)
            }
            index[collection] = objects
        }
        if let extras = values["eagleExtras"] { index["eagleExtras"] = try JSONSerialization.jsonObject(with: extras) }
        return try encode(index)
    }
}

nonisolated enum LibrarySyncError: LocalizedError {
    case waiting(String)
    case invalidAsset
    case unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .waiting(let name): "正在等待 iCloud 下载 \(name)，稍后会自动重试"
        case .invalidAsset: "同步文件校验失败，已保留本地资源库，请稍后重试"
        case .unsupportedVersion: "此共享库由更新版本创建，请先更新灵感库"
        }
    }
}

/// Runs off the main actor. Each installation publishes its own state file;
/// no two computers ever overwrite a shared index.json.
nonisolated enum LibrarySyncDisk {
    struct Result: Sendable {
        var state: LibrarySyncState
        var index: Data
    }

    static func read(_ url: URL) throws -> Data {
        let resources = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if resources?.isUbiquitousItem == true,
           resources?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw LibrarySyncError.waiting(url.lastPathComponent)
        }
        var result: Swift.Result<Data, Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Swift.Result { try Data(contentsOf: coordinated) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func write(_ data: Data, to url: URL) throws {
        var failure: Error?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { coordinated in
            do { try data.write(to: coordinated, options: .atomic) } catch { failure = error }
        }
        if let error { throw error }
        if let failure { throw failure }
    }

    static func exchange(indexData: Data, assetURLs: [String: URL], localRoot: URL, cloudRoot: URL,
                         writer: String, previous: LibrarySyncState, baseline: [String: Data]) throws -> Result {
        let fm = FileManager.default
        let cloudAssets = cloudRoot.appendingPathComponent("assets")
        let devices = cloudRoot.appendingPathComponent("devices")
        try fm.createDirectory(at: cloudAssets, withIntermediateDirectories: true)
        try fm.createDirectory(at: devices, withIntermediateDirectories: true)
        guard var index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              var items = index["items"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        // Assets are immutable and addressed by content, including bundled demo images.
        for i in items.indices {
            guard let id = items[i]["id"] as? String, let source = assetURLs[id] else { throw LibrarySyncError.invalidAsset }
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let ext = source.pathExtension.lowercased().filter { $0.isASCII && $0.isLetter || $0.isNumber }
            let filename = digest + "." + (ext.isEmpty ? "img" : ext)
            let destination = cloudAssets.appendingPathComponent(filename)
            if !fm.fileExists(atPath: destination.path) { try write(data, to: destination) }
            items[i]["storedFilename"] = filename
            items[i].removeValue(forKey: "bundledResource")
        }
        index["items"] = items
        let local = try LibrarySyncCodec.flatten(LibrarySyncCodec.encode(index))
        var state = previous
        state.record(local, comparedTo: baseline, writer: writer)
        let deviceURLs = try fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)
        for url in deviceURLs {
            if url.pathExtension == "icloud" {
                let filename = String(url.lastPathComponent.dropFirst().dropLast(7))
                try? fm.startDownloadingUbiquitousItem(at: devices.appendingPathComponent(filename))
                throw LibrarySyncError.waiting(filename)
            }
            guard url.pathExtension == "json" else { continue }
            let remote = try JSONDecoder().decode(LibrarySyncState.self, from: read(url))
            guard remote.schema == 1 else { throw LibrarySyncError.unsupportedVersion }
            state.merge(remote)
            // iCloud may preserve a version from an interrupted write. Include
            // its records as well rather than silently discarding those edits.
            for conflict in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                let version = try JSONDecoder().decode(LibrarySyncState.self, from: read(conflict.url))
                guard version.schema == 1 else { throw LibrarySyncError.unsupportedVersion }
                state.merge(version)
            }
        }
        let merged = try LibrarySyncCodec.expand(state.values)
        let object = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        let localAssets = localRoot.appendingPathComponent("assets")
        for item in object["items"] as? [[String: Any]] ?? [] {
            guard let filename = item["storedFilename"] as? String,
                  filename == (filename as NSString).lastPathComponent,
                  filename.count > 64,
                  filename.prefix(64).allSatisfy({ $0.isHexDigit }) else { throw LibrarySyncError.invalidAsset }
            let target = localAssets.appendingPathComponent(filename)
            if !fm.fileExists(atPath: target.path) {
                let data = try read(cloudAssets.appendingPathComponent(filename))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard filename.hasPrefix(digest + ".") else { throw LibrarySyncError.invalidAsset }
                try data.write(to: target, options: .atomic)
            }
        }
        // Publish metadata only after all files are safe locally. iCloud still
        // controls upload ordering; receivers wait for unavailable originals.
        let ownURL = devices.appendingPathComponent(writer + ".json")
        let published = try? JSONDecoder().decode(LibrarySyncState.self, from: read(ownURL))
        if published != state { try write(JSONEncoder().encode(state), to: ownURL) }
        return Result(state: state, index: merged)
    }
}

@MainActor
final class LibrarySyncController: ObservableObject {
    static let shared = LibrarySyncController()
    @Published private(set) var isEnabled = false
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "尚未连接共享库"
    @Published private(set) var lastSync: Date?
    @Published private(set) var cloudURL: URL?
    private weak var store: LibraryStore?
    private var timer: Timer?
    private var saveObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var state = LibrarySyncState()
    private var baseline: [String: Data] = [:]
    private var scopedURL: URL?
    private let writer: String
    private var lastDuplicateCheck = Date.distantPast
    private var scanningDuplicates = false
    private let duplicateMonitor = ExactDuplicateMonitor()

    private struct Cache: Codable {
        var state: LibrarySyncState
        var baseline: [String: Data]
        var cloudPath: String
    }
    init() {
        let key = "EagleReplica.sync.deviceID"
        writer = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(writer, forKey: key)
    }

    func start(store: LibraryStore) {
        if self.store === store, timer != nil { return }
        self.store = store
        restoreConnection()
        saveObserver = NotificationCenter.default.addObserver(forName: .libraryDidSave, object: store, queue: .main) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.schedule() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in controller.syncNow(); controller.checkDuplicatesInBackground() }
        }
        syncNow()
        checkDuplicatesInBackground()
    }

    private func checkDuplicatesInBackground() {
        guard !scanningDuplicates, Date().timeIntervalSince(lastDuplicateCheck) > 60, let store else { return }
        scanningDuplicates = true
        let root = store.libraryURL
        let revision = store.saveRevision
        let files = store.items.filter { $0.keepDuplicate != true }.compactMap { item in store.imageURL(for: item).map { (item.id, $0) } }
        Task {
            let groups = await duplicateMonitor.scan(files)
            if store.libraryURL == root, store.saveRevision == revision {
                let matches = groups.map { ids in DuplicateGroup(items: store.items.filter { ids.contains($0.id) }) }
                _ = store.mergeConfirmedDuplicateGroups(matches)
                lastDuplicateCheck = Date()
            }
            scanningDuplicates = false
        }
    }

    func libraryDidChange() { restoreConnection(); syncNow() }

    private var configurationURL: URL? { store?.libraryURL.appendingPathComponent(".icloud-connection") }
    private var cacheURL: URL? { store?.libraryURL.appendingPathComponent(".icloud-state") }

    private func restoreConnection() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        cloudURL = nil
        isEnabled = false
        state = LibrarySyncState()
        baseline = [:]
        lastSync = nil
        status = "尚未连接共享库"
        guard let configurationURL, let bookmark = try? Data(contentsOf: configurationURL) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            scopedURL = url
            cloudURL = url
            isEnabled = true
            if let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.cloudPath == url.path {
                state = cache.state; baseline = cache.baseline
            }
            status = "等待同步"
        } catch { status = "共享文件夹不可用，请重新选择：\(error.localizedDescription)" }
    }

    func chooseFolder() {
        guard !isSyncing else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 iCloud Drive 中的共享文件夹"
        panel.message = "第一台 Mac 可新建“灵感库共享”文件夹；其他 Mac 选择同一个文件夹。当前素材和分类会合并。"
        panel.prompt = "连接共享库"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.connect(to: url)
        }
    }

    private func connect(to url: URL) {
        guard let configurationURL, let store else { return }
        do {
            let iCloudRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let ubiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            guard ubiquitous || path.hasPrefix(iCloudRoot + "/") else {
                status = "请选择 iCloud Drive 内的专用子文件夹，以便其他 Mac 可以访问。"; return
            }
            guard path != store.libraryURL.standardizedFileURL.path else {
                status = "请选择独立的共享文件夹。"; return
            }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            try bookmark.write(to: configurationURL, options: .atomic)
            restoreConnection()
            syncNow()
        } catch { status = error.localizedDescription }
    }

    func disconnect() {
        guard !isSyncing else { return }
        do {
            if let configurationURL, FileManager.default.fileExists(atPath: configurationURL.path) {
                try FileManager.default.removeItem(at: configurationURL)
            }
            restoreConnection()
            status = "已断开同步，本地素材和云端副本均已保留"
        } catch { status = error.localizedDescription }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        guard isEnabled, !isSyncing, let store, let cloudURL else { return }
        let root = store.libraryURL
        let revision = store.saveRevision
        let previous = state
        let baseline = baseline
        let writer = writer
        let data: Data
        do { data = try store.syncSnapshot() } catch { status = error.localizedDescription; return }
        let assets = Dictionary(uniqueKeysWithValues: store.items.compactMap { item in
            store.imageURL(for: item).map { (item.id.uuidString, $0) }
        })
        isSyncing = true
        status = "正在合并素材、AI 数据与文件夹…"
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try LibrarySyncDisk.exchange(indexData: data, assetURLs: assets, localRoot: root,
                        cloudRoot: cloudURL, writer: writer, previous: previous, baseline: baseline)
                }.value
                guard store.libraryURL == root else { isSyncing = false; schedule(); return }
                guard store.saveRevision == revision else {
                    isSyncing = false; status = "有新的本地修改，继续同步…"; schedule(); return
                }
                // Backup and validate before replacing the local index.
                try store.applySyncSnapshot(result.index)
                state = result.state
                self.baseline = try LibrarySyncCodec.flatten(result.index)
                if let cacheURL {
                    try JSONEncoder().encode(Cache(state: state, baseline: self.baseline, cloudPath: cloudURL.path))
                        .write(to: cacheURL, options: .atomic)
                }
                lastSync = Date()
                status = "已合并到本机；云端上传进度请查看 Finder 的 iCloud 状态"
            } catch {
                status = error.localizedDescription
            }
            isSyncing = false
        }
    }
}

actor ExactDuplicateMonitor {
    private var cache: [URL: (Date, UInt64, String)] = [:]
    func scan(_ files: [(UUID, URL)]) -> [[UUID]] {
        var matches: [String: [UUID]] = [:]
        for (id, url) in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else { continue }
            let digest: String
            if let cached = cache[url], cached.0 == date, cached.1 == size.uint64Value {
                digest = cached.2
            } else {
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                var hasher = SHA256()
                do {
                    while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hasher.update(data: block) }
                } catch { continue }
                digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                cache[url] = (date, size.uint64Value, digest)
            }
            matches[digest, default: []].append(id)
        }
        let liveURLs = Set(files.map(\.1))
        cache = cache.filter { liveURLs.contains($0.key) }
        return matches.values.filter { $0.count > 1 }
    }
}
