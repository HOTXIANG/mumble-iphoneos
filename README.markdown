# Mumble for iOS and macOS

[中文](#中文) | [English](#english)

---

## 中文

Mumble 是一款低延迟、高音质、开源的语音聊天应用。本仓库是 iOS + macOS 客户端实现，包含 SwiftUI 界面层、Objective-C 应用逻辑层以及 MumbleKit 音频/网络底层。

- 官方网站: https://mumble.info/
- 桌面版仓库: https://github.com/mumble-voip/mumble
- 本仓库: https://github.com/HOTXIANG/mumble-iphoneos

### TestFlight 公测

欢迎通过 TestFlight 参与公开测试：

https://testflight.apple.com/join/wTzGU5Zq

### 平台与技术栈

- 平台: iOS 17.0+ / macOS 14.0+
- 语言: Swift 5.9+、Objective-C（ARC）
- 底层: MumbleKit（MRC，音频与协议栈）
- UI: SwiftUI
- 数据: SQLite（FMDB）
- 依赖管理: Git submodule（无 CocoaPods / SPM）

### 项目结构

```text
Source/Classes/
    SwiftUI/                  # 现代 UI 与状态管理
    MU*.h/.m                  # Objective-C 应用层
MumbleKit/
    src/                      # 音频与协议底层（MRC）
Dependencies/
    fmdb/                     # SQLite 封装
Mumble.xcodeproj            # Xcode 工程
```

### 快速开始

1. 克隆仓库（包含子模块）

```bash
git clone --recursive https://github.com/HOTXIANG/mumble-iphoneos.git
cd mumble-iphoneos
```

2. 若已克隆但未拉取子模块

```bash
git submodule update --init --recursive
```

3. 打开工程

```bash
open Mumble.xcodeproj
```

4. 在 Xcode 中选择目标设备后构建（Cmd+B）

### 命令行构建

```bash
# iOS
xcodebuild -target Mumble -destination 'generic/platform=iOS' build

# macOS
xcodebuild -target Mumble -destination 'platform=macOS' build
```

> 提示: 如首次构建遇到第三方库相关问题，请确认子模块已完整同步。

### 开发说明

- UI 更新请注意主线程约束（@MainActor / 主线程派发）。
- Source/Classes/ 下 Objective-C 代码默认 ARC。
- MumbleKit/src/ 下为 MRC，修改时需要手动内存管理。
- 提交前建议至少完成 iOS 与 macOS 双平台构建验证。

### 贡献

欢迎提交 Issue 和 Pull Request。

- 提交前请确保代码可编译。
- 新功能请尽量保持 iOS/macOS 体验一致。
- 建议遵循常见 commit 前缀：feat、fix、refactor、docs、chore。

### 许可证

本项目遵循仓库内 LICENSE 文件。

---

## English

Mumble is a low-latency, high-quality, open-source voice chat application. This repository contains the iOS + macOS client, including a SwiftUI UI layer, an Objective-C application layer, and the MumbleKit audio/network core.

- Official website: https://mumble.info/
- Desktop repository: https://github.com/mumble-voip/mumble
- This repository: https://github.com/HOTXIANG/mumble-iphoneos

### TestFlight Public Beta

Join the public beta on TestFlight:

https://testflight.apple.com/join/wTzGU5Zq

### Platforms and Stack

- Platforms: iOS 17.0+ / macOS 14.0+
- Languages: Swift 5.9+, Objective-C (ARC)
- Core: MumbleKit (MRC, audio and protocol stack)
- UI: SwiftUI
- Data: SQLite (FMDB)
- Dependency management: Git submodules (no CocoaPods / SPM)

### Project Structure

```text
Source/Classes/
    SwiftUI/                  # Modern UI and state management
    MU*.h/.m                  # Objective-C app layer
MumbleKit/
    src/                      # Audio/protocol core (MRC)
Dependencies/
    fmdb/                     # SQLite wrapper
Mumble.xcodeproj            # Xcode project
```

### Quick Start

1. Clone the repository with submodules:

```bash
git clone --recursive https://github.com/HOTXIANG/mumble-iphoneos.git
cd mumble-iphoneos
```

2. If already cloned, initialize submodules:

```bash
git submodule update --init --recursive
```

3. Open the project:

```bash
open Mumble.xcodeproj
```

4. Select a target device in Xcode and build (Cmd+B).

### Command-Line Build

```bash
# iOS
xcodebuild -target Mumble -destination 'generic/platform=iOS' build

# macOS
xcodebuild -target Mumble -destination 'platform=macOS' build
```

> Tip: If you hit third-party build issues on first build, verify submodules are fully synced.

### Development Notes

- Keep UI state updates on the main thread (@MainActor / main-thread dispatch).
- Objective-C code under Source/Classes/ uses ARC.
- MumbleKit/src/ uses MRC, so manual memory management is required.
- Validate both iOS and macOS builds before submitting changes.

### Contributing

Issues and pull requests are welcome.

- Ensure the project builds successfully before submitting.
- Keep feature behavior consistent across iOS and macOS when possible.
- Recommended commit prefixes: feat, fix, refactor, docs, chore.

### License

This project is licensed under the LICENSE file in this repository.
