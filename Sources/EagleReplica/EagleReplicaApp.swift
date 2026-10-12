import AppKit
import SwiftUI

@main
struct EagleReplicaApp: App {
    @NSApplicationDelegateAdaptor(EagleReplicaAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
                .background(WindowTestConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("素材") {
                Button("新建文件夹") { NotificationCenter.default.post(name: .libraryNewFolder, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("导入图片…") { NotificationCenter.default.post(name: .libraryImport, object: nil) }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("预览所选素材") { NotificationCenter.default.post(name: .libraryPreviewSelection, object: nil) }
                    .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button("显示或隐藏侧栏") { NotificationCenter.default.post(name: .libraryToggleSidebar, object: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("显示或隐藏详情栏") { NotificationCenter.default.post(name: .libraryToggleInspector, object: nil) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("显示") {
                Button("进入或退出全屏") {
                    (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}

@MainActor
final class EagleReplicaAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM can launch the executable without a normal foreground-app
        // policy. Force the main library to behave like a regular macOS app so
        // it owns a Dock icon and text fields can reliably become first responder.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        DragCoordinator.shared.startMonitoring()
        BrowserBridgeServer.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DragCoordinator.shared.stopMonitoring()
        BrowserBridgeServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return LibraryEditingState.shared.selectedAssetCount > 0
        }
        if menuItem.action == #selector(paste(_:)) {
            return AssetClipboard.canPaste()
        }
        return true
    }

    @objc func copy(_ sender: Any?) {
        NotificationCenter.default.post(name: .libraryCopySelection, object: nil)
    }

    @objc func paste(_ sender: Any?) {
        NotificationCenter.default.post(name: .libraryPasteClipboard, object: nil)
    }
}

private struct WindowTestConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.contentMinSize = NSSize(width: 1040, height: 660)
            // 和正式 App 保持一致：确保窗口有全屏能力，绿灯才是“进入全屏”而不是缩放。
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            if let width = ProcessInfo.processInfo.environment["EAGLE_TEST_WIDTH"].flatMap(Double.init),
               let height = ProcessInfo.processInfo.environment["EAGLE_TEST_HEIGHT"].flatMap(Double.init) {
                window.setContentSize(NSSize(width: width, height: height))
                window.center()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
