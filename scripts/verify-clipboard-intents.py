"""Reject packaged apps whose clipboard Shortcuts actions were not extracted."""
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
metadata = directory / "extract.actionsdata"
data = json.loads(metadata.read_text())
serialized = json.dumps(data, ensure_ascii=False)
expected = [
    "OpenClipboardHistoryIntent", "SearchClipboardHistoryIntent",
    "GetClipboardHistoryTextIntent", "CopyClipboardHistoryIntent",
    "DeleteClipboardHistoryIntent", "ClearClipboardHistoryIntent",
    "PauseClipboardHistoryIntent", "IgnoreNextClipboardCopyIntent",
]
missing = [name for name in expected if name not in serialized]
if missing:
    raise SystemExit("Missing clipboard intent metadata: " + ", ".join(missing))
print(f"Verified {len(expected)} clipboard Shortcuts actions.")
