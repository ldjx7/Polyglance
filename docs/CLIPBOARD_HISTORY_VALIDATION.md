# 剪贴板历史验证记录

## 开发环境

本次开发主机为 Linux，无法在本机运行 AppKit 或构建 macOS 应用。macOS 构建与 Swift 测试由功能分支的 GitHub Actions 执行；GUI 和权限路径仍需要用户 Mac 真机验证。

Windows UI 按用户要求暂不实现，公共 Rust 模块在 Windows CI 中单独验证。

## 本地验证

- `cargo test -p clipboard-core -p translator-uniffi`：通过。
- `cargo test --workspace --locked`：218 项测试通过，0 失败，其中新增 clipboard-core 测试 9 项。
- `cargo fmt --all --check`、`git diff --check`：通过。
- `cargo clippy -p clipboard-core --all-targets --locked -- -D warnings`：通过。
- `cargo clippy -p translator-uniffi --all-targets --no-deps --locked -- -D warnings`：通过。
- 包含依赖的全量 Clippy 在已有 `capture-core` 上发现 3 条基线警告；未改动无关模块，新增模块与 FFI 的检查均通过。
- Swift 绑定已在 Linux 上从实际 UniFFI 库重新生成，用于核对接口和类型；正式 macOS 绑定在 macOS 构建脚本中生成，不手工修改生成物。

## 待验证

- macOS CI 的开发应用构建、Swift 测试及签名检查。
- `CLIPBOARD_HISTORY.md` 中列出的真机交互、权限、资源占用和隐私验收。
