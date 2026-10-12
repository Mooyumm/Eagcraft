import AppKit
import Foundation
import XCTest
@testable import EagleReplica

@MainActor
final class AssetClipboardTests: XCTestCase {
    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaClipboard-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// 测试用独立剪贴板，避免碰到用户真实的系统剪贴板。
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("EagleReplicaTests.\(UUID().uuidString)"))
    }

    private func makePNG(size: Int = 24, red: CGFloat = 0.9, green: CGFloat = 0.3) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let color = NSColor(deviceRed: red, green: green, blue: 0.2, alpha: 1)
        for y in 0..<size {
            for x in 0..<size {
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testCopyWritesFileURLImageDataAndLibraryIdentity() throws {
        let root = temporaryRoot("Copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try XCTUnwrap(store.items.first)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        XCTAssertEqual(AssetClipboard.copy([item], store: store, pasteboard: pasteboard), 1)

        let entry = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertNotNil(entry.string(forType: .fileURL), "粘到访达需要真实文件地址")
        XCTAssertNotNil(entry.data(forType: .tiff), "粘到只认图片数据的地方需要位图")
        XCTAssertEqual(entry.string(forType: AssetClipboard.assetIDType), item.id.uuidString)
        XCTAssertTrue(AssetClipboard.canPaste(from: pasteboard))
    }

    func testPasteImportsImageDataIntoTheChosenFolder() throws {
        let root = temporaryRoot("PasteData")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let folder = store.addFolder(named: "粘贴目标")
        let before = store.items.count
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(try makePNG(), forType: .png)

        let pasted = AssetClipboard.paste(into: store, folder: folder, pasteboard: pasteboard)

        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(store.items.count, before + 1)
        let item = try XCTUnwrap(pasted.first)
        XCTAssertEqual(item.folder, folder)
        XCTAssertTrue(item.name.hasPrefix("粘贴"), "剪贴板图片应该有个可读的默认名")
        XCTAssertNotNil(store.imageURL(for: item))
    }

    func testPasteOfFileURLImportsTheImageFile() throws {
        let root = temporaryRoot("PasteFile")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let before = store.items.count
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clipboard-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try makePNG(red: 0.2, green: 0.7).write(to: fileURL)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let pasted = AssetClipboard.paste(into: store, folder: "", pasteboard: pasteboard)

        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(store.items.count, before + 1)
        XCTAssertEqual(pasted.first?.name, fileURL.deletingPathExtension().lastPathComponent)
    }

    func testPastingLibraryItemsAddsFolderMembershipWithoutDuplicating() throws {
        let root = temporaryRoot("PasteInternal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try XCTUnwrap(store.items.first)
        let folder = store.addFolder(named: "内部粘贴")
        let before = store.items.count
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        XCTAssertEqual(AssetClipboard.copy([item], store: store, pasteboard: pasteboard), 1)
        let pasted = AssetClipboard.paste(into: store, folder: folder, pasteboard: pasteboard)

        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(store.items.count, before, "库内素材来回粘贴不应该重复导入")
        XCTAssertEqual(pasted.first?.id, item.id)
        XCTAssertTrue(store.items.first { $0.id == item.id }?.allFolders.contains(folder) == true)
    }

    func testCanPasteIsFalseForPlainText() {
        let root = temporaryRoot("Text")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("只是一段文字", forType: .string)

        XCTAssertFalse(AssetClipboard.canPaste(from: pasteboard))
        XCTAssertTrue(AssetClipboard.paste(into: store, folder: "", pasteboard: pasteboard).isEmpty)
        XCTAssertEqual(store.items.count, LibraryStore(rootURL: root).items.count, "粘贴失败不应该改动素材库")
    }
}
