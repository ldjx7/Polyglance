#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h:h}"
app_file="$root_dir/apps/windows/src/Polyglance.UI/App.xaml.cs"
selection_file="$root_dir/apps/windows/src/Polyglance.UI/Views/ScreenSelectionWindow.xaml.cs"
toolbar_file="$root_dir/apps/windows/src/Polyglance.UI/Controls/ScreenshotToolbar.xaml"
toolbar_code_file="$root_dir/apps/windows/src/Polyglance.UI/Controls/ScreenshotToolbar.xaml.cs"
long_file="$root_dir/apps/windows/src/Polyglance.UI/Views/LongScreenshotSessionWindow.xaml.cs"
long_xaml_file="$root_dir/apps/windows/src/Polyglance.UI/Views/LongScreenshotSessionWindow.xaml"
scroller_file="$root_dir/apps/windows/src/Polyglance.Platform/Capture/UnderlyingWindowScroller.cs"

translation_group_line=$(grep -n 'Group 2: 文本翻译' "$app_file" | cut -d: -f1)
translation_item_line=$(grep -n 'Items.Add("截图翻译"' "$app_file" | cut -d: -f1)
if (( translation_item_line <= translation_group_line )); then
  print -u2 "截图翻译没有位于托盘菜单的翻译分组"
  exit 1
fi

grep -q 'BeginScreenshotSelection(ScreenshotCaptureIntent.ScreenTranslation)' "$app_file"
grep -q 'BeginScreenshotSelection(ScreenshotCaptureIntent.LongScreenshot)' "$app_file"
grep -q 'Tag="OCRTranslate"' "$toolbar_file"
grep -q 'new OcrSelectionWindow' "$selection_file"
grep -q 'case "ScreenTranslation"' "$selection_file"
grep -q 'UnderlyingWindowScroller.ForwardWheel' "$long_file"
grep -q 'RenderPreview()' "$long_file"
grep -q 'PointToScreen(_cropRect.TopLeft)' "$long_file"
grep -q 'PointToScreen(_cropRect.BottomRight)' "$long_file"
grep -q 'ChildWindowFromPointEx' "$scroller_file"
grep -q 'WalkToDeepestChild' "$scroller_file"

# The native stitcher returns raw RGBA pixels, not an encoded PNG. Both the
# final image and live thumbnail must carry dimensions into BitmapSource.
grep -q 'BitmapSource.Create' "$long_file"
grep -q 'PixelFormats.Bgra32' "$long_file"
grep -q 'CopyBgraPixels()' "$long_file"
grep -q 'PreviewBorder.Visibility = Visibility.Visible' "$long_file"
if grep -Eq 'PngBitmapDecoder|DecodePng' "$long_file"; then
  print -u2 "Windows 长截图仍把原始 RGBA 数据当作 PNG 解码"
  exit 1
fi

# The Windows selection toolbar mirrors the macOS screenshot toolbar's visual
# contract: one icon language, one neutral tint, system-blue active state,
# frameless buttons, and the same 6-tool / 10-action compact layout.
grep -q 'x:Key="ToolbarIconBrush" Color="#FF2E2E2E"' "$toolbar_file"
grep -q 'x:Key="ToolbarActiveBrush" Color="#FF0A84FF"' "$toolbar_file"
grep -q 'x:Key="ToolbarHoverBackgroundBrush" Color="#14000000"' "$toolbar_file"
grep -q 'x:Key="ToolbarDisabledBrush" Color="#33000000"' "$toolbar_file"
grep -q 'x:Name="ToolbarRows"' "$toolbar_file"
grep -q 'x:Name="ToolRow"' "$toolbar_file"
grep -q 'x:Name="ActionRow"' "$toolbar_file"
grep -q 'SetCompactLayout' "$toolbar_code_file"
grep -q 'Toolbar.SetCompactLayout(Width < 700)' "$selection_file"

main_toolbar=$(sed -n '/<!-- 一级主工具栏/,$p' "$toolbar_file")
if print -r -- "$main_toolbar" | grep -Eq 'ToolTip="[^"]*\(|#EF4444|#1E293B'; then
  print -u2 "Windows 截图工具栏仍包含快捷键提示或与 macOS 不一致的独立图标颜色"
  exit 1
fi
if (( $(print -r -- "$main_toolbar" | grep -o 'RelativeSource AncestorType=Button' | wc -l | tr -d ' ') < 12 )); then
  print -u2 "Windows 截图工具栏图标没有统一继承按钮的状态颜色"
  exit 1
fi
grep -q 'ToolTip="贴图"' "$long_xaml_file"
grep -q 'ToolTip="复制"' "$long_xaml_file"
grep -q 'ToolTip="关闭"' "$long_xaml_file"
if grep -Eq '<ui:Button|SymbolIcon' "$long_xaml_file"; then
  print -u2 "Windows 长截图工具栏仍使用带方框的 WPF-UI 按钮"
  exit 1
fi

if grep -Eq '自动滚动|完成拼接|OnToggleAutoScrollClick|OnFinishClick' "$long_xaml_file" "$long_file"; then
  print -u2 "Windows 长截图仍包含与 macOS 不一致的自动滚动或完成按钮"
  exit 1
fi

for xaml in "$root_dir"/apps/windows/src/Polyglance.UI/**/*.xaml; do
  xmllint --noout "$xaml"
done

echo "Windows capture alignment contract passed"
