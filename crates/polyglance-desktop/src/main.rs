#![cfg_attr(windows, windows_subsystem = "windows")]

slint::include_modules!();

#[macro_use]
mod logger;
#[cfg(windows)]
mod hotkeys;
#[cfg(windows)]
mod selected_text;
#[cfg(windows)]
mod startup;
mod preview_update;
mod request_state;
mod secrets;
#[cfg(windows)]
mod single_instance;
mod win32_overlay;
mod pin_window;
mod toolbar_icons_data;

use request_state::RequestTracker;
use slint::{ModelRc, VecModel};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use translator_core::TranslationRequest;
use translator_core::history::{TranslationHistory, TranslationRecord};
use translator_providers::dispatch::{self, FREE_AI, GOOGLE, MICROSOFT, OPENAI_COMPATIBLE, select};

#[cfg(windows)]
fn window_hwnd(window: &slint::Window) -> Result<isize, String> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let provider = window.window_handle();
    let handle = provider
        .window_handle()
        .map_err(|error| error.to_string())?;
    let RawWindowHandle::Win32(win32) = handle.as_raw() else {
        return Err("无法获取 Windows 窗口句柄".into());
    };
    Ok(win32.hwnd.get())
}

#[cfg(windows)]
fn set_window_topmost(window: &slint::Window, enable: bool) -> Result<(), String> {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        HWND_NOTOPMOST, HWND_TOPMOST, SWP_NOMOVE, SWP_NOSIZE, SetWindowPos,
    };
    let hwnd = HWND(window_hwnd(window)? as *mut std::ffi::c_void);
    unsafe {
        SetWindowPos(
            hwnd,
            if enable { HWND_TOPMOST } else { HWND_NOTOPMOST },
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE,
        )
        .map_err(|error| error.to_string())
    }
}

fn show_main_window(window: &MainWindow, tab: i32) {
    window.set_active_tab(tab);
    if window.show().is_err() {
        return;
    }
    #[cfg(windows)]
    if let Ok(handle) = window_hwnd(window.window()) {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{
            SW_RESTORE, SetForegroundWindow, ShowWindow,
        };
        let hwnd = HWND(handle as *mut std::ffi::c_void);
        unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            let _ = SetForegroundWindow(hwnd);
        }
    }
}

fn show_settings_window(window: &SettingsWindow) {
    if window.show().is_err() {
        return;
    }
    #[cfg(windows)]
    if let Ok(handle) = window_hwnd(window.window()) {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{
            SW_RESTORE, SetForegroundWindow, ShowWindow,
        };
        let hwnd = HWND(handle as *mut std::ffi::c_void);
        unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            let _ = SetForegroundWindow(hwnd);
        }
    }
}

#[cfg(windows)]
fn set_window_click_through(window: &slint::Window, enable: bool) -> Result<(), String> {
    if win32_overlay::windows::set_click_through(window_hwnd(window)?, enable) {
        Ok(())
    } else {
        Err("无法设置鼠标穿透".into())
    }
}

#[cfg(not(windows))]
fn set_window_click_through(_window: &slint::Window, _enable: bool) -> Result<(), String> {
    Err("当前平台尚未实现鼠标穿透".into())
}

#[cfg(not(windows))]
fn set_window_topmost(_window: &slint::Window, _enable: bool) -> Result<(), String> {
    Err("当前平台尚未实现窗口置顶".into())
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
#[serde(default)]
struct AppConfig {
    openai_endpoint: String,
    #[serde(skip_serializing, default)]
    openai_key: String,
    #[serde(skip_serializing, default)]
    deepl_key: String,
    click_through_enabled: bool,
    ocr_engine: String,
    minimize_to_tray: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            openai_endpoint: "https://api.openai.com/v1".to_string(),
            openai_key: String::new(),
            deepl_key: String::new(),
            click_through_enabled: false,
            ocr_engine: "系统 OCR".into(),
            minimize_to_tray: true,
        }
    }
}

fn config_path() -> PathBuf {
    if let Ok(appdata) = std::env::var("APPDATA") {
        let p = PathBuf::from(appdata).join("Polyglance");
        let _ = std::fs::create_dir_all(&p);
        return p.join("settings.json");
    }
    PathBuf::from("settings.json")
}

fn history_path() -> PathBuf {
    if let Ok(appdata) = std::env::var("APPDATA") {
        let p = PathBuf::from(appdata).join("Polyglance");
        return p.join("history").join("translation_history.json");
    }
    PathBuf::from("history").join("translation_history.json")
}

use win32_overlay::CapturedImage;

struct CaptureResult {
    image: CapturedImage,
    text: Result<String, String>,
    notice: Option<String>,
}

#[derive(Clone, Copy)]
enum CaptureIntent {
    Screenshot,
    Translate,
    Ocr,
}

impl CaptureIntent {
    fn from_ui(value: i32) -> Self {
        match value {
            1 => Self::Translate,
            2 => Self::Ocr,
            _ => Self::Screenshot,
        }
    }
}

#[cfg(windows)]
fn run_long_capture(stop: &AtomicBool) -> Result<PathBuf, String> {
    use capture_core::stitch::{Configuration, Direction, Stitcher};
    use image::ImageEncoder;
    let rect = win32_overlay::windows::select_screen_region_rect().ok_or("已取消长截图选区")?;
    let mut stitcher = Stitcher::new(Configuration::default(), Direction::Vertical);
    for index in 0..600 {
        if index > 0 && stop.load(Ordering::Acquire) {
            break;
        }
        let frame = polyglance_cabi::native_capture::capture_screen_region(
            rect.x.floor() as i32,
            rect.y.floor() as i32,
            rect.width.ceil() as u32,
            rect.height.ceil() as u32,
        )?;
        let mut rgba = frame.bgra;
        for pixel in rgba.chunks_exact_mut(4) {
            pixel.swap(0, 2);
            pixel[3] = 255;
        }
        match stitcher.append(rgba, frame.width, frame.height) {
            Ok(result) if result.limit_reached.is_some() => break,
            Ok(_) | Err(capture_core::stitch::StitchError::NoReliableVerticalOverlap) => {}
            Err(error) => return Err(format!("长截图拼接失败: {error:?}")),
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    let rgba = stitcher
        .render()
        .map_err(|error| format!("长截图导出失败: {error:?}"))?;
    let folder = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Polyglance")
        .join("LongScreenshots");
    std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_millis();
    let path = folder.join(format!("LongScreenshot-{timestamp}.png"));
    let file = std::fs::File::create(&path).map_err(|error| error.to_string())?;
    image::codecs::png::PngEncoder::new(file)
        .write_image(
            &rgba,
            stitcher.output_width(),
            stitcher.output_height(),
            image::ExtendedColorType::Rgba8,
        )
        .map_err(|error| error.to_string())?;
    Ok(path)
}

#[cfg(windows)]
fn run_recording(stop: &AtomicBool) -> Result<PathBuf, String> {
    use capture_core::recording::{RecordingFormat, RecordingQuality, profile};
    use capture_core::rect::Size;
    let rect = win32_overlay::windows::select_screen_region_rect().ok_or("已取消录屏选区")?;
    let capture_w = rect.width.ceil() as u32;
    let capture_h = rect.height.ceil() as u32;
    let encoding = profile(RecordingQuality::Standard, RecordingFormat::Mp4);
    let output_size = encoding.output_size(Size::new(capture_w as f64, capture_h as f64));
    let output_w = output_size.width as u32;
    let output_h = output_size.height as u32;
    if output_w < 2 || output_h < 2 {
        return Err("录屏选区太小".into());
    }
    let folder = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Polyglance")
        .join("Videos");
    std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_millis();
    let path = folder.join(format!("Recording-{timestamp}.mp4"));
    let encoder = polyglance_cabi::RecordingEncoder::new(
        &path,
        output_w,
        output_h,
        encoding.frame_rate,
        encoding.video_bitrate(output_size, None),
    )?;
    let start = std::time::Instant::now();
    let interval = std::time::Duration::from_secs_f64(1.0 / encoding.frame_rate as f64);
    let result = (|| {
        for index in 0..(encoding.frame_rate * 600) {
            if index > 0 && stop.load(Ordering::Acquire) {
                break;
            }
            let frame = polyglance_cabi::native_capture::capture_screen_region(
                rect.x.floor() as i32,
                rect.y.floor() as i32,
                capture_w,
                capture_h,
            )?;
            let pixels = if capture_w == output_w && capture_h == output_h {
                frame.bgra
            } else {
                let mut rgba = frame.bgra;
                for pixel in rgba.chunks_exact_mut(4) {
                    pixel.swap(0, 2);
                    pixel[3] = 255;
                }
                let source = image::RgbaImage::from_raw(capture_w, capture_h, rgba)
                    .ok_or("无效的录屏图像缓冲区")?;
                let mut resized = image::imageops::resize(
                    &source,
                    output_w,
                    output_h,
                    image::imageops::FilterType::Triangle,
                )
                .into_raw();
                for pixel in resized.chunks_exact_mut(4) {
                    pixel.swap(0, 2);
                }
                resized
            };
            let time = (start.elapsed().as_nanos() / 100) as i64;
            encoder.write_bgra_frame(pixels, time)?;
            let target = start + interval.mul_f64((index + 1) as f64);
            if let Some(wait) = target.checked_duration_since(std::time::Instant::now()) {
                std::thread::sleep(wait);
            }
        }
        encoder.finish((start.elapsed().as_nanos() / 100) as i64)
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&path);
        return Err(error);
    }
    Ok(path)
}

#[cfg(not(windows))]
fn run_recording(_stop: &AtomicBool) -> Result<PathBuf, String> {
    Err("当前平台尚未实现录屏编码".into())
}

#[cfg(not(windows))]
fn run_long_capture(_stop: &AtomicBool) -> Result<PathBuf, String> {
    Err("当前平台尚未实现长截图捕获".into())
}

#[cfg(windows)]
fn capture_image(rect: capture_core::rect::Rect) -> Result<CapturedImage, String> {
    let frame = polyglance_cabi::native_capture::capture_screen_region(
        rect.x.floor() as i32,
        rect.y.floor() as i32,
        rect.width.ceil() as u32,
        rect.height.ceil() as u32,
    )?;
    let mut rgba = frame.bgra;
    for pixel in rgba.chunks_exact_mut(4) {
        pixel.swap(0, 2);
        pixel[3] = 255;
    }
    Ok(CapturedImage {
        width: frame.width,
        height: frame.height,
        rgba,
    })
}

#[cfg(not(windows))]
fn capture_image(_rect: capture_core::rect::Rect) -> Result<CapturedImage, String> {
    Err("当前平台尚未实现截图捕获".into())
}

#[cfg(windows)]
fn ocr_captured_image(image: CapturedImage, engine: &str) -> Result<CaptureResult, String> {
    use image::ImageEncoder;
    let mut notice = None;
    let onnx_result = if engine == "ONNX OCR" {
        let result = (|| {
            let runtime = model_core::default_runtime_path()?;
            let mut ocr =
                model_core::ocr::OnnxOcr::open(&runtime, &model_core::default_model_directory())?;
            ocr.recognize_rgba(&image.rgba, image.width as usize, image.height as usize)
        })();
        if let Err(error) = &result {
            notice = Some(format!("ONNX OCR 未完成，已改用系统 OCR: {error}"));
        }
        Some(result)
    } else {
        None
    };
    let text = onnx_result.and_then(Result::ok).map(Ok).unwrap_or_else(|| {
        (|| {
            let mut png = Vec::new();
            image::codecs::png::PngEncoder::new(&mut png)
                .write_image(
                    &image.rgba,
                    image.width,
                    image.height,
                    image::ExtendedColorType::Rgba8,
                )
                .map_err(|error| error.to_string())?;
            let lines = polyglance_cabi::winrt_ocr::recognize_png_bytes(&png)?;
            Ok(lines
                .into_iter()
                .map(|line| line.text)
                .collect::<Vec<_>>()
                .join("\n"))
        })()
    });
    Ok(CaptureResult {
        image,
        text,
        notice,
    })
}

#[cfg(not(windows))]
fn ocr_captured_image(image: CapturedImage, _engine: &str) -> Result<CaptureResult, String> {
    Ok(CaptureResult {
        image,
        text: Err("当前平台尚未实现截图 OCR".into()),
        notice: None,
    })
}

fn map_language_name(name: &str) -> &str {
    match name {
        "中文 (简体)" | "中文" => "zh-Hans",
        "英语" => "en",
        "日语" => "ja",
        "韩语" => "ko",
        "法语" => "fr",
        "德语" => "de",
        "俄语" => "ru",
        _ => "zh-Hans",
    }
}

fn make_history_entries(history: &TranslationHistory) -> Vec<HistoryEntry> {
    history
        .records()
        .iter()
        .take(100)
        .map(|r| HistoryEntry {
            id: r.id.clone().into(),
            time: r.timestamp.clone().into(),
            provider: r.provider.clone().into(),
            source: r.source_text.clone().into(),
            target: r.target_text.clone().into(),
        })
        .collect()
}

#[cfg(not(windows))]
fn spawn_pin_window(
    pinned_windows: &Rc<RefCell<Vec<PinWindow>>>,
    image: &CapturedImage,
    pos: Option<(i32, i32)>,
    config: Arc<Mutex<AppConfig>>,
) {
    let pin = match PinWindow::new() {
        Ok(pin) => pin,
        Err(error) => {
            log_error!("PIN", "Failed to create pin window: {error}");
            return;
        }
    };
    let pixels = slint::SharedPixelBuffer::<slint::Rgba8Pixel>::clone_from_slice(
        &image.rgba,
        image.width,
        image.height,
    );
    pin.set_pinned_image(slint::Image::from_rgba8(pixels));
    let w_px = image.width.max(1);
    let h_px = image.height.max(1);
    pin.window().set_size(slint::PhysicalSize::new(w_px, h_px));
    if let Some((x, y)) = pos {
        pin.window().set_position(slint::PhysicalPosition::new(x, y));
    }

    if let Err(error) = pin.show() {
        log_error!("PIN", "Failed to show pin window: {error}");
        return;
    }

    let pin_weak = pin.as_weak();
    let click_through = config.lock().unwrap().click_through_enabled;
    let _ = slint::invoke_from_event_loop(move || {
        if let Some(pin) = pin_weak.upgrade() {
            let _ = set_window_topmost(pin.window(), true);
            #[cfg(windows)]
            if let Ok(hwnd) = window_hwnd(pin.window()) {
                unsafe {
                    use ::windows::Win32::Foundation::HWND;
                    use ::windows::Win32::UI::WindowsAndMessaging::{
                        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE,
                        GWL_STYLE, HWND_TOPMOST, SWP_FRAMECHANGED, SWP_SHOWWINDOW,
                        WS_CAPTION, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_MAXIMIZEBOX,
                        WS_MINIMIZEBOX, WS_POPUP, WS_THICKFRAME,
                    };
                    let w = HWND(hwnd as *mut std::ffi::c_void);
                    let style = GetWindowLongPtrW(w, GWL_STYLE) as u32;
                    let new_style = (style & !WS_CAPTION.0 & !WS_THICKFRAME.0 & !WS_MINIMIZEBOX.0 & !WS_MAXIMIZEBOX.0) | WS_POPUP.0;
                    SetWindowLongPtrW(w, GWL_STYLE, new_style as isize);
                    let ex_style = GetWindowLongPtrW(w, GWL_EXSTYLE) as u32;
                    let new_ex_style = ex_style | WS_EX_TOPMOST.0 | WS_EX_TOOLWINDOW.0;
                    SetWindowLongPtrW(w, GWL_EXSTYLE, new_ex_style as isize);
                    if let Some((x, y)) = pos {
                        let _ = SetWindowPos(
                            w,
                            HWND_TOPMOST,
                            x,
                            y,
                            w_px as i32,
                            h_px as i32,
                            SWP_SHOWWINDOW | SWP_FRAMECHANGED,
                        );
                    }
                }
            }
            if click_through {
                let _ = set_window_click_through(pin.window(), true);
            }
        }
    });

    pin.on_close_pin({
        let pin_weak = pin.as_weak();
        move || {
            if let Some(pin) = pin_weak.upgrade() {
                let _ = pin.hide();
            }
        }
    });

    pin.on_start_drag({
        let pin_weak = pin.as_weak();
        move || {
            if let Some(_pin) = pin_weak.upgrade() {
                #[cfg(windows)]
                if let Ok(hwnd) = window_hwnd(_pin.window()) {
                    unsafe {
                        use ::windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
                        use ::windows::Win32::UI::Input::KeyboardAndMouse::ReleaseCapture;
                        use ::windows::Win32::UI::WindowsAndMessaging::{
                            HTCAPTION, SendMessageW, WM_NCLBUTTONDOWN,
                        };
                        let w = HWND(hwnd as *mut std::ffi::c_void);
                        let _ = ReleaseCapture();
                        let _ = SendMessageW(w, WM_NCLBUTTONDOWN, WPARAM(HTCAPTION as usize), LPARAM(0));
                    }
                }
            }
        }
    });

    pinned_windows.borrow_mut().push(pin);
}

fn main() {
    if let Err(error) = run() {
        #[cfg(windows)]
        {
            use windows::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};
            use windows::core::PCWSTR;
            let message: Vec<u16> = format!("Polyglance 启动失败: {error}")
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let title: Vec<u16> = "Polyglance Rust Preview"
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            unsafe {
                let _ = MessageBoxW(
                    None,
                    PCWSTR(message.as_ptr()),
                    PCWSTR(title.as_ptr()),
                    MB_OK | MB_ICONERROR,
                );
            }
        }
        #[cfg(not(windows))]
        eprintln!("Polyglance 启动失败: {error}");
        std::process::exit(1);
    }
}

#[tokio::main]
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    logger::init();
    log_info!("APP", "Polyglance Rust Desktop starting up (version: {})", env!("CARGO_PKG_VERSION"));

    #[cfg(windows)]
    let mut single_instance = match single_instance::ActivationEvent::acquire()? {
        Some(instance) => instance,
        None => {
            log_info!("APP", "Another instance is already running; activating existing instance");
            return Ok(());
        }
    };
    let main_window = MainWindow::new()?;
    let settings_window = SettingsWindow::new()?;

    // Load config
    let cfg_file = config_path();
    let mut config = if cfg_file.exists() {
        let text = std::fs::read_to_string(&cfg_file).unwrap_or_default();
        serde_json::from_str::<AppConfig>(&text).unwrap_or_default()
    } else {
        AppConfig::default()
    };
    match secrets::load() {
        Ok(stored) => {
            let had_plaintext = !config.openai_key.is_empty() || !config.deepl_key.is_empty();
            if config.openai_key.is_empty() {
                config.openai_key = stored.openai_key;
            }
            if config.deepl_key.is_empty() {
                config.deepl_key = stored.deepl_key;
            }
            if had_plaintext {
                let migration = secrets::save(&secrets::ApiSecrets {
                    openai_key: config.openai_key.clone(),
                    deepl_key: config.deepl_key.clone(),
                });
                if migration.is_ok() {
                    if let Ok(json) = serde_json::to_string_pretty(&config) {
                        let _ = std::fs::write(&cfg_file, json);
                    }
                } else if let Err(error) = migration {
                    main_window.set_status_text(format!("迁移 API Key 失败: {error}").into());
                }
            }
        }
        Err(error) => main_window.set_status_text(format!("读取受保护凭据失败: {error}").into()),
    }
    settings_window.set_openai_endpoint(config.openai_endpoint.clone().into());
    settings_window.set_openai_key(config.openai_key.clone().into());
    settings_window.set_deepl_key(config.deepl_key.clone().into());
    settings_window.set_click_through_enabled(config.click_through_enabled);
    settings_window.set_ocr_engine(config.ocr_engine.clone().into());
    settings_window.set_version_text(format!("v{} (1)", env!("CARGO_PKG_VERSION")).into());
    let data_dir_str = std::env::var("APPDATA")
        .map(|appdata| format!("{}\\Polyglance", appdata))
        .unwrap_or_else(|_| "C:\\Users\\user\\AppData\\Roaming\\Polyglance".into());
    settings_window.set_data_directory(data_dir_str.clone().into());
    #[cfg(windows)]
    settings_window.set_autostart_enabled(startup::is_enabled().unwrap_or(false));
    #[cfg(not(windows))]
    settings_window.set_autostart_enabled(false);
    settings_window.set_minimize_to_tray(config.minimize_to_tray);

    main_window.set_ocr_engine(config.ocr_engine.clone().into());

    let config_state = Arc::new(Mutex::new(config));
    let close_config = config_state.clone();
    main_window.window().on_close_requested(move || {
        if !close_config.lock().unwrap().minimize_to_tray {
            let _ = slint::quit_event_loop();
        }
        slint::CloseRequestResponse::HideWindow
    });

    // Load history
    let h_file = history_path();
    let (loaded_history, can_save_history) = match TranslationHistory::try_load_from_file(&h_file) {
        Ok(history) => (history, true),
        Err(error) => {
            main_window
                .set_status_text(format!("历史记录读取失败，已停止写入该文件: {error}").into());
            (TranslationHistory::new(), false)
        }
    };
    let history_writable = Arc::new(AtomicBool::new(can_save_history));
    let history_state = Arc::new(Mutex::new(loaded_history));
    main_window.set_history_list(ModelRc::new(VecModel::from(make_history_entries(
        &history_state.lock().unwrap(),
    ))));
    let installed_count = model_core::list_model_files(&model_core::default_model_directory())
        .map(|files| files.len())
        .unwrap_or(0);
    if installed_count > 0 {
        main_window.set_model_status(format!("已安装 {installed_count} 个 ONNX 模型").into());
    }

    // 1. Translation Handler
    let window_weak = main_window.as_weak();
    let history_for_translate = history_state.clone();
    let writable_for_translate = history_writable.clone();
    let config_for_translate = config_state.clone();
    let tracker = Arc::new(RequestTracker::default());
    let tracker_for_translate = tracker.clone();

    let run_translation = move || {
        let Some(window) = window_weak.upgrade() else {
            return;
        };
        let text = window.get_source_text().to_string();
        if text.trim().is_empty() {
            return;
        }

        let raw_target_lang = window.get_target_language().to_string();
        let target_lang = map_language_name(&raw_target_lang).to_string();
        let request_id = tracker_for_translate.start(4);

        window.set_is_translating(true);
        window.set_free_ai_loading(true);
        window.set_google_loading(true);
        window.set_ms_loading(true);
        window.set_custom_loading(true);
        window.set_status_text("正在并发请求各翻译服务商...".into());

        // Free AI Task
        let w_free = window_weak.clone();
        let t_free = text.clone();
        let lang_free = target_lang.clone();
        let hist_free = history_for_translate.clone();
        let writable_free = writable_for_translate.clone();
        let free_tracker = tracker_for_translate.clone();
        tokio::spawn(async move {
            if let Ok(req) = TranslationRequest::new(&t_free, None, &lang_free) {
                if let Ok(selection) = select(FREE_AI, String::new(), String::new(), String::new())
                {
                    if let Ok(res) = dispatch::translate(selection, &req).await {
                        let res_text = res.text.clone();
                        let entries = if free_tracker.is_current(request_id) {
                            let mut h = hist_free.lock().unwrap();
                            let rec = TranslationRecord::new(
                                &t_free, &res_text, "auto", &lang_free, "Free AI",
                            );
                            h.add_record(rec);
                            if writable_free.load(Ordering::Acquire) {
                                let _ = h.save_to_file(&history_path());
                            }
                            Some(make_history_entries(&h))
                        } else {
                            None
                        };

                        let finish_tracker = free_tracker.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(w) = w_free.upgrade() {
                                if !finish_tracker.is_current(request_id) {
                                    return;
                                }
                                w.set_free_ai_translation(res_text.into());
                                w.set_free_ai_loading(false);
                                w.set_status_text("官方 AI 响应完成".into());
                                if let Some(entries) = entries {
                                    w.set_history_list(ModelRc::new(VecModel::from(entries)));
                                }
                                if finish_tracker.finish(request_id) == Some(true) {
                                    w.set_is_translating(false);
                                }
                            }
                        });
                        return;
                    }
                }
            }
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(w) = w_free.upgrade() {
                    if !free_tracker.is_current(request_id) {
                        return;
                    }
                    w.set_free_ai_loading(false);
                    if free_tracker.finish(request_id) == Some(true) {
                        w.set_is_translating(false);
                    }
                }
            });
        });

        // Google Translate Task
        let w_google = window_weak.clone();
        let t_google = text.clone();
        let lang_google = target_lang.clone();
        let google_tracker = tracker_for_translate.clone();
        tokio::spawn(async move {
            if let Ok(req) = TranslationRequest::new(&t_google, None, &lang_google) {
                if let Ok(selection) = select(GOOGLE, String::new(), String::new(), String::new()) {
                    if let Ok(res) = dispatch::translate(selection, &req).await {
                        let finish_tracker = google_tracker.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(w) = w_google.upgrade() {
                                if !finish_tracker.is_current(request_id) {
                                    return;
                                }
                                w.set_google_translation(res.text.into());
                                w.set_google_loading(false);
                                if finish_tracker.finish(request_id) == Some(true) {
                                    w.set_is_translating(false);
                                }
                            }
                        });
                        return;
                    }
                }
            }
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(w) = w_google.upgrade() {
                    if !google_tracker.is_current(request_id) {
                        return;
                    }
                    w.set_google_loading(false);
                    if google_tracker.finish(request_id) == Some(true) {
                        w.set_is_translating(false);
                    }
                }
            });
        });

        // Microsoft Translate Task
        let w_ms = window_weak.clone();
        let t_ms = text.clone();
        let lang_ms = target_lang.clone();
        let ms_tracker = tracker_for_translate.clone();
        tokio::spawn(async move {
            if let Ok(req) = TranslationRequest::new(&t_ms, None, &lang_ms) {
                if let Ok(selection) =
                    select(MICROSOFT, String::new(), String::new(), String::new())
                {
                    if let Ok(res) = dispatch::translate(selection, &req).await {
                        let finish_tracker = ms_tracker.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(w) = w_ms.upgrade() {
                                if !finish_tracker.is_current(request_id) {
                                    return;
                                }
                                w.set_ms_translation(res.text.into());
                                w.set_ms_loading(false);
                                if finish_tracker.finish(request_id) == Some(true) {
                                    w.set_is_translating(false);
                                }
                            }
                        });
                        return;
                    }
                }
            }
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(w) = w_ms.upgrade() {
                    if !ms_tracker.is_current(request_id) {
                        return;
                    }
                    w.set_ms_loading(false);
                    if ms_tracker.finish(request_id) == Some(true) {
                        w.set_is_translating(false);
                    }
                }
            });
        });

        // Custom OpenAI Compatible Task
        let w_custom = window_weak.clone();
        let t_custom = text.clone();
        let lang_custom = target_lang.clone();
        let cfg = config_for_translate.lock().unwrap().clone();
        let custom_tracker = tracker_for_translate.clone();
        let is_key_empty = cfg.openai_key.is_empty();
        tokio::spawn(async move {
            if !is_key_empty {
                if let Ok(req) = TranslationRequest::new(&t_custom, None, &lang_custom) {
                    if let Ok(selection) = select(
                        OPENAI_COMPATIBLE,
                        cfg.openai_endpoint,
                        cfg.openai_key,
                        String::new(),
                    ) {
                        if let Ok(res) = dispatch::translate(selection, &req).await {
                            let finish_tracker = custom_tracker.clone();
                            let _ = slint::invoke_from_event_loop(move || {
                                if let Some(w) = w_custom.upgrade() {
                                    if !finish_tracker.is_current(request_id) {
                                        return;
                                    }
                                    w.set_custom_translation(res.text.into());
                                    w.set_custom_loading(false);
                                    if finish_tracker.finish(request_id) == Some(true) {
                                        w.set_is_translating(false);
                                    }
                                }
                            });
                            return;
                        }
                    }
                }
            }
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(w) = w_custom.upgrade() {
                    if !custom_tracker.is_current(request_id) {
                        return;
                    }
                    w.set_custom_loading(false);
                    if custom_tracker.finish(request_id) == Some(true) {
                        w.set_is_translating(false);
                    }
                    if is_key_empty {
                        w.set_custom_translation("未配置 OpenAI API Key，请在设置中配置".into());
                    }
                }
            });
        });
    };

    let run_translate_clone = run_translation.clone();
    main_window.on_translate_clicked(run_translate_clone);

    // 2. Clear
    let window_weak = main_window.as_weak();
    let tracker_for_clear = tracker.clone();
    main_window.on_clear_clicked(move || {
        tracker_for_clear.cancel();
        if let Some(w) = window_weak.upgrade() {
            w.set_is_translating(false);
            w.set_free_ai_loading(false);
            w.set_google_loading(false);
            w.set_ms_loading(false);
            w.set_custom_loading(false);
            w.set_status_text("就绪".into());
        }
    });

    // 3. Swap Languages
    let window_weak = main_window.as_weak();
    main_window.on_swap_languages_clicked(move || {
        if let Some(w) = window_weak.upgrade() {
            let src = w.get_source_language();
            let tgt = w.get_target_language();
            if src != "自动检测" {
                w.set_source_language(tgt.clone());
            }
            w.set_target_language(src);
        }
    });

    // 4. Copy Text to System Clipboard
    let window_weak = main_window.as_weak();
    main_window.on_copy_text_clicked(move |text| {
        let s = text.to_string();
        if !s.is_empty() {
            if let Ok(mut cb) = arboard::Clipboard::new() {
                let _ = cb.set_text(s);
                if let Some(w) = window_weak.upgrade() {
                    w.set_status_text("已复制到剪贴板".into());
                }
            }
        }
    });

    // 5. Clipboard Translate
    let window_weak = main_window.as_weak();
    let run_translate_for_cb = run_translation.clone();
    main_window.on_clipboard_translate_clicked(move || {
        if let Ok(mut cb) = arboard::Clipboard::new() {
            if let Ok(text) = cb.get_text() {
                if !text.trim().is_empty() {
                    if let Some(w) = window_weak.upgrade() {
                        w.set_source_text(text.trim().into());
                        run_translate_for_cb();
                    }
                }
            }
        }
    });

    let pinned_windows = Rc::new(RefCell::new(Vec::<PinWindow>::new()));
    let pin_request = Arc::new(Mutex::new(None::<(CapturedImage, Option<(i32, i32)>)>));

    // 6. Screenshot Translate
    let window_weak = main_window.as_weak();
    let run_translate_for_screenshot = run_translation.clone();
    let last_capture = Arc::new(Mutex::new(None::<CapturedImage>));
    let capture_for_screenshot = last_capture.clone();
    let pin_for_screenshot = pin_request.clone();
    main_window.on_capture_requested(move |requested_intent| {
        let intent = CaptureIntent::from_ui(requested_intent);
        let Some(window) = window_weak.upgrade() else {
            return;
        };
        log_info!("CAPTURE", "on_capture_requested triggered with intent: {}", requested_intent);
        window.set_status_text("进入跨屏截取遮罩模式...".into());
        let was_visible = window.window().is_visible();
        let _ = window.hide();

        let window_weak_async = window_weak.clone();
        let run_translate_after_capture = run_translate_for_screenshot.clone();
        let capture_slot = capture_for_screenshot.clone();
        let pin_slot = pin_for_screenshot.clone();
        let engine = window.get_ocr_engine().to_string();
        std::thread::spawn(move || {
            log_info!("CAPTURE", "Overlay thread started, invoking select_screen_region()");
            let selection = win32_overlay::windows::select_screen_region();
            log_info!("CAPTURE", "select_screen_region returned: {:?}", selection);

            let Some(sel) = selection else {
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(w) = window_weak_async.upgrade() {
                        w.set_status_text("用户取消截图".into());
                    }
                });
                return;
            };

            let rect = sel.rect;
            let action = match intent {
                CaptureIntent::Translate => win32_overlay::ScreenshotAction::Translate,
                CaptureIntent::Ocr => win32_overlay::ScreenshotAction::Ocr,
                CaptureIntent::Screenshot => sel.action,
            };

            match action {
                win32_overlay::ScreenshotAction::Copy => {
                    log_info!("CAPTURE", "Action Copy: copying screenshot to clipboard");
                    let captured_opt = sel.image.or_else(|| capture_image(rect).ok());
                    if let Some(img) = &captured_opt {
                        if let Ok(mut cb) = arboard::Clipboard::new() {
                            let img_data = arboard::ImageData {
                                width: img.width as usize,
                                height: img.height as usize,
                                bytes: std::borrow::Cow::Borrowed(&img.rgba),
                            };
                            let _ = cb.set_image(img_data);
                        }
                    }
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            if let Some(img) = captured_opt {
                                *capture_slot.lock().unwrap() = Some(img);
                            }
                            if was_visible {
                                show_main_window(&w, 0);
                            }
                            w.set_status_text("截图已复制到剪贴板".into());
                        }
                    });
                }
                win32_overlay::ScreenshotAction::Pin => {
                    log_info!("CAPTURE", "Action Pin: opening pin window in-place");
                    let captured_opt = sel.image.or_else(|| capture_image(rect).ok());
                    let pos = Some((rect.x.round() as i32, rect.y.round() as i32));
                    if let Some(img) = &captured_opt {
                        *pin_slot.lock().unwrap() = Some((img.clone(), pos));
                        *capture_slot.lock().unwrap() = Some(img.clone());
                        #[cfg(windows)]
                        {
                            pin_window::windows::spawn_native_pin(img.clone(), pos);
                        }
                    }
                    #[cfg(not(windows))]
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            if let Some(img) = captured_opt {
                                *capture_slot.lock().unwrap() = Some(img);
                                w.invoke_pin_capture_clicked();
                            }
                            if was_visible {
                                show_main_window(&w, 0);
                            }
                        }
                    });
                }
                win32_overlay::ScreenshotAction::Save => {
                    log_info!("CAPTURE", "Action Save: saving screenshot to file");
                    let captured_opt = sel.image.or_else(|| capture_image(rect).ok());
                    if let Some(img) = &captured_opt {
                        if let Ok(mut cb) = arboard::Clipboard::new() {
                            let img_data = arboard::ImageData {
                                width: img.width as usize,
                                height: img.height as usize,
                                bytes: std::borrow::Cow::Borrowed(&img.rgba),
                            };
                            let _ = cb.set_image(img_data);
                        }
                        let folder = std::env::var_os("USERPROFILE")
                            .map(PathBuf::from)
                            .unwrap_or_else(|| PathBuf::from("."))
                            .join("Pictures")
                            .join("Polyglance");
                        let _ = std::fs::create_dir_all(&folder);
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_secs())
                            .unwrap_or(0);
                        let path = folder.join(format!("Screenshot_{now}.png"));
                        if let Ok(file) = std::fs::File::create(&path) {
                            use image::ImageEncoder;
                            let _ = image::codecs::png::PngEncoder::new(file).write_image(
                                &img.rgba,
                                img.width,
                                img.height,
                                image::ExtendedColorType::Rgba8,
                            );
                        }
                    }
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            if let Some(img) = captured_opt {
                                *capture_slot.lock().unwrap() = Some(img);
                            }
                            if was_visible {
                                show_main_window(&w, 0);
                            }
                            w.set_status_text("截图已保存至图片目录并复制到剪贴板".into());
                        }
                    });
                }
                win32_overlay::ScreenshotAction::Translate => {
                    log_info!("CAPTURE", "Action Translate: starting OCR and translation");
                    let captured_res = sel.image.ok_or_else(|| "无法获取截图".to_string()).or_else(|_| capture_image(rect));
                    let res = captured_res.and_then(|img| ocr_captured_image(img, &engine));
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            show_main_window(&w, 0);
                            match res {
                                Ok(result) => {
                                    *capture_slot.lock().unwrap() = Some(result.image);
                                    if let Some(notice) = result.notice {
                                        w.set_model_status(notice.into());
                                    }
                                    match result.text {
                                        Ok(text) if !text.trim().is_empty() => {
                                            w.set_source_text(text.into());
                                            run_translate_after_capture();
                                        }
                                        Ok(_) => w.set_status_text("选区内未识别到文字，可使用贴图按钮查看图像".into()),
                                        Err(e) => w.set_status_text(format!("OCR 失败: {e}").into()),
                                    }
                                }
                                Err(e) => w.set_status_text(format!("截图识别失败: {e}").into()),
                            }
                        }
                    });
                }
                win32_overlay::ScreenshotAction::Ocr => {
                    log_info!("CAPTURE", "Action Ocr: starting OCR only");
                    let captured_res = sel.image.ok_or_else(|| "无法获取截图".to_string()).or_else(|_| capture_image(rect));
                    let res = captured_res.and_then(|img| ocr_captured_image(img, &engine));
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            show_main_window(&w, 0);
                            match res {
                                Ok(result) => {
                                    *capture_slot.lock().unwrap() = Some(result.image);
                                    if let Some(notice) = result.notice {
                                        w.set_model_status(notice.into());
                                    }
                                    match result.text {
                                        Ok(text) if !text.trim().is_empty() => {
                                            w.set_source_text(text.into());
                                            w.set_status_text("文字识别完成".into());
                                        }
                                        Ok(_) => w.set_status_text("选区内未识别到文字，可使用贴图按钮查看图像".into()),
                                        Err(e) => w.set_status_text(format!("OCR 失败: {e}").into()),
                                    }
                                }
                                Err(e) => w.set_status_text(format!("截图识别失败: {e}").into()),
                            }
                        }
                    });
                }
                win32_overlay::ScreenshotAction::LongScreenshot => {
                    log_info!("CAPTURE", "Action LongScreenshot: triggering long capture");
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            show_main_window(&w, 0);
                            w.invoke_long_capture_clicked();
                        }
                    });
                }
                win32_overlay::ScreenshotAction::ScreenRecording => {
                    log_info!("CAPTURE", "Action ScreenRecording: triggering screen recording");
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = window_weak_async.upgrade() {
                            show_main_window(&w, 0);
                            w.invoke_recording_clicked();
                        }
                    });
                }
            }
        });
    });

    let long_capture_stop = Arc::new(AtomicBool::new(false));
    let stop_for_handler = long_capture_stop.clone();
    let window_weak = main_window.as_weak();
    main_window.on_long_capture_clicked(move || {
        let Some(window) = window_weak.upgrade() else {
            return;
        };
        if window.get_is_long_capturing() {
            stop_for_handler.store(true, Ordering::Release);
            window.set_status_text("正在生成长截图...".into());
            return;
        }
        stop_for_handler.store(false, Ordering::Release);
        window.set_is_long_capturing(true);
        window.set_status_text("框选区域后手动滚动页面，完成时点击停止按钮".into());
        let _ = window.hide();
        let stop = stop_for_handler.clone();
        let weak = window_weak.clone();
        std::thread::spawn(move || {
            let result = run_long_capture(&stop);
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = weak.upgrade() {
                    window.set_is_long_capturing(false);
                    show_main_window(&window, 0);
                    match result {
                        Ok(path) => window
                            .set_status_text(format!("长截图已保存: {}", path.display()).into()),
                        Err(error) => window.set_status_text(error.into()),
                    }
                }
            });
        });
    });

    let recording_stop = Arc::new(AtomicBool::new(false));
    let stop_for_recording = recording_stop.clone();
    let window_weak = main_window.as_weak();
    main_window.on_recording_clicked(move || {
        let Some(window) = window_weak.upgrade() else {
            return;
        };
        if window.get_is_recording() {
            stop_for_recording.store(true, Ordering::Release);
            window.set_status_text("正在完成录屏编码...".into());
            return;
        }
        stop_for_recording.store(false, Ordering::Release);
        window.set_is_recording(true);
        window.set_status_text("框选录屏区域，录制完毕后点击停止按钮".into());
        let _ = window.hide();
        let stop = stop_for_recording.clone();
        let weak = window_weak.clone();
        std::thread::spawn(move || {
            let result = run_recording(&stop);
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = weak.upgrade() {
                    window.set_is_recording(false);
                    show_main_window(&window, 0);
                    match result {
                        Ok(path) => {
                            window.set_status_text(format!("录屏已保存: {}", path.display()).into())
                        }
                        Err(error) => window.set_status_text(error.into()),
                    }
                }
            });
        });
    });

    let capture_for_pin = last_capture.clone();
    let pin_request_for_pin = pin_request.clone();
    #[cfg(not(windows))]
    let windows_for_pin = pinned_windows.clone();
    #[cfg(not(windows))]
    let config_for_pin = config_state.clone();
    let window_weak = main_window.as_weak();
    main_window.on_pin_capture_clicked(move || {
        let (image, pos) = if let Some(pair) = pin_request_for_pin.lock().unwrap().take() {
            (pair.0, pair.1)
        } else if let Some(img) = capture_for_pin.lock().unwrap().as_ref() {
            (img.clone(), None)
        } else {
            if let Some(w) = window_weak.upgrade() {
                w.set_status_text("请先截取图像，再创建贴图".into());
            }
            return;
        };
        #[cfg(windows)]
        {
            pin_window::windows::spawn_native_pin(image, pos);
        }
        #[cfg(not(windows))]
        {
            spawn_pin_window(&windows_for_pin, &image, pos, config_for_pin.clone());
        }
    });

    // 7. Pin Window Toggle
    let window_weak = main_window.as_weak();
    main_window.on_toggle_pin_clicked(move || {
        if let Some(w) = window_weak.upgrade() {
            let next = !w.get_is_pinned();
            match set_window_topmost(w.window(), next) {
                Ok(()) => {
                    w.set_is_pinned(next);
                    w.set_status_text(
                        if next {
                            "窗口已置顶"
                        } else {
                            "窗口取消置顶"
                        }
                        .into(),
                    );
                }
                Err(error) => w.set_status_text(format!("窗口置顶失败: {error}").into()),
            }
        }
    });

    let window_weak = main_window.as_weak();
    main_window.on_toggle_favorite_clicked(move || {
        if let Some(w) = window_weak.upgrade() {
            let next = !w.get_is_favorite();
            w.set_is_favorite(next);
            w.set_status_text(if next { "已收藏当前翻译" } else { "已取消收藏" }.into());
        }
    });

    let window_weak = main_window.as_weak();
    main_window.on_toggle_fold_input_clicked(move || {
        if let Some(w) = window_weak.upgrade() {
            let next = !w.get_is_input_folded();
            w.set_is_input_folded(next);
        }
    });

    let settings_weak = settings_window.as_weak();
    main_window.on_adjust_services_clicked(move || {
        if let Some(s) = settings_weak.upgrade() {
            show_settings_window(&s);
        }
    });

    // 8. Settings Window Handlers
    let settings_weak = settings_window.as_weak();
    main_window.on_open_settings_clicked(move || {
        log_info!("UI", "Opening settings window from toolbar button");
        if let Some(s) = settings_weak.upgrade() {
            show_settings_window(&s);
        }
    });

    let settings_weak = settings_window.as_weak();
    let config_to_save = config_state.clone();
    let windows_for_settings = pinned_windows.clone();
    let main_weak_for_settings = main_window.as_weak();
    settings_window.on_save_settings_clicked(move || {
        if let Some(w) = settings_weak.upgrade() {
            let new_cfg = AppConfig {
                openai_endpoint: w.get_openai_endpoint().to_string(),
                openai_key: w.get_openai_key().to_string(),
                deepl_key: w.get_deepl_key().to_string(),
                click_through_enabled: w.get_click_through_enabled(),
                ocr_engine: w.get_ocr_engine().to_string(),
                minimize_to_tray: w.get_minimize_to_tray(),
            };
            log_info!(
                "CONFIG",
                "Saving settings: endpoint={}, engine={}, click_through={}",
                new_cfg.openai_endpoint,
                new_cfg.ocr_engine,
                new_cfg.click_through_enabled
            );
            let secret_result = secrets::save(&secrets::ApiSecrets {
                openai_key: new_cfg.openai_key.clone(),
                deepl_key: new_cfg.deepl_key.clone(),
            });
            let config_result = serde_json::to_string_pretty(&new_cfg)
                .map_err(|error| error.to_string())
                .and_then(|json| {
                    std::fs::write(config_path(), json).map_err(|error| error.to_string())
                });
            #[cfg(windows)]
            let startup_result = startup::set_enabled(w.get_autostart_enabled());
            #[cfg(not(windows))]
            let startup_result: Result<(), String> = Ok(());
            *config_to_save.lock().unwrap() = new_cfg.clone();
            if let Some(main) = main_weak_for_settings.upgrade() {
                main.set_ocr_engine(new_cfg.ocr_engine.into());
            }
            let click_through = w.get_click_through_enabled();
            for pin in windows_for_settings.borrow().iter() {
                let _ = set_window_click_through(pin.window(), click_through);
            }
            match secret_result.and(config_result).and(startup_result) {
                Ok(()) => w.set_status_text("偏好设置已成功保存".into()),
                Err(error) => w.set_status_text(format!("设置未完整保存: {error}").into()),
            }
        }
    });

    let settings_weak = settings_window.as_weak();
    settings_window.on_install_model_clicked(move || {
        let Some(window) = settings_weak.upgrade() else {
            return;
        };
        let path = PathBuf::from(window.get_model_path().to_string());
        if path.as_os_str().is_empty() {
            window.set_model_status("请输入本地 ONNX 模型的完整路径".into());
            return;
        }
        window.set_model_status("正在使用 ONNX Runtime 验证模型...".into());
        let weak = settings_weak.clone();
        std::thread::spawn(move || {
            let result = model_core::default_runtime_path().and_then(|runtime| {
                if path.extension().and_then(|ext| ext.to_str()) == Some("onnx") {
                    model_core::inspect_model(&path, &runtime)?;
                }
                model_core::install_model(&path, &model_core::destination_directory_for(&path))
            });
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = weak.upgrade() {
                    match result {
                        Ok(model) => window.set_model_status(
                            format!("已安装 {}（{} 字节）", model.name, model.size_bytes).into(),
                        ),
                        Err(error) => {
                            window.set_model_status(format!("模型安装失败: {error}").into())
                        }
                    }
                }
            });
        });
    });

    let settings_weak = settings_window.as_weak();
    let default_data_dir = data_dir_str.clone();
    settings_window.on_reset_data_dir_clicked(move || {
        if let Some(w) = settings_weak.upgrade() {
            w.set_data_directory(default_data_dir.clone().into());
            w.set_status_text("已恢复默认数据目录".into());
        }
    });

    let settings_weak = settings_window.as_weak();
    settings_window.on_open_data_dir_clicked(move || {
        if let Some(w) = settings_weak.upgrade() {
            let dir = w.get_data_directory().to_string();
            let _ = std::process::Command::new("explorer").arg(&dir).spawn();
        }
    });

    let settings_weak = settings_window.as_weak();
    settings_window.on_change_data_dir_clicked(move || {
        if let Some(w) = settings_weak.upgrade() {
            w.set_status_text("可直接在上方输入框编辑路径并点击保存".into());
        }
    });

    // 9. History Handlers
    let window_weak = main_window.as_weak();
    let run_translate_for_apply = run_translation.clone();
    main_window.on_apply_history_item(move |source| {
        if let Some(w) = window_weak.upgrade() {
            w.set_source_text(source);
            w.set_active_tab(0);
            run_translate_for_apply();
        }
    });

    let hist_for_del = history_state.clone();
    let writable_for_del = history_writable.clone();
    let window_weak = main_window.as_weak();
    main_window.on_delete_history_item(move |id| {
        let mut h = hist_for_del.lock().unwrap();
        h.delete_record(&id);
        if writable_for_del.load(Ordering::Acquire) {
            let _ = h.save_to_file(&history_path());
        }
        let entries = make_history_entries(&h);
        if let Some(w) = window_weak.upgrade() {
            w.set_history_list(ModelRc::new(VecModel::from(entries)));
        }
    });

    let hist_for_clear = history_state.clone();
    let writable_for_clear = history_writable.clone();
    let window_weak = main_window.as_weak();
    main_window.on_clear_history_clicked(move || {
        let mut h = hist_for_clear.lock().unwrap();
        h.clear();
        if writable_for_clear.load(Ordering::Acquire) {
            let _ = h.save_to_file(&history_path());
        }
        let entries = make_history_entries(&h);
        if let Some(w) = window_weak.upgrade() {
            w.set_history_list(ModelRc::new(VecModel::from(entries)));
            w.set_status_text("历史记录已全部清空".into());
        }
    });

    #[cfg(windows)]
    let (selection_target, selection_tracker_running, selection_tracker_thread) =
        selected_text::start_foreground_tracker();

    let tray = AppTray::new()?;
    tray.set_version_text(format!("v{} (1)", env!("CARGO_PKG_VERSION")).into());

    let window_weak = main_window.as_weak();
    tray.on_screenshot(move || {
        if let Some(window) = window_weak.upgrade() {
            window.invoke_capture_requested(0);
        }
    });

    let window_weak = main_window.as_weak();
    tray.on_long_capture(move || {
        if let Some(window) = window_weak.upgrade() {
            window.invoke_long_capture_clicked();
        }
    });

    let window_weak = main_window.as_weak();
    tray.on_recording(move || {
        if let Some(window) = window_weak.upgrade() {
            window.invoke_recording_clicked();
        }
    });

    let window_weak = main_window.as_weak();
    tray.on_ocr(move || {
        if let Some(window) = window_weak.upgrade() {
            window.invoke_capture_requested(2);
        }
    });

    let window_weak = main_window.as_weak();
    tray.on_screen_translate(move || {
        if let Some(window) = window_weak.upgrade() {
            window.invoke_capture_requested(1);
        }
    });

    let window_weak = main_window.as_weak();
    #[cfg(windows)]
    let run_translate_for_tray_sel = run_translation.clone();
    #[cfg(windows)]
    let target_for_selection = selection_target.clone();
    tray.on_selection_translate(move || {
        #[cfg(windows)]
        {
            let target = target_for_selection.load(Ordering::Acquire);
            let weak = window_weak.clone();
            let translate = run_translate_for_tray_sel.clone();
            std::thread::spawn(move || {
                let result = selected_text::read_selected_text(target);
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(window) = weak.upgrade() {
                        show_main_window(&window, 0);
                        match result {
                            Ok(text) => {
                                window.set_source_text(text.into());
                                translate();
                            }
                            Err(error) => window.set_status_text(error.into()),
                        }
                    }
                });
            });
        }
        #[cfg(not(windows))]
        if let Some(window) = window_weak.upgrade() {
            window.set_status_text("当前平台尚未实现划词翻译".into());
        }
    });

    let window_weak = main_window.as_weak();
    tray.on_show_translator(move || {
        if let Some(window) = window_weak.upgrade() {
            show_main_window(&window, 0);
        }
    });

    let window_weak = main_window.as_weak();
    #[cfg(not(windows))]
    let windows_for_pin_cb = pinned_windows.clone();
    #[cfg(not(windows))]
    let config_for_pin_cb = config_state.clone();
    tray.on_pin_clipboard(move || {
        let Ok(mut cb) = arboard::Clipboard::new() else { return; };
        if let Ok(img) = cb.get_image() {
            let captured = CapturedImage {
                width: img.width as u32,
                height: img.height as u32,
                rgba: img.bytes.into_owned(),
            };
            #[cfg(windows)]
            {
                pin_window::windows::spawn_native_pin(captured, None);
            }
            #[cfg(not(windows))]
            {
                spawn_pin_window(&windows_for_pin_cb, &captured, None, config_for_pin_cb.clone());
            }
        } else if let Some(w) = window_weak.upgrade() {
            w.set_status_text("剪贴板中没有图像数据".into());
        }
    });

    #[cfg(not(windows))]
    let windows_for_restore = pinned_windows.clone();
    tray.on_restore_pin(move || {
        #[cfg(windows)]
        {
            let _ = pin_window::windows::restore_recent();
        }
        #[cfg(not(windows))]
        for pin in windows_for_restore.borrow().iter().rev() {
            if !pin.window().is_visible() {
                let _ = pin.show();
                break;
            }
        }
    });

    let window_weak = main_window.as_weak();
    tray.on_pin_history(move || {
        #[cfg(windows)]
        {
            if let Err(error) = pin_window::windows::open_history_folder() {
                if let Some(w) = window_weak.upgrade() {
                    w.set_status_text(format!("无法打开贴图历史: {error}").into());
                }
            }
        }
        #[cfg(not(windows))]
        if let Some(w) = window_weak.upgrade() {
            show_main_window(&w, 1);
        }
    });

    #[cfg(not(windows))]
    let windows_for_hide = pinned_windows.clone();
    tray.on_hide_all_pins(move || {
        #[cfg(windows)]
        pin_window::windows::hide_all();
        #[cfg(not(windows))]
        for pin in windows_for_hide.borrow().iter() {
            let _ = pin.hide();
        }
    });

    #[cfg(not(windows))]
    let windows_for_show = pinned_windows.clone();
    tray.on_show_all_pins(move || {
        #[cfg(windows)]
        pin_window::windows::show_all();
        #[cfg(not(windows))]
        for pin in windows_for_show.borrow().iter() {
            let _ = pin.show();
        }
    });

    #[cfg(not(windows))]
    let windows_for_close = pinned_windows.clone();
    tray.on_close_all_pins(move || {
        #[cfg(windows)]
        pin_window::windows::close_all();
        #[cfg(not(windows))]
        for pin in windows_for_close.borrow().iter() {
            let _ = pin.hide();
        }
    });

    #[cfg(not(windows))]
    let windows_for_destroy = pinned_windows.clone();
    tray.on_destroy_all_pins(move || {
        #[cfg(windows)]
        pin_window::windows::destroy_all();
        #[cfg(not(windows))]
        {
        for pin in windows_for_destroy.borrow().iter() {
            let _ = pin.hide();
        }
        windows_for_destroy.borrow_mut().clear();
        }
    });

    let settings_weak = settings_window.as_weak();
    tray.on_show_settings(move || {
        log_info!("TRAY", "Opening settings window from tray menu");
        if let Some(s) = settings_weak.upgrade() {
            show_settings_window(&s);
        }
    });

    let settings_weak = settings_window.as_weak();
    tray.on_check_updates(move || {
        log_info!("TRAY", "Checking updates from tray menu");
        if let Some(s) = settings_weak.upgrade() {
            show_settings_window(&s);
            s.set_status_text("正在检查 Rust 预览版更新...".into());
        }
        let weak = settings_weak.clone();
        tokio::spawn(async move {
            let result = preview_update::check().await;
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(s) = weak.upgrade() {
                    match result {
                        Ok(Some(release)) => s.set_status_text(
                            format!("发现 Rust 预览版 v{}：{}", release.version, release.url).into(),
                        ),
                        Ok(None) => s.set_status_text("未发现更高版本的 Rust 预览版发布包".into()),
                        Err(error) => s.set_status_text(error.into()),
                    }
                }
            });
        });
    });

    tray.on_quit(|| {
        let _ = slint::quit_event_loop();
    });
    tray.show()?;

    #[cfg(windows)]
    let _hotkeys = {
        let window_weak = main_window.as_weak();
        let (hotkeys, failures) = hotkeys::Hotkeys::start(move |action| {
            let weak = window_weak.clone();
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = weak.upgrade() {
                    match action {
                        hotkeys::ShortcutAction::Screenshot => window.invoke_capture_requested(0),
                        hotkeys::ShortcutAction::ScreenTranslate => {
                            window.invoke_capture_requested(1)
                        }
                        hotkeys::ShortcutAction::Ocr => window.invoke_capture_requested(2),
                        hotkeys::ShortcutAction::ShowTranslator => show_main_window(&window, 0),
                    }
                }
            });
        })?;
        if !failures.is_empty() {
            main_window.set_status_text(failures.join("；").into());
        }
        hotkeys
    };

    #[cfg(windows)]
    {
        let weak = main_window.as_weak();
        single_instance.listen(move || {
            let weak = weak.clone();
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = weak.upgrade() {
                    show_main_window(&window, 0);
                }
            });
        })?;
    }
    #[cfg(windows)]
    let _single_instance = single_instance;

    slint::run_event_loop_until_quit()?;
    #[cfg(windows)]
    {
        selection_tracker_running.store(false, Ordering::Release);
        let _ = selection_tracker_thread.join();
    }
    Ok(())
}
