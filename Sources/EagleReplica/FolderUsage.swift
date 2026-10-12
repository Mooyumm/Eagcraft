import Foundation

/// 单个文件夹的使用记录。
struct FolderUsageRecord: Codable, Equatable {
    var score: Int
    var lastUsedAt: Date
}

/// 本机保存的文件夹使用账本。
///
/// 只用来决定**采集框**里文件夹的排列顺序，主程序侧栏的手动顺序完全不受影响。
/// 数据只写进本机 UserDefaults，不进入素材库索引、也不参与 iCloud 同步，
/// 所以两台 Mac 各记各的使用习惯。
struct FolderUsageLedger: Codable, Equatable {
    /// 进入文件夹的分值。
    static let openedWeight = 1
    /// 把素材放进文件夹（导入、拖入、移动）的分值，让整理行为比浏览行为权重更高。
    static let importedWeight = 3

    private(set) var records: [String: FolderUsageRecord] = [:]

    func score(for folder: String) -> Int { records[folder]?.score ?? 0 }

    func lastUsedAt(for folder: String) -> Date? { records[folder]?.lastUsedAt }

    mutating func record(_ folder: String, weight: Int, at date: Date = Date()) {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, weight > 0 else { return }
        var record = records[name] ?? FolderUsageRecord(score: 0, lastUsedAt: date)
        record.score += weight
        record.lastUsedAt = max(record.lastUsedAt, date)
        records[name] = record
    }

    mutating func rename(_ oldName: String, to newName: String) {
        guard oldName != newName, let moved = records.removeValue(forKey: oldName) else { return }
        var merged = records[newName] ?? FolderUsageRecord(score: 0, lastUsedAt: moved.lastUsedAt)
        merged.score += moved.score
        merged.lastUsedAt = max(merged.lastUsedAt, moved.lastUsedAt)
        records[newName] = merged
    }

    mutating func remove(_ folder: String) {
        records.removeValue(forKey: folder)
    }

    /// 丢弃已经不在资源库里的文件夹记录，避免账本无限增长。
    mutating func prune(keeping folderNames: Set<String>) {
        records = records.filter { folderNames.contains($0.key) }
    }

    /// 按使用频次排序：分数高的在前；同分时最近用过的在前；再相同则保留手动顺序，
    /// 让结果稳定、可预期。没有记录的文件夹会自动落回原来的位置。
    static func ordered(_ folders: [String], by ledger: FolderUsageLedger) -> [String] {
        let manualIndex = Dictionary(
            folders.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return folders.sorted { lhs, rhs in
            let lhsScore = ledger.score(for: lhs)
            let rhsScore = ledger.score(for: rhs)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            let lhsDate = ledger.lastUsedAt(for: lhs)
            let rhsDate = ledger.lastUsedAt(for: rhs)
            if lhsDate != rhsDate { return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast) }
            return (manualIndex[lhs] ?? 0) < (manualIndex[rhs] ?? 0)
        }
    }
}
