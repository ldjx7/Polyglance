//! Safe, virtual-desktop aware Windows screen capture for Rust callers.

#[cfg(windows)]
pub struct CapturedFrame {
    pub width: u32,
    pub height: u32,
    /// Top-down BGRA pixels, tightly packed.
    pub bgra: Vec<u8>,
}

/// Captures a rectangle in physical virtual-screen coordinates. Unlike a
/// single-monitor WinRT capture session, this supports negative origins and
/// selections crossing display boundaries.
#[cfg(windows)]
pub fn capture_screen_region(
    x: i32,
    y: i32,
    width: u32,
    height: u32,
) -> Result<CapturedFrame, String> {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::{
        BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC,
        DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetDIBits, HGDIOBJ, ReleaseDC, SRCCOPY,
        SelectObject,
    };

    if width == 0 || height == 0 || width > i32::MAX as u32 || height > i32::MAX as u32 {
        return Err("invalid capture dimensions".into());
    }
    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .filter(|count| *count <= 100_000_000)
        .ok_or_else(|| "capture exceeds the 100-megapixel limit".to_string())?;
    let byte_count = pixel_count
        .checked_mul(4)
        .ok_or("capture buffer overflow")?;
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(byte_count)
        .map_err(|_| "unable to allocate capture buffer")?;
    pixels.resize(byte_count, 0);

    unsafe {
        let desktop = HWND::default();
        let screen_dc = GetDC(desktop);
        if screen_dc.0.is_null() {
            return Err("GetDC failed".into());
        }
        let memory_dc = CreateCompatibleDC(screen_dc);
        if memory_dc.0.is_null() {
            ReleaseDC(desktop, screen_dc);
            return Err("CreateCompatibleDC failed".into());
        }
        let bitmap = CreateCompatibleBitmap(screen_dc, width as i32, height as i32);
        if bitmap.0.is_null() {
            let _ = DeleteDC(memory_dc);
            ReleaseDC(desktop, screen_dc);
            return Err("CreateCompatibleBitmap failed".into());
        }
        let old_bitmap = SelectObject(memory_dc, HGDIOBJ(bitmap.0));
        let copy_result = BitBlt(
            memory_dc,
            0,
            0,
            width as i32,
            height as i32,
            screen_dc,
            x,
            y,
            SRCCOPY,
        );
        SelectObject(memory_dc, old_bitmap);

        let mut info = BITMAPINFO::default();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width as i32,
            biHeight: -(height as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let rows = if copy_result.is_ok() {
            GetDIBits(
                screen_dc,
                bitmap,
                0,
                height,
                Some(pixels.as_mut_ptr().cast()),
                &mut info,
                DIB_RGB_COLORS,
            )
        } else {
            0
        };
        let _ = DeleteObject(bitmap);
        let _ = DeleteDC(memory_dc);
        ReleaseDC(desktop, screen_dc);
        if rows != height as i32 {
            return Err("screen capture failed or returned incomplete pixels".into());
        }
    }
    Ok(CapturedFrame {
        width,
        height,
        bgra: pixels,
    })
}
