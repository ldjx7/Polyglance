# Windows MP4 录屏性能分析与验证

验证日期：2026-09-23。

## 已确认的问题

原来的 MP4 链路是 WPF DispatcherTimer → GDI 截图 → WPF 位图 → JPEG 编码 → AVI → 停止后完整转码为 MP4。上一轮把编码放到后台，但每次采集仍由界面计时器触发，异步任务的完成也需要回到界面线程。因此，界面调度、截图和编码超过单帧预算后，下一次采集会被推迟。

重复写入最近的画面只能补齐视频时长，不能恢复错过的运动细节。文件显示 30 FPS 并不代表每秒采集了 30 张新画面。桌面动画对照测试中，旧实现 5 秒实际采集 97 张画面，输出却包含 150 帧。

## 竞品采用的方式

| 项目 | 官方实现证据 | 对本项目有用的做法 |
| --- | --- | --- |
| OBS Studio | [视频线程与调度](https://github.com/obsproject/obs-studio/blob/master/libobs/obs-video.c) 的 `obs_graphics_thread`、`video_sleep` 使用独立视频循环和绝对时间；编码队列传递时间戳并统计迟到帧。 [Windows 显示器采集](https://github.com/obsproject/obs-studio/blob/master/plugins/win-capture/duplicator-monitor-capture.c) 支持 Desktop Duplication 等路径。 | 采集时钟与界面分离；按绝对截止时间调度；记录实际掉帧和处理时间。 |
| ShareX | [ScreenRecorder](https://github.com/ShareX/ShareX/blob/develop/ShareX.ScreenCaptureLib/ScreenRecording/ScreenRecorder.cs) 在视频录制时直接运行 FFmpeg；[编码参数](https://github.com/ShareX/ShareX/blob/develop/ShareX.ScreenCaptureLib/ScreenRecording/FFmpegOptions.cs) 包括 GDIGrab、x264 ultrafast、NVENC 低延迟、QSV fast 等配置。GIF 的图像缓存流程单独处理。 | 视频边录边编码；按实时录制需求选择编码参数，避免先生成逐帧 JPEG 再完整转码。 |
| Windows Media Foundation | 微软提供 [Sink Writer 实时提交帧的用法](https://learn.microsoft.com/en-us/windows/win32/medfound/tutorial--using-the-sink-writer-to-encode-video) 和[硬件编码启用属性](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-readwrite-enable-hardware-transforms)。启用该属性允许使用硬件编码器，不保证每台机器最终都选择硬件。 | 使用系统自带编码组件实现实时 H.264，不增加外部 FFmpeg 运行依赖。 |

以上参考的是架构与公开 API；没有复制竞品实现代码。未获得闭源工具的实现证据，因此不推断其内部方案。

## 本次实现

- `ScreenRecordingCaptureLoop` 在独立线程上运行，以单调时钟计算绝对采集时刻。错过截止时间时前进到当前时刻，不反复采集同一瞬间来补过去的画面。
- `ScreenRecordingFrameCapture` 复用 GDI 设备上下文和 DIB 像素缓冲区。MP4 主路径不再逐帧创建 WPF 图像或 JPEG；仅为预览创建一次封面。
- 原生编码线程通过 Media Foundation Sink Writer 持续编码 H.264。优先允许硬件编码，初始化不兼容时尝试系统软件编码路径。
- 帧使用单调时间戳；发生采集间隔变化时，上一帧延续到下一帧时间。通信采用有界、同步确认的队列，避免未处理画面无限积压。
- 无声音录制结束后直接完成 MP4 并移动文件。有声音时先混音，再复制已压缩的 H.264 数据并编码 AAC 音轨，不重新压缩视频。
- 暂停期间停止录制时钟；停止和取消会先等待采集线程退出，再释放编码与音频资源。
- 录屏临时文件旁保存 `.diagnostics.json`，记录真实采集帧数、错过的帧时刻、采集/编码耗时及结束处理时间。

## Windows 桌面实测

环境：同一台 Windows 构建机的已登录桌面，Intel UHD Graphics 630，远程桌面会话。测试窗口持续绘制移动条和时间文字；实际录制区域为 1000×640，目标 30 FPS，每次 5 秒，视频码率 8 Mbps，无声音。

旧实现为上一轮已优化的 MJPEG 方案，已包含后台编码和重复帧压缩结果复用。新旧实现依次录制同一窗口；这是一组具体环境下的对照结果，不代表所有机器、分辨率或场景的性能。

| 指标 | 旧实现 | 本次实现 |
| --- | ---: | ---: |
| 实际采集画面数 | 97 | 150 |
| MP4 中的帧数 | 150 | 150 |
| 实际采集速率 | 约 19.4 FPS | 约 30 FPS |
| 运动条位置不变的相邻帧次数 | 77 | 3 |
| 最长连续静止画面 | 8 帧 | 2 帧 |
| 停止后的处理时间 | 2134.79 ms | 30.50 ms |

新实现平均每帧截图 22.68 ms、提交编码 1.25 ms；这一轮没有错过目标帧时刻。使用 FFprobe 解码检查：150 帧、5 秒、H.264，时间戳严格递增，相邻间隔为 33.333～33.334 ms。检查首帧确认顶部红色、底部蓝色，文字和运动条方向正确。

相邻帧位置统计来自逐帧解码后的运动条横坐标，包含桌面动画本身没有更新的情况，不能等同于录制线程的丢帧计数。

## 回归测试与复现

- 最终验证：Windows 完整 .NET 测试 296 项全部通过；原生视频数据保留测试通过；对照测试程序构建通过。macOS 开发应用构建及代码签名验证通过，Windows 应用、安装包和便携 ZIP 均已生成。
- Windows 原生测试 `remux_preserves_every_h264_packet_and_timestamp`：编码 30 张不同画面，合入 WAV 音轨后，逐项比较视频压缩数据、时间戳和帧持续时间，确认全部不变。
- Windows .NET 测试覆盖无音轨 MP4、奇数尺寸、独立采集循环、暂停/停止、时间计算，以及单声道/双声道/多声道混音和静音补齐。
- 可在 Windows 登录桌面中执行：

```powershell
cargo build --release -p polyglance-cabi
dotnet run --project scripts\benchmarks\windows-recording\Benchmark.csproj --configuration Release
```

测试会显示约十几秒的动画窗口并依次录制两段视频。输出位于测试程序的 `bin\Release\net9.0-windows\results`，包含 `before.mp4`、`after.mp4`、两份 JSON 和完成状态。需要实际交互桌面；不要在 WinRM 的非交互会话中直接录制并据此判断画面结果。

## 验证边界

本轮 MP4 采集仍使用经过缓冲区复用的 GDI，没有实现 OBS 的完整 GPU 纹理采集链路。高分辨率、60 FPS、显卡驱动和远程桌面环境仍可能限制真实采集速率，应结合诊断数据判断。上述桌面实测为无声音样本，带音频路径通过独立混音与压缩数据保留测试验证，不能将无音轨的 30.50 ms 直接套用到长录制混音。

本轮主要修复采集与编码造成的成片停顿，没有替换 WPF 预览播放器。若导出文件在系统播放器流畅而软件内预览仍卡，需要进一步测量预览渲染。

## 2026-09-23 预览进度条复查

用户提供的 `ScreenRecord_20260923_120600_173.mp4` 与应用临时文件哈希一致。文件长 13.163 秒，1272×668，H.264 60 FPS 和 AAC 音频；逐包检查发现 789 个视频包的 PTS/DTS 间隔均约 16.667 ms，617 个音频包间隔均约 21.333 ms，没有倒退或异常长间隔。完整解码无错误。因此，这段文件的进度条停顿后跳动不能归因于容器时间戳不均。

录制诊断同时显示，所选 60 FPS 下实际采集 417 帧、错过 372 个采集时刻，平均每帧截图 29.40 ms。编码输出被系统补成连续的 789 帧。该数据说明当前远程桌面的真实采集能力约为 32 FPS；它和进度条显示更新是两个需要分别衡量的问题。

预览窗口原来每 100 ms 在 WPF 界面线程读取一次 `MediaElement.Position`，然后直接设置进度条。现在每约 33 ms 用单调时钟插值更新；当媒体位置实际发生明显变化时重新同步。暂停、拖动和播放结束时重置时钟，避免进度值与视频脱节。微软说明 [DispatcherTimer](https://learn.microsoft.com/en-us/dotnet/api/system.windows.threading.dispatchertimer?view=netframework-4.8.1) 会受界面队列的其他工作影响，因此计时采用 `Stopwatch`；界面计时器只负责刷新显示。

用户是在远程桌面观察到相同文件于多个播放器中均有进度条跳动。应用内的刷新调整只能改善 Polyglance 自身的进度显示，不能控制其他播放器或远程桌面的画面传输。评估跨播放器现象仍需在 Windows 本机屏幕对照。

本轮进度条修改验证：Windows .NET 测试 299 项通过（其中新增 3 项覆盖播放器位置读取暂时不变、暂停与拖动、播放时钟明显偏移），Mac 开发应用构建及签名验证通过；Windows 应用、安装包与便携 ZIP 重新生成，构建机上没有遗留 Polyglance 进程。用户提供的原录屏文件未改写。

## 2026-09-23 远程桌面录制帧率复查

用户新提供的 `ScreenRecord_20260923_133929_809.mp4` 由更新后的 `dist\windows\Polyglance.exe` 生成，视频长 14.037 秒，录制区域 780×510。诊断中选择 60 FPS，但实际采集 445 帧，错过 396 个采集时刻，平均截图耗时 30.58 ms。最终 MP4 有 842 个 H.264 包，包间时间均约 16.667 ms；658 个 AAC 包间隔也连续。用户反馈更新进度条后仍在远程桌面中看到跨播放器跳动，因此只改 Polyglance 进度显示并未解决全部现象。

Windows 会话的 `WTSClientProtocolType` 实测为 2（RDP）。上一轮据此在 RDP 中把 MP4 录制帧率限制为 30 FPS，Windows 完整 .NET 测试 304 项通过并完成双端构建。但用户明确指出仍存在相同问题：其关注点是预览滑块以一段一段的方式向前跳，而非文件内的帧时间戳或时长。限制录制帧率不能改善这个交互，现已撤销该策略，保留用户选择的录制帧率。

## 2026-09-23 预览滑块视觉运动修正

macOS 和 Windows 的预览进度更新名义上都是约 30 Hz；Mac 的 `AVPlayer` 定期回调与 Windows 的 WPF `DispatcherTimer` 在调度机制上不同。Windows 此前每次界面计时器触发才给 `Slider.Value` 赋新值。即使计算播放位置的单调时钟连续，界面计时器延后时仍会让滑块跨过一段。时间文字本来就只显示整秒，不能据其正常递增判断滑块是否匀速。

Windows MP4 预览现在从当前播放位置到视频末尾使用 WPF 线性动画驱动滑块，动画由界面绘制时钟推进。界面计时器只负责更新时间文字及核对媒体时间，不再每次改写滑块位置。播放、暂停、拖动、结束和关闭时分别启动或停止动画；关闭了滑块刻度吸附和布局像素取整。该改变无需修改已生成的 MP4，但 Polyglance 目前在录制结束后才打开预览窗口，因此使用应用内预览复测仍需完成一次录制。远程桌面传输也可能限制任何播放器在客户端可见的刷新频率，需区分 Windows 本机窗口与远程观看效果。

验证：Windows 完整 .NET 测试 299 项全部通过（Core 79、Platform 157、UI 63），Windows 已发布应用、安装包和便携 ZIP 生成；Mac 开发应用已构建，代码签名验证通过。新版 Windows 应用在交互桌面成功启动。另在真实 Windows WPF 窗口中做滑块动画烟测：启动后 300 ms 进度约为 3.08/10；播放 250 ms、暂停 200 ms、恢复 250 ms 的进度依次约为 2.55、2.55、4.74，确认绘制时钟推进和暂停保持生效。进度条在实际远程桌面画面中的视觉流畅度仍需使用预览窗口观察，不能仅凭这些测试宣称已经消除远程传输造成的跳动。
