import Foundation
import XCTest
@testable import EagleReplica

@MainActor
final class LibrarySyncTests: XCTestCase {
    private func emptyStore(_ root: URL) throws -> LibraryStore {
        let store = LibraryStore(rootURL: root)
        try store.createLibrary(at: root.appendingPathComponent("Local"))
        return store
    }
    private var source: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
    }
    private func exchange(_ store: LibraryStore, cloud: URL, writer: String,
                          previous: LibrarySyncDisk.Result? = nil) throws -> LibrarySyncDisk.Result {
        let urls = Dictionary(uniqueKeysWithValues: store.items.compactMap { item in
            store.imageURL(for: item).map { (item.id.uuidString, $0) }
        })
        let result = try LibrarySyncDisk.exchange(indexData: store.syncSnapshot(), assetURLs: urls,
            localRoot: store.libraryURL, cloudRoot: cloud, writer: writer,
            previous: previous?.state ?? LibrarySyncState(),
            baseline: try previous.map { try LibrarySyncCodec.flatten($0.index) } ?? [:])
        try store.applySyncSnapshot(result.index)
        return result
    }

    func testTwoComputersShareOriginalAIChatAndEveryFolderType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try emptyStore(root.appendingPathComponent("A"))
        let b = try emptyStore(root.appendingPathComponent("B"))
        let cloud = root.appendingPathComponent("Cloud")
        let folder = a.addFolder(named: "风格/拼贴")
        let reference = a.addReferenceFolder(named: "排版参考")
        let item = try a.importFile(at: source, folder: folder)
        let question = AIChatMessage(role: .user, content: "分析这张图的构图")
        a.update(item.id) {
            $0.aiTags = ["拼贴", "复古"]; $0.referenceFolder = reference
            $0.aiPrompt = "拼贴海报"; $0.aiChatMessages = [question]
        }
        let smart = a.addSmartFolder(SmartFolder(name: "复古灵感", rules: [SmartFolderRule(field: .aiTag, operation: .equals, value: "复古")]))
        a.setFavoriteStyles(["复古"])
        let a1 = try exchange(a, cloud: cloud, writer: "A")
        let b1 = try exchange(b, cloud: cloud, writer: "B")
        let received = try XCTUnwrap(b.items.first)
        XCTAssertEqual(received.id, item.id)
        XCTAssertEqual(received.machineTags, ["拼贴", "复古"])
        XCTAssertEqual(received.chatMessages.map(\.id), [question.id])
        XCTAssertEqual(received.chatMessages.map(\.content), [question.content])
        XCTAssertEqual(received.chatMessages.first!.createdAt.timeIntervalSince1970,
                       question.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(received.referenceFolder, reference)
        XCTAssertEqual(b.folders, [folder])
        XCTAssertEqual(b.referenceFolders, [reference])
        XCTAssertEqual(b.favoriteStyles, ["复古"])
        XCTAssertEqual(b.smartFolders.first?.id, smart.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(b.imageURL(for: received))), try Data(contentsOf: source))

        // Offline changes affect different fields and append different messages.
        let answerA = AIChatMessage(role: .assistant, content: "A 的分析")
        let answerB = AIChatMessage(role: .user, content: "B 的追问")
        a.update(item.id) { $0.name = "A 改的标题"; $0.aiChatMessages?.append(answerA) }
        b.update(item.id) { $0.note = "B 补充的说明"; $0.aiChatMessages?.append(answerB) }
        let a2 = try exchange(a, cloud: cloud, writer: "A", previous: a1)
        let b2 = try exchange(b, cloud: cloud, writer: "B", previous: b1)
        let a3 = try exchange(a, cloud: cloud, writer: "A", previous: a2)
        XCTAssertEqual(a.items.first?.name, "A 改的标题")
        XCTAssertEqual(a.items.first?.note, "B 补充的说明")
        XCTAssertEqual(Set(a.items.first!.chatMessages.map(\.id)), [question.id, answerA.id, answerB.id])
        XCTAssertEqual(a3.state, b2.state)

        // A stale computer cannot resurrect a permanently deleted item.
        a.permanentlyDelete(item.id)
        let a4 = try exchange(a, cloud: cloud, writer: "A", previous: a3)
        let b3 = try exchange(b, cloud: cloud, writer: "B", previous: b2)
        XCTAssertTrue(b.items.isEmpty)
        XCTAssertEqual(a4.state, b3.state)
        let b4 = try exchange(b, cloud: cloud, writer: "B", previous: b3)
        XCTAssertEqual(b3.state, b4.state, "An idle sync must not generate new edits")
    }

    func testConcurrentDuplicateImportsConvergeWithoutLosingMemberships() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try emptyStore(root.appendingPathComponent("A"))
        let b = try emptyStore(root.appendingPathComponent("B"))
        let cloud = root.appendingPathComponent("Cloud")
        let fa = a.addFolder(named: "A 分类")
        let fb = b.addFolder(named: "B 分类")
        let ra = a.addReferenceFolder(named: "A 参考")
        let rb = b.addReferenceFolder(named: "B 参考")
        let ia = try a.importFile(at: source, folder: fa)
        let ib = try b.importFile(at: source, folder: fb)
        a.update(ia.id) { $0.referenceFolder = ra; $0.tags = ["人工"] }
        b.update(ib.id) { $0.referenceFolder = rb; $0.aiTags = ["复古"] }
        let a1 = try exchange(a, cloud: cloud, writer: "A")
        let b1 = try exchange(b, cloud: cloud, writer: "B")
        let b2 = try exchange(b, cloud: cloud, writer: "B", previous: b1)
        let a2 = try exchange(a, cloud: cloud, writer: "A", previous: a1)
        XCTAssertEqual(a.items.count, 1)
        XCTAssertEqual(b.items.count, 1)
        XCTAssertEqual(a.items.first?.id, b.items.first?.id)
        XCTAssertEqual(Set(a.items.first!.allFolders), [fa, fb])
        XCTAssertEqual(Set(a.items.first!.allReferenceFolders), [ra, rb])
        XCTAssertEqual(a.items.first?.tags, ["人工"])
        XCTAssertEqual(a.items.first?.machineTags, ["复古"])
        XCTAssertEqual(a2.state, b2.state)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("assets").path).count, 1)
    }

    func testMissingCloudAssetDoesNotReplaceLocalIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try emptyStore(root.appendingPathComponent("A"))
        let b = try emptyStore(root.appendingPathComponent("B"))
        let cloud = root.appendingPathComponent("Cloud")
        _ = try a.importFile(at: source, folder: "")
        _ = try exchange(a, cloud: cloud, writer: "A")
        let before = try b.syncSnapshot()
        let asset = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("assets"), includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: asset)
        XCTAssertThrowsError(try exchange(b, cloud: cloud, writer: "B"))
        XCTAssertEqual(try b.syncSnapshot(), before)
    }

    func testDefaultImportReusesBytesAndBackgroundScanFindsLegacyDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try emptyStore(root)
        let first = try store.importFile(at: source, folder: "A")
        let second = try store.importFile(at: source, folder: "B")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(Set(store.items.first!.allFolders), ["A", "B"])
        let kept = try store.importFile(at: source, folder: "C", allowDuplicate: true)
        XCTAssertEqual(store.checkExactDuplicates(), 0, "Respect an explicit keep-both decision")
        store.update(kept.id) { $0.keepDuplicate = nil }
        let monitor = ExactDuplicateMonitor()
        let matches = await monitor.scan(store.items.compactMap { item in store.imageURL(for: item).map { (item.id, $0) } })
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(store.checkExactDuplicates(), 1)
        XCTAssertEqual(Set(store.items.first!.allFolders), ["A", "B", "C"])
        XCTAssertEqual(LibraryStore(rootURL: store.libraryURL).items.count, 1)
    }

    func testOldDefaultModelMigratesWithoutChangingCustomModel() {
        let name = "eagle-model-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("deepseek-v4-flash-vision", forKey: "EagleReplica.ai.model")
        XCTAssertEqual(AISettingsStore(defaults: defaults, readsKeychain: false).configuration.model, "deepseek-v4-flash-vision-exp")
        defaults.set("my-custom-vision", forKey: "EagleReplica.ai.model")
        XCTAssertEqual(AISettingsStore(defaults: defaults, readsKeychain: false).configuration.model, "my-custom-vision")
    }

    func testDeletingKeptDuplicateNeverRemovesSharedOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try emptyStore(root.appendingPathComponent("A"))
        let first = try store.importFile(at: source, folder: "A")
        let kept = try store.importFile(at: source, folder: "B", allowDuplicate: true)
        _ = try exchange(store, cloud: root.appendingPathComponent("Cloud"), writer: "A")
        XCTAssertEqual(store.items.count, 2)
        store.permanentlyDelete(first.id)
        let survivor = try XCTUnwrap(store.items.first { $0.id == kept.id })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.imageURL(for: survivor))), try Data(contentsOf: source))
    }

    func testAIStyleFolderIdentityIsStableAcrossComputersAndReloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryStore(rootURL: root.appendingPathComponent("A"))
        let b = LibraryStore(rootURL: root.appendingPathComponent("B"))
        for store in [a, b] {
            for item in store.items { store.update(item.id) { $0.aiTags = ["复古"] } }
            store.rebuildAISmartFolders()
        }
        XCTAssertEqual(a.smartFolders, b.smartFolders)
        let before = a.smartFolders
        a.reloadLibrary()
        XCTAssertEqual(a.smartFolders, before)
    }
}
