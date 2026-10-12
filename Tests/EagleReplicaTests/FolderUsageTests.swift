import CryptoKit
import Foundation
import XCTest
@testable import EagleReplica

@MainActor
final class FolderUsageTests: XCTestCase {
    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaCollectorOrder-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// 与 LibraryStore 相同的键推导方式，用来验证已经存在的账本数据能被读回来。
    private func ledgerKey(for libraryURL: URL) -> String {
        let digest = SHA256.hash(data: Data(libraryURL.standardizedFileURL.path.utf8))
        return "EagleReplica.folderUsage." + digest.map { String(format: "%02x", $0) }.joined()
    }

    func testCollectorOrderUsesUsageWhileSidebarOrderStaysManual() throws {
        let root = temporaryRoot("Invariant")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let manualOrder = store.folders
        let target = try XCTUnwrap(manualOrder.last)

        for _ in 0..<5 { store.recordFolderOpened(target) }

        XCTAssertEqual(store.foldersByUsage.first, target)
        XCTAssertEqual(store.folders, manualOrder, "侧栏顺序不能被使用频次影响")
    }

    func testOrderIsStableWithoutUsage() {
        let ledger = FolderUsageLedger()
        let manual = ["照片素材", "文字设计", "配色"]

        XCTAssertEqual(FolderUsageLedger.ordered(manual, by: ledger), manual)
    }

    func testOpeningFolderAndAddingAssetsRecordWeightedUsage() throws {
        let root = temporaryRoot("Record")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let folder = store.addFolder(named: "频次")

        XCTAssertEqual(store.usageScore(for: folder), 0)

        store.rememberSelection(.folder(folder))
        XCTAssertEqual(store.usageScore(for: folder), FolderUsageLedger.openedWeight)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.addToFolder([item.id], folder: folder), 1)
        XCTAssertEqual(
            store.usageScore(for: folder),
            FolderUsageLedger.openedWeight + FolderUsageLedger.importedWeight
        )

        store.rememberSelection(.folder(folder))
        XCTAssertEqual(
            store.usageScore(for: folder),
            FolderUsageLedger.openedWeight * 2 + FolderUsageLedger.importedWeight
        )
    }

    func testBatchMoveCountsOncePerFolder() {
        let root = temporaryRoot("Batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let folder = store.addFolder(named: "批量")
        let ids = Set(store.items.map(\.id))
        XCTAssertGreaterThan(ids.count, 1)

        store.update(ids) { $0.folder = folder; $0.isTrashed = false }

        XCTAssertEqual(store.usageScore(for: folder), FolderUsageLedger.importedWeight)
    }

    func testRankingBreaksTiesByRecencyThenManualOrder() {
        let root = temporaryRoot("Rank")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let low = store.addFolder(named: "低频")
        let high = store.addFolder(named: "高频")
        let never = store.addFolder(named: "没用过")

        for _ in 0..<5 { store.recordFolderOpened(low) }
        for _ in 0..<9 { store.recordFolderOpened(high) }

        let order = store.foldersByUsage
        let highIndex = order.firstIndex(of: high)
        let lowIndex = order.firstIndex(of: low)
        let neverIndex = order.firstIndex(of: never)
        if let highIndex, let lowIndex, let neverIndex {
            XCTAssertLessThan(highIndex, lowIndex)
            XCTAssertLessThan(lowIndex, neverIndex)
        } else {
            XCTFail("排序结果缺少预期文件夹：\(order)")
        }

        // 同分时最近用过的排在前面。
        let earlier = store.addFolder(named: "同分先")
        let later = store.addFolder(named: "同分后")
        store.recordFolderOpened(earlier)
        store.recordFolderOpened(later)
        let tied = store.foldersByUsage
        if let laterIndex = tied.firstIndex(of: later), let earlierIndex = tied.firstIndex(of: earlier) {
            XCTAssertLessThan(laterIndex, earlierIndex)
        } else {
            XCTFail("排序结果缺少同分文件夹：\(tied)")
        }
    }

    func testRenameAndDeleteCarryUsageRecords() {
        let root = temporaryRoot("Rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let folder = store.addFolder(named: "旧名")
        for _ in 0..<4 { store.recordFolderOpened(folder) }

        let renamed = store.renameFolder(folder, to: "新名")
        XCTAssertEqual(renamed, "新名")
        XCTAssertEqual(store.usageScore(for: "新名"), 4)
        XCTAssertEqual(store.usageScore(for: "旧名"), 0)

        store.deleteFolder("新名")
        XCTAssertEqual(store.usageScore(for: "新名"), 0)
    }

    func testExistingLedgerIsReusedAndStaysScopedPerLibrary() throws {
        let root = temporaryRoot("Persist")
        let otherRoot = temporaryRoot("PersistOther")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let suiteName = "EagleReplicaTests.CollectorOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 资源库里先有这几个文件夹，再把 1.3 时期留下的账本写回去。
        let setup = LibraryStore(rootURL: root, folderUsageDefaults: defaults)
        let first = setup.addFolder(named: "【素材】")
        let second = setup.addFolder(named: "海报设计")
        _ = setup.addFolder(named: "没用过")
        let legacy = #"{"records":{"【素材】":{"lastUsedAt":811068609.645555,"score":13},"海报设计":{"lastUsedAt":811068530.727386,"score":4}}}"#
        defaults.set(Data(legacy.utf8), forKey: ledgerKey(for: root))

        let store = LibraryStore(rootURL: root, folderUsageDefaults: defaults)
        XCTAssertEqual(store.usageScore(for: first), 13)
        XCTAssertEqual(store.usageScore(for: second), 4)
        XCTAssertEqual(store.foldersByUsage.prefix(2).map { $0 }, [first, second])
        XCTAssertEqual(store.folders.suffix(3).map { $0 }.prefix(2).map { $0 }, [first, second])

        // 换一个资源库不共享统计。
        let other = LibraryStore(rootURL: otherRoot, folderUsageDefaults: defaults)
        XCTAssertEqual(other.usageScore(for: first), 0)
    }

    func testCustomLibraryRootKeepsUsageOffTheSharedDefaults() {
        let root = temporaryRoot("Isolated")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let folder = store.addFolder(named: "隔离")
        store.recordFolderOpened(folder)
        XCTAssertEqual(store.usageScore(for: folder), FolderUsageLedger.openedWeight)

        let reopened = LibraryStore(rootURL: root)
        XCTAssertEqual(reopened.usageScore(for: folder), 0)
    }
}
