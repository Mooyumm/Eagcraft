import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 主窗口的编辑状态，供 AppDelegate 校验「复制 / 粘贴」菜单项是否可用。
@MainActor
final class LibraryEditingState: ObservableObject {
    static let shared = LibraryEditingState()

    @Published private(set) var selectedAssetCount = 0

    private init() {}

    func updateSelectionCount(_ count: Int) {
        guard count != selectedAssetCount else { return }
        selectedAssetCount = count
    }
}

/// 素材的复制与粘贴。
///
/// 复制时一次写入三种表示，去到哪里都能用：
/// - `public.file-url`：访达、聊天软件这类需要真实文件的地方；
/// - `public.tiff`：只认图片数据的地方，例如截图粘贴进文档；
/// - 库内素材 ID：再粘回灵感库时能认出是同一张，只补归属、不重复导入。
enum AssetClipboard {
    static let assetIDType = NSPasteboard.PasteboardType(UTType.eagleLibraryItem.identifier)

    /// 把素材写到系统剪贴板，返回成功写入的张数。
    @MainActor
    @discardableResult
    static func copy(_ items: [LibraryItem], store: LibraryStore, pasteboard: NSPasteboard = .general) -> Int {
        let entries = items.compactMap { item -> NSPasteboardItem? in
            guard let url = store.imageURL(for: item) else { return nil }
            let entry = NSPasteboardItem()
            entry.setString(url.absoluteString, forType: .fileURL)
            if let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
            entry.setString(item.id.uuidString, forType: assetIDType)
            return entry
        }
        guard !entries.isEmpty else { return 0 }
        pasteboard.clearContents()
        pasteboard.writeObjects(entries)
        return entries.count
    }

    /// 剪贴板里有没有可以放进素材库的东西。
    static func canPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [
            UTType.eagleLibraryItem.identifier,
            UTType.fileURL.identifier,
            UTType.tiff.identifier,
            UTType.png.identifier
        ])
    }

    /// 把剪贴板内容导入素材库，返回新增或补充归属的素材。
    @MainActor
    @discardableResult
    static func paste(into store: LibraryStore, folder: String, pasteboard: NSPasteboard = .general) -> [LibraryItem] {
        // 1) 从灵感库自己复制出去的东西：只补文件夹归属，不重复导入同一张。
        let internalIDs = internalAssetIDs(from: pasteboard)
        if !internalIDs.isEmpty {
            return assign(internalIDs, to: folder, store: store)
        }

        // 2) 真实文件，例如从访达或浏览器的下载列表里复制的图片。
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []).filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
        let importedFromFiles = fileURLs.compactMap { url in
            try? store.importFile(at: url, folder: folder)
        }
        if !importedFromFiles.isEmpty { return importedFromFiles }

        // 3) 纯图片数据，例如截图或网页上复制的图。
        guard let data = imageData(from: pasteboard),
              let item = try? store.importImageData(
                data,
                folder: folder,
                metadata: WebImageMetadata(imageURL: "clipboard://paste", suggestedName: pastedName()),
                preferredExtension: "png"
              ) else { return [] }
        return [item]
    }

    // MARK: - 内部实现

    @MainActor
    private static func assign(_ ids: Set<UUID>, to folder: String, store: LibraryStore) -> [LibraryItem] {
        var affected: [LibraryItem] = []
        for id in ids {
            guard store.items.contains(where: { $0.id == id }) else { continue }
            if folder.isEmpty {
                store.move(id, to: "")
            } else {
                store.addToFolder([id], folder: folder)
            }
            if let item = store.items.first(where: { $0.id == id }) { affected.append(item) }
        }
        return affected
    }

    private static func internalAssetIDs(from pasteboard: NSPasteboard) -> Set<UUID> {
        let values = pasteboard.pasteboardItems?.compactMap { $0.string(forType: assetIDType) } ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), NSImage(data: png) != nil { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private static func pastedName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH.mm.ss"
        return "粘贴的图片 \(formatter.string(from: Date()))"
    }
}
