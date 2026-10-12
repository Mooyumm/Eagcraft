//
//  AppDelegate.swift
//  InspirationLibrary
//
//  Created by mooyumm on 8/26/26.
//

import Cocoa
import SafariServices

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {

    private let extensionBundleIdentifier = "com.mooyumm.InspirationLibrary.Extension"
    private weak var trafficLightWindow: NSWindow?
    private var trafficLightBaseFrames: [NSWindow.ButtonType: NSRect] = [:]
    private var trafficLightObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        DragCoordinator.shared.startMonitoring()
        BrowserBridgeServer.shared.start()

        if ProcessInfo.processInfo.arguments.contains("--show-collector") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                CollectorPanelController.shared.showNearMouse()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--install-safari-extension") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                SafariExtensionStatusController.shared.installOrManageExtension()
            }
        }

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
            window.title = "灵感库"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert([.fullSizeContentView, .resizable, .miniaturizable])
            // Storyboard 里这个窗口被声明成 fullScreenNone，绿灯只能做缩放。
            // 这里补回全屏能力，让绿灯恢复成“进入全屏”，并让 ⌃⌘F 可用。
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            let minimumContentSize = NSSize(width: 1040, height: 660)
            window.contentMinSize = minimumContentSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
            window.delegate = self
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            window.appearance = NSAppearance(named: .darkAqua)
            self.configureTrafficLights(in: window)
        }

        let extensionMenu = NSMenuItem(title: "打开 Safari 扩展设置…", action: #selector(openSafariExtensionSettings), keyEquivalent: ",")
        extensionMenu.target = self
        NSApp.mainMenu?.item(at: 0)?.submenu?.insertItem(extensionMenu, at: 1)
        installLibraryMenu()
        installEditingMenu()
        installViewMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 主窗口关闭后仍驻留，以便 Safari 拖图时显示收集器。
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        trafficLightObservers.forEach(NotificationCenter.default.removeObserver)
        trafficLightObservers.removeAll()
        DragCoordinator.shared.stopMonitoring()
        BrowserBridgeServer.shared.stop()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimumFrame = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: 1040, height: 660))
        ).size
        return NSSize(width: max(frameSize.width, minimumFrame.width), height: max(frameSize.height, minimumFrame.height))
    }

    @objc private func openSafariExtensionSettings() {
        SafariExtensionStatusController.shared.installOrManageExtension()
    }

    private func installLibraryMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let rootItem = NSMenuItem()
        let menu = NSMenu(title: "素材")
        rootItem.submenu = menu
        mainMenu.addItem(rootItem)

        menu.addItem(commandItem("新建文件夹", action: #selector(newFolder), key: "n", modifiers: [.command, .shift]))
        menu.addItem(commandItem("导入图片…", action: #selector(importImages), key: "i", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(commandItem("预览所选素材", action: #selector(previewSelection), key: " ", modifiers: []))
        menu.addItem(.separator())
        // 编辑菜单里的复制/粘贴优先给文本框用；这里再放一份，保证选中素材时
        // ⌘C/⌘V 一定落在素材上（菜单栏里靠前的可用项会被优先派发，两者行为一致，不会重复执行）。
        menu.addItem(commandItem("复制素材", action: #selector(copySelection), key: "c", modifiers: .command))
        menu.addItem(commandItem("粘贴图片", action: #selector(pasteSelection), key: "v", modifiers: .command))
        menu.addItem(.separator())
        menu.addItem(commandItem("显示或隐藏侧栏", action: #selector(toggleSidebar), key: "s", modifiers: [.command, .option]))
        menu.addItem(commandItem("显示或隐藏详情栏", action: #selector(toggleInspector), key: "i", modifiers: [.command, .option]))
    }

    private func installEditingMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let root = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        root.submenu = menu
        // Nil targets route to the active field editor, including SwiftUI sheets
        // and secure fields. Targeting the app delegate breaks this responder chain.
        for (title, selector, key) in [
            ("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
            ("复制", "copy:", "c"), ("粘贴", "paste:", "v"),
            ("全选", "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            menu.addItem(item)
        }
        let redo = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.insertItem(redo, at: 1)
        mainMenu.insertItem(root, at: min(1, mainMenu.items.count))
    }

    private func commandItem(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    /// 标准 macOS App 的“显示”菜单里应该有进入/退出全屏，这个工程的菜单是手工搭的，
    /// 所以这里补一个。
    private func installViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let root = NSMenuItem()
        let menu = NSMenu(title: "显示")
        root.submenu = menu
        menu.addItem(commandItem("进入全屏", action: #selector(toggleFullScreen), key: "f", modifiers: [.control, .command]))

        // 放在“帮助”之前，保持系统菜单的常见顺序。
        let helpIndex = mainMenu.items.firstIndex { $0.submenu?.title == "Help" } ?? mainMenu.items.count
        mainMenu.insertItem(root, at: helpIndex)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(previewSelection), NSApp.keyWindow?.firstResponder is NSTextView { return false }
        if menuItem.action == #selector(toggleFullScreen) {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            menuItem.title = window?.styleMask.contains(.fullScreen) == true ? "退出全屏" : "进入全屏"
            return window?.collectionBehavior.contains(.fullScreenPrimary) ?? false
        }
        // 编辑菜单里的复制/粘贴用 nil target 走响应链：文本框自己会处理，
        // 只有在没有文本框接手时才会落到这里，所以按素材选区与剪贴板内容决定可用性。
        if menuItem.action == #selector(copy(_:)) {
            return LibraryEditingState.shared.selectedAssetCount > 0
        }
        if menuItem.action == #selector(paste(_:)) {
            return AssetClipboard.canPaste()
        }
        if menuItem.action == #selector(copySelection) {
            return LibraryEditingState.shared.selectedAssetCount > 0
        }
        if menuItem.action == #selector(pasteSelection) {
            return AssetClipboard.canPaste()
        }
        return true
    }

    @objc private func copySelection() {
        NotificationCenter.default.post(name: .libraryCopySelection, object: nil)
    }

    @objc private func pasteSelection() {
        NotificationCenter.default.post(name: .libraryPasteClipboard, object: nil)
    }

    @objc func copy(_ sender: Any?) {
        NotificationCenter.default.post(name: .libraryCopySelection, object: nil)
    }

    @objc func paste(_ sender: Any?) {
        NotificationCenter.default.post(name: .libraryPasteClipboard, object: nil)
    }

    @objc private func newFolder() { NotificationCenter.default.post(name: .libraryNewFolder, object: nil) }
    @objc private func importImages() { NotificationCenter.default.post(name: .libraryImport, object: nil) }
    @objc private func previewSelection() { NotificationCenter.default.post(name: .libraryPreviewSelection, object: nil) }
    @objc private func toggleSidebar() { NotificationCenter.default.post(name: .libraryToggleSidebar, object: nil) }
    @objc private func toggleInspector() { NotificationCenter.default.post(name: .libraryToggleInspector, object: nil) }
    @objc private func toggleFullScreen() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { !($0 is NSPanel) }
        window?.toggleFullScreen(nil)
    }

    private func configureTrafficLights(in window: NSWindow) {
        trafficLightWindow = window
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        trafficLightBaseFrames = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
            window.standardWindowButton(kind).map { (kind, $0.frame) }
        })
        positionTrafficLights()

        let center = NotificationCenter.default
        trafficLightObservers = [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.positionTrafficLights() }
            }
        }
    }

    private func positionTrafficLights() {
        guard let window = trafficLightWindow else { return }
        for (kind, baseFrame) in trafficLightBaseFrames {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.setFrameOrigin(NSPoint(
                x: baseFrame.origin.x + WorkspaceLayoutMetrics.trafficLightHorizontalOffset,
                y: baseFrame.origin.y - WorkspaceLayoutMetrics.trafficLightVerticalOffset
            ))
        }
    }
}
