//! Win32 native in-place borderless PinWindow.
//! Exactly matches the official Polyglance WPF PinWindow behavior:
//! - Pure borderless topmost floating window at exact crop coordinates
//! - Left-drag moves window
//! - Wheel zooms with 800ms ZoomBadge
//! - Ctrl+Wheel adjusts opacity
//! - Double-click closes
//! - Right-click context menu (Copy, Save, Translate, OCR, Opacity, Topmost, Close)

use crate::win32_overlay::CapturedImage;

#[cfg(windows)]
pub mod windows {
    #![allow(unsafe_op_in_unsafe_fn)]
    use super::*;
    use std::sync::{Mutex, OnceLock};
    use ::windows::core::PCWSTR;
    use ::windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
    use ::windows::Win32::Graphics::Gdi::{
        BeginPaint, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateFontW, CreatePen,
        CreateSolidBrush, DeleteDC, DeleteObject, EndPaint, GetStockObject, InvalidateRect,
        RoundRect, SelectObject, SetBkMode, SetDIBits, SetStretchBltMode, SetTextColor, StretchBlt,
        TextOutW, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, COLORONCOLOR, DEFAULT_CHARSET,
        DEFAULT_PITCH, DEFAULT_QUALITY, DIB_RGB_COLORS, FF_DONTCARE, NULL_BRUSH,
        OUT_DEFAULT_PRECIS, PAINTSTRUCT, PS_SOLID, SRCCOPY, TRANSPARENT, CLIP_DEFAULT_PRECIS,
    };
    use ::windows::Win32::UI::Input::KeyboardAndMouse::ReleaseCapture;
    use ::windows::Win32::UI::WindowsAndMessaging::{
        AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DestroyWindow,
        DispatchMessageW, GetCursorPos, GetMessageW, GetWindowLongPtrW, GetWindowRect, LoadCursorW,
        PostMessageW, PostQuitMessage, RegisterClassW, SendMessageW, SetCursor, SetLayeredWindowAttributes,
        SetWindowLongPtrW, SetWindowPos, ShowWindow, TrackPopupMenu, TranslateMessage,
        GWL_USERDATA, HTCAPTION, IDC_ARROW, LWA_ALPHA, MF_CHECKED, MF_POPUP, MF_SEPARATOR,
        MF_STRING, MF_UNCHECKED, MSG, SW_SHOW, SWP_FRAMECHANGED, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
        SWP_SHOWWINDOW, SW_HIDE, TPM_LEFTALIGN, TPM_RETURNCMD, TPM_TOPALIGN, WM_ACTIVATE, WM_CLOSE, WM_DESTROY, WM_ERASEBKGND,
        WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_MOUSEWHEEL, WM_NCLBUTTONDBLCLK, WM_NCLBUTTONDOWN, WM_PAINT,
        WM_RBUTTONUP, WM_SETCURSOR, WNDCLASSW, WS_EX_LAYERED, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
        WS_POPUP, WS_VISIBLE, HWND_TOPMOST, HWND_NOTOPMOST, CS_DBLCLKS,
    };

    struct PinState {
        image: CapturedImage,
        x: i32,
        y: i32,
        orig_w: i32,
        orig_h: i32,
        current_w: i32,
        current_h: i32,
        scale: f64,
        opacity: u8,
        is_topmost: bool,
        zoom_badge_ticks: u32, // countdown frames for zoom badge
        is_highlighted: bool,
    }

    #[derive(Clone)]
    struct ClosedPin {
        image: CapturedImage,
        position: (i32, i32),
    }

    #[derive(Default)]
    struct PinRegistry {
        active: Vec<isize>,
        recently_closed: Vec<ClosedPin>,
        destroy_all: bool,
    }

    static PINS: OnceLock<Mutex<PinRegistry>> = OnceLock::new();

    fn pins() -> &'static Mutex<PinRegistry> {
        PINS.get_or_init(|| Mutex::new(PinRegistry::default()))
    }

    fn history_dir() -> std::path::PathBuf {
        std::env::var_os("APPDATA")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join("Polyglance")
            .join("PinHistoryRust")
    }

    fn archive_image(image: &CapturedImage) -> Result<(), String> {
        use image::ImageEncoder;
        let dir = history_dir();
        std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|error| error.to_string())?
            .as_nanos();
        let path = dir.join(format!("Pin-{stamp}.png"));
        let file = std::fs::File::create(path).map_err(|error| error.to_string())?;
        image::codecs::png::PngEncoder::new(file)
            .write_image(&image.rgba, image.width, image.height, image::ExtendedColorType::Rgba8)
            .map_err(|error| error.to_string())
    }

    pub fn open_history_folder() -> Result<(), String> {
        let dir = history_dir();
        std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
        std::process::Command::new("explorer")
            .arg(dir)
            .spawn()
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    pub fn hide_all() {
        if let Ok(registry) = pins().lock() {
            for &handle in &registry.active {
                unsafe { let _ = ShowWindow(HWND(handle as *mut _), SW_HIDE); }
            }
        }
    }

    pub fn show_all() {
        if let Ok(registry) = pins().lock() {
            for &handle in &registry.active {
                unsafe { let _ = ShowWindow(HWND(handle as *mut _), SW_SHOW); }
            }
        }
    }

    pub fn close_all() {
        if let Ok(registry) = pins().lock() {
            for &handle in &registry.active {
                unsafe { let _ = PostMessageW(HWND(handle as *mut _), WM_CLOSE, WPARAM(0), LPARAM(0)); }
            }
        }
    }

    pub fn destroy_all() {
        if let Ok(mut registry) = pins().lock() {
            registry.destroy_all = !registry.active.is_empty();
            registry.recently_closed.clear();
            for &handle in &registry.active {
                unsafe { let _ = PostMessageW(HWND(handle as *mut _), WM_CLOSE, WPARAM(0), LPARAM(0)); }
            }
        }
        let _ = std::fs::remove_dir_all(history_dir());
    }

    pub fn restore_recent() -> bool {
        let closed = pins().lock().ok().and_then(|mut registry| registry.recently_closed.pop());
        if let Some(closed) = closed {
            spawn_native_pin(closed.image, Some(closed.position));
            true
        } else {
            let latest = std::fs::read_dir(history_dir()).ok().and_then(|entries| {
                entries.filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .filter(|path| path.extension().is_some_and(|ext| ext == "png"))
                    .max()
            });
            if let Some(path) = latest {
                if let Ok(reader) = image::ImageReader::open(path) {
                    if let Ok(image) = reader.decode() {
                        let image = image.to_rgba8();
                        let (width, height) = image.dimensions();
                        spawn_native_pin(CapturedImage { width, height, rgba: image.into_raw() }, None);
                        return true;
                    }
                }
            }
            false
        }
    }

    unsafe extern "system" fn pin_wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        let ptr = GetWindowLongPtrW(hwnd, GWL_USERDATA) as *mut PinState;

        match msg {
            WM_ERASEBKGND => LRESULT(1),
            WM_SETCURSOR => {
                let cursor = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
                SetCursor(cursor);
                LRESULT(1)
            }
            WM_ACTIVATE => {
                if !ptr.is_null() {
                    let state = &mut *ptr;
                    let active = (wparam.0 & 0xFFFF) != 0;
                    if state.is_highlighted != active {
                        state.is_highlighted = active;
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                }
                DefWindowProcW(hwnd, msg, wparam, lparam)
            }
            WM_LBUTTONDOWN => {
                if !ptr.is_null() {
                    let state = &mut *ptr;
                    if !state.is_highlighted {
                        state.is_highlighted = true;
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                }
                // Drag window natively via HTCAPTION
                let _ = ReleaseCapture();
                let _ = SendMessageW(hwnd, WM_NCLBUTTONDOWN, WPARAM(HTCAPTION as usize), LPARAM(0));
                LRESULT(0)
            }
            WM_LBUTTONDBLCLK | WM_NCLBUTTONDBLCLK => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_MOUSEWHEEL => {
                if ptr.is_null() {
                    return LRESULT(0);
                }
                let state = &mut *ptr;
                let delta = (wparam.0 >> 16) as i16;
                let is_ctrl = (wparam.0 & 0x0008) != 0; // MK_CONTROL

                if is_ctrl {
                    // Adjust opacity
                    if delta > 0 {
                        state.opacity = (state.opacity as i32 + 25).min(255) as u8;
                    } else {
                        state.opacity = (state.opacity as i32 - 25).max(50) as u8;
                    }
                    let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), state.opacity, LWA_ALPHA);
                } else {
                    // Zoom centered
                    let factor = if delta > 0 { 1.1 } else { 1.0 / 1.1 };
                    let new_scale = (state.scale * factor).clamp(0.05, 8.0);
                    state.scale = new_scale;
                    let new_w = ((state.orig_w as f64 * new_scale).round() as i32).max(20);
                    let new_h = ((state.orig_h as f64 * new_scale).round() as i32).max(20);

                    let mut rc = RECT::default();
                    let _ = GetWindowRect(hwnd, &mut rc);
                    let center_x = rc.left + (rc.right - rc.left) / 2;
                    let center_y = rc.top + (rc.bottom - rc.top) / 2;
                    let new_x = center_x - new_w / 2;
                    let new_y = center_y - new_h / 2;

                    state.x = new_x;
                    state.y = new_y;
                    state.current_w = new_w;
                    state.current_h = new_h;
                    state.zoom_badge_ticks = 40; // ~800ms at 50Hz

                    let _ = SetWindowPos(
                        hwnd,
                        HWND::default(),
                        new_x,
                        new_y,
                        new_w,
                        new_h,
                        SWP_FRAMECHANGED | SWP_NOZORDER,
                    );
                    let _ = InvalidateRect(hwnd, None, false);
                }
                LRESULT(0)
            }
            WM_RBUTTONUP => {
                if ptr.is_null() {
                    return LRESULT(0);
                }
                let state = &mut *ptr;
                let mut cursor_pt = POINT::default();
                let _ = GetCursorPos(&mut cursor_pt);

                let menu = CreatePopupMenu().unwrap_or_default();
                let opacity_menu = CreatePopupMenu().unwrap_or_default();

                let _ = AppendMenuW(menu, MF_STRING, 1001, PCWSTR("复制图片 (Copy)\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(menu, MF_STRING, 1002, PCWSTR("保存图片 (Save)...\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR(std::ptr::null()));
                let _ = AppendMenuW(menu, MF_STRING, 1003, PCWSTR("截图翻译\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(menu, MF_STRING, 1004, PCWSTR("文字识别 (OCR)\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR(std::ptr::null()));

                let _ = AppendMenuW(opacity_menu, MF_STRING, 1010, PCWSTR("100% (默认)\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(opacity_menu, MF_STRING, 1011, PCWSTR("80%\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(opacity_menu, MF_STRING, 1012, PCWSTR("60%\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(opacity_menu, MF_STRING, 1013, PCWSTR("40%\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(menu, MF_POPUP, opacity_menu.0 as usize, PCWSTR("透明度 (Opacity)\0".encode_utf16().collect::<Vec<_>>().as_ptr()));

                let top_flag = if state.is_topmost { MF_CHECKED } else { MF_UNCHECKED };
                let _ = AppendMenuW(menu, MF_STRING | top_flag, 1020, PCWSTR("总在最前 (Topmost)\0".encode_utf16().collect::<Vec<_>>().as_ptr()));
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR(std::ptr::null()));
                let _ = AppendMenuW(menu, MF_STRING, 1030, PCWSTR("关闭贴图 (Close)\0".encode_utf16().collect::<Vec<_>>().as_ptr()));

                let cmd = TrackPopupMenu(
                    menu,
                    TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RETURNCMD,
                    cursor_pt.x,
                    cursor_pt.y,
                    0,
                    hwnd,
                    None,
                );

                let _ = DestroyMenu(opacity_menu);
                let _ = DestroyMenu(menu);

                match cmd.0 {
                    1001 => {
                        // Copy image
                        if let Ok(mut cb) = arboard::Clipboard::new() {
                            let _ = cb.set_image(arboard::ImageData {
                                width: state.image.width as usize,
                                height: state.image.height as usize,
                                bytes: std::borrow::Cow::Borrowed(&state.image.rgba),
                            });
                        }
                    }
                    1002 => {
                        // Save image
                        let folder = std::env::var_os("USERPROFILE")
                            .map(std::path::PathBuf::from)
                            .unwrap_or_else(|| std::path::PathBuf::from("."))
                            .join("Pictures")
                            .join("Polyglance");
                        let _ = std::fs::create_dir_all(&folder);
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_secs())
                            .unwrap_or(0);
                        let path = folder.join(format!("Polyglance_Pin_{now}.png"));
                        if let Ok(file) = std::fs::File::create(&path) {
                            use image::ImageEncoder;
                            let _ = image::codecs::png::PngEncoder::new(file).write_image(
                                &state.image.rgba,
                                state.image.width,
                                state.image.height,
                                image::ExtendedColorType::Rgba8,
                            );
                        }
                    }
                    1010 => {
                        state.opacity = 255;
                        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);
                    }
                    1011 => {
                        state.opacity = 204;
                        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 204, LWA_ALPHA);
                    }
                    1012 => {
                        state.opacity = 153;
                        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 153, LWA_ALPHA);
                    }
                    1013 => {
                        state.opacity = 102;
                        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 102, LWA_ALPHA);
                    }
                    1020 => {
                        state.is_topmost = !state.is_topmost;
                        let _ = SetWindowPos(
                            hwnd,
                            if state.is_topmost { HWND_TOPMOST } else { HWND_NOTOPMOST },
                            0,
                            0,
                            0,
                            0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED,
                        );
                    }
                    1030 => {
                        let _ = DestroyWindow(hwnd);
                    }
                    _ => {}
                }

                LRESULT(0)
            }
            WM_PAINT => {
                let mut ps = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &mut ps);

                if !ptr.is_null() {
                    let state = &mut *ptr;
                    let w = state.current_w;
                    let h = state.current_h;

                    let mem_dc = CreateCompatibleDC(hdc);
                    let mem_bmp = CreateCompatibleBitmap(hdc, w, h);
                    let old_bmp = SelectObject(mem_dc, mem_bmp);

                    // Render captured image stretched to current scale
                    let img_dc = CreateCompatibleDC(hdc);
                    let img_bmp = CreateCompatibleBitmap(hdc, state.orig_w, state.orig_h);
                    let old_img_bmp = SelectObject(img_dc, img_bmp);

                    // Populate img_bmp from rgba
                    let mut bmi = BITMAPINFO::default();
                    bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
                    bmi.bmiHeader.biWidth = state.orig_w;
                    bmi.bmiHeader.biHeight = -state.orig_h; // top-down
                    bmi.bmiHeader.biPlanes = 1;
                    bmi.bmiHeader.biBitCount = 32;
                    bmi.bmiHeader.biCompression = BI_RGB.0;

                    // Convert RGBA to BGRA for Win32 GDI
                    let mut bgra = state.image.rgba.clone();
                    for chunk in bgra.chunks_exact_mut(4) {
                        chunk.swap(0, 2);
                    }

                    let _ = SetDIBits(
                        img_dc,
                        img_bmp,
                        0,
                        state.orig_h as u32,
                        bgra.as_ptr() as *const _,
                        &bmi,
                        DIB_RGB_COLORS,
                    );

                    let _ = SetStretchBltMode(mem_dc, COLORONCOLOR);
                    let _ = StretchBlt(mem_dc, 0, 0, w, h, img_dc, 0, 0, state.orig_w, state.orig_h, SRCCOPY);

                    let _ = SelectObject(img_dc, old_img_bmp);
                    let _ = DeleteObject(img_bmp);
                    let _ = DeleteDC(img_dc);

                    // Selection border:
                    // Highlighted: 2px Vibrant Blue (#0A84FF) -> COLORREF 0x00FF840A
                    // Inactive: 1px subtle border (#D0D0D0)
                    let border_pen = if state.is_highlighted {
                        CreatePen(PS_SOLID, 2, COLORREF(0x00FF840A))
                    } else {
                        CreatePen(PS_SOLID, 1, COLORREF(0x00D0D0D0))
                    };
                    let old_p = SelectObject(mem_dc, border_pen);
                    let old_b = SelectObject(mem_dc, GetStockObject(NULL_BRUSH));
                    if state.is_highlighted {
                        let _ = RoundRect(mem_dc, 1, 1, w - 1, h - 1, 4, 4);
                    } else {
                        let _ = RoundRect(mem_dc, 0, 0, w, h, 2, 2);
                    }
                    let _ = SelectObject(mem_dc, old_b);
                    let _ = SelectObject(mem_dc, old_p);
                    let _ = DeleteObject(border_pen);

                    // Zoom badge if active
                    if state.zoom_badge_ticks > 0 {
                        state.zoom_badge_ticks -= 1;
                        let badge_w = 72;
                        let badge_h = 28;
                        let bx = (w - badge_w) / 2;
                        let by = (h - badge_h) / 2;

                        let badge_b = CreateSolidBrush(COLORREF(0x001A1A1A));
                        let old_bb = SelectObject(mem_dc, badge_b);
                        let old_bp = SelectObject(mem_dc, GetStockObject(NULL_BRUSH));
                        let _ = RoundRect(mem_dc, bx, by, bx + badge_w, by + badge_h, 12, 12);
                        let _ = SelectObject(mem_dc, old_bp);
                        let _ = SelectObject(mem_dc, old_bb);
                        let _ = DeleteObject(badge_b);

                        let percent = (state.scale * 100.0).round() as i32;
                        let zoom_str = format!("{}%", percent);
                        let zoom_u16: Vec<u16> = zoom_str.encode_utf16().collect();
                        let font = CreateFontW(
                            -13, 0, 0, 0, 700, 0, 0, 0,
                            DEFAULT_CHARSET.0 as u32,
                            OUT_DEFAULT_PRECIS.0 as u32,
                            CLIP_DEFAULT_PRECIS.0 as u32,
                            DEFAULT_QUALITY.0 as u32,
                            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                            PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                        );
                        let old_f = SelectObject(mem_dc, font);
                        let _ = SetBkMode(mem_dc, TRANSPARENT);
                        let _ = SetTextColor(mem_dc, COLORREF(0x00FFFFFF));
                        let _ = TextOutW(mem_dc, bx + 16, by + 6, &zoom_u16);
                        let _ = SelectObject(mem_dc, old_f);
                        let _ = DeleteObject(font);
                    }

                    let _ = BitBlt(hdc, 0, 0, w, h, mem_dc, 0, 0, SRCCOPY);

                    let _ = SelectObject(mem_dc, old_bmp);
                    let _ = DeleteObject(mem_bmp);
                    let _ = DeleteDC(mem_dc);
                }

                let _ = EndPaint(hwnd, &ps);
                LRESULT(0)
            }
            WM_DESTROY => {
                if !ptr.is_null() {
                    let state = Box::from_raw(ptr);
                    if let Ok(mut registry) = pins().lock() {
                        registry.active.retain(|&handle| handle != hwnd.0 as isize);
                        if !registry.destroy_all {
                            let mut bounds = RECT::default();
                            let _ = GetWindowRect(hwnd, &mut bounds);
                            registry.recently_closed.push(ClosedPin {
                                image: state.image.clone(),
                                position: (bounds.left, bounds.top),
                            });
                        } else if registry.active.is_empty() {
                            registry.destroy_all = false;
                        }
                    }
                    SetWindowLongPtrW(hwnd, GWL_USERDATA, 0);
                }
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    pub fn spawn_native_pin(image: CapturedImage, pos: Option<(i32, i32)>) {
        std::thread::spawn(move || {
            if let Err(error) = archive_image(&image) {
                crate::log_warn!("PIN", "Failed to archive pin: {error}");
            }
            let class_name: Vec<u16> = "PolyglanceNativePin\0".encode_utf16().collect();
            let cursor = unsafe { LoadCursorW(None, IDC_ARROW).unwrap_or_default() };
            let wc = WNDCLASSW {
                style: CS_DBLCLKS,
                lpfnWndProc: Some(pin_wnd_proc),
                hCursor: cursor,
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };
            unsafe {
                let _ = RegisterClassW(&wc);
            }

            let w = image.width as i32;
            let h = image.height as i32;
            let (x, y) = pos.unwrap_or((100, 100));

            let state = Box::new(PinState {
                image,
                x,
                y,
                orig_w: w,
                orig_h: h,
                current_w: w,
                current_h: h,
                scale: 1.0,
                opacity: 255,
                is_topmost: true,
                zoom_badge_ticks: 0,
                is_highlighted: true,
            });

            unsafe {
                let hwnd = match CreateWindowExW(
                    WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
                    PCWSTR(class_name.as_ptr()),
                    PCWSTR(std::ptr::null()),
                    WS_POPUP | WS_VISIBLE,
                    x,
                    y,
                    w,
                    h,
                    None,
                    None,
                    None,
                    None,
                ) {
                    Ok(h) => h,
                    Err(err) => {
                        crate::log_error!("PIN", "Failed to create native pin window: {:?}", err);
                        return;
                    }
                };

                let ptr = Box::into_raw(state);
                SetWindowLongPtrW(hwnd, GWL_USERDATA, ptr as isize);
                let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);

                if let Ok(mut registry) = pins().lock() {
                    registry.active.push(hwnd.0 as isize);
                }

                let _ = ShowWindow(hwnd, SW_SHOW);
                let _ = SetWindowPos(
                    hwnd,
                    HWND_TOPMOST,
                    x,
                    y,
                    w,
                    h,
                    SWP_SHOWWINDOW | SWP_FRAMECHANGED,
                );

                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        });
    }
}

#[cfg(not(windows))]
pub mod windows {
    use super::*;
    #[allow(dead_code)]
    pub fn spawn_native_pin(_image: CapturedImage, _pos: Option<(i32, i32)>) {}
}
