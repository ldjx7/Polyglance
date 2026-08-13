# Polyglance macOS 发布与自动更新

## 发布模型

Polyglance 使用 Sparkle 2 检查和安装更新。应用只接受 HTTPS feed，并使用项目专属 Ed25519 公钥验证更新包；私钥不得提交到 Git。

GitHub Actions 在推送 `vX.Y.Z` 格式的 tag 时启动，并先验证该 tag 指向的提交属于 `main`。工作流依次执行 Rust/Swift 测试、构建 `.app`、可选 Developer ID 签名与公证、生成 Sparkle appcast，最后创建 GitHub Release。

## 首次配置 GitHub Secrets

必须配置：

- `SPARKLE_PRIVATE_KEY`：本地 `.secrets/sparkle-private-key` 的完整内容。

公开分发建议同时配置：

- `MACOS_CERTIFICATE_P12`：Developer ID Application 证书 P12 的 Base64。
- `MACOS_CERTIFICATE_PASSWORD`：P12 密码。
- `MACOS_KEYCHAIN_PASSWORD`：CI 临时钥匙串密码。
- `DEVELOPER_ID_APPLICATION`：例如 `Developer ID Application: Example (TEAMID)`。
- `APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_SPECIFIC_PASSWORD`：Apple 公证凭据。

如果未配置 Developer ID，工作流仍能生成临时签名构建，但不适合给其他用户公开安装。更新签名私钥缺失时工作流会直接失败，不会发布无法验证的更新。

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
