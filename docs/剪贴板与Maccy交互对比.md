# 剪贴板与 Maccy 交互对比

核对日期：2026-10-12。

- Maccy：固定对比版本 **2.7.1**，提交 `eb03ebac3bbf24044c797c06f4304b74e3187835`。结论依据该版本源码，不自动推广到后续版本。
- Polyglance：本 PR 的 macOS 实现，包含通用设置开关、快速浮窗和管理窗口。已发布的 `v0.1.5-beta.1` 不包含这些交互调整。
- 方法：核对窗口、事件处理、设置默认值及调用路径。原生构建和测试状态见 PR；本文没有同机 GUI、耗电、识别率或响应时间对测结论，实机项目仍需执行。

## 1. 交互定位与已实现范围

日常快捷键和菜单中的剪贴板历史打开快速浮窗：直接输入搜索，单击或快捷键执行复制、粘贴，成功后关闭。管理历史按钮和 Command+M 进入完整管理窗口，继续支持多选、编辑、OCR、翻译、贴图和备份。菜单也可直接打开管理窗口。

两种界面共用历史服务和同一面板，切换时保留原粘贴目标。快速浮窗单击执行；管理窗口单击只选择，多选手势仍用于管理操作。复制内容仍默认关闭，开启后只保存在本机。

本次还统一了鼠标与键盘的动作表、搜索焦点、快速窗口数字编号和循环选择规则。自动粘贴开启时，Option 会切换为仅复制；纯文本粘贴改用 Command+Shift。已有用户需按新提示使用组合键，不再沿用之前自动粘贴与 Option 条件相加的行为。[P1] [P2] [P3] [P4] [P7]

## 2. 入口、窗口与搜索

| 项目 | Maccy 2.7.1 | Polyglance 当前行为 |
|---|---|---|
| 是否记录 | `ignoreEvents` 默认关闭，即正常监听复制 | 默认关闭；设置 > 通用中启用，立即保存；关闭保留已有历史 [M1] [P1] |
| 呼出入口 | 默认 Command+Shift+C；专用菜单栏图标 | 全局快捷键初始未分配；菜单提供快速历史和管理历史两个入口 [M2] [P2] |
| 窗口形态 | 无标准标题栏按钮的浮窗；列表宽度默认 450，高度默认上限 800 | 快速浮窗内容区 450 × 520；管理窗口初始 850 × 600，最小 760 × 520 [M1] [M3] [P3] |
| 出现位置 | 快捷键默认在鼠标附近，也可选菜单栏、窗口中心、屏幕中心或上次位置 | 外部呼出时居中；切换管理界面扩大尺寸时约束在所在屏幕可见区域内，尚无位置策略设置 [M4] [P2] [P3] |
| 点击窗口外部 | 通常失去键盘焦点后关闭，显示确认提示时例外 | 快速浮窗失焦关闭；管理窗口保留。附属编辑和确认窗口不使用快速失焦关闭规则 [M3] [P3] |
| 搜索焦点 | 进入活动状态时聚焦搜索 | 每次展示和进入管理界面时明确请求搜索焦点；Command+F 也可聚焦 [M5] [P3] [P4] |
| 查询和选择 | 成功选用后清空查询，活动时优先普通历史 | 每次重新呼出快速浮窗清空查询、筛选和旧选择，优先选择已加载结果中的普通历史；进入管理界面保留本次查询和选择；直接重开管理窗口恢复上次管理状态 [M5] [M8] [P4] |
| 鼠标悬停 | 可随悬停改变高亮，并协调键盘导航 | 快速浮窗单击执行，键盘移动高亮；尚未提供悬停选中 [M15] [P3] |
| 预览 | 默认延迟自动预览，延迟 1500 ms；Control+Space 切换 | 快速浮窗默认收起，可用 Control+Space 展开；管理窗口按自动预览设置展示详情 [M1] [M3] [P3] |
| 搜索模式 | 普通匹配、模糊、正则及混合模式 | 不区分大小写的字面子串搜索；管理窗口还提供类型、来源、标签筛选 [M7] [P5] |
| 搜索范围 | 搜索条目标题；普通文本生成的标题截取前 1000 字符，图片识别文字写入标题 | 搜索已保存的纯文本全文、文件路径、来源标识、名称、标签及 OCR 索引，160 字符摘要不限制搜索 [M7] [M18] [P5] |
| 图片 OCR 搜索 | 图片生成标题时异步调用 Vision，识别结果可搜索 | 后台自动索引默认关闭；关闭时停止后台处理并保留已有索引；手动识别仍可保存索引 [M18] [P3] [P4] |
| 无选择时按 Enter | 可复制搜索文字，或执行选中的底部菜单项 | 不创建新的搜索文字记录 [M9] [P4] |

搜索对比应包含长文本后半段、改名条目和同一图片的识别结果。图片 OCR 搜索是两者共有的能力；Polyglance 的隐私排除正则与历史搜索模式是不同设置。

## 3. 选择、复制与粘贴

下表中 Maccy 未开启默认移除格式。Polyglance 的鼠标动作适用于快速浮窗；管理窗口单击只改变选择，标注为复制的按钮始终仅复制。

| 操作 | 自动粘贴关闭：两者的选用动作 | 自动粘贴开启：两者的选用动作 |
|---|---|---|
| 单击、Enter、Command+数字或绑定字母 | 复制并关闭 | 粘贴并关闭 |
| Option+单击、Option+Enter、Option+数字或绑定字母 | 粘贴并关闭 | 仅复制并关闭 |
| 纯文本粘贴 | Option+Shift+单击、Enter、数字或绑定字母 | Command+Shift+单击、Enter、数字或绑定字母 |

Polyglance 让这些入口共用同一动作解析，快速浮窗底部、详细设置和固定字母说明按自动粘贴设置显示提示。未定义的组合键不触发历史选用。中文输入法组合期间不处理历史执行和导航键。[M6] [M10] [M11] [P3] [P4] [P7]

| 项目 | Maccy | Polyglance |
|---|---|---|
| 数字编号 | 普通历史单独编号；固定项使用字母 | 快速浮窗只为已加载的普通历史编号；管理窗口仍按完整列表前九条编号；数字直接执行并关闭，不只是移动高亮 |
| 固定字母 | 自动分配可用字母，可在设置中修改 | 收藏后手动分配允许使用的字母，并检查所有动作组合与全局快捷键的冲突 |
| Option+P / Option+Delete | 固定 / 删除，可配置局部快捷键 | 收藏 / 删除，局部组合固定 |
| 批量清理 | 两组组合键分别保留或包含固定项 | 管理窗口清理按钮及确认窗口 |
| 清理后的系统剪贴板 | 默认保留；高级设置可启用同步清空（`clearSystemClipboard` 默认 `false`） | 保留系统当前剪贴板，未提供同步清空选项 |

依据：[M1] [M2] [M8] [M16] [M19] [M20] [P3] [P4]。两者自动粘贴均依赖辅助功能权限。Polyglance 继续检查原目标应用及剪贴板变化；失败时不得改贴到其他应用或覆盖后来复制的内容。

## 4. 循环选择、编辑及多选

### 循环选择

开启循环选择后，首次呼出进入等待状态，直接松键只保留浮窗。保持修饰键并再次按主键后，开始向下循环；释放全部修饰键才确认一次。逐个松键不会提前执行，额外按住的修饰键也必须释放。鼠标操作、其他按键、Esc 或失焦取消循环，取消后的松键不执行操作。Polyglance 默认关闭此功能。[M12] [P2] [P3] [P7]

快速浮窗失焦后关闭，管理窗口失焦后仍保留。循环确认使用与 Enter 相同的默认动作，并继续检查中文输入法组合状态。

### 固定与编辑

Maccy 固定条目时自动分配字母，文字编辑随输入更新，并移除非纯文本格式。[M13] [M17]

Polyglance 在管理窗口手动分配字母、编辑并保存，保留 ID、名称、标签、收藏及绑定。保存文字内容会移除 HTML/RTF，原样保存文字也会转为纯文本；仅修改名称和标签不会执行内容格式转换。验收 A06 覆盖原样保存。[P3] [P4] [P6]

### 多选与连续粘贴

Maccy 2.7.1 有 `PasteStack` 和多选代码，但 `AppState.multiSelectionEnabled` 固定为 `false`，不能视为已开放功能。[M9] [M14]

Polyglance 的管理窗口保留 Command 点击、Shift 扩选、多项复制和逐条粘贴队列。从目标应用打开快速浮窗后进入管理窗口，也沿用原目标；每次执行单独配置的粘贴下一条历史快捷键发送一条。目标应用或剪贴板变化时停止。[P3] [P4]

## 5. 设置入口和验证边界

- 设置 > 通用的启用开关立即保存；错误时展示反馈，保留原启用值。管理窗口的旧设置草稿不能覆盖最新开关值。
- 快速浮窗未启用提示可以跳转通用设置；管理窗口齿轮继续提供容量、排除、OCR、外观、循环和默认动作选项。
- 开启不补录旧复制，关闭保留历史；暂停与总启用开关独立。
- 原有启停和旧草稿回归保留，新增动作表、循环状态、快速查询重置、编号、点击执行、模式切换目标和失焦行为回归。
- 自动构建和测试不能代替权限、焦点、中文输入法、跨应用粘贴及多屏 GUI 验收。逐项执行 [实机验收表](剪贴板macOS实机验收.md)，未执行项继续标为待实测。

## 6. 下一阶段

| 优先级 | 工作 | 验收条件 |
|---|---|---|
| P0 | 完成本次快速浮窗和管理界面实机验收 | 覆盖自动粘贴开关两种状态、快捷键与鼠标、中文候选、取消和原目标保护；补保存失败与忙碌场景 |
| P1 | 鼠标附近定位与可配置的出现位置 | 多屏、全屏和屏幕边缘可见，预览和模式切换后不越界 |
| P1 | 悬停选择和可选延迟预览 | 鼠标移动与键盘导航不互相抢占；不因列表刷新误执行 |
| P2 | 局部快捷键编辑及固定项管理简化 | 冲突有提示，数字和字母标注与执行一致 |
| P2 | 模糊 / 正则搜索、空结果创建内容 | 独立于隐私排除规则，不改变现有字面搜索默认含义；覆盖长文本和 OCR |

快速与管理界面继续共用 Rust 历史核心和 Swift 服务。Windows 后续接入遵循 Rust + Slint 及 Windows 平台习惯。

## 7. 核对来源

Maccy 链接固定到 2.7.1 提交；版本依据为 [2.7.1 Release](https://github.com/p0deje/Maccy/releases/tag/2.7.1)。Polyglance 链接指向本 PR 源码。

[M1]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Extensions/Defaults.Keys%2BNames.swift
[M2]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Extensions/KeyboardShortcuts.Name%2BShortcuts.swift
[M3]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/FloatingPanel.swift
[M4]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/PopupPosition.swift
[M5]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Views/HistoryListView.swift
[M6]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Views/HistoryItemView.swift
[M7]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Search.swift
[M8]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Observables/History.swift
[M9]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Observables/AppState.swift
[M10]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/HistoryItemAction.swift
[M11]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Settings/GeneralSettingsPane.swift
[M12]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Observables/Popup.swift
[M13]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Settings/PinsSettingsPane.swift
[M14]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/PasteStack.swift
[M15]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Views/HoverSelectionModifier.swift
[M16]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/KeyChord.swift
[M17]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Observables/HistoryItemDecorator.swift
[M18]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Models/HistoryItem.swift
[M19]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Clipboard.swift
[M20]: https://github.com/p0deje/Maccy/blob/eb03ebac3bbf24044c797c06f4304b74e3187835/Maccy/Settings/AdvancedSettingsPane.swift
[P1]: ../apps/macos/Sources/Polyglance/SettingsView.swift
[P2]: ../apps/macos/Sources/Polyglance/AppDelegate.swift
[P3]: ../apps/macos/Sources/Polyglance/ClipboardHistoryWindow.swift
[P4]: ../apps/macos/Sources/Polyglance/ClipboardHistoryService.swift
[P5]: ../crates/clipboard-core/src/lib.rs
[P6]: ../crates/clipboard-core/src/editing.rs
[P7]: ../apps/macos/Sources/Polyglance/ClipboardSelectionInteraction.swift
