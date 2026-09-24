use crate::{POLYGLANCE_ERR_NULL_PTR, ffi_status};
use std::ffi::c_char;

#[cfg(not(windows))]
use crate::POLYGLANCE_ERR_INIT;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_ocr_recognize(
    png_bytes: *const u8,
    png_len: usize,
    out_lines_json: *mut *mut c_char,
) -> i32 {
    ffi_status(|| {
        if png_bytes.is_null() || png_len == 0 || out_lines_json.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }

        #[cfg(windows)]
        {
            unsafe { windows_impl::recognize(png_bytes, png_len, out_lines_json) }
        }

        #[cfg(not(windows))]
        {
            let _ = (png_bytes, png_len, out_lines_json);
            POLYGLANCE_ERR_INIT
        }
    })
}

#[cfg(windows)]
mod windows_impl {
    use crate::{
        POLYGLANCE_ERR_INIT, POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_OK, string_to_c_char,
    };
    use serde::Serialize;
    use std::ffi::c_char;
    use windows::Globalization::Language;
    use windows::Graphics::Imaging::BitmapDecoder;
    use windows::Media::Ocr::OcrEngine;
    use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
    use windows::core::HSTRING;

    #[derive(Serialize)]
    pub struct OcrWordResult {
        pub text: String,
        pub x: f64,
        pub y: f64,
        pub width: f64,
        pub height: f64,
    }

    #[derive(Serialize)]
    pub struct OcrLineResult {
        pub text: String,
        pub words: Vec<OcrWordResult>,
    }

    pub unsafe fn recognize(
        png_bytes: *const u8,
        png_len: usize,
        out_lines_json: *mut *mut c_char,
    ) -> i32 {
        let slice = unsafe { std::slice::from_raw_parts(png_bytes, png_len) };
        let bytes = slice.to_vec();

        // WinRT 异步操作在 STA（UI 线程）上同步 .get() 会因消息循环被阻塞而死锁。
        // 在独立的后台线程（MTA）中执行，彻底根除 UI 卡死。
        let worker = std::thread::spawn(move || recognize_png_bytes(&bytes));

        match worker.join() {
            Ok(Ok(lines)) => {
                let json = match serde_json::to_string(&lines) {
                    Ok(j) => j,
                    Err(_) => return POLYGLANCE_ERR_INVALID_INPUT,
                };
                unsafe { *out_lines_json = string_to_c_char(json) };
                POLYGLANCE_OK
            }
            _ => POLYGLANCE_ERR_INIT,
        }
    }

    fn recognize_png_bytes(bytes: &[u8]) -> Result<Vec<OcrLineResult>, String> {
        let stream = InMemoryRandomAccessStream::new()
            .map_err(|e| format!("Create InMemoryRandomAccessStream failed: {e}"))?;
        let writer = DataWriter::CreateDataWriter(&stream)
            .map_err(|e| format!("Create DataWriter failed: {e}"))?;
        writer
            .WriteBytes(bytes)
            .map_err(|e| format!("WriteBytes failed: {e}"))?;
        writer
            .StoreAsync()
            .map_err(|e| format!("StoreAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("StoreAsync get failed: {e}"))?;
        let _ = writer.DetachStream();
        stream.Seek(0).map_err(|e| format!("Seek failed: {e}"))?;

        let decoder = BitmapDecoder::CreateAsync(&stream)
            .map_err(|e| format!("BitmapDecoder CreateAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("Decoder get failed: {e}"))?;
        let software_bitmap = decoder
            .GetSoftwareBitmapAsync()
            .map_err(|e| format!("GetSoftwareBitmapAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("SoftwareBitmap get failed: {e}"))?;

        let engine = create_engine()?;
        let result = engine
            .RecognizeAsync(&software_bitmap)
            .map_err(|e| format!("RecognizeAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("Recognize get failed: {e}"))?;

        let mut lines = Vec::new();
        let result_lines = result
            .Lines()
            .map_err(|e| format!("Get lines failed: {e}"))?;
        for line in result_lines {
            let text = line.Text().unwrap_or_default().to_string();
            let mut words = Vec::new();
            if let Ok(line_words) = line.Words() {
                for word in line_words {
                    let word_text = word.Text().unwrap_or_default().to_string();
                    if let Ok(rect) = word.BoundingRect() {
                        words.push(OcrWordResult {
                            text: word_text,
                            x: rect.X as f64,
                            y: rect.Y as f64,
                            width: rect.Width as f64,
                            height: rect.Height as f64,
                        });
                    }
                }
            }
            lines.push(OcrLineResult { text, words });
        }

        Ok(lines)
    }

    fn create_engine() -> Result<OcrEngine, String> {
        if let Ok(engine) = OcrEngine::TryCreateFromUserProfileLanguages() {
            return Ok(engine);
        }

        let candidates = [
            "zh-Hans",
            "zh-CN",
            "zh-Hans-CN",
            "zh-Hant",
            "zh-TW",
            "zh-HK",
            "en-US",
            "en-GB",
            "en",
            "ja-JP",
            "ja",
            "ko-KR",
            "ko",
        ];

        for tag in candidates {
            if let Ok(lang) = Language::CreateLanguage(&HSTRING::from(tag)) {
                if OcrEngine::IsLanguageSupported(&lang).unwrap_or(false) {
                    if let Ok(engine) = OcrEngine::TryCreateFromLanguage(&lang) {
                        return Ok(engine);
                    }
                }
            }
        }

        if let Ok(langs) = OcrEngine::AvailableRecognizerLanguages() {
            for lang in langs {
                if let Ok(engine) = OcrEngine::TryCreateFromLanguage(&lang) {
                    return Ok(engine);
                }
            }
        }

        Err("No available OCR languages found".to_string())
    }
}
