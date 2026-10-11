# 剪贴板与 Maccy 交互对比

初次核对日期：2026-10-08。复审以以下固定版本及源码为准。

- Maccy：固定对比版本 **2.7.1**，提交 `eb03ebac3bbf24044c797c06f4304b74e3187835`。依据官方使用说明和该版本源码，不将结论自动推广到后续版本。
- Polyglance：`feat/clipboard-history` 分支的 `1a28503`，包含本次将启用开关移入通用设置的修改；本次复审只补充文档，已发布的 `v0.1.5-beta.1` 尚不包含该入口迁移。
- 方法：核对窗口、事件处理、设置默认值和实际调用路径。本文描述代码行为；没有在同一台 Mac 上完成两个应用的 GUI、耗电或响应时间对测。

## 1. 结论

两者已有不少相同能力，包括文字和图片历史、搜索、固定条目、纯文本粘贴、预览及快捷键。但目前 Polyglance 更接近一个可以长期打开的历史管理窗口，Maccy 更接近随用随关的快速选择浮窗。

最明显的差异是：Maccy 通常点一次条目就完成复制或粘贴，并关闭浮窗；Polyglance 点条目会先选择并展示详情，再用按钮或键盘执行操作。窗口大小、失去焦点后的行为以及修饰键的含义也有差异。因此，功能清单接近并不代表已经实现相同的操作体验。

建议下一阶段提供快速选择模式，同时保留当前界面的历史管理能力。应先统一选择、复制、粘贴和关闭的规则，再调整视觉布局。本次完成的是启用开关迁移和对比分析，下面的后续建议尚未实施。

## 2. 入口、窗口与搜索

| 项目 | Maccy 2.7.1 | Polyglance 当前行为 | 对操作的影响 |
|---|---|---|---|
| 是否记录 | `ignoreEvents` 默认关闭，即正常监听复制 | 历史默认关闭；本次将启用开关移至设置 > 通用，立即保存 | Polyglance 需要先明确开启，适合截图工具中的可选功能 [M1] [P1] |
| 呼出入口 | 默认 Command+Shift+C；直接点击专用菜单栏图标 | 呼出快捷键初始未分配；从 Polyglance 菜单选择剪贴板历史 | Polyglance 的菜单操作多一步；Command+Shift+V 是此前文档建议，不能写成 Maccy 的默认值 [M2] [P2] |
| 窗口形态 | 无标准标题栏按钮的浮窗，列表宽度默认 450，预览展开时另加宽度；高度按内容调整、默认上限 800 | 初始 850 × 600，最小 760 × 520；标题栏、列表、详情和操作按钮 | Polyglance 初始窗口更宽，适合管理；快速取一条内容时操作区域偏多 [M1] [M3] [P3] |
| 出现位置 | 快捷键默认在鼠标附近；可选菜单栏、当前窗口中心、屏幕中心、上次位置 | 每次呼出调用 `center()`，没有位置策略设置 | 多屏及鼠标附近取内容的体验不同 [M4] [P2] |
| 点击窗口外部 | 通常在失去键盘焦点后关闭，显示确认提示时例外 | 失去焦点只取消循环选择，窗口继续保留 | Polyglance 更像持久工具窗；要退出通常需 Esc、关闭按钮或再次呼出 [M3] [P3] |
| 再次呼出的焦点 | 每次进入活动状态会聚焦搜索，并优先选择普通历史首条 | 搜索焦点在视图首次出现和 Command+F 时设置；重新打开未显式重置焦点 | 不能保证每次呼出后直接输入就进入搜索，需要实机验证并补齐规则 [M5] [P3] |
| 首条选择 | 活动时优先选择未固定历史，没有普通历史时再选固定条目 | 保留仍存在的选择，否则选当前结果第一条；收藏优先排序 | Polyglance 可能优先落到旧收藏，或保留上次选择 [M5] [P4] [P5] |
| 鼠标悬停 | 可随悬停改变高亮，并协调键盘导航状态 | 原生列表以点击和键盘选择为主，没有同等的悬停选中处理 | 鼠标滑过条目时的反馈不同 [M15] [P3] |
| 预览 | 默认开启延迟自动预览，默认延迟 1500 ms；可用 Control+Space 切换 | 默认展示右侧预览，选择后异步读取内容；同样支持 Control+Space | Polyglance 收起预览后仍保留右侧操作区域，并未切换为紧凑列表 [M1] [M3] [P3] |
| 搜索模式 | 支持普通匹配、模糊、正则及混合模式 | 不区分大小写的字面子串搜索，支持类型、来源、标签组合筛选 | 输入拼写不完整或正则时结果不同；内容排除正则不等于正则搜索 [M7] [P5] |
| 搜索范围 | 搜索条目标题；普通文本自动生成的标题截取前 1000 字符，图片识别出的文字也会写入标题 | 搜索已保存的纯文本全文、文件路径、来源标识、名称、标签及已建立的 OCR 索引；列表的 160 字符摘要不限制搜索范围 | 长文本后半段、改名条目和图片可能得到不同结果；不能将图片 OCR 搜索视为 Polyglance 独有能力 [M7] [M18] [P5] |
| 图片 OCR 搜索 | 图片生成标题时异步调用系统 Vision 识别，结果作为可搜索标题 | 后台自动 OCR 索引默认关闭；开启后为已有和新图片建立本机索引，关闭后停止后台处理并保留已有索引；手动识别仍可保存索引 | 对比应使用同一图片并等待识别完成，同时记录自动索引开关、是否手动识别及识别结果；本文未比较识别率或耗时 [M18] [P3] [P4] |
| 选用后搜索状态 | 成功选用条目后清空搜索词 | 复制、关闭、重开不主动清空查询和筛选 | 下次呼出可能仍是上次的过滤结果 [M8] [P4] |
| 没有历史选择时按 Enter | 可将输入的搜索文字作为新复制内容；选中底部菜单时执行对应菜单动作 | 没有选中条目就不执行复制，不创建搜索文字记录 | Polyglance 暂未提供通过搜索框创建内容的交互 [M9] [P4] |

## 3. 选择、复制与粘贴

以下默认行为指未开启自动粘贴，且 Maccy 未开启默认移除格式。

| 操作 | Maccy | Polyglance |
|---|---|---|
| 单击条目 | 复制并关闭；开启自动粘贴后会粘贴 | 只选中，保留窗口和详情 |
| Option+单击 | 根据当前动作设置执行粘贴或复制 | 没有对应的鼠标动作映射 |
| Enter | 复制并关闭 | 复制并关闭 |
| Option+Enter | 粘贴并关闭 | 粘贴并关闭 |
| Option+Shift+Enter | 纯文本粘贴并关闭 | 纯文本粘贴并关闭 |
| Command+1…9 | 立即复制对应的普通历史条目并关闭；固定项使用独立字母 | 立即复制当前列表中的对应条目并关闭；取前九条，收藏也占位置 |
| Command+已绑定字母 | 立即复制固定项并关闭，不占普通历史的数字编号 | 立即复制绑定的收藏并关闭；所在行仍占当前列表的数字位置 |
| Option+P / Option+Delete | 固定 / 删除，快捷键可在偏好设置修改 | 收藏 / 删除，窗口内组合固定，未提供对应的局部快捷键编辑器 |
| 批量清理 | 有保留固定项与包含固定项的两组清理组合键 | 主要通过清理按钮和确认窗口，未映射这两组组合键 |
| 清理后的系统剪贴板 | 默认保留；开启高级设置中的同步清空选项后，两种历史清理都会清空系统剪贴板（`clearSystemClipboard` 默认 `false`） | 清理仅删除历史库记录，保留当前系统剪贴板；未提供同步清空选项 |

依据：[M1] [M2] [M6] [M8] [M10] [M16] [M19] [M20] [P3] [P4]。两者自动粘贴均依赖辅助功能权限。Polyglance 还会检查原目标应用和剪贴板序号，目标变化时中止自动粘贴；这项保护应在后续交互调整中保留。

数字和固定字母快捷键都会执行操作，不能仅按是否移动高亮验收。开启自动粘贴后的动作见下表。两者默认清理历史都保留系统剪贴板，Maccy 另有同步清空选项；对比时应记录该设置，并分别核对历史库和系统剪贴板。

### 开启自动粘贴后的关键差异

| 操作 | Maccy：自动粘贴开启、默认移除格式关闭 | Polyglance：自动粘贴开启 |
|---|---|---|
| Enter / Command+数字 | 粘贴 | 粘贴 |
| Option+Enter / Option+数字 | 切换为仅复制 | 仍然粘贴 |
| 纯文本粘贴 | Command+Shift+Enter / Command+Shift+数字 | Option+Shift+Enter / Option+Shift+数字 |
| 单击条目 | 自动粘贴 | 仍然只选中 |

Maccy 会根据默认动作调整修饰键含义，并在设置中更新提示。Polyglance 当前采用自动粘贴开关与 Option 条件相加的判断，没有实现 Maccy 的动作反转规则；也没有独立的默认移除格式开关。[M10] [M11] [P3]

这部分需要明确产品选择：如果提供 Maccy 操作习惯预设，就应统一键盘、鼠标和行内提示的动作映射；如果沿用当前规则，也应展示当前组合键的实际效果。显式标注为复制的按钮应继续只复制，避免按钮文字与行为不符。

## 4. 循环选择、固定项及多选

### 循环选择

Maccy 首次按呼出快捷键时进入待判断状态；直接松开修饰键只保留浮窗。保持修饰键并再次按主键后，才进入循环选择；随后释放全部修饰键会确认。[M12]

Polyglance 默认关闭循环功能。开启后，首次呼出就开始循环模式；松开任一必需修饰键便会确认，不要求再按一次主键。鼠标操作、其他按键、Esc 或失去焦点会中止循环。[P2] [P3]

因此，即使两个产品都有循环选择，第一次呼出后松键的结果也不同。后续应补充首次呼出、重复主键、逐个松键及输入法候选状态的用例，再决定是否提供与 Maccy 一致的模式。

### 固定与编辑

Maccy 固定条目时自动分配可用字母，并能在固定项设置中调整字母、名称和文字内容。文字编辑随输入更新，富文本编辑会移除非纯文本格式。[M13] [M17]

Polyglance 先收藏，再由用户分配允许使用的字母，并检查与全局快捷键的冲突；编辑使用独立窗口和保存按钮，保留 ID、名称、标签、收藏及绑定。保存文字内容会移除 HTML/RTF，文字原样保存也会转为纯文本；仅修改名称或标签不属于这项内容编辑操作。两者文字编辑都会移除富文本格式，主要区别在即时更新与显式保存。验收表 A06 已覆盖原样保存的情况。[P3] [P4] [P6]

### 多选与连续粘贴

Maccy 2.7.1 源码中存在 `PasteStack` 和多选相关实现，但 `AppState.multiSelectionEnabled` 固定为 `false`，入口和建立队列的方法受该条件限制，不能把这部分当作该版本已经向用户开放的功能。[M9] [M14]

Polyglance 已开放 Command 点击、Shift 扩选、多项复制及逐条粘贴队列。队列使用单独配置的粘贴下一条历史快捷键，每次执行一条；目标应用或剪贴板发生变化时停止。其触发方式也不同于 Maccy 源码中尚未开放的 Command+V 监听方案。[P3] [P4]

## 5. 设置入口与本次修改

Maccy 的偏好设置按通用、存储、外观、固定项、忽略和高级分组；Command+, 打开这套剪贴板设置。[M9] [M11]

Polyglance 的全局偏好设置还包含翻译、OCR、截图和录屏，因此需要将基础入口融入现有设置，同时保留详细选项：

- **本次已修改**：设置 > 通用增加启用剪贴板历史开关，直接使用正在运行的服务状态，修改后立即保存；保存失败展示错误并保留原状态。
- **本次已修改**：历史窗口未启用提示提供前往通用设置按钮；齿轮中移除重复的启用开关，改为显示当前状态和入口说明。
- **本次已修改**：历史选项保存时保留通用设置的最新启用值，避免较早打开的设置窗口把它改回旧值；保存和数据处理期间限制重复提交。
- 开关默认关闭，开启不补录旧内容；关闭保留已有历史。容量、排除规则、OCR 和外观选项仍在历史窗口齿轮中，全局快捷键在现有快捷键页。
- 总启用开关与暂停是两个状态；当前处于暂停时，通用设置会提示从历史窗口恢复记录。

新增回归测试覆盖启停采集、启用值持久化、已有历史保留、其他选项保留，以及旧设置草稿不能重新开启或关闭记录。保存失败与忙碌拒绝还需可控的异常和并发测试；现有成功路径不能代替这些验证。GUI 入口和跨窗口操作仍按 [实机验收表](剪贴板macOS实机验收.md) 验证，当前没有实机通过结论。

## 6. 后续实现顺序

同一优先级内按下表顺序推进。快速模式应建立在明确的交互规则上；以下待实现项目均不属于本次 PR 已交付功能。

| 顺序 | 优先级 / 状态 | 建议 | 完成标准 |
|---|---|---|---|
| 0 | P0，已实现，待实机验收 | 验收通用设置中的启用入口与状态同步 | 完成 A01、A09、A10；补保存失败和忙碌拒绝验证；旧草稿不覆盖、启停不补录旧内容 |
| 1 | P1，待实现 | 确定并实现每次呼出的搜索焦点、查询和选择规则 | 明确快速模式与管理模式是否保留查询、筛选和选择；重开后可直接输入；普通历史与固定项的初始选择有确定规则 |
| 2 | P1，待实现 | 统一默认动作和修饰键映射 | 列出自动粘贴开关两种状态下 Enter、鼠标、数字、字母的动作；提示与实际一致；始终有仅复制和纯文本粘贴入口 |
| 3 | P1，待实现 | 新增快速选择模式，提供进入管理窗口的入口 | 紧凑列表、单击执行、点击外部关闭；切换到管理窗口后保留原粘贴目标；管理窗口继续支持多选；编辑和确认期间不误关闭 |
| 4 | P1，待实现 | 对齐可选的 Maccy 循环模式 | 第一次松键只展开；重复主键后循环；确认、取消及输入法组合状态均有测试；明确与现有循环方式的设置和兼容关系 |
| 5 | P2，待实现 | 鼠标附近定位、屏幕边缘约束和上次位置 | 多屏和全屏应用中可见，不因尺寸变化落到屏幕外 |
| 6 | P2，待实现 | 独立的固定项字母、普通历史数字编号，以及局部快捷键设置 | 编号与显示一致，固定项不造成数字跳号；冲突有提示 |
| 7 | P2，待实现 | 模糊 / 正则搜索、空结果创建内容等可选增强 | 与隐私排除正则分开说明；不改变现有字面搜索的默认含义；补长文本、改名和 OCR 内容的搜索用例 |

快速模式中的单击执行与当前管理窗口的多选会发生手势冲突，不能只给现有列表加单击复制。需要分开定义两种模式，并继续共用 Rust 历史核心和 Swift 平台服务，避免另建一套存储、OCR 或备份逻辑。Windows 后续接入仍以 Rust + Slint 为准。

### 快速模式与管理窗口切换的验收条件（待实现）

| 场景 | 预期结果 |
|---|---|
| 从 TextEdit 呼出快速模式，再进入管理窗口并粘贴 | 两个窗口沿用本次呼出时的 TextEdit 目标；内部切换不重新取 Polyglance 自己作为目标 |
| 在管理窗口编辑或显示删除确认，再点击窗口外部 | 按该模式的规则保留编辑和确认状态，不套用快速模式的失焦关闭规则 |
| 模式切换后原目标应用退出，或执行粘贴前用户进行了新的外部复制 | 取消过期操作，不改贴到其他应用，不覆盖后来复制的内容 |
| 取消本次操作，再从另一外部应用重新呼出 | 建立新的目标和操作状态；旧异步读取、OCR 和粘贴操作不能影响新一轮操作 |

当前 `preparePresentation()` 每次从前台应用重新记录目标，遇到 Polyglance 自己会清空目标。实现内部模式切换时不能直接把它当成一次新的外部呼出；应显式保留原目标，同时延续现有复制操作的取消和剪贴板变化检查。[P4]

## 7. 核对来源

Maccy 源码链接固定到 2.7.1 的提交；官方入口为 [maccy.app](https://maccy.app/)，版本依据为 [2.7.1 Release](https://github.com/p0deje/Maccy/releases/tag/2.7.1)。

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
