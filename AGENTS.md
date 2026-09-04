# Polyglance Agent Guide

本文件适用于整个仓库。除非用户明确要求，否则不要把凭据、私钥、API Key 或登录密码写入仓库、命令日志、提交信息或回复正文。

## 输出风格

- 覆盖范围：问答、代码注释、文档编写等任务
- 语言习惯：易懂、自然，只保留必要的技术关键词

## 规范与禁止事项

- **禁止使用中文引号**：除非用户明确要求逐字引用，否则回复中不得出现 Unicode 字符 U+201C 和 U+201D。

- **禁止翻译腔**：避免使用生硬直译、不符合中文母语习惯的词汇（如：接住、击穿、锋利、不崩、不爆、打穿、扛住等）。

  - 【错误示范】：当遇到大流量时，如果缓存被击穿，系统能否扛住压力？如果代码有漏洞，很容易被黑客打穿防线。
  - 【修改后的示范】：当遭遇大流量并发时，若缓存失效导致请求直达数据库，系统能否承受此负载压力？若代码存在安全漏洞，防线极易被黑客攻破。

- **禁止过度缩减词**：避免为了简短而过度简化计算机专业词汇，导致语义丢失或产生歧义。

  - 【错误示范】：服务器出现高负，导致微服响应超时，建议排查连池配置。
  - 【修改后的示范】：服务器出现高负载情况，导致微服务响应超时，建议排查数据库连接池配置。

- **禁止用中文引号包括的缩减词和短句**：尽量减少使用中文引号，避免使用引号来强调非专有名词的缩写词、行业黑话或四字短句。

  - 【错误示范】：这套系统做到了**“高可用”，前端实现了“多端适配”，后端进行了“冷热分离”**，线程池本身只提供“常驻线程反复取活”的机制。
  - 【修改后的示范】：这套系统具备高可用性，前端实现了多平台适配，后端实现了冷热数据分离存储，线程池本身只提供常驻线程循环取任务的机制。

- **禁止生造词**：避免将英文技术概念生硬糅合，或使用正常技术沟通中不存在的捏造词汇。

  - 【错误示范】：该架构具有极高的高并发抗性，代码的自解释度出色，并展现出良好的容灾力。
  - 【修改后的示范】：该架构能够有效应对高并发冲击，代码可读性强且易于理解，同时具备良好的容灾能力。

- **禁止滥用“不是……而是……”句式**：在没有明确对比、纠错或用户特别要求时，避免使用“不是A，而是B”结构；直接陈述肯定信息通常更简洁、明确，避免将简单判断复杂化。

  - 【错误示范】：该接口响应变慢的原因不是服务器负载过高，而是缓存策略失效。
  - 【修改后的示范】：该接口响应变慢的原因是缓存策略失效。

## Windows 构建机

Windows 客户端必须在真实 Windows 环境中编译和测试。不要因为当前主机是 macOS 就跳过 Windows 构建，也不要在 macOS 上声称已经完成 Windows C# 编译。

### 连接信息

- 连接方式：Windows PowerShell Remoting（WinRM），不是远程桌面 RDP。
- WinRM 地址：`http://10.92.9.25:5985/wsman`
- 认证方式：NTLM。
- Windows 登录主体：`MicrosoftAccount\ldjx7@outlook.com`。
- `pywinrm` 在此主机上已验证可使用的用户名：`ldjx7@outlook.com`。若所用客户端要求显式 Windows 主体，再使用上面的 `MicrosoftAccount\...` 形式。
- 远端项目目录：`D:\Develop\native-translator`。
- .NET SDK：`C:\Users\user\.dotnet\dotnet.exe`。
- Cargo 通常位于：`C:\Users\user\.cargo\bin`。

密码是用户此前提供的 Windows 登录密码，但不得写入本文件或其他版本控制文件。需要连接时，从当前会话的安全上下文取得；如果上下文中没有密码，应向用户询问，禁止猜测用户名或密码。

如需跨会话复用 WinRM 凭据，应把密码保存到操作系统钥匙串或其他安全凭据存储中，不得把明文密码补充到本文件。macOS 钥匙串条目使用服务名 `polyglance-winrm`、账户名 `ldjx7@outlook.com`。

RDP 是另一条仅用于图形界面操作的通道，常见端口为 3389，用户环境也可能使用自定义端口。Windows 自动构建不依赖 RDP，不能把 RDP 端口与 WinRM 的 5985 混用。

### WinRM 调用约定

使用 Python 时优先采用 `pywinrm`：

```python
import winrm

session = winrm.Session(
    "http://10.92.9.25:5985/wsman",
    auth=(username, password),
    transport="ntlm",
    read_timeout_sec=1200,
    operation_timeout_sec=1190,
)
```

- 不得打印 `username/password` 元组、认证头或包含密码的异常上下文。
- 长时间构建应提高读取与操作超时，避免编译仍在运行时被客户端误判为失败。
- 远端 PowerShell 配置文件可能因执行策略产生无害告警。执行构建脚本时使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass`。
- 复杂 PowerShell 命令优先通过 UTF-16LE Base64 的 `-EncodedCommand` 传入，避免 `-Command` 的引号和参数被 WinRM 二次解析。
- 子进程 PATH 中应包含 `C:\Users\user\.dotnet` 和 `C:\Users\user\.cargo\bin`。

## 同步当前源码到 Windows

远端目录可能只是构建副本而不是 Git 仓库。开始前先检查远端目录、进程和源码状态，不要假定可以直接执行 `git pull`，也不要覆盖无法确认归属的远端未提交修改。

若本地改动尚未提交，可以在 macOS 创建仅包含当前受 Git 管理及未忽略文件的临时归档，通过临时 HTTP 服务让 Windows 下载，然后解压覆盖到构建副本。创建 tar 包时必须设置 `COPYFILE_DISABLE=1`，防止 macOS `._*` AppleDouble 文件进入 Windows；这些文件会被 C# 通配符误当源码并触发 `CS2015`。

同步后若发现 `._*`，应只删除远端项目目录内这些明确的 macOS 元数据文件，再重新测试。临时 HTTP 服务完成传输后必须关闭。

## Windows 验证和构建顺序

在 `D:\Develop\native-translator` 中按以下顺序执行：

1. 退出已有 `Polyglance` / `Polyglance.UI` 进程。
2. 运行完整测试：
   `C:\Users\user\.dotnet\dotnet.exe test apps\windows\Polyglance.sln --configuration Release`
3. 构建应用：
   `.\scripts\build-windows-app.ps1 -Version "<version>" -BuildNumber "<number>"`
4. 构建安装包：
   `.\scripts\build-windows-installer.ps1 -Version "<version>" -BuildNumber "<number>"`
5. 构建便携/更新 ZIP：
   `.\scripts\build-windows-portable-update.ps1 -SourceDirectory "dist\windows" -DestinationPath "dist\installer\Polyglance-<version>-Windows-x64-Portable.zip"`

`build-windows-app.ps1` 已负责退出旧进程并清理 `dist\windows` 和 `dist\installer`，因此必须先执行它；安装包与 ZIP 必须在应用构建完成后生成。不要在生成安装包之后再次运行应用构建脚本，否则它会按约定清空安装包目录。

构建结果：

- 已发布应用：`D:\Develop\native-translator\dist\windows\Polyglance.exe`
- 安装包：`D:\Develop\native-translator\dist\installer\Polyglance-<version>-Windows-x64-Setup.exe`
- 便携包：`D:\Develop\native-translator\dist\installer\Polyglance-<version>-Windows-x64-Portable.zip`

完成后确认：测试全部通过、`dist\installer` 只保留本次产物，并且没有遗留 Polyglance 进程。除非用户明确要求，不要安装、提交、推送或创建 tag。

## 每次开发完成后的双端构建

每次完成代码修改后，都必须构建 macOS 与 Windows 两端的可交付产物，不能只运行单元测试或只构建当前主机对应的平台。

### macOS 开发版本

macOS 必须构建开发版本：

`./scripts/build-macos-app.sh`

不要传入 `--preserve-permissions`。该命令生成独立的开发应用 `dist/Polyglance Dev.app`，Bundle Identifier 为 `io.polyglance.macos.dev`，不会覆盖正式版 `Polyglance.app`。构建脚本会按开发版本约定停止已有的 `Polyglance Dev` 进程并重置辅助功能、屏幕录制和麦克风权限；完成后应确认应用包存在且代码签名验证通过。

### Windows 产物

Windows 必须在上述真实 Windows 构建机上完成测试和构建，并严格遵守 Windows 验证和构建顺序。最终需要同时生成已发布应用、安装包和便携/更新 ZIP，并确认没有遗留 Polyglance 进程。
