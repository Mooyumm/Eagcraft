import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var step = 0
    @State private var endpoint = AISettingsStore.shared.configuration.endpoint
    @State private var model = AISettingsStore.shared.configuration.model
    @State private var apiKey = AISettingsStore.shared.apiKey()
    @State private var automatic = AISettingsStore.shared.automaticTaggingEnabled
    @State private var message = ""
    @State private var busy = false
    @State private var failed = false
    @State private var sampleMessage = ""

    private let titles = ["把灵感收进来", "浏览与整理", "让 AI 帮你理解素材", "在不同 Mac 上继续", "连接你的 AI"]
    private let icons = ["square.and.arrow.down", "rectangle.3.group", "sparkles", "icloud", "key"]
    private var configuration: AIModelConfiguration {
        AIModelConfiguration(endpoint: endpoint, model: model,
            prompt: AISettingsStore.shared.configuration.prompt,
            maximumTags: AISettingsStore.shared.configuration.maximumTags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("灵感库 · 新手教程", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("\(step + 1) / \(titles.count)").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step + 1), total: Double(titles.count))
            HStack(spacing: 14) {
                Image(systemName: icons[step])
                    .font(.system(size: 30)).foregroundStyle(Color.accentColor)
                    .frame(width: 62, height: 62)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                Text(titles[step]).font(.system(size: 25, weight: .semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0:
                        sampleLesson
                        lesson("导入本地图片", "点击左上角 ＋ 选择导入图片，或把 Finder 中的图片拖进资源库。", "photo.badge.plus")
                        lesson("从 Safari 采集", "先在 Safari 设置 → 扩展中启用灵感库采集器并允许当前网站。拖动网页图片后，将它放入采集框或框内文件夹，看到成功提示即完成入库。", "safari")
                        lesson("重复图片会被检查", "完全相同的文件会复用已有素材并补充文件夹归属；相似图片需要确认，不会仅凭外观自动删除。", "doc.on.doc")
                    case 1:
                        lesson("预览与手势", "双击图片进入预览。触控板双指滑动移动画面，双指捏合缩放；鼠标滚轮的操作可在设置中调整。", "hand.draw")
                        lesson("拖进文件夹", "将素材拖到左栏文件夹即可添加归属。参考文件夹用于参考用途，风格文件夹用于视觉分类。", "folder")
                        lesson("搜索、标签与导出", "用搜索和筛选查找素材；右栏可编辑名称、注释和人工标签。把图片拖到 Finder 或聊天软件即可引用文件。", "magnifyingglass")
                    case 2:
                        lesson("自动整理", "配置 API Key 后，可开启自动标记：为素材生成名称、标签和提示词。人工标签与 AI 标签分开显示。", "sparkles")
                        lesson("风格与智能分类", "AI 标签会组成风格索引和智能文件夹；喜欢的风格可以右键收藏。", "square.grid.2x2")
                        lesson("围绕图片聊天", "在右栏 AI 标签下打开 AI 对话，发送问题时会附带当前图片。聊天记录保存在资源库，下次打开仍可继续。", "bubble.left.and.bubble.right")
                    case 3:
                        lesson("连接同一个 iCloud 共享库", "在设置 → iCloud 同步中，选择 iCloud Drive 下的专用文件夹。另一台 Mac 登录同一 Apple 账户、开启 iCloud Drive，再选择同一个文件夹。", "icloud")
                        lesson("共享整个素材库", "原图、AI 标签与聊天、智能文件夹、参考文件夹、风格文件夹和收藏一起共享。离线仍可使用本地副本，联网并打开 App 后继续同步。", "laptopcomputer")
                        lesson("查看同步进度", "设置页显示合并结果；iCloud 上传和下载进度以 Finder 为准。每台 Mac 单独填写 API Key。", "arrow.triangle.2.circlepath")
                    default:
                        Text("填写支持图片输入的服务信息，就能使用 AI 整理与图片对话。")
                            .foregroundStyle(.secondary)
                        Text("模型已按你的需求预填；服务商仍需实际支持该模型及图片输入。连接失败时可修改接口或模型，不影响本地素材管理。")
                            .font(.caption).foregroundStyle(.secondary)
                        field("API 接口") { TextField("https://api.deepseek.com/chat/completions", text: $endpoint) }
                        field("模型名称") { TextField(AISettingsStore.defaultModel, text: $model) }
                        field("API Key") { SecureField("粘贴你的 API Key（⌘V）", text: $apiKey) }
                        Toggle("连接后自动整理尚未处理的素材", isOn: $automatic)
                        Text("Key 保存在本机系统钥匙串。发送 AI 请求时，图片及问题会传给这里配置的服务，可能产生服务费用。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(busy ? "正在测试…" : "测试连接") { test() }
                            .disabled(busy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !message.isEmpty {
                            Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.green)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if step > 0 { Button("上一步") { step -= 1 }.disabled(busy) }
                Spacer()
                if step == titles.count - 1 {
                    Button("稍后设置") { finish() }.disabled(busy)
                    Button("保存并开始使用") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("下一步") { step += 1 }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 660, height: 590)
        .background(Color.eaglePanel)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private var sampleLesson: some View {
        HStack(spacing: 16) {
            if let url = LibraryStore.shared.tutorialImageURL,
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("先用一张示例图试试").font(.headline)
                Text("原创 AI 示例照片 · 窗边的橙子。可选添加，不会覆盖你的素材；重复点击也只保留一份。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("添加示例图到资源库") {
                    do {
                        let result = try LibraryStore.shared.importTutorialImage()
                        sampleMessage = result.disposition == .imported ? "已添加，可在「全部」中找到。" : "示例图已在库中，没有重复添加。"
                    } catch { sampleMessage = "添加失败：\(error.localizedDescription)" }
                }
                if !sampleMessage.isEmpty { Text(sampleMessage).font(.caption).textSelection(.enabled) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 10))
    }

    private func lesson(_ title: String, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 25)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 10))
    }

    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).padding(10)
                .background(Color.eagleField, in: RoundedRectangle(cornerRadius: 7))
        }
    }
    private func finish() {
        UserDefaults.standard.set(true, forKey: "EagleReplica.onboarding.completed.v1")
        onFinish()
    }
    private func save() {
        do {
            try AISettingsStore.shared.save(configuration: configuration, apiKey: apiKey, automaticTaggingEnabled: automatic)
            finish()
        } catch { failed = true; message = error.localizedDescription }
    }
    private func test() {
        busy = true
        Task {
            do {
                message = try await AISettingsStore.shared.testConnection(configuration: configuration, apiKey: apiKey)
                failed = false
            } catch { failed = true; message = error.localizedDescription }
            busy = false
        }
    }
}

struct LibraryCloudSettingsView: View {
    @ObservedObject private var sync = LibrarySyncController.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("iCloud 同步", systemImage: "icloud").font(.title2)
                Text("两台 Mac 登录同一 Apple 账户并开启 iCloud Drive，再选择同一个共享文件夹。当前素材库会与共享库合并。")
                    .foregroundStyle(.secondary)
                Label("原图、AI 标签、图片对话与提示词", systemImage: "photo.on.rectangle")
                Label("智能文件夹、参考文件夹、风格文件夹与收藏", systemImage: "folder")
                Text("API Key 留在每台 Mac 的钥匙串，需要分别配置。离线编辑会在再次联网并打开 App 后同步。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if let url = sync.cloudURL { Text(url.path).font(.caption).textSelection(.enabled) }
                HStack {
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    Text(sync.status).font(.callout).textSelection(.enabled)
                }
                if let date = sync.lastSync {
                    Text("上次本机合并：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(sync.isEnabled ? "更换共享文件夹…" : "选择 iCloud 共享文件夹…") { sync.chooseFolder() }
                    .buttonStyle(.borderedProminent).disabled(sync.isSyncing)
                if sync.isEnabled {
                    HStack {
                        Button("立即同步") { sync.syncNow() }
                        Button("在 Finder 中查看") {
                            if let url = sync.cloudURL { NSWorkspace.shared.open(url) }
                        }
                        Button("断开同步") { sync.disconnect() }
                    }.disabled(sync.isSyncing)
                }
                Text("不同字段的修改会合并；同时修改同一字段时按同步版本确定结果。每次应用远端修改前会在本地 sync-backups 保存索引备份。云端保留文件副本，以便离线设备重新连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}
