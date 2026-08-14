#!/bin/zsh
set -euo pipefail

# This command deliberately touches one known application bundle only. It does
# not disable Gatekeeper and does not remove quarantine attributes globally.
app_bundle="/Applications/Polyglance.app"

if [[ ! -d "$app_bundle" ]]; then
    /usr/bin/osascript -e 'display alert "未找到 Polyglance" message "请先将 Polyglance.app 拖入“应用程序”文件夹，再运行此文件。" as critical'
    exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$app_bundle" 2>/dev/null || true
/usr/bin/open "$app_bundle"
