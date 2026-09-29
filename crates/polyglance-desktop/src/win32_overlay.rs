#![allow(dead_code)]
#![allow(unsafe_op_in_unsafe_fn)]

use capture_core::rect::Rect;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VirtualScreenBounds {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenshotAction {
    Copy,
    Pin,
    Translate,
    Ocr,
    Save,
    LongScreenshot,
    ScreenRecording,
}

#[derive(Debug, Clone)]
pub struct CapturedImage {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ScreenshotSelection {
    pub rect: Rect,
    pub action: ScreenshotAction,
    pub image: Option<CapturedImage>,
}

#[cfg(windows)]
pub mod windows {
    use super::*;
    use ::windows::Win32::Foundation::{
        COLORREF, GetLastError, HWND, LPARAM, LRESULT, POINT, RECT, SetLastError, WIN32_ERROR,
        WPARAM,
    };
    use ::windows::Win32::Graphics::Gdi::{
        AC_SRC_OVER, AlphaBlend, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION,
        BS_SOLID, BeginPaint, BitBlt, COLORONCOLOR, CombineRgn, CreateCompatibleBitmap,
        CreateCompatibleDC, CreateFontW, CreatePen, CreateRectRgn, CreateSolidBrush,
        DIB_RGB_COLORS, DeleteDC, DeleteObject, Ellipse, EndPaint, ExtCreatePen, FillRect,
        GetDC, GetDIBits, GetPixel, GetStockObject, HBRUSH, HDC, HPEN, HRGN, HALFTONE, InvalidateRect, LineTo,
        LOGBRUSH, MoveToEx, NULL_BRUSH, PAINTSTRUCT, PEN_STYLE, PS_DASH, PS_DASHDOT, PS_DOT,
        PS_GEOMETRIC, PS_SOLID, Polygon, RGN_DIFF, Rectangle, ReleaseDC, RoundRect, SRCCOPY,
        ScreenToClient, SelectClipRgn, SelectObject, SetBkMode, SetDIBits, SetStretchBltMode,
        SetTextColor, SetWindowRgn, StretchBlt, TRANSPARENT, TextOutW, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET,
        DEFAULT_PITCH, DEFAULT_QUALITY, FF_DONTCARE, OUT_DEFAULT_PRECIS,
    };
    use ::windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyState, ReleaseCapture, SetCapture, SetFocus};
    use ::windows::Win32::UI::WindowsAndMessaging::{
        ChildWindowFromPointEx, CreateWindowExW, CWP_FLAGS, DefWindowProcW, DestroyWindow, DispatchMessageW, GWL_EXSTYLE,
        GetCursorPos, GetMessageW, GetSystemMetrics, GetTopWindow, GetWindow, GetWindowLongPtrW,
        GetWindowRect, GetWindowThreadProcessId, HWND_TOPMOST, IDC_ARROW, IDC_CROSS, IDC_HAND,
        IDC_SIZEALL, IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE, IsWindowVisible,
        KillTimer, LoadCursorW, MSG, PostQuitMessage, RegisterClassW, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
        SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SW_SHOW, SWP_FRAMECHANGED, SWP_NOMOVE, SWP_NOSIZE,
        SetCursor, SetForegroundWindow, SetTimer, SetWindowLongPtrW, SetWindowPos,
        ShowWindow, TranslateMessage, GW_HWNDNEXT, WM_CONTEXTMENU, WM_DESTROY,
        WM_ERASEBKGND, WM_KEYDOWN, WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE,
        WM_MOUSEWHEEL, WM_PAINT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SETCURSOR, WM_TIMER, WNDCLASSW,
        WS_EX_LAYERED, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP, WS_VISIBLE,
    };
    use ::windows::core::PCWSTR;
    use capture_core::geometry::expanded_selection_toward;
    use capture_core::rect::Point as CorePoint;
    use capture_core::stitch::{Configuration, Direction, Stitcher};
    use std::sync::Mutex;

    pub mod gdiplus {
        use super::*;

        #[repr(C)]
        pub struct GdiplusStartupInput {
            pub gdiplus_version: u32,
            pub debug_event_callback: usize,
            pub suppress_background_thread: i32,
            pub suppress_external_codecs: i32,
        }

        #[link(name = "gdiplus")]
        unsafe extern "system" {
            pub fn GdiplusStartup(token: *mut usize, input: *const GdiplusStartupInput, output: *mut std::ffi::c_void) -> i32;
            pub fn GdiplusShutdown(token: usize);
            pub fn GdipCreateFromHDC(hdc: HDC, graphics: *mut usize) -> i32;
            pub fn GdipDeleteGraphics(graphics: usize) -> i32;
            pub fn GdipSetSmoothingMode(graphics: usize, mode: i32) -> i32;
            pub fn GdipCreatePen1(color: u32, width: f32, unit: i32, pen: *mut usize) -> i32;
            pub fn GdipDeletePen(pen: usize) -> i32;
            pub fn GdipSetPenDashStyle(pen: usize, dash_style: i32) -> i32;
            pub fn GdipSetPenLineJoin(pen: usize, line_join: i32) -> i32;
            pub fn GdipSetPenStartCap(pen: usize, start_cap: i32) -> i32;
            pub fn GdipSetPenEndCap(pen: usize, end_cap: i32) -> i32;
            pub fn GdipDrawLine(graphics: usize, pen: usize, x1: f32, y1: f32, x2: f32, y2: f32) -> i32;
            pub fn GdipDrawLinesI(graphics: usize, pen: usize, points: *const POINT, count: i32) -> i32;
            pub fn GdipCreateSolidFill(color: u32, brush: *mut usize) -> i32;
            pub fn GdipDeleteBrush(brush: usize) -> i32;
            pub fn GdipFillPolygonI(graphics: usize, brush: usize, points: *const POINT, count: i32, fill_mode: i32) -> i32;
            pub fn GdipDrawPolygonI(graphics: usize, pen: usize, points: *const POINT, count: i32) -> i32;
            pub fn GdipDrawRectangleI(graphics: usize, pen: usize, x: i32, y: i32, w: i32, h: i32) -> i32;
            pub fn GdipDrawEllipseI(graphics: usize, pen: usize, x: i32, y: i32, w: i32, h: i32) -> i32;
            pub fn GdipFillEllipseI(graphics: usize, brush: usize, x: i32, y: i32, w: i32, h: i32) -> i32;
        }

        #[inline]
        pub fn colorref_to_argb(c: COLORREF, a: u8) -> u32 {
            let r = (c.0 & 0xFF) as u32;
            let g = ((c.0 >> 8) & 0xFF) as u32;
            let b = ((c.0 >> 16) & 0xFF) as u32;
            ((a as u32) << 24) | (r << 16) | (g << 8) | b
        }
    }

    pub fn get_virtual_screen_bounds() -> VirtualScreenBounds {
        unsafe {
            let x = GetSystemMetrics(SM_XVIRTUALSCREEN);
            let y = GetSystemMetrics(SM_YVIRTUALSCREEN);
            let width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            let height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            VirtualScreenBounds {
                x,
                y,
                width: if width > 0 { width } else { 1920 },
                height: if height > 0 { height } else { 1080 },
            }
        }
    }

    #[inline]
    pub const fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
        COLORREF((r as u32) | ((g as u32) << 8) | ((b as u32) << 16))
    }

    pub const PALETTE: [COLORREF; 8] = [
        rgb(0xEF, 0x44, 0x44), // #EF4444 Red
        rgb(0xF9, 0x73, 0x16), // #F97316 Orange
        rgb(0xFA, 0xCC, 0x15), // #FACC15 Yellow
        rgb(0x10, 0xB9, 0x81), // #10B981 Green
        rgb(0x3B, 0x82, 0xF6), // #3B82F6 Blue
        rgb(0x8B, 0x5C, 0xF6), // #8B5CF6 Purple
        rgb(0x1F, 0x29, 0x37), // #1F2937 Dark Slate
        rgb(0xFF, 0xFF, 0xFF), // #FFFFFF White
    ];

    const TOOLBAR_ITEMS: [(&str, &str); 19] = [
        ("pen", "画笔"),
        ("line", "线条"),
        ("arrow", "箭头"),
        ("ellipse", "椭圆"),
        ("rect", "矩形"),
        ("text", "文字"),
        ("mosaic", "马赛克"),
        ("number", "序号"),
        ("undo", "撤销"),
        ("redo", "重做"),
        ("longScreenshot", "长截图"),
        ("screenRecording", "录屏"),
        ("ocr", "文字识别 (O)"),
        ("translate", "OCR翻译 (T)"),
        ("barcode", "二维码/条形码"),
        ("save", "保存 (S)"),
        ("cancel", "取消 (Esc)"),
        ("pin", "贴图 (P)"),
        ("copy", "复制 (C / Enter)"),
    ];

    const BTN_W: i32 = 30;
    const BTN_H: i32 = 30;
    const GAP: i32 = 2;
    const DIVIDER_W: i32 = 12;
    const TB1_PAD_X: i32 = 8;
    const TB1_PAD_Y: i32 = 5;
    const TB1_W: i32 = TB1_PAD_X * 2 + 10 * BTN_W + 9 * GAP + DIVIDER_W + 9 * BTN_W + 8 * GAP; // 632
    const TB1_H: i32 = 40;

    const TB2_W: i32 = 246;
    const TB2_H: i32 = 32;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum SelectionPhase {
        Ready,
        DraggingNew,
        Selected,
        Moving,
        Resizing(usize),
        Expanding,
        LongCapturing,
    }

    #[derive(Clone, Debug)]
    pub enum AnnotationShape {
        Pen { points: Vec<POINT>, color: COLORREF, width: i32, dash: u32 },
        Line { start: POINT, end: POINT, color: COLORREF, width: i32, dash: u32 },
        Arrow { start: POINT, end: POINT, color: COLORREF, width: i32, arrow_style: usize, dash: u32 },
        Rect { rect: RECT, color: COLORREF, width: i32, dash: u32 },
        Ellipse { rect: RECT, color: COLORREF, width: i32, dash: u32 },
        Text { pos: POINT, text: String, color: COLORREF, font_size: i32 },
        Number { center: POINT, num: u32, color: COLORREF, radius: i32, is_filled: bool },
        Mosaic { shape_type: u8, is_blur: bool, points: Vec<POINT>, rect: RECT, block_size: i32 },
    }

    #[derive(Clone, Debug)]
    pub struct AnnotationItem {
        pub shape: AnnotationShape,
    }

    struct OverlayState {
        phase: SelectionPhase,
        start_pt: Option<POINT>,
        current_pt: Option<POINT>,
        drag_start: Option<POINT>,
        initial_sel: Option<RECT>,
        candidate_rect: Option<RECT>,
        selected_rect: Option<Rect>,
        selected_action: Option<ScreenshotAction>,
        selected_image: Option<CapturedImage>,
        is_finished: bool,
        virtual_origin: POINT,
        screen_w: i32,
        screen_h: i32,
        active_tool: Option<usize>,
        hovered_item: Option<usize>,
        stroke_size: u32,
        selected_color_idx: usize,
        line_dash_pattern: u32,
        arrow_style: usize,
        is_line_dash_popup_open: bool,
        is_arrow_popup_open: bool,
        number_is_filled: bool,
        mosaic_style: usize,
        is_mosaic_popup_open: bool,
        is_rgb_mode: bool,
        // Long screenshot session state
        long_stitcher: Option<Stitcher>,
        long_frame_count: usize,
        long_status_text: String,
        long_preview: Option<(Vec<u8>, u32, u32)>, // RGBA, w, h
        // Annotation states
        annotations: Vec<AnnotationItem>,
        redo_stack: Vec<AnnotationItem>,
        current_drawing: Option<AnnotationShape>,
        is_annotating: bool,
        next_badge_number: u32,
    }

    static OVERLAY_STATE: Mutex<Option<OverlayState>> = Mutex::new(None);
    static OVERLAY_SESSION: Mutex<()> = Mutex::new(());
    static SCREENSHOT_DC: Mutex<Option<usize>> = Mutex::new(None);
    static SCREENSHOT_BMP: Mutex<Option<usize>> = Mutex::new(None);

    fn get_main_toolbar_rect(sel: &RECT, screen_w: i32, screen_h: i32, show_sub: bool) -> RECT {
        let total_tb_h = if show_sub { TB1_H + 6 + 34 } else { TB1_H };
        let mut tb_y = sel.bottom + 10;
        if tb_y + total_tb_h > screen_h - 12 {
            if sel.top >= total_tb_h + 12 {
                tb_y = sel.top - TB1_H - 10;
            } else {
                tb_y = (sel.bottom - TB1_H - 10).max(12).min(screen_h - TB1_H - 12);
            }
        }

        let mut tb_x = sel.right - TB1_W;
        if tb_x + TB1_W > screen_w - 12 {
            tb_x = screen_w - TB1_W - 12;
        }
        if tb_x < 12 {
            tb_x = 12;
        }

        RECT {
            left: tb_x,
            top: tb_y,
            right: tb_x + TB1_W,
            bottom: tb_y + TB1_H,
        }
    }

    fn get_sub_toolbar_rect(tb1: &RECT, sel: &RECT, _screen_h: i32, active_tool: Option<usize>) -> RECT {
        let sub_w = match active_tool {
            Some(2) => 384, // Arrow: style + dash + stroke + divider + palette
            Some(6) => 162, // Mosaic: combo + stroke (no palette!)
            Some(7) => 304, // Number: filled/outline + stroke + divider + palette
            _ => 314,       // Pen, Line, Rect, Ellipse
        };
        let is_below = tb1.top >= sel.bottom;
        let top = if is_below {
            tb1.bottom + 6
        } else {
            tb1.top - 34 - 6
        };
        RECT {
            left: tb1.left,
            top,
            right: tb1.left + sub_w,
            bottom: top + 34,
        }
    }

    fn get_arrow_popup_rect(tb2: &RECT) -> RECT {
        let top = if tb2.top >= 270 { tb2.top - 264 } else { tb2.bottom + 6 };
        RECT {
            left: tb2.left + 8,
            top,
            right: tb2.left + 8 + 170,
            bottom: top + 260,
        }
    }

    fn get_line_dash_popup_rect(tb2: &RECT, active_tool: Option<usize>) -> RECT {
        let is_arrow = active_tool == Some(2);
        let left = if is_arrow { tb2.left + 78 } else { tb2.left + 8 };
        let top = if tb2.top >= 120 { tb2.top - 114 } else { tb2.bottom + 6 };
        RECT {
            left,
            top,
            right: left + 96,
            bottom: top + 112,
        }
    }

    fn get_mosaic_popup_rect(tb2: &RECT) -> RECT {
        let top = if tb2.top >= 120 { tb2.top - 114 } else { tb2.bottom + 6 };
        RECT {
            left: tb2.left + 8,
            top,
            right: tb2.left + 8 + 104,
            bottom: top + 112,
        }
    }

    fn get_long_status_rect(sel: &RECT, screen_w: i32, _screen_h: i32) -> RECT {
        let w = 280;
        let h = 32;
        let cx = (sel.left + sel.right) / 2;
        let left = (cx - w / 2).clamp(12, screen_w - w - 12);
        let top = (sel.top - h - 10).max(10);
        RECT { left, top, right: left + w, bottom: top + h }
    }

    fn get_long_toolbar_rect(sel: &RECT, screen_w: i32, screen_h: i32) -> RECT {
        let w = 180;
        let h = 40;
        let cx = (sel.left + sel.right) / 2;
        let left = (cx - w / 2).clamp(12, screen_w - w - 12);
        let top = (sel.bottom + 10).clamp(12, screen_h - h - 12);
        RECT { left, top, right: left + w, bottom: top + h }
    }

    fn get_long_preview_rect(sel: &RECT, screen_w: i32, screen_h: i32, preview_h: i32) -> RECT {
        let w = 160;
        let h = preview_h.clamp(100, 320);
        let left = if sel.right + 10 + w <= screen_w - 12 {
            sel.right + 10
        } else {
            (sel.left - 10 - w).max(12)
        };
        let top = sel.top.clamp(12, screen_h - h - 12);
        RECT { left, top, right: left + w, bottom: top + h }
    }

    fn get_button_rect(tb: &RECT, idx: usize) -> RECT {
        let (bx, by) = if idx < 10 {
            let col = idx as i32;
            (tb.left + TB1_PAD_X + col * (BTN_W + GAP), tb.top + TB1_PAD_Y)
        } else {
            let col = (idx - 10) as i32;
            let group_offset = TB1_PAD_X + 10 * (BTN_W + GAP) + DIVIDER_W;
            (tb.left + group_offset + col * (BTN_W + GAP), tb.top + TB1_PAD_Y)
        };
        RECT {
            left: bx,
            top: by,
            right: bx + BTN_W,
            bottom: by + BTN_H,
        }
    }

    fn hit_test_toolbars(
        pt: POINT,
        sel: &RECT,
        screen_w: i32,
        screen_h: i32,
        active_tool: Option<usize>,
        is_arrow_open: bool,
        is_dash_open: bool,
        is_mosaic_open: bool,
    ) -> Option<usize> {
        let show_sub = active_tool.is_some();
        let tb1 = get_main_toolbar_rect(sel, screen_w, screen_h, show_sub);

        if show_sub {
            let tb2 = get_sub_toolbar_rect(&tb1, sel, screen_h, active_tool);

            // Popups have topmost hit priority
            if is_arrow_open && active_tool == Some(2) {
                let ap = get_arrow_popup_rect(&tb2);
                if pt.x >= ap.left && pt.x <= ap.right && pt.y >= ap.top && pt.y <= ap.bottom {
                    let idx = ((pt.y - ap.top - 4) / 28).clamp(0, 9);
                    return Some(400 + idx as usize);
                }
            }

            if is_dash_open {
                let dp = get_line_dash_popup_rect(&tb2, active_tool);
                if pt.x >= dp.left && pt.x <= dp.right && pt.y >= dp.top && pt.y <= dp.bottom {
                    let idx = ((pt.y - dp.top - 4) / 26).clamp(0, 3);
                    return Some(500 + idx as usize);
                }
            }

            if is_mosaic_open && active_tool == Some(6) {
                let mp = get_mosaic_popup_rect(&tb2);
                if pt.x >= mp.left && pt.x <= mp.right && pt.y >= mp.top && pt.y <= mp.bottom {
                    let idx = ((pt.y - mp.top - 4) / 26).clamp(0, 3);
                    return Some(510 + idx as usize);
                }
            }

            if pt.x >= tb2.left && pt.x <= tb2.right && pt.y >= tb2.top && pt.y <= tb2.bottom {
                match active_tool {
                    Some(2) => {
                        // ArrowStyle button: tb2.left + 8..tb2.left + 74
                        if pt.x >= tb2.left + 8 && pt.x <= tb2.left + 74 {
                            return Some(300);
                        }
                        // LineDash button: tb2.left + 78..tb2.left + 142
                        if pt.x >= tb2.left + 78 && pt.x <= tb2.left + 142 {
                            return Some(301);
                        }
                        // Stroke button: tb2.left + 146..tb2.left + 186
                        if pt.x >= tb2.left + 146 && pt.x <= tb2.left + 186 {
                            return Some(100);
                        }
                        // Palette: starting at tb2.left + 196
                        let pal_x = tb2.left + 196;
                        for c in 0..8 {
                            let cx = pal_x + c * 22 + 11;
                            let cy = (tb2.top + tb2.bottom) / 2;
                            let dist_sq = (pt.x - cx) * (pt.x - cx) + (pt.y - cy) * (pt.y - cy);
                            if dist_sq <= 100 {
                                return Some(200 + c as usize);
                            }
                        }
                    }
                    Some(6) => {
                        // MosaicStyle dropdown button: tb2.left + 8..tb2.left + 108
                        if pt.x >= tb2.left + 8 && pt.x <= tb2.left + 108 {
                            return Some(320);
                        }
                        // Stroke/Block button: tb2.left + 112..tb2.left + 152
                        if pt.x >= tb2.left + 112 && pt.x <= tb2.left + 152 {
                            return Some(100);
                        }
                    }
                    Some(7) => {
                        // NumberFilled button: tb2.left + 8..tb2.left + 34
                        if pt.x >= tb2.left + 8 && pt.x <= tb2.left + 34 {
                            return Some(310);
                        }
                        // NumberOutline button: tb2.left + 36..tb2.left + 62
                        if pt.x >= tb2.left + 36 && pt.x <= tb2.left + 62 {
                            return Some(311);
                        }
                        // Stroke button: tb2.left + 66..tb2.left + 106
                        if pt.x >= tb2.left + 66 && pt.x <= tb2.left + 106 {
                            return Some(100);
                        }
                        // Palette: starting at tb2.left + 116
                        let pal_x = tb2.left + 116;
                        for c in 0..8 {
                            let cx = pal_x + c * 22 + 11;
                            let cy = (tb2.top + tb2.bottom) / 2;
                            let dist_sq = (pt.x - cx) * (pt.x - cx) + (pt.y - cy) * (pt.y - cy);
                            if dist_sq <= 100 {
                                return Some(200 + c as usize);
                            }
                        }
                    }
                    _ => {
                        // LineDash button: tb2.left + 8..tb2.left + 72
                        if pt.x >= tb2.left + 8 && pt.x <= tb2.left + 72 {
                            return Some(301);
                        }
                        // Stroke button: tb2.left + 76..tb2.left + 116
                        if pt.x >= tb2.left + 76 && pt.x <= tb2.left + 116 {
                            return Some(100);
                        }
                        // Palette: starting at tb2.left + 126
                        let pal_x = tb2.left + 126;
                        for c in 0..8 {
                            let cx = pal_x + c * 22 + 11;
                            let cy = (tb2.top + tb2.bottom) / 2;
                            let dist_sq = (pt.x - cx) * (pt.x - cx) + (pt.y - cy) * (pt.y - cy);
                            if dist_sq <= 100 {
                                return Some(200 + c as usize);
                            }
                        }
                    }
                }
                return Some(9998);
            }
        }

        if pt.x >= tb1.left && pt.x <= tb1.right && pt.y >= tb1.top && pt.y <= tb1.bottom {
            for i in 0..19 {
                let rc = get_button_rect(&tb1, i);
                if pt.x >= rc.left && pt.x <= rc.right && pt.y >= rc.top && pt.y <= rc.bottom {
                    return Some(i);
                }
            }
            return Some(9999);
        }

        None
    }

    fn hit_test_long_toolbar(pt: POINT, tb: &RECT) -> Option<usize> {
        if pt.x >= tb.left && pt.x <= tb.right && pt.y >= tb.top && pt.y <= tb.bottom {
            if pt.x >= tb.left + 10 && pt.x <= tb.left + 46 {
                return Some(600); // Pin
            } else if pt.x >= tb.left + 50 && pt.x <= tb.left + 86 {
                return Some(601); // Copy
            } else if pt.x >= tb.left + 90 && pt.x <= tb.left + 126 {
                return Some(602); // Finish
            } else if pt.x >= tb.left + 134 && pt.x <= tb.left + 170 {
                return Some(603); // Cancel
            }
            return Some(9997);
        }
        None
    }

    fn get_handle_rects(sel: &RECT) -> [RECT; 8] {
        let mid_x = (sel.left + sel.right) / 2;
        let mid_y = (sel.top + sel.bottom) / 2;
        [
            RECT { left: sel.left - 4, top: sel.top - 4, right: sel.left + 4, bottom: sel.top + 4 }, // 0: NW
            RECT { left: mid_x - 4, top: sel.top - 4, right: mid_x + 4, bottom: sel.top + 4 },       // 1: N
            RECT { left: sel.right - 4, top: sel.top - 4, right: sel.right + 4, bottom: sel.top + 4 },// 2: NE
            RECT { left: sel.left - 4, top: mid_y - 4, right: sel.left + 4, bottom: mid_y + 4 },     // 3: W
            RECT { left: sel.right - 4, top: mid_y - 4, right: sel.right + 4, bottom: mid_y + 4 },    // 4: E
            RECT { left: sel.left - 4, top: sel.bottom - 4, right: sel.left + 4, bottom: sel.bottom + 4 }, // 5: SW
            RECT { left: mid_x - 4, top: sel.bottom - 4, right: mid_x + 4, bottom: sel.bottom + 4 },       // 6: S
            RECT { left: sel.right - 4, top: sel.bottom - 4, right: sel.right + 4, bottom: sel.bottom + 4 },// 7: SE
        ]
    }

    fn hit_test_handles(pt: POINT, sel: &RECT) -> Option<usize> {
        let handles = get_handle_rects(sel);
        for (i, h) in handles.iter().enumerate() {
            if pt.x >= h.left - 4 && pt.x <= h.right + 4 && pt.y >= h.top - 4 && pt.y <= h.bottom + 4 {
                return Some(i);
            }
        }
        None
    }

    fn cursor_for_handle(idx: usize) -> PCWSTR {
        match idx {
            0 | 7 => IDC_SIZENWSE, // NW, SE
            1 | 6 => IDC_SIZENS,   // N, S
            2 | 5 => IDC_SIZENESW, // NE, SW
            3 | 4 => IDC_SIZEWE,   // W, E
            _ => IDC_ARROW,
        }
    }

    fn apply_resize(init: &RECT, handle: usize, pt: POINT, screen_w: i32, screen_h: i32) -> RECT {
        let mut r = *init;
        match handle {
            0 => {
                r.left = pt.x.min(init.right - 8).clamp(0, screen_w);
                r.top = pt.y.min(init.bottom - 8).clamp(0, screen_h);
            }
            1 => {
                r.top = pt.y.min(init.bottom - 8).clamp(0, screen_h);
            }
            2 => {
                r.right = pt.x.max(init.left + 8).clamp(0, screen_w);
                r.top = pt.y.min(init.bottom - 8).clamp(0, screen_h);
            }
            3 => {
                r.left = pt.x.min(init.right - 8).clamp(0, screen_w);
            }
            4 => {
                r.right = pt.x.max(init.left + 8).clamp(0, screen_w);
            }
            5 => {
                r.left = pt.x.min(init.right - 8).clamp(0, screen_w);
                r.bottom = pt.y.max(init.top + 8).clamp(0, screen_h);
            }
            6 => {
                r.bottom = pt.y.max(init.top + 8).clamp(0, screen_h);
            }
            7 => {
                r.right = pt.x.max(init.left + 8).clamp(0, screen_w);
                r.bottom = pt.y.max(init.top + 8).clamp(0, screen_h);
            }
            _ => {}
        }
        r
    }

    fn expand_toward(init: &RECT, pt: POINT, screen_w: i32, screen_h: i32) -> RECT {
        let core_sel = Rect::new(
            init.left as f64,
            init.top as f64,
            (init.right - init.left) as f64,
            (init.bottom - init.top) as f64,
        );
        let core_pt = CorePoint::new(pt.x as f64, pt.y as f64);
        let core_bounds = Rect::new(0.0, 0.0, screen_w as f64, screen_h as f64);
        let exp = expanded_selection_toward(core_sel, core_pt, core_bounds);
        RECT {
            left: exp.x.round() as i32,
            top: exp.y.round() as i32,
            right: (exp.x + exp.width).round() as i32,
            bottom: (exp.y + exp.height).round() as i32,
        }
    }

    unsafe fn detect_candidate_at(
        pt: POINT,
        screen_w: i32,
        screen_h: i32,
        my_hwnd: HWND,
        virtual_origin: POINT,
    ) -> RECT {
        let screen_pt = POINT {
            x: pt.x + virtual_origin.x,
            y: pt.y + virtual_origin.y,
        };
        let mut my_pid = 0u32;
        GetWindowThreadProcessId(my_hwnd, Some(&mut my_pid));

        let mut curr = GetTopWindow(None).unwrap_or_default();
        while !curr.0.is_null() {
            if curr != my_hwnd && IsWindowVisible(curr).as_bool() {
                let mut pid = 0u32;
                GetWindowThreadProcessId(curr, Some(&mut pid));
                if pid != my_pid {
                    let mut rc = RECT::default();
                    if GetWindowRect(curr, &mut rc).is_ok() {
                        if screen_pt.x >= rc.left
                            && screen_pt.x < rc.right
                            && screen_pt.y >= rc.top
                            && screen_pt.y < rc.bottom
                        {
                            let mut deepest = curr;
                            for _ in 0..10 {
                                let mut client_pt = screen_pt;
                                if !ScreenToClient(deepest, &mut client_pt).as_bool() {
                                    break;
                                }
                                let child = ChildWindowFromPointEx(
                                    deepest,
                                    client_pt,
                                    CWP_FLAGS(0x0001 | 0x0002 | 0x0004),
                                );
                                if child.0.is_null() || child == deepest {
                                    break;
                                }
                                deepest = child;
                            }

                            let mut target_rc = RECT::default();
                            if GetWindowRect(deepest, &mut target_rc).is_ok() {
                                let left = (target_rc.left - virtual_origin.x).max(0);
                                let top = (target_rc.top - virtual_origin.y).max(0);
                                let right = (target_rc.right - virtual_origin.x).min(screen_w);
                                let bottom = (target_rc.bottom - virtual_origin.y).min(screen_h);
                                if (right - left) >= 16
                                    && (bottom - top) >= 16
                                    && ((right - left) < screen_w || (bottom - top) < screen_h)
                                {
                                    return RECT { left, top, right, bottom };
                                }
                            }

                            let left = (rc.left - virtual_origin.x).max(0);
                            let top = (rc.top - virtual_origin.y).max(0);
                            let right = (rc.right - virtual_origin.x).min(screen_w);
                            let bottom = (rc.bottom - virtual_origin.y).min(screen_h);
                            if (right - left) >= 16
                                && (bottom - top) >= 16
                                && ((right - left) < screen_w || (bottom - top) < screen_h)
                            {
                                return RECT { left, top, right, bottom };
                            }
                        }
                    }
                }
            }
            curr = GetWindow(curr, GW_HWNDNEXT).unwrap_or_default();
        }

        RECT {
            left: 0,
            top: 0,
            right: screen_w,
            bottom: screen_h,
        }
    }

    fn current_selection(state: &OverlayState) -> Option<RECT> {
        if let (Some(start), Some(curr)) = (state.start_pt, state.current_pt) {
            let left = start.x.min(curr.x);
            let top = start.y.min(curr.y);
            let right = start.x.max(curr.x);
            let bottom = start.y.max(curr.y);
            if (right - left) > 4 && (bottom - top) > 4 {
                return Some(RECT { left, top, right, bottom });
            }
        }
        None
    }

    unsafe extern "system" fn overlay_wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        unsafe {
            match msg {
                WM_SETCURSOR => {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);
                    let _ = ScreenToClient(hwnd, &mut pt);

                    let mut cursor_type = IDC_CROSS;
                    if let Ok(state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_ref() {
                            match s.phase {
                                SelectionPhase::Ready => {
                                    cursor_type = IDC_CROSS;
                                }
                                SelectionPhase::DraggingNew => {
                                    cursor_type = IDC_CROSS;
                                }
                                SelectionPhase::Selected => {
                                    if let Some(sel) = current_selection(s) {
                                        if let Some(item_idx) = hit_test_toolbars(
                                            pt,
                                            &sel,
                                            s.screen_w,
                                            s.screen_h,
                                            s.active_tool,
                                            s.is_arrow_popup_open,
                                            s.is_line_dash_popup_open,
                                            s.is_mosaic_popup_open,
                                        ) {
                                            cursor_type = if item_idx < 1000 { IDC_HAND } else { IDC_ARROW };
                                        } else if let Some(h) = hit_test_handles(pt, &sel) {
                                            cursor_type = cursor_for_handle(h);
                                        } else if pt.x >= sel.left && pt.x <= sel.right && pt.y >= sel.top && pt.y <= sel.bottom {
                                            cursor_type = if s.active_tool.is_none() { IDC_SIZEALL } else { IDC_CROSS };
                                        } else {
                                            cursor_type = IDC_CROSS;
                                        }
                                    }
                                }
                                SelectionPhase::Moving => {
                                    cursor_type = IDC_SIZEALL;
                                }
                                SelectionPhase::Resizing(h) => {
                                    cursor_type = cursor_for_handle(h);
                                }
                                SelectionPhase::Expanding => {
                                    cursor_type = IDC_CROSS;
                                }
                                SelectionPhase::LongCapturing => {
                                    if let Some(sel) = current_selection(s) {
                                        let long_tb = get_long_toolbar_rect(&sel, s.screen_w, s.screen_h);
                                        if hit_test_long_toolbar(pt, &long_tb).is_some() {
                                            cursor_type = IDC_HAND;
                                        } else {
                                            cursor_type = IDC_ARROW;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let cursor = LoadCursorW(None, cursor_type).unwrap_or_default();
                    SetCursor(cursor);
                    LRESULT(1)
                }
                WM_ERASEBKGND => LRESULT(1),
                WM_LBUTTONDOWN => {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);
                    let _ = ScreenToClient(hwnd, &mut pt);

                    let mut trigger_action = None;
                    let mut should_redraw = false;

                    if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_mut() {
                            match s.phase {
                                SelectionPhase::LongCapturing => {
                                    if let Some(sel) = current_selection(s) {
                                        let long_tb = get_long_toolbar_rect(&sel, s.screen_w, s.screen_h);
                                        if let Some(btn_idx) = hit_test_long_toolbar(pt, &long_tb) {
                                            match btn_idx {
                                                600 => { // Pin
                                                    if let Some(stitcher) = s.long_stitcher.take() {
                                                        if let Ok(rgba) = stitcher.render() {
                                                            s.selected_image = Some(CapturedImage {
                                                                width: stitcher.output_width(),
                                                                height: stitcher.output_height(),
                                                                rgba,
                                                            });
                                                        }
                                                    }
                                                    trigger_action = Some(17);
                                                }
                                                601 => { // Copy
                                                    if let Some(stitcher) = s.long_stitcher.take() {
                                                        if let Ok(rgba) = stitcher.render() {
                                                            s.selected_image = Some(CapturedImage {
                                                                width: stitcher.output_width(),
                                                                height: stitcher.output_height(),
                                                                rgba,
                                                            });
                                                        }
                                                    }
                                                    trigger_action = Some(18);
                                                }
                                                602 => { // Finish / Save
                                                    if let Some(stitcher) = s.long_stitcher.take() {
                                                        if let Ok(rgba) = stitcher.render() {
                                                            s.selected_image = Some(CapturedImage {
                                                                width: stitcher.output_width(),
                                                                height: stitcher.output_height(),
                                                                rgba,
                                                            });
                                                        }
                                                    }
                                                    trigger_action = Some(15);
                                                }
                                                603 => { // Cancel
                                                    let _ = KillTimer(hwnd, 2001);
                                                    let _ = SetWindowRgn(hwnd, HRGN::default(), true);
                                                    s.phase = SelectionPhase::Selected;
                                                    s.long_stitcher = None;
                                                    should_redraw = true;
                                                }
                                                _ => {}
                                            }
                                        }
                                    }
                                }
                                SelectionPhase::Ready => {
                                    if let Some(cand) = s.candidate_rect {
                                        s.start_pt = Some(POINT { x: cand.left, y: cand.top });
                                        s.current_pt = Some(POINT { x: cand.right, y: cand.bottom });
                                        s.initial_sel = Some(cand);
                                        s.phase = SelectionPhase::Selected;
                                        s.candidate_rect = None;
                                        s.active_tool = None;
                                        should_redraw = true;
                                    } else {
                                        s.start_pt = Some(pt);
                                        s.current_pt = Some(pt);
                                        s.phase = SelectionPhase::DraggingNew;
                                        SetCapture(hwnd);
                                        should_redraw = true;
                                    }
                                }
                                SelectionPhase::Selected => {
                                    if let Some(sel) = current_selection(s) {
                                        if let Some(item_idx) = hit_test_toolbars(
                                            pt,
                                            &sel,
                                            s.screen_w,
                                            s.screen_h,
                                            s.active_tool,
                                            s.is_arrow_popup_open,
                                            s.is_line_dash_popup_open,
                                            s.is_mosaic_popup_open,
                                        ) {
                                            if item_idx >= 400 && item_idx <= 409 {
                                                s.arrow_style = item_idx - 400;
                                                s.is_arrow_popup_open = false;
                                                should_redraw = true;
                                            } else if item_idx >= 500 && item_idx <= 503 {
                                                s.line_dash_pattern = (item_idx - 500) as u32;
                                                s.is_line_dash_popup_open = false;
                                                should_redraw = true;
                                            } else if item_idx >= 510 && item_idx <= 513 {
                                                s.mosaic_style = item_idx - 510;
                                                s.is_mosaic_popup_open = false;
                                                should_redraw = true;
                                            } else if item_idx == 300 {
                                                s.is_arrow_popup_open = !s.is_arrow_popup_open;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                should_redraw = true;
                                            } else if item_idx == 301 {
                                                s.is_line_dash_popup_open = !s.is_line_dash_popup_open;
                                                s.is_arrow_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                should_redraw = true;
                                            } else if item_idx == 310 {
                                                s.number_is_filled = true;
                                                should_redraw = true;
                                            } else if item_idx == 311 {
                                                s.number_is_filled = false;
                                                should_redraw = true;
                                            } else if item_idx == 320 {
                                                s.is_mosaic_popup_open = !s.is_mosaic_popup_open;
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                should_redraw = true;
                                            } else if item_idx < 8 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                if s.active_tool == Some(item_idx) {
                                                    s.active_tool = None;
                                                } else {
                                                    s.active_tool = Some(item_idx);
                                                }
                                                should_redraw = true;
                                            } else if item_idx == 8 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                if let Some(item) = s.annotations.pop() {
                                                    if let AnnotationShape::Number { .. } = item.shape {
                                                        if s.next_badge_number > 1 {
                                                            s.next_badge_number -= 1;
                                                        }
                                                    }
                                                    s.redo_stack.push(item);
                                                    should_redraw = true;
                                                }
                                            } else if item_idx == 9 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                if let Some(item) = s.redo_stack.pop() {
                                                    if let AnnotationShape::Number { .. } = item.shape {
                                                        s.next_badge_number += 1;
                                                    }
                                                    s.annotations.push(item);
                                                    should_redraw = true;
                                                }
                                            } else if item_idx == 100 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                s.stroke_size = match s.stroke_size {
                                                    2 => 4,
                                                    4 => 6,
                                                    6 => 8,
                                                    _ => 2,
                                                };
                                                should_redraw = true;
                                            } else if item_idx >= 200 && item_idx <= 207 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                s.selected_color_idx = item_idx - 200;
                                                should_redraw = true;
                                            } else if item_idx == 10 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                s.active_tool = None;
                                                s.phase = SelectionPhase::LongCapturing;
                                                s.long_stitcher = Some(Stitcher::new(Configuration::default(), Direction::Vertical));
                                                s.long_frame_count = 0;
                                                s.long_status_text = "请慢速平稳滚动页面".into();
                                                s.long_preview = None;

                                                let full_rgn = CreateRectRgn(0, 0, s.screen_w, s.screen_h);
                                                let inner_hole = CreateRectRgn(sel.left + 2, sel.top + 2, sel.right - 2, sel.bottom - 2);
                                                let win_rgn = CreateRectRgn(0, 0, 0, 0);
                                                let _ = CombineRgn(win_rgn, full_rgn, inner_hole, RGN_DIFF);
                                                let _ = DeleteObject(full_rgn);
                                                let _ = DeleteObject(inner_hole);
                                                let _ = SetWindowRgn(hwnd, win_rgn, true);
                                                let _ = SetTimer(hwnd, 2001, 33, None);

                                                should_redraw = true;
                                            } else if item_idx < 1000 {
                                                s.is_arrow_popup_open = false;
                                                s.is_line_dash_popup_open = false;
                                                s.is_mosaic_popup_open = false;
                                                trigger_action = Some(item_idx);
                                            }
                                        } else {
                                            s.is_arrow_popup_open = false;
                                            s.is_line_dash_popup_open = false;
                                            s.is_mosaic_popup_open = false;

                                            if let Some(h) = hit_test_handles(pt, &sel) {
                                                s.phase = SelectionPhase::Resizing(h);
                                                s.initial_sel = Some(sel);
                                                s.drag_start = Some(pt);
                                                SetCapture(hwnd);
                                            } else if pt.x >= sel.left && pt.x <= sel.right && pt.y >= sel.top && pt.y <= sel.bottom {
                                                if let Some(tool) = s.active_tool {
                                                    let col = PALETTE[s.selected_color_idx];
                                                    let stroke = s.stroke_size as i32;
                                                    let dash = s.line_dash_pattern;
                                                    let arrow_style = s.arrow_style;

                                                    if tool == 7 {
                                                        let radius = (18.0f64.max((s.stroke_size as f64) * 4.5) / 2.0).round() as i32;
                                                        s.annotations.push(AnnotationItem {
                                                            shape: AnnotationShape::Number {
                                                                center: pt,
                                                                num: s.next_badge_number,
                                                                color: col,
                                                                radius,
                                                                is_filled: s.number_is_filled,
                                                            },
                                                        });
                                                        s.next_badge_number += 1;
                                                        s.redo_stack.clear();
                                                        should_redraw = true;
                                                    } else if tool == 5 {
                                                        s.annotations.push(AnnotationItem {
                                                            shape: AnnotationShape::Text {
                                                                pos: pt,
                                                                text: "标注文本".into(),
                                                                color: col,
                                                                font_size: 16,
                                                            },
                                                        });
                                                        s.redo_stack.clear();
                                                        should_redraw = true;
                                                    } else {
                                                        s.is_annotating = true;
                                                        s.current_drawing = match tool {
                                                            0 => Some(AnnotationShape::Pen { points: vec![pt], color: col, width: stroke, dash }),
                                                            1 => Some(AnnotationShape::Line { start: pt, end: pt, color: col, width: stroke, dash }),
                                                            2 => Some(AnnotationShape::Arrow { start: pt, end: pt, color: col, width: stroke, arrow_style, dash }),
                                                            3 => Some(AnnotationShape::Ellipse { rect: RECT { left: pt.x, top: pt.y, right: pt.x, bottom: pt.y }, color: col, width: stroke, dash }),
                                                            4 => Some(AnnotationShape::Rect { rect: RECT { left: pt.x, top: pt.y, right: pt.x, bottom: pt.y }, color: col, width: stroke, dash }),
                                                            6 => {
                                                                let block_size = (s.stroke_size as i32 * 2).max(4);
                                                                let is_blur = (s.mosaic_style % 2) == 1;
                                                                let shape_type = if s.mosaic_style >= 2 { 1 } else { 0 };
                                                                if shape_type == 0 {
                                                                    Some(AnnotationShape::Mosaic { shape_type: 0, is_blur, points: vec![pt], rect: RECT::default(), block_size })
                                                                } else {
                                                                    Some(AnnotationShape::Mosaic { shape_type: 1, is_blur, points: Vec::new(), rect: RECT { left: pt.x, top: pt.y, right: pt.x, bottom: pt.y }, block_size })
                                                                }
                                                            }
                                                            _ => None,
                                                        };
                                                        SetCapture(hwnd);
                                                        should_redraw = true;
                                                    }
                                                } else {
                                                    s.phase = SelectionPhase::Moving;
                                                    s.initial_sel = Some(sel);
                                                    s.drag_start = Some(pt);
                                                    SetCapture(hwnd);
                                                }
                                            } else {
                                                s.phase = SelectionPhase::Expanding;
                                                s.initial_sel = Some(sel);
                                                s.drag_start = Some(pt);
                                                let exp = expand_toward(&sel, pt, s.screen_w, s.screen_h);
                                                s.start_pt = Some(POINT { x: exp.left, y: exp.top });
                                                s.current_pt = Some(POINT { x: exp.right, y: exp.bottom });
                                                SetCapture(hwnd);
                                                should_redraw = true;
                                            }
                                        }
                                    }
                                }
                                _ => {}
                            }
                        }
                    }

                    if let Some(item_idx) = trigger_action {
                        match item_idx {
                            10 => handle_action(hwnd, ScreenshotAction::LongScreenshot),
                            11 => handle_action(hwnd, ScreenshotAction::ScreenRecording),
                            12 => handle_action(hwnd, ScreenshotAction::Ocr),
                            13 => handle_action(hwnd, ScreenshotAction::Translate),
                            14 => handle_action(hwnd, ScreenshotAction::Ocr), // Barcode
                            15 => handle_action(hwnd, ScreenshotAction::Save),
                            16 => cancel_overlay(hwnd),
                            17 => handle_action(hwnd, ScreenshotAction::Pin),
                            18 => handle_action(hwnd, ScreenshotAction::Copy),
                            _ => {}
                        }
                        return LRESULT(0);
                    }

                    if should_redraw {
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                    LRESULT(0)
                }
                WM_LBUTTONDBLCLK => {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);
                    let _ = ScreenToClient(hwnd, &mut pt);
                    let mut is_inside_sel = false;
                    if let Ok(state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_ref() {
                            if s.phase == SelectionPhase::Selected && s.active_tool.is_none() {
                                if let Some(sel) = current_selection(s) {
                                    if pt.x >= sel.left && pt.x <= sel.right && pt.y >= sel.top && pt.y <= sel.bottom {
                                        is_inside_sel = true;
                                    }
                                }
                            }
                        }
                    }
                    if is_inside_sel {
                        handle_action(hwnd, ScreenshotAction::Copy);
                        return LRESULT(0);
                    }
                    LRESULT(0)
                }
                WM_MOUSEMOVE => {
                    let mut pt = POINT::default();
                    let _ = GetCursorPos(&mut pt);
                    let _ = ScreenToClient(hwnd, &mut pt);

                    let mut should_redraw = false;
                    if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_mut() {
                            if s.is_annotating {
                                if let Some(ref mut shape) = s.current_drawing {
                                    match shape {
                                        AnnotationShape::Pen { points, .. } => {
                                            points.push(pt);
                                            should_redraw = true;
                                        }
                                        AnnotationShape::Line { end, .. } => {
                                            *end = pt;
                                            should_redraw = true;
                                        }
                                        AnnotationShape::Arrow { end, .. } => {
                                            *end = pt;
                                            should_redraw = true;
                                        }
                                        AnnotationShape::Rect { rect, .. }
                                        | AnnotationShape::Ellipse { rect, .. } => {
                                            rect.right = pt.x;
                                            rect.bottom = pt.y;
                                            should_redraw = true;
                                        }
                                        AnnotationShape::Mosaic { shape_type, points, rect, .. } => {
                                            if *shape_type == 0 {
                                                points.push(pt);
                                            } else {
                                                rect.right = pt.x;
                                                rect.bottom = pt.y;
                                            }
                                            should_redraw = true;
                                        }
                                        _ => {}
                                    }
                                }
                            } else {
                                match s.phase {
                                    SelectionPhase::Ready => {
                                        s.candidate_rect = Some(detect_candidate_at(pt, s.screen_w, s.screen_h, hwnd, s.virtual_origin));
                                        s.current_pt = Some(pt);
                                        should_redraw = true;
                                    }
                                    SelectionPhase::DraggingNew => {
                                        s.current_pt = Some(pt);
                                        should_redraw = true;
                                    }
                                    SelectionPhase::Moving => {
                                        if let (Some(init), Some(start)) = (s.initial_sel, s.drag_start) {
                                            let dx = pt.x - start.x;
                                            let dy = pt.y - start.y;
                                            let w = init.right - init.left;
                                            let h = init.bottom - init.top;
                                            let new_left = (init.left + dx).clamp(0, s.screen_w - w);
                                            let new_top = (init.top + dy).clamp(0, s.screen_h - h);
                                            s.start_pt = Some(POINT { x: new_left, y: new_top });
                                            s.current_pt = Some(POINT { x: new_left + w, y: new_top + h });
                                            should_redraw = true;
                                        }
                                    }
                                    SelectionPhase::Resizing(h) => {
                                        if let Some(init) = s.initial_sel {
                                            let resized = apply_resize(&init, h, pt, s.screen_w, s.screen_h);
                                            s.start_pt = Some(POINT { x: resized.left, y: resized.top });
                                            s.current_pt = Some(POINT { x: resized.right, y: resized.bottom });
                                            should_redraw = true;
                                        }
                                    }
                                    SelectionPhase::Expanding => {
                                        if let Some(init) = s.initial_sel {
                                            let expanded = expand_toward(&init, pt, s.screen_w, s.screen_h);
                                            s.start_pt = Some(POINT { x: expanded.left, y: expanded.top });
                                            s.current_pt = Some(POINT { x: expanded.right, y: expanded.bottom });
                                            should_redraw = true;
                                        }
                                    }
                                    SelectionPhase::Selected => {
                                        if let Some(sel) = current_selection(s) {
                                            let new_hover = hit_test_toolbars(
                                                pt,
                                                &sel,
                                                s.screen_w,
                                                s.screen_h,
                                                s.active_tool,
                                                s.is_arrow_popup_open,
                                                s.is_line_dash_popup_open,
                                                s.is_mosaic_popup_open,
                                            );
                                            if s.hovered_item != new_hover {
                                                s.hovered_item = new_hover;
                                                should_redraw = true;
                                            }
                                        }
                                    }
                                    SelectionPhase::LongCapturing => {
                                        if let Some(sel) = current_selection(s) {
                                            let long_tb = get_long_toolbar_rect(&sel, s.screen_w, s.screen_h);
                                            let new_hover = hit_test_long_toolbar(pt, &long_tb);
                                            if s.hovered_item != new_hover {
                                                s.hovered_item = new_hover;
                                                should_redraw = true;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if should_redraw {
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                    LRESULT(0)
                }
                WM_LBUTTONUP => {
                    let _ = ReleaseCapture();
                    let mut should_redraw = false;
                    if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_mut() {
                            if s.is_annotating {
                                s.is_annotating = false;
                                if let Some(shape) = s.current_drawing.take() {
                                    s.annotations.push(AnnotationItem { shape });
                                    s.redo_stack.clear();
                                    should_redraw = true;
                                }
                            } else {
                                match s.phase {
                                    SelectionPhase::DraggingNew => {
                                        if let Some(sel) = current_selection(s) {
                                            let w = sel.right - sel.left;
                                            let h = sel.bottom - sel.top;
                                            if w > 6 && h > 6 {
                                                s.phase = SelectionPhase::Selected;
                                                s.initial_sel = Some(sel);
                                                s.active_tool = None;
                                                should_redraw = true;
                                            } else if let Some(cand) = s.candidate_rect {
                                                s.start_pt = Some(POINT { x: cand.left, y: cand.top });
                                                s.current_pt = Some(POINT { x: cand.right, y: cand.bottom });
                                                s.initial_sel = Some(cand);
                                                s.phase = SelectionPhase::Selected;
                                                s.active_tool = None;
                                                should_redraw = true;
                                            } else {
                                                s.phase = SelectionPhase::Ready;
                                                s.start_pt = None;
                                                s.current_pt = None;
                                                should_redraw = true;
                                            }
                                        }
                                    }
                                    SelectionPhase::Moving
                                    | SelectionPhase::Resizing(_)
                                    | SelectionPhase::Expanding => {
                                        s.phase = SelectionPhase::Selected;
                                        s.initial_sel = current_selection(s);
                                        s.drag_start = None;
                                        should_redraw = true;
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                    if should_redraw {
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                    LRESULT(0)
                }
                WM_RBUTTONDOWN => {
                    LRESULT(0)
                }
                WM_RBUTTONUP => {
                    let mut should_cancel = false;
                    let mut should_redraw = false;
                    if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_mut() {
                            if s.is_arrow_popup_open || s.is_line_dash_popup_open || s.is_mosaic_popup_open {
                                s.is_arrow_popup_open = false;
                                s.is_line_dash_popup_open = false;
                                s.is_mosaic_popup_open = false;
                                should_redraw = true;
                            } else if s.phase == SelectionPhase::LongCapturing {
                                let _ = KillTimer(hwnd, 2001);
                                let _ = SetWindowRgn(hwnd, HRGN::default(), true);
                                s.phase = SelectionPhase::Selected;
                                s.long_stitcher = None;
                                should_redraw = true;
                            } else if s.active_tool.is_some() {
                                s.active_tool = None;
                                should_redraw = true;
                            } else if s.phase == SelectionPhase::Selected || s.start_pt.is_some() {
                                s.phase = SelectionPhase::Ready;
                                s.start_pt = None;
                                s.current_pt = None;
                                s.initial_sel = None;
                                s.hovered_item = None;
                                s.annotations.clear();
                                s.redo_stack.clear();
                                s.next_badge_number = 1;
                                let mut pt = POINT::default();
                                let _ = GetCursorPos(&mut pt);
                                let _ = ScreenToClient(hwnd, &mut pt);
                                s.candidate_rect = Some(detect_candidate_at(pt, s.screen_w, s.screen_h, hwnd, s.virtual_origin));
                                should_redraw = true;
                            } else {
                                should_cancel = true;
                            }
                        }
                    }
                    if should_cancel {
                        cancel_overlay(hwnd);
                    } else if should_redraw {
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                    LRESULT(0)
                }
                WM_TIMER => {
                    if wparam.0 == 2001 {
                        let mut should_redraw = false;
                        if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                            if let Some(s) = state_lock.as_mut() {
                                if s.phase == SelectionPhase::LongCapturing {
                                    if let Some(sel) = current_selection(s) {
                                        let x = sel.left + s.virtual_origin.x + 2;
                                        let y = sel.top + s.virtual_origin.y + 2;
                                        let w = ((sel.right - sel.left - 4) as u32).max(10);
                                        let h = ((sel.bottom - sel.top - 4) as u32).max(10);

                                        if let Ok(frame) = polyglance_cabi::native_capture::capture_screen_region(x, y, w, h) {
                                            let mut rgba = frame.bgra;
                                            for p in rgba.chunks_exact_mut(4) {
                                                p.swap(0, 2);
                                                p[3] = 255;
                                            }
                                            if let Some(stitcher) = s.long_stitcher.as_mut() {
                                                match stitcher.append(rgba, frame.width, frame.height) {
                                                    Ok(res) => {
                                                        s.long_frame_count += 1;
                                                        s.long_status_text = format!("请慢速平稳滚动页面 · 已拼接 {} px", stitcher.output_height());
                                                        if let Ok((prev, pw, ph)) = stitcher.render_preview(120, 240) {
                                                            s.long_preview = Some((prev, pw, ph));
                                                        }
                                                        if res.limit_reached.is_some() {
                                                            s.long_status_text = "已达长截图最大长度，请贴图或复制".into();
                                                        }
                                                        should_redraw = true;
                                                    }
                                                    Err(capture_core::stitch::StitchError::NoReliableVerticalOverlap) => {}
                                                    Err(_) => {}
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if should_redraw {
                            let _ = InvalidateRect(hwnd, None, false);
                        }
                    }
                    LRESULT(0)
                }
                WM_KEYDOWN => {
                    let is_shift = ((GetKeyState(0x10) as u16) & 0x8000) != 0;
                    match wparam.0 {
                        0x1B => { // ESC
                            let mut should_cancel = false;
                            let mut should_redraw = false;
                            if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                                if let Some(s) = state_lock.as_mut() {
                                    if s.is_arrow_popup_open || s.is_line_dash_popup_open || s.is_mosaic_popup_open {
                                        s.is_arrow_popup_open = false;
                                        s.is_line_dash_popup_open = false;
                                        s.is_mosaic_popup_open = false;
                                        should_redraw = true;
                                    } else if s.phase == SelectionPhase::LongCapturing {
                                        let _ = KillTimer(hwnd, 2001);
                                        let _ = SetWindowRgn(hwnd, HRGN::default(), true);
                                        s.phase = SelectionPhase::Selected;
                                        s.long_stitcher = None;
                                        should_redraw = true;
                                    } else if s.active_tool.is_some() {
                                        s.active_tool = None;
                                        should_redraw = true;
                                    } else if s.phase == SelectionPhase::Selected || s.start_pt.is_some() {
                                        s.phase = SelectionPhase::Ready;
                                        s.start_pt = None;
                                        s.current_pt = None;
                                        s.initial_sel = None;
                                        s.annotations.clear();
                                        let mut pt = POINT::default();
                                        let _ = GetCursorPos(&mut pt);
                                        let _ = ScreenToClient(hwnd, &mut pt);
                                        s.candidate_rect = Some(detect_candidate_at(pt, s.screen_w, s.screen_h, hwnd, s.virtual_origin));
                                        should_redraw = true;
                                    } else {
                                        should_cancel = true;
                                    }
                                }
                            }
                            if should_cancel {
                                cancel_overlay(hwnd);
                            } else if should_redraw {
                                let _ = InvalidateRect(hwnd, None, false);
                            }
                        }
                        0x43 => { // C
                            if is_shift {
                                if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                                    if let Some(s) = state_lock.as_mut() {
                                        s.is_rgb_mode = !s.is_rgb_mode;
                                    }
                                }
                                let _ = InvalidateRect(hwnd, None, false);
                            } else {
                                // Copy sampled color
                                if let Ok(state_lock) = OVERLAY_STATE.lock() {
                                    if let Some(s) = state_lock.as_ref() {
                                        if let Some(pt) = s.current_pt {
                                            if let Ok(dc_lock) = SCREENSHOT_DC.lock() {
                                                if let Some(saved_dc_raw) = *dc_lock {
                                                    let saved_dc = HDC(saved_dc_raw as *mut std::ffi::c_void);
                                                    let pixel = GetPixel(saved_dc, pt.x, pt.y);
                                                    let r = (pixel.0 & 0xFF) as u8;
                                                    let g = ((pixel.0 >> 8) & 0xFF) as u8;
                                                    let b = ((pixel.0 >> 16) & 0xFF) as u8;
                                                    let text = if s.is_rgb_mode {
                                                        format!("RGB({}, {}, {})", r, g, b)
                                                    } else {
                                                        format!("#{:02X}{:02X}{:02X}", r, g, b)
                                                    };
                                                    if let Ok(mut cb) = arboard::Clipboard::new() {
                                                        let _ = cb.set_text(text);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        0x0D => { // ENTER
                            handle_action(hwnd, ScreenshotAction::Copy);
                        }
                        0x50 => { // P
                            handle_action(hwnd, ScreenshotAction::Pin);
                        }
                        0x54 => { // T
                            handle_action(hwnd, ScreenshotAction::Translate);
                        }
                        0x4F => { // O
                            handle_action(hwnd, ScreenshotAction::Ocr);
                        }
                        0x53 => { // S
                            handle_action(hwnd, ScreenshotAction::Save);
                        }
                        _ => {}
                    }
                    LRESULT(0)
                }

                WM_MOUSEWHEEL => {
                    let delta = ((wparam.0 >> 16) as i16) as i32;
                    let step = if delta > 0 { 1 } else { -1 };
                    let mut should_redraw = false;
                    if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_mut() {
                            if s.active_tool.is_some() {
                                s.stroke_size = ((s.stroke_size as i32) + step).clamp(1, 50) as u32;
                                should_redraw = true;
                            }
                        }
                    }
                    if should_redraw {
                        let _ = InvalidateRect(hwnd, None, false);
                    }
                    LRESULT(0)
                }

                WM_PAINT => {
                    let mut ps = PAINTSTRUCT::default();
                    let hdc = BeginPaint(hwnd, &mut ps);
                    if let Ok(state_lock) = OVERLAY_STATE.lock() {
                        if let Some(s) = state_lock.as_ref() {
                            paint_overlay(hdc, s);
                        }
                    }
                    let _ = EndPaint(hwnd, &ps);
                    LRESULT(0)
                }
                WM_CONTEXTMENU => LRESULT(0),
                WM_DESTROY => {
                    PostQuitMessage(0);
                    LRESULT(0)
                }
                _ => DefWindowProcW(hwnd, msg, wparam, lparam),
            }
        }
    }

    unsafe fn capture_annotated_selection(
        desktop_dc: HDC,
        sel: &RECT,
        annotations: &[AnnotationItem],
    ) -> Option<CapturedImage> {
        let width = sel.right - sel.left;
        let height = sel.bottom - sel.top;
        if width <= 0 || height <= 0 {
            return None;
        }

        let mem_dc = CreateCompatibleDC(desktop_dc);
        let mem_bmp = CreateCompatibleBitmap(desktop_dc, width, height);
        let old_bmp = SelectObject(mem_dc, mem_bmp);

        let _ = BitBlt(mem_dc, 0, 0, width, height, desktop_dc, sel.left, sel.top, SRCCOPY);

        for item in annotations {
            draw_shape_offset(mem_dc, &item.shape, -sel.left, -sel.top, Some(desktop_dc));
        }

        let mut bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height, // top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                biSizeImage: 0,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            bmiColors: [::windows::Win32::Graphics::Gdi::RGBQUAD::default()],
        };

        let mut bgra = vec![0u8; (width * height * 4) as usize];
        let _ = GetDIBits(
            mem_dc,
            mem_bmp,
            0,
            height as u32,
            Some(bgra.as_mut_ptr() as *mut _),
            &mut bi,
            DIB_RGB_COLORS,
        );

        let _ = SelectObject(mem_dc, old_bmp);
        let _ = DeleteObject(mem_bmp);
        let _ = DeleteDC(mem_dc);

        let mut rgba = bgra;
        for chunk in rgba.chunks_exact_mut(4) {
            chunk.swap(0, 2);
            chunk[3] = 255;
        }

        Some(CapturedImage {
            width: width as u32,
            height: height as u32,
            rgba,
        })
    }

    unsafe fn handle_action(hwnd: HWND, action: ScreenshotAction) {
        if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
            if let Some(s) = state_lock.as_mut() {
                if let Some(sel) = current_selection(s) {
                    let rect = Rect::new(
                        (sel.left + s.virtual_origin.x) as f64,
                        (sel.top + s.virtual_origin.y) as f64,
                        (sel.right - sel.left) as f64,
                        (sel.bottom - sel.top) as f64,
                    );
                    s.selected_rect = Some(rect);
                    s.selected_action = Some(action);

                    if let Ok(dc_lock) = SCREENSHOT_DC.lock() {
                        if let Some(saved_dc_raw) = *dc_lock {
                            let saved_dc = HDC(saved_dc_raw as *mut std::ffi::c_void);
                            s.selected_image = capture_annotated_selection(saved_dc, &sel, &s.annotations);
                        }
                    }

                    s.is_finished = true;
                }
            }
        }
        unsafe {
            let _ = DestroyWindow(hwnd);
        }
    }

    unsafe fn cancel_overlay(hwnd: HWND) {
        if let Ok(mut state_lock) = OVERLAY_STATE.lock() {
            if let Some(s) = state_lock.as_mut() {
                s.selected_rect = None;
                s.selected_action = None;
                s.selected_image = None;
                s.is_finished = true;
            }
        }
        unsafe {
            let _ = DestroyWindow(hwnd);
        }
    }

    unsafe fn draw_icon(
        hdc: HDC,
        icon_dc: HDC,
        icon_bmp: ::windows::Win32::Graphics::Gdi::HBITMAP,
        bi: &BITMAPINFO,
        idx: usize,
        cx: i32,
        cy: i32,
        is_active: bool,
        is_hover: bool,
        can_undo: bool,
        can_redo: bool,
    ) {
        if idx >= crate::toolbar_icons_data::ICON_MASKS.len() {
            return;
        }

        let (r, g, b) = if idx == 8 && !can_undo {
            (0xB0, 0xB0, 0xB0)
        } else if idx == 9 && !can_redo {
            (0xB0, 0xB0, 0xB0)
        } else if is_active {
            (0x0A, 0x84, 0xFF)
        } else if is_hover {
            (0x14, 0x14, 0x14)
        } else {
            (0x2E, 0x2E, 0x2E)
        };

        let mask = &crate::toolbar_icons_data::ICON_MASKS[idx];
        let mut bgra = [0u8; 20 * 20 * 4];
        for (i, &a) in mask.iter().enumerate() {
            if a > 0 {
                let pr = ((r as u32 * a as u32) / 255) as u8;
                let pg = ((g as u32 * a as u32) / 255) as u8;
                let pb = ((b as u32 * a as u32) / 255) as u8;
                let base = i * 4;
                bgra[base] = pb;
                bgra[base + 1] = pg;
                bgra[base + 2] = pr;
                bgra[base + 3] = a;
            }
        }

        let _ = SetDIBits(
            icon_dc,
            icon_bmp,
            0,
            20,
            bgra.as_ptr() as *const _,
            bi,
            DIB_RGB_COLORS,
        );

        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: 1, // AC_SRC_ALPHA
        };

        let _ = AlphaBlend(
            hdc,
            cx - 10,
            cy - 10,
            20,
            20,
            icon_dc,
            0,
            0,
            20,
            20,
            blend,
        );
    }

    unsafe fn create_annotation_pen(color: COLORREF, width: i32, dash: u32) -> HPEN {
        let w = width.max(1);
        if dash == 0 {
            CreatePen(PS_SOLID, w, color)
        } else {
            let pen_style = match dash {
                1 => PS_DASH,
                2 => PS_DOT,
                3 => PS_DASHDOT,
                _ => PS_SOLID,
            };
            let lb = LOGBRUSH {
                lbStyle: BS_SOLID,
                lbColor: color,
                lbHatch: 0,
            };
            ExtCreatePen(
                PEN_STYLE(PS_GEOMETRIC.0 | pen_style.0),
                w as u32,
                &lb,
                None,
            )
        }
    }

    unsafe fn draw_arrow(
        hdc: HDC,
        start: POINT,
        end: POINT,
        color: COLORREF,
        width: i32,
        arrow_style: usize,
        dash: u32,
        off_x: i32,
        off_y: i32,
    ) {
        let sx = (start.x + off_x) as f64;
        let sy = (start.y + off_y) as f64;
        let ex = (end.x + off_x) as f64;
        let ey = (end.y + off_y) as f64;
        let dx = ex - sx;
        let dy = ey - sy;
        let length = (dx * dx + dy * dy).sqrt();
        if length < 1.0 {
            return;
        }

        let angle = dy.atan2(dx);
        let head_length = ((width as f64) * 3.0).max(8.0).min(length * 0.38);
        let perp_angle = angle + std::f64::consts::PI / 2.0;

        let mut line_start = POINT { x: sx.round() as i32, y: sy.round() as i32 };
        let mut line_end = POINT { x: ex.round() as i32, y: ey.round() as i32 };

        if arrow_style == 7 || arrow_style == 8 {
            line_end = POINT {
                x: (ex - head_length * 0.75 * angle.cos()).round() as i32,
                y: (ey - head_length * 0.75 * angle.sin()).round() as i32,
            };
        }
        if arrow_style == 8 {
            line_start = POINT {
                x: (sx + head_length * 0.75 * angle.cos()).round() as i32,
                y: (sy + head_length * 0.75 * angle.sin()).round() as i32,
            };
        }

        let stroke_width = if arrow_style == 2 || arrow_style == 3 {
            ((width as f64) * 1.6).round() as i32
        } else {
            width
        };

        let mut graphics = 0usize;
        let _ = gdiplus::GdipCreateFromHDC(hdc, &mut graphics);
        if graphics != 0 {
            let _ = gdiplus::GdipSetSmoothingMode(graphics, 2);
            let argb = gdiplus::colorref_to_argb(color, 255);
            let mut pen = 0usize;
            let _ = gdiplus::GdipCreatePen1(argb, stroke_width.max(1) as f32, 2, &mut pen);
            let gdi_dash = match dash { 1 => 1, 2 => 2, 3 => 3, _ => 0 };
            let _ = gdiplus::GdipSetPenDashStyle(pen, gdi_dash);
            let _ = gdiplus::GdipSetPenLineJoin(pen, 2);
            let _ = gdiplus::GdipSetPenStartCap(pen, 2);
            let _ = gdiplus::GdipSetPenEndCap(pen, 2);

            if arrow_style != 4 && arrow_style != 5 {
                let _ = gdiplus::GdipDrawLine(graphics, pen, line_start.x as f32, line_start.y as f32, line_end.x as f32, line_end.y as f32);
            }

            match arrow_style {
                0 | 2 => {
                    let wing_angle = std::f64::consts::PI / 6.5;
                    let h1 = POINT {
                        x: (ex - head_length * (angle - wing_angle).cos()).round() as i32,
                        y: (ey - head_length * (angle - wing_angle).sin()).round() as i32,
                    };
                    let h2 = POINT {
                        x: (ex - head_length * (angle + wing_angle).cos()).round() as i32,
                        y: (ey - head_length * (angle + wing_angle).sin()).round() as i32,
                    };
                    let _ = gdiplus::GdipDrawLine(graphics, pen, h1.x as f32, h1.y as f32, ex as f32, ey as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, ex as f32, ey as f32, h2.x as f32, h2.y as f32);
                }
                1 | 3 => {
                    let wing_angle = std::f64::consts::PI / 6.5;
                    let eh1 = POINT {
                        x: (ex - head_length * (angle - wing_angle).cos()).round() as i32,
                        y: (ey - head_length * (angle - wing_angle).sin()).round() as i32,
                    };
                    let eh2 = POINT {
                        x: (ex - head_length * (angle + wing_angle).cos()).round() as i32,
                        y: (ey - head_length * (angle + wing_angle).sin()).round() as i32,
                    };
                    let sh1 = POINT {
                        x: (sx + head_length * (angle - wing_angle).cos()).round() as i32,
                        y: (sy + head_length * (angle - wing_angle).sin()).round() as i32,
                    };
                    let sh2 = POINT {
                        x: (sx + head_length * (angle + wing_angle).cos()).round() as i32,
                        y: (sy + head_length * (angle + wing_angle).sin()).round() as i32,
                    };
                    let _ = gdiplus::GdipDrawLine(graphics, pen, eh1.x as f32, eh1.y as f32, ex as f32, ey as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, ex as f32, ey as f32, eh2.x as f32, eh2.y as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, sh1.x as f32, sh1.y as f32, sx as f32, sy as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, sx as f32, sy as f32, sh2.x as f32, sh2.y as f32);
                }
                4 | 5 => {
                    let start_w = ((width as f64) * 0.35).max(1.5);
                    let base_w = ((width as f64) * 1.5).max(3.5);
                    let h_len = ((width as f64) * 3.2).max(9.0).min(length * 0.4);
                    let wing_w = base_w * 1.6;
                    let base_cx = ex - h_len * angle.cos();
                    let base_cy = ey - h_len * angle.sin();

                    let pts = [
                        POINT { x: (sx + (start_w / 2.0) * perp_angle.cos()).round() as i32, y: (sy + (start_w / 2.0) * perp_angle.sin()).round() as i32 },
                        POINT { x: (base_cx + (base_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy + (base_w / 2.0) * perp_angle.sin()).round() as i32 },
                        POINT { x: (base_cx + (wing_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy + (wing_w / 2.0) * perp_angle.sin()).round() as i32 },
                        POINT { x: ex.round() as i32, y: ey.round() as i32 },
                        POINT { x: (base_cx - (wing_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy - (wing_w / 2.0) * perp_angle.sin()).round() as i32 },
                        POINT { x: (base_cx - (base_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy - (base_w / 2.0) * perp_angle.sin()).round() as i32 },
                        POINT { x: (sx - (start_w / 2.0) * perp_angle.cos()).round() as i32, y: (sy - (start_w / 2.0) * perp_angle.sin()).round() as i32 },
                    ];

                    if arrow_style == 5 {
                        let mut brush = 0usize;
                        let _ = gdiplus::GdipCreateSolidFill(argb, &mut brush);
                        let _ = gdiplus::GdipFillPolygonI(graphics, brush, pts.as_ptr(), pts.len() as i32, 0);
                        let _ = gdiplus::GdipDeleteBrush(brush);
                    }
                    let _ = gdiplus::GdipDrawPolygonI(graphics, pen, pts.as_ptr(), pts.len() as i32);
                }
                6 => {
                    let bar_len = head_length * 0.65;
                    let _ = gdiplus::GdipDrawLine(graphics, pen,
                        (sx + bar_len * perp_angle.cos()).round() as f32, (sy + bar_len * perp_angle.sin()).round() as f32,
                        (sx - bar_len * perp_angle.cos()).round() as f32, (sy - bar_len * perp_angle.sin()).round() as f32,
                    );
                    let _ = gdiplus::GdipDrawLine(graphics, pen,
                        (ex + bar_len * perp_angle.cos()).round() as f32, (ey + bar_len * perp_angle.sin()).round() as f32,
                        (ex - bar_len * perp_angle.cos()).round() as f32, (ey - bar_len * perp_angle.sin()).round() as f32,
                    );
                }
                7 => {
                    let base_w = head_length * 0.6;
                    let b1 = POINT {
                        x: (ex - head_length * angle.cos() + base_w * perp_angle.cos()).round() as i32,
                        y: (ey - head_length * angle.sin() + base_w * perp_angle.sin()).round() as i32,
                    };
                    let b2 = POINT {
                        x: (ex - head_length * angle.cos() - base_w * perp_angle.cos()).round() as i32,
                        y: (ey - head_length * angle.sin() - base_w * perp_angle.sin()).round() as i32,
                    };
                    let pts = [POINT { x: ex.round() as i32, y: ey.round() as i32 }, b1, b2];
                    let mut brush = 0usize;
                    let _ = gdiplus::GdipCreateSolidFill(argb, &mut brush);
                    let _ = gdiplus::GdipFillPolygonI(graphics, brush, pts.as_ptr(), pts.len() as i32, 0);
                    let _ = gdiplus::GdipDeleteBrush(brush);
                    let _ = gdiplus::GdipDrawPolygonI(graphics, pen, pts.as_ptr(), pts.len() as i32);
                }
                8 => {
                    let base_w = head_length * 0.6;
                    let eb1 = POINT {
                        x: (ex - head_length * angle.cos() + base_w * perp_angle.cos()).round() as i32,
                        y: (ey - head_length * angle.sin() + base_w * perp_angle.sin()).round() as i32,
                    };
                    let eb2 = POINT {
                        x: (ex - head_length * angle.cos() - base_w * perp_angle.cos()).round() as i32,
                        y: (ey - head_length * angle.sin() - base_w * perp_angle.sin()).round() as i32,
                    };
                    let epts = [POINT { x: ex.round() as i32, y: ey.round() as i32 }, eb1, eb2];

                    let sb1 = POINT {
                        x: (sx + head_length * angle.cos() + base_w * perp_angle.cos()).round() as i32,
                        y: (sy + head_length * angle.sin() + base_w * perp_angle.sin()).round() as i32,
                    };
                    let sb2 = POINT {
                        x: (sx + head_length * angle.cos() - base_w * perp_angle.cos()).round() as i32,
                        y: (sy + head_length * angle.sin() - base_w * perp_angle.sin()).round() as i32,
                    };
                    let spts = [POINT { x: sx.round() as i32, y: sy.round() as i32 }, sb1, sb2];

                    let mut brush = 0usize;
                    let _ = gdiplus::GdipCreateSolidFill(argb, &mut brush);
                    let _ = gdiplus::GdipFillPolygonI(graphics, brush, epts.as_ptr(), epts.len() as i32, 0);
                    let _ = gdiplus::GdipFillPolygonI(graphics, brush, spts.as_ptr(), spts.len() as i32, 0);
                    let _ = gdiplus::GdipDeleteBrush(brush);
                    let _ = gdiplus::GdipDrawPolygonI(graphics, pen, epts.as_ptr(), epts.len() as i32);
                    let _ = gdiplus::GdipDrawPolygonI(graphics, pen, spts.as_ptr(), spts.len() as i32);
                }
                9 => {
                    let bar_len = head_length * 0.65;
                    let _ = gdiplus::GdipDrawLine(graphics, pen,
                        (sx + bar_len * perp_angle.cos()).round() as f32, (sy + bar_len * perp_angle.sin()).round() as f32,
                        (sx - bar_len * perp_angle.cos()).round() as f32, (sy - bar_len * perp_angle.sin()).round() as f32,
                    );
                    let _ = gdiplus::GdipDrawLine(graphics, pen,
                        (ex + bar_len * perp_angle.cos()).round() as f32, (ey + bar_len * perp_angle.sin()).round() as f32,
                        (ex - bar_len * perp_angle.cos()).round() as f32, (ey - bar_len * perp_angle.sin()).round() as f32,
                    );

                    let wing_angle = std::f64::consts::PI / 6.5;
                    let eh1 = POINT {
                        x: (ex - head_length * (angle - wing_angle).cos()).round() as i32,
                        y: (ey - head_length * (angle - wing_angle).sin()).round() as i32,
                    };
                    let eh2 = POINT {
                        x: (ex - head_length * (angle + wing_angle).cos()).round() as i32,
                        y: (ey - head_length * (angle + wing_angle).sin()).round() as i32,
                    };
                    let sh1 = POINT {
                        x: (sx + head_length * (angle - wing_angle).cos()).round() as i32,
                        y: (sy + head_length * (angle - wing_angle).sin()).round() as i32,
                    };
                    let sh2 = POINT {
                        x: (sx + head_length * (angle + wing_angle).cos()).round() as i32,
                        y: (sy + head_length * (angle + wing_angle).sin()).round() as i32,
                    };
                    let _ = gdiplus::GdipDrawLine(graphics, pen, eh1.x as f32, eh1.y as f32, ex as f32, ey as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, ex as f32, ey as f32, eh2.x as f32, eh2.y as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, sh1.x as f32, sh1.y as f32, sx as f32, sy as f32);
                    let _ = gdiplus::GdipDrawLine(graphics, pen, sx as f32, sy as f32, sh2.x as f32, sh2.y as f32);
                }
                _ => {}
            }

            let _ = gdiplus::GdipDeletePen(pen);
            let _ = gdiplus::GdipDeleteGraphics(graphics);
            return;
        }

        // Fallback to GDI
        let pen = create_annotation_pen(color, stroke_width, dash);
        let old_pen = SelectObject(hdc, pen);

        if arrow_style != 4 && arrow_style != 5 {
            let _ = MoveToEx(hdc, line_start.x, line_start.y, None);
            let _ = LineTo(hdc, line_end.x, line_end.y);
        }

        match arrow_style {
            0 | 2 => {
                let wing_angle = std::f64::consts::PI / 6.5;
                let h1 = POINT {
                    x: (ex - head_length * (angle - wing_angle).cos()).round() as i32,
                    y: (ey - head_length * (angle - wing_angle).sin()).round() as i32,
                };
                let h2 = POINT {
                    x: (ex - head_length * (angle + wing_angle).cos()).round() as i32,
                    y: (ey - head_length * (angle + wing_angle).sin()).round() as i32,
                };
                let _ = MoveToEx(hdc, h1.x, h1.y, None);
                let _ = LineTo(hdc, ex.round() as i32, ey.round() as i32);
                let _ = LineTo(hdc, h2.x, h2.y);
            }
            1 | 3 => {
                let wing_angle = std::f64::consts::PI / 6.5;
                let eh1 = POINT {
                    x: (ex - head_length * (angle - wing_angle).cos()).round() as i32,
                    y: (ey - head_length * (angle - wing_angle).sin()).round() as i32,
                };
                let eh2 = POINT {
                    x: (ex - head_length * (angle + wing_angle).cos()).round() as i32,
                    y: (ey - head_length * (angle + wing_angle).sin()).round() as i32,
                };
                let sh1 = POINT {
                    x: (sx + head_length * (angle - wing_angle).cos()).round() as i32,
                    y: (sy + head_length * (angle - wing_angle).sin()).round() as i32,
                };
                let sh2 = POINT {
                    x: (sx + head_length * (angle + wing_angle).cos()).round() as i32,
                    y: (sy + head_length * (angle + wing_angle).sin()).round() as i32,
                };
                let _ = MoveToEx(hdc, eh1.x, eh1.y, None);
                let _ = LineTo(hdc, ex.round() as i32, ey.round() as i32);
                let _ = LineTo(hdc, eh2.x, eh2.y);
                let _ = MoveToEx(hdc, sh1.x, sh1.y, None);
                let _ = LineTo(hdc, sx.round() as i32, sy.round() as i32);
                let _ = LineTo(hdc, sh2.x, sh2.y);
            }
            4 | 5 => {
                let start_w = ((width as f64) * 0.35).max(1.5);
                let base_w = ((width as f64) * 1.5).max(3.5);
                let h_len = ((width as f64) * 3.2).max(9.0).min(length * 0.4);
                let wing_w = base_w * 1.6;
                let base_cx = ex - h_len * angle.cos();
                let base_cy = ey - h_len * angle.sin();

                let pts = [
                    POINT { x: (sx + (start_w / 2.0) * perp_angle.cos()).round() as i32, y: (sy + (start_w / 2.0) * perp_angle.sin()).round() as i32 },
                    POINT { x: (base_cx + (base_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy + (base_w / 2.0) * perp_angle.sin()).round() as i32 },
                    POINT { x: (base_cx + (wing_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy + (wing_w / 2.0) * perp_angle.sin()).round() as i32 },
                    POINT { x: ex.round() as i32, y: ey.round() as i32 },
                    POINT { x: (base_cx - (wing_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy - (wing_w / 2.0) * perp_angle.sin()).round() as i32 },
                    POINT { x: (base_cx - (base_w / 2.0) * perp_angle.cos()).round() as i32, y: (base_cy - (base_w / 2.0) * perp_angle.sin()).round() as i32 },
                    POINT { x: (sx - (start_w / 2.0) * perp_angle.cos()).round() as i32, y: (sy - (start_w / 2.0) * perp_angle.sin()).round() as i32 },
                ];

                let brush = if arrow_style == 5 {
                    CreateSolidBrush(color)
                } else {
                    HBRUSH(GetStockObject(NULL_BRUSH).0)
                };
                let old_brush = SelectObject(hdc, brush);
                let _ = Polygon(hdc, &pts);
                let _ = SelectObject(hdc, old_brush);
                if arrow_style == 5 {
                    let _ = DeleteObject(brush);
                }
            }
            6 => {
                let bar_len = head_length * 0.65;
                let _ = MoveToEx(hdc, (sx + bar_len * perp_angle.cos()).round() as i32, (sy + bar_len * perp_angle.sin()).round() as i32, None);
                let _ = LineTo(hdc, (sx - bar_len * perp_angle.cos()).round() as i32, (sy - bar_len * perp_angle.sin()).round() as i32);
                let _ = MoveToEx(hdc, (ex + bar_len * perp_angle.cos()).round() as i32, (ey + bar_len * perp_angle.sin()).round() as i32, None);
                let _ = LineTo(hdc, (ex - bar_len * perp_angle.cos()).round() as i32, (ey - bar_len * perp_angle.sin()).round() as i32);
            }
            7 => {
                let base_w = head_length * 0.6;
                let b1 = POINT {
                    x: (ex - head_length * angle.cos() + base_w * perp_angle.cos()).round() as i32,
                    y: (ey - head_length * angle.sin() + base_w * perp_angle.sin()).round() as i32,
                };
                let b2 = POINT {
                    x: (ex - head_length * angle.cos() - base_w * perp_angle.cos()).round() as i32,
                    y: (ey - head_length * angle.sin() - base_w * perp_angle.sin()).round() as i32,
                };
                let pts = [POINT { x: ex.round() as i32, y: ey.round() as i32 }, b1, b2];
                let brush = CreateSolidBrush(color);
                let old_brush = SelectObject(hdc, brush);
                let _ = Polygon(hdc, &pts);
                let _ = SelectObject(hdc, old_brush);
                let _ = DeleteObject(brush);
            }
            8 => {
                let base_w = head_length * 0.6;
                let eb1 = POINT {
                    x: (ex - head_length * angle.cos() + base_w * perp_angle.cos()).round() as i32,
                    y: (ey - head_length * angle.sin() + base_w * perp_angle.sin()).round() as i32,
                };
                let eb2 = POINT {
                    x: (ex - head_length * angle.cos() - base_w * perp_angle.cos()).round() as i32,
                    y: (ey - head_length * angle.sin() - base_w * perp_angle.sin()).round() as i32,
                };
                let epts = [POINT { x: ex.round() as i32, y: ey.round() as i32 }, eb1, eb2];

                let sb1 = POINT {
                    x: (sx + head_length * angle.cos() + base_w * perp_angle.cos()).round() as i32,
                    y: (sy + head_length * angle.sin() + base_w * perp_angle.sin()).round() as i32,
                };
                let sb2 = POINT {
                    x: (sx + head_length * angle.cos() - base_w * perp_angle.cos()).round() as i32,
                    y: (sy + head_length * angle.sin() - base_w * perp_angle.sin()).round() as i32,
                };
                let spts = [POINT { x: sx.round() as i32, y: sy.round() as i32 }, sb1, sb2];

                let brush = CreateSolidBrush(color);
                let old_brush = SelectObject(hdc, brush);
                let _ = Polygon(hdc, &epts);
                let _ = Polygon(hdc, &spts);
                let _ = SelectObject(hdc, old_brush);
                let _ = DeleteObject(brush);
            }
            9 => {
                let bar_len = head_length * 0.65;
                let _ = MoveToEx(hdc, (sx + bar_len * perp_angle.cos()).round() as i32, (sy + bar_len * perp_angle.sin()).round() as i32, None);
                let _ = LineTo(hdc, (sx - bar_len * perp_angle.cos()).round() as i32, (sy - bar_len * perp_angle.sin()).round() as i32);
                let _ = MoveToEx(hdc, (ex + bar_len * perp_angle.cos()).round() as i32, (ey + bar_len * perp_angle.sin()).round() as i32, None);
                let _ = LineTo(hdc, (ex - bar_len * perp_angle.cos()).round() as i32, (ey - bar_len * perp_angle.sin()).round() as i32);

                let wing_angle = std::f64::consts::PI / 6.5;
                let eh1 = POINT {
                    x: (ex - head_length * (angle - wing_angle).cos()).round() as i32,
                    y: (ey - head_length * (angle - wing_angle).sin()).round() as i32,
                };
                let eh2 = POINT {
                    x: (ex - head_length * (angle + wing_angle).cos()).round() as i32,
                    y: (ey - head_length * (angle + wing_angle).sin()).round() as i32,
                };
                let sh1 = POINT {
                    x: (sx + head_length * (angle - wing_angle).cos()).round() as i32,
                    y: (sy + head_length * (angle - wing_angle).sin()).round() as i32,
                };
                let sh2 = POINT {
                    x: (sx + head_length * (angle + wing_angle).cos()).round() as i32,
                    y: (sy + head_length * (angle + wing_angle).sin()).round() as i32,
                };
                let _ = MoveToEx(hdc, eh1.x, eh1.y, None);
                let _ = LineTo(hdc, ex.round() as i32, ey.round() as i32);
                let _ = LineTo(hdc, eh2.x, eh2.y);
                let _ = MoveToEx(hdc, sh1.x, sh1.y, None);
                let _ = LineTo(hdc, sx.round() as i32, sy.round() as i32);
                let _ = LineTo(hdc, sh2.x, sh2.y);
            }
            _ => {}
        }

        let _ = SelectObject(hdc, old_pen);
        let _ = DeleteObject(pen);
    }

    unsafe fn draw_toolbars(
        hdc: HDC,
        sel: &RECT,
        screen_w: i32,
        screen_h: i32,
        active_tool: Option<usize>,
        hovered_item: Option<usize>,
        stroke_size: u32,
        selected_color_idx: usize,
        line_dash: u32,
        arrow_style: usize,
        is_arrow_open: bool,
        is_dash_open: bool,
        number_is_filled: bool,
        mosaic_style: usize,
        is_mosaic_open: bool,
        can_undo: bool,
        can_redo: bool,
    ) {
        let show_sub = active_tool.is_some();
        let tb1 = get_main_toolbar_rect(sel, screen_w, screen_h, show_sub);

        // 1. Draw Main Toolbar capsule
        let bg_brush = CreateSolidBrush(rgb(0xFF, 0xFF, 0xFF));
        let border_pen = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
        let old_brush = SelectObject(hdc, bg_brush);
        let old_pen = SelectObject(hdc, border_pen);
        let _ = RoundRect(hdc, tb1.left, tb1.top, tb1.right, tb1.bottom, 22, 22);

        // Draw divider between tool group and action group
        let div_x = tb1.left + TB1_PAD_X + 10 * (BTN_W + GAP) + DIVIDER_W / 2;
        let div_pen = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
        let _ = SelectObject(hdc, div_pen);
        let _ = MoveToEx(hdc, div_x, tb1.top + 10, None);
        let _ = LineTo(hdc, div_x, tb1.bottom - 10);
        let _ = SelectObject(hdc, border_pen);
        let _ = DeleteObject(div_pen);

        let icon_dc = CreateCompatibleDC(hdc);
        let icon_bmp = CreateCompatibleBitmap(hdc, 20, 20);
        let old_icon_bmp = SelectObject(icon_dc, icon_bmp);

        let bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: 20,
                biHeight: -20, // top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                biSizeImage: 0,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            bmiColors: [::windows::Win32::Graphics::Gdi::RGBQUAD::default()],
        };

        // Draw 19 buttons
        for i in 0..19 {
            let rc = get_button_rect(&tb1, i);
            let is_active = active_tool == Some(i);
            let is_hover = hovered_item == Some(i);

            if is_active {
                let act_b = CreateSolidBrush(rgb(0xE0, 0xED, 0xFF));
                let _ = SelectObject(hdc, act_b);
                let null_p = CreatePen(PS_SOLID, 1, rgb(0x0A, 0x84, 0xFF));
                let _ = SelectObject(hdc, null_p);
                let _ = RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, 6, 6);
                let _ = SelectObject(hdc, border_pen);
                let _ = SelectObject(hdc, bg_brush);
                let _ = DeleteObject(null_p);
                let _ = DeleteObject(act_b);
            } else if is_hover {
                let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                let _ = SelectObject(hdc, hov_b);
                let null_p = GetStockObject(NULL_BRUSH);
                let _ = SelectObject(hdc, null_p);
                let _ = RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, 6, 6);
                let _ = SelectObject(hdc, border_pen);
                let _ = SelectObject(hdc, bg_brush);
                let _ = DeleteObject(hov_b);
            }

            let cx = (rc.left + rc.right) / 2;
            let cy = (rc.top + rc.bottom) / 2;
            draw_icon(hdc, icon_dc, icon_bmp, &bi, i, cx, cy, is_active, is_hover, can_undo, can_redo);
        }

        let _ = SelectObject(icon_dc, old_icon_bmp);
        let _ = DeleteObject(icon_bmp);
        let _ = DeleteDC(icon_dc);

        // 2. Draw Sub Toolbar capsule
        if show_sub {
            let tb2 = get_sub_toolbar_rect(&tb1, sel, screen_h, active_tool);
            let _ = RoundRect(hdc, tb2.left, tb2.top, tb2.right, tb2.bottom, 18, 18);

            match active_tool {
                Some(2) => {
                    // Arrow Style dropdown button (item 300)
                    let btn_arr_hov = hovered_item == Some(300) || is_arrow_open;
                    if btn_arr_hov {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 8, tb2.top + 4, tb2.left + 74, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let acx = tb2.left + 41;
                    let acy = (tb2.top + tb2.bottom) / 2;
                    draw_arrow(hdc, POINT { x: acx - 18, y: acy }, POINT { x: acx + 18, y: acy }, rgb(0x2E, 0x2E, 0x2E), 2, arrow_style, 0, 0, 0);

                    // Line Dash dropdown button (item 301)
                    let btn_dash_hov = hovered_item == Some(301) || is_dash_open;
                    if btn_dash_hov {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 78, tb2.top + 4, tb2.left + 142, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let lcx = tb2.left + 110;
                    let lcy = (tb2.top + tb2.bottom) / 2;
                    let dpen = create_annotation_pen(rgb(0x2E, 0x2E, 0x2E), 2, line_dash);
                    let old_dp = SelectObject(hdc, dpen);
                    let _ = MoveToEx(hdc, lcx - 22, lcy, None);
                    let _ = LineTo(hdc, lcx + 22, lcy);
                    let _ = SelectObject(hdc, old_dp);
                    let _ = DeleteObject(dpen);

                    // Stroke size button (item 100)
                    let stroke_is_hover = hovered_item == Some(100);
                    if stroke_is_hover {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 146, tb2.top + 4, tb2.left + 186, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let dot_b = CreateSolidBrush(rgb(0x33, 0x33, 0x33));
                    let _ = SelectObject(hdc, dot_b);
                    let _ = Ellipse(hdc, tb2.left + 152, tb2.top + 14, tb2.left + 158, tb2.top + 20);
                    let _ = SelectObject(hdc, bg_brush);
                    let _ = DeleteObject(dot_b);

                    let stroke_str = format!("{}", stroke_size);
                    let stroke_u16: Vec<u16> = stroke_str.encode_utf16().collect();
                    let font = CreateFontW(
                        -11, 0, 0, 0, 700, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_f = SelectObject(hdc, font);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, rgb(0x33, 0x33, 0x33));
                    let _ = TextOutW(hdc, tb2.left + 162, tb2.top + 10, &stroke_u16);
                    let _ = SelectObject(hdc, old_f);
                    let _ = DeleteObject(font);

                    // Divider
                    let sdiv_x = tb2.left + 190;
                    let sdiv_p = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
                    let _ = SelectObject(hdc, sdiv_p);
                    let _ = MoveToEx(hdc, sdiv_x, tb2.top + 8, None);
                    let _ = LineTo(hdc, sdiv_x, tb2.bottom - 8);
                    let _ = SelectObject(hdc, border_pen);
                    let _ = DeleteObject(sdiv_p);

                    // 8 Color circles
                    let pal_x = tb2.left + 196;
                    for c in 0..8 {
                        let cx = pal_x + c * 22 + 11;
                        let cy = (tb2.top + tb2.bottom) / 2;
                        let col = PALETTE[c as usize];

                        let cb = CreateSolidBrush(col);
                        let _ = SelectObject(hdc, cb);
                        let cp = if c == 7 {
                            CreatePen(PS_SOLID, 1, rgb(0xCB, 0xD5, 0xE1))
                        } else {
                            CreatePen(PS_SOLID, 1, col)
                        };
                        let _ = SelectObject(hdc, cp);
                        let _ = Ellipse(hdc, cx - 7, cy - 7, cx + 7, cy + 7);
                        let _ = SelectObject(hdc, border_pen);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(cp);
                        let _ = DeleteObject(cb);

                        if selected_color_idx == c as usize {
                            let ring_p = CreatePen(PS_SOLID, 2, col);
                            let _ = SelectObject(hdc, ring_p);
                            let _ = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                            let _ = Ellipse(hdc, cx - 10, cy - 10, cx + 10, cy + 10);
                            let _ = SelectObject(hdc, bg_brush);
                            let _ = SelectObject(hdc, border_pen);
                            let _ = DeleteObject(ring_p);
                        }
                    }
                }
                Some(6) => {
                    // Mosaic style dropdown button (item 320): tb2.left + 8..tb2.left + 108
                    let btn_mos_hov = hovered_item == Some(320) || is_mosaic_open;
                    if btn_mos_hov {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 8, tb2.top + 4, tb2.left + 108, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let names = ["涂抹 · 像素", "涂抹 · 模糊", "矩形 · 像素", "矩形 · 模糊"];
                    let cur_name = names[mosaic_style.min(3)];
                    let cur_name_u16: Vec<u16> = cur_name.encode_utf16().collect();
                    let font = CreateFontW(
                        -11, 0, 0, 0, 500, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Microsoft YaHei\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_f = SelectObject(hdc, font);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, rgb(0x2E, 0x2E, 0x2E));
                    let _ = TextOutW(hdc, tb2.left + 14, tb2.top + 9, &cur_name_u16);
                    let _ = SelectObject(hdc, old_f);
                    let _ = DeleteObject(font);

                    let chevron = "▾";
                    let chevron_u16: Vec<u16> = chevron.encode_utf16().collect();
                    let c_font = CreateFontW(
                        -9, 0, 0, 0, 400, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_cf = SelectObject(hdc, c_font);
                    let _ = SetTextColor(hdc, rgb(0x66, 0x66, 0x66));
                    let _ = TextOutW(hdc, tb2.left + 94, tb2.top + 10, &chevron_u16);
                    let _ = SelectObject(hdc, old_cf);
                    let _ = DeleteObject(c_font);

                    // Stroke size / Block size button (item 100): tb2.left + 112..tb2.left + 152
                    let stroke_is_hover = hovered_item == Some(100);
                    if stroke_is_hover {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 112, tb2.top + 4, tb2.left + 152, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let dot_b = CreateSolidBrush(rgb(0x33, 0x33, 0x33));
                    let _ = SelectObject(hdc, dot_b);
                    let _ = Ellipse(hdc, tb2.left + 118, tb2.top + 14, tb2.left + 124, tb2.top + 20);
                    let _ = SelectObject(hdc, bg_brush);
                    let _ = DeleteObject(dot_b);

                    let stroke_str = format!("{}", stroke_size);
                    let stroke_u16: Vec<u16> = stroke_str.encode_utf16().collect();
                    let font = CreateFontW(
                        -11, 0, 0, 0, 700, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_f = SelectObject(hdc, font);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, rgb(0x33, 0x33, 0x33));
                    let _ = TextOutW(hdc, tb2.left + 128, tb2.top + 10, &stroke_u16);
                    let _ = SelectObject(hdc, old_f);
                    let _ = DeleteObject(font);
                }
                Some(7) => {
                    // NumberFilled button (item 310): tb2.left + 8..tb2.left + 34
                    let btn_fill_hov = hovered_item == Some(310);
                    if number_is_filled {
                        let act_b = CreateSolidBrush(rgb(0xE0, 0xED, 0xFF));
                        let _ = SelectObject(hdc, act_b);
                        let null_p = CreatePen(PS_SOLID, 1, rgb(0x0A, 0x84, 0xFF));
                        let _ = SelectObject(hdc, null_p);
                        let _ = RoundRect(hdc, tb2.left + 8, tb2.top + 4, tb2.left + 34, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, border_pen);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(null_p);
                        let _ = DeleteObject(act_b);
                    } else if btn_fill_hov {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 8, tb2.top + 4, tb2.left + 34, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let fcx = tb2.left + 21;
                    let fcy = (tb2.top + tb2.bottom) / 2;
                    let fcol = if number_is_filled { rgb(0x0A, 0x84, 0xFF) } else { rgb(0x4B, 0x55, 0x63) };
                    let cb = CreateSolidBrush(fcol);
                    let cp = CreatePen(PS_SOLID, 1, fcol);
                    let _ = SelectObject(hdc, cb);
                    let _ = SelectObject(hdc, cp);
                    let _ = Ellipse(hdc, fcx - 7, fcy - 7, fcx + 8, fcy + 8);
                    let _ = SelectObject(hdc, border_pen);
                    let _ = SelectObject(hdc, bg_brush);
                    let _ = DeleteObject(cp);
                    let _ = DeleteObject(cb);

                    let ffont = CreateFontW(
                        -9, 0, 0, 0, 700, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_ff = SelectObject(hdc, ffont);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, rgb(0xFF, 0xFF, 0xFF));
                    let one_str: Vec<u16> = "1\0".encode_utf16().collect();
                    let _ = TextOutW(hdc, fcx - 3, fcy - 6, &one_str[..1]);
                    let _ = SelectObject(hdc, old_ff);
                    let _ = DeleteObject(ffont);

                    // NumberOutline button (item 311): tb2.left + 36..tb2.left + 62
                    let btn_out_hov = hovered_item == Some(311);
                    if !number_is_filled {
                        let act_b = CreateSolidBrush(rgb(0xE0, 0xED, 0xFF));
                        let _ = SelectObject(hdc, act_b);
                        let null_p = CreatePen(PS_SOLID, 1, rgb(0x0A, 0x84, 0xFF));
                        let _ = SelectObject(hdc, null_p);
                        let _ = RoundRect(hdc, tb2.left + 36, tb2.top + 4, tb2.left + 62, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, border_pen);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(null_p);
                        let _ = DeleteObject(act_b);
                    } else if btn_out_hov {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 36, tb2.top + 4, tb2.left + 62, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let ocx = tb2.left + 49;
                    let ocy = (tb2.top + tb2.bottom) / 2;
                    let ocol = if !number_is_filled { rgb(0x0A, 0x84, 0xFF) } else { rgb(0x4B, 0x55, 0x63) };
                    let op = CreatePen(PS_SOLID, 1, ocol);
                    let _ = SelectObject(hdc, op);
                    let _ = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                    let _ = Ellipse(hdc, ocx - 7, ocy - 7, ocx + 8, ocy + 8);
                    let _ = SelectObject(hdc, bg_brush);
                    let _ = SelectObject(hdc, border_pen);
                    let _ = DeleteObject(op);

                    let ofont = CreateFontW(
                        -9, 0, 0, 0, 700, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_of = SelectObject(hdc, ofont);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, ocol);
                    let _ = TextOutW(hdc, ocx - 3, ocy - 6, &one_str[..1]);
                    let _ = SelectObject(hdc, old_of);
                    let _ = DeleteObject(ofont);

                    // Stroke size button (item 100): tb2.left + 66..tb2.left + 106
                    let stroke_is_hover = hovered_item == Some(100);
                    if stroke_is_hover {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 66, tb2.top + 4, tb2.left + 106, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let dot_b = CreateSolidBrush(rgb(0x33, 0x33, 0x33));
                    let _ = SelectObject(hdc, dot_b);
                    let _ = Ellipse(hdc, tb2.left + 72, tb2.top + 14, tb2.left + 78, tb2.top + 20);
                    let _ = SelectObject(hdc, bg_brush);
                    let _ = DeleteObject(dot_b);

                    let stroke_str = format!("{}", stroke_size);
                    let stroke_u16: Vec<u16> = stroke_str.encode_utf16().collect();
                    let font = CreateFontW(
                        -11, 0, 0, 0, 700, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_f = SelectObject(hdc, font);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, rgb(0x33, 0x33, 0x33));
                    let _ = TextOutW(hdc, tb2.left + 82, tb2.top + 10, &stroke_u16);
                    let _ = SelectObject(hdc, old_f);
                    let _ = DeleteObject(font);

                    // Divider
                    let sdiv_x = tb2.left + 110;
                    let sdiv_p = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
                    let _ = SelectObject(hdc, sdiv_p);
                    let _ = MoveToEx(hdc, sdiv_x, tb2.top + 8, None);
                    let _ = LineTo(hdc, sdiv_x, tb2.bottom - 8);
                    let _ = SelectObject(hdc, border_pen);
                    let _ = DeleteObject(sdiv_p);

                    // 8 Color circles starting at tb2.left + 116
                    let pal_x = tb2.left + 116;
                    for c in 0..8 {
                        let cx = pal_x + c * 22 + 11;
                        let cy = (tb2.top + tb2.bottom) / 2;
                        let col = PALETTE[c as usize];

                        let cb = CreateSolidBrush(col);
                        let _ = SelectObject(hdc, cb);
                        let cp = if c == 7 {
                            CreatePen(PS_SOLID, 1, rgb(0xCB, 0xD5, 0xE1))
                        } else {
                            CreatePen(PS_SOLID, 1, col)
                        };
                        let _ = SelectObject(hdc, cp);
                        let _ = Ellipse(hdc, cx - 7, cy - 7, cx + 7, cy + 7);
                        let _ = SelectObject(hdc, border_pen);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(cp);
                        let _ = DeleteObject(cb);

                        if selected_color_idx == c as usize {
                            let ring_p = CreatePen(PS_SOLID, 2, col);
                            let _ = SelectObject(hdc, ring_p);
                            let _ = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                            let _ = Ellipse(hdc, cx - 10, cy - 10, cx + 10, cy + 10);
                            let _ = SelectObject(hdc, bg_brush);
                            let _ = SelectObject(hdc, border_pen);
                            let _ = DeleteObject(ring_p);
                        }
                    }
                }
                _ => {
                    // Default tools: Pen, Line, Ellipse, Rect, Text
                    // Line Dash dropdown button (item 301)
                    let btn_dash_hov = hovered_item == Some(301) || is_dash_open;
                    if btn_dash_hov {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 8, tb2.top + 4, tb2.left + 72, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let lcx = tb2.left + 40;
                    let lcy = (tb2.top + tb2.bottom) / 2;
                    let dpen = create_annotation_pen(rgb(0x2E, 0x2E, 0x2E), 2, line_dash);
                    let old_dp = SelectObject(hdc, dpen);
                    let _ = MoveToEx(hdc, lcx - 22, lcy, None);
                    let _ = LineTo(hdc, lcx + 22, lcy);
                    let _ = SelectObject(hdc, old_dp);
                    let _ = DeleteObject(dpen);

                    // Stroke size button (item 100)
                    let stroke_is_hover = hovered_item == Some(100);
                    if stroke_is_hover {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, tb2.left + 76, tb2.top + 4, tb2.left + 116, tb2.bottom - 4, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let dot_b = CreateSolidBrush(rgb(0x33, 0x33, 0x33));
                    let _ = SelectObject(hdc, dot_b);
                    let _ = Ellipse(hdc, tb2.left + 82, tb2.top + 14, tb2.left + 88, tb2.top + 20);
                    let _ = SelectObject(hdc, bg_brush);
                    let _ = DeleteObject(dot_b);

                    let stroke_str = format!("{}", stroke_size);
                    let stroke_u16: Vec<u16> = stroke_str.encode_utf16().collect();
                    let font = CreateFontW(
                        -11, 0, 0, 0, 700, 0, 0, 0,
                        DEFAULT_CHARSET.0 as u32,
                        OUT_DEFAULT_PRECIS.0 as u32,
                        CLIP_DEFAULT_PRECIS.0 as u32,
                        DEFAULT_QUALITY.0 as u32,
                        (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                        PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                    );
                    let old_f = SelectObject(hdc, font);
                    let _ = SetBkMode(hdc, TRANSPARENT);
                    let _ = SetTextColor(hdc, rgb(0x33, 0x33, 0x33));
                    let _ = TextOutW(hdc, tb2.left + 92, tb2.top + 10, &stroke_u16);
                    let _ = SelectObject(hdc, old_f);
                    let _ = DeleteObject(font);

                    // Divider
                    let sdiv_x = tb2.left + 120;
                    let sdiv_p = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
                    let _ = SelectObject(hdc, sdiv_p);
                    let _ = MoveToEx(hdc, sdiv_x, tb2.top + 8, None);
                    let _ = LineTo(hdc, sdiv_x, tb2.bottom - 8);
                    let _ = SelectObject(hdc, border_pen);
                    let _ = DeleteObject(sdiv_p);

                    // 8 Color circles
                    let pal_x = tb2.left + 126;
                    for c in 0..8 {
                        let cx = pal_x + c * 22 + 11;
                        let cy = (tb2.top + tb2.bottom) / 2;
                        let col = PALETTE[c as usize];

                        let cb = CreateSolidBrush(col);
                        let _ = SelectObject(hdc, cb);
                        let cp = if c == 7 {
                            CreatePen(PS_SOLID, 1, rgb(0xCB, 0xD5, 0xE1))
                        } else {
                            CreatePen(PS_SOLID, 1, col)
                        };
                        let _ = SelectObject(hdc, cp);
                        let _ = Ellipse(hdc, cx - 7, cy - 7, cx + 7, cy + 7);
                        let _ = SelectObject(hdc, border_pen);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(cp);
                        let _ = DeleteObject(cb);

                        if selected_color_idx == c as usize {
                            let ring_p = CreatePen(PS_SOLID, 2, col);
                            let _ = SelectObject(hdc, ring_p);
                            let _ = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                            let _ = Ellipse(hdc, cx - 10, cy - 10, cx + 10, cy + 10);
                            let _ = SelectObject(hdc, bg_brush);
                            let _ = SelectObject(hdc, border_pen);
                            let _ = DeleteObject(ring_p);
                        }
                    }
                }
            }

            // Draw Arrow Style Popup
            if is_arrow_open && active_tool == Some(2) {
                let ap = get_arrow_popup_rect(&tb2);
                let _ = RoundRect(hdc, ap.left, ap.top, ap.right, ap.bottom, 12, 12);
                for i in 0..10 {
                    let it = ap.top + 4 + i as i32 * 28;
                    let ib = it + 26;
                    let is_h = hovered_item == Some(400 + i);
                    let is_sel = arrow_style == i;
                    if is_sel {
                        let sel_b = CreateSolidBrush(rgb(0xE0, 0xED, 0xFF));
                        let _ = SelectObject(hdc, sel_b);
                        let _ = RoundRect(hdc, ap.left + 4, it, ap.right - 4, ib, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(sel_b);
                    } else if is_h {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, ap.left + 4, it, ap.right - 4, ib, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let acx = (ap.left + ap.right) / 2;
                    let acy = (it + ib) / 2;
                    let acol = if is_sel { rgb(0x0A, 0x84, 0xFF) } else { rgb(0x2E, 0x2E, 0x2E) };
                    draw_arrow(hdc, POINT { x: acx - 20, y: acy }, POINT { x: acx + 20, y: acy }, acol, 2, i, 0, 0, 0);
                }
            }

            // Draw Line Dash Popup
            if is_dash_open {
                let dp = get_line_dash_popup_rect(&tb2, active_tool);
                let _ = RoundRect(hdc, dp.left, dp.top, dp.right, dp.bottom, 10, 10);
                for i in 0..4 {
                    let it = dp.top + 4 + i as i32 * 26;
                    let ib = it + 24;
                    let is_h = hovered_item == Some(500 + i);
                    let is_sel = line_dash == i as u32;
                    if is_sel {
                        let sel_b = CreateSolidBrush(rgb(0xE0, 0xED, 0xFF));
                        let _ = SelectObject(hdc, sel_b);
                        let _ = RoundRect(hdc, dp.left + 4, it, dp.right - 4, ib, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(sel_b);
                    } else if is_h {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, dp.left + 4, it, dp.right - 4, ib, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let lcx = (dp.left + dp.right) / 2;
                    let lcy = (it + ib) / 2;
                    let lcol = if is_sel { rgb(0x0A, 0x84, 0xFF) } else { rgb(0x2E, 0x2E, 0x2E) };
                    let pen = create_annotation_pen(lcol, 2, i as u32);
                    let old_p = SelectObject(hdc, pen);
                    let _ = MoveToEx(hdc, lcx - 24, lcy, None);
                    let _ = LineTo(hdc, lcx + 24, lcy);
                    let _ = SelectObject(hdc, old_p);
                    let _ = DeleteObject(pen);
                }
            }

            // Draw Mosaic Popup
            if is_mosaic_open && active_tool == Some(6) {
                let mp = get_mosaic_popup_rect(&tb2);
                let _ = RoundRect(hdc, mp.left, mp.top, mp.right, mp.bottom, 10, 10);
                let names = ["涂抹 · 像素", "涂抹 · 模糊", "矩形 · 像素", "矩形 · 模糊"];
                let font = CreateFontW(
                    -11, 0, 0, 0, 500, 0, 0, 0,
                    DEFAULT_CHARSET.0 as u32,
                    OUT_DEFAULT_PRECIS.0 as u32,
                    CLIP_DEFAULT_PRECIS.0 as u32,
                    DEFAULT_QUALITY.0 as u32,
                    (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                    PCWSTR("Microsoft YaHei\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                );
                let old_f = SelectObject(hdc, font);
                let _ = SetBkMode(hdc, TRANSPARENT);
                for i in 0..4 {
                    let it = mp.top + 4 + i as i32 * 26;
                    let ib = it + 24;
                    let is_h = hovered_item == Some(510 + i);
                    let is_sel = mosaic_style == i;
                    if is_sel {
                        let sel_b = CreateSolidBrush(rgb(0xE0, 0xED, 0xFF));
                        let _ = SelectObject(hdc, sel_b);
                        let _ = RoundRect(hdc, mp.left + 4, it, mp.right - 4, ib, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(sel_b);
                    } else if is_h {
                        let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                        let _ = SelectObject(hdc, hov_b);
                        let _ = RoundRect(hdc, mp.left + 4, it, mp.right - 4, ib, 6, 6);
                        let _ = SelectObject(hdc, bg_brush);
                        let _ = DeleteObject(hov_b);
                    }
                    let tcol = if is_sel { rgb(0x0A, 0x84, 0xFF) } else { rgb(0x2E, 0x2E, 0x2E) };
                    let _ = SetTextColor(hdc, tcol);
                    let item_u16: Vec<u16> = names[i].encode_utf16().collect();
                    let _ = TextOutW(hdc, mp.left + 14, it + 4, &item_u16);
                }
                let _ = SelectObject(hdc, old_f);
                let _ = DeleteObject(font);
            }
        }

        let _ = SelectObject(hdc, old_brush);
        let _ = SelectObject(hdc, old_pen);
        let _ = DeleteObject(border_pen);
        let _ = DeleteObject(bg_brush);
    }

    unsafe fn draw_shape_offset(
        hdc: HDC,
        shape: &AnnotationShape,
        off_x: i32,
        off_y: i32,
        saved_dc: Option<HDC>,
    ) {
        match shape {
            AnnotationShape::Pen { points, color, width, dash } => {
                if points.len() < 2 {
                    return;
                }
                let mut graphics = 0usize;
                let _ = gdiplus::GdipCreateFromHDC(hdc, &mut graphics);
                if graphics != 0 {
                    let _ = gdiplus::GdipSetSmoothingMode(graphics, 2);
                    let argb = gdiplus::colorref_to_argb(*color, 255);
                    let mut pen = 0usize;
                    let _ = gdiplus::GdipCreatePen1(argb, (*width).max(1) as f32, 2, &mut pen);
                    let gdi_dash = match *dash { 1 => 1, 2 => 2, 3 => 3, _ => 0 };
                    let _ = gdiplus::GdipSetPenDashStyle(pen, gdi_dash);
                    let _ = gdiplus::GdipSetPenLineJoin(pen, 2);
                    let _ = gdiplus::GdipSetPenStartCap(pen, 2);
                    let _ = gdiplus::GdipSetPenEndCap(pen, 2);
                    let offset_pts: Vec<POINT> = points.iter().map(|p| POINT { x: p.x + off_x, y: p.y + off_y }).collect();
                    let _ = gdiplus::GdipDrawLinesI(graphics, pen, offset_pts.as_ptr(), offset_pts.len() as i32);
                    let _ = gdiplus::GdipDeletePen(pen);
                    let _ = gdiplus::GdipDeleteGraphics(graphics);
                } else {
                    let pen = create_annotation_pen(*color, *width, *dash);
                    let old_pen = SelectObject(hdc, pen);
                    let _ = MoveToEx(hdc, points[0].x + off_x, points[0].y + off_y, None);
                    for pt in &points[1..] {
                        let _ = LineTo(hdc, pt.x + off_x, pt.y + off_y);
                    }
                    let _ = SelectObject(hdc, old_pen);
                    let _ = DeleteObject(pen);
                }
            }
            AnnotationShape::Line { start, end, color, width, dash } => {
                let mut graphics = 0usize;
                let _ = gdiplus::GdipCreateFromHDC(hdc, &mut graphics);
                if graphics != 0 {
                    let _ = gdiplus::GdipSetSmoothingMode(graphics, 2);
                    let argb = gdiplus::colorref_to_argb(*color, 255);
                    let mut pen = 0usize;
                    let _ = gdiplus::GdipCreatePen1(argb, (*width).max(1) as f32, 2, &mut pen);
                    let gdi_dash = match *dash { 1 => 1, 2 => 2, 3 => 3, _ => 0 };
                    let _ = gdiplus::GdipSetPenDashStyle(pen, gdi_dash);
                    let _ = gdiplus::GdipSetPenLineJoin(pen, 2);
                    let _ = gdiplus::GdipSetPenStartCap(pen, 2);
                    let _ = gdiplus::GdipSetPenEndCap(pen, 2);
                    let _ = gdiplus::GdipDrawLine(
                        graphics, pen,
                        (start.x + off_x) as f32, (start.y + off_y) as f32,
                        (end.x + off_x) as f32, (end.y + off_y) as f32,
                    );
                    let _ = gdiplus::GdipDeletePen(pen);
                    let _ = gdiplus::GdipDeleteGraphics(graphics);
                } else {
                    let pen = create_annotation_pen(*color, *width, *dash);
                    let old_pen = SelectObject(hdc, pen);
                    let _ = MoveToEx(hdc, start.x + off_x, start.y + off_y, None);
                    let _ = LineTo(hdc, end.x + off_x, end.y + off_y);
                    let _ = SelectObject(hdc, old_pen);
                    let _ = DeleteObject(pen);
                }
            }
            AnnotationShape::Arrow { start, end, color, width, arrow_style, dash } => {
                draw_arrow(hdc, *start, *end, *color, *width, *arrow_style, *dash, off_x, off_y);
            }
            AnnotationShape::Rect { rect, color, width, dash } => {
                let l = rect.left.min(rect.right) + off_x;
                let t = rect.top.min(rect.bottom) + off_y;
                let r = rect.left.max(rect.right) + off_x;
                let b = rect.top.max(rect.bottom) + off_y;
                let w = (r - l).max(1);
                let h = (b - t).max(1);
                let mut graphics = 0usize;
                let _ = gdiplus::GdipCreateFromHDC(hdc, &mut graphics);
                if graphics != 0 {
                    let _ = gdiplus::GdipSetSmoothingMode(graphics, 2);
                    let argb = gdiplus::colorref_to_argb(*color, 255);
                    let mut pen = 0usize;
                    let _ = gdiplus::GdipCreatePen1(argb, (*width).max(1) as f32, 2, &mut pen);
                    let gdi_dash = match *dash { 1 => 1, 2 => 2, 3 => 3, _ => 0 };
                    let _ = gdiplus::GdipSetPenDashStyle(pen, gdi_dash);
                    let _ = gdiplus::GdipDrawRectangleI(graphics, pen, l, t, w, h);
                    let _ = gdiplus::GdipDeletePen(pen);
                    let _ = gdiplus::GdipDeleteGraphics(graphics);
                } else {
                    let pen = create_annotation_pen(*color, *width, *dash);
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                    let _ = Rectangle(hdc, l, t, r, b);
                    let _ = SelectObject(hdc, old_brush);
                    let _ = SelectObject(hdc, old_pen);
                    let _ = DeleteObject(pen);
                }
            }
            AnnotationShape::Ellipse { rect, color, width, dash } => {
                let l = rect.left.min(rect.right) + off_x;
                let t = rect.top.min(rect.bottom) + off_y;
                let r = rect.left.max(rect.right) + off_x;
                let b = rect.top.max(rect.bottom) + off_y;
                let w = (r - l).max(1);
                let h = (b - t).max(1);
                let mut graphics = 0usize;
                let _ = gdiplus::GdipCreateFromHDC(hdc, &mut graphics);
                if graphics != 0 {
                    let _ = gdiplus::GdipSetSmoothingMode(graphics, 2);
                    let argb = gdiplus::colorref_to_argb(*color, 255);
                    let mut pen = 0usize;
                    let _ = gdiplus::GdipCreatePen1(argb, (*width).max(1) as f32, 2, &mut pen);
                    let gdi_dash = match *dash { 1 => 1, 2 => 2, 3 => 3, _ => 0 };
                    let _ = gdiplus::GdipSetPenDashStyle(pen, gdi_dash);
                    let _ = gdiplus::GdipDrawEllipseI(graphics, pen, l, t, w, h);
                    let _ = gdiplus::GdipDeletePen(pen);
                    let _ = gdiplus::GdipDeleteGraphics(graphics);
                } else {
                    let pen = create_annotation_pen(*color, *width, *dash);
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                    let _ = Ellipse(hdc, l, t, r, b);
                    let _ = SelectObject(hdc, old_brush);
                    let _ = SelectObject(hdc, old_pen);
                    let _ = DeleteObject(pen);
                }
            }
            AnnotationShape::Text { pos, text, color, font_size } => {
                let font = CreateFontW(
                    -*font_size,
                    0, 0, 0, 700, 0, 0, 0,
                    DEFAULT_CHARSET.0 as u32,
                    OUT_DEFAULT_PRECIS.0 as u32,
                    CLIP_DEFAULT_PRECIS.0 as u32,
                    DEFAULT_QUALITY.0 as u32,
                    (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                    PCWSTR("Microsoft YaHei\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                );
                let old_font = SelectObject(hdc, font);
                let _ = SetBkMode(hdc, TRANSPARENT);
                let _ = SetTextColor(hdc, *color);
                let u16_text: Vec<u16> = text.encode_utf16().collect();
                let _ = TextOutW(hdc, pos.x + off_x, pos.y + off_y, &u16_text);
                let _ = SelectObject(hdc, old_font);
                let _ = DeleteObject(font);
            }
            AnnotationShape::Number { center, num, color, radius, is_filled } => {
                let cx = center.x + off_x;
                let cy = center.y + off_y;
                let r = *radius;
                let mut graphics = 0usize;
                let _ = gdiplus::GdipCreateFromHDC(hdc, &mut graphics);
                if graphics != 0 {
                    let _ = gdiplus::GdipSetSmoothingMode(graphics, 2);
                    let argb = gdiplus::colorref_to_argb(*color, 255);
                    if *is_filled {
                        let mut brush = 0usize;
                        let _ = gdiplus::GdipCreateSolidFill(argb, &mut brush);
                        let _ = gdiplus::GdipFillEllipseI(graphics, brush, cx - r, cy - r, r * 2, r * 2);
                        let _ = gdiplus::GdipDeleteBrush(brush);
                    } else {
                        let mut pen = 0usize;
                        let _ = gdiplus::GdipCreatePen1(argb, 2.0, 2, &mut pen);
                        let _ = gdiplus::GdipDrawEllipseI(graphics, pen, cx - r, cy - r, r * 2, r * 2);
                        let _ = gdiplus::GdipDeletePen(pen);
                    }
                    let _ = gdiplus::GdipDeleteGraphics(graphics);
                } else {
                    let brush = if *is_filled { CreateSolidBrush(*color) } else { HBRUSH(GetStockObject(NULL_BRUSH).0) };
                    let pen = CreatePen(PS_SOLID, 2, *color);
                    let old_brush = SelectObject(hdc, brush);
                    let old_pen = SelectObject(hdc, pen);
                    let _ = Ellipse(hdc, cx - r, cy - r, cx + r, cy + r);
                    let _ = SelectObject(hdc, old_pen);
                    let _ = SelectObject(hdc, old_brush);
                    let _ = DeleteObject(pen);
                    if *is_filled {
                        let _ = DeleteObject(brush);
                    }
                }

                let num_str = format!("{}", num);
                let num_u16: Vec<u16> = num_str.encode_utf16().collect();
                let font_h = ((r as f64) * 1.1).round() as i32;
                let font = CreateFontW(
                    -font_h, 0, 0, 0, 700, 0, 0, 0,
                    DEFAULT_CHARSET.0 as u32,
                    OUT_DEFAULT_PRECIS.0 as u32,
                    CLIP_DEFAULT_PRECIS.0 as u32,
                    DEFAULT_QUALITY.0 as u32,
                    (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                    PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                );
                let old_font = SelectObject(hdc, font);
                let _ = SetBkMode(hdc, TRANSPARENT);
                let text_color = if *is_filled { rgb(0xFF, 0xFF, 0xFF) } else { *color };
                let _ = SetTextColor(hdc, text_color);
                let tx = if *num < 10 { cx - font_h / 3 } else { cx - font_h / 2 };
                let ty = cy - font_h / 2;
                let _ = TextOutW(hdc, tx, ty, &num_u16);
                let _ = SelectObject(hdc, old_font);
                let _ = DeleteObject(font);
            }
            AnnotationShape::Mosaic { shape_type, is_blur, points, rect, block_size } => {
                if let Some(src_dc) = saved_dc {
                    let bs = (*block_size).max(4);
                    if *shape_type == 1 {
                        let l = rect.left.min(rect.right) + off_x;
                        let t = rect.top.min(rect.bottom) + off_y;
                        let r = rect.left.max(rect.right) + off_x;
                        let b = rect.top.max(rect.bottom) + off_y;
                        let rw = r - l;
                        let rh = b - t;
                        if rw > 0 && rh > 0 {
                            if *is_blur {
                                let scale = (bs / 2).clamp(4, 16);
                                let small_w = (rw / scale).max(1);
                                let small_h = (rh / scale).max(1);
                                let mem_dc = CreateCompatibleDC(hdc);
                                let mem_bmp = CreateCompatibleBitmap(hdc, small_w, small_h);
                                let old_bmp = SelectObject(mem_dc, mem_bmp);

                                let _ = SetStretchBltMode(mem_dc, HALFTONE);
                                let _ = StretchBlt(mem_dc, 0, 0, small_w, small_h, src_dc, l - off_x, t - off_y, rw, rh, SRCCOPY);

                                let _ = SetStretchBltMode(hdc, HALFTONE);
                                let _ = StretchBlt(hdc, l, t, rw, rh, mem_dc, 0, 0, small_w, small_h, SRCCOPY);

                                let _ = SelectObject(mem_dc, old_bmp);
                                let _ = DeleteObject(mem_bmp);
                                let _ = DeleteDC(mem_dc);
                            } else {
                                let mut y = t;
                                while y < b {
                                    let mut x = l;
                                    while x < r {
                                        let sample_x = (x + bs / 2).min(r - 1) - off_x;
                                        let sample_y = (y + bs / 2).min(b - 1) - off_y;
                                        let col = GetPixel(src_dc, sample_x, sample_y);
                                        let brush = CreateSolidBrush(col);
                                        let bx = RECT {
                                            left: x,
                                            top: y,
                                            right: (x + bs).min(r),
                                            bottom: (y + bs).min(b),
                                        };
                                        let _ = FillRect(hdc, &bx, brush);
                                        let _ = DeleteObject(brush);
                                        x += bs;
                                    }
                                    y += bs;
                                }
                            }
                        }
                    } else {
                        // Smear (涂抹)
                        if !points.is_empty() {
                            let radius = bs;
                            let diameter = radius * 2;
                            for i in 0..points.len() {
                                let pt0 = points[i];
                                let pt1 = if i + 1 < points.len() { points[i + 1] } else { pt0 };
                                let dx = (pt1.x - pt0.x) as f64;
                                let dy = (pt1.y - pt0.y) as f64;
                                let dist = (dx * dx + dy * dy).sqrt();
                                let steps = ((dist / (radius.max(2) as f64)).ceil() as i32).max(1);

                                for step in 0..=steps {
                                    let progress = (step as f64) / (steps as f64);
                                    let cx = (pt0.x as f64 + dx * progress).round() as i32 + off_x;
                                    let cy = (pt0.y as f64 + dy * progress).round() as i32 + off_y;
                                    let sx = cx - off_x;
                                    let sy = cy - off_y;

                                    let sl = cx - radius;
                                    let st = cy - radius;

                                    if *is_blur {
                                        let small_w = 4;
                                        let small_h = 4;
                                        let mem_dc = CreateCompatibleDC(hdc);
                                        let mem_bmp = CreateCompatibleBitmap(hdc, small_w, small_h);
                                        let old_bmp = SelectObject(mem_dc, mem_bmp);

                                        let _ = SetStretchBltMode(mem_dc, HALFTONE);
                                        let _ = StretchBlt(mem_dc, 0, 0, small_w, small_h, src_dc, sx - radius, sy - radius, diameter, diameter, SRCCOPY);

                                        let _ = SetStretchBltMode(hdc, HALFTONE);
                                        let _ = StretchBlt(hdc, sl, st, diameter, diameter, mem_dc, 0, 0, small_w, small_h, SRCCOPY);

                                        let _ = SelectObject(mem_dc, old_bmp);
                                        let _ = DeleteObject(mem_bmp);
                                        let _ = DeleteDC(mem_dc);
                                    } else {
                                        let col = GetPixel(src_dc, sx, sy);
                                        let brush = CreateSolidBrush(col);
                                        let bx = RECT { left: sl, top: st, right: sl + diameter, bottom: st + diameter };
                                        let _ = FillRect(hdc, &bx, brush);
                                        let _ = DeleteObject(brush);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    unsafe fn draw_long_status(hdc: HDC, sel: &RECT, screen_w: i32, screen_h: i32, text: &str) {
        let rc = get_long_status_rect(sel, screen_w, screen_h);
        let brush = CreateSolidBrush(rgb(0x1E, 0x1E, 0x24));
        let pen = CreatePen(PS_SOLID, 1, rgb(0x44, 0x44, 0x44));
        let old_brush = SelectObject(hdc, brush);
        let old_pen = SelectObject(hdc, pen);
        let _ = RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, 16, 16);

        let text_u16: Vec<u16> = text.encode_utf16().collect();
        let font = CreateFontW(
            -12, 0, 0, 0, 600, 0, 0, 0,
            DEFAULT_CHARSET.0 as u32,
            OUT_DEFAULT_PRECIS.0 as u32,
            CLIP_DEFAULT_PRECIS.0 as u32,
            DEFAULT_QUALITY.0 as u32,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            PCWSTR("Microsoft YaHei\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        let _ = SetBkMode(hdc, TRANSPARENT);
        let _ = SetTextColor(hdc, rgb(0xFF, 0xFF, 0xFF));
        let _ = TextOutW(hdc, rc.left + 16, rc.top + 7, &text_u16);

        let _ = SelectObject(hdc, old_font);
        let _ = SelectObject(hdc, old_pen);
        let _ = SelectObject(hdc, old_brush);
        let _ = DeleteObject(font);
        let _ = DeleteObject(pen);
        let _ = DeleteObject(brush);
    }

    unsafe fn draw_long_toolbar(
        hdc: HDC,
        sel: &RECT,
        screen_w: i32,
        screen_h: i32,
        hovered: Option<usize>,
    ) {
        let tb = get_long_toolbar_rect(sel, screen_w, screen_h);
        let bg_b = CreateSolidBrush(rgb(0xFF, 0xFF, 0xFF));
        let pen = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
        let old_b = SelectObject(hdc, bg_b);
        let old_p = SelectObject(hdc, pen);
        let _ = RoundRect(hdc, tb.left, tb.top, tb.right, tb.bottom, 22, 22);

        // Divider before Cancel
        let div_x = tb.left + 130;
        let div_p = CreatePen(PS_SOLID, 1, rgb(0xE5, 0xE7, 0xEB));
        let _ = SelectObject(hdc, div_p);
        let _ = MoveToEx(hdc, div_x, tb.top + 10, None);
        let _ = LineTo(hdc, div_x, tb.bottom - 10);
        let _ = SelectObject(hdc, pen);
        let _ = DeleteObject(div_p);

        let items = [
            (600, tb.left + 10, 17), // Pin
            (601, tb.left + 50, 18), // Copy
            (602, tb.left + 90, 15), // Save/Finish
            (603, tb.left + 134, 16), // Cancel
        ];

        let icon_dc = CreateCompatibleDC(hdc);
        let icon_bmp = CreateCompatibleBitmap(hdc, 20, 20);
        let old_icon_bmp = SelectObject(icon_dc, icon_bmp);
        let bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: 20,
                biHeight: -20,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                biSizeImage: 0,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            bmiColors: [::windows::Win32::Graphics::Gdi::RGBQUAD::default()],
        };

        for (action_id, btn_x, icon_idx) in items {
            let is_hov = hovered == Some(action_id);
            if is_hov {
                let hov_b = CreateSolidBrush(rgb(0xF3, 0xF4, 0xF6));
                let _ = SelectObject(hdc, hov_b);
                let _ = RoundRect(hdc, btn_x, tb.top + 5, btn_x + 36, tb.bottom - 5, 8, 8);
                let _ = SelectObject(hdc, bg_b);
                let _ = DeleteObject(hov_b);
            }
            draw_icon(hdc, icon_dc, icon_bmp, &bi, icon_idx, btn_x + 18, (tb.top + tb.bottom) / 2, false, is_hov, true, true);
        }

        let _ = SelectObject(icon_dc, old_icon_bmp);
        let _ = DeleteObject(icon_bmp);
        let _ = DeleteDC(icon_dc);

        let _ = SelectObject(hdc, old_p);
        let _ = SelectObject(hdc, old_b);
        let _ = DeleteObject(pen);
        let _ = DeleteObject(bg_b);
    }

    unsafe fn draw_long_preview(
        hdc: HDC,
        sel: &RECT,
        screen_w: i32,
        screen_h: i32,
        preview: Option<&(Vec<u8>, u32, u32)>,
    ) {
        let Some((bytes, pw, ph)) = preview else {
            return;
        };
        if *pw == 0 || *ph == 0 || bytes.is_empty() {
            return;
        }

        let rc = get_long_preview_rect(sel, screen_w, screen_h, *ph as i32 + 10);
        let card_b = CreateSolidBrush(rgb(0xF8, 0xF9, 0xFA));
        let card_p = CreatePen(PS_SOLID, 1, rgb(0xD1, 0xD5, 0xDB));
        let old_b = SelectObject(hdc, card_b);
        let old_p = SelectObject(hdc, card_p);
        let _ = RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, 10, 10);

        let img_dc = CreateCompatibleDC(hdc);
        let img_bmp = CreateCompatibleBitmap(hdc, *pw as i32, *ph as i32);
        let old_img = SelectObject(img_dc, img_bmp);

        let bi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: *pw as i32,
                biHeight: -(*ph as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                biSizeImage: 0,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            bmiColors: [::windows::Win32::Graphics::Gdi::RGBQUAD::default()],
        };

        let mut bgra = bytes.clone();
        for p in bgra.chunks_exact_mut(4) {
            p.swap(0, 2);
        }

        let _ = SetDIBits(img_dc, img_bmp, 0, *ph, bgra.as_ptr() as *const _, &bi, DIB_RGB_COLORS);

        let draw_x = rc.left + (rc.right - rc.left - *pw as i32) / 2;
        let draw_y = rc.top + 5;
        let _ = BitBlt(hdc, draw_x, draw_y, *pw as i32, *ph as i32, img_dc, 0, 0, SRCCOPY);

        let vp_h = ((*ph as f64) * 0.15).max(6.0).min(*ph as f64) as i32;
        let vp_y = draw_y + *ph as i32 - vp_h;
        let vp_pen = CreatePen(PS_SOLID, 2, rgb(0x34, 0xC7, 0x59));
        let old_vp_p = SelectObject(hdc, vp_pen);
        let old_vp_b = SelectObject(hdc, GetStockObject(NULL_BRUSH));
        let _ = Rectangle(hdc, draw_x, vp_y, draw_x + *pw as i32, vp_y + vp_h);

        let _ = SelectObject(hdc, old_vp_b);
        let _ = SelectObject(hdc, old_vp_p);
        let _ = DeleteObject(vp_pen);

        let _ = SelectObject(img_dc, old_img);
        let _ = DeleteObject(img_bmp);
        let _ = DeleteDC(img_dc);

        let _ = SelectObject(hdc, old_p);
        let _ = SelectObject(hdc, old_b);
        let _ = DeleteObject(card_p);
        let _ = DeleteObject(card_b);
    }

    unsafe fn draw_dimension_badge(hdc: HDC, sel: &RECT) {
        let width = sel.right - sel.left;
        let height = sel.bottom - sel.top;
        let text = format!("{} \u{00D7} {} px", width, height);
        let text_u16: Vec<u16> = text.encode_utf16().collect();

        let badge_w = 96;
        let badge_h = 24;
        let mut bx = sel.left;
        let mut by = sel.top - badge_h - 6;
        if by < 6 {
            by = sel.top + 6;
            bx = sel.left + 6;
        }

        let badge_brush = CreateSolidBrush(rgb(0x1A, 0x1A, 0x1E));
        let border_pen = CreatePen(PS_SOLID, 1, rgb(0x38, 0x38, 0x40));
        let old_brush = SelectObject(hdc, badge_brush);
        let old_pen = SelectObject(hdc, border_pen);
        let _ = RoundRect(hdc, bx, by, bx + badge_w, by + badge_h, 8, 8);

        let font = CreateFontW(
            -11, 0, 0, 0, 600, 0, 0, 0,
            DEFAULT_CHARSET.0 as u32,
            OUT_DEFAULT_PRECIS.0 as u32,
            CLIP_DEFAULT_PRECIS.0 as u32,
            DEFAULT_QUALITY.0 as u32,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            PCWSTR("Segoe UI\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        let _ = SetBkMode(hdc, TRANSPARENT);
        let _ = SetTextColor(hdc, rgb(0xFF, 0xFF, 0xFF));
        let _ = TextOutW(hdc, bx + 10, by + 4, &text_u16);

        let _ = SelectObject(hdc, old_font);
        let _ = SelectObject(hdc, old_pen);
        let _ = SelectObject(hdc, old_brush);
        let _ = DeleteObject(font);
        let _ = DeleteObject(border_pen);
        let _ = DeleteObject(badge_brush);
    }

    unsafe fn draw_magnifier(hdc: HDC, pt: POINT, screen_w: i32, screen_h: i32, origin: POINT, is_rgb_mode: bool) {
        let mag_w = 196;
        let mag_h = 196;
        let mut mag_x = pt.x + 16;
        let mut mag_y = pt.y + 16;
        if mag_x + mag_w > screen_w - 10 {
            mag_x = pt.x - mag_w - 16;
        }
        if mag_y + mag_h > screen_h - 10 {
            mag_y = pt.y - mag_h - 16;
        }
        if mag_x < 10 { mag_x = 10; }
        if mag_y < 10 { mag_y = 10; }

        let card_b = CreateSolidBrush(rgb(0x1E, 0x1E, 0x24));
        let card_p = CreatePen(PS_SOLID, 1, rgb(0x44, 0x44, 0x44));
        let old_b = SelectObject(hdc, card_b);
        let old_p = SelectObject(hdc, card_p);
        let _ = RoundRect(hdc, mag_x, mag_y, mag_x + mag_w, mag_y + mag_h, 16, 16);

        let vp_x = mag_x + 9;
        let vp_y = mag_y + 9;
        let vp_w = 178;
        let vp_h = 100;

        if let Ok(dc_lock) = SCREENSHOT_DC.lock() {
            if let Some(saved_dc_raw) = *dc_lock {
                let saved_dc = HDC(saved_dc_raw as *mut std::ffi::c_void);
                let _ = SetStretchBltMode(hdc, COLORONCOLOR);
                let _ = StretchBlt(
                    hdc,
                    vp_x,
                    vp_y,
                    vp_w,
                    vp_h,
                    saved_dc,
                    pt.x - 15,
                    pt.y - 8,
                    30,
                    17,
                    SRCCOPY,
                );

                let vp_p = CreatePen(PS_SOLID, 1, rgb(0x60, 0x60, 0x60));
                let _ = SelectObject(hdc, vp_p);
                let _ = SelectObject(hdc, GetStockObject(NULL_BRUSH));
                let _ = RoundRect(hdc, vp_x, vp_y, vp_x + vp_w, vp_y + vp_h, 8, 8);
                let _ = DeleteObject(vp_p);

                let cx = vp_x + vp_w / 2;
                let cy = vp_y + vp_h / 2;

                let white_p = CreatePen(PS_SOLID, 2, rgb(0xC0, 0xC0, 0xC0));
                let _ = SelectObject(hdc, white_p);
                let _ = MoveToEx(hdc, vp_x + 1, cy, None);
                let _ = LineTo(hdc, vp_x + vp_w - 1, cy);
                let _ = MoveToEx(hdc, cx, vp_y + 1, None);
                let _ = LineTo(hdc, cx, vp_y + vp_h - 1);
                let _ = DeleteObject(white_p);

                let red_p = CreatePen(PS_SOLID, 1, rgb(0xFF, 0x3B, 0x30));
                let _ = SelectObject(hdc, red_p);
                let _ = MoveToEx(hdc, vp_x + 1, cy, None);
                let _ = LineTo(hdc, vp_x + vp_w - 1, cy);
                let _ = MoveToEx(hdc, cx, vp_y + 1, None);
                let _ = LineTo(hdc, cx, vp_y + vp_h - 1);

                let _ = Rectangle(hdc, cx - 5, cy - 5, cx + 6, cy + 6);
                let _ = DeleteObject(red_p);

                let pixel = GetPixel(saved_dc, pt.x, pt.y);
                let r = (pixel.0 & 0xFF) as u8;
                let g = ((pixel.0 >> 8) & 0xFF) as u8;
                let b = ((pixel.0 >> 16) & 0xFF) as u8;

                let box_x = mag_x + 28;
                let box_y = mag_y + 118;
                let col_b = CreateSolidBrush(rgb(r, g, b));
                let col_p = CreatePen(PS_SOLID, 1, rgb(0x88, 0x88, 0x88));
                let _ = SelectObject(hdc, col_b);
                let _ = SelectObject(hdc, col_p);
                let _ = RoundRect(hdc, box_x, box_y, box_x + 15, box_y + 15, 4, 4);
                let _ = DeleteObject(col_p);
                let _ = DeleteObject(col_b);

                let color_str = if is_rgb_mode {
                    format!("RGB({}, {}, {})", r, g, b)
                } else {
                    format!("#{:02X}{:02X}{:02X}", r, g, b)
                };
                let color_u16: Vec<u16> = color_str.encode_utf16().collect();
                let font_bold = CreateFontW(
                    -12, 0, 0, 0, 700, 0, 0, 0,
                    DEFAULT_CHARSET.0 as u32,
                    OUT_DEFAULT_PRECIS.0 as u32,
                    CLIP_DEFAULT_PRECIS.0 as u32,
                    DEFAULT_QUALITY.0 as u32,
                    (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                    PCWSTR("Consolas\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                );
                let _ = SelectObject(hdc, font_bold);
                let _ = SetBkMode(hdc, TRANSPARENT);
                let _ = SetTextColor(hdc, rgb(0xFF, 0xFF, 0xFF));
                let _ = TextOutW(hdc, box_x + 22, box_y + 1, &color_u16);
                let _ = DeleteObject(font_bold);

                let coord_str = format!("({}, {}) px", pt.x + origin.x, pt.y + origin.y);
                let coord_u16: Vec<u16> = coord_str.encode_utf16().collect();
                let font_norm = CreateFontW(
                    -11, 0, 0, 0, 500, 0, 0, 0,
                    DEFAULT_CHARSET.0 as u32,
                    OUT_DEFAULT_PRECIS.0 as u32,
                    CLIP_DEFAULT_PRECIS.0 as u32,
                    DEFAULT_QUALITY.0 as u32,
                    (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
                    PCWSTR("Consolas\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
                );
                let _ = SelectObject(hdc, font_norm);
                let _ = SetTextColor(hdc, rgb(0xB9, 0xC2, 0xCF));
                let _ = TextOutW(hdc, mag_x + 50, mag_y + 142, &coord_u16);

                let hint_str = "C 复制色值 · ⇧C 切换 HEX/RGB";
                let hint_u16: Vec<u16> = hint_str.encode_utf16().collect();
                let _ = SetTextColor(hdc, rgb(0x94, 0xA3, 0xB8));
                let _ = TextOutW(hdc, mag_x + 14, mag_y + 166, &hint_u16);
                let _ = DeleteObject(font_norm);
            }
        }

        let _ = SelectObject(hdc, old_p);
        let _ = SelectObject(hdc, old_b);
        let _ = DeleteObject(card_p);
        let _ = DeleteObject(card_b);
    }

    unsafe fn draw_top_hint(hdc: HDC, screen_w: i32) {
        let text = "移动鼠标自动选择 · C 复制色值 · ⇧C 切换 HEX/RGB · 右键返回 · Esc 退出";
        let text_u16: Vec<u16> = text.encode_utf16().collect();
        let hint_w = 480;
        let hint_h = 32;
        let hint_x = (screen_w - hint_w) / 2;
        let hint_y = 36;

        let badge_brush = CreateSolidBrush(rgb(0x1E, 0x1E, 0x24));
        let border_pen = CreatePen(PS_SOLID, 1, rgb(0x44, 0x44, 0x44));
        let old_brush = SelectObject(hdc, badge_brush);
        let old_pen = SelectObject(hdc, border_pen);
        let _ = RoundRect(hdc, hint_x, hint_y, hint_x + hint_w, hint_y + hint_h, 16, 16);

        let font = CreateFontW(
            -12, 0, 0, 0, 500, 0, 0, 0,
            DEFAULT_CHARSET.0 as u32,
            OUT_DEFAULT_PRECIS.0 as u32,
            CLIP_DEFAULT_PRECIS.0 as u32,
            DEFAULT_QUALITY.0 as u32,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            PCWSTR("Microsoft YaHei\0".encode_utf16().collect::<Vec<_>>().as_ptr()),
        );
        let old_font = SelectObject(hdc, font);
        let _ = SetBkMode(hdc, TRANSPARENT);
        let _ = SetTextColor(hdc, rgb(0xFF, 0xFF, 0xFF));
        let _ = TextOutW(hdc, hint_x + 18, hint_y + 7, &text_u16);

        let _ = SelectObject(hdc, old_font);
        let _ = SelectObject(hdc, old_pen);
        let _ = SelectObject(hdc, old_brush);
        let _ = DeleteObject(font);
        let _ = DeleteObject(border_pen);
        let _ = DeleteObject(badge_brush);
    }

    unsafe fn paint_overlay(hdc: HDC, state: &OverlayState) {
        let width = state.screen_w;
        let height = state.screen_h;

        let backbuffer_dc = CreateCompatibleDC(hdc);
        let backbuffer_bmp = CreateCompatibleBitmap(hdc, width, height);
        let old_backbuffer = SelectObject(backbuffer_dc, backbuffer_bmp);

        // 1. BitBlt saved desktop screenshot
        if let Ok(dc_lock) = SCREENSHOT_DC.lock() {
            if let Some(saved_dc_raw) = *dc_lock {
                let saved_dc = HDC(saved_dc_raw as *mut std::ffi::c_void);
                let _ = BitBlt(backbuffer_dc, 0, 0, width, height, saved_dc, 0, 0, SRCCOPY);
            }
        }

        // 2. AlphaBlend dark mask
        let dim_dc = CreateCompatibleDC(hdc);
        let dim_bmp = CreateCompatibleBitmap(hdc, 1, 1);
        let old_dim_bmp = SelectObject(dim_dc, dim_bmp);
        let black_brush = CreateSolidBrush(COLORREF(0));
        let rc_one = RECT { left: 0, top: 0, right: 1, bottom: 1 };
        let _ = FillRect(dim_dc, &rc_one, black_brush);
        let _ = DeleteObject(black_brush);

        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 102, // 40% black
            AlphaFormat: 0,
        };

        let active_hole = if let Some(sel) = current_selection(state) {
            Some(sel)
        } else if state.phase == SelectionPhase::Ready {
            state.candidate_rect
        } else {
            None
        };

        if let Some(hole) = active_hole {
            // Darken outside selection (4-quadrant mask)
            if hole.top > 0 {
                let _ = AlphaBlend(backbuffer_dc, 0, 0, width, hole.top, dim_dc, 0, 0, 1, 1, blend);
            }
            if hole.bottom < height {
                let _ = AlphaBlend(backbuffer_dc, 0, hole.bottom, width, height - hole.bottom, dim_dc, 0, 0, 1, 1, blend);
            }
            if hole.left > 0 {
                let _ = AlphaBlend(backbuffer_dc, 0, hole.top, hole.left, hole.bottom - hole.top, dim_dc, 0, 0, 1, 1, blend);
            }
            if hole.right < width {
                let _ = AlphaBlend(backbuffer_dc, hole.right, hole.top, width - hole.right, hole.bottom - hole.top, dim_dc, 0, 0, 1, 1, blend);
            }

            if state.phase == SelectionPhase::LongCapturing {
                let pen = CreatePen(PS_SOLID, 2, rgb(0x0A, 0x84, 0xFF));
                let old_pen = SelectObject(backbuffer_dc, pen);
                let old_brush = SelectObject(backbuffer_dc, GetStockObject(NULL_BRUSH));
                let _ = Rectangle(backbuffer_dc, hole.left, hole.top, hole.right, hole.bottom);
                let _ = SelectObject(backbuffer_dc, old_brush);
                let _ = SelectObject(backbuffer_dc, old_pen);
                let _ = DeleteObject(pen);

                draw_long_status(backbuffer_dc, &hole, width, height, &state.long_status_text);
                draw_long_toolbar(backbuffer_dc, &hole, width, height, state.hovered_item);
                draw_long_preview(backbuffer_dc, &hole, width, height, state.long_preview.as_ref());
            } else if state.phase == SelectionPhase::Ready {
                // Draw candidate border
                let pen = CreatePen(PS_SOLID, 2, rgb(0x0A, 0x84, 0xFF));
                let old_pen = SelectObject(backbuffer_dc, pen);
                let old_brush = SelectObject(backbuffer_dc, GetStockObject(NULL_BRUSH));
                let _ = Rectangle(backbuffer_dc, hole.left, hole.top, hole.right, hole.bottom);
                let _ = SelectObject(backbuffer_dc, old_brush);
                let _ = SelectObject(backbuffer_dc, old_pen);
                let _ = DeleteObject(pen);

                if let Some(pt) = state.current_pt {
                    draw_magnifier(backbuffer_dc, pt, width, height, state.virtual_origin, state.is_rgb_mode);
                }
            } else {
                // Draw annotations inside selection (clipped)
                let hrgn = CreateRectRgn(hole.left, hole.top, hole.right, hole.bottom);
                let _ = SelectClipRgn(backbuffer_dc, hrgn);

                if let Ok(dc_lock) = SCREENSHOT_DC.lock() {
                    if let Some(saved_dc_raw) = *dc_lock {
                        let saved_dc = HDC(saved_dc_raw as *mut std::ffi::c_void);
                        for item in &state.annotations {
                            draw_shape_offset(backbuffer_dc, &item.shape, 0, 0, Some(saved_dc));
                        }
                        if let Some(ref current_shape) = state.current_drawing {
                            draw_shape_offset(backbuffer_dc, current_shape, 0, 0, Some(saved_dc));
                        }
                    }
                }

                let _ = SelectClipRgn(backbuffer_dc, HRGN::default());
                let _ = DeleteObject(hrgn);

                // Draw selection border: 2px Vibrant Blue (#0A84FF)
                let pen = CreatePen(PS_SOLID, 2, rgb(0x0A, 0x84, 0xFF));
                let old_pen = SelectObject(backbuffer_dc, pen);
                let old_brush = SelectObject(backbuffer_dc, GetStockObject(NULL_BRUSH));
                let _ = Rectangle(backbuffer_dc, hole.left, hole.top, hole.right, hole.bottom);

                if state.phase != SelectionPhase::DraggingNew {
                    // Draw 8 handles: 8x8 white boxes with #0A84FF border
                    let handle_brush = CreateSolidBrush(rgb(0xFF, 0xFF, 0xFF));
                    let _ = SelectObject(backbuffer_dc, handle_brush);
                    let handle_pen = CreatePen(PS_SOLID, 1, rgb(0x0A, 0x84, 0xFF));
                    let _ = SelectObject(backbuffer_dc, handle_pen);
                    let handles = get_handle_rects(&hole);
                    for h in handles.iter() {
                        let _ = RoundRect(backbuffer_dc, h.left, h.top, h.right, h.bottom, 2, 2);
                    }
                    let _ = DeleteObject(handle_pen);
                    let _ = DeleteObject(handle_brush);
                }

                let _ = SelectObject(backbuffer_dc, old_brush);
                let _ = SelectObject(backbuffer_dc, old_pen);
                let _ = DeleteObject(pen);

                // Size badge
                draw_dimension_badge(backbuffer_dc, &hole);

                if state.phase != SelectionPhase::DraggingNew {
                    let can_undo = !state.annotations.is_empty();
                    let can_redo = !state.redo_stack.is_empty();
                    draw_toolbars(
                        backbuffer_dc,
                        &hole,
                        width,
                        height,
                        state.active_tool,
                        state.hovered_item,
                        state.stroke_size,
                        state.selected_color_idx,
                        state.line_dash_pattern,
                        state.arrow_style,
                        state.is_arrow_popup_open,
                        state.is_line_dash_popup_open,
                        state.number_is_filled,
                        state.mosaic_style,
                        state.is_mosaic_popup_open,
                        can_undo,
                        can_redo,
                    );
                } else if let Some(pt) = state.current_pt {
                    draw_magnifier(backbuffer_dc, pt, width, height, state.virtual_origin, state.is_rgb_mode);
                }
            }
        } else {
            let _ = AlphaBlend(backbuffer_dc, 0, 0, width, height, dim_dc, 0, 0, 1, 1, blend);
            draw_top_hint(backbuffer_dc, width);

            if let Some(pt) = state.current_pt {
                draw_magnifier(backbuffer_dc, pt, width, height, state.virtual_origin, state.is_rgb_mode);
            }
        }

        let _ = SelectObject(dim_dc, old_dim_bmp);
        let _ = DeleteObject(dim_bmp);
        let _ = DeleteDC(dim_dc);

        let _ = BitBlt(hdc, 0, 0, width, height, backbuffer_dc, 0, 0, SRCCOPY);

        let _ = SelectObject(backbuffer_dc, old_backbuffer);
        let _ = DeleteObject(backbuffer_bmp);
        let _ = DeleteDC(backbuffer_dc);
    }

    pub fn select_screen_region() -> Option<ScreenshotSelection> {
        let _session_guard = match OVERLAY_SESSION.try_lock() {
            Ok(g) => g,
            Err(_) => {
                crate::log_warn!("OVERLAY", "OVERLAY_SESSION is locked, rejecting duplicate overlay");
                return None;
            }
        };
        let bounds = get_virtual_screen_bounds();
        crate::log_info!("OVERLAY", "Starting select_screen_region, bounds: {:?}", bounds);
        let class_name: Vec<u16> = "PolyglanceOverlayMask\0".encode_utf16().collect();

        unsafe {
            let mut gdiplus_token: usize = 0;
            let gdiplus_input = gdiplus::GdiplusStartupInput {
                gdiplus_version: 1,
                debug_event_callback: 0,
                suppress_background_thread: 0,
                suppress_external_codecs: 0,
            };
            let _ = gdiplus::GdiplusStartup(&mut gdiplus_token, &gdiplus_input, std::ptr::null_mut());

            let desktop = HWND::default();
            let screen_dc = GetDC(desktop);
            let mem_dc = CreateCompatibleDC(screen_dc);
            let hbitmap = CreateCompatibleBitmap(screen_dc, bounds.width, bounds.height);
            let old_bmp = SelectObject(mem_dc, hbitmap);
            let _ = BitBlt(
                mem_dc,
                0,
                0,
                bounds.width,
                bounds.height,
                screen_dc,
                bounds.x,
                bounds.y,
                SRCCOPY,
            );
            ReleaseDC(desktop, screen_dc);

            *SCREENSHOT_DC.lock().unwrap() = Some(mem_dc.0 as usize);
            *SCREENSHOT_BMP.lock().unwrap() = Some(hbitmap.0 as usize);

            let cursor = LoadCursorW(None, IDC_CROSS).unwrap_or_default();
            let wc = WNDCLASSW {
                lpfnWndProc: Some(overlay_wnd_proc),
                hCursor: cursor,
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };
            let _ = RegisterClassW(&wc);

            let mut cursor_pt = POINT::default();
            let _ = GetCursorPos(&mut cursor_pt);
            let local_pt = POINT {
                x: cursor_pt.x - bounds.x,
                y: cursor_pt.y - bounds.y,
            };
            let initial_candidate = detect_candidate_at(
                local_pt,
                bounds.width,
                bounds.height,
                HWND::default(),
                POINT { x: bounds.x, y: bounds.y },
            );

            *OVERLAY_STATE.lock().unwrap() = Some(OverlayState {
                phase: SelectionPhase::Ready,
                start_pt: None,
                current_pt: Some(local_pt),
                drag_start: None,
                initial_sel: None,
                candidate_rect: Some(initial_candidate),
                selected_rect: None,
                selected_action: None,
                selected_image: None,
                is_finished: false,
                virtual_origin: POINT {
                    x: bounds.x,
                    y: bounds.y,
                },
                screen_w: bounds.width,
                screen_h: bounds.height,
                active_tool: None,
                hovered_item: None,
                stroke_size: 4,
                selected_color_idx: 0,
                line_dash_pattern: 0,
                arrow_style: 0,
                is_line_dash_popup_open: false,
                is_arrow_popup_open: false,
                number_is_filled: true,
                mosaic_style: 0,
                is_mosaic_popup_open: false,
                is_rgb_mode: false,
                long_stitcher: None,
                long_frame_count: 0,
                long_status_text: String::new(),
                long_preview: None,
                annotations: Vec::new(),
                redo_stack: Vec::new(),
                current_drawing: None,
                is_annotating: false,
                next_badge_number: 1,
            });

            let hwnd = match CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                PCWSTR(class_name.as_ptr()),
                PCWSTR(std::ptr::null()),
                WS_POPUP | WS_VISIBLE,
                bounds.x,
                bounds.y,
                bounds.width,
                bounds.height,
                None,
                None,
                None,
                None,
            ) {
                Ok(h) => h,
                Err(err) => {
                    crate::log_error!("OVERLAY", "CreateWindowExW failed: {:?}", err);
                    let _ = SelectObject(mem_dc, old_bmp);
                    let _ = DeleteObject(hbitmap);
                    let _ = DeleteDC(mem_dc);
                    *SCREENSHOT_DC.lock().unwrap() = None;
                    *SCREENSHOT_BMP.lock().unwrap() = None;
                    if gdiplus_token != 0 {
                        gdiplus::GdiplusShutdown(gdiplus_token);
                    }
                    return None;
                }
            };

            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);
            let _ = SetFocus(hwnd);
            let _ = SetCursor(cursor);

            crate::log_info!("OVERLAY", "Overlay window created and shown, entering message loop");

            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
                if let Ok(state) = OVERLAY_STATE.lock() {
                    if let Some(s) = state.as_ref() {
                        if s.is_finished {
                            break;
                        }
                    }
                }
            }

            let _ = SelectObject(mem_dc, old_bmp);
            let _ = DeleteObject(hbitmap);
            let _ = DeleteDC(mem_dc);
            *SCREENSHOT_DC.lock().unwrap() = None;
            *SCREENSHOT_BMP.lock().unwrap() = None;

            if gdiplus_token != 0 {
                gdiplus::GdiplusShutdown(gdiplus_token);
            }

            let result = OVERLAY_STATE
                .lock()
                .unwrap()
                .take()
                .and_then(|s| {
                    if let (Some(rect), Some(action)) = (s.selected_rect, s.selected_action) {
                        Some(ScreenshotSelection { rect, action, image: s.selected_image })
                    } else {
                        None
                    }
                });

            crate::log_info!("OVERLAY", "select_screen_region message loop finished, result: {:?}", result);
            result
        }
    }

    pub fn select_screen_region_rect() -> Option<Rect> {
        select_screen_region().map(|s| s.rect)
    }

    pub fn set_click_through(hwnd: isize, enable: bool) -> bool {
        unsafe {
            let w = HWND(hwnd as *mut std::ffi::c_void);
            SetLastError(WIN32_ERROR(0));
            let ex_style = GetWindowLongPtrW(w, GWL_EXSTYLE);
            if ex_style == 0 && GetLastError().0 != 0 {
                return false;
            }
            let new_style = if enable {
                ex_style | (WS_EX_TRANSPARENT.0 as isize) | (WS_EX_LAYERED.0 as isize)
            } else {
                ex_style & !(WS_EX_TRANSPARENT.0 as isize)
            };
            SetLastError(WIN32_ERROR(0));
            let previous = SetWindowLongPtrW(w, GWL_EXSTYLE, new_style);
            if previous == 0 && GetLastError().0 != 0 {
                return false;
            }
            SetWindowPos(
                w,
                HWND_TOPMOST,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED,
            )
            .is_ok()
        }
    }
}

#[cfg(not(windows))]
pub mod windows {
    use super::*;

    pub fn get_virtual_screen_bounds() -> VirtualScreenBounds {
        VirtualScreenBounds {
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
        }
    }

    pub fn select_screen_region() -> Option<ScreenshotSelection> {
        None
    }

    pub fn select_screen_region_rect() -> Option<Rect> {
        None
    }

    pub fn set_click_through(_hwnd: isize, _enable: bool) -> bool {
        false
    }
}
