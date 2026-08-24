# Polyglance 跨平台架构规范

本文档是**强约束**，不是建议。任何人（包括 AI 助手）在本仓库新增或修改代码前必须遵守。

它要解决的问题只有一个：**防止同一份逻辑被在三个平台各写一遍，以及防止平台代码渗进共享内核。** 一旦越界，后果不是"风格不一致"，而是三份实现开始各自演化，行为悄悄分叉，最终谁都不敢动。

---

## 1. 分层与依赖方向

```
┌─ 第 2 层：平台应用 ─────────────────────────────────┐
│  macOS: Swift + AppKit/SwiftUI                      │
│  Windows: C# (.NET) + WPF                           │
│  Linux: 见 §7，默认不开发                            │
└──────────────────┬──────────────────────────────────┘
                   │ 只能向下依赖
┌─ 第 1 层：FFI 绑定层 ───────────────────────────────┐
│  translator-uniffi   (UniFFI → Swift)               │
│  未来: polyglance-cabi (C ABI → .NET LibraryImport) │
└──────────────────┬──────────────────────────────────┘
                   │ 只能向下依赖
┌─ 第 0 层：共享内核（纯 Rust，无平台依赖）──────────────┐
│  capture-core         截图/贴图/长截图/录制的纯逻辑    │
│  translator-core      翻译请求模型与校验              │
│  translator-providers 各翻译服务与流式解析            │
└─────────────────────────────────────────────────────┘
```

**硬性规则：**

1. 第 0 层**不得**依赖第 1 层，**不得**依赖任何 GUI/图形/系统框架，**不得**依赖 uniffi。
   - 理由：Windows 走 C ABI + .NET，不经过 uniffi。第 0 层一旦沾上 uniffi，Windows 就得为 Swift 的绑定机制买单。
2. 第 1 层是**薄转换层**，只做类型映射与运行时托管，**不得**包含业务逻辑或策略判断。
   - 枚举/记录转换所需的 `match` 属于类型映射，是正当的；判定服务、构造配置、决定隐私策略则不是。
3. 第 2 层**不得**重新实现第 0 层已有的任何逻辑，只能调用。

---

## 2. 归属判定规则

新增一段代码时，先问这一个问题：

> **能不能在没有窗口、没有屏幕、没有图像对象的情况下，为它写一个单元测试？**

- **能** → 必须放第 0 层（Rust）。不允许"先在平台层写着，以后再搬"。
- **不能** → 放第 2 层（平台层）。

第二个问题用来切分灰色地带：

> **这段代码里的"平台部分"能不能收窄成一次数据传递？**

能的话就拆成两半：平台负责取得/写回数据，Rust 负责算。已有先例：

| 功能 | 平台负责 | Rust 负责 |
|---|---|---|
| 长截图拼接 | CGImage ⇄ RGBA 字节 的编解码 | 重叠检测、偏移搜索、帧拼接、内存上限 |
| 截屏翻译排版 | Vision OCR 调用、像素取色 | 行→段落聚合、包围盒 |
| 录制编码 | AVFoundation 编码器 | 档位表、输出尺寸、码率、帧率归一化 |
| 流式翻译 | URLSession 传输 | SSE 解析、请求体构造、发射节流 |

---

## 3. 各平台技术选型

### 共享内核
**Rust**（edition 2024）。不引入 GUI 相关依赖。

### macOS
**Swift + AppKit/SwiftUI**，FFI 走 **UniFFI**。这是既有实现，不变更。

### Windows
**C# (.NET) + WPF**，FFI 走 **C ABI + `LibraryImport`**。

**明确不用 WinUI 3。** 本应用的命门是逐像素透明 + 任意屏幕坐标定位 + 点击穿透的悬浮窗（截图选区、贴图、截屏翻译原位覆盖）。WinUI 3 在这块支持薄弱，而 WPF 的 Win32 互操作生态成熟，可直接用 `WS_EX_LAYERED` + `UpdateLayeredWindow`，同时通过 CsWinRT 使用 `Windows.Graphics.Capture` 与 `Windows.Media.Ocr`。

若需命令行入口，出**两个 exe**（GUI 子系统 + 控制台子系统），共享同一份 Rust 内核；不要用 GUI 子系统硬接控制台。

### Linux
**默认不开发。** 原因见 §7。若确定要做，只支持 X11，并在 README 明确标注功能缺失范围。

### 关于跨平台 UI 框架

Tauri、Flutter、Qt、Avalonia 等方案**已评估，不采用**，理由记录在此以免反复论证：

- 本应用约 95% 的代码是屏幕交互（捕获、OCR、悬浮窗定位、逐像素绘制、编码），常规界面只有约 850 行。跨平台 UI 框架统一的正是最小的那部分，而捕获、OCR、全局快捷键、编码在任何框架下仍需按平台实现。
- 贴图窗口可同时存在任意多个。Web 系方案每个窗口是一个 WebView（几十 MB 量级），原生分层窗口是亚 MB 量级。
- 截图放大镜需要以裸像素表面高频重绘，Web 的渲染模型要求每帧把像素推过 IPC，属于模型错配。
- Linux 的缺失是**协议层面**的（见 §7），任何 UI 框架都给不了平台不暴露的能力，"一份代码同时覆盖 Windows 与 Linux"的前提本身不成立。

**重新评估的触发条件：** 若产品重心从"屏幕工具"转向"翻译工作台"（历史记录、词库、文档翻译、批量任务等常规界面成为主体），此结论应重新审视。届时 Qt 或 Avalonia 比 Web 系方案更契合，因为它们提供真正的绘制表面与廉价窗口。

---

## 4. 归属清单

### 必须在 Rust（第 0 层）

- 一切几何计算：选区、裁剪、缩放、工具栏定位、贴图尺寸与位置
- 一切图像**算法**：长截图重叠检测与拼接、取色、段落聚合
- 一切策略表：录制档位、码率、帧率选项与归一化
- 一切文本处理：原文译文对齐、分句、CJK 判定、空白判定
- 一切协议处理：翻译请求构造、响应解析、SSE 流式解析
- 一切上限与校验：像素数、内存、帧数、参数合法性

### 必须在平台层（第 2 层）

- 屏幕捕获 API 调用（ScreenCaptureKit / Windows.Graphics.Capture / 无）
- OCR 引擎调用（Vision / Windows.Media.Ocr / 需自带引擎）
- 全局快捷键注册（Carbon / RegisterHotKey / 无标准方案）
- 窗口、绘制、事件循环、菜单、托盘
- 图像编解码（CGImage / WIC ⇄ RGBA 字节）
- 音视频编码器（AVFoundation / Media Foundation）
- 配置持久化（UserDefaults / 注册表或 JSON）
- 凭据存储（Keychain / DPAPI）
- 权限请求与提示文案
- 所有面向用户的字符串与本地化

### 明确不要下沉到 Rust

- **UI 文案**：属于平台的本地化体系
- **键位码**：macOS 虚拟键码与 Windows VK 码命名空间不同，模型可共享但取值不可，需要重新设计而不是搬运
- **极小的胶水**（< 50 行且无分支）：FFI 开销大于收益

---

## 5. FFI 约定

1. **像素缓冲统一为紧凑排列的 8 位 RGBA**（无行填充）。平台负责转换到这个格式，Rust 不处理平台位图布局。
2. **几何统一为 f64**。Rust 侧的 `Rect` 精确复刻 CoreGraphics 语义（null 哨兵、半开区间包含、向外取整、inset 塌缩），三个平台共用同一套判定。
3. **文本偏移统一为 UTF-16 码元**。macOS 的 `NSRange` 直接对应，其他平台自行换算。
4. **有状态对象**用互斥量包装后以对象形式导出（先例：`LongScreenshotStitcher`），不要用全局状态。
5. **错误跨 FFI 传枚举，不传字符串**。用户可见文案在平台层生成。
6. 第 1 层每加一个类型，必须同时提供双向转换，且**不得**在转换中夹带逻辑。
7. **异步与运行时分属不同层。** 第 0 层可以暴露 `async fn`，但**不得持有运行时**；运行时由第 1 层拥有并负责桥接到平台的调用约定。现状：`translator-providers` 有 async 接口且零 Runtime，唯一的 tokio Runtime 在 `translator-uniffi`。Windows 绑定需自备运行时策略，**不要**把 Runtime 塞进第 0 层，否则 macOS 会出现两个。
8. **跨界是有成本的，要按成本设计接口。** 跨 FFI 的缓冲区会被完整拷贝一次（长截图 `render()` 即为此多付一次拷贝）。因此：**FFI 调用不得出现在逐帧绘制路径上**；大缓冲跨界前先估算拷贝量；高频小调用应合并成一次批量调用。

---

## 6. 构建管线

每个平台都必须有**一个脚本**把 Rust 内核变成该平台可链接的产物，不允许各处手工拼装。

**macOS（既有）**：`scripts/build-macos-core.sh`

1. `cargo build --release -p translator-uniffi -p uniffi-bindgen`
2. `uniffi-bindgen` 从 dylib 生成 Swift 绑定
3. 产物拷入 `apps/macos/Generated/`（Swift 源 + C 头 + modulemap）与 `apps/macos/Libraries/`（静态库）

**Windows（已建立）**：`scripts/build-windows-core.ps1` 与 `scripts/build-windows-app.ps1`

1. `cargo build --release -p polyglance-cabi` 生成 `polyglance_cabi.dll`
2. `Polyglance.Core/Native/NativeMethods.cs` 通过 `LibraryImport` 声明稳定 C ABI
3. `dotnet publish` 生成 .NET 9 WPF 自包含目录，并复制 Rust DLL
4. Windows CI 在 `windows-2025` 上运行 Rust/C# 测试和完整构建；tag 发布同时生成免安装 Portable ZIP、当前用户级 Inno Setup 安装包与 `appcast-windows.xml`
5. 安装包使用固定 `AppId` 支持原位升级，在“应用和功能”注册卸载入口；卸载清理程序文件、快捷方式和开机自启项，但保留 `%APPDATA%\Polyglance` 与 `%LOCALAPPDATA%\Polyglance` 用户数据

**规则：**

- 生成的绑定代码**属于产物，不手工编辑**。需要改就改 Rust 源再重新生成。
- 平台工程不得直接 `cargo build` 拼路径，一律走脚本，保证 CI 与本地一致。
- 新增 FFI 类型或函数后，必须重新运行脚本并提交更新后的绑定产物。

---

## 7. 平台能力矩阵

| 能力 | macOS | Windows | Linux/X11 | Linux/Wayland |
|---|---|---|---|---|
| 屏幕捕获 | ScreenCaptureKit（需 TCC 授权） | DXGI / BitBlt（**无需授权**）；WGC 见下注 | XShm | 仅 portal + PipeWire，**每次弹授权** |
| 系统 OCR | Vision | Windows.Media.Ocr | 无，需自带 | 无，需自带 |
| 全局快捷键 | Carbon RegisterEventHotKey | RegisterHotKey | XGrabKey | **无标准方案** |
| 绝对坐标悬浮窗 | 支持 | WS_EX_LAYERED | override-redirect | **协议禁止** |
| 读取他应用选中文字 | AX（需授权） | UI Automation（免授权） | AT-SPI（不可靠） | AT-SPI（不可靠） |

**Windows 注意**：Windows 11 上 `Windows.Graphics.Capture` 默认会给捕获区域画黄色高亮边框，去除需调用 `GraphicsCaptureAccess.RequestAccessAsync(Borderless)`，那会弹一次确认。静态截图应走 GDI BitBlt 或 Desktop Duplication（无边框、无提示），录屏再考虑 WGC。

**Wayland 的两条硬限制**（不是工程量问题，是协议层面做不到）：

- 客户端**无法获知或设置自己的全局屏幕坐标** → 贴图钉在截取位置、译文原位覆盖无法实现（wlr-layer-shell 仅 Sway/Hyprland/KDE 支持，GNOME 不支持）
- **没有标准全局快捷键接口** → 核心交互入口不成立

而 Wayland 已是 Ubuntu/Fedora/GNOME/KDE 的默认。因此 Linux 版若要做，必须明确只支持 X11 并接受功能缺失。

---

## 8. 新增与移植的流程

### 8.1 新增一个功能

1. 用 §2 的判定规则把功能拆成"纯逻辑"与"平台调用"两半，**先拆再写**。
2. 纯逻辑部分在第 0 层落地：选一个既有模块，放不进去才新建；同时写单元测试。
3. 需要暴露给平台时，在第 1 层加镜像类型与转发函数（只做转换），重新运行 §6 的脚本。
4. 平台层只写 API 调用、窗口与绘制，通过 FFI 取用逻辑结果。
5. 禁止"先在平台层写完，以后再搬"——实践中不会再搬。

### 8.2 测试归属

- **第 0 层：必须有单元测试。** 这是逻辑正确性的唯一归属地。
- **第 1 层：不写测试。** 它只有类型转换，由两侧的测试间接覆盖。
- **第 2 层：只测平台绑定与交互**（窗口行为、权限分支、事件流），**不重复测已下沉的逻辑**——重复的断言会在下一次迁移时变成阻力。
- 迁移期间例外：原有平台测试**必须原样保留并通过**，作为行为等价的证据；确认稳定后再决定是否精简。

### 8.3 下沉既有代码

从平台层往 Rust 下沉时，按以下顺序执行，**不得跳步**：

1. **先核对平台 API 的真实语义，不要凭直觉。** 写一个最小程序打印实际行为再动手。
   本仓库已因此拦下四处会造成静默行为漂移的差异：
   - `CGRectIntersection` 对边缘相接/空矩形返回**零面积矩形**而非 null，判据是 `min > max` 而非 `>=`
   - Foundation 的 `whitespacesAndNewlines` **包含 U+200B**，Rust 的 `char::is_whitespace` 不包含
   - Swift `Character` 是字形簇，`chars()` 是标量：`漢︀` 取首标量得 U+6F22，取末标量得 U+FE00
   - `CGRectUnion` **不跳过**空矩形，只跳过 null
2. **平台层改成转发层，公开 API 一字不改**，调用点零改动。
3. **原有平台测试一行不改地跑通**——这是行为等价的唯一可接受证据。
4. Rust 侧补齐单元测试，覆盖平台测试没覆盖的分支。

**关于测试的红线：** 不得为了让测试通过而修改被测行为。若某条测试确实固化了错误行为，必须在提交信息中说明"为什么原断言是错的"，并确认该测试保护的真实约束由其他测试覆盖。

> 本仓库真实发生过反例：一个标题为 `fix(test):` 的提交删掉了 `accessibilityPermissionRequest()` 调用以迎合断言，导致未授权时不再弹出系统授权框，用户无从授权。

---

## 9. 红线

以下任何一条出现，改动一律不予合入：

1. 第 0 层出现 `use` 任何 GUI/图形/系统框架，或依赖 uniffi
2. 同一段业务逻辑在两个平台各存在一份实现
3. 平台层出现几何计算、图像算法、协议解析、策略表
4. 为通过测试而修改产品行为
5. 下沉逻辑时未跑通原有平台测试就宣称完成
6. 在第 1 层写业务判断
7. 未经真机验证就把涉及权限、窗口层级、屏幕捕获的改动发版

---

## 10. 评审清单

新增/修改代码时逐条确认：

- [ ] 这段逻辑能脱离窗口和屏幕做单测吗？能的话它在 Rust 里吗？
- [ ] 有没有在另一个平台已经存在同样的实现？
- [ ] 第 0 层的依赖是否仍然只有纯计算库？
- [ ] FFI 新增类型是否只做转换、不含逻辑？
- [ ] 是否核对过所依赖平台 API 的真实语义（而非凭印象）？
- [ ] 原有平台测试是否未经修改即通过？
- [ ] 若修改了任何测试断言，是否说明了原断言为何是错的？
- [ ] 涉及权限/窗口/捕获的改动，是否真机验证过？

---

## 11. 当前状态

截至 v0.0.4-beta.2 后的开发版本：

- 共享内核约 6,150 行，macOS 平台层约 18,000 行，共享比例约 25%
- `capture-core` 模块：`rect` `geometry` `pin` `alignment` `layout` `recording` `stitch` `text`
- `translator-providers` 含 `dispatch` `google` `microsoft` `openai` `streaming`；服务分发与隐私策略在 `dispatch`，FFI 层只保留运行时与类型映射
- `polyglance-cabi` 已提供翻译、文本布局/对齐、录屏策略、长截图拼接和选区几何 C ABI；所有状态型入口隔离 panic，字节缓冲区使用 boxed slice 所有权协议
- Windows WPF 原型已接入托盘、快捷键、截图/OCR/贴图/录屏/长截图；配置 JSON 与 DPAPI 凭据分离，并由 Windows CI 验证

**有意留在平台层**（不是待办，不要"顺手"迁走）：

- 图像编解码、屏幕捕获、OCR 调用、音视频编码器
- 配置持久化与凭据存储
- 全部 UI 文案与键位码

**暂时留在平台层，属于待下沉：**

| 待迁 | 现状 | 阻塞点 |
|---|---|---|
| 截屏翻译取色 | `ScreenTranslationColorSampler` 在 Swift，用 CGContext 采样 | 需先定义"平台递 RGBA buffer、Rust 算颜色"的接口 |
| 流式翻译传输层 | Swift URLSession | 需要跨 FFI 的异步流与取消语义，建议与 Windows 端一并设计 |
