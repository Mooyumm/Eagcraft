@preconcurrency import AppKit
@preconcurrency import SafariServices
import Combine
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private enum SafariExtensionInstaller {
    struct Result: Sendable {
        let succeeded: Bool
        let message: String?
    }

    nonisolated static func install(extensionURL: URL, identifier: String) -> Result {
        let currentPath = extensionURL.standardizedFileURL.path
        let lookupArguments = ["-m", "-A", "-D", "-vvv", "-i", identifier]

        let initialLookup = run(arguments: lookupArguments)
        for registeredPath in registeredPaths(from: initialLookup.output)
        where URL(fileURLWithPath: registeredPath).standardizedFileURL.path != currentPath {
            _ = run(arguments: ["-r", registeredPath])
        }

        let registration = run(arguments: ["-a", currentPath])
        guard registration.status == 0 else {
            return Result(
                succeeded: false,
                message: registration.message ?? "系统没有接受扩展注册请求。"
            )
        }

        let verification = run(arguments: lookupArguments)
        let verifiedPaths = registeredPaths(from: verification.output).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard verifiedPaths.contains(currentPath) else {
            return Result(
                succeeded: false,
                message: "扩展注册命令已完成，但 Safari 仍未登记当前 App 中的扩展。请确认 App 和扩展已使用同一签名构建。"
            )
        }
        return Result(succeeded: true, message: nil)
    }

    private struct CommandResult {
        let status: Int32
        let output: String
        let error: String

        var message: String? {
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    nonisolated private static func run(arguments: [String]) -> CommandResult {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = arguments
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return CommandResult(status: task.terminationStatus, output: output, error: error)
        } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription)
        }
    }

    nonisolated private static func registeredPaths(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            let marker = "Path = "
            guard text.hasPrefix(marker) else { return nil }
            return String(text.dropFirst(marker.count))
        }
    }
}

private enum SafariHostApplicationInstaller {
    struct Result: Sendable {
        let installedURL: URL?
        let message: String?
    }

    nonisolated static func isInstalledApplication(_ bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true).path + "/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path + "/"
        return path.hasPrefix(systemApplications) || path.hasPrefix(userApplications)
    }

    nonisolated static func install(sourceBundleURL: URL) -> Result {
        let fileManager = FileManager.default
        let applicationsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let destinationURL = applicationsURL.appendingPathComponent("灵感库.app", isDirectory: true)
        let stagingURL = applicationsURL.appendingPathComponent(".灵感库-installing-\(UUID().uuidString).app", isDirectory: true)
        let backupURL = applicationsURL.appendingPathComponent(".灵感库-previous-\(UUID().uuidString).app", isDirectory: true)

        do {
            try fileManager.createDirectory(at: applicationsURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceBundleURL, to: stagingURL)

            var movedExistingAside = false
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                movedExistingAside = true
            }

            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                if movedExistingAside { try? fileManager.removeItem(at: backupURL) }
                return Result(installedURL: destinationURL, message: nil)
            } catch {
                if movedExistingAside, !fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: destinationURL)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            return Result(installedURL: nil, message: error.localizedDescription)
        }
    }
}

@MainActor
final class SafariExtensionStatusController: ObservableObject {
    enum Status: Equatable {
        case checking
        case installing
        case disabled
        case enabled
        case unavailable(String)

        var isEnabled: Bool {
            if case .enabled = self { return true }
            return false
        }
    }

    static let shared = SafariExtensionStatusController()
    static let extensionBundleIdentifier = "com.mooyumm.InspirationLibrary.Extension"

    @Published private(set) var status: Status = .checking
    private var activationObserver: NSObjectProtocol?

    private init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        status = .checking
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.extensionBundleIdentifier) { [weak self] state, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.status = .unavailable(error.localizedDescription)
                } else {
                    self.status = state?.isEnabled == true ? .enabled : .disabled
                }
            }
        }
    }

    func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.extensionBundleIdentifier) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.status = .unavailable(error.localizedDescription)
                    self?.presentInstallationError(error.localizedDescription)
                }
                try? await Task.sleep(for: .milliseconds(700))
                self?.refresh()
            }
        }
    }

    /// Registers the Safari web extension embedded in the currently running app,
    /// then opens Safari's extension preferences so the user can approve it.
    /// Safari deliberately does not allow apps to silently enable an extension.
    func installOrManageExtension() {
        let runningBundleURL = Bundle.main.bundleURL
        guard SafariHostApplicationInstaller.isInstalledApplication(runningBundleURL) else {
            installHostApplication(from: runningBundleURL)
            return
        }

        registerCurrentExtensionAndOpenSafari()
    }

    private func installHostApplication(from sourceBundleURL: URL) {
        status = .installing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SafariHostApplicationInstaller.install(sourceBundleURL: sourceBundleURL)
            Task { @MainActor in
                guard let self else { return }
                guard let installedURL = result.installedURL else {
                    let message = result.message ?? "无法将灵感库安装到应用程序文件夹。"
                    self.status = .unavailable(message)
                    self.presentInstallationError(message)
                    return
                }

                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["--install-safari-extension"]
                configuration.activates = true
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) { _, error in
                    Task { @MainActor in
                        if let error {
                            self.status = .unavailable(error.localizedDescription)
                            self.presentInstallationError(error.localizedDescription)
                        } else {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    private func registerCurrentExtensionAndOpenSafari() {
        guard let extensionURL = embeddedExtensionURL else {
            let message = "当前运行的灵感库没有包含 Safari 扩展。请使用 Xcode 的 InspirationLibrary App 目标重新构建。"
            status = .unavailable(message)
            presentInstallationError(message)
            return
        }

        status = .installing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SafariExtensionInstaller.install(
                extensionURL: extensionURL,
                identifier: Self.extensionBundleIdentifier
            )
            Task { @MainActor in
                guard let self else { return }
                guard result.succeeded else {
                    let message = result.message ?? "系统没有接受扩展注册请求。"
                    self.status = .unavailable(message)
                    self.presentInstallationError(message)
                    return
                }
                self.openSafariExtensionSettings()
            }
        }
    }

    private var embeddedExtensionURL: URL? {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return nil }
        let expectedURL = plugInsURL.appendingPathComponent("InspirationLibrary Extension.appex", isDirectory: true)
        if FileManager.default.fileExists(atPath: expectedURL.path) { return expectedURL }

        return try? FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first { $0.pathExtension == "appex" }
    }

    private func presentInstallationError(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法安装 Safari 扩展"
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    var helpText: String {
        switch status {
        case .checking: "正在检查 Safari 扩展状态"
        case .installing: "正在安装 Safari 扩展"
        case .disabled: "Safari 扩展未启用，点击前往启用"
        case .enabled: "Safari 扩展已启用，点击管理"
        case .unavailable: "Safari 扩展未安装，点击安装"
        }
    }
}

enum WorkspaceLayoutMetrics {
    static let topBarHeight = 48.0
    static let topBarContentOffset = 3.0
    static let sidebarSectionHeight = 26.0
    static let sidebarLibraryHeaderHeight = 38.0
    static let sidebarGroupSeparation = 8.0
    static let resourceLibraryPopoverWidth = 320.0
    static let sidebarRegularFontName = "PingFangSC-Regular"
    static let sidebarMediumFontName = "PingFangSC-Medium"
    static let sidebarTextOpacity = 0.88
    static let sidebarSelectedTextOpacity = 0.96
    static let sidebarCountOpacity = 0.58
    static let sidebarSectionOpacity = 0.50
    static let trafficLightHorizontalOffset = 8.0
    static let trafficLightVerticalOffset = 11.0
}

enum StyleStackLayout {
    static let cardWidth = 124.0
    static let cardHeight = 142.0
    static let previewHeight = 164.0

    static func rotation(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        if count == 2 { return index == 0 ? 0 : -4 }
        switch index {
        case 0: return 0
        case 1: return 4
        default: return -5
        }
    }

    static func offset(index: Int, count: Int) -> CGSize {
        guard count > 1 else { return .zero }
        if count == 2 { return index == 0 ? .zero : CGSize(width: -11, height: 7) }
        switch index {
        case 0: return .zero
        case 1: return CGSize(width: 14, height: 7)
        default: return CGSize(width: -14, height: 10)
        }
    }
}

/// Keeps macOS editing behavior predictable: clicking anywhere outside a text
/// input ends the current edit and lets SwiftUI's focus-change handlers commit it.
/// 把 App 级命令（复制 / 粘贴 / 提示）接到主界面的状态上。
///
/// 抽成独立的 ViewModifier，是因为主 body 的修饰符链已经很大，
/// 再往里塞几个 onReceive/onChange 会让 Swift 类型检查超时。
private struct LibraryCommandBridge: ViewModifier {
    let selectionCount: Int
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onToast: (String) -> Void
    let onSelectionCountChanged: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .libraryCopySelection)
                    .merge(with: NotificationCenter.default.publisher(for: .libraryPasteClipboard))
                    .merge(with: NotificationCenter.default.publisher(for: .libraryShowToast))
            ) { notification in
                switch notification.name {
                case .libraryCopySelection: onCopy()
                case .libraryPasteClipboard: onPaste()
                default:
                    if let message = notification.object as? String { onToast(message) }
                }
            }
            .onChange(of: selectionCount) { _, count in onSelectionCountChanged(count) }
    }
}

private struct AppFocusDismissMonitor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) { }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private struct ClickContext: @unchecked Sendable {
            let window: NSWindow
            let locationInWindow: NSPoint
        }

        private var eventMonitor: Any?

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                if let window = event.window {
                    let click = ClickContext(window: window, locationInWindow: event.locationInWindow)
                    MainActor.assumeIsolated { Self.dismissEditingIfNeeded(for: click) }
                }
                return event
            }
        }

        func stop() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        @MainActor
        private static func dismissEditingIfNeeded(for click: ClickContext) {
            let window = click.window
            guard let activeInput = activeInputView(for: window.firstResponder) else { return }
            let pointInInput = activeInput.convert(click.locationInWindow, from: nil)
            guard !activeInput.bounds.insetBy(dx: -3, dy: -3).contains(pointInInput) else { return }
            let activeInputID = ObjectIdentifier(activeInput)

            DispatchQueue.main.async {
                guard let currentInput = activeInputView(for: window.firstResponder),
                      ObjectIdentifier(currentInput) == activeInputID else { return }
                window.makeFirstResponder(nil)
            }
        }

        @MainActor
        private static func activeInputView(for responder: NSResponder?) -> NSView? {
            if let textView = responder as? NSTextView {
                // A TextField uses the window's shared field editor; its delegate
                // is the actual control whose bounds should remain clickable.
                return (textView.delegate as? NSView) ?? textView
            }
            return responder as? NSTextField
        }

    }
}

/// Exits transient workspace modes when this specific library window stops
/// being the key window. Scoping the observer to the hosting window avoids one
/// window's focus change dismissing preview state in every open library window.
private struct WindowResignKeyMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView(frame: .zero)
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        context.coordinator.action = action
        context.coordinator.observe(nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Coordinator) {
        nsView.windowDidChange = nil
        coordinator.observe(nil)
    }

    final class WindowTrackingView: NSView {
        var windowDidChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }

    final class Coordinator: @unchecked Sendable {
        var action: () -> Void
        private weak var observedWindow: NSWindow?
        private var observer: NSObjectProtocol?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func observe(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedWindow = window
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.action() }
            }
        }

    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = LibraryStore.shared
    @StateObject private var browserBridge = BrowserBridgeServer.shared
    @ObservedObject private var aiTagger = AITaggingService.shared
    @State private var selection: SidebarSelection = LibraryStore.shared.lastSelection
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var previewItemID: UUID?
    @State private var searchText = ""
    @AppStorage("EagleReplica.layout.thumbnailHeight") private var thumbnailWidth = 156.0
    @State private var showImporter = false
    @State private var inspectorRequested = true
    @State private var showFilterBar = false
    @State private var filter: AssetFilter = .all
    @State private var sort: LibrarySort = .addedNewest
    @State private var editingSmartFolder: SmartFolder?
    @State private var showDuplicateScanner = false
    @State private var duplicateInitialGroups: [DuplicateGroup] = []
    @State private var didRunStartupDuplicateCheck = false
    @State private var showAISettings = false
    @State private var showOnboarding = false
    @State private var sidebarVisible = true
    @State private var backHistory: [SidebarSelection] = []
    @State private var forwardHistory: [SidebarSelection] = []
    @State private var isRestoringHistory = false
    @State private var requestedFolderRename: String?
    @State private var bridgeStatusHidden = false
    @State private var importToast: String?
    @State private var importToastToken: UUID?
    @State private var activeTagBrowse: String?
    @State private var tagBrowseReturnSelection: SidebarSelection?
    @AppStorage("EagleReplica.layout.sidebarWidth") private var sidebarWidth = 238.0
    @AppStorage("EagleReplica.layout.inspectorWidth") private var inspectorWidth = 238.0
    private var favoriteStylesData: String {
        get { StyleFavoritesStorage.encode(Set(store.favoriteStyles)) }
        nonmutating set { store.setFavoriteStyles(Array(StyleFavoritesStorage.decode(newValue))) }
    }

    private var currentItems: [LibraryItem] {
        store.visibleItems(for: selection, searchText: searchText, filter: filter, sort: sort)
    }

    private var tagBrowseTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    private var tagBrowseEmptyAction: (() -> Void)? {
        activeTagBrowse == nil ? nil : { dismissTagBrowse() }
    }

    var body: some View {
        let workspace = GeometryReader { geometry in
            let showInspector = inspectorRequested && geometry.size.width >= 1120
            let effectiveSidebarWidth = min(max(sidebarWidth, 180), max(180, geometry.size.width - (showInspector ? inspectorWidth : 0) - 480))
            let effectiveInspectorWidth = min(max(inspectorWidth, 210), max(210, geometry.size.width - (sidebarVisible ? effectiveSidebarWidth : 0) - 480))
            HStack(spacing: 0) {
                if sidebarVisible {
                    LibrarySidebar(
                        store: store,
                        selection: $selection,
                        selectedItemIDs: $selectedItemIDs,
                        importAction: { showImporter = true },
                        addSmartFolderAction: { editingSmartFolder = SmartFolder(name: "新建智能文件夹") },
                        editSmartFolderAction: { editingSmartFolder = $0 },
                        scanDuplicatesAction: {
                            duplicateInitialGroups = []
                            showDuplicateScanner = true
                        },
                        settingsAction: { showAISettings = true },
                        toggleSidebarAction: { sidebarVisible = false },
                        requestedFolderRename: $requestedFolderRename
                    )
                    .frame(width: effectiveSidebarWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                    PanelResizeHandle(
                        width: $sidebarWidth,
                        currentWidth: effectiveSidebarWidth,
                        range: 180...min(380, max(180, geometry.size.width - (showInspector ? effectiveInspectorWidth : 0) - 480)),
                        reversed: false,
                        accessibilityLabel: "调整左侧栏宽度"
                    )
                }

                VStack(spacing: 0) {
                    if previewItemID != nil {
                        EaglePreviewWorkspace(
                            store: store,
                            itemID: $previewItemID,
                            items: currentItems,
                            closeAction: { previewItemID = nil },
                            selectionAction: { id in selectedItemIDs = [id] }
                        )
                    } else {
                        LibraryToolbar(
                            title: selectionTitle,
                            searchText: $searchText,
                            thumbnailWidth: $thumbnailWidth,
                            inspectorRequested: $inspectorRequested,
                            inspectorVisible: showInspector,
                            showFilterBar: $showFilterBar,
                            filter: $filter,
                            sort: $sort,
                            importAction: { showImporter = true },
                            sidebarVisible: sidebarVisible,
                            toggleSidebarAction: { sidebarVisible.toggle() },
                            canGoBack: !backHistory.isEmpty,
                            canGoForward: !forwardHistory.isEmpty,
                            goBackAction: goBack,
                            goForwardAction: goForward
                        )
                        Divider().overlay(Color.eagleLine)
                        if showFilterBar {
                            QuickFilterBar(filter: $filter)
                            Divider().overlay(Color.eagleLine)
                        }
                        if let activeTagBrowse {
                            TagBrowseBar(
                                tag: activeTagBrowse,
                                count: currentItems.count,
                                closeAction: dismissTagBrowse
                            )
                            .transition(tagBrowseTransition)
                        }
                        if selection == .section(.community) {
                            StyleLibraryView(
                                store: store,
                                items: currentItems,
                                selectedItemIDs: $selectedItemIDs,
                                previewItemID: $previewItemID,
                                thumbnailWidth: $thumbnailWidth,
                                settingsAction: { showAISettings = true }
                            )
                        } else if selection == .section(.tags) {
                            TagManagementView(store: store, selection: $selection)
                        } else {
                            LibraryGrid(
                                store: store,
                                items: currentItems,
                                selectedItemIDs: $selectedItemIDs,
                                previewItemID: $previewItemID,
                                thumbnailWidth: $thumbnailWidth,
                                targetFolder: importFolder,
                                openOnSingleClick: activeTagBrowse != nil,
                                emptyAreaAction: tagBrowseEmptyAction
                            )
                            .id(activeTagBrowse ?? selectionTitle)
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.eagleMain)
                .layoutPriority(1)

                if showInspector {
                    PanelResizeHandle(
                        width: $inspectorWidth,
                        currentWidth: effectiveInspectorWidth,
                        range: 210...min(420, max(210, geometry.size.width - (sidebarVisible ? effectiveSidebarWidth : 0) - 480)),
                        reversed: true,
                        accessibilityLabel: "调整右侧栏宽度"
                    )
                    InspectorPanel(
                        store: store,
                        itemIDs: $selectedItemIDs,
                        selection: $selection,
                        count: currentItems.count,
                        editSmartFolderAction: { editingSmartFolder = $0 },
                        settingsAction: { showAISettings = true },
                        browseTagAction: browseTag,
                        createSmartFolderFromTagAction: createSmartFolder,
                        addTagToStyleLibraryAction: addTagToStyleLibrary,
                        closeAction: { inspectorRequested = false }
                    )
                        .frame(width: effectiveInspectorWidth, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
            .overlay(alignment: .bottom) {
                if let message = browserBridge.failureMessage, !bridgeStatusHidden {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 11))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button { bridgeStatusHidden = true } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.eaglePrimary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 520, minHeight: 38)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .padding(.bottom, 14)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let importToast {
                    Label(importToast, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.eaglePrimary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.green.opacity(0.35)))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .padding(.top, 12)
                        .padding(.trailing, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        let styledWorkspace = workspace
            .background(Color.eagleMain)
        .background(AppFocusDismissMonitor())
        .background(WindowResignKeyMonitor {
            if PreviewPresentationPolicy.shouldCloseOnWindowResign(hasPreview: previewItemID != nil) {
                previewItemID = nil
            }
        })
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        let presentedWorkspace = styledWorkspace
            .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: handleImportResult
        )
        .sheet(item: $editingSmartFolder) { smartFolder in
            SmartFolderEditor(store: store, smartFolder: smartFolder) { saved in
                let existing = store.smartFolders.contains { $0.id == saved.id }
                if existing { store.updateSmartFolder(saved) } else { _ = store.addSmartFolder(saved) }
                selection = .smartFolder(saved.id)
            }
        }
        .sheet(isPresented: $showDuplicateScanner) {
            DuplicateScannerView(
                store: store,
                currentItems: currentItems,
                selectedIDs: selectedItemIDs,
                initialGroups: duplicateInitialGroups,
                initialMode: duplicateInitialGroups.isEmpty ? .exact : .similar
            )
                .frame(minWidth: 820, minHeight: 590)
        }
        .sheet(isPresented: $showAISettings) {
            AISettingsView()
                .frame(width: 760, height: 620)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false; runStartupDuplicateCheckIfNeeded() }
        }
        return presentedWorkspace
        .onAppear {
            NSWindow.allowsAutomaticWindowTabbing = false
            LibrarySyncController.shared.start(store: store)
            showOnboarding = !UserDefaults.standard.bool(forKey: "EagleReplica.onboarding.completed.v1")
            store.purgeExpiredTrash()
            aiTagger.scheduleAutomaticTagging(in: store)
            runStartupDuplicateCheckIfNeeded()
        }
        .onChange(of: browserBridge.status) { _, status in
            if status == .ready { bridgeStatusHidden = false }
        }
        .onChange(of: selection) { oldSelection, newSelection in
            if let activeTagBrowse, newSelection != .tag(activeTagBrowse) {
                self.activeTagBrowse = nil
                tagBrowseReturnSelection = nil
            }
            if activeTagBrowse == nil { store.rememberSelection(selection) }
            selectedItemIDs.removeAll()
            if isRestoringHistory {
                isRestoringHistory = false
            } else {
                backHistory.append(oldSelection)
                if backHistory.count > 50 { backHistory.removeFirst() }
                forwardHistory.removeAll()
            }
        }
        .onChange(of: currentItems.map(\.id)) { _, visibleIDs in
            selectedItemIDs.formIntersection(Set(visibleIDs))
            if let previewItemID, !visibleIDs.contains(previewItemID) { self.previewItemID = nil }
        }
        .onChange(of: store.libraryURL) { _, _ in
            LibrarySyncController.shared.libraryDidChange()
            DispatchQueue.main.async {
                selection = store.lastSelection
                selectedItemIDs.removeAll()
                backHistory.removeAll()
                forwardHistory.removeAll()
                aiTagger.scheduleAutomaticTagging(in: store)
                didRunStartupDuplicateCheck = false
                runStartupDuplicateCheckIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryNewFolder)) { _ in
            let folder = store.addFolder(named: "新建风格文件夹")
            sidebarVisible = true
            selection = .folder(folder)
            requestedFolderRename = folder
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryImport)) { _ in showImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPreviewSelection)) { _ in
            guard let id = selectedItemIDs.first, currentItems.contains(where: { $0.id == id }) else { return }
            store.markOpened(id)
            previewItemID = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryToggleSidebar)) { _ in sidebarVisible.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryToggleInspector)) { _ in inspectorRequested.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImportAsset)) { notification in
            guard let item = notification.object as? LibraryItem else { return }
            aiTagger.enqueueAutomatically(item, in: store)
            sidebarVisible = true
            selection = item.folder.isEmpty ? .section(.uncategorized) : .folder(item.folder)
            selectedItemIDs = [item.id]
            let destination = item.folder.isEmpty ? "未分类" : item.folder
            let token = UUID()
            importToastToken = token
            withAnimation(.easeOut(duration: 0.18)) { importToast = "已加入“\(destination)”" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                guard importToastToken == token else { return }
                withAnimation(.easeIn(duration: 0.18)) { importToast = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiSettingsDidChange)) { _ in
            aiTagger.scheduleAutomaticTagging(in: store, retryFailures: true)
        }
        .modifier(LibraryCommandBridge(
            selectionCount: selectedItemIDs.count,
            onCopy: { copySelectedAssets() },
            onPaste: { pasteClipboard() },
            onToast: { showToast($0) },
            onSelectionCountChanged: { LibraryEditingState.shared.updateSelectionCount($0) }
        ))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.purgeExpiredTrash()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            store.purgeExpiredTrash()
        }
    }

    private func runStartupDuplicateCheckIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "EagleReplica.onboarding.completed.v1") else { return }
        guard !didRunStartupDuplicateCheck else { return }
        didRunStartupDuplicateCheck = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            let groups = DuplicateScanner.scan(
                store.items.filter { !$0.isTrashed },
                mode: .similar,
                store: store
            )
            guard !groups.isEmpty else { return }
            duplicateInitialGroups = groups
            showDuplicateScanner = true
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard let item = try? store.importFile(at: url, folder: importFolder) else { continue }
            selectedItemIDs = Set([item.id])
        }
    }

    /// 复制当前选中的素材。文件地址、图片数据和库内 ID 会一起写进剪贴板，
    /// 所以粘到访达是文件，粘到聊天软件是图片，粘回灵感库则识别为同一张。
    private func copySelectedAssets() {
        let selected = store.items.filter { selectedItemIDs.contains($0.id) }
        let copied = AssetClipboard.copy(selected, store: store)
        showToast(copied > 0 ? "已复制 \(copied) 张素材" : "没有可复制的素材")
    }

    /// 把剪贴板里的图片放进素材库，落在当前打开的文件夹里。
    private func pasteClipboard() {
        let pasted = AssetClipboard.paste(into: store, folder: importFolder)
        guard pasted.isEmpty else {
            selectedItemIDs = Set(pasted.map(\.id))
            return
        }
        showToast("剪贴板里没有可粘贴的图片")
    }

    private var importFolder: String {
        if case .folder(let folder) = selection { return folder }
        return ""
    }

    private var selectionTitle: String {
        if case .smartFolder(let id) = selection { return store.smartFolders.first(where: { $0.id == id })?.name ?? "智能文件夹" }
        return selection.title
    }

    private func goBack() {
        guard let target = backHistory.popLast() else { return }
        isRestoringHistory = true
        forwardHistory.append(selection)
        selection = target
    }

    private func goForward() {
        guard let target = forwardHistory.popLast() else { return }
        isRestoringHistory = true
        backHistory.append(selection)
        selection = target
    }

    private func browseTag(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if activeTagBrowse == nil { tagBrowseReturnSelection = selection }
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.18)
        withAnimation(animation) {
            activeTagBrowse = normalized
            selection = .tag(normalized)
            selectedItemIDs.removeAll()
        }
    }

    private func dismissTagBrowse() {
        guard activeTagBrowse != nil else { return }
        let returnSelection = tagBrowseReturnSelection ?? .section(.all)
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.16)
        withAnimation(animation) {
            activeTagBrowse = nil
            tagBrowseReturnSelection = nil
            selectedItemIDs.removeAll()
            selection = returnSelection
        }
    }

    private func createSmartFolder(from tag: String) {
        if let existing = store.smartFolders.first(where: {
            $0.rules.count == 1 && $0.rules[0].field == .aiTag &&
            $0.rules[0].operation == .equals &&
            $0.rules[0].value.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            activeTagBrowse = nil
            tagBrowseReturnSelection = nil
            selection = .smartFolder(existing.id)
            showToast("已打开智能文件夹“\(existing.name)”")
            return
        }

        let smartFolder = store.addSmartFolder(SmartFolder(
            name: tag,
            rules: [SmartFolderRule(field: .aiTag, operation: .equals, value: tag)]
        ))
        activeTagBrowse = nil
        tagBrowseReturnSelection = nil
        selection = .smartFolder(smartFolder.id)
        showToast("已创建智能文件夹“\(tag)”")
    }

    private func addTagToStyleLibrary(_ tag: String) {
        var names = StyleFavoritesStorage.decode(favoriteStylesData)
        names.insert(tag)
        favoriteStylesData = StyleFavoritesStorage.encode(names)
        showToast("已将“\(tag)”加入风格库")
    }

    private func showToast(_ message: String) {
        let token = UUID()
        importToastToken = token
        withAnimation(.easeOut(duration: 0.18)) { importToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard importToastToken == token else { return }
            withAnimation(.easeIn(duration: 0.18)) { importToast = nil }
        }
    }
}

private enum SidebarFolderTarget: Equatable {
    case style(String)
    case reference(String)
}

private struct LibrarySidebar: View {
    @ObservedObject var store: LibraryStore
    @Binding var selection: SidebarSelection
    @Binding var selectedItemIDs: Set<UUID>
    let importAction: () -> Void
    let addSmartFolderAction: () -> Void
    let editSmartFolderAction: (SmartFolder) -> Void
    let scanDuplicatesAction: () -> Void
    let settingsAction: () -> Void
    let toggleSidebarAction: () -> Void
    @Binding var requestedFolderRename: String?
    @State private var renameFolder: String?
    @State private var renameText = ""
    @State private var renameReferenceFolder: String?
    @State private var renameReferenceText = ""
    @State private var sidebarFilterText = ""
    @State private var showLibrarySwitcher = false
    @State private var dropTargetFolder: SidebarFolderTarget?
    @State private var draggedFolder: String?
    @State private var reorderTargetFolder: SidebarFolderTarget?
    @AppStorage("EagleReplica.sidebar.smartFoldersExpanded") private var smartFoldersExpanded = true
    @AppStorage("EagleReplica.sidebar.referenceFoldersExpanded") private var referenceFoldersExpanded = true
    @AppStorage("EagleReplica.sidebar.foldersExpanded") private var foldersExpanded = true
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                Menu {
                    Button("导入图片…", systemImage: "photo.badge.plus", action: importAction)
                    Button("新建风格文件夹", systemImage: "folder.badge.plus") { createFolder() }
                    Button("新建参考文件夹", systemImage: "folder.badge.questionmark") { createReferenceFolder() }
                    Button("新建智能文件夹", systemImage: "folder.badge.gearshape", action: createSmartFolder)
                    Divider()
                    Button("扫描重复文件", systemImage: "doc.on.doc", action: scanDuplicatesAction)
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                Button(action: toggleSidebarAction) { Image(systemName: "sidebar.left") }
                    .help("隐藏侧栏")
            }
            .buttonStyle(IconButtonStyle())
            .frame(height: WorkspaceLayoutMetrics.topBarHeight)
            .padding(.trailing, 14)
            .offset(y: WorkspaceLayoutMetrics.topBarContentOffset)

            Button { showLibrarySwitcher.toggle() } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.blue)
                        .frame(width: 22, height: 22)
                        .overlay(Image(systemName: "archivebox.fill").font(.system(size: 13)).foregroundStyle(.white))
                    Text(store.libraryDisplayName)
                        .font(.custom(WorkspaceLayoutMetrics.sidebarMediumFontName, fixedSize: 14))
                        .foregroundStyle(Color.eagleSidebarSelectedText)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Color.eagleSecondary)
                    Spacer()
                }
                .foregroundStyle(Color.eaglePrimary)
                .padding(.horizontal, 19)
                .frame(height: WorkspaceLayoutMetrics.sidebarLibraryHeaderHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(
                isPresented: $showLibrarySwitcher,
                attachmentAnchor: .point(.bottomLeading),
                arrowEdge: .top
            ) {
                ResourceLibraryPopover(store: store)
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredSections) { section in
                        SidebarRow(
                            title: section.title,
                            icon: section.icon,
                            count: count(for: section),
                            selected: selection == .section(section)
                        ) { selection = .section(section) }
                    }
                    CollapsibleSectionHeader(
                        title: "智能文件夹",
                        isExpanded: $smartFoldersExpanded,
                        addHelp: "新增智能文件夹",
                        addAction: createSmartFolder
                    )
                    .padding(.top, WorkspaceLayoutMetrics.sidebarGroupSeparation)
                    if smartFoldersExpanded {
                        ForEach(filteredSmartFolders) { smartFolder in
                            SidebarRow(
                                title: smartFolder.name,
                                icon: smartFolder.aiGeneratedTag == nil ? "folder.badge.gearshape" : "sparkles.rectangle.stack",
                                count: store.count(in: .smartFolder(smartFolder.id)),
                                selected: selection == .smartFolder(smartFolder.id)
                            ) { selection = .smartFolder(smartFolder.id) }
                            .contextMenu {
                                if smartFolder.aiGeneratedTag == nil {
                                    Button("编辑规则", systemImage: "slider.horizontal.3") { editSmartFolderAction(smartFolder) }
                                } else {
                                    Label("由 AI 标签自动维护", systemImage: "sparkles")
                                }
                                Button("删除智能文件夹", systemImage: "trash", role: .destructive) {
                                    store.deleteSmartFolder(smartFolder.id)
                                    selection = .section(.all)
                                }
                            }
                        }
                    }
                    CollapsibleSectionHeader(
                        title: "参考文件夹 (\(store.referenceFolders.count))",
                        isExpanded: $referenceFoldersExpanded,
                        addHelp: "新增参考文件夹",
                        addAction: createReferenceFolder
                    )
                    if referenceFoldersExpanded {
                        ForEach(filteredReferenceFolders, id: \.self) { folder in
                            if renameReferenceFolder == folder {
                                HStack(spacing: 9) {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.system(size: 14))
                                        .frame(width: 17)
                                    TextField("参考文件夹名称", text: $renameReferenceText)
                                        .textFieldStyle(.plain)
                                        .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 13))
                                        .focused($renameFieldFocused)
                                        .onSubmit(commitReferenceRename)
                                    Text("\(store.count(in: .referenceFolder(folder)))")
                                        .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 11))
                                        .foregroundStyle(Color.eagleSidebarCount)
                                }
                                .foregroundStyle(Color.eaglePrimary)
                                .padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .background(Color.eagleSelection)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onExitCommand(perform: cancelReferenceRename)
                                .task {
                                    NSApp.activate(ignoringOtherApps: true)
                                    renameFieldFocused = true
                                }
                            } else {
                                SidebarFolderRow(
                                    title: folder,
                                    count: store.count(in: .referenceFolder(folder)),
                                    selected: selection == .referenceFolder(folder),
                                    dropTargeted: reorderTargetFolder == .reference(folder)
                                        || dropTargetFolder == .reference(folder),
                                    reorderChanged: { translation in
                                        draggedFolder = folder
                                        reorderTargetFolder = reorderTarget(
                                            for: folder,
                                            in: store.referenceFolders,
                                            verticalTranslation: translation
                                        ).map(SidebarFolderTarget.reference)
                                    },
                                    reorderEnded: { translation in
                                        if let target = reorderTarget(
                                            for: folder,
                                            in: store.referenceFolders,
                                            verticalTranslation: translation
                                        ) {
                                            _ = store.reorderReferenceFolder(folder, over: target)
                                        }
                                        draggedFolder = nil
                                        reorderTargetFolder = nil
                                    }
                                ) { selection = .referenceFolder(folder) }
                                .dropDestination(for: AssetTransfer.self) { transfers, _ in
                                    acceptAssetTransfers(transfers, intoReferenceFolder: folder)
                                } isTargeted: { targeted in
                                    let target = SidebarFolderTarget.reference(folder)
                                    if targeted { dropTargetFolder = target }
                                    else if dropTargetFolder == target { dropTargetFolder = nil }
                                }
                                .contextMenu {
                                    Button("重命名", systemImage: "pencil") { beginReferenceRename(folder) }
                                    Button("新建参考文件夹", systemImage: "folder.badge.questionmark") { createReferenceFolder() }
                                    Divider()
                                    Button("删除参考文件夹", systemImage: "trash", role: .destructive) {
                                        store.deleteReferenceFolder(folder)
                                        selection = .section(.all)
                                    }
                                }
                            }
                        }
                    }
                    CollapsibleSectionHeader(
                        title: "风格文件夹 (\(store.folders.count))",
                        isExpanded: $foldersExpanded,
                        addHelp: "新增风格文件夹",
                        addAction: createFolder
                    )
                    if foldersExpanded {
                        ForEach(filteredFolders, id: \.self) { folder in
                            Group {
                                if renameFolder == folder {
                                    HStack(spacing: 9) {
                                        Image(systemName: "folder").font(.system(size: 14)).frame(width: 17)
                                        TextField("文件夹名称", text: $renameText)
                                            .textFieldStyle(.plain)
                                            .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 13))
                                            .focused($renameFieldFocused)
                                            .onSubmit(commitRename)
                                        Text("\(store.count(in: .folder(folder)))")
                                            .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 11))
                                            .foregroundStyle(Color.eagleSidebarCount)
                                    }
                                    .foregroundStyle(Color.eaglePrimary)
                                    .padding(.horizontal, 9)
                                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                    .background(Color.eagleSelection)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onExitCommand(perform: cancelRename)
                                    .task {
                                        NSApp.activate(ignoringOtherApps: true)
                                        renameFieldFocused = true
                                    }
                                } else {
                                    reorderableFolderRow(folder)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                Button(action: settingsAction) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Color.eagleField)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("AI 与应用设置")

                Button {
                    selection = .section(.trash)
                    selectedItemIDs.removeAll()
                } label: {
                    Image(systemName: selection == .section(.trash) ? "trash.fill" : "trash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(selection == .section(.trash) ? Color.eagleSelection : Color.eagleField)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("回收站")

                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    TextField("筛选", text: $sidebarFilterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !sidebarFilterText.isEmpty {
                        Button { sidebarFilterText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.eagleField)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 13))
            .foregroundStyle(Color.eagleSecondary)
            .padding(10)
        }
        .background(Color.eaglePanel)
        .onChange(of: requestedFolderRename) { _, folder in
            guard let folder else { return }
            foldersExpanded = true
            beginRename(folder)
            requestedFolderRename = nil
        }
        .onChange(of: renameFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                if renameFolder != nil { commitRename() }
                if renameReferenceFolder != nil { commitReferenceRename() }
            }
        }
    }

    private func reorderableFolderRow(_ folder: String) -> some View {
        SidebarFolderRow(
            title: folder,
            count: store.count(in: .folder(folder)),
            selected: selection == .folder(folder),
            dropTargeted: reorderTargetFolder == .style(folder)
                || dropTargetFolder == .style(folder),
            reorderChanged: { translation in
                draggedFolder = folder
                reorderTargetFolder = reorderTarget(
                    for: folder,
                    in: store.folders,
                    verticalTranslation: translation
                ).map(SidebarFolderTarget.style)
            },
            reorderEnded: { translation in
                if let target = reorderTarget(
                    for: folder,
                    in: store.folders,
                    verticalTranslation: translation
                ) {
                    _ = store.reorderFolder(folder, over: target)
                }
                draggedFolder = nil
                reorderTargetFolder = nil
            }
        ) { selection = .folder(folder) }
        .contentShape(Rectangle())
        .dropDestination(for: AssetTransfer.self) { transfers, _ in
            acceptAssetTransfers(transfers, intoStyleFolder: folder)
        } isTargeted: { targeted in
            let target = SidebarFolderTarget.style(folder)
            if targeted { dropTargetFolder = target }
            else if dropTargetFolder == target { dropTargetFolder = nil }
        }
        .contextMenu {
            Button("重命名", systemImage: "pencil") { beginRename(folder) }
            Button("新建风格文件夹", systemImage: "folder.badge.plus") { createFolder() }
            Divider()
            Button("删除文件夹", systemImage: "trash", role: .destructive) {
                store.deleteFolder(folder)
                selection = .section(.uncategorized)
            }
        }
        .overlay(alignment: .top) {
            if reorderTargetFolder == .style(folder), draggedFolder != folder {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 7)
                    .offset(y: -1)
            }
        }
    }

    private func reorderTarget(
        for source: String,
        in folders: [String],
        verticalTranslation: CGFloat
    ) -> String? {
        guard let sourceIndex = folders.firstIndex(of: source), folders.count > 1 else { return nil }
        let rowStride: CGFloat = 32
        let offset = Int((verticalTranslation / rowStride).rounded())
        let targetIndex = min(max(sourceIndex + offset, folders.startIndex), folders.index(before: folders.endIndex))
        guard targetIndex != sourceIndex else { return nil }
        return folders[targetIndex]
    }

    private var normalizedSidebarFilter: String {
        sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSections: [LibrarySection] {
        let primarySections = LibrarySection.allCases.filter { $0 != .trash }
        guard !normalizedSidebarFilter.isEmpty else { return primarySections }
        return primarySections.filter { sidebarFilterMatches($0.rawValue) }
    }

    private var filteredSmartFolders: [SmartFolder] {
        guard !normalizedSidebarFilter.isEmpty else { return store.smartFolders }
        return store.smartFolders.filter { sidebarFilterMatches($0.name) }
    }

    private var filteredFolders: [String] {
        guard !normalizedSidebarFilter.isEmpty else { return store.folders }
        return store.folders.filter(sidebarFilterMatches)
    }

    private var filteredReferenceFolders: [String] {
        guard !normalizedSidebarFilter.isEmpty else { return store.referenceFolders }
        return store.referenceFolders.filter(sidebarFilterMatches)
    }

    private func sidebarFilterMatches(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains(normalizedSidebarFilter)
    }

    private func count(for section: LibrarySection) -> Int? {
        switch section {
        case .all, .uncategorized, .untagged, .recent, .community, .trash: store.count(in: .section(section))
        default: nil
        }
    }

    private func createFolder() {
        foldersExpanded = true
        let folder = store.addFolder(named: "新建风格文件夹")
        selection = .folder(folder)
        beginRename(folder)
    }

    private func createReferenceFolder() {
        referenceFoldersExpanded = true
        let folder = store.addReferenceFolder()
        selection = .referenceFolder(folder)
        beginReferenceRename(folder)
    }

    private func createSmartFolder() {
        smartFoldersExpanded = true
        addSmartFolderAction()
    }

    private func beginRename(_ folder: String) {
        renameFolder = folder
        renameText = folder
        renameFieldFocused = true
    }

    private func commitRename() {
        guard let old = renameFolder else { return }
        let proposed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { cancelRename(); return }
        let resolved = store.renameFolder(old, to: proposed)
        selection = .folder(resolved)
        renameFolder = nil
        renameFieldFocused = false
    }

    private func cancelRename() {
        renameFolder = nil
        renameFieldFocused = false
    }

    private func beginReferenceRename(_ folder: String) {
        renameReferenceFolder = folder
        renameReferenceText = folder
        renameFieldFocused = true
    }

    private func commitReferenceRename() {
        guard let old = renameReferenceFolder else { return }
        let proposed = renameReferenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { cancelReferenceRename(); return }
        let resolved = store.renameReferenceFolder(old, to: proposed)
        selection = .referenceFolder(resolved)
        renameReferenceFolder = nil
        renameFieldFocused = false
    }

    private func cancelReferenceRename() {
        renameReferenceFolder = nil
        renameFieldFocused = false
    }

    private func acceptFolderDrop(_ providers: [NSItemProvider], into folder: String) -> Bool {
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.eagleLibraryItem.identifier)
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.eagleLibraryItem.identifier) { data, _ in
                guard let data,
                      let rawID = String(data: data, encoding: .utf8),
                      let draggedID = UUID(uuidString: rawID) else { return }
                Task { @MainActor in
                    let ids = selectedItemIDs.contains(draggedID) ? selectedItemIDs : [draggedID]
                    _ = store.addToFolder(ids, folder: folder)
                    selectedItemIDs = ids
                    dropTargetFolder = nil
                }
            }
            return true
        }

        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                accepted = true
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    Task { @MainActor in
                        _ = try? store.importFile(at: url, folder: folder)
                        dropTargetFolder = nil
                    }
                }
                continue
            }
            guard let imageType = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { continue }
            accepted = true
            provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    _ = try? store.importFile(at: url, folder: folder)
                    dropTargetFolder = nil
                }
            }
        }
        return accepted
    }

    private func acceptAssetTransfers(_ transfers: [AssetTransfer], intoStyleFolder folder: String) -> Bool {
        let internalIDs = Set(transfers.compactMap(\.itemID))
        if !internalIDs.isEmpty {
            let ids = internalIDs.contains(where: selectedItemIDs.contains) ? selectedItemIDs : internalIDs
            _ = store.addToFolder(ids, folder: folder)
            selectedItemIDs = ids
        }
        var imported = false
        for url in transfers.compactMap(\.fileURL) where internalIDs.isEmpty {
            if let item = try? store.importFile(at: url, folder: folder) {
                selectedItemIDs.insert(item.id)
                imported = true
            }
        }
        dropTargetFolder = nil
        return !internalIDs.isEmpty || imported
    }

    private func acceptAssetTransfers(_ transfers: [AssetTransfer], intoReferenceFolder folder: String) -> Bool {
        let internalIDs = Set(transfers.compactMap(\.itemID))
        if !internalIDs.isEmpty {
            let ids = internalIDs.contains(where: selectedItemIDs.contains) ? selectedItemIDs : internalIDs
            for id in ids { store.assignReferenceFolder(id, to: folder) }
            selectedItemIDs = ids
            dropTargetFolder = nil
            return true
        }
        var imported = false
        for url in transfers.compactMap(\.fileURL) {
            if let item = try? store.importFile(at: url, folder: "") {
                store.assignReferenceFolder(item.id, to: folder)
                selectedItemIDs.insert(item.id)
                imported = true
            }
        }
        dropTargetFolder = nil
        return imported
    }
}

private struct SidebarFolderDragPreview: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .frame(width: 17)
            Text(title)
                .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 11))
                .foregroundStyle(Color.eagleSidebarCount)
        }
        .foregroundStyle(Color.eagleSidebarSelectedText)
        .padding(.horizontal, 10)
        .frame(width: 200, height: 32)
        .background(Color.eagleSelection)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.32), radius: 8, y: 4)
    }
}

private struct SidebarFolderDropDelegate: DropDelegate {
    let targetFolder: String
    @Binding var activeDraggedFolder: String?
    @Binding var reorderTargetFolder: String?
    @Binding var assetDropTargetFolder: String?
    let reorder: (String, String) -> Void
    let acceptAssets: ([NSItemProvider], String) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [
            UTType.eagleFolderOrder.identifier,
            UTType.eagleLibraryItem.identifier,
            UTType.fileURL.identifier,
            UTType.image.identifier
        ])
    }

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [UTType.eagleFolderOrder.identifier]) {
            assetDropTargetFolder = nil
            guard let source = activeDraggedFolder,
                  source != targetFolder,
                  reorderTargetFolder != targetFolder else { return }
            reorderTargetFolder = targetFolder
            withAnimation(.easeOut(duration: 0.14)) {
                reorder(source, targetFolder)
            }
        } else {
            reorderTargetFolder = nil
            assetDropTargetFolder = targetFolder
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [UTType.eagleFolderOrder.identifier]) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        if reorderTargetFolder == targetFolder { reorderTargetFolder = nil }
        if assetDropTargetFolder == targetFolder { assetDropTargetFolder = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            activeDraggedFolder = nil
            reorderTargetFolder = nil
            assetDropTargetFolder = nil
        }
        if info.hasItemsConforming(to: [UTType.eagleFolderOrder.identifier]) { return true }
        let providers = info.itemProviders(for: [
            UTType.eagleLibraryItem.identifier,
            UTType.fileURL.identifier,
            UTType.image.identifier
        ])
        return acceptAssets(providers, targetFolder)
    }
}

private struct ResourceLibraryPopover: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var message: String?

    private var visibleLibraries: [URL] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.recentLibraryURLs }
        return store.recentLibraryURLs.filter {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField("搜索资源库…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.eagleSecondary)
            .padding(.horizontal, 14)
            .frame(height: 40)

            Divider().overlay(Color.eagleLine)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(visibleLibraries, id: \.self) { url in
                        Button { open(url) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "archivebox.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Color.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(url)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(url.path).font(.system(size: 11)).foregroundStyle(Color.eagleSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if url.standardizedFileURL == store.libraryURL.standardizedFileURL {
                                    Image(systemName: "checkmark").foregroundStyle(Color.eaglePrimary)
                                }
                                Image(systemName: "ellipsis").foregroundStyle(Color.eagleSecondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
            }
            .frame(minHeight: 52, maxHeight: 112)

            Divider().overlay(Color.eagleLine)

            VStack(spacing: 0) {
                libraryAction("创建资源库…", icon: "externaldrive.badge.plus", action: create)
                libraryAction("打开其他资源库…", icon: "folder", action: chooseAndOpen)
                libraryAction("导入 Eagle 资源库…", icon: "square.and.arrow.down", action: importEagle)
                libraryAction("导出为 Eagle 资源库…", icon: "square.and.arrow.up", action: exportEagle)
                libraryAction("清除缓存并重新加载", icon: "arrow.clockwise", action: reload)
                libraryAction("合并其他资源库…", icon: "point.3.connected.trianglepath.dotted", action: merge)
            }
            .padding(.vertical, 5)

            if let message {
                Divider().overlay(Color.eagleLine)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.eagleSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
            }
        }
        .frame(width: WorkspaceLayoutMetrics.resourceLibraryPopoverWidth)
        .background(Color.eaglePanel)
        .preferredColorScheme(.dark)
    }

    private func libraryAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(Color.eaglePrimary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func displayName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name == "Library" ? "小羊的灵感库" : name
    }

    private func open(_ url: URL) {
        do { try store.openLibrary(at: url); message = nil }
        catch { message = error.localizedDescription }
    }

    private func create() {
        let panel = NSSavePanel()
        panel.title = "创建资源库"
        panel.prompt = "创建"
        panel.nameFieldStringValue = "新建灵感库"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.createLibrary(at: url); message = "资源库已创建" }
        catch { message = error.localizedDescription }
    }

    private func chooseLibrary(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseAndOpen() {
        guard let url = chooseLibrary(title: "打开资源库") else { return }
        open(url)
    }

    private func reload() {
        store.reloadLibrary()
        message = "已重新加载当前资源库"
    }

    private func importEagle() {
        guard let url = chooseLibrary(title: "导入 Eagle 资源库") else { return }
        do {
            let count = try store.importEagleLibrary(at: url)
            message = count == 0 ? "没有发现新的素材" : "已从 Eagle 导入 \(count) 个素材"
        } catch {
            message = error.localizedDescription
        }
    }

    private func exportEagle() {
        let panel = NSSavePanel()
        panel.title = "导出 Eagle 资源库"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(displayName(store.libraryURL)).library"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "library" {
            url.appendPathExtension("library")
        }
        do {
            try store.exportEagleLibrary(to: url)
            message = "已导出可供 Eagle 读取的资源库"
        } catch {
            message = error.localizedDescription
        }
    }

    private func merge() {
        guard let url = chooseLibrary(title: "合并其他资源库") else { return }
        do {
            let count = try store.mergeLibrary(at: url)
            message = "已合并 \(count) 个素材"
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let count: Int?
    let selected: Bool
    var dropTargeted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
    }

    private var content: some View {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 17)
                Text(title)
                    .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 13))
                    .lineLimit(1)
                Spacer(minLength: 5)
                if let count {
                    Text("\(count)")
                        .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 11))
                        .foregroundStyle(Color.eagleSidebarCount)
                }
            }
            .foregroundStyle(selected ? Color.eagleSidebarSelectedText : Color.eagleSidebarText)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
            .background(dropTargeted ? Color.accentColor.opacity(0.20) : (selected ? Color.eagleSelection : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(dropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SidebarFolderRow: View {
    let title: String
    let count: Int
    let selected: Bool
    let dropTargeted: Bool
    let reorderChanged: (CGFloat) -> Void
    let reorderEnded: (CGFloat) -> Void
    let action: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var isReordering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .frame(width: 17)
            Text(title)
                .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 13))
                .lineLimit(1)
            Spacer(minLength: 5)
            Text("\(count)")
                .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 11))
                .foregroundStyle(Color.eagleSidebarCount)
        }
        .foregroundStyle(selected ? Color.eagleSidebarSelectedText : Color.eagleSidebarText)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .background(dropTargeted ? Color.accentColor.opacity(0.20) : (selected ? Color.eagleSelection : .clear))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(dropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .offset(y: isReordering ? dragOffset : 0)
        .scaleEffect(isReordering ? 1.015 : 1)
        .shadow(color: isReordering ? Color.black.opacity(0.35) : .clear, radius: 8, y: 4)
        .zIndex(isReordering ? 20 : 0)
        .onTapGesture(perform: action)
        .highPriorityGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    isReordering = true
                    dragOffset = value.translation.height
                    reorderChanged(value.translation.height)
                }
                .onEnded { value in
                    reorderEnded(value.translation.height)
                    withAnimation(.easeOut(duration: 0.14)) {
                        dragOffset = 0
                        isReordering = false
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { action() }
    }
}

private struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    let addHelp: String
    let addAction: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: addAction) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(hovering ? 0.07 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help(addHelp)
            .accessibilityLabel(addHelp)
        }
        .font(.custom(WorkspaceLayoutMetrics.sidebarRegularFontName, fixedSize: 12))
        .foregroundStyle(hovering ? Color.eagleSidebarText : Color.eagleSidebarSectionText)
        .padding(.leading, 11)
        .padding(.trailing, 2)
        .frame(height: WorkspaceLayoutMetrics.sidebarSectionHeight)
        .onHover { hovering = $0 }
    }
}

private struct LibraryToolbar: View {
    @ObservedObject private var safariExtension = SafariExtensionStatusController.shared
    let title: String
    @Binding var searchText: String
    @Binding var thumbnailWidth: Double
    @Binding var inspectorRequested: Bool
    let inspectorVisible: Bool
    @Binding var showFilterBar: Bool
    @Binding var filter: AssetFilter
    @Binding var sort: LibrarySort
    let importAction: () -> Void
    let sidebarVisible: Bool
    let toggleSidebarAction: () -> Void
    let canGoBack: Bool
    let canGoForward: Bool
    let goBackAction: () -> Void
    let goForwardAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) { fullToolbar; compactToolbar }
            .padding(.horizontal, 16)
            .frame(height: WorkspaceLayoutMetrics.topBarHeight)
            .offset(y: WorkspaceLayoutMetrics.topBarContentOffset)
            .background(Color.eagleMain)
            .onAppear { safariExtension.refresh() }
    }

    private var navigation: some View {
        HStack(spacing: 14) {
            if !sidebarVisible {
                Button(action: toggleSidebarAction) { Image(systemName: "sidebar.left") }
                    .help("显示侧栏")
            }
            Button(action: goBackAction) { Image(systemName: "chevron.left") }
                .disabled(!canGoBack).help("返回")
            Button(action: goForwardAction) { Image(systemName: "chevron.right") }
                .disabled(!canGoForward).help("前进")
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
        }
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
            TextField("搜索", text: $searchText).textFieldStyle(.plain).font(.system(size: 13))
            if !searchText.isEmpty { Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            Button(action: importAction) { Image(systemName: "camera.badge.ellipsis") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).frame(width: 180, height: 31)
        .background(Color.eagleField).clipShape(RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Color.white.opacity(0.72))
    }

    private var tools: some View {
        HStack(spacing: 15) {
            Menu {
                Picker("排列方式", selection: $sort) { ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) } }
            } label: { Image(systemName: "rectangle.split.3x1") }
            .menuStyle(.borderlessButton)
            Button { showFilterBar.toggle() } label: { Image(systemName: "line.3.horizontal.decrease") }.buttonStyle(.plain)
        }
    }

    private var safariExtensionButton: some View {
        Button {
            safariExtension.installOrManageExtension()
        } label: {
            Image(systemName: safariExtension.status.isEnabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(safariExtension.status.isEnabled ? Color.white.opacity(0.96) : Color.white.opacity(0.28))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(safariExtension.status == .installing)
        .help(safariExtension.helpText)
        .accessibilityLabel(safariExtension.status.isEnabled ? "Safari 扩展已启用" : "安装 Safari 扩展")
    }

    private var fullToolbar: some View {
        HStack(spacing: 14) {
            navigation; Spacer(minLength: 10)
            Image(systemName: "minus").foregroundStyle(Color.eagleSecondary)
            Slider(value: $thumbnailWidth, in: ThumbnailScaleMath.range).controlSize(.small).frame(width: 105)
            Image(systemName: "plus").foregroundStyle(Color.eagleSecondary)
            Spacer(minLength: 10); safariExtensionButton; tools; search
            if !inspectorVisible {
                Button { inspectorRequested = true } label: { Image(systemName: "pin") }
                    .help("显示详情栏")
            }
        }
        .buttonStyle(IconButtonStyle()).foregroundStyle(Color.eaglePrimary)
    }

    private var compactToolbar: some View {
        HStack(spacing: 12) {
            navigation; Spacer(minLength: 8); search.frame(maxWidth: 180)
            safariExtensionButton
            Button { showFilterBar.toggle() } label: { Image(systemName: "line.3.horizontal.decrease") }
            if !inspectorVisible {
                Button { inspectorRequested = true } label: { Image(systemName: "pin") }
                    .help("显示详情栏")
            }
        }
        .buttonStyle(IconButtonStyle()).foregroundStyle(Color.eaglePrimary)
    }
}

private struct QuickFilterBar: View {
    @Binding var filter: AssetFilter
    var body: some View {
        HStack(spacing: 8) {
            ForEach(AssetFilter.allCases) { value in
                Button(value.rawValue) { filter = value }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: filter == value ? .semibold : .regular))
                    .foregroundStyle(filter == value ? Color.white : Color.eagleSecondary)
                    .padding(.horizontal, 10).frame(height: 27)
                    .background(filter == value ? Color.eagleSelection : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 42).background(Color.eagleMain)
    }
}

private struct StyleLibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject private var aiTagger = AITaggingService.shared
    @ObservedObject private var aiSettings = AISettingsStore.shared
    let items: [LibraryItem]
    @Binding var selectedItemIDs: Set<UUID>
    @Binding var previewItemID: UUID?
    @Binding var thumbnailWidth: Double
    let settingsAction: () -> Void
    @State private var selectedStyle: String?
    private var favoriteStylesData: String {
        get { StyleFavoritesStorage.encode(Set(store.favoriteStyles)) }
        nonmutating set { store.setFavoriteStyles(Array(StyleFavoritesStorage.decode(newValue))) }
    }

    private var groups: [AIStyleGroup] { AIStyleIndex.groups(in: items) }
    private var favoriteNames: Set<String> { StyleFavoritesStorage.decode(favoriteStylesData) }
    private var favoriteGroups: [AIStyleGroup] {
        StyleFavoritesStorage.favorites(in: groups, favoriteNames: favoriteNames)
    }
    private var selectedGroup: AIStyleGroup? {
        guard let selectedStyle else { return nil }
        return groups.first { $0.name == selectedStyle }
    }
    private var pendingCount: Int {
        store.items.lazy.filter { !$0.isTrashed && $0.machineTags.isEmpty }.count
    }

    var body: some View {
        Group {
            if let group = selectedGroup {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button { selectedStyle = nil; selectedItemIDs.removeAll() } label: {
                            Label("所有风格", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.eagleSecondary)
                        Divider().frame(height: 18).overlay(Color.eagleLine)
                        Text(group.name)
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(group.items.count) 张")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.eagleSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    Divider().overlay(Color.eagleLine)
                    LibraryGrid(
                        store: store,
                        items: group.items,
                        selectedItemIDs: $selectedItemIDs,
                        previewItemID: $previewItemID,
                        thumbnailWidth: $thumbnailWidth,
                        targetFolder: ""
                    )
                }
            } else if groups.isEmpty {
                emptyState
            } else {
                overview
            }
        }
        .onChange(of: groups.map(\.name)) { _, names in
            if let selectedStyle, !names.contains(selectedStyle) { self.selectedStyle = nil }
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 风格索引")
                            .font(.system(size: 18, weight: .semibold))
                        Text("从 AI 标签中整理出 \(groups.count) 种风格，点击卡片快速预览")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.eagleSecondary)
                    }
                    Spacer()
                    if pendingCount > 0 {
                        if aiSettings.hasAPIKey {
                            Button {
                                aiTagger.scheduleAutomaticTagging(in: store, retryFailures: true)
                            } label: {
                                Label("整理剩余 \(pendingCount) 张", systemImage: "sparkles")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button(action: settingsAction) {
                                Label("设置 AI", systemImage: "gearshape")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                if !favoriteGroups.isEmpty {
                    styleSection(
                        title: "置顶风格",
                        systemImage: "star.fill",
                        groups: favoriteGroups
                    )
                }

                styleSection(
                    title: "全部风格",
                    systemImage: "square.grid.2x2",
                    groups: groups
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.eagleMain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.eagleSecondary)
            Text("还没有 AI 风格标签")
                .font(.system(size: 17, weight: .semibold))
            Text("完成 AI 识别后，素材会按风格自动出现在这里")
                .font(.system(size: 11))
                .foregroundStyle(Color.eagleSecondary)
            Button(action: aiSettings.hasAPIKey ? startTagging : settingsAction) {
                Label(aiSettings.hasAPIKey ? "开始整理" : "设置 AI", systemImage: aiSettings.hasAPIKey ? "sparkles" : "gearshape")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.eagleMain)
    }

    private func startTagging() {
        aiTagger.scheduleAutomaticTagging(in: store, retryFailures: true)
    }

    private func styleSection(title: String, systemImage: String, groups: [AIStyleGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(title == "置顶风格" ? Color.accentColor : Color.eagleSecondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(groups) { group in
                    let isFavorite = favoriteNames.contains(group.name)
                    Button { selectedStyle = group.name; selectedItemIDs.removeAll() } label: {
                        StyleGroupCard(store: store, group: group, isFavorite: isFavorite)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            toggleFavorite(group.name)
                        } label: {
                            Label(
                                isFavorite ? "取消收藏" : "收藏这个风格",
                                systemImage: isFavorite ? "star.slash" : "star"
                            )
                        }
                    }
                }
            }
        }
    }

    private func toggleFavorite(_ styleName: String) {
        var names = favoriteNames
        if names.contains(styleName) {
            names.remove(styleName)
        } else {
            names.insert(styleName)
        }
        favoriteStylesData = StyleFavoritesStorage.encode(names)
    }
}

private struct StyleGroupCard: View {
    @ObservedObject var store: LibraryStore
    let group: AIStyleGroup
    let isFavorite: Bool

    private var previewItems: [LibraryItem] {
        Array(group.items.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
                    AssetImage(store: store, item: item, thumbnail: true)
                        .frame(width: StyleStackLayout.cardWidth, height: StyleStackLayout.cardHeight)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(index == 0 ? 0.34 : 0.20), lineWidth: 1)
                        }
                        .shadow(
                            color: Color.black.opacity(index == 0 ? 0.28 : 0.18),
                            radius: index == 0 ? 5 : 3,
                            x: 0,
                            y: index == 0 ? 3 : 2
                        )
                        .rotationEffect(.degrees(StyleStackLayout.rotation(index: index, count: previewItems.count)))
                        .offset(StyleStackLayout.offset(index: index, count: previewItems.count))
                        .zIndex(Double(previewItems.count - index))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: StyleStackLayout.previewHeight)
            .background(Color.eagleField)
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor, in: Circle())
                        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                        .padding(9)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.eaglePrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.eagleSecondary)
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(Color.eagleField)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.eagleLine, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// 缩略图网格里的一行：行内每张素材按自己的比例分配宽度，整行刚好铺满容器。
private struct AssetGridRow: Identifiable {
    let index: Int
    let items: [AssetGridPlacement]
    var id: Int { index }
}

private struct AssetGridPlacement: Identifiable {
    let item: LibraryItem
    let width: CGFloat
    let height: CGFloat
    var id: UUID { item.id }
}

private struct LibraryGrid: View {
    @ObservedObject var store: LibraryStore
    let items: [LibraryItem]
    @Binding var selectedItemIDs: Set<UUID>
    @Binding var previewItemID: UUID?
    @Binding var thumbnailWidth: Double
    let targetFolder: String
    var openOnSingleClick = false
    var emptyAreaAction: (() -> Void)?
    @State private var selectionAnchorID: UUID?
    @State private var pendingPermanentDeleteIDs: Set<UUID> = []
    @State private var magnificationStartWidth: Double?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(assetRows(containerWidth: proxy.size.width - horizontalPadding * 2)) { row in
                        HStack(alignment: .top, spacing: columnSpacing) {
                            ForEach(row.items) { placement in
                                assetCell(placement)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("这里还没有素材", systemImage: "photo.on.rectangle.angled", description: Text("拖入图片，或点击左上角 + 导入"))
                    .foregroundStyle(Color.eagleSecondary)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { _ = try? store.importFile(at: url, folder: targetFolder) }
            return !urls.isEmpty
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { magnification in
                    if magnificationStartWidth == nil { magnificationStartWidth = thumbnailWidth }
                    thumbnailWidth = ThumbnailScaleMath.width(
                        from: magnificationStartWidth ?? thumbnailWidth,
                        magnification: Double(magnification)
                    )
                }
                .onEnded { _ in magnificationStartWidth = nil }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Color.eagleMain
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedItemIDs.removeAll()
                    emptyAreaAction?()
                }
                .contextMenu {
                    Button("粘贴", systemImage: "doc.on.clipboard") {
                        NotificationCenter.default.post(name: .libraryPasteClipboard, object: nil)
                    }
                    .disabled(!AssetClipboard.canPaste())
                }
        }
        .confirmationDialog(
            "永久删除 \(pendingPermanentDeleteIDs.count) 个文件？",
            isPresented: Binding(
                get: { !pendingPermanentDeleteIDs.isEmpty },
                set: { if !$0 { pendingPermanentDeleteIDs.removeAll() } }
            )
        ) {
            Button("永久删除", role: .destructive) {
                store.permanentlyDelete(pendingPermanentDeleteIDs)
                pendingPermanentDeleteIDs.removeAll()
            }
            Button("取消", role: .cancel) { pendingPermanentDeleteIDs.removeAll() }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    /// 缩略图很小的时候（行高低于阈值）隐藏图片下方的文字，并收紧边距，
    /// 让一屏能排下更多素材。
    private var isCompact: Bool { ThumbnailScaleMath.isCompact(thumbnailWidth) }
    private var horizontalPadding: CGFloat { isCompact ? 8 : 16 }
    private var columnSpacing: CGFloat { isCompact ? 6 : 10 }
    private var rowSpacing: CGFloat { isCompact ? 6 : 12 }

    private var itemsByID: [UUID: LibraryItem] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 把当前列表按「原图比例 + 整行铺满」排成若干行。
    private func assetRows(containerWidth: CGFloat) -> [AssetGridRow] {
        let lookup = itemsByID
        return JustifiedGalleryLayout.rows(
            for: items.map { JustifiedGalleryLayout.Item(id: $0.id, ratio: $0.displayAspectRatio) },
            containerWidth: containerWidth,
            targetHeight: thumbnailWidth,
            spacing: columnSpacing
        ).enumerated().map { index, row in
            AssetGridRow(index: index, items: row.placements.compactMap { placement in
                guard let item = lookup[placement.id] else { return nil }
                return AssetGridPlacement(item: item, width: placement.width, height: placement.height)
            })
        }
    }

    @ViewBuilder
    private func assetCell(_ placement: AssetGridPlacement) -> some View {
        let item = placement.item
        AssetCard(
            store: store,
            item: item,
            width: placement.width,
            imageHeight: placement.height,
            showsCaption: !isCompact,
            selected: selectedItemIDs.contains(item.id)
        )
        .modifier(AssetCardDragModifier(store: store, item: item))
        .onTapGesture {
            if openOnSingleClick {
                selectedItemIDs = [item.id]
                selectionAnchorID = item.id
                store.markOpened(item.id)
                previewItemID = item.id
                return
            }
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.shift),
               let anchorID = selectionAnchorID,
               let anchorIndex = items.firstIndex(where: { $0.id == anchorID }),
               let clickedIndex = items.firstIndex(where: { $0.id == item.id }) {
                let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
                selectedItemIDs = Set(range.map { items[$0].id })
            } else if modifiers.contains(.command) {
                if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) } else { selectedItemIDs.insert(item.id) }
                selectionAnchorID = item.id
            } else {
                selectedItemIDs = [item.id]
                selectionAnchorID = item.id
            }
        }
        .onTapGesture(count: 2) {
            selectedItemIDs = [item.id]
            store.markOpened(item.id)
            previewItemID = item.id
        }
        .contextMenu {
            Button("预览", systemImage: "eye") {
                selectedItemIDs = [item.id]
                store.markOpened(item.id)
                previewItemID = item.id
            }
            Button("复制", systemImage: "doc.on.doc") {
                let ids = actionIDs(for: item)
                selectedItemIDs = ids
                let selected = items.filter { ids.contains($0.id) }
                let copied = AssetClipboard.copy(selected, store: store)
                NotificationCenter.default.post(
                    name: .libraryShowToast,
                    object: copied > 0 ? "已复制 \(copied) 张素材" : "这张素材没有可复制的原图"
                )
            }
            Button("在 Finder 中显示", systemImage: "folder") { store.reveal(item) }
            if item.sourceURL != nil { Button("打开来源网页", systemImage: "link") { store.openSource(item) } }
            Menu("移动到风格文件夹", systemImage: "folder.badge.plus") {
                Button("未分类") { store.update(actionIDs(for: item)) { $0.folder = ""; $0.isTrashed = false } }
                Divider()
                ForEach(store.folders, id: \.self) { folder in Button(folder) { store.update(actionIDs(for: item)) { $0.folder = folder; $0.isTrashed = false } } }
            }
            Divider()
            if item.isTrashed {
                Button("恢复", systemImage: "arrow.uturn.backward") { store.update(actionIDs(for: item)) { $0.isTrashed = false } }
                Button("永久删除", systemImage: "trash", role: .destructive) {
                    pendingPermanentDeleteIDs = actionIDs(for: item)
                }
            } else {
                Button("移到回收站", systemImage: "trash", role: .destructive) { store.update(actionIDs(for: item)) { $0.isTrashed = true } }
            }
        }
    }

    private func actionIDs(for item: LibraryItem) -> Set<UUID> {
        selectedItemIDs.contains(item.id) ? selectedItemIDs : [item.id]
    }
}

private struct TagBrowseBar: View {
    let tag: String
    let count: Int
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("正在浏览")
                .foregroundStyle(Color.eagleSecondary)
            Text(tag)
                .fontWeight(.semibold)
                .foregroundStyle(Color.eaglePrimary)
            Text("\(count) 张")
                .foregroundStyle(Color.eagleSecondary)
            Spacer(minLength: 8)
            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.eagleSecondary)
            .help("退出标签浏览")
        }
        .font(.system(size: 11))
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 34)
        .background(Color.eagleField.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.eagleLine).frame(height: 1)
        }
    }
}

enum ThumbnailScaleMath {
    /// 下限够小才能排得密，上限放开到 380，方便放大看细节。
    static let range: ClosedRange<Double> = 76...380
    /// 行高低于这个值时进入紧凑模式：隐藏名称与尺寸文字，并收紧间距。
    static let compactThreshold: Double = 132

    static func width(from startWidth: Double, magnification: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, startWidth * magnification))
    }

    static func isCompact(_ height: Double) -> Bool {
        height < compactThreshold
    }
}

private struct AssetCard: View {
    @ObservedObject var store: LibraryStore
    let item: LibraryItem
    let width: CGFloat
    /// 缩略图高度由排版算好：与宽度一起构成原图比例，不再统一裁成竖版。
    let imageHeight: CGFloat
    /// 缩略图太小时隐藏名称与尺寸，紧凑模式下只留图片。
    let showsCaption: Bool
    let selected: Bool
    @AppStorage(TrashRetentionPolicy.defaultsKey) private var trashRetentionDays = TrashRetentionPolicy.defaultDays

    var body: some View {
        VStack(spacing: showsCaption ? 5 : 0) {
            ZStack(alignment: .topLeading) {
                AssetImage(store: store, item: item, thumbnail: true, contentMode: .fit)
                    .frame(width: width, height: imageHeight)
                    .background(Color.eagleField)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(item.extensionBadge)
                    .font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).frame(height: 17)
                    .background(.black.opacity(0.48)).clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(5).opacity(selected ? 1 : 0)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            if showsCaption {
                Text(item.name).font(.system(size: 13)).multilineTextAlignment(.center)
                    .foregroundStyle(Color.eaglePrimary).lineLimit(2).frame(width: width)
                Text(item.dimensions).font(.system(size: 11)).foregroundStyle(Color.eagleSecondary)
            }
            if item.isTrashed {
                Label(trashStatusText, systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            }
        }
        .help(showsCaption ? "" : item.name)
    }

    private var trashStatusText: String {
        TrashRetentionPolicy.statusText(
            trashedAt: item.trashedAt ?? item.modifiedAt,
            retentionDays: trashRetentionDays
        )
    }
}

struct AssetImage: View {
    @ObservedObject var store: LibraryStore
    let item: LibraryItem
    var thumbnail = false
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if let url = store.imageURL(for: item, thumbnail: thumbnail), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.eagleField.overlay(Image(systemName: "photo").foregroundStyle(Color.eagleSecondary))
            }
        }.clipped()
    }
}

private struct InspectorPanel: View {
    @ObservedObject var store: LibraryStore
    @Binding var itemIDs: Set<UUID>
    @Binding var selection: SidebarSelection
    let count: Int
    let editSmartFolderAction: (SmartFolder) -> Void
    let settingsAction: () -> Void
    let browseTagAction: (String) -> Void
    let createSmartFolderFromTagAction: (String) -> Void
    let addTagToStyleLibraryAction: (String) -> Void
    let closeAction: () -> Void
    private var selectedItems: [LibraryItem] { store.items.filter { itemIDs.contains($0.id) } }
    private var item: LibraryItem? { selectedItems.count == 1 ? selectedItems.first : nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button(action: closeAction) { Image(systemName: "pin.slash") }
                    .buttonStyle(.plain)
                    .help("隐藏详情栏")
            }
            .foregroundStyle(Color.eagleSecondary)
            .frame(height: WorkspaceLayoutMetrics.topBarHeight)
            .padding(.horizontal, 16)
            .offset(y: WorkspaceLayoutMetrics.topBarContentOffset)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                if selectedItems.count > 1 {
                    BatchInspector(store: store, items: selectedItems)
                } else if let item {
                    AssetInspector(
                        store: store,
                        item: item,
                        settingsAction: settingsAction,
                        browseTagAction: browseTagAction,
                        createSmartFolderFromTagAction: createSmartFolderFromTagAction,
                        addTagToStyleLibraryAction: addTagToStyleLibraryAction
                    )
                    .id(item.id)
                } else if case .folder(let folder) = selection {
                    FolderInspector(store: store, folder: folder, selection: $selection)
                        .id(folder)
                } else if case .referenceFolder(let folder) = selection {
                    ReferenceFolderInspector(store: store, folder: folder)
                        .id(folder)
                } else if case .smartFolder(let id) = selection,
                          let smartFolder = store.smartFolders.first(where: { $0.id == id }) {
                    SmartFolderInspector(store: store, smartFolder: smartFolder, editAction: editSmartFolderAction)
                } else if case .section(let section) = selection {
                    SectionInspector(section: section, count: count)
                } else if case .tag(let tag) = selection {
                    TagInspector(store: store, tag: tag, selection: $selection)
                        .id(tag)
                }
            }
            }
        }
        .foregroundStyle(Color.eaglePrimary).background(Color.eaglePanel)
    }
}

private struct AssetInspector: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject private var aiTagger = AITaggingService.shared
    @ObservedObject private var aiSettings = AISettingsStore.shared
    let item: LibraryItem
    let settingsAction: () -> Void
    let browseTagAction: (String) -> Void
    let createSmartFolderFromTagAction: (String) -> Void
    let addTagToStyleLibraryAction: (String) -> Void
    @State private var name: String
    @State private var note: String
    @State private var source: String
    @State private var newTag = ""
    @State private var confirmPermanentDelete = false
    @State private var showAIChat = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, note, source }

    init(
        store: LibraryStore,
        item: LibraryItem,
        settingsAction: @escaping () -> Void,
        browseTagAction: @escaping (String) -> Void,
        createSmartFolderFromTagAction: @escaping (String) -> Void,
        addTagToStyleLibraryAction: @escaping (String) -> Void
    ) {
        self.store = store
        self.item = item
        self.settingsAction = settingsAction
        self.browseTagAction = browseTagAction
        self.createSmartFolderFromTagAction = createSmartFolderFromTagAction
        self.addTagToStyleLibraryAction = addTagToStyleLibraryAction
        _name = State(initialValue: item.name)
        _note = State(initialValue: item.note)
        _source = State(initialValue: item.sourceURL ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AssetImage(store: store, item: item, contentMode: .fit)
                .frame(maxWidth: .infinity).frame(height: 195)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            PhotoPaletteDots(palette: item.palette ?? [])
                .padding(.bottom, 17)
            InspectorTextField(placeholder: "标题", text: $name)
                .focused($focusedField, equals: .name).onSubmit { commit(.name) }
                .disabled(!item.hasCompletedAINaming)
                .padding(.horizontal, 16)
            if !item.hasCompletedAINaming {
                Text(aiTagger.state(for: item.id) == .running ? "AI 正在为素材命名…" : "完成首次 AI 命名后可人工修改，人工名称不会被覆盖。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.eagleSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            TextField("添加注释", text: $note, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                .padding(11).background(Color.eagleField).clipShape(RoundedRectangle(cornerRadius: 6))
                .focused($focusedField, equals: .note)
                .padding(.horizontal, 16).padding(.top, 8)
            HStack(spacing: 6) {
                InspectorTextField(placeholder: "来源网址", text: $source)
                    .focused($focusedField, equals: .source).onSubmit { commit(.source) }
                Button { commit(.source); store.openSource(itemWithDraftSource) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain).disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("打开来源网页")
            }.padding(.horizontal, 16).padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(16)
            Text("人工标签").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            TagEditor(store: store, item: item, draft: $newTag).padding(.horizontal, 16).padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(16)
            Text("颜色").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            if let palette = item.palette, !palette.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(palette.prefix(8))) { swatch in
                            PaletteCard(swatch: swatch)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 9)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在提取图片主色…")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.eagleSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 9)
            }
            Divider().overlay(Color.eagleLine).padding(16)
            Text("风格文件夹").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            Menu(item.allFolders.isEmpty ? "未分类" : item.allFolders.joined(separator: "、")) {
                Button("未分类") { store.move(item.id, to: "") }
                Divider()
                ForEach(store.folders, id: \.self) { folder in Button(folder) { store.move(item.id, to: folder) } }
            }
            .menuStyle(.borderlessButton).padding(.horizontal, 16).padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(16)
            Text("参考意义").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            Menu(item.referenceFolder ?? "未设置") {
                Button("未设置") { store.assignReferenceFolder(item.id, to: nil) }
                Divider()
                ForEach(store.referenceFolders, id: \.self) { folder in
                    Button(folder) { store.assignReferenceFolder(item.id, to: folder) }
                }
                if store.referenceFolders.isEmpty {
                    Button("新建参考文件夹") {
                        let folder = store.addReferenceFolder()
                        store.assignReferenceFolder(item.id, to: folder)
                    }
                }
            }
            .menuStyle(.borderlessButton).padding(.horizontal, 16).padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(16)
            aiTagsSection
            aiChatEntry
            Divider().overlay(Color.eagleLine).padding(.horizontal, 16).padding(.vertical, 12)
            aiPromptSection
            Divider().overlay(Color.eagleLine).padding(16)
            Text("基本信息").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            RatingRow(store: store, item: item).padding(.horizontal, 16).padding(.top, 10)
            InspectorInfo(label: "尺寸", value: item.dimensions)
            InspectorInfo(label: "文件大小", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            InspectorInfo(label: "格式", value: item.extensionBadge)
            InspectorInfo(label: "添加日期", value: item.createdAt.formatted(date: .numeric, time: .shortened))
            InspectorInfo(label: "修改日期", value: item.modifiedAt.formatted(date: .numeric, time: .shortened))
            if let eagleID = item.eagleID {
                InspectorInfo(label: "Eagle ID", value: eagleID)
            }
            Divider().overlay(Color.eagleLine).padding(16)
            if item.isTrashed {
                HStack(spacing: 8) {
                    Button("恢复", systemImage: "arrow.uturn.backward") { store.restore(item.id) }
                    Button("永久删除", systemImage: "trash", role: .destructive) { confirmPermanentDelete = true }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            } else {
                Button("移到回收站", systemImage: "trash", role: .destructive) { store.trash(item.id) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
            }
            Spacer(minLength: 16)
        }
        .onChange(of: focusedField) { old, new in
            if let old, old != new { commit(old) }
        }
        .onChange(of: item.name) { _, newName in
            if focusedField != .name { name = newName }
        }
        .task(id: item.id) {
            await store.ensurePalette(item.id)
        }
        .confirmationDialog("永久删除“\(item.name)”？", isPresented: $confirmPermanentDelete) {
            Button("永久删除", role: .destructive) { store.permanentlyDelete(item.id) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作无法撤销。")
        }
        .sheet(isPresented: $showAIChat) {
            AIAssetChatView(store: store, itemID: item.id)
                .frame(width: 560, height: 640)
        }
    }

    private var aiChatEntry: some View {
        Button { showAIChat = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("与 AI 对话")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.eaglePrimary)
                    Text(item.chatMessages.isEmpty ? "自动带入当前图片" : "继续上次对话 · \(item.chatMessages.count) 条记录")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.eagleSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.eagleSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 11)
    }

    @ViewBuilder
    private var aiTagsSection: some View {
        HStack(spacing: 8) {
            Label("AI 标签", systemImage: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary)
            Spacer()
            Button(action: settingsAction) { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("AI 设置")
            Button {
                Task { await aiTagger.tag(item, in: store) }
            } label: {
                if aiTagger.state(for: item.id) == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Text(item.machineTags.isEmpty ? "识别" : "重新识别")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(aiTagger.state(for: item.id) == .running)
        }
        .padding(.horizontal, 16)

        if !item.machineTags.isEmpty {
            MachineTagCloud(
                tags: item.machineTags,
                selectAction: browseTagAction,
                createSmartFolderAction: createSmartFolderFromTagAction,
                addToStyleLibraryAction: addTagToStyleLibraryAction
            )
                .padding(.horizontal, 16)
                .padding(.top, 9)
        } else if aiTagger.state(for: item.id) != .running {
            Text(aiSettings.hasAPIKey ? "点击“识别”，让视觉模型自动整理素材。" : "请先在设置中填写 API Key。")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.eagleSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }

        if case .failure(let message) = aiTagger.state(for: item.id) {
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.red.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 7)
        }
    }

    @ViewBuilder
    private var aiPromptSection: some View {
        HStack(spacing: 8) {
            Label("AI 提示词", systemImage: "text.badge.sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary)
            Spacer()
            if let prompt = item.aiPrompt, !prompt.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制 AI 提示词")
            }
            Button {
                Task { await aiTagger.generatePrompt(item, in: store) }
            } label: {
                if aiTagger.state(for: item.id) == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Text(item.aiPrompt == nil ? "生成" : "重新生成")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(aiTagger.state(for: item.id) == .running)
        }
        .padding(.horizontal, 16)

        if let prompt = item.aiPrompt, !prompt.isEmpty {
            Text(prompt)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.eaglePrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 16)
                .padding(.top, 9)
        } else if aiTagger.state(for: item.id) != .running {
            Text(aiSettings.hasAPIKey ? "尚未生成，自动队列会为这张素材生成一次。" : "请先在设置中填写 API Key。")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.eagleSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    private var itemWithDraftSource: LibraryItem {
        var draft = item
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sourceURL = value.isEmpty ? nil : value
        return draft
    }

    private func commit(_ field: Field) {
        switch field {
        case .name:
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != item.name else { return }
            guard store.updateManualName(item.id, name: value) else {
                name = item.name
                return
            }
        case .note:
            let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != item.note else { return }
            store.update(item.id) { $0.note = value }
        case .source:
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != (item.sourceURL ?? "") else { return }
            store.update(item.id) { $0.sourceURL = value.isEmpty ? nil : value }
        }
    }
}

private struct PaletteCard: View {
    let swatch: AssetPaletteColor

    var body: some View {
        Button(action: copyHex) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(swatch.swiftUIColor)
                    .frame(height: 38)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                VStack(spacing: 2) {
                    Text(swatch.hexString)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.eaglePrimary)
                    Text("\(swatch.displayPercentage)%")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.eagleSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 58, height: 70)
            .background(Color.eagleField)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.eagleLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击复制 \(swatch.hexString) · 占比 \(swatch.displayPercentage)%")
    }

    private func copyHex() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(swatch.hexString, forType: .string)
    }
}

private struct TagManagementView: View {
    @ObservedObject var store: LibraryStore
    @Binding var selection: SidebarSelection

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(store.tagCounts, id: \.name) { tag in
                    Button { selection = .tag(tag.name) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tag.fill").foregroundStyle(Color.accentColor)
                            Text(tag.name).lineLimit(1)
                            Spacer()
                            Text("\(tag.count)").foregroundStyle(Color.eagleSecondary)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(Color.eagleField)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("删除标签", systemImage: "trash", role: .destructive) { store.deleteTag(tag.name) }
                    }
                }
            }.padding(18)
        }
        .overlay {
            if store.tagCounts.isEmpty {
                ContentUnavailableView("还没有标签", systemImage: "tag", description: Text("在右侧素材详情栏中添加标签"))
                    .foregroundStyle(Color.eagleSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.eagleMain)
    }
}

private struct TagInspector: View {
    @ObservedObject var store: LibraryStore
    let tag: String
    @Binding var selection: SidebarSelection
    @State private var name: String
    @FocusState private var nameFieldFocused: Bool

    init(store: LibraryStore, tag: String, selection: Binding<SidebarSelection>) {
        self.store = store
        self.tag = tag
        _selection = selection
        _name = State(initialValue: tag)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorTextField(placeholder: "标签名称", text: $name)
                .focused($nameFieldFocused)
                .onSubmit(commitRename).padding(.horizontal, 16)
            Divider().overlay(Color.eagleLine).padding(16)
            Text("基本信息").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            InspectorInfo(label: "文件数", value: "\(store.count(in: .tag(tag)))")
            Button("删除此标签", systemImage: "trash", role: .destructive) {
                store.deleteTag(tag)
                selection = .section(.tags)
            }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(16)
        }
        .onChange(of: nameFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused { commitRename() }
        }
    }

    private func commitRename() {
        let proposed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { name = tag; return }
        store.renameTag(tag, to: proposed)
        selection = .tag(proposed)
    }
}

private struct FolderInspector: View {
    @ObservedObject var store: LibraryStore
    let folder: String
    @Binding var selection: SidebarSelection
    @State private var name: String
    @State private var note: String
    @FocusState private var focusedField: Field?

    private enum Field { case name, note }

    init(store: LibraryStore, folder: String, selection: Binding<SidebarSelection>) {
        self.store = store
        self.folder = folder
        _selection = selection
        let details = store.details(for: folder)
        _name = State(initialValue: details.name)
        _note = State(initialValue: details.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorTextField(placeholder: "文件夹名称", text: $name)
                .focused($focusedField, equals: .name)
                .onSubmit(commitName)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            TextField("描述", text: $note, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13))
                .lineLimit(2...3).padding(11).frame(minHeight: 48, alignment: .topLeading).background(Color.eagleField)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .focused($focusedField, equals: .note)
                .onSubmit(commitNote)
                .padding(.horizontal, 16).padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(.horizontal, 16).padding(.vertical, 16)
            Text("基本信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            InspectorInfo(label: "文件数", value: "\(store.count(in: .folder(folder)))")
            InspectorInfo(label: "占用空间", value: ByteCountFormatter.string(fromByteCount: store.totalSize(in: folder), countStyle: .file))
            InspectorInfo(label: "创建日期", value: store.details(for: folder).createdAt.formatted(date: .numeric, time: .shortened))
            if let modifiedAt = store.details(for: folder).modifiedAt {
                InspectorInfo(label: "修改日期", value: modifiedAt.formatted(date: .numeric, time: .shortened))
            }
            if let tags = store.details(for: folder).tags, !tags.isEmpty {
                InspectorInfo(label: "文件夹标签", value: tags.joined(separator: "、"))
            }
            if !(store.details(for: folder).password ?? "").isEmpty {
                InspectorInfo(label: "密码保护", value: "已保留")
            }
            Button(action: exportFolder) {
                Label("导出文件夹", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.eaglePrimary)
            .frame(height: 34)
            .background(Color.eagleSelection)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 16)
            .padding(.top, 18)
            Spacer(minLength: 16)
        }
        .onChange(of: focusedField) { old, new in
            if old == .name && new != .name { commitName() }
            if old == .note && new != .note { commitNote() }
        }
    }

    private func commitName() {
        let resolved = store.renameFolder(folder, to: name)
        name = resolved
        selection = .folder(resolved)
    }

    private func commitNote() {
        store.updateFolderNote(folder, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func exportFolder() {
        let panel = NSOpenPanel()
        panel.title = "导出“\(folder)”"
        panel.prompt = "导出"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let destination = parent.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in store.items where !item.isTrashed && item.folder == folder {
            guard let source = store.imageURL(for: item) else { continue }
            let ext = source.pathExtension.isEmpty ? item.format : source.pathExtension
            let base = item.name.replacingOccurrences(of: "/", with: "-")
            var target = destination.appendingPathComponent(base).appendingPathExtension(ext)
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = destination.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext)
                suffix += 1
            }
            try? FileManager.default.copyItem(at: source, to: target)
        }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

private struct ReferenceFolderInspector: View {
    @ObservedObject var store: LibraryStore
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorReadOnlyField(text: folder)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            InspectorReadOnlyField(text: "用于归纳图片在创作中的参考意义", secondary: true)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(.horizontal, 16).padding(.vertical, 16)
            Text("基本信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary)
                .padding(.horizontal, 16)
            InspectorInfo(label: "文件数", value: "\(store.count(in: .referenceFolder(folder)))")
            Spacer(minLength: 16)
        }
    }
}

private struct SmartFolderInspector: View {
    @ObservedObject var store: LibraryStore
    let smartFolder: SmartFolder
    let editAction: (SmartFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: smartFolder.aiGeneratedTag == nil ? "folder.badge.gearshape" : "sparkles.rectangle.stack")
                    .font(.system(size: 24))
                VStack(alignment: .leading, spacing: 3) {
                    Text(smartFolder.name).font(.system(size: 14, weight: .semibold))
                    Text(smartFolder.aiGeneratedTag == nil ? "符合\(smartFolder.matchMode.rawValue)规则" : "由高频 AI 标签自动维护")
                        .font(.system(size: 11)).foregroundStyle(Color.eagleSecondary)
                }
            }.padding(.horizontal, 16).padding(.bottom, 16)
            Divider().overlay(Color.eagleLine).padding(.horizontal, 16)
            Text("规则")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary).padding(16)
            ForEach(smartFolder.rules) { rule in
                HStack(spacing: 5) {
                    Text(rule.field.rawValue)
                    Text(rule.operation.rawValue).foregroundStyle(Color.eagleSecondary)
                    if !rule.value.isEmpty { Text(rule.value).lineLimit(1) }
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 8)
            }
            InspectorInfo(label: "文件数", value: "\(store.count(in: .smartFolder(smartFolder.id)))")
            if smartFolder.aiGeneratedTag == nil {
                Button("编辑智能文件夹", systemImage: "slider.horizontal.3") { editAction(smartFolder) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
        }
    }
}

private struct SectionInspector: View {
    let section: LibrarySection
    let count: Int

    private var description: String {
        switch section {
        case .all: "灵感库中的全部素材"
        case .uncategorized: "尚未放入文件夹的素材"
        case .untagged: "尚未添加标签的素材"
        case .recent: "最近打开过的素材"
        case .random: "以随机顺序浏览素材"
        case .community: "按 AI 标签自动整理的风格索引"
        case .tags: "按标签整理素材"
        case .trash: "已移到回收站的素材"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorReadOnlyField(text: section.title)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            InspectorReadOnlyField(text: description, secondary: true)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Divider().overlay(Color.eagleLine).padding(.horizontal, 16).padding(.vertical, 16)
            Text("基本信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.eagleSecondary)
                .padding(.horizontal, 16)
            InspectorInfo(label: "文件数", value: "\(count)")
            Spacer(minLength: 16)
        }
    }
}

private struct AIAssetChatView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject private var aiTagger = AITaggingService.shared
    @ObservedObject private var aiSettings = AISettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @State private var draft = ""
    @State private var confirmClear = false
    @FocusState private var composerFocused: Bool

    private var item: LibraryItem? { store.items.first { $0.id == itemID } }
    private var messages: [AIChatMessage] { item?.chatMessages ?? [] }
    private var isSending: Bool { aiTagger.chatState(for: itemID) == .running }
    private var canSend: Bool {
        item != nil && aiSettings.hasAPIKey && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.eagleLine)
            conversation
            Divider().overlay(Color.eagleLine)
            composer
        }
        .foregroundStyle(Color.eaglePrimary)
        .background(Color.eaglePanel)
        .preferredColorScheme(.dark)
        .confirmationDialog("清空这张素材的 AI 对话？", isPresented: $confirmClear) {
            Button("清空对话", role: .destructive) {
                store.clearAIChat(for: itemID)
                aiTagger.clearChatState(for: itemID)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("清空后无法恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let item {
                AssetImage(store: store, item: item, thumbnail: true)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("与 AI 对话").font(.system(size: 15, weight: .semibold))
                Text(item.map { "围绕“\($0.name)” · 每次发送自动附带原图" } ?? "素材不可用")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.eagleSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if !messages.isEmpty {
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.eagleSecondary)
                    .disabled(isSending)
                    .help("清空对话")
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty { emptyConversation }
                    ForEach(messages) { message in
                        AIChatBubble(message: message).id(message.id)
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在结合图片思考…")
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.eagleSecondary)
                        .padding(.horizontal, 4)
                        .id("ai-chat-loading")
                    }
                    if case .failure(let message) = aiTagger.chatState(for: itemID) {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: isSending) { _, sending in
                if sending { withAnimation { proxy.scrollTo("ai-chat-loading", anchor: .bottom) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.eagleMain)
    }

    private var emptyConversation: some View {
        VStack(spacing: 13) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("可以直接询问这张图片")
                .font(.system(size: 14, weight: .semibold))
            Text("AI 会自动看到原图，并把本次对话保存在素材库中。")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.eagleSecondary)
            HStack(spacing: 8) {
                suggestion("分析设计亮点")
                suggestion("给我改进建议")
                suggestion("提炼创作提示词")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 74)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) {
            draft = text
            composerFocused = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 10.5))
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !aiSettings.hasAPIKey {
                Label("请先在设置中填写 API Key，已有记录仍可查看。", systemImage: "key")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("问问这张图片…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 9))
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.eagleSecondary)
                        .frame(width: 34, height: 34)
                        .background(canSend ? Color.accentColor : Color.eagleField, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(14)
    }

    private func send() {
        guard canSend, let item else { return }
        let text = draft
        draft = ""
        Task { await aiTagger.sendChat(text, about: item, in: store) }
    }
}

private struct AIChatBubble: View {
    let message: AIChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "你" : "AI")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(message.role == .user ? Color.white.opacity(0.78) : Color.accentColor)
                if message.role == .assistant {
                    AIChatMarkdownText(source: message.content)
                } else {
                    Text(message.content)
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.82) : Color.eagleField,
                in: RoundedRectangle(cornerRadius: 10)
            )
            if message.role == .assistant { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AIChatMarkdownText: View {
    private enum Block: Identifiable {
        case paragraph(Int, String)
        case heading(Int, level: Int, text: String)
        case ordered(Int, number: String, text: String)
        case bullet(Int, String)
        case quote(Int, String)
        case code(Int, String)
        case spacer(Int)

        var id: Int {
            switch self {
            case .paragraph(let id, _), .bullet(let id, _), .quote(let id, _), .code(let id, _), .spacer(let id): id
            case .heading(let id, _, _), .ordered(let id, _, _): id
            }
        }
    }

    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.blocks(from: source)) { block in
                blockView(block)
            }
        }
        .font(.system(size: 12))
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(_, let text):
            inlineText(text)
        case .heading(_, let level, let text):
            inlineText(text)
                .font(.system(size: level == 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .bold))
                .padding(.top, 2)
        case .ordered(_, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(number + ".").fontWeight(.semibold).frame(minWidth: 16, alignment: .trailing)
                inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .bullet(_, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").fontWeight(.bold).frame(width: 10)
                inlineText(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote(_, let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.7)).frame(width: 3)
                inlineText(text).foregroundStyle(Color.eagleSecondary)
            }
        case .code(_, let text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
        case .spacer:
            Color.clear.frame(height: 3)
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }

    private static func blocks(from source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []
        var codeLines: [String] = []
        var inCode = false
        var id = 0

        func append(_ block: Block) {
            result.append(block)
            id += 1
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    append(.code(id, codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                if !(result.last.map { if case .spacer = $0 { true } else { false } } ?? false) {
                    append(.spacer(id))
                }
                continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 3, trimmed.dropFirst(hashes).first == " " {
                append(.heading(id, level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
                continue
            }
            if let ordered = orderedItem(trimmed) {
                append(.ordered(id, number: ordered.number, text: ordered.text))
                continue
            }
            if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) {
                append(.bullet(id, String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("> ") {
                append(.quote(id, String(trimmed.dropFirst(2))))
                continue
            }
            append(.paragraph(id, trimmed))
        }
        if inCode, !codeLines.isEmpty { append(.code(id, codeLines.joined(separator: "\n"))) }
        while result.last.map({ if case .spacer = $0 { true } else { false } }) == true { result.removeLast() }
        return result
    }

    private static func orderedItem(_ line: String) -> (number: String, text: String)? {
        guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let number = String(line[..<separator])
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let remainder = line[line.index(after: separator)...]
        guard remainder.first == " " else { return nil }
        return (number, remainder.trimmingCharacters(in: .whitespaces))
    }
}

private struct BatchInspector: View {
    @ObservedObject var store: LibraryStore
    let items: [LibraryItem]
    @State private var note = ""
    @State private var tag = ""
    @State private var confirmPermanentDelete = false

    private var ids: Set<UUID> { Set(items.map(\.id)) }
    private var totalSize: Int64 { items.reduce(0) { $0 + $1.fileSize } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    AssetImage(store: store, item: item, thumbnail: true)
                        .frame(width: 112, height: 150).clipShape(RoundedRectangle(cornerRadius: 5))
                        .rotationEffect(.degrees(Double(index - 1) * 4))
                        .offset(x: CGFloat(index - 1) * 8, y: CGFloat(index) * 2)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 175)
            Text("已选 \(items.count) 个文件")
                .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.bottom, 14)

            HStack(spacing: 6) {
                InspectorTextField(placeholder: "添加注释", text: $note)
                Button("应用") { applyNote() }.buttonStyle(.borderless)
            }.padding(.horizontal, 16)

            Divider().overlay(Color.eagleLine).padding(16)
            Text("标签").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            HStack {
                TextField("添加标签", text: $tag).textFieldStyle(.plain).onSubmit(applyTag)
                Button(action: applyTag) { Image(systemName: "plus") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 9).frame(height: 30).background(Color.eagleField)
            .clipShape(RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 16).padding(.top, 8)

            Divider().overlay(Color.eagleLine).padding(16)
            Text("风格文件夹").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary).padding(.horizontal, 16)
            Menu("移动 \(items.count) 个文件") {
                Button("未分类") { store.update(ids) { $0.folder = ""; $0.isTrashed = false } }
                Divider()
                ForEach(store.folders, id: \.self) { folder in
                    Button(folder) { store.update(ids) { $0.folder = folder; $0.isTrashed = false } }
                }
            }.menuStyle(.borderlessButton).padding(.horizontal, 16).padding(.top, 8)

            Divider().overlay(Color.eagleLine).padding(16)
            HStack {
                Text("评分").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65)); Spacer()
                ForEach(1...5, id: \.self) { value in
                    Button { store.update(ids) { $0.rating = value } } label: {
                        Image(systemName: "star").foregroundStyle(Color.eagleSecondary)
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
            InspectorInfo(label: "文件大小", value: ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))

            Button { store.reveal(items) } label: {
                Label("在 Finder 中显示", systemImage: "folder")
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(Color.eagleSelection).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).padding(16)

            if items.allSatisfy(\.isTrashed) {
                HStack(spacing: 8) {
                    Button("全部恢复", systemImage: "arrow.uturn.backward") {
                        store.update(ids) { $0.isTrashed = false }
                    }
                    Button("永久删除", systemImage: "trash", role: .destructive) {
                        confirmPermanentDelete = true
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            } else {
                Button("移到回收站", systemImage: "trash", role: .destructive) {
                    store.update(ids) { $0.isTrashed = true }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .confirmationDialog("永久删除 \(items.count) 个文件？", isPresented: $confirmPermanentDelete) {
            Button("永久删除", role: .destructive) { store.permanentlyDelete(ids) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    private func applyNote() {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.update(ids) { $0.note = value }; note = ""
    }

    private func applyTag() {
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.update(ids) { if !$0.tags.contains(value) { $0.tags.append(value) } }; tag = ""
    }
}

private struct InspectorTextField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 11).frame(height: 34).background(Color.eagleField)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct InspectorReadOnlyField: View {
    let text: String
    var secondary = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: secondary ? .regular : .medium))
            .foregroundStyle(secondary ? Color.eagleSecondary : Color.eaglePrimary)
            .lineLimit(secondary ? 2 : 1)
            .frame(maxWidth: .infinity, minHeight: secondary ? 48 : 34, alignment: .leading)
            .padding(.horizontal, 11)
            .background(Color.eagleField)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct InspectorInfo: View {
    let label: String
    let value: String
    var body: some View {
        HStack { Text(label).foregroundStyle(Color.white.opacity(0.65)); Spacer(); Text(value).foregroundStyle(Color.eagleSecondary).lineLimit(1) }
            .font(.system(size: 11)).padding(.horizontal, 16).padding(.top, 8)
    }
}

private struct RatingRow: View {
    @ObservedObject var store: LibraryStore
    let item: LibraryItem
    var body: some View {
        HStack {
            Text("评分").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65)); Spacer()
            ForEach(1...5, id: \.self) { value in
                Button { store.update(item.id) { $0.rating = $0.rating == value ? 0 : value } } label: {
                    Image(systemName: value <= item.rating ? "star.fill" : "star").foregroundStyle(value <= item.rating ? .yellow : Color.eagleSecondary)
                }.buttonStyle(.plain)
            }
        }
    }
}

private struct PhotoPaletteDots: View {
    let palette: [AssetPaletteColor]

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if palette.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 16)
                    .help("正在提取图片主色")
            } else {
                ForEach(Array(palette.prefix(8))) { swatch in
                    Button { copy(swatch) } label: {
                        Circle()
                            .fill(swatch.swiftUIColor)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("点击复制 \(swatch.hexString) · 占比 \(swatch.displayPercentage)%")
                }
            }
            Spacer()
        }
    }

    private func copy(_ swatch: AssetPaletteColor) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(swatch.hexString, forType: .string)
    }
}

private struct TagEditor: View {
    @ObservedObject var store: LibraryStore
    let item: LibraryItem
    @Binding var draft: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FlowTags(tags: item.tags) { tag in store.update(item.id) { $0.tags.removeAll { $0 == tag } } }
            HStack {
                TextField("添加标签", text: $draft).textFieldStyle(.plain).onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 9).frame(height: 30).background(Color.eagleField).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    private func add() {
        let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !item.tags.contains(tag) else { return }
        store.update(item.id) { $0.tags.append(tag) }; draft = ""
    }
}

private struct FlowTags: View {
    let tags: [String]
    let remove: (String) -> Void
    var body: some View {
        if !tags.isEmpty {
            WrappingTagLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag).fixedSize(horizontal: false, vertical: true)
                        Button { remove(tag) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                        .font(.system(size: 10)).padding(.horizontal, 7).frame(minHeight: 23)
                        .background(Color.eagleSelection).clipShape(Capsule())
                }
            }
        }
    }
}

private struct MachineTagCloud: View {
    let tags: [String]
    let selectAction: (String) -> Void
    let createSmartFolderAction: (String) -> Void
    let addToStyleLibraryAction: (String) -> Void

    var body: some View {
        WrappingTagLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button { selectAction(tag) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle").font(.system(size: 8, weight: .semibold))
                        Text(tag).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.purple.opacity(0.95))
                    .padding(.horizontal, 7)
                    .frame(minHeight: 23)
                    .background(Color.purple.opacity(0.12))
                    .overlay(Capsule().stroke(Color.purple.opacity(0.25), lineWidth: 1))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("浏览使用“\(tag)”标签的图片")
                .contextMenu {
                    Button {
                        createSmartFolderAction(tag)
                    } label: {
                        Label("创建智能文件夹", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        addToStyleLibraryAction(tag)
                    } label: {
                        Label("添加到风格库", systemImage: "square.stack.3d.up")
                    }
                }
            }
        }
    }
}

private struct WrappingTagLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = max(proposal.width ?? .infinity, 1)
        let rows = rows(for: subviews, availableWidth: availableWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let contentHeight = rows.reduce(0) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(
            width: proposal.width ?? contentWidth,
            height: contentHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: subviews, availableWidth: max(bounds.width, 1))
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(element.size)
                )
                x += element.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var elements: [Element] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let naturalSize = subview.sizeThatFits(.unspecified)
            let size = naturalSize.width > availableWidth
                ? subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
                : naturalSize
            let proposedWidth = elements.isEmpty ? size.width : rowWidth + horizontalSpacing + size.width
            if !elements.isEmpty, proposedWidth > availableWidth {
                rows.append(Row(elements: elements, width: rowWidth, height: rowHeight))
                elements = []
                rowWidth = 0
                rowHeight = 0
            }
            elements.append(Element(subview: subview, size: size))
            rowWidth = elements.count == 1 ? size.width : rowWidth + horizontalSpacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
        if !elements.isEmpty {
            rows.append(Row(elements: elements, width: rowWidth, height: rowHeight))
        }
        return rows
    }

    private struct Element {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let elements: [Element]
        let width: CGFloat
        let height: CGFloat
    }
}

private struct AISettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case preview = "图片预览"
        case trash = "回收站"
        case ai = "AI 素材识别"
        case cloud = "iCloud 同步"
        case duplicates = "重复素材"
        case guide = "新手教程"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .preview: "photo.on.rectangle.angled"
            case .trash: "trash"
            case .ai: "sparkles"
            case .cloud: "icloud"
            case .duplicates: "doc.on.doc"
            case .guide: "book"
            }
        }
        var detail: String {
            switch self {
            case .preview: "缩放与滚轮"
            case .trash: "自动清理"
            case .ai: "模型与标签"
            case .cloud: "多台 Mac 共享"
            case .duplicates: "监测与合并"
            case .guide: "入门与连接 AI"
            }
        }
    }

    @ObservedObject private var settings = AISettingsStore.shared
    @ObservedObject private var aiTagger = AITaggingService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPane: Pane = .preview
    @State private var showTutorial = false
    @ObservedObject private var library = LibraryStore.shared
    @State private var endpoint: String
    @State private var model: String
    @State private var apiKey: String
    @State private var prompt: String
    @State private var maximumTags: Int
    @State private var automaticTaggingEnabled: Bool
    @State private var trashRetentionDays: Int
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isTesting = false
    @AppStorage("EagleReplica.preview.scrollBehavior") private var previewScrollBehavior = PreviewScrollBehavior.zoom.rawValue

    init() {
        let settings = AISettingsStore.shared
        _endpoint = State(initialValue: settings.configuration.endpoint)
        _model = State(initialValue: settings.configuration.model)
        _apiKey = State(initialValue: settings.apiKey())
        _prompt = State(initialValue: settings.configuration.prompt)
        _maximumTags = State(initialValue: settings.configuration.maximumTags)
        _automaticTaggingEnabled = State(initialValue: settings.automaticTaggingEnabled)
        let storedTrashDays = UserDefaults.standard.object(forKey: TrashRetentionPolicy.defaultsKey) as? Int
        _trashRetentionDays = State(initialValue: TrashRetentionPolicy.normalizedDays(
            storedTrashDays ?? TrashRetentionPolicy.defaultDays
        ))
    }

    private var draft: AIModelConfiguration {
        AIModelConfiguration(endpoint: endpoint, model: model, prompt: prompt, maximumTags: maximumTags)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置").font(.system(size: 17, weight: .semibold))
                    Text(selectedPane.rawValue).font(.system(size: 11)).foregroundStyle(Color.eagleSecondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 72)

            Divider().overlay(Color.eagleLine)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置项目")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.eagleSecondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 5)
                    ForEach(Pane.allCases) { pane in
                        Button { selectedPane = pane } label: {
                            HStack(spacing: 10) {
                                Image(systemName: pane.icon)
                                    .font(.system(size: 14))
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pane.rawValue).font(.system(size: 12.5, weight: .medium))
                                    Text(pane.detail).font(.system(size: 9.5)).foregroundStyle(Color.eagleSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Color.eaglePrimary)
                            .padding(.horizontal, 11)
                            .frame(height: 48)
                            .background(selectedPane == pane ? Color.eagleSelection : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 188)
                .background(Color.black.opacity(0.10))

                Divider().overlay(Color.eagleLine)

                Group {
                    switch selectedPane {
                    case .preview: previewSettings
                    case .trash: trashSettings
                    case .ai: aiSettings
                    case .cloud: LibraryCloudSettingsView()
                    case .duplicates: duplicateSettings
                    case .guide:
                        VStack(alignment: .leading, spacing: 16) {
                            Text("新手教程").font(.title2)
                            Text("从导入、采集和整理，到多台 Mac 同步；最后引导填写 API Key。")
                                .foregroundStyle(Color.eagleSecondary)
                            Button("重新打开新手教程") { showTutorial = true }.buttonStyle(.borderedProminent)
                            Spacer()
                        }.padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().overlay(Color.eagleLine)
            HStack {
                Button("恢复默认", action: restoreDefaults)
                .buttonStyle(.plain)
                .foregroundStyle(Color.eagleSecondary)
                Spacer()
                if selectedPane == .ai {
                    Button {
                        testConnection()
                    } label: {
                        if isTesting { ProgressView().controlSize(.small) } else { Text("测试连接") }
                    }
                    .disabled(isTesting)
                }
                Button("保存") { saveAndDismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
        }
        .foregroundStyle(Color.eaglePrimary)
        .background(Color.eaglePanel)
        .sheet(isPresented: $showTutorial) { OnboardingView { showTutorial = false } }
    }

    private var duplicateSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重复素材监测").font(.title2)
            Text("普通导入、网页采集、合并资源库和 iCloud 同步都会检查完全重复的文件。每次打开资源库也会补查存量素材。")
            Text("按文件内容检查，不按文件名判断。合并时保留标签、AI 对话及文件夹归属；视觉相似的图片由你确认。")
                .foregroundStyle(Color.eagleSecondary)
            Text(library.duplicateStatus).font(.callout)
            Button("立即检查完全重复的素材") { library.checkExactDuplicates() }
                .buttonStyle(.borderedProminent)
            Text("要对比相似图片，可在主界面左上角 ＋ → 扫描重复文件中选择相似模式。")
                .font(.caption).foregroundStyle(Color.eagleSecondary)
            Spacer()
        }.padding(24)
    }

    private var previewSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("预览滚轮行为").font(.system(size: 15, weight: .semibold))
                Text("鼠标滚轮执行的操作；触控板始终为滑动平移、捏合缩放")
                    .font(.system(size: 10.5)).foregroundStyle(Color.eagleSecondary)
                HStack(spacing: 9) {
                    ForEach(PreviewScrollBehavior.allCases) { behavior in
                        Button { previewScrollBehavior = behavior.rawValue } label: {
                            VStack(spacing: 9) {
                                Image(systemName: behavior.icon).font(.system(size: 25)).frame(height: 30)
                                Text(behavior.rawValue).font(.system(size: 11.5, weight: .semibold))
                                Text(behavior.detail)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.eagleSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .foregroundStyle(Color.eaglePrimary)
                            .frame(maxWidth: .infinity, minHeight: 132)
                            .padding(.horizontal, 6)
                            .background(previewScrollBehavior == behavior.rawValue ? Color.accentColor.opacity(0.13) : Color.eagleField, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(previewScrollBehavior == behavior.rawValue ? Color.accentColor : Color.eagleLine, lineWidth: previewScrollBehavior == behavior.rawValue ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "viewfinder")
                    Text("放大图片时，内容会被限制在中央预览画布内，不会遮挡工具栏和两侧信息栏。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Color.eagleSecondary)
                .padding(.top, 5)
            }
            .padding(24)
        }
    }

    private var aiSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI 素材识别").font(.system(size: 15, weight: .semibold))
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动标记未处理图片").font(.system(size: 12.5, weight: .medium))
                        Text("启动时扫描存量素材；新图片入库后自动加入单任务队列。只处理从未完成 AI 标记的图片。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.eagleSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $automaticTaggingEnabled).labelsHidden()
                }
                .padding(12)
                .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 8))
                if aiTagger.automaticIsRunning || aiTagger.automaticPendingCount > 0 {
                    Label(
                        "正在自动标记，队列剩余 \(aiTagger.automaticPendingCount) 张",
                        systemImage: "sparkles"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.accentColor)
                } else if let pauseMessage = aiTagger.automaticPauseMessage {
                    Label(pauseMessage, systemImage: "pause.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.eagleSecondary)
                }
                settingsField("API 接口", hint: "OpenAI 兼容的 Chat Completions 地址") {
                    TextField("https://api.deepseek.com/chat/completions", text: $endpoint).textFieldStyle(.plain)
                }
                settingsField("模型名称", hint: "已按你的视觉模型名称预填，可随时修改") {
                    TextField(AISettingsStore.defaultModel, text: $model).textFieldStyle(.plain)
                }
                settingsField("API Key", hint: "仅保存在这台 Mac 的系统钥匙串中") {
                    SecureField("sk-…", text: $apiKey).textFieldStyle(.plain)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("每张图片标签数").font(.system(size: 12, weight: .medium))
                        Text("建议 6–10 个，兼顾检索和准确性").font(.system(size: 10.5)).foregroundStyle(Color.eagleSecondary)
                    }
                    Spacer()
                    Stepper("\(maximumTags) 个", value: $maximumTags, in: 3...16).labelsHidden()
                    Text("\(maximumTags) 个").font(.system(size: 12)).frame(width: 38, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("标签提示词").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $prompt)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(9)
                        .frame(height: 92)
                        .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 7))
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("这里保留你指定的 vision 模型名和可编辑接口，方便接入支持图片输入的兼容服务。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 10.5)).foregroundStyle(Color.eagleSecondary)
                if !statusMessage.isEmpty {
                    Label(statusMessage, systemImage: statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(statusIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
    }

    private var trashSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("回收站自动清理").font(.system(size: 15, weight: .semibold))
                Text("素材进入回收站后会开始倒计时，到期后永久删除原文件与缩略图。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.eagleSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动删除时间").font(.system(size: 12.5, weight: .medium))
                        Text("可设置 1–365 天，默认 30 天")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.eagleSecondary)
                    }
                    Spacer()
                    Stepper("", value: $trashRetentionDays, in: TrashRetentionPolicy.allowedDays)
                        .labelsHidden()
                    Text("\(trashRetentionDays) 天")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 54, alignment: .trailing)
                }
                .padding(14)
                .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 9))

                Label(
                    "缩短时间后，已经超过新期限的素材会在保存设置时立即永久删除。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private func restoreDefaults() {
        switch selectedPane {
        case .preview:
            previewScrollBehavior = PreviewScrollBehavior.zoom.rawValue
        case .trash:
            trashRetentionDays = TrashRetentionPolicy.defaultDays
        case .ai:
            endpoint = "https://api.deepseek.com/chat/completions"
            model = AISettingsStore.defaultModel
            prompt = AISettingsStore.defaultPrompt
            maximumTags = 8
            automaticTaggingEnabled = true
        case .cloud, .duplicates, .guide:
            break
        }
    }

    private func settingsField<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            content()
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 7))
            Text(hint).font(.system(size: 10)).foregroundStyle(Color.eagleSecondary)
        }
    }

    private func saveAndDismiss() {
        do {
            let normalizedTrashDays = TrashRetentionPolicy.normalizedDays(trashRetentionDays)
            UserDefaults.standard.set(normalizedTrashDays, forKey: TrashRetentionPolicy.defaultsKey)
            LibraryStore.shared.purgeExpiredTrash(retentionDays: normalizedTrashDays)
            try settings.save(
                configuration: draft,
                apiKey: apiKey,
                automaticTaggingEnabled: automaticTaggingEnabled
            )
            dismiss()
        } catch {
            statusIsError = true
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func testConnection() {
        isTesting = true
        statusMessage = ""
        Task {
            do {
                statusMessage = try await settings.testConnection(configuration: draft, apiKey: apiKey)
                statusIsError = false
            } catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                statusIsError = true
            }
            isTesting = false
        }
    }
}

extension UTType {
    static let eagleLibraryItem = UTType(exportedAs: "com.mooyumm.InspirationLibrary.asset-id")
    static let eagleFolderOrder = UTType(exportedAs: "com.mooyumm.InspirationLibrary.folder-order")
}

struct AssetTransfer: Transferable {
    let itemID: UUID?
    let fileURL: URL?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(
            contentType: .eagleLibraryItem,
            exporting: { transfer in
                guard let itemID = transfer.itemID,
                      let data = itemID.uuidString.data(using: .utf8) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return data
            },
            importing: { data in
                guard let rawID = String(data: data, encoding: .utf8),
                      let itemID = UUID(uuidString: rawID) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return AssetTransfer(itemID: itemID, fileURL: nil)
            }
        )
        FileRepresentation(
            contentType: .image,
            shouldAttemptToOpenInPlace: true,
            exporting: { transfer in
                guard let fileURL = transfer.fileURL else { throw CocoaError(.fileNoSuchFile) }
                return SentTransferredFile(fileURL, allowAccessingOriginalFile: true)
            },
            importing: { received in
                AssetTransfer(itemID: nil, fileURL: received.file)
            }
        )
    }
}

private struct AssetCardDragModifier: ViewModifier {
    @ObservedObject var store: LibraryStore
    let item: LibraryItem

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fileURL = store.imageURL(for: item) {
            content.draggable(AssetTransfer(itemID: item.id, fileURL: fileURL)) {
                AssetImage(store: store, item: item, thumbnail: true)
                    .frame(width: 92, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
            }
        } else {
            content
        }
    }
}

enum FolderOrderDragProvider {
    static func provider(for folder: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = folder
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.eagleFolderOrder.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(folder.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

enum AssetDragProvider {
    @MainActor
    static func provider(for item: LibraryItem, store: LibraryStore) -> NSItemProvider {
        guard let fileURL = store.imageURL(for: item) else {
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        let provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
        provider.suggestedName = suggestedFilename(for: item, fileURL: fileURL)
        let fileType = UTType(filenameExtension: fileURL.pathExtension)?.identifier ?? UTType.image.identifier
        provider.registerFileRepresentation(forTypeIdentifier: fileType, fileOptions: [.openInPlace], visibility: .all) { completion in
            completion(fileURL, true, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.eagleLibraryItem.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(item.id.uuidString.data(using: .utf8), nil)
            return nil
        }
        provider.registerObject(item.id.uuidString as NSString, visibility: .ownProcess)
        return provider
    }

    static func suggestedFilename(for item: LibraryItem, fileURL: URL) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let safeName = item.name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = safeName.isEmpty ? "图片" : safeName
        let ext = fileURL.pathExtension.isEmpty ? item.format.lowercased() : fileURL.pathExtension.lowercased()
        return ext.isEmpty || base.lowercased().hasSuffix(".\(ext)") ? base : "\(base).\(ext)"
    }
}

private struct EaglePreviewWorkspace: View {
    @ObservedObject var store: LibraryStore
    @Binding var itemID: UUID?
    let items: [LibraryItem]
    let closeAction: () -> Void
    let selectionAction: (UUID) -> Void
    @AppStorage("EagleReplica.preview.scrollBehavior") private var scrollBehaviorRaw = PreviewScrollBehavior.zoom.rawValue
    @State private var zoom = 1.0
    @State private var accumulatedWheel = 0.0
    @State private var lastWheelNavigation = Date.distantPast
    @State private var transitionEdge: Edge = .trailing
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize?
    @State private var magnificationStartZoom: Double?
    @State private var viewportSize: CGSize = .zero

    private var item: LibraryItem? { itemID.flatMap { id in store.items.first { $0.id == id } } }
    private var index: Int { itemID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0 }
    private var scrollBehavior: PreviewScrollBehavior { PreviewScrollBehavior(rawValue: scrollBehaviorRaw) ?? .zoom }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: closeAction) { Image(systemName: "chevron.left") }
                    .help("返回素材列表")
                Text("\(min(index + 1, items.count)) / \(items.count)").font(.system(size: 12))
                Spacer()
                Button { zoom = max(0.2, zoom - 0.1) } label: { Image(systemName: "minus") }
                Slider(value: $zoom, in: 0.2...4).frame(width: 150)
                Button { zoom = min(4, zoom + 0.1) } label: { Image(systemName: "plus") }
                Text("\(Int(zoom * 100))%").font(.system(size: 11)).frame(width: 40)
                Spacer()
                Label("滑动平移 · 捏合缩放", systemImage: "hand.draw")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.eagleSecondary)
                Button { previous(edge: .leading) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                Button { next(edge: .trailing) } label: { Image(systemName: "chevron.right") }.disabled(index + 1 >= items.count)
            }
            .buttonStyle(IconButtonStyle()).foregroundStyle(Color.eaglePrimary).padding(.horizontal, 18).frame(height: 52)
            Divider().overlay(Color.eagleLine)
            GeometryReader { geometry in
                if let item {
                    ZStack {
                        Color.eagleMain
                        AssetImage(store: store, item: item, contentMode: .fit)
                            .frame(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 48))
                            .scaleEffect(zoom)
                            .offset(panOffset)
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: transitionEdge).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .animation(.easeOut(duration: 0.18), value: item.id)
                            .padding(24)
                        ScrollWheelReader { deltaX, deltaY, precise in
                            handleWheel(deltaX: deltaX, deltaY: deltaY, precise: precise)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(panGesture(for: item, viewport: geometry.size))
                    .simultaneousGesture(magnificationGesture)
                    .onTapGesture(count: 2, perform: resetView)
                    .onAppear { viewportSize = geometry.size }
                    .onChange(of: geometry.size) { _, newSize in
                        viewportSize = newSize
                        panOffset = PreviewPanMath.clampedOffset(
                            panOffset,
                            imageSize: CGSize(width: item.width, height: item.height),
                            viewportSize: newSize,
                            zoom: zoom
                        )
                    }
                    .clipped()
                } else {
                    ContentUnavailableView("素材不可用", systemImage: "photo.badge.exclamationmark")
                }
            }
            .clipped()
        }
        .background(Color.eagleMain).preferredColorScheme(.dark)
        .clipped()
        .onAppear {
            if let itemID { store.markOpened(itemID); selectionAction(itemID) }
        }
        .onChange(of: itemID) { _, newID in
            guard let newID else { return }
            resetView()
            store.markOpened(newID)
            selectionAction(newID)
        }
        .onChange(of: zoom) { _, _ in constrainPan() }
        .onExitCommand(perform: closeAction)
        .onMoveCommand { direction in
            if direction == .left { previous(edge: .leading) }
            if direction == .right { next(edge: .trailing) }
        }
    }

    private func panGesture(for item: LibraryItem, viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if dragStartOffset == nil { dragStartOffset = panOffset }
                let origin = dragStartOffset ?? panOffset
                let proposed = CGSize(
                    width: origin.width + value.translation.width,
                    height: origin.height + value.translation.height
                )
                panOffset = PreviewPanMath.clampedOffset(
                    proposed,
                    imageSize: CGSize(width: item.width, height: item.height),
                    viewportSize: viewport,
                    zoom: zoom
                )
            }
            .onEnded { _ in dragStartOffset = nil }
    }

    private func resetView() {
        zoom = 1
        panOffset = .zero
        dragStartOffset = nil
        magnificationStartZoom = nil
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                if magnificationStartZoom == nil { magnificationStartZoom = zoom }
                zoom = PreviewGestureMath.zoom(
                    from: magnificationStartZoom ?? zoom,
                    magnification: Double(magnification)
                )
            }
            .onEnded { _ in magnificationStartZoom = nil }
    }

    private func constrainPan() {
        guard let item else { panOffset = .zero; return }
        panOffset = PreviewPanMath.clampedOffset(
            panOffset,
            imageSize: CGSize(width: item.width, height: item.height),
            viewportSize: viewportSize,
            zoom: zoom
        )
    }

    private func handleWheel(deltaX: Double, deltaY: Double, precise: Bool) {
        if precise {
            guard let item else { return }
            panOffset = PreviewPanMath.clampedOffset(
                PreviewGestureMath.scrolledOffset(from: panOffset, deltaX: deltaX, deltaY: deltaY),
                imageSize: CGSize(width: item.width, height: item.height),
                viewportSize: viewportSize,
                zoom: zoom
            )
            return
        }
        switch scrollBehavior {
        case .zoom:
            let delta = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
            zoom = min(4, max(0.2, zoom + delta * 0.012))
        case .vertical, .paging:
            let delta = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
            accumulatedWheel += delta
            let now = Date()
            guard abs(accumulatedWheel) >= 18, now.timeIntervalSince(lastWheelNavigation) >= 0.28 else { return }
            lastWheelNavigation = now
            if accumulatedWheel > 0 {
                previous(edge: scrollBehavior == .vertical ? .top : .leading)
            } else {
                next(edge: scrollBehavior == .vertical ? .bottom : .trailing)
            }
            accumulatedWheel = 0
        }
    }

    private func previous(edge: Edge) {
        guard index > 0 else { return }
        transitionEdge = edge
        itemID = items[index - 1].id
    }

    private func next(edge: Edge) {
        guard index + 1 < items.count else { return }
        transitionEdge = edge
        itemID = items[index + 1].id
    }
}

enum PreviewPresentationPolicy {
    static func shouldCloseOnWindowResign(hasPreview: Bool) -> Bool { hasPreview }
}

enum PreviewGestureMath {
    static func zoom(from startZoom: Double, magnification: Double) -> Double {
        min(4, max(0.2, startZoom * magnification))
    }

    static func scrolledOffset(from current: CGSize, deltaX: Double, deltaY: Double) -> CGSize {
        CGSize(width: current.width + deltaX, height: current.height + deltaY)
    }
}

enum PreviewPanMath {
    static func clampedOffset(
        _ proposed: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize,
        zoom: Double,
        inset: CGFloat = 24
    ) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let available = CGSize(
            width: max(1, viewportSize.width - inset * 2),
            height: max(1, viewportSize.height - inset * 2)
        )
        let fitScale = min(available.width / imageSize.width, available.height / imageSize.height)
        let scaledWidth = imageSize.width * fitScale * CGFloat(zoom)
        let scaledHeight = imageSize.height * fitScale * CGFloat(zoom)
        let maximumX = max(0, (scaledWidth - viewportSize.width) / 2)
        let maximumY = max(0, (scaledHeight - viewportSize.height) / 2)
        return CGSize(
            width: min(maximumX, max(-maximumX, proposed.width)),
            height: min(maximumY, max(-maximumY, proposed.height))
        )
    }
}

private struct ScrollWheelReader: NSViewRepresentable {
    let action: (Double, Double, Bool) -> Void

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) { nsView.action = action }
}

private final class ScrollWheelCaptureView: NSView {
    var action: ((Double, Double, Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) {
        action?(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
    }
}

private struct SmartFolderEditor: View {
    @ObservedObject var store: LibraryStore
    @State private var draft: SmartFolder
    let save: (SmartFolder) -> Void
    @Environment(\.dismiss) private var dismiss

    init(store: LibraryStore, smartFolder: SmartFolder, save: @escaping (SmartFolder) -> Void) {
        self.store = store
        _draft = State(initialValue: smartFolder)
        self.save = save
    }

    private var matchCount: Int { store.items.filter { !$0.isTrashed && draft.matches($0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("智能文件夹").font(.system(size: 15, weight: .semibold)); Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.padding(.horizontal, 18).frame(height: 50)
            Divider().overlay(Color.eagleLine)

            VStack(alignment: .leading, spacing: 14) {
                Text("智能文件夹名称").font(.system(size: 12)).foregroundStyle(Color.eagleSecondary)
                InspectorTextField(placeholder: "名称", text: $draft.name)
                HStack(spacing: 8) {
                    Text("符合").foregroundStyle(Color.eagleSecondary)
                    Picker("", selection: $draft.matchMode) {
                        ForEach(SmartMatchMode.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 92)
                    Text("条件时自动显示在此文件夹").foregroundStyle(Color.eagleSecondary)
                    Spacer()
                }.font(.system(size: 12))

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($draft.rules) { $rule in
                            HStack(spacing: 8) {
                                Picker("字段", selection: $rule.field) {
                                    ForEach(SmartRuleField.allCases) { Text($0.rawValue).tag($0) }
                                }.frame(width: 130)
                                .onChange(of: rule.field) { _, field in
                                    rule.operation = SmartRuleOperator.choices(for: field).first ?? .equals
                                }
                                Picker("条件", selection: $rule.operation) {
                                    ForEach(SmartRuleOperator.choices(for: rule.field)) { Text($0.rawValue).tag($0) }
                                }.frame(width: 130)
                                if rule.operation != .isEmpty && rule.operation != .isNotEmpty {
                                    TextField(rule.field.isDate ? "ISO 日期，如 2026-08-27T00:00:00Z" : "值", text: $rule.value)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    Spacer()
                                }
                                Button(role: .destructive) {
                                    if draft.rules.count > 1 { draft.rules.removeAll { $0.id == rule.id } }
                                } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.frame(minHeight: 160, maxHeight: 280)

                HStack {
                    Button("添加条件", systemImage: "plus") { draft.rules.append(SmartFolderRule()) }
                    Spacer()
                    Text("找到 \(matchCount) 个符合规则的文件").font(.system(size: 11)).foregroundStyle(Color.eagleSecondary)
                }
            }.padding(18)

            Divider().overlay(Color.eagleLine)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存智能文件夹") { save(draft); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
        }
        .frame(width: 720, height: 470).background(Color.eaglePanel).preferredColorScheme(.dark)
    }
}

private enum DuplicateScope: String, CaseIterable, Identifiable {
    case all = "扫描全部"
    case current = "扫描当前列表"
    case selected = "扫描已选项目"
    var id: String { rawValue }
}

private struct DuplicateScannerView: View {
    @ObservedObject var store: LibraryStore
    let currentItems: [LibraryItem]
    let selectedIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var mode: DuplicateScanMode = .exact
    @State private var scope: DuplicateScope = .all
    @State private var groups: [DuplicateGroup] = []
    @State private var didScan = false
    private let startedFromAutomaticPrompt: Bool

    init(
        store: LibraryStore,
        currentItems: [LibraryItem],
        selectedIDs: Set<UUID>,
        initialGroups: [DuplicateGroup] = [],
        initialMode: DuplicateScanMode = .exact
    ) {
        self.store = store
        self.currentItems = currentItems
        self.selectedIDs = selectedIDs
        _mode = State(initialValue: initialMode)
        _groups = State(initialValue: initialGroups)
        _didScan = State(initialValue: !initialGroups.isEmpty)
        startedFromAutomaticPrompt = !initialGroups.isEmpty
    }

    private var candidates: [LibraryItem] {
        switch scope {
        case .all: store.items.filter { !$0.isTrashed }
        case .current: currentItems
        case .selected: store.items.filter { selectedIDs.contains($0.id) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(startedFromAutomaticPrompt ? "重复添加提示" : "扫描重复文件")
                    .font(.system(size: 15, weight: .semibold)); Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.padding(.horizontal, 18).frame(height: 50)
            Divider().overlay(Color.eagleLine)

            HStack(spacing: 16) {
                Picker("扫描方式", selection: $mode) {
                    ForEach(DuplicateScanMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 280)
                Picker("范围", selection: $scope) {
                    ForEach(DuplicateScope.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 170)
                Spacer()
                Text("\(candidates.count) 个文件").font(.system(size: 11)).foregroundStyle(Color.eagleSecondary)
                Button("开始扫描", systemImage: "doc.on.doc") { scan() }.buttonStyle(.borderedProminent)
            }.padding(16)
            Divider().overlay(Color.eagleLine)

            if groups.isEmpty {
                ContentUnavailableView(
                    didScan ? "没有发现重复项" : (mode == .exact ? "扫描完全相同的文件" : "扫描视觉相似的图像"),
                    systemImage: mode == .exact ? "doc.on.doc" : "photo.stack",
                    description: Text(didScan ? "当前范围内的素材没有形成重复组" : "相同文件按 SHA-256 检测；相似图像使用感知哈希比较")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            if startedFromAutomaticPrompt, let existing = group.items.first {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("重复组 · \(group.items.count) 个文件")
                                        .font(.system(size: 12, weight: .semibold))
                                    HStack(alignment: .top, spacing: 28) {
                                        duplicateComparisonCard(item: existing, badge: "已存在", emphasized: true)
                                        if let incoming = group.items.dropFirst().first {
                                            duplicateComparisonCard(item: incoming, badge: "重复文件", emphasized: false)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .padding(16).background(Color.eagleField).clipShape(RoundedRectangle(cornerRadius: 9))
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Text("重复组 · \(group.items.count) 个文件").font(.system(size: 12, weight: .semibold)); Spacer() }
                                    ScrollView(.horizontal) {
                                        HStack(spacing: 10) {
                                            ForEach(group.items) { item in
                                                VStack(spacing: 5) {
                                                    AssetImage(store: store, item: item, thumbnail: true)
                                                        .frame(width: 100, height: 118).clipShape(RoundedRectangle(cornerRadius: 5))
                                                    Text(item.name).font(.system(size: 10)).lineLimit(1).frame(width: 100)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(12).background(Color.eagleField).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.padding(16)
                }
                Divider().overlay(Color.eagleLine)
                HStack {
                    Text("共发现 \(groups.count) 组").font(.system(size: 11)).foregroundStyle(Color.eagleSecondary)
                    Spacer()
                    if startedFromAutomaticPrompt {
                        Button("保留全部") { dismiss() }
                        Button("使用已有文件合并") {
                            _ = store.mergeConfirmedDuplicateGroups(groups)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("每组保留第一项，其余移到回收站", role: .destructive) { cleanDuplicates() }
                    }
                }.padding(16)
            }
        }
        .background(Color.eagleMain).preferredColorScheme(.dark)
        .onChange(of: mode) { _, _ in groups = []; didScan = false }
        .onChange(of: scope) { _, _ in groups = []; didScan = false }
    }

    private func scan() {
        groups = DuplicateScanner.scan(candidates, mode: mode, store: store)
        didScan = true
    }

    private func duplicateComparisonCard(item: LibraryItem, badge: String, emphasized: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                AssetImage(store: store, item: item, thumbnail: true)
                    .frame(width: 250, height: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(badge)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(emphasized ? Color.black.opacity(0.68) : Color.accentColor.opacity(0.72), in: Capsule())
            }
            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 250)
            Text("\(item.dimensions) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                .font(.system(size: 10)).foregroundStyle(Color.eagleSecondary)
            Text(item.folder.isEmpty ? "未分类" : item.folder)
                .font(.system(size: 10)).padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(Color.white.opacity(0.18)))
        }
    }

    private func cleanDuplicates() {
        let duplicateIDs = Set(groups.flatMap { $0.items.dropFirst().map(\.id) })
        store.update(duplicateIDs) { $0.isTrashed = true }
        scan()
    }
}

enum PanelResizeMath {
    static func width(
        from startWidth: Double,
        translation: CGFloat,
        reversed: Bool,
        range: ClosedRange<Double>
    ) -> Double {
        let delta = Double(translation) * (reversed ? -1 : 1)
        return min(range.upperBound, max(range.lowerBound, startWidth + delta))
    }
}

private struct PanelResizeHandle: View {
    @Binding var width: Double
    let currentWidth: Double
    let range: ClosedRange<Double>
    let reversed: Bool
    let accessibilityLabel: String
    @State private var dragStartWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .fill(hovering ? Color.accentColor.opacity(0.72) : Color.eagleLine)
                    .frame(width: hovering ? 2 : 1)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = currentWidth }
                        width = PanelResizeMath.width(
                            from: dragStartWidth ?? currentWidth,
                            translation: value.translation.width,
                            reversed: reversed,
                            range: range
                        )
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onTapGesture(count: 2) {
                width = min(range.upperBound, max(range.lowerBound, 238))
            }
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(Int(currentWidth)) 点")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 12.0 : -12.0
                width = min(range.upperBound, max(range.lowerBound, currentWidth + delta))
            }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.45 : 0.75)).contentShape(Rectangle())
    }
}

extension AssetPaletteColor {
    var displayPercentage: Int {
        let normalized = ratio > 1 ? ratio / 100 : ratio
        return Int((min(1, max(0, normalized)) * 100).rounded())
    }

    var hexString: String {
        let components = color + [0, 0, 0]
        return String(
            format: "#%02X%02X%02X",
            max(0, min(255, components[0])),
            max(0, min(255, components[1])),
            max(0, min(255, components[2]))
        )
    }

    var swiftUIColor: Color {
        let components = color + [0, 0, 0]
        return Color(
            red: Double(max(0, min(255, components[0]))) / 255,
            green: Double(max(0, min(255, components[1]))) / 255,
            blue: Double(max(0, min(255, components[2]))) / 255
        )
    }
}

extension Color {
    static let eagleMain = Color(red: 0.205, green: 0.209, blue: 0.218)
    static let eaglePanel = Color(red: 0.235, green: 0.239, blue: 0.247)
    static let eagleField = Color(red: 0.172, green: 0.176, blue: 0.183)
    static let eagleSelection = Color(red: 0.31, green: 0.315, blue: 0.33)
    static let eagleLine = Color.white.opacity(0.105)
    static let eaglePrimary = Color.white.opacity(0.86)
    static let eagleSecondary = Color.white.opacity(0.52)
    static let eagleSidebarText = Color.white.opacity(WorkspaceLayoutMetrics.sidebarTextOpacity)
    static let eagleSidebarSelectedText = Color.white.opacity(WorkspaceLayoutMetrics.sidebarSelectedTextOpacity)
    static let eagleSidebarCount = Color.white.opacity(WorkspaceLayoutMetrics.sidebarCountOpacity)
    static let eagleSidebarSectionText = Color.white.opacity(WorkspaceLayoutMetrics.sidebarSectionOpacity)
}
