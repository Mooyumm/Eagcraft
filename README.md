# Eagcraft · 灵感库

A native macOS asset library for collecting, organizing, and rediscovering visual inspiration.

面向创作者的 macOS 原生素材库，支持网页图片采集、文件夹与标签整理、重复图片检测，以及通过自选 AI 服务生成标签和提示词。

**状态：早期公开测试版。** 当前应用内名称仍为「灵感库」，工程名为 `EagleReplica` / `InspirationLibrary`。这是独立项目，与 Eagle、PhotoCraft、ArtCraft 无隶属或背书关系；不承诺完整替代 Eagle。

[下载安装包](https://github.com/Mooyumm/Eagcraft/releases) · [构建与开发](docs/DEVELOPMENT.zh-CN.md) · [反馈问题](https://github.com/Mooyumm/Eagcraft/issues)

## 功能

- **收集**：本地导入、拖放、剪贴板粘贴，以及配合浏览器扩展采集网页图片。
- **整理**：文件夹、标签、评分、色标、注释、来源网址、批量编辑与智能文件夹。
- **浏览**：按原比例展示的图片网格、缩略图大小调节、预览、搜索与筛选。
- **查重**：SHA-256 完全重复检测与感知哈希相似图片检测。
- **AI 辅助**：配置自己的兼容接口，生成标签和图片提示词；API Key 保存于本机钥匙串。
- **本地素材库**：素材与索引保存在本机，支持资源库选择与基于共享目录的 iCloud 同步流程。

功能仍在迭代，大素材库性能、跨设备同步和不同网站的采集兼容性需要更多实际验证。重要素材请保留独立备份。

## 下载与安装

首个公开预发布提供现有 **灵感库 1.3（build 12）** 安装包：

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 或更高版本 |
| 芯片 | Apple Silicon（M 系列） |
| 安装 | 打开 DMG，将「灵感库.app」拖入「应用程序」 |
| Windows / Linux | 暂无可运行版本 |
| Intel Mac | 本次未提供安装包，也未验证源码构建 |

安装包为本地临时签名，未公证；macOS 可能阻止首次打开。在确认下载来源后，可检查「系统设置 → 隐私与安全性」中的「仍要打开」。

**发布来源**：安装包沿用项目中 2026-09-14 的 1.3 构建；公开源码来自当前工作目录。本次发布未重新构建二进制，不保证二进制与公开源码精确对应，也未完成另一台 Mac 上的安装验证。请将它作为预发布试用。

## 浏览器采集

- Chrome / Edge：扩展管理页打开开发者模式，选择「加载已解压的扩展程序」，加载本仓库的 `BrowserExtension/` 目录。
- Safari：应用内嵌采集扩展，在 Safari 设置中检查启用状态。临时签名扩展在其他 Mac 上的加载尚未验证，可能需要本地开发签名。
- 保持主程序运行。桥接服务只监听本机 `127.0.0.1:49158`。

## 从源码运行

需要 macOS 和带 Swift 6 工具链的 Xcode；首次启动 Xcode，完成组件安装与许可接受。

```bash
git clone https://github.com/Mooyumm/Eagcraft.git
cd Eagcraft
open Xcode/InspirationLibrary/InspirationLibrary.xcodeproj
```

选择 `InspirationLibrary` Scheme 与 `My Mac`，为主 App 和 Extension 配置自己的签名团队，按 `⌘R`。整个仓库目录结构必须保留，Xcode 工程使用相对路径引用源码和浏览器扩展。

用于开发与测试的 SwiftPM 入口：

```bash
swift build
swift test
swift run EagleReplica
```

本次发布环境的 Xcode 许可未接受，因此未重新运行构建和测试。现有测试位于 `Tests/EagleReplicaTests/`，覆盖素材库、剪贴板、网格布局、文件夹使用统计及同步逻辑；不代表所有用户操作都已验证。

## 数据与 AI

默认资源库：`~/Library/Application Support/EagleReplica/Library`。若在应用里切换了资源库，请以实际选择的目录为准。

迁移时先退出应用，复制整个资源库（包括 `index.json`、`assets`、`thumbnails` 等），然后在新电脑选择该目录。安装包和源码不包含你的个人素材或 API Key。新电脑需重新配置 AI 服务与同步连接，详见[迁移说明](docs/MIGRATION.zh-CN.txt)。

基础素材管理不需要 AI 服务。启用 AI 分析后，图片内容和请求文本会发送到你配置的服务，可能产生该服务的费用。

## 反馈与贡献

欢迎提交 Issue 或 Pull Request。反馈时请附 macOS 版本、芯片型号、复现步骤与错误信息，避免上传私人图片、API Key 或完整个人素材库。

近期重点：目标机安装验证、开发者签名与公证、素材备份恢复验证、大素材库性能，以及浏览器采集兼容性。CLI / MCP 素材自动化属于后续探索方向，当前尚未提供。

## 许可证

项目原创代码以 [MIT License](LICENSE) 发布。图像、图标等非代码资源的范围说明见 [ASSETS.md](ASSETS.md)。
