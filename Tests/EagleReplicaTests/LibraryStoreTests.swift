import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import EagleReplica

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testTutorialImageIsBundledAndRepeatedImportReusesOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Tutorial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        XCTAssertNotNil(store.tutorialImageURL)
        let count = store.items.count
        let first = try store.importTutorialImage()
        let second = try store.importTutorialImage()
        XCTAssertEqual(first.disposition, .imported)
        XCTAssertEqual(first.item.id, second.item.id)
        XCTAssertEqual(store.items.count, count + 1)
        XCTAssertNotNil(store.imageURL(for: first.item))
        let reopened = LibraryStore(rootURL: root)
        XCTAssertTrue(reopened.items.contains { $0.id == first.item.id })
    }

    func testAssetDragProviderPublishesARealImageFileAndInternalID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaDragOut-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try XCTUnwrap(store.items.first)
        let provider = AssetDragProvider.provider(for: item, store: store)

        XCTAssertTrue(provider.canLoadObject(ofClass: NSString.self))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.eagleLibraryItem.identifier))
        let imageType = try XCTUnwrap(provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        })
        let sourceURL = try XCTUnwrap(store.imageURL(for: item))
        XCTAssertEqual((provider.suggestedName as NSString?)?.pathExtension.lowercased(), sourceURL.pathExtension.lowercased())

        let fileExpectation = expectation(description: "加载拖出的真实图片文件")
        provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, error in
            XCTAssertNil(error)
            XCTAssertNotNil(url)
            if let url { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
            fileExpectation.fulfill()
        }
        let internalIDExpectation = expectation(description: "加载库内拖放素材 ID")
        provider.loadObject(ofClass: NSString.self) { object, error in
            XCTAssertNil(error)
            XCTAssertEqual((object as? NSString) as String?, item.id.uuidString)
            internalIDExpectation.fulfill()
        }
        let privateIDExpectation = expectation(description: "加载专用库内拖放素材 ID")
        provider.loadDataRepresentation(forTypeIdentifier: UTType.eagleLibraryItem.identifier) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, item.id.uuidString)
            privateIDExpectation.fulfill()
        }
        await fulfillment(of: [fileExpectation, internalIDExpectation, privateIDExpectation], timeout: 2)
    }

    func testDroppingAssetsIntoFolderAddsMembershipWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaFolderDrop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try XCTUnwrap(store.items.first)
        let originalFolders = item.allFolders
        let destination = store.addFolder(named: "拖放目标")

        XCTAssertEqual(store.addToFolder([item.id], folder: destination), 1)
        let added = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
        XCTAssertTrue(added.allFolders.contains(destination))
        XCTAssertTrue(originalFolders.allSatisfy(added.allFolders.contains))

        XCTAssertEqual(store.addToFolder([item.id], folder: destination), 0)
        let repeated = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
        XCTAssertEqual(repeated.allFolders.filter { $0 == destination }.count, 1)
    }

    func testFolderReorderingPersistsAndKeepsFolderMetadataAligned() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaFolderOrder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let first = store.addFolder(named: "顺序 A")
        let second = store.addFolder(named: "顺序 B")
        let third = store.addFolder(named: "顺序 C")

        XCTAssertTrue(store.reorderFolder(first, over: third))
        XCTAssertEqual(Array(store.folders.suffix(3)), [second, third, first])
        XCTAssertEqual(Array(store.folderDetails.map(\.name).suffix(3)), [second, third, first])

        let reopened = LibraryStore(rootURL: root)
        XCTAssertEqual(Array(reopened.folders.suffix(3)), [second, third, first])
        XCTAssertFalse(reopened.reorderFolder(first, over: first))
    }

    func testFolderOrderDragProviderPublishesPrivateFolderPayload() async {
        let provider = FolderOrderDragProvider.provider(for: "文字设计")
        XCTAssertEqual(provider.suggestedName, "文字设计")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.eagleFolderOrder.identifier))

        let payloadExpectation = expectation(description: "加载文件夹排序拖动数据")
        provider.loadDataRepresentation(forTypeIdentifier: UTType.eagleFolderOrder.identifier) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(data.flatMap { String(data: $0, encoding: .utf8) }, "文字设计")
            payloadExpectation.fulfill()
        }
        await fulfillment(of: [payloadExpectation], timeout: 2)
    }

    func testReferenceFolderAssignmentRenameDeletionAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaReferenceFolders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let itemID = try XCTUnwrap(store.items.first?.id)
        let folder = store.addReferenceFolder(named: "构图参考")

        store.assignReferenceFolder(itemID, to: folder)
        XCTAssertEqual(store.count(in: .referenceFolder(folder)), 1)
        XCTAssertEqual(
            store.visibleItems(for: .referenceFolder(folder), searchText: "", filter: .all, sort: .addedNewest).first?.id,
            itemID
        )

        store.rememberSelection(.referenceFolder(folder))
        let renamed = store.renameReferenceFolder(folder, to: "版式参考")
        XCTAssertEqual(renamed, "版式参考")
        XCTAssertEqual(store.items.first(where: { $0.id == itemID })?.referenceFolder, renamed)

        let reopened = LibraryStore(rootURL: root)
        XCTAssertEqual(reopened.referenceFolders, [renamed])
        XCTAssertEqual(reopened.lastSelection, .referenceFolder(renamed))
        XCTAssertEqual(reopened.items.first(where: { $0.id == itemID })?.referenceFolder, renamed)

        reopened.deleteReferenceFolder(renamed)
        XCTAssertNil(reopened.items.first(where: { $0.id == itemID })?.referenceFolder)
        XCTAssertEqual(reopened.lastSelection, .section(.all))
    }

    func testReferenceFolderReorderingPersists() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaReferenceFolderOrder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let first = store.addReferenceFolder(named: "构图参考")
        let second = store.addReferenceFolder(named: "配色参考")
        let third = store.addReferenceFolder(named: "材质参考")

        XCTAssertTrue(store.reorderReferenceFolder(first, over: third))
        XCTAssertEqual(store.referenceFolders, [second, third, first])
        XCTAssertEqual(LibraryStore(rootURL: root).referenceFolders, [second, third, first])
    }

    func testPreviewOffersAllThreePersistableWheelBehaviors() {
        XCTAssertEqual(PreviewScrollBehavior.allCases.map(\.rawValue), ["垂直浏览", "缩放图片", "左右翻页"])
        XCTAssertEqual(PreviewScrollBehavior(rawValue: "缩放图片"), .zoom)
    }

    func testPreviewPanIsLimitedToOverflowingImageAxes() {
        let viewport = CGSize(width: 800, height: 600)
        let portrait = CGSize(width: 400, height: 800)

        XCTAssertEqual(
            PreviewPanMath.clampedOffset(
                CGSize(width: 300, height: 400),
                imageSize: portrait,
                viewportSize: viewport,
                zoom: 1
            ),
            .zero
        )

        let zoomed = PreviewPanMath.clampedOffset(
            CGSize(width: 300, height: 400),
            imageSize: portrait,
            viewportSize: viewport,
            zoom: 2
        )
        XCTAssertEqual(zoomed.width, 0, accuracy: 0.001)
        XCTAssertEqual(zoomed.height, 252, accuracy: 0.001)

        let oppositeEdge = PreviewPanMath.clampedOffset(
            CGSize(width: -300, height: -400),
            imageSize: portrait,
            viewportSize: viewport,
            zoom: 2
        )
        XCTAssertEqual(oppositeEdge.height, -252, accuracy: 0.001)
    }

    func testTrackpadScrollPansWhilePinchControlsZoom() {
        XCTAssertEqual(
            PreviewGestureMath.scrolledOffset(
                from: CGSize(width: 12, height: -8),
                deltaX: 5,
                deltaY: -20
            ),
            CGSize(width: 17, height: -28)
        )
        XCTAssertEqual(PreviewGestureMath.zoom(from: 1.2, magnification: 1.5), 1.8, accuracy: 0.001)
        XCTAssertEqual(PreviewGestureMath.zoom(from: 3, magnification: 2), 4, accuracy: 0.001)
        XCTAssertEqual(PreviewGestureMath.zoom(from: 0.5, magnification: 0.1), 0.2, accuracy: 0.001)
    }

    func testPreviewClosesWhenItsWindowResignsKey() {
        XCTAssertTrue(PreviewPresentationPolicy.shouldCloseOnWindowResign(hasPreview: true))
        XCTAssertFalse(PreviewPresentationPolicy.shouldCloseOnWindowResign(hasPreview: false))
    }

    func testTrashRetentionRecordsEntryDateShowsCountdownAndPurgesExpiredAsset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaTrashRetention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let id = try XCTUnwrap(store.items.first?.id)

        store.trash(id)
        let trashedAt = try XCTUnwrap(store.items.first(where: { $0.id == id })?.trashedAt)
        XCTAssertEqual(
            TrashRetentionPolicy.statusText(trashedAt: trashedAt, retentionDays: 30, now: trashedAt),
            "还有 30 天删除"
        )
        XCTAssertEqual(store.purgeExpiredTrash(retentionDays: 30, now: trashedAt.addingTimeInterval(29 * 86_400)), 0)
        XCTAssertEqual(store.purgeExpiredTrash(retentionDays: 30, now: trashedAt.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertFalse(store.items.contains { $0.id == id })
        XCTAssertEqual(TrashRetentionPolicy.normalizedDays(0), 1)
        XCTAssertEqual(TrashRetentionPolicy.normalizedDays(900), 365)
    }

    func testWorkspaceLayoutUsesCompactAlignedMacMetrics() {
        XCTAssertEqual(WorkspaceLayoutMetrics.topBarHeight, 48)
        XCTAssertEqual(WorkspaceLayoutMetrics.topBarContentOffset, 3)
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarSectionHeight, 26)
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarLibraryHeaderHeight, 38)
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarGroupSeparation, 8)
        XCTAssertEqual(WorkspaceLayoutMetrics.resourceLibraryPopoverWidth, 320)
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarRegularFontName, "PingFangSC-Regular")
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarMediumFontName, "PingFangSC-Medium")
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarTextOpacity, 0.88)
        XCTAssertEqual(WorkspaceLayoutMetrics.sidebarSelectedTextOpacity, 0.96)
        XCTAssertGreaterThan(WorkspaceLayoutMetrics.sidebarTextOpacity, WorkspaceLayoutMetrics.sidebarCountOpacity)
        XCTAssertGreaterThan(WorkspaceLayoutMetrics.sidebarCountOpacity, WorkspaceLayoutMetrics.sidebarSectionOpacity)
        XCTAssertEqual(WorkspaceLayoutMetrics.trafficLightHorizontalOffset, 8)
        XCTAssertEqual(WorkspaceLayoutMetrics.trafficLightVerticalOffset, 11)
        XCTAssertLessThan(WorkspaceLayoutMetrics.sidebarSectionHeight * 2, 60)
        XCTAssertLessThan(WorkspaceLayoutMetrics.resourceLibraryPopoverWidth, 360)
    }

    func testStyleStackKeepsThePrimaryPreviewFrontAndCentered() {
        XCTAssertEqual(StyleStackLayout.cardWidth, 124)
        XCTAssertEqual(StyleStackLayout.cardHeight, 142)
        XCTAssertEqual(StyleStackLayout.previewHeight, 164)
        XCTAssertEqual(StyleStackLayout.rotation(index: 0, count: 3), 0)
        XCTAssertEqual(StyleStackLayout.offset(index: 0, count: 3), .zero)
        XCTAssertEqual(StyleStackLayout.rotation(index: 1, count: 3), 4)
        XCTAssertEqual(StyleStackLayout.offset(index: 1, count: 3), CGSize(width: 14, height: 7))
        XCTAssertEqual(StyleStackLayout.rotation(index: 2, count: 3), -5)
        XCTAssertEqual(StyleStackLayout.offset(index: 2, count: 3), CGSize(width: -14, height: 10))
    }

    func testGridPinchScaleClampsAndPaletteUsesHexCards() {
        XCTAssertEqual(ThumbnailScaleMath.width(from: 156, magnification: 1.25), 195, accuracy: 0.001)
        XCTAssertEqual(ThumbnailScaleMath.width(from: 200, magnification: 2), 380, accuracy: 0.001)
        XCTAssertEqual(ThumbnailScaleMath.width(from: 140, magnification: 0.2), 76, accuracy: 0.001)
        XCTAssertEqual(AssetPaletteColor(color: [28, 120, 230], ratio: 0.6).hexString, "#1C78E6")
        XCTAssertEqual(AssetPaletteColor(color: [999, -2, 15], ratio: 0.1).hexString, "#FF000F")
        XCTAssertEqual(AssetPaletteColor(color: [10, 20, 30], ratio: 0.33).displayPercentage, 33)
        XCTAssertEqual(AssetPaletteColor(color: [10, 20, 30], ratio: 33).displayPercentage, 33)
    }

    func testLocalPaletteExtractionFindsColorsWithoutEagleMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Palette-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40,
            pixelsHigh: 20,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        for y in 0..<20 {
            for x in 0..<40 {
                bitmap.setColor(x < 28 ? red : blue, atX: x, y: y)
            }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)

        let palette = ImagePaletteExtractor.extract(from: url)
        XCTAssertGreaterThanOrEqual(palette.count, 2)
        XCTAssertTrue(palette.contains { $0.color[0] > $0.color[2] + 80 })
        XCTAssertTrue(palette.contains { $0.color[2] > $0.color[0] + 80 })
    }

    func testAITaggingRequestContainsConfiguredVisionModelAndImage() throws {
        let configuration = AIModelConfiguration(
            endpoint: "https://api.deepseek.com/chat/completions",
            model: "deepseek-v4-flash-vision",
            prompt: "生成中文标签",
            maximumTags: 8
        )
        let request = try AITaggingService.makeRequest(
            imageJPEG: Data([0xFF, 0xD8, 0xFF]),
            configuration: configuration,
            apiKey: "test-key"
        )

        XCTAssertEqual(request.url?.absoluteString, configuration.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-v4-flash-vision")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.first(where: { $0["type"] as? String == "image_url" }))
        let imageURL = try XCTUnwrap(image["image_url"] as? [String: Any])
        XCTAssertTrue((imageURL["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    func testAITaggingRequestAsksForADetailedGenerationPrompt() throws {
        let configuration = AIModelConfiguration(
            endpoint: "https://api.deepseek.com/chat/completions",
            model: "deepseek-v4-flash-vision",
            prompt: "生成中文标签",
            maximumTags: 8
        )
        let request = try AITaggingService.makeRequest(
            imageJPEG: Data([0xFF, 0xD8, 0xFF]),
            configuration: configuration,
            apiKey: "test-key"
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first { $0["type"] as? String == "text" }?["text"] as? String)

        // 指令必须给出结构顺序和长度要求，否则模型只会返回一句很短的提示词。
        XCTAssertTrue(text.contains("主体与关键细节"))
        XCTAssertTrue(text.contains("构图与景别"))
        XCTAssertTrue(text.contains("光线与色温"))
        XCTAssertTrue(text.contains("120–220 字"))
        XCTAssertGreaterThanOrEqual(object["max_tokens"] as? Int ?? 0, 1_000)
    }

    func testAIChatRequestIncludesCurrentImageAndConversationHistory() throws {
        let configuration = AIModelConfiguration(
            endpoint: "https://api.deepseek.com/chat/completions",
            model: "deepseek-v4-flash-vision",
            prompt: "",
            maximumTags: 8
        )
        let history = [
            AIChatMessage(role: .user, content: "这张海报的构图有什么特点？"),
            AIChatMessage(role: .assistant, content: "主体位于中心，留白集中在上方。"),
            AIChatMessage(role: .user, content: "如何改得更有张力？")
        ]
        let request = try AITaggingService.makeChatRequest(
            imageJPEG: Data([0xFF, 0xD8, 0xFF]),
            history: history,
            configuration: configuration,
            apiKey: "chat-key"
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        let imageContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let imagePart = try XCTUnwrap(imageContent.first { $0["type"] as? String == "image_url" })
        let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
        XCTAssertTrue((imageURL["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(messages.last?["content"] as? String, "如何改得更有张力？")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer chat-key")
    }

    func testAIChatHistoryPersistsWithItsAsset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAIChat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let itemID = try XCTUnwrap(store.items.first?.id)
        store.appendAIChatMessage(AIChatMessage(role: .user, content: "分析一下配色"), to: itemID)
        store.appendAIChatMessage(AIChatMessage(role: .assistant, content: "画面以蓝色和白色为主。"), to: itemID)

        let reloaded = LibraryStore(rootURL: root)
        let messages = try XCTUnwrap(reloaded.items.first(where: { $0.id == itemID })?.aiChatMessages)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["分析一下配色", "画面以蓝色和白色为主。"])
    }

    func testAIChatResponseParsesAssistantText() throws {
        let response: [String: Any] = [
            "choices": [["message": ["content": "  可以加强标题与主体之间的尺寸反差。  "]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        XCTAssertEqual(try AITaggingService.parseChatReply(from: data), "可以加强标题与主体之间的尺寸反差。")
    }

    func testAITaggingResponseCleansDeduplicatesAndLimitsTags() throws {
        let response: [String: Any] = [
            "choices": [["message": ["content": "```json\n{\"tags\":[\" 拼贴 \" ,\"蓝色\",\"拼贴\",\"#海报\",\"极简\"]}\n```"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let tags = try AITaggingService.parseTags(from: data, maximum: 3)

        XCTAssertEqual(tags, ["拼贴", "蓝色", "海报"])
    }

    func testAIAnalysisResponseIncludesReusableImagePrompt() throws {
        let response: [String: Any] = [
            "choices": [["message": ["content": "{\"name\":\"蓝色纸张拼贴\",\"tags\":[\"拼贴\",\"蓝色\"],\"prompt\":\"蓝色纸张拼贴，居中构图，柔和漫射光\"}"]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let analysis = try AITaggingService.parseAnalysis(from: data, maximum: 8)

        XCTAssertEqual(analysis.tags, ["拼贴", "蓝色"])
        XCTAssertEqual(analysis.prompt, "蓝色纸张拼贴，居中构图，柔和漫射光")
        XCTAssertEqual(analysis.name, "蓝色纸张拼贴")
    }

    func testStyleLibraryGroupsAITagsByStyleAndKeepsLegacySectionIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaStyleLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let items = Array(store.items.prefix(3))
        XCTAssertEqual(items.count, 3)

        store.updateAITags(items[0].id, tags: ["极简风格", "蓝色", "海报"])
        store.updateAITags(items[1].id, tags: ["极简风格", "拼贴"])
        store.updateAITags(items[2].id, tags: ["复古摄影", "人物"])

        let groups = AIStyleIndex.groups(in: store.items)
        XCTAssertEqual(groups.first(where: { $0.name == "极简风格" })?.items.count, 2)
        XCTAssertEqual(groups.first(where: { $0.name == "复古摄影" })?.items.count, 1)
        XCTAssertFalse(groups.contains { $0.name == "蓝色" })
        XCTAssertEqual(store.count(in: .section(.community)), 3)
        XCTAssertEqual(LibrarySection.community.rawValue, "资源社区")
        XCTAssertEqual(LibrarySection.community.title, "风格库")
    }

    func testStyleFavoritesPersistAndStayIndependentFromAllGroups() {
        let groups = [
            AIStyleGroup(name: "拼贴艺术", items: []),
            AIStyleGroup(name: "极简风格", items: []),
            AIStyleGroup(name: "复古摄影", items: [])
        ]
        let encoded = StyleFavoritesStorage.encode(["极简风格", "拼贴艺术"])
        let restored = StyleFavoritesStorage.decode(encoded)
        let favorites = StyleFavoritesStorage.favorites(in: groups, favoriteNames: restored)

        XCTAssertEqual(restored, ["极简风格", "拼贴艺术"])
        XCTAssertEqual(favorites.map(\.name), ["拼贴艺术", "极简风格"])
        XCTAssertEqual(groups.count, 3, "全部风格区应保留所有风格，包括已置顶风格")
    }

    func testTagSelectionFindsMatchingAITags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAITagBrowse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let items = Array(store.items.prefix(3))
        XCTAssertEqual(items.count, 3)

        store.updateAITags(items[0].id, tags: ["几何图形", "粗线条"])
        store.updateAITags(items[1].id, tags: ["几何图形"])
        store.updateAITags(items[2].id, tags: ["拼贴艺术"])

        let matches = store.visibleItems(
            for: .tag("几何图形"),
            searchText: "",
            filter: .all,
            sort: .addedNewest
        )
        XCTAssertEqual(Set(matches.map(\.id)), Set([items[0].id, items[1].id]))
    }

    func testAutomaticAITaggingOnlyQueuesNeverProcessedActiveImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAutomaticAI-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        var items = store.items
        XCTAssertGreaterThanOrEqual(items.count, 4)

        items[0].aiTags = nil
        items[0].aiPrompt = nil
        items[0].aiGeneratedName = nil
        items[1].aiTags = []
        items[1].aiPrompt = ""
        items[1].aiGeneratedName = "已命名"
        items[2].aiTags = ["已处理"]
        items[2].aiPrompt = nil
        items[2].aiGeneratedName = "已命名"
        items[3].aiTags = nil
        items[3].aiPrompt = nil
        items[3].aiGeneratedName = nil
        items[3].isTrashed = true

        let candidates = AITaggingService.automaticCandidates(in: items)
        XCTAssertEqual(candidates.map(\.id), [items[2].id, items[0].id])
    }

    func testAINamesOnceThenManualNameIsPermanentlyProtected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAIName-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let id = try XCTUnwrap(store.items.first?.id)

        XCTAssertFalse(store.updateManualName(id, name: "过早的人工名称"))
        store.updateAIAnalysis(id, tags: ["海报"], prompt: "蓝色海报", generatedName: "AI 蓝色海报")
        XCTAssertEqual(store.items.first(where: { $0.id == id })?.name, "AI 蓝色海报")
        XCTAssertEqual(store.items.first(where: { $0.id == id })?.aiGeneratedName, "AI 蓝色海报")

        XCTAssertTrue(store.updateManualName(id, name: "我的最终名称"))
        store.updateAIAnalysis(id, tags: ["设计"], prompt: "新提示词", generatedName: "AI 第二次名称")
        let final = try XCTUnwrap(store.items.first(where: { $0.id == id }))
        XCTAssertEqual(final.name, "我的最终名称")
        XCTAssertEqual(final.aiGeneratedName, "AI 蓝色海报")
        XCTAssertTrue(final.hasManualName)
    }

    func testVisionDuplicatePreflightAndConfirmedMergePreserveMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaVisionDuplicates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
        let data = try Data(contentsOf: source)

        let match = try XCTUnwrap(store.visualDuplicate(for: data))
        XCTAssertEqual(match.distance, 0)

        let duplicate = try store.importFile(at: source, folder: "配色", allowDuplicate: true)
        store.update(duplicate.id) {
            $0.tags = ["待合并标签"]
            $0.note = "来自新副本的说明"
        }
        let groups = DuplicateScanner.scan(store.items, mode: .similar, store: store)
        let group = try XCTUnwrap(groups.first { $0.items.contains(where: { $0.id == duplicate.id }) })
        let before = store.items.count
        XCTAssertEqual(store.mergeConfirmedDuplicateGroups([group]), group.items.count - 1)
        XCTAssertEqual(store.items.count, before - group.items.count + 1)
        let keeper = try XCTUnwrap(store.items.first { $0.tags.contains("待合并标签") })
        XCTAssertEqual(keeper.note, "来自新副本的说明")
        XCTAssertTrue(keeper.allFolders.contains("配色"))
    }

    func testCollectorCanKeepBothAfterVisualDuplicateWarning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaKeepBoth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let coordinator = CollectorImportCoordinator(store: store)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
        let originalCount = store.items.count
        coordinator.importImageData(
            try Data(contentsOf: source),
            folder: "配色",
            metadata: WebImageMetadata(imageURL: "https://example.test/keep-both.png", sessionID: "keep-both")
        )
        for _ in 0..<30 {
            if case .duplicateReview = coordinator.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .duplicateReview = coordinator.phase else {
            return XCTFail("Expected duplicate decision before import: \(coordinator.phase)")
        }
        coordinator.resolveDuplicate(useExisting: false)
        guard case .success = coordinator.phase else {
            return XCTFail("Keeping both did not import the new file: \(coordinator.phase)")
        }
        XCTAssertEqual(store.items.count, originalCount + 1)
    }

    func testFrequentAITagsCreateAndMaintainSmartFoldersWithoutMovingAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAISmartFolders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(rootURL: root)
        let ids = Array(store.items.prefix(4).map(\.id))
        XCTAssertEqual(ids.count, 4)
        let originalFolders = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0.folder) })

        let manual = store.addSmartFolder(SmartFolder(
            name: "我的蓝色收藏",
            rules: [SmartFolderRule(field: .tag, operation: .contains, value: "蓝色")]
        ))
        for id in ids.prefix(3) {
            store.updateAITags(id, tags: ["海报", "蓝色"])
        }
        store.updateAITags(ids[3], tags: ["摄影"])

        let posterFolder = try XCTUnwrap(store.smartFolders.first { $0.aiGeneratedTag == "海报" })
        XCTAssertEqual(posterFolder.name, "AI · 海报")
        XCTAssertEqual(store.count(in: .smartFolder(posterFolder.id)), 3)
        XCTAssertNotNil(store.smartFolders.first { $0.aiGeneratedTag == "蓝色" })
        XCTAssertNotNil(store.smartFolders.first { $0.id == manual.id })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0.folder) }), originalFolders)

        store.updateAITags(ids[0], tags: ["摄影"])
        XCTAssertNil(store.smartFolders.first { $0.aiGeneratedTag == "海报" })
        XCTAssertNil(store.smartFolders.first { $0.aiGeneratedTag == "蓝色" })
        XCTAssertNotNil(store.smartFolders.first { $0.id == manual.id })

        let reloaded = LibraryStore(rootURL: root)
        XCTAssertNotNil(reloaded.smartFolders.first { $0.id == manual.id })
        XCTAssertFalse(reloaded.smartFolders.contains { $0.aiGeneratedTag == "海报" })
    }

    func testPanelResizeMathSupportsBothSidebarsAndClampsWidth() {
        XCTAssertEqual(
            PanelResizeMath.width(from: 238, translation: 40, reversed: false, range: 180...380),
            278
        )
        XCTAssertEqual(
            PanelResizeMath.width(from: 238, translation: -40, reversed: true, range: 210...420),
            278
        )
        XCTAssertEqual(
            PanelResizeMath.width(from: 238, translation: -500, reversed: false, range: 180...380),
            180
        )
        XCTAssertEqual(
            PanelResizeMath.width(from: 238, translation: -500, reversed: true, range: 210...420),
            420
        )
    }

    func testEagleLibraryRoundTripPreservesExtendedMetadata() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaEagleRoundTrip-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = parent.appendingPathComponent("source", isDirectory: true)
        let exportRoot = parent.appendingPathComponent("往返测试.library", isDirectory: true)
        let targetRoot = parent.appendingPathComponent("target", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let source = LibraryStore(rootURL: sourceRoot)
        let itemID = try XCTUnwrap(source.items.first?.id)
        source.update(itemID) {
            $0.note = "Eagle 注释"
            $0.sourceURL = "https://example.test/eagle"
            $0.tags = ["设计", "参考"]
            $0.additionalFolders = ["配色"]
            $0.palette = [AssetPaletteColor(color: [28, 120, 230], ratio: 0.6)]
        }

        try source.exportEagleLibrary(to: exportRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("images").path))

        let target = LibraryStore(rootURL: targetRoot)
        let initialTargetCount = target.items.count
        XCTAssertEqual(try target.importEagleLibrary(at: exportRoot), 0)
        XCTAssertEqual(target.items.count, initialTargetCount)
        let imported = try XCTUnwrap(target.items.first(where: { $0.eagleID != nil && $0.note == "Eagle 注释" }))
        XCTAssertEqual(imported.sourceURL, "https://example.test/eagle")
        XCTAssertEqual(imported.tags, ["设计", "参考"])
        XCTAssertEqual(Set(imported.allFolders), Set(["文字设计", "配色"]))
        XCTAssertEqual(imported.palette?.first?.color, [28, 120, 230])
        XCTAssertNotNil(target.imageURL(for: imported))
    }

    func testExistingExactDuplicatesAreMergedOnceAndKeepFolderMembership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaDedupMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(rootURL: root)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
        let duplicate = try store.importFile(at: source, folder: "参考合并", allowDuplicate: true)
        store.update(duplicate.id) { $0.keepDuplicate = nil } // Simulate an old index without an explicit keep-both decision.
        XCTAssertNotNil(store.imageURL(for: duplicate))
        XCTAssertEqual(store.items.count, 5)

        try FileManager.default.removeItem(at: root.appendingPathComponent(".exact-dedup-v1"))
        let migrated = LibraryStore(rootURL: root)

        XCTAssertEqual(migrated.items.count, 4)
        let kept = try XCTUnwrap(migrated.items.first { Set($0.allFolders).isSuperset(of: ["文字设计", "参考合并"]) })
        XCTAssertNotNil(migrated.imageURL(for: kept))
        XCTAssertTrue(DuplicateScanner.scan(migrated.items, mode: .exact, store: migrated).isEmpty)
    }

    func testCollectorImportReportsExistingFolderAndAddsOnlyNewMembership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaImportDisposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")

        let originalCount = store.items.count
        let sameFolder = try store.importFileResult(at: source, folder: "文字设计")
        XCTAssertEqual(sameFolder.disposition, .alreadyInFolder)
        XCTAssertEqual(store.items.count, originalCount)

        let newMembership = try store.importFileResult(at: source, folder: "配色")
        XCTAssertEqual(newMembership.disposition, .addedToFolder)
        XCTAssertTrue(newMembership.item.allFolders.contains("配色"))
        XCTAssertEqual(store.items.count, originalCount)

        let repeatedMembership = try store.importFileResult(at: source, folder: "配色")
        XCTAssertEqual(repeatedMembership.disposition, .alreadyInFolder)
        XCTAssertEqual(store.items.count, originalCount)

        let importer = CollectorImportCoordinator(store: store)
        let data = try Data(contentsOf: source)
        importer.importImageData(data, folder: "配色", metadata: WebImageMetadata(
            imageURL: "https://example.test/poster.png",
            suggestedName: "重复素材",
            sessionID: "duplicate-notice-session"
        ))
        for _ in 0..<30 {
            if case .duplicateReview = importer.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .duplicateReview = importer.phase else {
            return XCTFail("Duplicate collection did not show its dedicated notice: \(importer.phase)")
        }
        importer.resolveDuplicate(useExisting: true)
        guard case .duplicate(_, let destination) = importer.phase else {
            return XCTFail("Using the existing file did not complete: \(importer.phase)")
        }
        XCTAssertEqual(destination, "配色")
        XCTAssertEqual(store.items.count, originalCount)
    }

    func testProvidedEagleLibraryImportsAllAssetsWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["EAGLE_REFERENCE_LIBRARY"], !path.isEmpty else {
            throw XCTSkip("Set EAGLE_REFERENCE_LIBRARY to verify a real Eagle library")
        }
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaReferenceImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = LibraryStore(rootURL: parent)
        let initialCount = store.items.count

        let importedCount = try store.importEagleLibrary(at: URL(fileURLWithPath: path, isDirectory: true))
        XCTAssertEqual(store.items.count, initialCount + importedCount)
        XCTAssertTrue(DuplicateScanner.scan(store.items, mode: .exact, store: store).isEmpty)
        XCTAssertEqual(store.items.filter { $0.eagleID != nil }.count, 16)
        XCTAssertEqual(store.folderDetails.filter { $0.eagleID != nil }.count, 6)
        XCTAssertEqual(store.items.filter { $0.eagleID != nil && !($0.palette ?? []).isEmpty }.count, 16)
        XCTAssertEqual(store.items.filter { $0.eagleID != nil && $0.noThumbnail == true }.count, 7)
    }

    func testResourceLibraryCreateSwitchReloadAndMerge() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaLibraryManagement-\(UUID().uuidString)", isDirectory: true)
        let originalRoot = parent.appendingPathComponent("原资源库", isDirectory: true)
        let secondRoot = parent.appendingPathComponent("第二资源库", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let store = LibraryStore(rootURL: originalRoot)
        let originalCount = store.items.count
        try store.createLibrary(at: secondRoot)
        XCTAssertEqual(store.libraryURL.standardizedFileURL, secondRoot.standardizedFileURL)
        XCTAssertTrue(store.items.isEmpty)

        let folder = store.addFolder(named: "合并测试")
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-3.png")
        let imported = try store.importFile(at: source, folder: folder)
        store.reloadLibrary()
        XCTAssertEqual(store.items.map(\.id), [imported.id])

        try store.openLibrary(at: originalRoot)
        XCTAssertEqual(store.items.count, originalCount)
        XCTAssertEqual(try store.mergeLibrary(at: secondRoot), 0)
        XCTAssertEqual(store.items.count, originalCount)
        let merged = try XCTUnwrap(store.items.first(where: { $0.allFolders.contains("合并测试") }))
        XCTAssertNotNil(store.imageURL(for: merged))
    }

    func testBrowserDragDoesNotPublishNavigableURLFlavors() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("BrowserExtension/content.js")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("clearData(\"text/uri-list\")"))
        XCTAssertTrue(script.contains("clearData(\"text/plain\")"))
        XCTAssertFalse(script.contains("setData(\"text/uri-list\""))
        XCTAssertFalse(script.contains("setData(\"text/plain\""))
    }

    func testBrowserDropRequiresLiveMatchingSessionAndCannotTreatEscapeAsDrop() {
        let now = Date(timeIntervalSince1970: 1000)
        let valid: [String: Any] = ["type": "imageDragDropped", "sessionID": "current", "timestamp": 1_000_000]
        XCTAssertTrue(DragCoordinator.acceptsDropMessage(valid, activeSessionID: "current", now: now))
        XCTAssertFalse(DragCoordinator.acceptsDropMessage(valid, activeSessionID: nil, now: now))
        XCTAssertFalse(DragCoordinator.acceptsDropMessage(valid, activeSessionID: "next", now: now))
        XCTAssertFalse(DragCoordinator.acceptsDropMessage(valid, activeSessionID: "current", now: now.addingTimeInterval(6)))
        var ended = valid
        ended["type"] = "imageDragEnded"
        XCTAssertFalse(DragCoordinator.acceptsDropMessage(ended, activeSessionID: "current", now: now))
    }

    func testCollectorPositionUsesBrowserDragPointAndStaysOnScreen() {
        let converted = CollectorPanelController.appKitPoint(
            browserX: 600,
            browserY: 250,
            primaryScreenMaxY: 900
        )
        XCTAssertEqual(converted, NSPoint(x: 600, y: 650))

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CollectorPanelController.panelSize
        let first = CollectorPanelController.origin(near: NSPoint(x: 200, y: 700), panelSize: size, visibleFrame: visible)
        let second = CollectorPanelController.origin(near: NSPoint(x: 1000, y: 300), panelSize: size, visibleFrame: visible)
        XCTAssertNotEqual(first, second, "Different browser drag points must not reuse a fixed collector position")
        for origin in [first, second] {
            XCTAssertGreaterThanOrEqual(origin.x, visible.minX + 12)
            XCTAssertGreaterThanOrEqual(origin.y, visible.minY + 12)
            XCTAssertLessThanOrEqual(origin.x + size.width, visible.maxX - 12)
            XCTAssertLessThanOrEqual(origin.y + size.height, visible.maxY - 12)
        }
    }

    func testCollectorOriginKeepsDropTargetUnderNativePointerOnSecondaryScreen() {
        let visible = NSRect(x: -1728, y: 0, width: 1728, height: 1117)
        let pointer = NSPoint(x: -840, y: 640)
        let origin = CollectorPanelController.origin(
            near: pointer,
            panelSize: CollectorPanelController.panelSize,
            visibleFrame: visible
        )
        let leftDropTarget = NSRect(
            x: origin.x,
            y: origin.y,
            width: CollectorPanelController.panelSize.width * 0.56,
            height: CollectorPanelController.panelSize.height
        )

        XCTAssertTrue(leftDropTarget.contains(pointer))
        XCTAssertGreaterThanOrEqual(origin.x, visible.minX + 12)
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY + 12)
        XCTAssertLessThanOrEqual(origin.x + CollectorPanelController.panelSize.width, visible.maxX - 12)
        XCTAssertLessThanOrEqual(origin.y + CollectorPanelController.panelSize.height, visible.maxY - 12)
    }

    func testClickThroughCollectorMapsPointerToDefaultAndFolderTargets() {
        let frame = NSRect(x: 100, y: 200, width: 480, height: 276)
        let folders = ["照片素材", "文字设计", "配色"]

        XCTAssertEqual(
            CollectorPanelController.dropTarget(at: NSPoint(x: 180, y: 330), panelFrame: frame, folders: folders),
            CollectorDropTarget(isValid: true, folder: nil)
        )
        XCTAssertEqual(
            CollectorPanelController.dropTarget(at: NSPoint(x: 390, y: 457), panelFrame: frame, folders: folders),
            CollectorDropTarget(isValid: true, folder: "照片素材")
        )
        XCTAssertEqual(
            CollectorPanelController.dropTarget(at: NSPoint(x: 390, y: 419), panelFrame: frame, folders: folders),
            CollectorDropTarget(isValid: true, folder: "文字设计")
        )
        XCTAssertEqual(
            CollectorPanelController.dropTarget(at: NSPoint(x: 390, y: 220), panelFrame: frame, folders: folders),
            CollectorDropTarget(isValid: true, folder: nil, createsFolder: true)
        )
        XCTAssertEqual(
            CollectorPanelController.dropTarget(at: NSPoint(x: 390, y: 190), panelFrame: frame, folders: folders),
            .invalid
        )

        let manyFolders = (0..<10).map { "文件夹 \($0)" }
        XCTAssertEqual(
            CollectorPanelController.dropTarget(
                at: NSPoint(x: 390, y: 457),
                panelFrame: frame,
                folders: manyFolders,
                folderStartIndex: 4
            ),
            CollectorDropTarget(isValid: true, folder: "文件夹 4")
        )
        XCTAssertEqual(
            CollectorPanelController.dropTarget(
                at: NSPoint(x: 390, y: 249),
                panelFrame: frame,
                folders: manyFolders,
                folderStartIndex: 4
            ),
            CollectorDropTarget(isValid: true, folder: "文件夹 9")
        )
        XCTAssertEqual(
            CollectorPanelController.folderAutoScrollDirection(at: NSPoint(x: 390, y: 465), panelFrame: frame),
            -1
        )
        XCTAssertEqual(
            CollectorPanelController.folderAutoScrollDirection(at: NSPoint(x: 390, y: 255), panelFrame: frame),
            1
        )
        XCTAssertEqual(
            CollectorPanelController.folderAutoScrollDirection(at: NSPoint(x: 390, y: 350), panelFrame: frame),
            0
        )
    }

    func testCollectorCreatesNamedFolderThenImportsPendingBrowserImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaNewCollectorFolder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-4.png")
        let imageData = try Data(contentsOf: source)
        let store = LibraryStore(rootURL: root)
        let coordinator = CollectorImportCoordinator(store: store)
        let metadata = WebImageMetadata(
            imageURL: "https://example.test/new-folder-image.png",
            suggestedName: "新文件夹素材",
            sessionID: "new-folder-session"
        )
        BrowserPayloadCache.shared.store(imageData, sessionID: "new-folder-session", mimeType: "image/png")

        coordinator.requestNewFolder(for: metadata)
        coordinator.confirmNewFolder(named: "网页灵感")
        for _ in 0..<30 {
            if case .duplicateReview = coordinator.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        coordinator.resolveDuplicate(useExisting: true)

        XCTAssertTrue(store.folders.contains("网页灵感"))
        guard case .addedToFolder(_, let destination) = coordinator.phase else {
            return XCTFail("Pending image was not saved into the new folder: \(coordinator.phase)")
        }
        XCTAssertEqual(destination, "网页灵感")
        XCTAssertEqual(store.items.count, 4)
        XCTAssertTrue(store.items.contains { $0.allFolders.contains("网页灵感") })
    }

    func testCollectorDropHandlerAcceptsPNGAndImportsIntoChosenFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaDropHandlerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-3.png")
        let imageData = try Data(contentsOf: source)
        let store = LibraryStore(rootURL: root)
        let importer = CollectorImportCoordinator(store: store)
        let handler = CollectorDropHandler(importer: importer, store: store)
        let metadata = WebImageMetadata(
            imageURL: "https://example.test/dragged.png",
            sourceURL: "https://example.test/board",
            pageTitle: "真实放置路径",
            suggestedName: "拖入采集框",
            sessionID: "drop-handler-session"
        )
        let customType = NSPasteboard.PasteboardType("application/x-eagle-replica")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("collector-drop-\(UUID().uuidString)"))
        pasteboard.declareTypes([customType, .png], owner: nil)
        XCTAssertTrue(pasteboard.setData(try JSONEncoder().encode(metadata), forType: customType))
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))

        XCTAssertTrue(handler.performDrop(from: pasteboard, folder: "照片素材"))
        for _ in 0..<30 {
            if case .duplicateReview = importer.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        importer.resolveDuplicate(useExisting: true)

        guard case .addedToFolder(let title, let destination) = importer.phase else {
            return XCTFail("The actual collector drop path did not finish: \(importer.phase)")
        }
        XCTAssertEqual(title, "收藏到 Arata Art")
        XCTAssertEqual(destination, "照片素材")
        XCTAssertEqual(store.items.count, 4)
        let collected = try XCTUnwrap(store.items.first { $0.allFolders.contains("照片素材") })
        XCTAssertTrue(collected.allFolders.contains("文字设计"))
        XCTAssertNotNil(store.imageURL(for: collected))
    }

    func testRemoteImageImportValidatesResponseAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaRemoteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
        let imageData = try Data(contentsOf: source)
        let recorder = RequestRecorder()
        let imageURL = try XCTUnwrap(URL(string: "https://images.example.test/protected/artwork"))

        let store = LibraryStore(rootURL: root) { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: imageURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "Content-Length": "\(imageData.count)"]
            )!
            return (imageData, response)
        }
        let metadata = WebImageMetadata(
            imageURL: imageURL.absoluteString,
            sourceURL: "https://example.test/board/42",
            pageTitle: "测试来源页",
            suggestedName: "远程采集作品",
            sessionID: "remote-session"
        )

        // This test exercises a new remote import, not reuse of the bundled fixture.
        try store.createLibrary(at: root.appendingPathComponent("empty"))

        let item = try await store.importRemote(metadata, folder: "照片素材")
        XCTAssertEqual(item.name, "远程采集作品")
        XCTAssertEqual(item.note, "测试来源页")
        XCTAssertEqual(item.sourceURL, "https://example.test/board/42")
        XCTAssertEqual(item.folder, "照片素材")
        XCTAssertEqual(item.format, "png")
        XCTAssertTrue(item.storedFilename?.hasSuffix(".png") == true)
        XCTAssertNotNil(store.imageURL(for: item))
        XCTAssertNotNil(store.imageURL(for: item, thumbnail: true))
        XCTAssertEqual(recorder.request?.value(forHTTPHeaderField: "Referer"), "https://example.test/board/42")
        XCTAssertTrue(recorder.request?.value(forHTTPHeaderField: "Accept")?.contains("image/webp") == true)

        let reloaded = LibraryStore(rootURL: store.libraryURL)
        XCTAssertEqual(reloaded.items.first(where: { $0.id == item.id })?.format, "png")

        let failedRoot = root.appendingPathComponent("failed", isDirectory: true)
        let failingStore = LibraryStore(rootURL: failedRoot) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data("forbidden".utf8), response)
        }
        do {
            _ = try await failingStore.importRemote(metadata, folder: "照片素材")
            XCTFail("403 response must not create an asset")
        } catch LibraryImportError.serverStatus(let status) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(failingStore.items.count, 4)
    }

    func testCollectorUsesBrowserPayloadFallbackAndDeduplicatesSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaCollectorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-2.png")
        let imageData = try Data(contentsOf: source)
        let store = LibraryStore(rootURL: root) { _ in throw URLError(.userAuthenticationRequired) }
        let coordinator = CollectorImportCoordinator(store: store)
        let metadata = WebImageMetadata(
            imageURL: "https://protected.example.test/private-image",
            sourceURL: "https://protected.example.test/board",
            pageTitle: "需要登录的页面",
            suggestedName: "浏览器凭据兜底",
            sessionID: "credential-session"
        )
        BrowserPayloadCache.shared.store(imageData, sessionID: "credential-session", mimeType: "image/png")

        coordinator.importRemote(metadata, folder: "配色")
        for _ in 0..<30 {
            if case .duplicateReview = coordinator.phase { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        coordinator.resolveDuplicate(useExisting: true)

        guard case .addedToFolder(let title, let destination) = coordinator.phase else {
            return XCTFail("Collector did not reach success: \(coordinator.phase)")
        }
        XCTAssertEqual(title, "收藏到 Arata Art")
        XCTAssertEqual(destination, "配色")
        XCTAssertEqual(store.items.count, 4)
        let collected = try XCTUnwrap(store.items.first { $0.allFolders.contains("配色") })
        XCTAssertTrue(collected.allFolders.contains("文字设计"))
        XCTAssertNil(BrowserPayloadCache.shared.payload(for: "credential-session"))

        coordinator.importRemote(metadata, folder: "配色")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.items.count, 4, "The same drag session must only import once")
    }

    func testBrowserBridgeParsesPreflightAndFragmentedPost() throws {
        let options = Data("OPTIONS /drag HTTP/1.1\r\nOrigin: safari-web-extension://test\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(BrowserBridgeServer.httpMethod(from: options), "OPTIONS")
        XCTAssertTrue(BrowserBridgeServer.isCompleteRequest(options))
        XCTAssertEqual(BrowserBridgeServer.httpBody(from: options), Data())

        let json = Data("{\"type\":\"imageDragStarted\",\"imageURL\":\"https://example.com/a.jpg\"}".utf8)
        let header = Data("POST /drag HTTP/1.1\r\nContent-Type: application/json\r\nX-Inspiration-Bridge: inspiration-library-safari-extension-v1\r\nContent-Length: \(json.count)\r\n\r\n".utf8)
        let partial = header + json.prefix(json.count / 2)
        XCTAssertEqual(BrowserBridgeServer.httpMethod(from: partial), "POST")
        XCTAssertFalse(BrowserBridgeServer.isCompleteRequest(partial))
        XCTAssertNil(BrowserBridgeServer.httpBody(from: partial))

        let complete = header + json
        XCTAssertTrue(BrowserBridgeServer.isCompleteRequest(complete))
        XCTAssertEqual(BrowserBridgeServer.httpBody(from: complete), json)
        XCTAssertTrue(BrowserBridgeServer.isTrustedExtensionRequest(complete))

        let untrusted = Data("POST /drag HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\n\r\n".utf8) + json
        XCTAssertFalse(BrowserBridgeServer.isTrustedExtensionRequest(untrusted))

        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        let payloadHeader = Data("POST /payload HTTP/1.1\r\nContent-Type: application/octet-stream\r\nX-Inspiration-Bridge: inspiration-library-safari-extension-v1\r\nX-Inspiration-Session: session-42\r\nX-Inspiration-Mime: image/png\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        let payloadRequest = payloadHeader + payload
        XCTAssertEqual(BrowserBridgeServer.httpPath(from: payloadRequest), "/payload")
        XCTAssertEqual(BrowserBridgeServer.headerValue("x-inspiration-session", from: payloadRequest), "session-42")
        XCTAssertEqual(BrowserBridgeServer.headerValue("X-Inspiration-Mime", from: payloadRequest), "image/png")
        XCTAssertEqual(BrowserBridgeServer.contentLength(from: payloadRequest), payload.count)
        XCTAssertEqual(BrowserBridgeServer.httpBody(from: payloadRequest), payload)

        BrowserPayloadCache.shared.store(payload, sessionID: "session-42", mimeType: "image/png")
        XCTAssertEqual(BrowserPayloadCache.shared.payload(for: "session-42")?.data, payload)
        BrowserPayloadCache.shared.remove(sessionID: "session-42")
        XCTAssertNil(BrowserPayloadCache.shared.payload(for: "session-42"))
    }

    func testCollectorRejectsStaleOrNonSafariDragMessages() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let valid: [String: Any] = [
            "type": "imageDragStarted",
            "imageURL": "https://images.example.test/art.jpg",
            "sourceURL": "https://example.test/board",
            "timestamp": now.timeIntervalSince1970 * 1000
        ]

        XCTAssertTrue(DragCoordinator.shouldAcceptBrowserDrag(valid, frontmostBundleIdentifier: "com.apple.Safari", now: now))
        XCTAssertTrue(DragCoordinator.shouldAcceptBrowserDrag(valid, frontmostBundleIdentifier: "com.apple.SafariTechnologyPreview", now: now))
        XCTAssertFalse(DragCoordinator.shouldAcceptBrowserDrag(valid, frontmostBundleIdentifier: "com.apple.finder", now: now))

        var stale = valid
        stale["timestamp"] = now.addingTimeInterval(-6).timeIntervalSince1970 * 1000
        XCTAssertFalse(DragCoordinator.shouldAcceptBrowserDrag(stale, frontmostBundleIdentifier: "com.apple.Safari", now: now))

        var missingSource = valid
        missingSource.removeValue(forKey: "sourceURL")
        XCTAssertFalse(DragCoordinator.shouldAcceptBrowserDrag(missingSource, frontmostBundleIdentifier: "com.apple.Safari", now: now))
    }

    func testImportMetadataFolderLifecycleAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(rootURL: root)
        XCTAssertEqual(store.count(in: .folder("文字设计")), 4)

        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let imported = try store.importFile(at: source, folder: "照片素材")
        XCTAssertEqual(imported.format, "png")
        XCTAssertGreaterThan(imported.width, 0)
        XCTAssertGreaterThan(imported.height, 0)
        XCTAssertGreaterThan(imported.fileSize, 0)
        XCTAssertNotNil(store.imageURL(for: imported))
        XCTAssertNotNil(store.imageURL(for: imported, thumbnail: true))

        store.update(imported.id) {
            $0.name = "已编辑素材"
            $0.note = "来自测试"
            $0.tags = ["插画", "蓝色"]
            $0.rating = 4
        }
        let newFolder = store.addFolder(named: "研究")
        store.move(imported.id, to: newFolder)
        store.updateFolderNote(newFolder, note: "为视觉研究收集的参考")
        let renamed = store.renameFolder(newFolder, to: "参考")
        XCTAssertEqual(renamed, "参考")
        store.rememberSelection(.folder("参考"))

        let reloaded = LibraryStore(rootURL: root)
        let persisted = try XCTUnwrap(reloaded.items.first { $0.id == imported.id })
        XCTAssertEqual(persisted.name, "已编辑素材")
        XCTAssertEqual(persisted.note, "来自测试")
        XCTAssertEqual(persisted.tags, ["插画", "蓝色"])
        XCTAssertEqual(persisted.rating, 4)
        XCTAssertEqual(persisted.folder, "参考")
        XCTAssertEqual(reloaded.details(for: "参考").note, "为视觉研究收集的参考")
        XCTAssertEqual(reloaded.lastSelection, .folder("参考"))

        let collision = reloaded.renameFolder("参考", to: "照片素材")
        XCTAssertEqual(collision, "参考")
        XCTAssertTrue(reloaded.folders.contains("参考"))
        XCTAssertEqual(reloaded.items.first { $0.id == imported.id }?.folder, "参考")

        reloaded.deleteFolder("参考")
        XCTAssertEqual(reloaded.items.first { $0.id == imported.id }?.folder, "")
        XCTAssertEqual(reloaded.count(in: .section(.uncategorized)), 1)
        XCTAssertEqual(reloaded.lastSelection, .section(.uncategorized))
        XCTAssertEqual(LibraryStore(rootURL: root).lastSelection, .section(.uncategorized))
    }

    func testLegacyIndexMigratesFolderDetails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let legacy = """
        {
          "folders" : ["旧文件夹"],
          "items" : [],
          "smartFolders" : []
        }
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("index.json"))

        let migrated = LibraryStore(rootURL: root)
        XCTAssertEqual(migrated.folders, ["旧文件夹"])
        XCTAssertEqual(migrated.details(for: "旧文件夹").name, "旧文件夹")
        XCTAssertEqual(migrated.details(for: "旧文件夹").note, "")
    }

    func testSmartFoldersBatchEditingAndDuplicateScanning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAdvancedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(rootURL: root)
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/EagleReplica/Resources/poster-1.png")
        let first = try store.importFile(at: source, folder: "照片素材", allowDuplicate: true)
        let second = try store.importFile(at: source, folder: "照片素材", allowDuplicate: true)

        store.update(first.id) {
            $0.tags = ["蓝色", "插画"]
            $0.rating = 5
        }
        store.update([first.id, second.id]) {
            $0.note = "批量注释"
            $0.folder = "照片素材"
        }

        let smart = SmartFolder(
            name: "高分蓝色插画",
            matchMode: .all,
            rules: [
                SmartFolderRule(field: .tag, operation: .contains, value: "蓝色"),
                SmartFolderRule(field: .rating, operation: .greaterThan, value: "3")
            ]
        )
        let saved = store.addSmartFolder(smart)
        XCTAssertEqual(store.count(in: .smartFolder(saved.id)), 1)
        XCTAssertEqual(store.visibleItems(for: .smartFolder(saved.id), searchText: "", filter: .all, sort: .addedNewest).first?.id, first.id)

        let exact = DuplicateScanner.scan([first, second], mode: .exact, store: store)
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(Set(exact[0].items.map(\.id)), [first.id, second.id])

        let similar = DuplicateScanner.scan([first, second], mode: .similar, store: store)
        XCTAssertEqual(similar.count, 1)
        XCTAssertEqual(Set(similar[0].items.map(\.id)), [first.id, second.id])

        let reloaded = LibraryStore(rootURL: root)
        XCTAssertEqual(reloaded.smartFolders.first?.name, "高分蓝色插画")
        XCTAssertEqual(reloaded.items.first(where: { $0.id == second.id })?.note, "批量注释")
        XCTAssertEqual(reloaded.count(in: .smartFolder(saved.id)), 1)

        XCTAssertEqual(reloaded.count(in: .tag("蓝色")), 1)
        XCTAssertEqual(reloaded.tagCounts.first(where: { $0.name == "蓝色" })?.count, 1)
        reloaded.renameTag("蓝色", to: "青色")
        XCTAssertEqual(reloaded.count(in: .tag("蓝色")), 0)
        XCTAssertEqual(reloaded.count(in: .tag("青色")), 1)
        reloaded.deleteTag("青色")
        XCTAssertEqual(reloaded.count(in: .tag("青色")), 0)

        reloaded.update(first.id) { $0.lastOpenedAt = Date(timeIntervalSince1970: 100) }
        reloaded.update(second.id) { $0.lastOpenedAt = Date(timeIntervalSince1970: 200) }
        let recent = reloaded.visibleItems(for: .section(.recent), searchText: "", filter: .all, sort: .addedNewest)
        XCTAssertEqual(recent.prefix(2).map(\.id), [second.id, first.id])
        let randomFirst = reloaded.visibleItems(for: .section(.random), searchText: "", filter: .all, sort: .addedNewest).map(\.id)
        let randomSecond = reloaded.visibleItems(for: .section(.random), searchText: "", filter: .all, sort: .addedNewest).map(\.id)
        XCTAssertEqual(randomFirst, randomSecond)

        reloaded.permanentlyDelete([first.id, second.id])
        XCTAssertNil(reloaded.items.first(where: { $0.id == first.id }))
        XCTAssertNil(reloaded.items.first(where: { $0.id == second.id }))
        XCTAssertNil(reloaded.imageURL(for: first))
        XCTAssertNil(reloaded.imageURL(for: second, thumbnail: true))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: URLRequest) {
        lock.lock(); storedRequest = request; lock.unlock()
    }
}
