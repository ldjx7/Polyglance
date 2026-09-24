#!/bin/bash
set -euo pipefail

# Usage: run.sh <git revision before the mixdown change>
# Requires the macOS Swift toolchain, FFmpeg and Python 3.
script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/../../.." && pwd)"
baseline_revision="${1:?Provide a git revision before the audio-only mixdown change}"
output_directory="$(mktemp -d "${TMPDIR:-/tmp}/polyglance-mixdown-benchmark.XXXXXX")"
source_path="apps/macos/Sources/Polyglance/ScreenRecordingAudioMixdown.swift"

cd "$repository_root"
git show "$baseline_revision:$source_path" |
    sed 's/ScreenRecordingAudioMixdown/LegacyAudioMixdown/g' > "$output_directory/LegacyAudioMixdown.swift"
swiftc -O -parse-as-library -o "$output_directory/benchmark" \
    "$source_path" "$output_directory/LegacyAudioMixdown.swift" "$script_directory/Benchmark.swift"
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=60:duration=10' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=10' \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=10' \
    -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -crf 22 \
    -c:a aac -b:a 128k -movflags +faststart "$output_directory/source.mp4"
"$output_directory/benchmark" "$output_directory/source.mp4" | tee "$output_directory/timings.txt"
python3 - "$output_directory" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])

def packets(path):
    output = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
        "-show_data_hash", "sha256", "-show_entries",
        "packet=pts_time,dts_time,duration_time,data_hash", "-of", "json", str(path),
    ])
    return json.loads(output)["packets"]

original = packets(root / "source.mp4")
assert len(original) == 600
for path in sorted(root.glob("after-*.mp4")):
    assert packets(path) == original, f"Video samples or timestamps changed: {path.name}"
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"], check=True)
    print(f"{path.name}: 600 unchanged video packets, complete decode passed")
print(f"Benchmark files: {root}")
PY
