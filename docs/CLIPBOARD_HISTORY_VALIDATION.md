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

## Maccy 对照能力补齐

日期：2026-10-03 UTC。本轮增加内容正则排除、系统清空同步移除、仅忽略下一次复制、预览和 HEX 色块、来源图标、数字及固定项快捷键、修饰键循环选择、固定文本编辑、系统通知和八个 Apple 快捷指令动作。

- Rust 增加 8 项测试，覆盖完整原文和多项正则过滤、无效规则、编辑保留元数据/快捷键/ID、格式变为纯文本、重复和容量失败回滚、绑定唯一性与取消固定、备份合并/重启、v2 迁移。
- 清空保护使用随机捕获令牌。测试包含同一毫秒内重复复制、编辑后令牌失效和收藏删除，旧清理任务不能删除新内容。
- Swift 增加 8 项测试，覆盖一次性忽略生命周期、内部重放关联失效、HEX 完整匹配、真实 NSPasteboard 空内容和来源标记、旧设置默认值、快捷指令读取完整原文和重放富文本、暂停的用户开关与默认保留收藏。
- 原生监听测试使用独立真实 NSPasteboard，开启记录后捕获、固定、写入带敏感元数据的空内容，核对同步删除；随后验证只忽略一次复制，再次复制正常入库。测试不改写系统通用剪贴板。
- 构建脚本为 SwiftPM 生成编译器常量并在签名前提取 `Metadata.appintents`；CI 检查最终包中的八个动作，避免只验证 Swift 类型编译。
- 本地 `zsh scripts/tests/build-macos-app.test.zsh` 与 `git diff --check` 通过。Linux 环境未运行 Swift 或 AppKit；原生构建和执行结果以本轮 CI 为准。

### 本轮原生 CI 结果

最终代码提交：`3804caf7805544b4038f55a67e025c18757a0aaf`。

[最终 CI 结果](https://github.com/ldjx7/Polyglance/actions/runs/37102648010)：macOS 和 Windows 两个任务均成功。

- macOS 15：`cargo test --workspace --locked`，238 项 Rust 测试通过，0 失败；`cargo fmt --all --check` 通过。
- Windows 2025：`cargo test -p clipboard-core --locked`，29 项测试通过，0 失败。
- `./scripts/build-macos-app.sh`：重新生成真实 UniFFI 绑定，完整构建独立开发应用，未使用 `--preserve-permissions`，采用 ad-hoc 开发签名。
- `codesign --verify --deep --strict 'dist/Polyglance Dev.app'` 通过。最终应用包的 `Metadata.appintents` 校验确认八个剪贴板动作均存在。
- `swift test --package-path apps/macos --configuration release --filter Clipboard`：26 项通过，0 失败、无跳过；其中 ClipboardHistoryTests 13 项、ClipboardInteractionTests 8 项，另外 5 项为已有剪贴板相关测试。
- Swift 全量 Release：586 项测试，3 项既有 ScreenRecordingPassthroughTests 因 runner 视频样本生成失败而跳过，0 失败；新增剪贴板测试无跳过。
- [macOS 开发包](https://github.com/ldjx7/Polyglance/actions/runs/37102648010/artifacts/11265909295)：`Polyglance-Clipboard-macOS-Dev`，约 7.7 MB，CI 保留至 2026-10-10 UTC。

本轮修改没有包含 Windows C# 客户端；新平台接入仍使用文档中的 Rust + Slint 方案。以上代码、签名、真实剪贴板测试和动作元数据均经过 CI 验证；系统快捷指令中的实际发现、通知授权和跨应用交互仍按下面的真机清单验收。

## 使用与真机验收

从菜单栏打开剪贴板历史，点击齿轮开启保存；新安装默认关闭。呼出快捷键在原有快捷键设置中配置。自动粘贴需要辅助功能权限，普通复制不需要。

尚需完成 `CLIPBOARD_HISTORY.md` 的实机验收，重点为中文输入、多显示器和全屏、跨应用粘贴及权限、连续粘贴中止路径、Finder 多文件重放、大图片性能、敏感来源排除、OCR 后台索引开关、备份与损坏恢复。本轮新增循环选择松键与中止、设置冲突提示、实际密码管理器清空、通知授权和快捷指令在系统中的发现与冷启动。当前 Linux 开发环境无法执行这些 GUI 操作；CI 不代替这些检查。

## 五项 review 问题修复（2026-10-03 UTC）

- 选择锚点使用条目 ID，列表刷新和鼠标重新选择会重置范围选择；筛选、删除或清空后不会使用旧数组下标。
- 界面和快捷指令共用清空流程：暂停采样，使旧任务失效，等待已经开始的捕获退出，再清空数据库。导入替换及退出也等待旧捕获结束。
- 重复记录只有在有序图片载荷完全一致时才保留 OCR。后台和手动识别通过捕获令牌提交结果，旧结果和旧失败状态不能覆盖新内容。备份合并只采用与最终图片一致的 OCR；旧版遗留的无图片缓存会在打开数据库或恢复备份时移除。
- 普通、数字及固定项复制持有操作版本和初始剪贴板序号。关闭窗口、重新打开、清空或导入使旧操作失效；改写前重新核对剪贴板和粘贴目标。操作自己关闭窗口后仍可完成已确认的粘贴。
- 标签先转为规范的小写形式，再校验字符和字节长度，避免已保存标签在恢复自身备份时被拒绝。

新增 Rust 回归覆盖缓存失效与容量记账、相同图片缓存保留、过期 OCR 提交、备份合并和恢复、旧库修复以及 Unicode 标签边界。新增 macOS 回归使用可控暂停的处理器验证清空竞争，并覆盖筛选后多选、鼠标重选、Esc 关闭后重开、等待期间外部复制、正常复制和生成绑定的旧 OCR 拒绝。

验证完成：

- 修复提交：`b9b82d5370ef0f9c2f9baceca46e81973496142f`；最终验证代码提交：`c9e9579821ff6e22d70e4f69e40daadaf0756bcd`。
- [Clipboard History CI 37139889119](https://github.com/ldjx7/Polyglance/actions/runs/37139889119)：macOS 和 Windows 两个任务全部成功。
- Rust workspace：245 项通过；Windows 公共核心：36 项通过；Rust 格式检查通过。
- macOS 剪贴板专项：34 项通过，无跳过。新增 8 项回归在专项和全量测试中均通过，包括界面清空、快捷指令清空、监听恢复、Esc 后重开和旧 OCR 拒绝。
- Swift 全量：执行 594 项，0 失败，3 项已有的 ScreenRecordingPassthroughTests 因 CI 无法生成录屏样本而跳过。
- 开发包构建、代码签名和 8 个快捷指令动作元数据验证通过。
- [macOS 开发包](https://github.com/ldjx7/Polyglance/actions/runs/37139889119/artifacts/11280325855)，产物 ID `11280325855`，大小 7,691,180 字节，保留至 2026-10-10 17:24 UTC。

首轮两项清空测试因模拟复制未先调用 clearContents 更新剪贴板变更序号而超时。测试补上真实复制的声明流程、写入成功断言和分阶段定位后，原有清空及恢复监听断言全部通过，没有删除或跳过回归用例。

Windows UI 仍按原规划留给 Rust + Slint 重构分支，本轮只验证公共核心。GUI 实机验收仍按上文列表执行，CI 不代替真实应用中的权限、焦点、中文输入和多屏操作检查。

## 三项追加 review 问题修复（2026-10-04 UTC）

- 图片预算下沉到 Rust 共同入库入口：读取完整 PNG 尺寸头，对每张图片检查 1600 万像素限制；备份合并和替换遇到超限图片时，整次事务回滚。仍由平台图像框架负责实际解码。
- macOS 保存手动 OCR 的任务和请求代次。关闭和重开窗口、切换条目、清空、导入及退出时取消；异步返回后再次检查有效性，旧结果不能弹窗、显示错误或清除新任务的忙碌状态。调用方取消会传递给实际处理任务。
- 固定富文本原样保存也转为纯文本，重新计算容量并更新捕获令牌；ID、来源、复制时间、名称、标签、固定和快捷键保持原值。已经是纯文本且内容相同的保存仍不改动数据。

本地验证：`cargo test -p clipboard-core --locked --offline`，40 项通过，0 失败。新增 4 项 Rust 回归覆盖像素边界、独立/混合/多项图片、合并和替换回滚、异常尺寸头，以及原样保存的格式和元数据。图片 fixture 使用完整有效 PNG，替换早期仅含签名的占位载荷。

新增 6 项 macOS 生命周期回归，使用可控暂停且故意延迟响应取消的 OCR 处理器，覆盖关闭后重开、迟到错误、新旧请求交错、切换选择后返回、清空和导入、调用方取消及缓存结果正常展示。

### 本轮原生 CI 结果

修复代码提交：`3acda5282ee069fe97cc1327cedc6b95c8fea8c6`。

[Clipboard History CI 37219766704](https://github.com/ldjx7/Polyglance/actions/runs/37219766704)：macOS 和 Windows 两个任务全部成功。

- macOS Rust workspace：249 项通过，0 失败；Rust 格式检查通过。
- Windows 公共核心：40 项通过，0 失败。
- macOS 剪贴板专项：40 项全部通过，无跳过；新增 6 项 OCR 生命周期回归在专项和全量测试中均通过。
- Swift 全量 Release：执行 600 项，0 失败，3 项既有 ScreenRecordingPassthroughTests 因 CI 无法生成录屏样本而跳过。
- `./scripts/build-macos-app.sh` 重新生成 UniFFI 绑定并构建独立开发应用，使用 ad-hoc 签名，未使用 `--preserve-permissions`；代码签名和 8 个快捷指令动作元数据验证均通过。
- [macOS 开发包](https://github.com/ldjx7/Polyglance/actions/runs/37219766704/artifacts/11310057958)：大小 7,692,343 字节，保留至 2026-10-11 17:24 UTC。

当前 Linux 环境没有 Swift/AppKit，上述原生结果来自 macOS CI。窗口实际焦点、系统权限和跨应用交互仍按实机清单验收。Windows UI 仍留给 Rust + Slint 重构分支，本轮验证公共核心。本地 Rust 1.95 工具链未安装 Clippy，本轮不将 Clippy 记为已通过。

## macOS 验收准备与性能基线（2026-10-05 UTC）

- 新增 [剪贴板macOS实机验收.md](剪贴板macOS实机验收.md)，包含 29 项操作用例、环境记录、样本入口和缺陷模板。GUI 结果均保留待实测。
- 新增文本、富文本页面、文件引用和无效备份样本；性能程序可生成 500 条和 10000 条合成备份，并使用默认保留期限复核恢复条数。
- 新增 Rust Release 性能示例，测量 10 类数据库操作。Linux 两种规模各完成 40 次采样；完整 JSON 与解读见 [剪贴板性能基线.md](剪贴板性能基线.md)。
- 本地已检查参数范围、导出目录存在时保持原文件不变、样本恢复、文档相对链接、工作流 YAML 和改动空白。
- CI 增加 macOS / Windows 公共核心性能报告及验收材料附件。原生结果待本轮运行完成后补充。

当前执行环境为 Linux，未连接可交互的 Mac 桌面；实际焦点、权限、多屏和耗电验收需要在 Mac 上执行。
