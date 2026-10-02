# 剪贴板历史验证记录

## 开发环境

本次开发主机为 Linux，无法在本机运行 AppKit 或构建 macOS 应用。macOS 构建与 Swift 测试由功能分支的 GitHub Actions 执行；GUI 和权限路径仍需要用户 Mac 真机验证。

Windows UI 按用户要求暂不实现，公共 Rust 模块在 Windows CI 中单独验证。

## 本地验证

- `cargo test -p clipboard-core -p translator-uniffi`：通过。
- Rust 工作区测试、格式与静态检查：提交前补充结果。
- Swift 绑定已在 Linux 上从实际 UniFFI 库重新生成，用于核对接口和类型；正式 macOS 绑定在 macOS 构建脚本中生成，不手工修改生成物。

## 待验证

- macOS CI 的开发应用构建、Swift 测试及签名检查。
- `CLIPBOARD_HISTORY.md` 中列出的真机交互、权限、资源占用和隐私验收。
