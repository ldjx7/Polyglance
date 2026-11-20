#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
app_bundle="$1"
asset_cache="${script_directory:h}/target/macos-ocr-assets"
model_directory="$app_bundle/Contents/Resources/OCRModels"
framework_directory="$app_bundle/Contents/Frameworks"
model_base_url="https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv5"

case "$(uname -m)" in
    arm64)
        runtime_url="https://files.pythonhosted.org/packages/3d/41/fba0cabccecefe4a1b5fc8020c44febb334637f133acefc7ec492029dd2c/onnxruntime-1.23.2-cp313-cp313-macosx_13_0_arm64.whl"
        runtime_checksum="2ff531ad8496281b4297f32b83b01cdd719617e2351ffe0dba5684fb283afa1f"
        ;;
    x86_64)
        runtime_url="https://files.pythonhosted.org/packages/fe/f9/2d49ca491c6a986acce9f1d1d5fc2099108958cc1710c28e89a032c9cfe9/onnxruntime-1.23.2-cp313-cp313-macosx_13_0_x86_64.whl"
        runtime_checksum="162f4ca894ec3de1a6fd53589e511e06ecdc3ff646849b62a9da7489dee9ce95"
        ;;
    *)
        print -u2 "Unsupported architecture for offline OCR."
        exit 1
        ;;
esac

mkdir -p "$asset_cache" "$model_directory"

function fetch_asset() {
    local url="$1" destination="$2" checksum="$3" temporary_file
    if [[ -f "$destination" ]] && print -r -- "$checksum  $destination" | shasum -a 256 -c --status; then
        return
    fi
    temporary_file="$(mktemp "$asset_cache/.download.XXXXXXXX")"
    if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 120 "$url" -o "$temporary_file" \
        || ! print -r -- "$checksum  $temporary_file" | shasum -a 256 -c --status; then
        unlink "$temporary_file"
        print -u2 "Unable to fetch or verify offline OCR asset: ${destination:t}"
        return 1
    fi
    mv -f "$temporary_file" "$destination"
}

runtime_archive="$asset_cache/onnxruntime-$(uname -m).whl"
fetch_asset "$runtime_url" "$runtime_archive" "$runtime_checksum"
fetch_asset "$model_base_url/det/ch_PP-OCRv5_det_mobile.onnx" "$asset_cache/detect.onnx" \
    "4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae"
fetch_asset "$model_base_url/rec/ch_PP-OCRv5_rec_mobile.onnx" "$asset_cache/recognize.onnx" \
    "5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5"
fetch_asset "$model_base_url/rec/korean_PP-OCRv5_rec_mobile.onnx" "$asset_cache/recognize-ko.onnx" \
    "cd6e2ea50f6943ca7271eb8c56a877a5a90720b7047fe9c41a2e541a25773c9b"
fetch_asset "https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v3.3.2/LICENSE" \
    "$asset_cache/ppocr-LICENSE" "3840c5c0c61c294264d2dd77b8777be6ddd90121ef4e0e64abcd22edea581d6e"

/usr/bin/unzip -p "$runtime_archive" onnxruntime/capi/libonnxruntime.1.23.2.dylib \
    > "$framework_directory/libonnxruntime.dylib"
/usr/bin/unzip -p "$runtime_archive" onnxruntime/LICENSE > "$model_directory/ONNXRuntime-LICENSE"
/usr/bin/unzip -p "$runtime_archive" onnxruntime/ThirdPartyNotices.txt > "$model_directory/ONNXRuntime-ThirdPartyNotices.txt"
cp "$asset_cache"/{detect.onnx,recognize.onnx,recognize-ko.onnx,ppocr-LICENSE} "$model_directory/"
