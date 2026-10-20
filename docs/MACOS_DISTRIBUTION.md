# macOS DMG 分发

在仓库根目录运行 `./package_and_notarize_dmg.sh`，即可从**当前工作目录的源代码**构建、签名并公证一个可拖拽安装的 DMG。安装包同时包含 Apple 芯片和 Intel 的代码，当前最低系统版本为 **macOS 14.6**。

脚本会使用当前代码，包括未提交的修改；不会自动拉取远程仓库、切换分支或更新子模块。发布前先自行确认需要发布的版本，并在 Xcode 中更新主 App 和 Widget 的版本号、构建号。

## 一次性准备

1. 安装完整 Xcode，打开一次并完成组件安装，在 **Xcode → Settings → Accounts** 登录有权使用本项目团队的 Apple 账号。默认团队为 `5Q255DK223`。
2. 使用有效的付费 Apple Developer Program 团队，在钥匙串中安装以下证书及其**私钥**：
   - **Apple Development**：供 Xcode 归档及自动管理开发描述文件。
   - **Developer ID Application**：供 App、Widget、动态库和 DMG 对外分发签名。它与 Apple Distribution、Developer ID Installer 是不同的证书。
3. 可在 Xcode Accounts 的 **Manage Certificates** 中管理证书。没有创建 Developer ID 证书权限时，请联系团队 Account Holder；从其他 Mac 导入时，需要含私钥的 `.p12`，仅导入 `.cer` 不够。
4. 确认团队中的两个 macOS App ID 都启用了 App Groups，并关联 `group.cn.hotxiang.Mumble`：
   - 主程序：`cn.hotxiang.Mumble`
   - Widget：`cn.hotxiang.Mumble.MumbleWidget`

   脚本通过 Xcode 自动获取开发和 Developer ID 分发描述文件。主程序和 Widget 都需要授权共享组的分发描述文件。不会移除共享组、沙盒、麦克风、网络或文件访问权限来绕过签名问题。
5. 将 Apple 公证凭据安全地保存进钥匙串。以下命令会交互式询问 App 专用密码，请勿把密码写入脚本或提交到仓库：

   ```bash
   xcrun notarytool store-credentials "mumble-notary" \
     --apple-id "你的 Apple ID 邮箱" \
     --team-id "5Q255DK223"
   ```

   也可以运行 `xcrun notarytool store-credentials mumble-notary`，按提示保存 App Store Connect API Key 凭据。配置完成后，脚本只读取钥匙串中的 `mumble-notary` 配置。

## 一键打包

```bash
# 先检查证书、私钥和公证登录；不会构建或上传 App
./package_and_notarize_dmg.sh --check

# 构建当前源码，完成签名、公证、DMG 和校验文件
./package_and_notarize_dmg.sh
```

`--check` 不会创建证书，也不保证团队权限或描述文件一定能被 Xcode 解析；实际归档、导出时还会验证这些条件。

流程如下：

1. 显式使用 `Release` 配置归档原生 macOS App，同时构建 `arm64` 和 `x86_64`，开启 Swift 发布优化及 Hardened Runtime。
2. 使用 Xcode 的 `developer-id` 方式导出 App 和 Widget，取得分发签名及相应的 provisioning profiles。
3. 对内嵌代码由内向外补齐安全时间戳和运行时保护。保留 Xcode 生成的完整权限，不使用 `codesign --deep` 签名。
4. 验证每个 Mach-O 的双架构、Developer ID 签名、团队、时间戳和调试权限；验证主程序的必要权限，以及共享组描述文件的证书、应用标识、团队和有效期。
5. 将 App 的 ZIP 提交 Apple 公证，只有状态为 `Accepted` 才继续；随后把票据附加到 App，并通过 Gatekeeper 验证。
6. 将 App 和指向 `/Applications` 的快捷方式放入压缩 DMG，签名并单独公证 DMG，再附加票据。
7. 验证 DMG 完整性与 Gatekeeper。全部通过后，才将 DMG 放到输出目录顶层，并生成 SHA-256 校验文件。

默认输出示例：

```text
build/distribution/
  Mumble-6.7.0-600700000-universal.dmg
  Mumble-6.7.0-600700000-universal.dmg.sha256
  run-<时间>-<随机值>/  # 归档、导出 App、构建缓存和所有诊断日志
```

同名发布包已存在时，脚本会停止，避免覆盖。更新版本号/构建号或指定新的输出目录后重试。每次运行的目录会保留，可能占用数 GB，发布完成后可自行清理不再需要的旧 `run-*` 目录。

用户打开 DMG 后，将 `Mumble.app` 拖到 **Applications** 即可安装。正常的首次打开确认、麦克风或其他必要权限提示仍会显示。公证票据同时附加到 App 和 DMG，便于安装后的离线验证；最终仍应在另一台受支持的 Mac 上进行下载、拖拽安装、首次启动、麦克风和通话验收。

## 常用选项

```bash
# 修改输出位置；带空格的路径也可以
./package_and_notarize_dmg.sh --output-dir "$HOME/Desktop/Mumble Release"

# 使用已经通过 Xcode Developer ID 导出的 App，不重新构建
./package_and_notarize_dmg.sh --app "/path/to/Mumble.app"
# 也兼容旧脚本的 App 路径参数形式
./package_and_notarize_dmg.sh "/path/to/Mumble.app"

# 使用其他团队及公证钥匙串配置
./package_and_notarize_dmg.sh \
  --team-id YOURTEAMID --keychain-profile my-notary
```

`--app` 会复制 App，再进行签名、公证，不修改传入的原件。输入必须已使用 Developer ID 导出，并携带正确的分发描述文件；开发签名、临时签名、仅包含单一架构的 App 会被拒绝。

如使用其他团队，需先处理 Bundle ID、App Group 归属及相应的签名配置；仅替换 Team ID 不会转移当前团队的标识或已有用户数据。

支持以下环境变量，或查看 `./package_and_notarize_dmg.sh --help`：

| 变量 | 默认值 / 用途 |
| --- | --- |
| `TEAM_ID` | `5Q255DK223` |
| `NOTARY_PROFILE` | `mumble-notary` |
| `OUTPUT_DIR` | 仓库内的 `build/distribution` |
| `NOTARY_KEYCHAIN` | 可选的公证凭据钥匙串文件路径 |
| `NOTARY_TIMEOUT` | 每次公证最多等待 `60m`，可用 `30m`、`2h` 等 |
| `EXPORT_OPTIONS_PLIST` | 自定义 `developer-id` 导出配置文件，等价于 `--export-options-plist` |

需要手动管理导出描述文件时，可传入从 Xcode 导出流程获得的 ExportOptions.plist，`method` 必须为 `developer-id`，`teamID` 必须与脚本一致。若使用 `signingStyle=manual`，`provisioningProfiles` 中应同时配置主 App 与 Widget 的 Bundle ID。默认归档步骤仍使用 Xcode 自动开发签名；已在其他机器完成导出的流水线可使用 `--app`。

## 失败排查

- **找不到 Developer ID Application identity**：检查证书是否过期、是否属于指定团队、私钥是否存在，以及钥匙串是否已解锁。只有 Apple Development 证书时无法生成正式分发包。
- **归档或导出签名失败**：查看本次 `run-*` 中的 `archive.log` / `export.log`。确认 Xcode 账号有团队权限、两个 App ID 的 App Groups 配置正确，且都有可用的描述文件。
- **公证 Invalid / Rejected**：查看 `app-notary.plist` / `dmg-notary.plist` 和相应的 `*-notary-log.json`。脚本会拒绝公证状态不是 `Accepted` 的结果，即使命令本身返回成功。
- **公证等待超时**：Apple 仍可能继续处理该提交。脚本会记录 submission ID，可以用 `xcrun notarytool info <ID> --keychain-profile mumble-notary` 查询，或用 `log` 子命令获取报告。超时的运行不会发布 DMG。
- **Gatekeeper 或票据验证失败**：查看 `app-gatekeeper.log` / `dmg-gatekeeper.log`，以及终端中的 stapler 错误。脚本不会忽略这类失败；修复后重新运行。

当前机器缺少分发证书或公证凭据时，脚本会在构建前停止，不会生成一个被误称为“已公证”的 DMG。凭据、证书和真实 Apple 公证结果无法通过脚本模拟替代。

参考 Apple 文档：[macOS 分发签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、[App Group 容器](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)、[公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[打包 macOS 软件](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。
