import AppKit
import CryptoKit
import Foundation
import Vision

enum DuplicateScanMode: String, CaseIterable, Identifiable {
    case exact = "相同文件"
    case similar = "相似图像"
    var id: String { rawValue }
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    var items: [LibraryItem]
}

@MainActor
enum DuplicateScanner {
    static let defaultVisionDistance: Float = 0.12
    private static var featureCache: [String: VNFeaturePrintObservation] = [:]

    static func scan(_ items: [LibraryItem], mode: DuplicateScanMode, store: LibraryStore) -> [DuplicateGroup] {
        switch mode {
        case .exact: exactGroups(items, store: store)
        case .similar: similarGroups(items, store: store)
        }
    }

    private static func exactGroups(_ items: [LibraryItem], store: LibraryStore) -> [DuplicateGroup] {
        var groups: [String: [LibraryItem]] = [:]
        for item in items {
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            groups[digest, default: []].append(item)
        }
        return groups.values.filter { $0.count > 1 }
            .map { DuplicateGroup(items: $0.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.items.count > $1.items.count }
    }

    private static func similarGroups(_ items: [LibraryItem], store: LibraryStore) -> [DuplicateGroup] {
        let described: [(LibraryItem, VNFeaturePrintObservation?, UInt64?)] = items.compactMap { item in
            guard let url = store.imageURL(for: item) else { return nil }
            return (item, featurePrint(url: url), averageHash(url))
        }
        guard described.count > 1 else { return [] }
        var parent = Array(described.indices)
        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current { current = parent[current] }
            return current
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let left = root(lhs), right = root(rhs)
            if left != right { parent[right] = left }
        }
        for lhs in described.indices {
            for rhs in described.indices where rhs > lhs {
                let isSimilar: Bool
                if let left = described[lhs].1, let right = described[rhs].1,
                   let distance = distance(left, right) {
                    isSimilar = distance <= defaultVisionDistance
                } else if let left = described[lhs].2, let right = described[rhs].2 {
                    isSimilar = (left ^ right).nonzeroBitCount <= 6
                } else {
                    isSimilar = false
                }
                if isSimilar { union(lhs, rhs) }
            }
        }
        var groups: [Int: [LibraryItem]] = [:]
        for index in described.indices { groups[root(index), default: []].append(described[index].0) }
        return groups.values.filter { $0.count > 1 }
            .map { DuplicateGroup(items: $0.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.items.count > $1.items.count }
    }

    static func mostSimilarItem(
        to data: Data,
        among items: [LibraryItem],
        store: LibraryStore,
        maximumDistance: Float = 0.12
    ) -> (item: LibraryItem, distance: Float)? {
        guard let incoming = featurePrint(data: data) else { return nil }
        var best: (LibraryItem, Float)?
        for item in items where !item.isTrashed {
            guard let url = store.imageURL(for: item), let existing = featurePrint(url: url),
                  let value = distance(incoming, existing), value <= maximumDistance else { continue }
            if best == nil || value < best!.1 { best = (item, value) }
        }
        return best
    }

    private static func featurePrint(url: URL) -> VNFeaturePrintObservation? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(modified)"
        if let cached = featureCache[key] { return cached }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url)
        guard (try? handler.perform([request])) != nil else { return nil }
        guard let result = request.results?.first as? VNFeaturePrintObservation else { return nil }
        if featureCache.count >= 5_000 { featureCache.removeAll(keepingCapacity: true) }
        featureCache[key] = result
        return result
    }

    private static func featurePrint(data: Data) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(data: data)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func distance(_ lhs: VNFeaturePrintObservation, _ rhs: VNFeaturePrintObservation) -> Float? {
        var value: Float = 0
        guard (try? lhs.computeDistance(&value, to: rhs)) != nil else { return nil }
        return value
    }

    private static func averageHash(_ url: URL) -> UInt64? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 64)
        guard let context = CGContext(
            data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return pixels.enumerated().reduce(UInt64(0)) { value, pair in
            pair.element >= average ? value | (UInt64(1) << UInt64(pair.offset)) : value
        }
    }
}
