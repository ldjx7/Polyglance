---
title: 常见问题
description: 使用中常见的问题
---

## 为什么要辅助功能权限？

划词翻译需要读取其他应用中你选中的文字。优先调用 macOS Accessibility API，失败时才回退到模拟复制，复制完会自动恢复剪贴板。

## 我的 API Key 存在哪里？

- 内置的 Microsoft / Google / 免费 AI 服务：**不需要 Key**，开箱即用
- 自定义 AI（DeepSeek、OpenAI 等）：Key 存在 **macOS Keychain**，不会上传到任何服务器

## 应用为什么没有公证？

Polyglance 是免费开源项目，未加入 Apple Developer Program。检查方式：`codesign -dv /Applications/Polyglance.app`。

## 关掉菜单栏图标后怎么找回？

通过 Spotlight 或 `Command+Space` 重新启动应用即可。

## 长截图怎么结束？

点击「完成」、按 `Esc`，或直接复制 / 贴图，都会自动结束拼接。
