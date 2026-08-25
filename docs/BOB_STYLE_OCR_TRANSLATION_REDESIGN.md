---
document_id: POLYGLANCE-BOB-OCR-TRANSLATION-REDESIGN
title: Bob 风格 OCR 与截图翻译改造规格
version: 1.0.0
status: proposed
created_at: 2026-08-25
last_updated_at: 2026-08-25
language: zh-CN
applies_to:
  - macOS
  - Windows
implementation_order:
  - macOS
  - Windows
normative_keywords:
  MUST: 必须实现
  SHOULD: 推荐实现，除非有明确理由延期
  MAY: 可选实现
related_documents:
  - README.md
  - docs/CROSS_PLATFORM_ARCHITECTURE.md
  - docs/PIXPin_FEATURE_PARITY.md
source_of_truth_scope:
  - OCR 入口与结果窗口
  - OCR 翻译结果卡
  - 截图翻译
  - 原图翻译
---

# Bob 风格 OCR 与截图翻译改造规格

## 0. AI 执行约定

本文既供人阅读，也作为后续 AI 编码、审查和验收的输入。

- 带有稳定 ID 的需求为规范性要求，后续任务、测试和提交信息 SHOULD 引用对应 ID。
- `现状` 描述当前代码行为；`目标` 描述改造完成后的行为，AI 不得将二者混淆。
- `OCR 翻译` 的现有有道式交互 MUST 保留，不得在 Bob 风格改造中删除或替换。
- 当前名为 `截图翻译` 的原位覆盖能力 MUST 保留，但应改名为 `原图翻译`。
- 本阶段不要求复刻 Bob 的全部功能，只对齐本文定义的核心信息架构和交互流程。
- 如本文与旧的功能对照文档冲突，以本文中带需求 ID 的最新决策为准。

## 1. 背景

Polyglance 当前已经具备以下基础能力：

- 平台原生截图与选区处理。
- macOS Vision OCR 与 Windows Media OCR。
- Rust 共享翻译服务和平台原生翻译窗口。
- OCR 原图选字、OCR 翻译结果卡、原图覆盖翻译。
- 翻译流式输出、复制、朗读、窗口置顶及失焦隐藏等基础能力。

当前主要问题不是缺少 OCR 或翻译内核，而是三个入口的职责和命名混在一起：

1. `OCR` 当前更接近 PixPin 的“在原图上选择文字”。
2. `OCR 翻译` 当前采用有道式“原文 + 译文结果卡”。
3. `截图翻译` 当前实际执行的是“译文覆盖在截图原位置”，更符合“原图翻译”的定义。

本次改造将借鉴 Bob 的信息架构：OCR 进入独立文字工作台，截图翻译进入常规悬浮翻译窗口，原图覆盖翻译作为独立功能保留。

## 2. 改造目标

### 2.1 核心目标

- `GOAL-001`：用户能清楚理解并区分 OCR、OCR 翻译、截图翻译和原图翻译。
- `GOAL-002`：OCR 截图后进入以文字编辑、复制和继续处理为中心的独立工作台。
- `GOAL-003`：截图翻译在 OCR 后进入常规悬浮翻译窗口，与划词翻译保持一致。
- `GOAL-004`：保留现有有道式 OCR 翻译卡及其原译文联动能力。
- `GOAL-005`：保留现有原位覆盖译文的能力，并将其明确命名为原图翻译。
- `GOAL-006`：macOS 先建立交互基线，Windows 随后按同一行为契约实现。

### 2.2 非目标

- `NON-GOAL-001`：本阶段不实现 Bob 的完整复刻。
- `NON-GOAL-002`：本阶段不要求同时展示多个翻译服务的结果。
- `NON-GOAL-003`：本阶段不更换现有 OCR 或翻译供应商。
- `NON-GOAL-004`：本阶段不把 AppKit、SwiftUI 或 WPF 窗口逻辑下沉到 Rust。
- `NON-GOAL-005`：本阶段不删除 PixPin 式原图选字能力。

## 3. 术语与最终命名

| 稳定名称 | 定义 | 默认结果界面 | 是否保留现状 |
|---|---|---|---|
| OCR | 截图后识别文字，面向编辑、复制和继续处理 | Bob 式 OCR 文字工作台 | 改造 |
| OCR 翻译 | 截图后识别并翻译，强调原文与译文对照 | 现有有道式结果卡 | 原样保留 |
| 截图翻译 | 截图只是获取原文的方式，结果进入常规翻译窗口 | Bob 式悬浮翻译窗口 | 改造 |
| 原图翻译 | 将译文绘制或覆盖到原图文字对应位置 | 现有原位翻译覆盖层 | 保留并改名 |
| 原图选字 | 在识别后的原图上选择部分文字 | 现有 OCR 选字窗口/贴图 | 作为 OCR 工作台的辅助入口保留 |

### 3.1 禁止使用的混淆命名

- 不得继续把“译文覆盖原图”的功能称为“截图翻译”。
- 不得把“OCR 翻译”和“截图翻译”合并为同一入口。
- 不得因为 OCR 工作台改造而删除“原图选字”。

## 4. 目标信息架构

```text
截图完成
├── OCR
│   └── Bob 式 OCR 文字工作台
│       └── 可选：进入原图选字
├── OCR 翻译
│   └── 现有有道式原文/译文结果卡
├── 截图翻译
│   └── Bob 式常规悬浮翻译窗口
└── 原图翻译
    └── 现有译文原位覆盖层
```

建议使用统一的内部动作枚举表达四条分支：

```yaml
capture_post_actions:
  ocr_workspace:
    user_label: OCR
    output: editable_ocr_workspace
  ocr_translation_card:
    user_label: OCR 翻译
    output: youdao_style_result_card
  screenshot_translation:
    user_label: 截图翻译
    output: standard_floating_translation_window
  in_place_translation:
    user_label: 原图翻译
    output: translated_image_overlay
```

## 5. 功能需求

### 5.1 入口、菜单和快捷键

- `NAV-001`：应用菜单和截图工具栏 MUST 使用第 3 节定义的稳定名称。
- `NAV-002`：现有“截图翻译”快捷键 MUST 继续代表“截图后翻译”，但完成出口改为常规悬浮翻译窗口。
- `NAV-003`：原图翻译 SHOULD 提供独立快捷键设置项，默认 MAY 不分配快捷键。
- `NAV-004`：OCR 翻译的入口、图标、快捷键及现有行为 MUST 保持兼容。
- `NAV-005`：OCR 入口 MUST 打开 OCR 文字工作台，不再默认直接进入原图选字贴图。
- `NAV-006`：OCR 工作台 MUST 提供“原图选字”辅助动作，以保留当前能力。
- `NAV-007`：macOS 和 Windows MUST 使用一致的用户可见名称、入口分组和基础图标语义。

### 5.2 OCR 翻译：保留有道式结果卡

- `OTR-001`：OCR 翻译 MUST 继续执行“截图 → OCR → 翻译 → 结果卡”。
- `OTR-002`：结果卡 MUST 保留原图、原文、译文三种显示状态。
- `OTR-003`：结果卡 MUST 保留复制、贴图、关闭和右键菜单能力。
- `OTR-004`：支持流式翻译的服务 MUST 继续流式更新结果卡。
- `OTR-005`：macOS MUST 保留鼠标悬浮时原文与译文对应片段联动高亮。
- `OTR-006`：Windows SHOULD 补齐与 macOS 一致的原译文片段联动高亮。
- `OTR-007`：Bob 风格改造不得改变该功能的产品定位或默认结果界面。

### 5.3 截图翻译：Bob 式悬浮翻译窗口

- `STR-001`：截图翻译 MUST 执行“截图 → OCR → 填入常规翻译窗口 → 自动翻译”。
- `STR-002`：截图翻译 MUST 使用用户当前选择的翻译服务和语言设置。
- `STR-003`：识别出的文字 MUST 作为可编辑原文填入常规翻译窗口。
- `STR-004`：翻译窗口 MUST 自动开始翻译，无需用户再次点击翻译按钮。
- `STR-005`：翻译服务支持流式输出时，窗口 MUST 流式展示译文。
- `STR-006`：结果窗口 SHOULD 出现在截图选区附近；空间不足时 MUST 保持在当前屏幕可见区域内。
- `STR-007`：窗口未置顶时，点击外部 SHOULD 自动隐藏；置顶后 MUST 保持可见。
- `STR-008`：窗口 MUST 保留复制、朗读、语言切换、清空、重试和置顶等常规翻译能力。
- `STR-009`：截图翻译默认不得把译文覆盖在图片上。
- `STR-010`：OCR 无结果时 MUST 给出明确错误，不得打开空白翻译窗口。
- `STR-011`：用户取消截图或 OCR/翻译任务后，不得出现迟到的旧结果窗口。

### 5.4 原图翻译：保留现有覆盖模式

- `IPT-001`：当前原位覆盖译文的实现 MUST 保留。
- `IPT-002`：所有用户可见名称 MUST 从“截图翻译”调整为“原图翻译”。
- `IPT-003`：原图翻译 MUST 继续支持查看原文、复制译文、贴图、保存、刷新和关闭等现有能力。
- `IPT-004`：原图翻译和截图翻译 MUST 使用独立动作及独立快捷键配置，不能根据隐藏设置暗中切换。
- `IPT-005`：重命名不得破坏已保存的翻译供应商、目标语言或贴图历史。

### 5.5 OCR：Bob 式文字工作台

#### 5.5.1 基础窗口

- `OCR-001`：截图 OCR 完成后 MUST 打开独立 OCR 文字工作台。
- `OCR-002`：工作台主体 MUST 是可选择、可编辑、可复制的纯文本区域。
- `OCR-003`：工作台 SHOULD 是紧凑悬浮窗口，而不是固定尺寸的大型图片查看器。
- `OCR-004`：窗口 MUST 支持调整大小，并设置合理的最小宽高和最大默认高度。
- `OCR-005`：窗口未固定时，点击外部 SHOULD 自动隐藏；固定后 MUST 保持显示。
- `OCR-006`：窗口 MUST 支持 Esc 或标准关闭操作。
- `OCR-007`：窗口 SHOULD 在原截图选区附近显示，并确保完整位于可见屏幕区域内。

#### 5.5.2 内容与操作

- `OCR-010`：识别结果 MUST 尽可能保留段落和换行，不得无条件拼接为单行。
- `OCR-011`：工作台 MUST 提供“复制全部”。
- `OCR-012`：工作台 MUST 支持用户选择部分文字后复制。
- `OCR-013`：工作台 MUST 提供“翻译”操作，并把当前选中文字或全文送入常规翻译窗口。
- `OCR-014`：工作台 MUST 提供“重新识别”。
- `OCR-015`：工作台 MUST 提供“重新截图”。
- `OCR-016`：工作台 MUST 提供“原图选字”，进入现有 PixPin 式原图文字选择界面。
- `OCR-017`：OCR 无结果时 MUST 给出明确错误和重新截图入口。
- `OCR-018`：OCR 识别本身 MUST 保持本地执行；只有用户执行翻译时才允许发送识别文本到当前翻译服务。

#### 5.5.3 建议设置

- `OCR-020`：工作台 SHOULD 提供“自动复制”开关。
- `OCR-021`：自动复制开关的建议默认值为开启，但最终值 MUST 可在设置中修改。
- `OCR-022`：工作台 SHOULD 显示当前识别语言或自动检测状态。
- `OCR-023`：工作台 SHOULD 提供 OCR 设置快捷入口。
- `OCR-024`：工作台 MAY 展示当前 OCR 后端；本阶段不要求用户切换多个 OCR 服务。

#### 5.5.4 后续增强

- `OCR-FUTURE-001`：连续识别，将多次截图结果追加到同一工作台。
- `OCR-FUTURE-002`：静默 OCR，不显示窗口并直接复制识别结果。
- `OCR-FUTURE-003`：访达/文件管理器选图 OCR，支持单张和多张图片。
- `OCR-FUTURE-004`：二维码识别及复制、打开链接、Wi-Fi 和联系人等结构化动作。
- `OCR-FUTURE-005`：更完善的智能分段、多栏阅读顺序和表格识别。

以上 `OCR-FUTURE-*` 不属于第一阶段的阻塞验收项。

## 6. 状态机

### 6.1 截图翻译状态机

```text
idle
  → selecting
  → recognizing
  → presenting_translation_window
  → translating_streaming
  → completed
```

异常分支：

```text
selecting → cancelled
recognizing → no_text | failed | cancelled
translating_streaming → failed | cancelled | completed
```

状态约束：

- 同一代截图任务只能产生一个结果窗口。
- 新任务开始后，旧任务回调 MUST 被取消或通过 generation token 丢弃。
- OCR 失败不得清空用户原有翻译窗口内容，除非该窗口已明确进入本次截图翻译会话。

### 6.2 OCR 工作台状态机

```text
hidden
  → recognizing
  → presenting
  → editing
  ├── copying
  ├── opening_translation
  ├── opening_image_selection
  ├── retrying
  └── closing
```

建议数据模型：

```yaml
ocr_workspace_state:
  source_image_reference: optional
  recognized_text: string
  edited_text: string
  detected_language: optional_string
  is_recognizing: boolean
  is_pinned: boolean
  auto_copy_enabled: boolean
  error_message: optional_string
  source_selection_frame: optional_rect
  generation: integer
```

## 7. 窗口布局契约

### 7.1 OCR 工作台布局

```text
┌──────────────────────────────────────────┐
│ OCR       自动检测        固定  设置  × │
├──────────────────────────────────────────┤
│                                          │
│ 可编辑 OCR 文字区域                       │
│ 保留段落与换行                            │
│                                          │
├──────────────────────────────────────────┤
│ 原图选字  重新截图  重新识别   翻译  复制 │
└──────────────────────────────────────────┘
```

布局要求：

- 顶部只放状态和低频窗口操作。
- 中间文字区域占据主要空间。
- 底部放面向结果的动作。
- 按钮应使用平台原生图标，悬浮提示只显示短标题。
- 窄窗口下允许动作折叠到更多菜单，但复制和翻译 SHOULD 保持可见。

### 7.2 截图翻译窗口布局

截图翻译复用常规翻译窗口，不新增另一套结果卡。窗口至少包含：

- 原文编辑区。
- 目标语言选择。
- 流式译文区。
- 原文和译文复制、朗读。
- 清空、重试、置顶和关闭。

## 8. 平台实现映射

### 8.1 macOS

#### 复用

- `OCRService` 与 `VisionOCRBackend`。
- `TranslatorViewModel`、`TranslationView` 和现有悬浮翻译面板。
- `OCRTranslationPinContentView`，继续承载有道式 OCR 翻译。
- `ScreenTranslationCoordinator` 与覆盖层能力，调整为原图翻译职责。
- `OCRSelectionResultView`，作为 OCR 工作台中的原图选字辅助界面。

#### 建议新增或调整

- 新增 `OCRWorkspaceViewModel`。
- 新增 `OCRWorkspaceView`。
- 新增 `OCRWorkspaceWindowController` 或等价窗口协调器。
- `ScreenshotCoordinator` 将 OCR 动作路由到 OCR 工作台。
- `AppDelegate` 增加“把截图 OCR 文字送入常规翻译面板”的流程。
- 将当前 `.screenTranslation` 内部语义拆成 `.screenshotTranslation` 和 `.inPlaceTranslation`。
- 截图翻译完成后使用 `TranslatorViewModel.applyCapturedText`，显示面板并触发翻译。

### 8.2 Windows

#### 复用

- `WindowsMediaOcr` 与 `OcrTextDocument`。
- `MainWindow.SetAndTranslate` 及现有翻译服务。
- `ScreenTranslationWindow`，继续承载当前 OCR 翻译结果卡，后续补齐交互。
- `InPlaceTranslationOverlayWindow`，调整为原图翻译职责。
- `OcrSelectionWindow` 的原图文字选择能力。

#### 建议新增或调整

- 新增 `OcrWorkspaceWindow`，或将现有 `OcrSelectionWindow` 拆分为工作台与原图选字两个界面。
- `ScreenSelectionWindow` 将 OCR 动作路由到工作台。
- `App` 为截图窗口提供将 OCR 结果交给主翻译窗口的回调或服务。
- 将 `ScreenshotCaptureIntent.ScreenTranslation` 的用户语义改为 Bob 式截图翻译。
- 新增独立的 `InPlaceTranslation` intent，继续打开现有覆盖层。

### 8.3 Rust 与跨平台边界

- 第一阶段 SHOULD 不修改 Rust FFI 合约。
- OCR 捕获、OCR 后端、窗口位置、窗口生命周期继续由平台原生层负责。
- 翻译请求、供应商配置和可复用文本处理继续由 Rust 共享内核负责。
- 如果未来加入跨平台 OCR 历史或连续识别记录，可以再定义平台无关数据模型，不应提前下沉窗口状态。

## 9. 分阶段实施计划

### Phase 1：名称与流程分流

目标：建立正确的信息架构，不改变 OCR 翻译。

- `P1-001`：保留 OCR 翻译现状。
- `P1-002`：将当前原位覆盖能力的用户名称改为原图翻译。
- `P1-003`：新增 Bob 式截图翻译路由，进入常规悬浮翻译窗口。
- `P1-004`：调整菜单、工具栏、快捷键设置及内部 action/intent。
- `P1-005`：补充状态取消与迟到结果防护。

完成标准：四个入口可以被用户和代码明确区分。

### Phase 2：基础 OCR 文字工作台

- `P2-001`：实现独立、可编辑的 OCR 文字窗口。
- `P2-002`：实现复制全部、复制选中、翻译、重新识别、重新截图。
- `P2-003`：接入置顶和失焦隐藏。
- `P2-004`：保留原图选字入口。
- `P2-005`：实现自动复制设置。

完成标准：OCR 默认流程不依赖图片贴图，用户可直接处理识别文字。

### Phase 3：macOS 验收与 Windows 对齐

- `P3-001`：先在 macOS 完成人工交互验收。
- `P3-002`：Windows 按相同需求 ID 实现，不创造 Windows 独有流程。
- `P3-003`：统一名称、菜单分组、图标语义、快捷键和错误提示。
- `P3-004`：补齐 Windows OCR 翻译原译文联动高亮。

### Phase 4：Bob OCR 增强能力

- 连续 OCR。
- 静默 OCR。
- 文件 OCR。
- 二维码识别。
- 智能分段增强。
- OCR 历史和多图管理。

## 10. 验收标准

### 10.1 截图翻译

- `AC-STR-001`：Given 用户选择截图翻译，When 框选含文字区域，Then OCR 原文进入常规翻译窗口并自动翻译。
- `AC-STR-002`：Given 翻译服务支持流式输出，When 翻译进行中，Then 译文逐步更新而不是等待完整结果。
- `AC-STR-003`：Given 窗口未置顶，When 用户点击其他应用，Then 窗口自动隐藏。
- `AC-STR-004`：Given 窗口已置顶，When 用户点击其他应用，Then 窗口保持显示。
- `AC-STR-005`：Given 截图中没有文字，When OCR 完成，Then 显示错误且不打开空白翻译窗口。
- `AC-STR-006`：Given 用户连续触发两次截图翻译，When第一次任务较晚返回，Then 第一次结果不得覆盖第二次结果。

### 10.2 OCR 翻译

- `AC-OTR-001`：Given 用户选择 OCR 翻译，When 翻译完成，Then 仍显示现有有道式结果卡。
- `AC-OTR-002`：Given 用户切换原图、原文、译文，Then 三种内容均正确显示。
- `AC-OTR-003`：Given 用户在 macOS 悬浮原文片段，Then 对应译文片段同步高亮，反向亦然。

### 10.3 原图翻译

- `AC-IPT-001`：Given 用户选择原图翻译，When 翻译完成，Then 译文覆盖在图片对应位置。
- `AC-IPT-002`：Given 版本升级，When 用户查看菜单和快捷键设置，Then 该功能显示为原图翻译。

### 10.4 OCR 工作台

- `AC-OCR-001`：Given 用户选择 OCR，When 识别成功，Then 打开含可编辑文字的独立 OCR 工作台。
- `AC-OCR-002`：Given 用户选择部分文字，When 点击复制，Then 只复制选中文字。
- `AC-OCR-003`：Given 未选择文字，When 点击复制全部，Then 复制完整 OCR 结果。
- `AC-OCR-004`：Given 用户编辑过 OCR 结果，When 点击翻译，Then 翻译编辑后的文字。
- `AC-OCR-005`：Given 用户点击原图选字，Then 打开现有图片文字选择界面且识别结果一致。
- `AC-OCR-006`：Given 自动复制开启，When OCR 成功，Then 完整结果写入剪贴板一次。
- `AC-OCR-007`：Given OCR 失败或无文字，Then 工作台提供错误状态和重新截图入口。

### 10.5 跨平台一致性

- `AC-XP-001`：相同动作在 macOS 和 Windows 使用相同中文名称。
- `AC-XP-002`：相同动作在两个平台产生相同类型的结果窗口。
- `AC-XP-003`：Windows 不得保留“自动滚动/完成”等与 macOS 信息架构不一致的额外主流程按钮。
- `AC-XP-004`：平台可使用不同原生控件，但操作顺序、默认行为和错误语义必须一致。

## 11. 测试要求

### 11.1 单元测试

- action/intent 到结果界面的映射。
- OCR 工作台状态变更。
- 新旧截图任务 generation 隔离。
- 空 OCR、取消、失败和重试。
- 自动复制开关。
- 窗口位置限制在目标屏幕可见范围。

### 11.2 集成测试

- 截图翻译能够复用当前翻译供应商和目标语言。
- OCR 翻译仍使用原有结果卡。
- 原图翻译重命名后行为不回归。
- OCR 工作台到常规翻译窗口的数据传递。
- macOS 和 Windows 的四入口行为矩阵一致。

### 11.3 人工验收

- 单屏、多屏和不同缩放比例。
- 中文、英文、日文及中英混排。
- 长段落和无换行文本。
- 翻译窗口已显示、已置顶和隐藏三种状态。
- 连续快速触发、取消和切换动作。
- 无屏幕权限、OCR 无结果和网络翻译失败。

## 12. 风险与缓解

| 风险 ID | 风险 | 缓解措施 |
|---|---|---|
| RISK-001 | 截图完成后翻译窗口失焦而立即隐藏 | 先写入状态并激活窗口，再启用失焦隐藏判断 |
| RISK-002 | 旧 OCR/翻译异步任务覆盖新任务 | 使用任务取消和 generation token 双重保护 |
| RISK-003 | 重命名导致快捷键语义迁移错误 | 迁移时保留现有截图翻译快捷键给新流程，原图翻译新增独立配置 |
| RISK-004 | OCR 工作台与原图选字出现重复状态 | 两者共享同一个 OCR document，不重复识别 |
| RISK-005 | Windows 为追求外观一致而偏离原生体验 | 对齐行为契约和设计令牌，不要求像素级复制 AppKit |
| RISK-006 | 功能范围膨胀为完整 Bob 复刻 | 第一阶段只实现第 9 节 Phase 1–3，增强能力单独排期 |

## 13. 改造规模评估

| 子项 | 规模 | 复用程度 | 主要风险 |
|---|---|---|---|
| 截图翻译进入常规翻译窗口 | 小到中 | 高 | 窗口激活、任务取消、选区附近定位 |
| 原图翻译重命名与动作拆分 | 小 | 高 | 快捷键和配置迁移 |
| macOS 基础 OCR 工作台 | 中 | 中到高 | AppKit/SwiftUI 窗口生命周期 |
| Windows 基础 OCR 工作台 | 中 | 中 | WPF 界面拆分与跨平台行为对齐 |
| 两端完整交互验收 | 中到大 | 中 | 多屏、焦点、剪贴板和异步竞态 |
| 连续 OCR、文件 OCR、二维码、智能分段 | 大 | 视能力而定 | 范围和状态复杂度 |

总体判断：核心改造不需要重写 Rust、OCR 或翻译内核；macOS 单端属于中等规模，两端同时完成属于中到大规模。

## 14. AI 实施清单

```yaml
implementation_manifest:
  preserve_without_regression:
    - id: OTR-001..OTR-007
      component: OCR 翻译有道式结果卡
    - id: IPT-001
      component: 当前原位译文覆盖能力
    - id: NAV-006
      component: PixPin 式原图选字

  rename:
    - from: 截图翻译
      to: 原图翻译
      applies_to: 当前原位译文覆盖能力

  create_or_rewire:
    - action: screenshot_translation
      pipeline: screenshot -> OCR -> standard translation window -> auto translate
    - action: ocr_workspace
      pipeline: screenshot -> OCR -> editable OCR workspace

  phase_1_required:
    - P1-001
    - P1-002
    - P1-003
    - P1-004
    - P1-005

  phase_2_required:
    - P2-001
    - P2-002
    - P2-003
    - P2-004
    - P2-005

  deferred:
    - OCR-FUTURE-001
    - OCR-FUTURE-002
    - OCR-FUTURE-003
    - OCR-FUTURE-004
    - OCR-FUTURE-005

  platform_order:
    - macOS implementation
    - macOS manual acceptance
    - Windows implementation
    - cross-platform parity acceptance

  definition_of_done:
    - all Phase 1 and Phase 2 requirements implemented
    - all AC-STR, AC-OTR, AC-IPT, AC-OCR and AC-XP criteria pass
    - OCR translation card has no regression
    - original-image translation remains accessible
    - macOS and Windows expose the same four user-facing actions
```

## 15. 决策记录

| 决策 ID | 日期 | 决策 |
|---|---|---|
| DEC-001 | 2026-08-25 | OCR 翻译保留现有有道式交互，不纳入 Bob 风格替换范围 |
| DEC-002 | 2026-08-25 | 当前原位截图翻译保留并改名为原图翻译 |
| DEC-003 | 2026-08-25 | 新截图翻译采用 Bob 式流程，进入常规悬浮翻译窗口 |
| DEC-004 | 2026-08-25 | OCR 默认进入 Bob 式文字工作台，原图选字作为辅助入口保留 |
| DEC-005 | 2026-08-25 | macOS 先完成交互基线，Windows 再严格对齐 |
