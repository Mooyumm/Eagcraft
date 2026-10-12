import AppKit
import Combine
import SwiftUI

struct BrowserImagePayload {
    let data: Data
    let mimeType: String?
    let createdAt: Date
}

@MainActor
final class BrowserPayloadCache {
    static let shared = BrowserPayloadCache()
    private var payloads: [String: BrowserImagePayload] = [:]

    private init() {}

    func store(_ data: Data, sessionID: String, mimeType: String?) {
        guard !sessionID.isEmpty, sessionID.count <= 128, !data.isEmpty, data.count <= 80 * 1024 * 1024 else { return }
        removeExpired()
        payloads[sessionID] = BrowserImagePayload(data: data, mimeType: mimeType, createdAt: Date())
        while payloads.count > 4 || payloads.values.reduce(0, { $0 + $1.data.count }) > 160 * 1024 * 1024 {
            guard let oldest = payloads.min(by: { $0.value.createdAt < $1.value.createdAt })?.key else { break }
            payloads.removeValue(forKey: oldest)
        }
    }

    func payload(for sessionID: String) -> BrowserImagePayload? {
        removeExpired()
        return payloads[sessionID]
    }

    func remove(sessionID: String?) {
        guard let sessionID else { return }
        payloads.removeValue(forKey: sessionID)
    }

    private func removeExpired() {
        let cutoff = Date().addingTimeInterval(-120)
        payloads = payloads.filter { $0.value.createdAt >= cutoff }
    }
}

@MainActor
final class DragCoordinator: ObservableObject {
    static let shared = DragCoordinator()
    static let visibleFolderRows = 6
    private var dragMonitor: Any?
    private var applicationActivationObserver: NSObjectProtocol?
    private var autoScrollTimer: Timer?
    private var autoScrollDirection = 0
    private var lastDragPoint: NSPoint?
    private var didShowForCurrentDrag = false
    private(set) var latestMetadata: WebImageMetadata?
    private var latestMetadataAt: Date?
    private var activeSessionID: String?
    @Published private(set) var hoveredFolder: String?
    @Published private(set) var isHoveringDropTarget = false
    @Published private(set) var isHoveringCreateFolder = false
    @Published private(set) var folderScrollIndex = 0
    private var lastAcceptedSessionID: String?

    private init() {}

    func startMonitoring() {
        guard dragMonitor == nil else { return }
        // The browser extension is the authoritative trigger. A global drag
        // monitor cannot distinguish an image from selected text or a link.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .scrollWheel]) { event in
            Task { @MainActor in
                if event.type == .scrollWheel {
                    self.handleGlobalScroll(event)
                    return
                }
                self.updateDropTarget(at: NSEvent.mouseLocation, managesAutoScroll: event.type == .leftMouseDragged)
                if event.type == .leftMouseUp {
                    self.stopAutoScroll()
                    self.didShowForCurrentDrag = false
                    self.handleGlobalMouseUp()
                }
            }
        }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard !Self.isSafariBundleIdentifier(application?.bundleIdentifier) else { return }
                self?.cancelActiveBrowserDrag()
            }
        }
    }

    func stopMonitoring() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
        applicationActivationObserver = nil
        stopAutoScroll()
    }

    func metadata(from pasteboard: NSPasteboard) -> WebImageMetadata? {
        let custom = NSPasteboard.PasteboardType("application/x-eagle-replica")
        if let value = pasteboard.string(forType: custom),
           let data = value.data(using: .utf8),
           let metadata = try? JSONDecoder().decode(WebImageMetadata.self, from: data) { return metadata }
        guard let latestMetadataAt, Date().timeIntervalSince(latestMetadataAt) < 120 else { return nil }
        return latestMetadata
    }

    func dragWasAccepted(sessionID: String?) {
        didShowForCurrentDrag = false
        lastAcceptedSessionID = sessionID
        hoveredFolder = nil
        isHoveringDropTarget = false
        isHoveringCreateFolder = false
        stopAutoScroll()
        folderScrollIndex = 0
        if let sessionID, activeSessionID == sessionID { activeSessionID = nil }
    }

    func updateHoveredFolder(_ folder: String?, active: Bool = true, createsFolder: Bool = false) {
        hoveredFolder = folder
        isHoveringDropTarget = active
        isHoveringCreateFolder = active && createsFolder
    }

    func commitActiveSessionForTesting(sessionID: String, folder: String) -> Bool {
        guard ProcessInfo.processInfo.environment["INSPIRATION_ENABLE_TEST_COMMIT"] == "1",
              latestMetadata?.sessionID == sessionID,
              let latestMetadataAt,
              Date().timeIntervalSince(latestMetadataAt) < 120,
              let metadata = latestMetadata else { return false }
        CollectorImportCoordinator.shared.importRemote(metadata, folder: folder)
        dragWasAccepted(sessionID: sessionID)
        return true
    }

    func handleBrowserMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        if type == "imageDragDropped" {
            guard Self.acceptsDropMessage(message, activeSessionID: activeSessionID, now: Date()),
                  Self.isSafariBundleIdentifier(NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
                  CollectorPanelController.shared.contains(NSEvent.mouseLocation) else { return }
            handleGlobalMouseUp()
            return
        }
        if type == "imageDragEnded" {
            let endedSessionID = message["sessionID"] as? String
            guard endedSessionID == nil || activeSessionID == nil || endedSessionID == activeSessionID else { return }
            didShowForCurrentDrag = false
            if !CollectorPanelController.shared.contains(NSEvent.mouseLocation) {
                cancelActiveBrowserDrag()
            }
            return
        }
        guard type == "imageDragStarted",
              Self.shouldAcceptBrowserDrag(
                message,
                frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                now: Date()
              ),
              let imageURL = message["imageURL"] as? String else { return }
        let sessionID = message["sessionID"] as? String ?? UUID().uuidString
        let metadata = WebImageMetadata(
            imageURL: imageURL,
            sourceURL: message["sourceURL"] as? String,
            pageTitle: message["pageTitle"] as? String,
            suggestedName: message["suggestedName"] as? String,
            width: (message["width"] as? NSNumber)?.intValue,
            height: (message["height"] as? NSNumber)?.intValue,
            sessionID: sessionID,
            timestamp: (message["timestamp"] as? NSNumber)?.doubleValue
        )
        latestMetadata = metadata
        latestMetadataAt = Date()
        activeSessionID = sessionID
        hoveredFolder = nil
        isHoveringDropTarget = false
        isHoveringCreateFolder = false
        stopAutoScroll()
        folderScrollIndex = 0
        CollectorImportCoordinator.shared.prepareForDrag(metadata)
        guard !didShowForCurrentDrag else { return }
        didShowForCurrentDrag = true
        if let x = (message["cursorScreenX"] as? NSNumber)?.doubleValue,
           let y = (message["cursorScreenY"] as? NSNumber)?.doubleValue,
           x.isFinite, y.isFinite {
            CollectorPanelController.shared.showNearBrowserPoint(x: x, y: y)
        } else {
            CollectorPanelController.shared.showNearMouse()
        }
    }

    private func handleGlobalMouseUp() {
        let mouse = NSEvent.mouseLocation
        updateDropTarget(at: mouse)
        guard isHoveringDropTarget,
              let sessionID = activeSessionID,
              let metadata = latestMetadata,
              metadata.sessionID == sessionID else {
            cancelActiveBrowserDrag()
            return
        }
        if isHoveringCreateFolder {
            CollectorImportCoordinator.shared.requestNewFolder(for: metadata)
            dragWasAccepted(sessionID: sessionID)
            return
        }
        let destination = hoveredFolder ?? ""

        // Browser panels are click-through: claim the release synchronously so
        // a later dragend/mouse-up cannot cancel or submit the same drop twice.
        // The importer waits asynchronously for the prefetched image bytes.
        dragWasAccepted(sessionID: sessionID)
        CollectorImportCoordinator.shared.importRemote(metadata, folder: destination)
    }

    private func updateDropTarget(at screenPoint: NSPoint, managesAutoScroll: Bool = false) {
        lastDragPoint = screenPoint
        // 采集框按使用频次排列文件夹，主程序侧栏不受影响。
        let folders = LibraryStore.shared.foldersByUsage
        let target = CollectorPanelController.shared.dropTarget(
            at: screenPoint,
            folders: folders,
            folderStartIndex: folderScrollIndex
        )
        hoveredFolder = target.folder
        isHoveringDropTarget = target.isValid
        isHoveringCreateFolder = target.isValid && target.createsFolder
        if managesAutoScroll {
            setAutoScrollDirection(
                CollectorPanelController.shared.folderAutoScrollDirection(at: screenPoint),
                folderCount: folders.count
            )
        }
    }

    private func handleGlobalScroll(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard activeSessionID != nil,
              CollectorPanelController.shared.isFolderListPoint(point),
              abs(event.scrollingDeltaY) > 0.01 else { return }
        stopAutoScroll()
        scrollFolders(by: event.scrollingDeltaY < 0 ? 1 : -1)
        updateDropTarget(at: point)
    }

    private func setAutoScrollDirection(_ direction: Int, folderCount: Int) {
        let maximum = max(0, folderCount - Self.visibleFolderRows)
        let usableDirection: Int
        if direction < 0, folderScrollIndex > 0 {
            usableDirection = -1
        } else if direction > 0, folderScrollIndex < maximum {
            usableDirection = 1
        } else {
            usableDirection = 0
        }
        guard usableDirection != autoScrollDirection else { return }
        stopAutoScroll()
        guard usableDirection != 0 else { return }
        autoScrollDirection = usableDirection
        scrollFolders(by: usableDirection)
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.34, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.scrollFolders(by: self.autoScrollDirection)
                if let point = self.lastDragPoint { self.updateDropTarget(at: point) }
            }
        }
        if let autoScrollTimer { RunLoop.main.add(autoScrollTimer, forMode: .common) }
    }

    private func scrollFolders(by delta: Int) {
        guard delta != 0 else { return }
        let count = LibraryStore.shared.folders.count
        let maximum = max(0, count - Self.visibleFolderRows)
        let next = min(max(0, folderScrollIndex + delta), maximum)
        guard next != folderScrollIndex else {
            stopAutoScroll()
            return
        }
        folderScrollIndex = next
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    private func cancelActiveBrowserDrag() {
        guard activeSessionID != nil else { return }
        BrowserPayloadCache.shared.remove(sessionID: activeSessionID)
        activeSessionID = nil
        latestMetadata = nil
        latestMetadataAt = nil
        didShowForCurrentDrag = false
        hoveredFolder = nil
        isHoveringDropTarget = false
        isHoveringCreateFolder = false
        folderScrollIndex = 0
        stopAutoScroll()
        CollectorImportCoordinator.shared.handleDragEnded()
        CollectorPanelController.shared.hideImmediately()
    }

    static func isSafariBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.apple.Safari" || bundleIdentifier.hasPrefix("com.apple.Safari")
    }

    static func acceptsDropMessage(_ message: [String: Any], activeSessionID: String?, now: Date) -> Bool {
        guard message["type"] as? String == "imageDragDropped",
              let activeSessionID,
              message["sessionID"] as? String == activeSessionID,
              let milliseconds = (message["timestamp"] as? NSNumber)?.doubleValue,
              milliseconds.isFinite else { return false }
        let age = now.timeIntervalSince1970 - milliseconds / 1000
        return age >= -1 && age <= 5
    }

    static func shouldAcceptBrowserDrag(
        _ message: [String: Any],
        frontmostBundleIdentifier: String?,
        now: Date
    ) -> Bool {
        guard isSafariBundleIdentifier(frontmostBundleIdentifier),
              message["type"] as? String == "imageDragStarted",
              let imageURLString = message["imageURL"] as? String,
              let imageURL = URL(string: imageURLString),
              ["http", "https"].contains(imageURL.scheme?.lowercased() ?? ""),
              let sourceURLString = message["sourceURL"] as? String,
              let sourceURL = URL(string: sourceURLString),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              let timestamp = (message["timestamp"] as? NSNumber)?.doubleValue else { return false }
        let ageMilliseconds = now.timeIntervalSince1970 * 1000 - timestamp
        return ageMilliseconds >= -2_000 && ageMilliseconds <= 5_000
    }
}

@MainActor
final class CollectorImportCoordinator: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case importing(title: String, destination: String)
        case success(title: String, destination: String)
        case addedToFolder(title: String, destination: String)
        case duplicate(title: String, destination: String)
        case duplicateReview(existingID: UUID, incomingName: String, similarityPercent: Int)
        case namingFolder(title: String)
        case failure(message: String)
    }

    static let shared = CollectorImportCoordinator(store: .shared)
    @Published private(set) var phase: Phase = .waiting
    private let store: LibraryStore
    private var retryAction: (() -> Void)?
    private var completedSessionIDs: Set<String> = []
    private var pendingFolderMetadata: WebImageMetadata?
    private struct PendingDuplicate {
        let data: Data
        let folder: String
        let metadata: WebImageMetadata?
        let preferredExtension: String?
        let existingID: UUID
    }
    private var pendingDuplicate: PendingDuplicate?
    @Published private(set) var duplicateIncomingImage: NSImage?
    @Published private(set) var folderNameError: String?

    init(store: LibraryStore) { self.store = store }

    var canRetry: Bool { retryAction != nil }
    private var keepsPanelVisible: Bool {
        switch phase {
        case .waiting: false
        case .importing, .success, .addedToFolder, .duplicate, .duplicateReview, .namingFolder, .failure: true
        }
    }

    func prepareForDrag(_ metadata: WebImageMetadata) {
        if let sessionID = metadata.sessionID, completedSessionIDs.contains(sessionID) { return }
        retryAction = nil
        phase = .waiting
    }

    func handleMouseUp() {
        if !keepsPanelVisible { CollectorPanelController.shared.hide(after: 0.65) }
    }

    func handleDragEnded() {
        if !keepsPanelVisible { CollectorPanelController.shared.hide(after: 0.65) }
    }

    func importRemote(_ metadata: WebImageMetadata, folder: String) {
        CollectorPanelController.shared.cancelScheduledHide()
        if let sessionID = metadata.sessionID, completedSessionIDs.contains(sessionID) {
            phase = .success(title: displayTitle(for: metadata), destination: destinationName(folder))
            CollectorPanelController.shared.hide(after: 1.2)
            return
        }
        let retryMetadata = metadata
        retryAction = { [weak self] in self?.importRemote(retryMetadata, folder: folder) }
        phase = .importing(title: displayTitle(for: metadata), destination: destinationName(folder))
        Task {
            do {
                let payload: BrowserImagePayload
                if let payload = await browserPayload(for: metadata.sessionID, waitNanoseconds: 250_000_000) {
                    try self.reviewOrImport(
                        data: payload.data, folder: folder, metadata: metadata,
                        preferredExtension: LibraryStore.extensionForMIMEType(payload.mimeType)
                    )
                    return
                } else {
                    do {
                        let downloaded = try await store.downloadRemoteImage(metadata)
                        payload = BrowserImagePayload(data: downloaded.data, mimeType: downloaded.format, createdAt: .now)
                    } catch {
                        guard let payload = await browserPayload(for: metadata.sessionID, waitNanoseconds: 1_500_000_000) else { throw error }
                        try self.reviewOrImport(
                            data: payload.data, folder: folder, metadata: metadata,
                            preferredExtension: LibraryStore.extensionForMIMEType(payload.mimeType)
                        )
                        return
                    }
                }
                try reviewOrImport(
                    data: payload.data, folder: folder, metadata: metadata,
                    preferredExtension: LibraryStore.extensionForMIMEType(payload.mimeType) ?? payload.mimeType
                )
            } catch {
                fail(error)
            }
        }
    }

    func importFiles(_ urls: [URL], folder: String, metadata: WebImageMetadata?, removeAfterImport: Bool = false) {
        CollectorPanelController.shared.cancelScheduledHide()
        guard !urls.isEmpty else { return }
        if showAlreadyImportedIfNeeded(metadata, folder: folder) {
            if removeAfterImport { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
            return
        }
        let retryURLs = urls
        retryAction = { [weak self] in
            self?.importFiles(retryURLs, folder: folder, metadata: metadata, removeAfterImport: removeAfterImport)
        }
        phase = .importing(title: metadata.map(displayTitle) ?? urls[0].lastPathComponent, destination: destinationName(folder))
        Task {
            do {
                var lastResult: LibraryImportResult?
                for url in urls {
                    defer { if removeAfterImport { try? FileManager.default.removeItem(at: url) } }
                    lastResult = try store.importFileResult(at: url, folder: folder, metadata: metadata)
                }
                if let lastResult { finish(result: lastResult, folder: folder, sessionID: metadata?.sessionID) }
            } catch {
                fail(error)
            }
        }
    }

    func importImageData(_ data: Data, folder: String, metadata: WebImageMetadata?) {
        CollectorPanelController.shared.cancelScheduledHide()
        if showAlreadyImportedIfNeeded(metadata, folder: folder) { return }
        let retryData = data
        retryAction = { [weak self] in self?.importImageData(retryData, folder: folder, metadata: metadata) }
        phase = .importing(title: metadata.map(displayTitle) ?? "网页图片", destination: destinationName(folder))
        Task {
            do {
                try reviewOrImport(data: data, folder: folder, metadata: metadata, preferredExtension: nil)
            } catch {
                fail(error)
            }
        }
    }

    func beginReceivingPromise(folder: String, metadata: WebImageMetadata?) {
        CollectorPanelController.shared.cancelScheduledHide()
        if showAlreadyImportedIfNeeded(metadata, folder: folder) { return }
        retryAction = nil
        phase = .importing(title: metadata.map(displayTitle) ?? "正在接收网页图片", destination: destinationName(folder))
    }

    func promiseFailed(_ error: Error?) {
        fail(error ?? CocoaError(.fileReadUnknown))
    }

    func retry() { retryAction?() }

    func resolveDuplicate(useExisting: Bool) {
        guard let pending = pendingDuplicate else { return }
        do {
            let result: LibraryImportResult
            if useExisting {
                guard let reused = store.reuseExistingItem(
                    pending.existingID,
                    folder: pending.folder,
                    metadata: pending.metadata
                ) else { throw CocoaError(.fileNoSuchFile) }
                result = reused
            } else {
                let item = try store.importImageData(
                    pending.data,
                    folder: pending.folder,
                    metadata: pending.metadata,
                    preferredExtension: pending.preferredExtension,
                    allowDuplicate: true
                )
                result = LibraryImportResult(item: item, disposition: .imported)
            }
            pendingDuplicate = nil
            duplicateIncomingImage = nil
            CollectorPanelController.shared.endDuplicateReview()
            finish(result: result, folder: pending.folder, sessionID: pending.metadata?.sessionID)
        } catch {
            fail(error)
        }
    }

    func requestNewFolder(for metadata: WebImageMetadata) {
        CollectorPanelController.shared.cancelScheduledHide()
        pendingFolderMetadata = metadata
        folderNameError = nil
        retryAction = nil
        phase = .namingFolder(title: displayTitle(for: metadata))
        CollectorPanelController.shared.beginFolderNaming()
    }

    func confirmNewFolder(named proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            folderNameError = "请输入文件夹名称"
            return
        }
        guard !store.folders.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            folderNameError = "这个文件夹已经存在，请换一个名称"
            return
        }
        guard let metadata = pendingFolderMetadata else {
            fail(CocoaError(.userCancelled))
            return
        }
        pendingFolderMetadata = nil
        folderNameError = nil
        let folder = store.addFolder(named: name)
        CollectorPanelController.shared.endFolderNaming()
        importRemote(metadata, folder: folder)
    }

    func cancelNewFolder() {
        BrowserPayloadCache.shared.remove(sessionID: pendingFolderMetadata?.sessionID)
        pendingFolderMetadata = nil
        folderNameError = nil
        retryAction = nil
        phase = .waiting
        CollectorPanelController.shared.endFolderNaming()
        CollectorPanelController.shared.hideImmediately()
    }

    func dismiss() {
        pendingFolderMetadata = nil
        folderNameError = nil
        retryAction = nil
        pendingDuplicate = nil
        duplicateIncomingImage = nil
        phase = .waiting
        CollectorPanelController.shared.hideImmediately()
    }

    private func reviewOrImport(
        data: Data,
        folder: String,
        metadata: WebImageMetadata?,
        preferredExtension: String?
    ) throws {
        if let match = store.visualDuplicate(for: data) {
            pendingDuplicate = PendingDuplicate(
                data: data,
                folder: folder,
                metadata: metadata,
                preferredExtension: preferredExtension,
                existingID: match.item.id
            )
            duplicateIncomingImage = NSImage(data: data)
            let percent = max(0, min(100, Int(((1 - match.distance) * 100).rounded())))
            phase = .duplicateReview(
                existingID: match.item.id,
                incomingName: metadata.map(displayTitle) ?? "新加入的图片",
                similarityPercent: percent
            )
            CollectorPanelController.shared.beginDuplicateReview()
            return
        }
        let result = try store.importImageDataResult(
            data,
            folder: folder,
            metadata: metadata,
            preferredExtension: preferredExtension
        )
        finish(result: result, folder: folder, sessionID: metadata?.sessionID)
    }

    private func finish(result: LibraryImportResult, folder: String, sessionID: String?) {
        BrowserPayloadCache.shared.remove(sessionID: sessionID)
        if let sessionID {
            completedSessionIDs.insert(sessionID)
            if completedSessionIDs.count > 100 { completedSessionIDs.removeAll(keepingCapacity: true) }
        }
        retryAction = nil
        switch result.disposition {
        case .imported:
            phase = .success(title: result.item.name, destination: destinationName(folder))
        case .addedToFolder:
            phase = .addedToFolder(title: result.item.name, destination: destinationName(folder))
        case .alreadyInFolder:
            phase = .duplicate(title: result.item.name, destination: destinationName(folder))
        }
        CollectorPanelController.shared.hide(after: result.disposition == .alreadyInFolder ? 2.0 : 1.45)
    }

    private func fail(_ error: Error) {
        phase = .failure(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        NSSound.beep()
    }

    private func displayTitle(for metadata: WebImageMetadata) -> String {
        let value = metadata.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "网页图片" : value
    }

    private func destinationName(_ folder: String) -> String { folder.isEmpty ? "未分类" : folder }

    private func showAlreadyImportedIfNeeded(_ metadata: WebImageMetadata?, folder: String) -> Bool {
        guard let sessionID = metadata?.sessionID, completedSessionIDs.contains(sessionID) else { return false }
        phase = .duplicate(title: metadata.map(displayTitle) ?? "网页图片", destination: destinationName(folder))
        CollectorPanelController.shared.hide(after: 1.2)
        return true
    }

    private func browserPayload(for sessionID: String?, waitNanoseconds: UInt64) async -> BrowserImagePayload? {
        guard let sessionID else { return nil }
        if let payload = BrowserPayloadCache.shared.payload(for: sessionID) { return payload }
        let interval: UInt64 = 100_000_000
        var waited: UInt64 = 0
        while waited < waitNanoseconds {
            try? await Task.sleep(nanoseconds: min(interval, waitNanoseconds - waited))
            waited += min(interval, waitNanoseconds - waited)
            if let payload = BrowserPayloadCache.shared.payload(for: sessionID) { return payload }
        }
        return nil
    }
}

@MainActor
final class CollectorPanelController {
    static let shared = CollectorPanelController()
    static let panelSize = NSSize(width: 480, height: 276)
    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        panel = CollectorNonactivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = NSHostingView(rootView: CollectorPanelView(store: .shared))
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func showNearMouse() {
        show(near: NSEvent.mouseLocation, acceptsNativeDrops: true)
    }

    func showNearBrowserPoint(x: Double, y: Double) {
        // The native pointer is authoritative while a drag is active. Safari's
        // screen coordinates can use a different origin/scale on mixed Retina
        // and multi-display setups, so keep them only as a fallback.
        let liveMouse = NSEvent.mouseLocation
        if NSScreen.screens.contains(where: { $0.frame.contains(liveMouse) }) {
            show(near: liveMouse, acceptsNativeDrops: false)
            return
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        show(near: Self.appKitPoint(browserX: x, browserY: y, primaryScreenMaxY: primaryMaxY), acceptsNativeDrops: false)
    }

    private func show(near mouse: NSPoint, acceptsNativeDrops: Bool) {
        hideWorkItem?.cancel()
        let size = panel.frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = Self.origin(near: mouse, panelSize: size, visibleFrame: visible)
        panel.setFrameOrigin(origin)
        panel.ignoresMouseEvents = !acceptsNativeDrops
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        saveSnapshotIfRequested()
    }

    static func appKitPoint(browserX: Double, browserY: Double, primaryScreenMaxY: Double) -> NSPoint {
        NSPoint(x: browserX, y: primaryScreenMaxY - browserY)
    }

    static func origin(near mouse: NSPoint, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        // Place the large left drop target under the cursor, like Eagle. The
        // user can release immediately or move right onto a folder row.
        var x = mouse.x - panelSize.width * 0.28
        var y = mouse.y - panelSize.height * 0.50
        let inset: CGFloat = 12
        x = min(max(x, visibleFrame.minX + inset), visibleFrame.maxX - panelSize.width - inset)
        y = min(max(y, visibleFrame.minY + inset), visibleFrame.maxY - panelSize.height - inset)
        return NSPoint(x: x, y: y)
    }

    private func saveSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["INSPIRATION_COLLECTOR_SNAPSHOT_PATH"],
              !path.isEmpty,
              let view = panel.contentView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            view.layoutSubtreeIfNeeded()
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideImmediately() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        panel.alphaValue > 0.01 && panel.frame.contains(screenPoint)
    }

    func dropTarget(at screenPoint: NSPoint, folders: [String], folderStartIndex: Int = 0) -> CollectorDropTarget {
        Self.dropTarget(
            at: screenPoint,
            panelFrame: panel.frame,
            folders: folders,
            folderStartIndex: folderStartIndex
        )
    }

    static func dropTarget(
        at screenPoint: NSPoint,
        panelFrame: NSRect,
        folders: [String],
        folderStartIndex: Int = 0
    ) -> CollectorDropTarget {
        guard panelFrame.contains(screenPoint) else { return .invalid }
        let localX = screenPoint.x - panelFrame.minX
        let localY = screenPoint.y - panelFrame.minY
        if localX < 238 { return CollectorDropTarget(isValid: true, folder: nil) }
        guard localY >= 48 else { return CollectorDropTarget(isValid: true, folder: nil, createsFolder: true) }
        let row = Int((panelFrame.height - localY) / 38)
        let index = max(0, folderStartIndex) + row
        guard row < DragCoordinator.visibleFolderRows, folders.indices.contains(index) else { return .invalid }
        return CollectorDropTarget(isValid: true, folder: folders[index])
    }

    func folderAutoScrollDirection(at screenPoint: NSPoint) -> Int {
        Self.folderAutoScrollDirection(at: screenPoint, panelFrame: panel.frame)
    }

    static func folderAutoScrollDirection(at screenPoint: NSPoint, panelFrame: NSRect) -> Int {
        guard isFolderListPoint(screenPoint, panelFrame: panelFrame) else { return 0 }
        let localY = screenPoint.y - panelFrame.minY
        let edgeHeight: CGFloat = 28
        if localY >= panelFrame.height - edgeHeight { return -1 }
        if localY <= 48 + edgeHeight { return 1 }
        return 0
    }

    func isFolderListPoint(_ screenPoint: NSPoint) -> Bool {
        Self.isFolderListPoint(screenPoint, panelFrame: panel.frame)
    }

    static func isFolderListPoint(_ screenPoint: NSPoint, panelFrame: NSRect) -> Bool {
        guard panelFrame.contains(screenPoint) else { return false }
        let localX = screenPoint.x - panelFrame.minX
        let localY = screenPoint.y - panelFrame.minY
        return localX >= 238 && localY >= 48
    }

    func beginFolderNaming() {
        hideWorkItem?.cancel()
        panel.ignoresMouseEvents = false
        (panel as? CollectorNonactivatingPanel)?.acceptsKeyboardInput = true
        panel.makeKeyAndOrderFront(nil)
    }

    func beginDuplicateReview() {
        hideWorkItem?.cancel()
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    func endDuplicateReview() {
        panel.ignoresMouseEvents = true
    }

    func endFolderNaming() {
        (panel as? CollectorNonactivatingPanel)?.acceptsKeyboardInput = false
        panel.ignoresMouseEvents = true
        panel.resignKey()
    }

    func hideImmediately() {
        hideWorkItem?.cancel()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }
}

struct CollectorDropTarget: Equatable {
    let isValid: Bool
    let folder: String?
    var createsFolder = false
    static let invalid = CollectorDropTarget(isValid: false, folder: nil, createsFolder: false)
}

private final class CollectorNonactivatingPanel: NSPanel {
    var acceptsKeyboardInput = false
    override var canBecomeKey: Bool { acceptsKeyboardInput }
    override var canBecomeMain: Bool { false }
}

private struct CollectorPanelView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject private var importer = CollectorImportCoordinator.shared
    @ObservedObject private var dragCoordinator = DragCoordinator.shared

    var body: some View {
        Group {
            switch importer.phase {
            case .waiting:
                waitingView
            case .importing(let title, let destination):
                statusView(
                    icon: nil,
                    title: "正在加入素材库",
                    detail: title,
                    destination: destination,
                    showsProgress: true
                )
            case .success(let title, let destination):
                statusView(
                    icon: "checkmark.circle.fill",
                    title: "已成功入库",
                    detail: title,
                    destination: destination,
                    iconColor: .green
                )
            case .addedToFolder(let title, let destination):
                statusView(
                    icon: "folder.badge.plus",
                    title: "已添加到文件夹",
                    detail: title,
                    destination: destination,
                    iconColor: .blue
                )
            case .duplicate(let title, let destination):
                statusView(
                    icon: "checkmark.circle",
                    title: "已经添加过",
                    detail: title,
                    destination: destination,
                    iconColor: .orange
                )
            case .duplicateReview(let existingID, let incomingName, let similarityPercent):
                duplicateReviewView(
                    existingID: existingID,
                    incomingName: incomingName,
                    similarityPercent: similarityPercent
                )
            case .namingFolder(let title):
                FolderNamingView(title: title, importer: importer)
            case .failure(let message):
                failureView(message)
            }
        }
        .frame(width: CollectorPanelController.panelSize.width, height: CollectorPanelController.panelSize.height)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.7), lineWidth: 1))
    }

    private func duplicateReviewView(existingID: UUID, incomingName: String, similarityPercent: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                Label("发现疑似重复图片", systemImage: "photo.stack")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("相似度 \(similarityPercent)%")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    if let item = store.items.first(where: { $0.id == existingID }) {
                        AssetImage(store: store, item: item, thumbnail: true)
                            .frame(width: 118, height: 112).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("已存在 · \(item.name)").lineLimit(1)
                    }
                }
                VStack(spacing: 4) {
                    if let image = importer.duplicateIncomingImage {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 118, height: 112).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("新文件 · \(incomingName)").lineLimit(1)
                }
            }
            .font(.system(size: 9.5)).foregroundStyle(Color.eagleSecondary)
            HStack(spacing: 10) {
                Button("使用已有文件") { importer.resolveDuplicate(useExisting: true) }
                    .buttonStyle(.borderedProminent)
                Button("保留两者") { importer.resolveDuplicate(useExisting: false) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
    }

    private var waitingView: some View {
        let visibleFolders = store.foldersByUsage
        return HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(dragCoordinator.isHoveringDropTarget && dragCoordinator.hoveredFolder == nil && !dragCoordinator.isHoveringCreateFolder ? Color.accentColor.opacity(0.12) : Color.clear)
                    .padding(16)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        dragCoordinator.isHoveringDropTarget && dragCoordinator.hoveredFolder == nil && !dragCoordinator.isHoveringCreateFolder ? Color.accentColor : Color.black.opacity(0.16),
                        style: StrokeStyle(lineWidth: dragCoordinator.isHoveringDropTarget && dragCoordinator.hoveredFolder == nil && !dragCoordinator.isHoveringCreateFolder ? 2 : 1, dash: [5, 5])
                    )
                    .padding(16)
                VStack(spacing: 13) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "folder")
                            .font(.system(size: 64, weight: .ultraLight))
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 24, weight: .regular))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.52))
                            .background(Circle().fill(Color.white).padding(2))
                            .offset(x: 4, y: 2)
                    }
                    .foregroundStyle(Color.black.opacity(0.43))
                    Text(dragCoordinator.isHoveringDropTarget && dragCoordinator.hoveredFolder == nil && !dragCoordinator.isHoveringCreateFolder ? "松开添加到灵感库" : "拖拽到这里添加到灵感库")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.48))
                }
                DropReceiver(folder: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 238)

            Divider().opacity(0.38)

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: visibleFolders.count > DragCoordinator.visibleFolderRows) {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleFolders, id: \.self) { folder in
                                ZStack {
                                    if dragCoordinator.isHoveringDropTarget && dragCoordinator.hoveredFolder == folder {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.accentColor.opacity(0.16))
                                            .padding(.horizontal, 7)
                                    }
                                    HStack(spacing: 11) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 15, weight: .regular))
                                            .frame(width: 18)
                                        Text(folder).font(.system(size: 13)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if dragCoordinator.isHoveringDropTarget && dragCoordinator.hoveredFolder == folder {
                                            Text("松开保存")
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .foregroundStyle(Color.black.opacity(0.72))
                                    .padding(.horizontal, 18)
                                    .frame(height: 38)
                                    DropReceiver(folder: folder)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(height: 38)
                                .id(folder)
                            }
                        }
                    }
                    .onChange(of: dragCoordinator.folderScrollIndex) { _, index in
                        guard visibleFolders.indices.contains(index) else { return }
                        proxy.scrollTo(visibleFolders[index], anchor: .top)
                    }
                    .overlay(alignment: .top) {
                        if dragCoordinator.folderScrollIndex > 0 {
                            folderScrollCue(systemName: "chevron.up")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if dragCoordinator.folderScrollIndex < max(0, visibleFolders.count - DragCoordinator.visibleFolderRows) {
                            folderScrollCue(systemName: "chevron.down")
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                Divider().opacity(0.38)
                ZStack {
                    if dragCoordinator.isHoveringCreateFolder {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.16))
                            .padding(.horizontal, 7)
                    }
                    Button(action: createFolder) {
                        HStack(spacing: 11) {
                            Image(systemName: "plus").font(.system(size: 15, weight: .regular)).frame(width: 18)
                            Text(dragCoordinator.isHoveringCreateFolder ? "松开新建文件夹" : "建立或选择文件夹")
                                .font(.system(size: 13, weight: dragCoordinator.isHoveringCreateFolder ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(dragCoordinator.isHoveringCreateFolder ? Color.accentColor : Color.black.opacity(0.72))
                    .padding(.horizontal, 18)
                }
                .frame(height: 48)
            }
        }
    }

    private func folderScrollCue(systemName: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.72), Color.white.opacity(0)],
                startPoint: systemName == "chevron.up" ? .top : .bottom,
                endPoint: systemName == "chevron.up" ? .bottom : .top
            )
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.48))
        }
        .frame(height: 22)
        .allowsHitTesting(false)
    }

    private func statusView(
        icon: String?,
        title: String,
        detail: String,
        destination: String,
        showsProgress: Bool = false,
        iconColor: Color = .accentColor
    ) -> some View {
        VStack(spacing: 13) {
            Spacer()
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 34)).foregroundStyle(iconColor)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.black.opacity(0.78))
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.black.opacity(0.55)).lineLimit(2).multilineTextAlignment(.center)
            Label(destination, systemImage: destination == "未分类" ? "tray" : "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.62))
            Spacer()
        }
        .padding(14)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 11) {
            Spacer()
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 32)).foregroundStyle(.orange)
            Text("入库失败").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.black.opacity(0.78))
            Text(message).font(.system(size: 12)).foregroundStyle(Color.black.opacity(0.56))
                .lineLimit(4).multilineTextAlignment(.center)
            HStack(spacing: 7) {
                Button("关闭") { importer.dismiss() }
                if importer.canRetry { Button("重试") { importer.retry() }.keyboardShortcut(.defaultAction) }
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(13)
    }

    private func createFolder() {
        CollectorPanelController.shared.hideImmediately()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .libraryNewFolder, object: nil)
    }
}

private struct FolderNamingView: View {
    let title: String
    @ObservedObject var importer: CollectorImportCoordinator
    @State private var folderName = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建文件夹并保存")
                        .font(.system(size: 15, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.black.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
            }

            TextField("输入文件夹名称", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit { submit() }

            if let error = importer.folderNameError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            } else {
                Text("确认后会立即建立文件夹，并把这张图片保存进去。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.black.opacity(0.48))
            }

            HStack {
                Spacer()
                Button("取消") { importer.cancelNewFolder() }
                    .keyboardShortcut(.cancelAction)
                Button("新建并保存") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(22)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private func submit() {
        importer.confirmNewFolder(named: folderName)
    }
}

private struct DropReceiver: NSViewRepresentable {
    let folder: String?
    func makeNSView(context: Context) -> DragReceiverView { DragReceiverView(folder: folder) }
    func updateNSView(_ nsView: DragReceiverView, context: Context) { nsView.folder = folder }
}

@MainActor
final class CollectorDropHandler {
    static let shared = CollectorDropHandler(importer: .shared, store: .shared)
    private let importer: CollectorImportCoordinator
    private let store: LibraryStore

    init(importer: CollectorImportCoordinator, store: LibraryStore) {
        self.importer = importer
        self.store = store
    }

    func performDrop(from pasteboard: NSPasteboard, folder: String) -> Bool {
        let metadata = DragCoordinator.shared.metadata(from: pasteboard)

        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let destination = store.incomingDirectory()
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            importer.beginReceivingPromise(folder: folder, metadata: metadata)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [importer] url, error in
                    Task { @MainActor in
                        if let error {
                            importer.promiseFailed(error)
                        } else {
                            importer.importFiles([url], folder: folder, metadata: metadata, removeAfterImport: true)
                        }
                    }
                }
            }
            DragCoordinator.shared.dragWasAccepted(sessionID: metadata?.sessionID)
            return true
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importer.importFiles(urls, folder: folder, metadata: metadata)
            DragCoordinator.shared.dragWasAccepted(sessionID: metadata?.sessionID)
            return true
        }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            importer.importImageData(data, folder: folder, metadata: metadata)
            DragCoordinator.shared.dragWasAccepted(sessionID: metadata?.sessionID)
            return true
        }

        if let metadata {
            importer.importRemote(metadata, folder: folder)
            DragCoordinator.shared.dragWasAccepted(sessionID: metadata.sessionID)
            return true
        }

        if let raw = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let fallback = WebImageMetadata(
                imageURL: url.absoluteString,
                sessionID: UUID().uuidString,
                timestamp: Date().timeIntervalSince1970 * 1000
            )
            importer.importRemote(fallback, folder: folder)
            DragCoordinator.shared.dragWasAccepted(sessionID: fallback.sessionID)
            return true
        }
        return false
    }
}

private final class DragReceiverView: NSView {
    var folder: String?
    private let customType = NSPasteboard.PasteboardType("application/x-eagle-replica")

    init(folder: String?) {
        self.folder = folder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types.append(contentsOf: [.fileURL, .URL, .string, .png, .tiff, customType])
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DragCoordinator.shared.updateHoveredFolder(folder)
        updateHighlight()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        DragCoordinator.shared.updateHoveredFolder(folder)
        updateHighlight()
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    private func updateHighlight() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DragCoordinator.shared.updateHoveredFolder(nil, active: false)
        clearHighlight()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearHighlight() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = CollectorDropHandler.shared.performDrop(from: sender.draggingPasteboard, folder: folder ?? "")
        clearHighlight()
        return accepted
    }

    private func clearHighlight() {
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
