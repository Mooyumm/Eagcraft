import CoreGraphics
import Foundation

extension LibraryItem {
    /// 网格排版用的宽高比（宽 ÷ 高）。缺少像素信息时沿用原来的竖版比例，
    /// 让没有尺寸的素材也能正常排进去。
    var displayAspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 / 1.24 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// 素材网格的排版计算。
///
/// 每张缩略图都按原图比例显示，不做裁切；同一行统一高度，行内按各自比例分配宽度，
/// 整行刚好铺满容器宽度。这样横图宽、竖图窄，既保留原始比例，也不会留下成片的空白。
enum JustifiedGalleryLayout {
    /// 参与排版的一张素材：只要 ID 与宽高比。
    struct Item: Equatable {
        let id: UUID
        let ratio: CGFloat
    }

    struct Placement: Equatable {
        let id: UUID
        let width: CGFloat
        let height: CGFloat
    }

    struct Row: Equatable {
        let height: CGFloat
        let placements: [Placement]
    }

    /// 宽高比的下限。极端长条图（比如很长的卷轴）会让一行只剩一张，
    /// 这里兜个底，避免出现宽度不到 1 点的格子。
    private static let minimumRatio: CGFloat = 0.06

    static func rows(
        for items: [Item],
        containerWidth: CGFloat,
        targetHeight: CGFloat,
        spacing: CGFloat
    ) -> [Row] {
        guard !items.isEmpty, containerWidth > 40, targetHeight > 20, spacing >= 0 else { return [] }

        var rows: [Row] = []
        var current: [Item] = []
        var ratioSum: CGFloat = 0

        func closeRow() {
            guard !current.isEmpty else { return }
            let available = containerWidth - spacing * CGFloat(current.count - 1)
            // 已经够一行时高度必然 ≤ 目标高度；最后一行不足时按目标高度收，
            // 宁可左边留白，也不把少数几张图拉得过大。
            let height = min(available / max(ratioSum, minimumRatio), targetHeight)
            rows.append(Row(
                height: height,
                placements: current.map {
                    Placement(id: $0.id, width: max(1, $0.ratio * height), height: height)
                }
            ))
            current.removeAll()
            ratioSum = 0
        }

        for item in items {
            let ratio = max(item.ratio, minimumRatio)
            current.append(Item(id: item.id, ratio: ratio))
            ratioSum += ratio
            let available = containerWidth - spacing * CGFloat(current.count - 1)
            if available / ratioSum <= targetHeight { closeRow() }
        }
        closeRow()
        return rows
    }
}
