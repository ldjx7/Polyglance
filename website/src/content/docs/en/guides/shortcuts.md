---
title: Keyboard Shortcuts
description: Complete overview of default shortcuts, presets, and common interactions
---

## Global Default Shortcuts (Recommended Preset)

All shortcuts can be modified or unbound in **Preferences → Shortcuts**.

| Action | macOS Default | Windows Default | Description |
| --- | --- | --- | --- |
| **Screenshot Tool** | `⌥A` (`Option+A`) | `Alt+C` | Region capture, annotation, color picker, and pin |
| **Selected Text Translation** | `⌥D` (`Option+D`) | `Alt+D` | In-place floating translation popover for selected text |
| **Translate & Replace** | `⌥R` (`Option+R`) | `Alt+R` | Translate selected text and immediately replace original text |
| **Screen Translation** | `⌥S` (`Option+S`) | `Alt+S` | Offline OCR and side-by-side translation of any screen area |
| **Pin Clipboard Image** | `⌥W` (`Option+W`) | `Alt+V` | Pin clipboard image directly on top of all windows |
| **Restore Most Recent Pin** | `⌥⇧W` (`Option+Shift+W`) | `Alt+Shift+V` | Reopen the most recently closed desktop pin in sequence |
| **Text Recognition (OCR)** | `⌥C` (`Option+C`) | `Alt+O` | Extract pure text with clickable word/sentence selection |

---

## Built-in Preset Schemes

Easily switch between standard workflows in Preferences:

- **Recommended (Default)**: Uses `Option` (macOS) / `Alt` (Windows) for ergonomic single-hand triggers.
- **Snipaste Style**: `F1` Capture, `F3` Pin, `Shift+F3` Restore Pin.
- **PixPin Style**: `Ctrl+1` Capture, `Ctrl+2` Pin, `Ctrl+Q` Translate, `Alt+Q` Screen Translate, `Ctrl+3` OCR.

---

## Optional Bindings

These actions have no default global shortcut and can be assigned as needed:

- **Open Main Translator Window**: Launch the standalone dictionary and multi-language translator window
- **Capture & Copy**: Directly copy screenshot area to clipboard, skipping annotation toolbar
- **Scrolling Long Screenshot**: Enter scrolling screenshot stitcher
- **Region Screen Recording**: Enter region screen recording mode
- **Read Selection (No Auto-Translate)**: Copy selected text into main translator without translating immediately

---

## Screenshot & Annotation Controls

Active during screenshot capture:

| Key / Action | Description |
| --- | --- |
| `Enter` | Complete capture and copy image to clipboard |
| `Esc` | Cancel selection or exit screenshot mode |
| `Delete` / `Backspace` | Delete currently selected annotation item |
| Arrow Keys `↑ / ↓ / ← / →` | Nudge selection by 1px (hold `Shift` for 10px) |
| `Cmd+Z` / `Ctrl+Z` | Undo last drawing action |
| `Cmd+Shift+Z` / `Ctrl+Y` | Redo undone drawing action |
| `C` | Copy color value at crosshair cursor |
| `Shift+C` | Toggle color format between HEX and RGB |

---

## Desktop Pin Window Controls

Active on pinned image windows:

| Key / Action | Description |
| --- | --- |
| `Space` | Toggle drawing and annotation toolbar on pin |
| Mouse Wheel | Smoothly zoom pinned image |
| Double Click | Reset scale to 100% original dimensions |
| Right Click | Context menu (Copy, Save, History, Color, Close) |
| `Esc` | Close active pin window (when not drawing) |

---

## Offline OCR Text Controls

Active in the text recognition workspace:

| Key / Action | Description |
| --- | --- |
| Click / Drag | Select individual words or full text blocks |
| `Cmd+C` / `Ctrl+C` | Copy selected text |
| `Shift+C` | Copy all recognized text in region |
| `Esc` | Dismiss OCR window |
