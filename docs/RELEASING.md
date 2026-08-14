# Polyglance macOS 发布与自动更新

## 发布模型

Polyglance 使用 Sparkle 2 检查和安装更新。应用只接受 HTTPS feed，并使用项目专属 Ed25519 公钥验证更新包；私钥不得提交到 Git。

GitHub Actions 在推送 `vX.Y.Z` 格式的 tag 时启动，并先验证该 tag 指向的提交属于 `main`。工作流依次执行 Rust/Swift 测试、构建 `.app`、生成 Sparkle appcast，最后创建 GitHub Release。

默认发布方式是**免费、未公证的开源分发**：构建使用项目长期保存的自签名代码身份，不需要 Apple Developer Program。固定证书、Bundle ID 和显式 Designated Requirement 让后续 Sparkle 替换继续被 macOS 识别为同一应用。Sparkle 的 Ed25519 签名仍会独立校验更新包的完整性与来源。

## 首次配置 GitHub Secrets

必须配置：

- `SPARKLE_PRIVATE_KEY`：本地 `.secrets/sparkle-private-key` 的完整内容。
- `FREE_AI_OPENROUTER_API_KEY`：仅供发布构建“免费 AI 翻译”使用的受限 OpenRouter Key。必须设置单独额度与模型限制，不能使用管理或高额度 Key。
- `MACOS_SIGNING_P12`：`.secrets/Polyglance-Code-Signing.p12` 的 Base64 内容。
- `MACOS_SIGNING_P12_PASSWORD`：导出 P12 时设置的密码。
- `MACOS_SIGNING_IDENTITY`：固定为 `Polyglance Open Source Signing`。
- `MACOS_KEYCHAIN_PASSWORD`：CI 临时钥匙串使用的随机密码。

自签名私钥不得提交到 Git、打印到日志或放入 Release。证书的公开 SHA-1 固定在 `config/macos-signing-certificate-sha1.txt`；CI 会拒绝任何不匹配的 P12，避免误用新证书导致更新后 TCC 权限失效。

以下 Apple 凭据完全可选，当前项目默认不配置。只有维护者日后决定加入 Apple Developer Program 并提供 Developer ID 签名/公证时才需要：

- `DEVELOPER_ID_APPLICATION`：例如 `Developer ID Application: Example (TEAMID)`。
- `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_SPECIFIC_PASSWORD`：Apple 公证凭据。

自签名版本仍未获得 Apple 公共信任，因此不改变首次下载时的 Gatekeeper 行为。它的作用是稳定更新前后的代码身份，使首次迁移并重新授权后的后续版本能够满足同一个 TCC Designated Requirement。

更新签名私钥缺失时工作流会直接失败，不会发布无法验证的更新。

## 用户安装说明（未公证版本）

1. 优先从 GitHub Release 下载并打开 `Polyglance-<版本>-macOS.dmg`，将 `Polyglance.app` 拖入“应用程序”文件夹。
2. 若 macOS 阻止首次启动，打开 DMG 中与应用并列的 `打不开Polyglance-复制本文件全部内容到终端执行.txt`，按 Command+A、Command+C 全选复制，再打开“终端”粘贴并按回车。说明行均以 `#` 开头，整份内容可直接执行；它只移除 `/Applications/Polyglance.app` 的下载隔离标记并启动该应用，不会关闭 Gatekeeper 或影响其他软件。
3. `Polyglance-<版本>-macOS.zip` 是 Sparkle 自动更新使用的完整应用包，也可手动解压安装。
4. 若仍被系统阻止，前往“系统设置 → 隐私与安全性”并选择“仍要打开”。未公证应用无法完全避免这一系统级确认。

无需关闭 Gatekeeper 或关闭 SIP。上述命令只在首次安装遇到 Gatekeeper 拦截时需要执行一次；后续启动和 Sparkle 应用内更新不需要重复操作。

## 创建版本

确保目标提交已经合入 `main`，然后执行：

```bash
git switch main
git pull --ff-only
git tag v0.2.0
git push origin v0.2.0
```

发布应用中的 `SUFeedURL` 会由工作流设置为当前仓库最新 Release 的 `appcast.xml`。菜单栏“检查更新…”可以手动触发检查，Sparkle 也会每天自动检查一次。

## 本地构建

普通本地构建不会注入更新源，因此不会后台访问占位地址：

```bash
./scripts/build-macos-app.sh
```

如需本地验证更新配置，可显式传入：

```bash
POLYGLANCE_APPCAST_URL="https://github.com/OWNER/REPO/releases/latest/download/appcast.xml" \
APP_VERSION="0.2.0" \
APP_BUILD_NUMBER="2" \
./scripts/build-macos-app.sh --preserve-permissions
```

私钥只用于生成 appcast 和签名发布压缩包，永远不应嵌入应用或写入构建日志。

OpenRouter Key 与 Sparkle 私钥不同：前者为了客户端直接调用会进入发布产物，因此不能视为真正秘密。面向大量用户发布前，建议把免费 AI 请求迁移到自有服务端代理；代理负责持有上游 Key、限流和防滥用。
