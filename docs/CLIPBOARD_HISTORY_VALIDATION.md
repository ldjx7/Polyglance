# 剪贴板历史验证记录

## 开发环境

本次开发主机为 Linux，无法在本机运行 AppKit 或构建 macOS 应用。macOS 构建与 Swift 测试由功能分支的 GitHub Actions 执行；GUI 和权限路径仍需要用户 Mac 真机验证。

Windows UI 按用户要求暂不实现，公共 Rust 模块在 Windows CI 中单独验证。

## 第一版本地验证

- `cargo test -p clipboard-core -p translator-uniffi`：通过。
- `cargo test --workspace --locked`：218 项测试通过，0 失败，其中新增 clipboard-core 测试 9 项。
- `cargo fmt --all --check`、`git diff --check`：通过。
- `cargo clippy -p clipboard-core --all-targets --locked -- -D warnings`：通过。
- `cargo clippy -p translator-uniffi --all-targets --no-deps --locked -- -D warnings`：通过。
- 包含依赖的全量 Clippy 在已有 `capture-core` 上发现 3 条基线警告；未改动该模块，新增模块与 FFI 的检查均通过。
- Swift 绑定已在 Linux 上从实际 UniFFI 库重新生成，用于核对接口和类型；正式 macOS 绑定在 macOS 构建脚本中生成，不手工修改生成物。

## 第一版原生 CI 验证

日期：2026-10-02。验证代码提交：`02e8d65fb82d7674ccddab3e3651134ed1d01697`。

[完整 CI 结果](https://github.com/ldjx7/Polyglance/actions/runs/37019244535)：macOS 和 Windows 两个任务均成功。

- macOS 15：`cargo test --workspace --locked`，218 项 Rust 测试通过。
- Windows 2025：`cargo test -p clipboard-core --locked`，9 项测试通过。
- `./scripts/build-macos-app.sh`：开发应用构建成功，未使用 `--preserve-permissions`。CI 显式使用 ad-hoc 开发签名，避免依赖开发者本机的证书。
- macOS 新增剪贴板测试单独运行：8 项全部通过，包含真实 NSPasteboard 富文本、TIFF 转 PNG、PNG 往返和生成绑定的持久化验证。
- `swift test --package-path apps/macos --configuration release --skip-build`：573 项测试，3 项跳过、0 失败。跳过项均为已有录屏 passthrough 测试，其视频样本在 runner 上生成失败；剪贴板测试无跳过。
- `codesign --verify --deep --strict 'dist/Polyglance Dev.app'`：通过。
- 开发应用 ZIP 已上传：[Polyglance-Clipboard-macOS-Dev](https://github.com/ldjx7/Polyglance/actions/runs/37019244535/artifacts/11232389964)，CI 保留至 2026-10-09。

全量 Release 测试首次运行时，已有 `ScreenRecordingAudioMixdownTests` 在读取音频样本前崩溃。测试输出对象不持有 `AVAssetReader`，优化后读取器可能在最后一次使用后提前释放。测试 fixture 增加 `withExtendedLifetime(readers)` 保持读取器直到采样结束，原有断言和录屏生产代码均未修改；最终全量测试通过。

## 后续功能验证

本轮新增文件引用与有序多项、类型/来源/标签筛选、名称和标签、后台本机 OCR 搜索索引、连续粘贴、SQLite 备份合并/替换和损坏库恢复。Windows UI 继续留给 `refactor/windows-rust-track`。

- 公共核心扩展测试覆盖顺序和去重、组合筛选、元数据/OCR 缓存、v1 迁移、备份与损坏恢复、无效和超额收藏导入回滚、10000 条分页及容量边界。
- Swift 增加旧设置兼容、纯文本多项合并、真实文件/多项重放、元数据/OCR 备份恢复、真实 Vision OCR 和图像像素预算测试。
- 从实际 UniFFI 库重新生成 Swift 绑定，核对新增类型、方法和错误；生成物仍不提交。
- 本地 Rust workspace：230 项测试通过，0 失败；其中 clipboard-core 原有 9 项、本轮扩展 12 项。扩展测试包含实际写入和分页 10000 条记录，整组约 9.3 秒，不将测试耗时当作 GUI 性能承诺。
- `cargo fmt --all --check`、`git diff --check` 及 clipboard-core / translator-uniffi 定向 Clippy 均通过。
- Linux Rust 1.99 在绑定生成依赖的默认并行代码生成中出现空目标文件归档错误；本地全量测试关闭调试信息，并仅将 `uniffi_bindgen` 的 codegen units 设为 1 后通过。此覆盖未写入仓库配置，原生 CI 仍用标准构建命令验证。
### 后续原生 CI 结果

日期：2026-10-02 UTC（北京时间 2026-10-03）。最终代码提交：`64cff8d2d203ece9a1218cb400afb63141626a5c`。

[最终 CI 结果](https://github.com/ldjx7/Polyglance/actions/runs/37060540877)：macOS 和 Windows 两个任务均成功。

- macOS 15：标准 `cargo test --workspace --locked`，230 项 Rust 测试通过，无本地 codegen 覆盖。
- Windows 2025：`cargo test -p clipboard-core --locked`，21 项测试通过。
- `./scripts/build-macos-app.sh`：完整生成 Swift 绑定并构建开发应用，未使用 `--preserve-permissions`；采用 ad-hoc 开发签名。
- macOS 剪贴板专项：13 项全部通过，无跳过；覆盖真实文件/多项 NSPasteboard、旧设置、生成绑定的元数据和备份恢复、Vision OCR 与图片预算。
- Swift 全量 Release：578 项测试，3 项已有录屏 passthrough fixture 测试跳过，0 失败；剪贴板测试无跳过。
- `codesign --verify --deep --strict 'dist/Polyglance Dev.app'`：通过。
- [最终 macOS 开发包](https://github.com/ldjx7/Polyglance/actions/runs/37060540877/artifacts/11250996502)：`Polyglance-Clipboard-macOS-Dev`，约 7.5 MB，保留至 2026-10-09 UTC。

复查修正包括：改写剪贴板前再次检查队列、前台应用和变化序号；取消旧操作不清空后来新建的队列；搜索筛选变化后不复制旧结果；敏感类型同时检查系统剪贴板与各项；手动 OCR 保存索引失败时仍展示识别结果。最终构建和测试覆盖该代码提交。

## 使用与真机验收

从菜单栏打开剪贴板历史，点击齿轮开启保存；新安装默认关闭。呼出快捷键在原有快捷键设置中配置。自动粘贴需要辅助功能权限，普通复制不需要。

尚需完成 `CLIPBOARD_HISTORY.md` 的实机验收，重点为中文输入、多显示器和全屏、跨应用粘贴及权限、连续粘贴中止路径、Finder 多文件重放、大图片性能、敏感来源排除、OCR 后台索引开关、备份与损坏恢复。当前 Linux 开发环境无法执行这些 GUI 操作。
