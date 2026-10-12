import CoreGraphics
import Foundation
import XCTest
@testable import EagleReplica

@MainActor
final class GalleryLayoutTests: XCTestCase {
    private func makeItems(_ ratios: [CGFloat]) -> [JustifiedGalleryLayout.Item] {
        ratios.map { JustifiedGalleryLayout.Item(id: UUID(), ratio: $0) }
    }

    func testCompleteRowsFillTheContainerWidth() {
        let items = makeItems(Array(repeating: 0.8, count: 12))
        let rows = JustifiedGalleryLayout.rows(for: items, containerWidth: 900, targetHeight: 160, spacing: 10)

        XCTAssertGreaterThan(rows.count, 1)
        for row in rows.dropLast() {
            let width = row.placements.reduce(0) { $0 + $1.width }
            let gaps = 10 * CGFloat(max(0, row.placements.count - 1))
            XCTAssertEqual(width + gaps, 900, accuracy: 0.5, "完整行要刚好铺满容器宽度")
        }
    }

    func testEveryPlacementKeepsItsOriginalRatio() throws {
        let items = makeItems([1.5, 0.667, 1.0, 0.5, 2.4, 0.75, 1.33])
        let ratioByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.ratio) })
        let rows = JustifiedGalleryLayout.rows(for: items, containerWidth: 820, targetHeight: 180, spacing: 12)

        for row in rows {
            XCTAssertGreaterThan(row.height, 0)
            for placement in row.placements {
                let expected = try XCTUnwrap(ratioByID[placement.id])
                XCTAssertEqual(placement.width / placement.height, expected, accuracy: 0.01)
            }
        }
    }

    func testItemsKeepTheirOrderAndNoneAreDropped() {
        let items = makeItems((0..<15).map { [0.7, 1.4, 1.0][$0 % 3] })
        let rows = JustifiedGalleryLayout.rows(for: items, containerWidth: 700, targetHeight: 150, spacing: 8)

        XCTAssertEqual(rows.flatMap { $0.placements.map(\.id) }, items.map(\.id))
    }

    func testTrailingRowIsNotStretchedBeyondTheTargetHeight() {
        let items = makeItems([0.8, 0.8, 0.8])
        let rows = JustifiedGalleryLayout.rows(for: items, containerWidth: 900, targetHeight: 150, spacing: 10)

        XCTAssertEqual(rows.count, 1)
        XCTAssertLessThanOrEqual(rows[0].height, 150.001, "最后一行不足时应保持目标高度，不把图片拉大")
    }

    func testRowHeightStaysNearTheTargetForMixedRatios() {
        let items = makeItems((0..<20).map { [1.6, 1.0, 0.66][$0 % 3] })
        let rows = JustifiedGalleryLayout.rows(for: items, containerWidth: 1000, targetHeight: 170, spacing: 10)

        XCTAssertGreaterThan(rows.count, 1)
        for row in rows.dropLast() {
            XCTAssertLessThanOrEqual(row.height, 170.001)
            XCTAssertGreaterThan(row.height, 170 * 0.55, "行高不该比目标高度小太多，否则会显得稀碎")
        }
    }

    func testDegenerateInputProducesNoRows() {
        XCTAssertTrue(JustifiedGalleryLayout.rows(for: [], containerWidth: 800, targetHeight: 160, spacing: 10).isEmpty)
        XCTAssertTrue(JustifiedGalleryLayout.rows(for: makeItems([1]), containerWidth: 10, targetHeight: 160, spacing: 10).isEmpty)
        XCTAssertTrue(JustifiedGalleryLayout.rows(for: makeItems([1]), containerWidth: 800, targetHeight: 0, spacing: 10).isEmpty)
    }

    func testCompactModeKicksInBelowTheThresholdAndAllowsBiggerThumbnails() {
        XCTAssertTrue(ThumbnailScaleMath.isCompact(ThumbnailScaleMath.compactThreshold - 1))
        XCTAssertFalse(ThumbnailScaleMath.isCompact(ThumbnailScaleMath.compactThreshold))
        XCTAssertFalse(ThumbnailScaleMath.isCompact(156), "默认尺寸要保持显示名称")
        XCTAssertEqual(ThumbnailScaleMath.range.lowerBound, 76)
        XCTAssertEqual(ThumbnailScaleMath.range.upperBound, 380)
    }

    func testDisplayAspectRatioUsesPixelSizeAndFallsBackWhenUnknown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EagleReplicaAspect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let seeded = try XCTUnwrap(store.items.first)
        XCTAssertEqual(seeded.displayAspectRatio, CGFloat(seeded.width) / CGFloat(seeded.height), accuracy: 0.0001)

        let unknown = LibraryItem(
            id: UUID(), name: "无尺寸", note: "", width: 0, height: 0,
            storedFilename: nil, bundledResource: nil, fileSize: 0, format: "jpg",
            folder: "", sourceURL: nil, tags: [], rating: 0, colorLabel: nil,
            createdAt: Date(), modifiedAt: Date(), lastOpenedAt: nil, isTrashed: false
        )
        XCTAssertEqual(unknown.displayAspectRatio, 1 / 1.24, accuracy: 0.0001)
    }
}
