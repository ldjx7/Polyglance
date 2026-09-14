# Polyglance 品牌与 Logo

## 名称

Polyglance 由 poly（多语言、多形态内容）和 glance（一眼获取信息）组合而成，含义是多语言内容，一眼看懂。产品同时提供截图、OCR 和翻译功能。

## Logo

新版图标采用截图取景框与双语卡片：

- 四个靛蓝色圆角角标表示截图选区。
- 两张错位卡片中的 A 和文表示原文与译文。
- 靛蓝与青色构成主色，保留透明背景，便于适配不同桌面和界面。

macOS 菜单栏使用专门绘制的单色版本：保留截图框及前后错位的 A、文双语卡片，在 18 点尺寸下保持清晰。图像启用 `NSImage.isTemplate`，由 macOS 根据菜单栏背景及选中状态自动决定颜色。Dock、Finder 和应用内品牌图标使用彩色版本。

## 资源

- `apps/macos/Resources/PolyglanceIcon.png`：1024×1024 PNG。
- `apps/macos/Resources/Polyglance.icns`：macOS 图标，包含 16–1024 像素尺寸。
- `apps/macos/Sources/Polyglance/AppBranding.swift`：菜单栏单色矢量绘制。
- `apps/windows/src/Polyglance.UI/Resources/Polyglance.ico`：Windows 程序、任务栏、托盘及安装包图标，包含 16、20、24、32、40、48、64、128、256 像素尺寸。
- `apps/windows/src/Polyglance.UI/Resources/Polyglance.png`：Windows 应用内品牌图片。
- `website/src/assets/logo.png`：网站品牌图片。
- `website/public/favicon-32.png` 与 `favicon-48.png`：网站图标。

彩色资源由本次确认的截图框与双语卡片设计稿转换，设计稿由内置 imagegen 生成。
