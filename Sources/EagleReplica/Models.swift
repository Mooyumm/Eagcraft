import Foundation

extension Notification.Name {
    static let libraryNewFolder = Notification.Name("EagleReplica.libraryNewFolder")
    static let libraryImport = Notification.Name("EagleReplica.libraryImport")
    static let libraryPreviewSelection = Notification.Name("EagleReplica.libraryPreviewSelection")
    static let libraryToggleSidebar = Notification.Name("EagleReplica.libraryToggleSidebar")
    static let libraryToggleInspector = Notification.Name("EagleReplica.libraryToggleInspector")
    static let libraryDidImportAsset = Notification.Name("EagleReplica.libraryDidImportAsset")
    static let aiSettingsDidChange = Notification.Name("EagleReplica.aiSettingsDidChange")
    static let libraryDidSave = Notification.Name("EagleReplica.libraryDidSave")
    static let libraryCopySelection = Notification.Name("EagleReplica.libraryCopySelection")
    static let libraryPasteClipboard = Notification.Name("EagleReplica.libraryPasteClipboard")
    static let libraryShowToast = Notification.Name("EagleReplica.libraryShowToast")
}

struct WebImageMetadata: Codable, Hashable {
    var imageURL: String
    var sourceURL: String? = nil
    var pageTitle: String? = nil
    var suggestedName: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var sessionID: String? = nil
    var timestamp: Double? = nil
}

enum LibraryImportError: LocalizedError {
    case invalidURL
    case unsupportedURLScheme
    case serverStatus(Int)
    case emptyResponse
    case fileTooLarge
    case unsupportedImage

    var errorDescription: String? {
        switch self {
        case .invalidURL: "图片地址无效"
        case .unsupportedURLScheme: "该网页图片地址无法直接下载"
        case .serverStatus(let code): "图片服务器返回错误（HTTP \(code)）"
        case .emptyResponse: "图片服务器没有返回内容"
        case .fileTooLarge: "图片超过 80 MB，未加入素材库"
        case .unsupportedImage: "下载内容不是可识别的图片"
        }
    }
}

struct LibraryItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var note: String
    var width: Int
    var height: Int
    var storedFilename: String?
    var bundledResource: String?
    var fileSize: Int64
    var format: String
    var folder: String
    var referenceFolder: String? = nil
    var sourceURL: String?
    var tags: [String]
    var aiTags: [String]? = nil
    var aiPrompt: String? = nil
    /// The first title proposed by AI. `nil` means this asset has never completed AI naming.
    var aiGeneratedName: String? = nil
    /// Optional for backward-compatible decoding of libraries created before AI naming existed.
    var isManuallyNamed: Bool? = nil
    var rating: Int
    var colorLabel: Int?
    var createdAt: Date
    var modifiedAt: Date
    var lastOpenedAt: Date?
    var isTrashed: Bool
    var eagleID: String? = nil
    var additionalFolders: [String]? = nil
    var palette: [AssetPaletteColor]? = nil
    var noThumbnail: Bool? = nil
    var trashedAt: Date? = nil
    var aiChatMessages: [AIChatMessage]? = nil
    /// An explicit “keep both” decision must survive later automatic scans.
    var keepDuplicate: Bool? = nil
    var additionalReferenceFolders: [String]? = nil

    var dimensions: String { "\(width) × \(height)" }
    var extensionBadge: String { format.uppercased() }
    var machineTags: [String] { aiTags ?? [] }
    var hasCompletedAINaming: Bool { aiGeneratedName != nil }
    var hasManualName: Bool { isManuallyNamed == true }
    var chatMessages: [AIChatMessage] { aiChatMessages ?? [] }
    var allTags: [String] { (tags + machineTags).uniqued() }
    var allFolders: [String] {
        ([folder] + (additionalFolders ?? [])).filter { !$0.isEmpty }.uniqued()
    }
    var allReferenceFolders: [String] {
        ([referenceFolder].compactMap { $0 } + (additionalReferenceFolders ?? [])).filter { !$0.isEmpty }.uniqued()
    }
}

enum AIChatRole: String, Codable, Hashable {
    case user
    case assistant
}

struct AIChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: AIChatRole
    var content: String
    var createdAt: Date = Date()
}

enum TrashRetentionPolicy {
    static let defaultsKey = "EagleReplica.trash.retentionDays"
    static let defaultDays = 30
    static let allowedDays = 1...365

    static func normalizedDays(_ days: Int) -> Int {
        min(allowedDays.upperBound, max(allowedDays.lowerBound, days))
    }

    static func deadline(trashedAt: Date, retentionDays: Int) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: normalizedDays(retentionDays),
            to: trashedAt
        ) ?? trashedAt
    }

    static func remainingDays(trashedAt: Date, retentionDays: Int, now: Date = Date()) -> Int {
        let interval = deadline(trashedAt: trashedAt, retentionDays: retentionDays).timeIntervalSince(now)
        return max(0, Int(ceil(interval / 86_400)))
    }

    static func isExpired(trashedAt: Date, retentionDays: Int, now: Date = Date()) -> Bool {
        deadline(trashedAt: trashedAt, retentionDays: retentionDays) <= now
    }

    static func statusText(trashedAt: Date, retentionDays: Int, now: Date = Date()) -> String {
        let days = remainingDays(trashedAt: trashedAt, retentionDays: retentionDays, now: now)
        return days == 0 ? "今天自动删除" : "还有 \(days) 天删除"
    }
}

struct AIStyleGroup: Identifiable, Hashable {
    let name: String
    let items: [LibraryItem]

    var id: String { name }
}

enum StyleFavoritesStorage {
    static func decode(_ data: String) -> Set<String> {
        guard let encoded = data.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: encoded) else { return [] }
        return Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    static func encode(_ names: Set<String>) -> String {
        let ordered = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(ordered),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }

    static func favorites(in groups: [AIStyleGroup], favoriteNames: Set<String>) -> [AIStyleGroup] {
        groups.filter { favoriteNames.contains($0.name) }
    }
}

enum AIStyleIndex {
    nonisolated private static let styleKeywords = [
        "风格", "主义", "摄影", "插画", "海报", "排版", "字体", "拼贴", "手绘", "水彩", "油画",
        "版画", "像素", "三维", "3d", "扁平", "抽象", "黑白", "电影", "编辑", "现代", "东方",
        "日系", "韩系", "极简", "复古", "未来", "赛博", "孟菲斯", "包豪斯", "波普", "故障",
        "霓虹", "暗黑", "梦幻", "超现实", "写实", "minimal", "vintage", "retro", "editorial",
        "collage", "illustration", "photography", "typography", "brutalism", "bauhaus", "surreal",
        "cinematic", "monochrome", "futuristic", "cyberpunk", "y2k", "flat"
    ]

    static func groups(in items: [LibraryItem]) -> [AIStyleGroup] {
        let activeItems = items.filter { !$0.isTrashed && !$0.machineTags.isEmpty }
        let allTags = orderedUnique(activeItems.flatMap(\.machineTags))
        let styleTags = allTags.filter(isStyleTag)
        let groupingTags = styleTags.isEmpty ? allTags : styleTags

        return groupingTags.compactMap { tag in
            let matches = activeItems.filter { item in
                item.machineTags.contains { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            }
            return matches.isEmpty ? nil : AIStyleGroup(name: tag, items: matches)
        }
        .sorted {
            if $0.items.count != $1.items.count { return $0.items.count > $1.items.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func isStyleTag(_ tag: String) -> Bool {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && styleKeywords.contains { normalized.contains($0) }
    }

    private static func orderedUnique(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { rawTag in
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !tag.isEmpty, seen.insert(key).inserted else { return nil }
            return tag
        }
    }
}

struct AssetPaletteColor: Codable, Hashable, Identifiable, Sendable {
    var color: [Int]
    var ratio: Double
    var id: String { color.map(String.init).joined(separator: "-") + "-\(ratio)" }
}

struct FolderDetails: Identifiable, Codable, Hashable {
    var id: String { name }
    var name: String
    var note: String = ""
    var createdAt: Date = Date()
    var eagleID: String? = nil
    var parentEagleID: String? = nil
    var childEagleIDs: [String]? = nil
    var tags: [String]? = nil
    var password: String? = nil
    var passwordTips: String? = nil
    var modifiedAt: Date? = nil
}

struct EagleLibraryExtras: Codable, Hashable {
    var metadataJSON: Data?
    var tagsJSON: Data?
    var savedFiltersJSON: Data?
    var applicationVersion: String?
}

enum LibrarySection: String, Codable, CaseIterable, Identifiable {
    case all = "全部"
    case uncategorized = "未分类"
    case untagged = "未标签"
    case recent = "最近使用"
    case random = "随机模式"
    case community = "资源社区"
    case tags = "标签管理"
    case trash = "回收站"

    var id: String { rawValue }

    var title: String {
        self == .community ? "风格库" : rawValue
    }

    var icon: String {
        switch self {
        case .all: "tray"
        case .uncategorized: "folder.badge.questionmark"
        case .untagged: "tag.slash"
        case .recent: "clock"
        case .random: "shuffle"
        case .community: "square.grid.2x2"
        case .tags: "bookmark"
        case .trash: "trash"
        }
    }
}

enum PreviewScrollBehavior: String, CaseIterable, Identifiable {
    case vertical = "垂直浏览"
    case zoom = "缩放图片"
    case paging = "左右翻页"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .vertical: "rectangle.stack"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .paging: "rectangle.portrait.on.rectangle.portrait.angled"
        }
    }

    var detail: String {
        switch self {
        case .vertical: "滚轮切换上一张或下一张"
        case .zoom: "滚轮直接放大或缩小当前图片"
        case .paging: "滚轮以左右方向翻阅素材"
        }
    }
}

enum SidebarSelection: Codable, Hashable {
    case section(LibrarySection)
    case folder(String)
    case referenceFolder(String)
    case smartFolder(UUID)
    case tag(String)

    var title: String {
        switch self {
        case .section(let section): section.title
        case .folder(let folder): folder
        case .referenceFolder(let folder): folder
        case .smartFolder: "智能文件夹"
        case .tag(let tag): tag
        }
    }
}

enum SmartMatchMode: String, Codable, CaseIterable, Identifiable {
    case all = "全部"
    case any = "任一"
    var id: String { rawValue }
}

enum SmartRuleField: String, Codable, CaseIterable, Identifiable {
    case name = "名称"
    case format = "格式"
    case tag = "标签"
    case aiTag = "AI 标签"
    case folder = "文件夹"
    case color = "颜色"
    case addedDate = "添加日期"
    case modifiedDate = "修改日期"
    case source = "链接"
    case note = "注释"
    case width = "宽度"
    case height = "高度"
    case fileSize = "文件大小"
    case shape = "形状"
    case rating = "评分"
    var id: String { rawValue }

    var isNumeric: Bool { [.width, .height, .fileSize, .rating].contains(self) }
    var isDate: Bool { self == .addedDate || self == .modifiedDate }
}

enum SmartRuleOperator: String, Codable, CaseIterable, Identifiable {
    case contains = "包含"
    case notContains = "不包含"
    case beginsWith = "开头为"
    case endsWith = "结尾为"
    case equals = "相等"
    case isEmpty = "没有内容"
    case isNotEmpty = "有内容"
    case regex = "正则表达式"
    case greaterThan = "大于"
    case lessThan = "小于"
    case onOrAfter = "不早于"
    case onOrBefore = "不晚于"
    var id: String { rawValue }

    static func choices(for field: SmartRuleField) -> [SmartRuleOperator] {
        if field.isNumeric { return [.equals, .greaterThan, .lessThan] }
        if field.isDate { return [.onOrAfter, .onOrBefore] }
        return [.contains, .notContains, .beginsWith, .endsWith, .equals, .isEmpty, .isNotEmpty, .regex]
    }
}

struct SmartFolderRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var field: SmartRuleField = .name
    var operation: SmartRuleOperator = .contains
    var value: String = ""
}

struct SmartFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var matchMode: SmartMatchMode = .all
    var rules: [SmartFolderRule] = [SmartFolderRule()]
    /// Non-nil only for folders maintained by the automatic AI classifier.
    /// Optional keeps existing library indexes backward compatible.
    var aiGeneratedTag: String? = nil

    func matches(_ item: LibraryItem) -> Bool {
        let results = rules.map { $0.matches(item) }
        return matchMode == .all ? results.allSatisfy { $0 } : results.contains(true)
    }
}

private extension SmartFolderRule {
    func matches(_ item: LibraryItem) -> Bool {
        if field.isNumeric {
            let actual: Double
            switch field {
            case .width: actual = Double(item.width)
            case .height: actual = Double(item.height)
            case .fileSize: actual = Double(item.fileSize)
            case .rating: actual = Double(item.rating)
            default: actual = 0
            }
            let expected = Double(value) ?? 0
            switch operation {
            case .greaterThan: return actual > expected
            case .lessThan: return actual < expected
            default: return actual == expected
            }
        }

        if field.isDate {
            let actual = field == .addedDate ? item.createdAt : item.modifiedAt
            let formatter = ISO8601DateFormatter()
            guard let expected = formatter.date(from: value) else { return false }
            return operation == .onOrBefore ? actual <= expected : actual >= expected
        }

        if field == .aiTag {
            let values = item.machineTags
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            switch operation {
            case .equals: return values.contains { $0.compare(value, options: options) == .orderedSame }
            case .contains: return values.contains { $0.range(of: value, options: options) != nil }
            case .notContains: return !values.contains { $0.range(of: value, options: options) != nil }
            case .beginsWith: return values.contains { $0.range(of: value, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
            case .endsWith: return values.contains { $0.lowercased().hasSuffix(value.lowercased()) }
            case .isEmpty: return values.isEmpty
            case .isNotEmpty: return !values.isEmpty
            case .regex:
                guard let expression = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
                return values.contains { expression.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            default: return false
            }
        }

        let actual: String
        switch field {
        case .name: actual = item.name
        case .format: actual = item.format
        case .tag: actual = item.allTags.joined(separator: " ")
        case .aiTag: actual = ""
        case .folder: actual = item.folder
        case .color: actual = item.colorLabel.map(String.init) ?? ""
        case .source: actual = item.sourceURL ?? ""
        case .note: actual = item.note
        case .shape: actual = item.width == item.height ? "方形" : (item.width > item.height ? "横图" : "竖图")
        default: actual = ""
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch operation {
        case .contains: return actual.range(of: value, options: options) != nil
        case .notContains: return actual.range(of: value, options: options) == nil
        case .beginsWith: return actual.lowercased().hasPrefix(value.lowercased())
        case .endsWith: return actual.lowercased().hasSuffix(value.lowercased())
        case .equals: return actual.compare(value, options: options) == .orderedSame
        case .isEmpty: return actual.isEmpty
        case .isNotEmpty: return !actual.isEmpty
        case .regex: return (try? NSRegularExpression(pattern: value, options: [.caseInsensitive]))?.firstMatch(in: actual, range: NSRange(actual.startIndex..., in: actual)) != nil
        default: return false
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case addedNewest = "添加日期（新到旧）"
    case addedOldest = "添加日期（旧到新）"
    case nameAscending = "名称（A–Z）"
    case nameDescending = "名称（Z–A）"
    case fileSize = "文件大小"
    var id: String { rawValue }
}

enum AssetFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case tagged = "有标签"
    case rated = "有评分"
    case landscape = "横图"
    case portrait = "竖图"
    var id: String { rawValue }
}

struct LibraryIndex: Codable {
    var folders: [String]
    var referenceFolders: [String]? = nil
    var items: [LibraryItem]
    var smartFolders: [SmartFolder]?
    var folderDetails: [FolderDetails]?
    var lastSelection: SidebarSelection?
    var eagleExtras: EagleLibraryExtras? = nil
    var favoriteStyles: [String]? = nil
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
