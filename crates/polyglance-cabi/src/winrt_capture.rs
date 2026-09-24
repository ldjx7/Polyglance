#[cfg(windows)]
use crate::POLYGLANCE_OK;
use crate::{
    POLYGLANCE_ERR_INIT, POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, ffi_status,
    ffi_void,
};
use std::ffi::c_void;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_capture_new(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    cursor: bool,
    out_handle: *mut *mut c_void,
) -> i32 {
    ffi_status(|| {
        if out_handle.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }
        unsafe {
            *out_handle = std::ptr::null_mut();
        }
        if width <= 0 || height <= 0 {
            return POLYGLANCE_ERR_INVALID_INPUT;
        }

        #[cfg(windows)]
        {
            match windows_impl::CaptureSession::new(x, y, width, height, cursor) {
                Ok(session) => {
                    unsafe {
                        *out_handle = Box::into_raw(Box::new(session)).cast();
                    }
                    POLYGLANCE_OK
                }
                Err(_) => POLYGLANCE_ERR_INIT,
            }
        }
        #[cfg(not(windows))]
        {
            let _ = (x, y, width, height, cursor);
            POLYGLANCE_ERR_INIT
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_capture_frame(
    handle: *mut c_void,
    buffer: *mut u8,
    buffer_len: usize,
    cursor: bool,
    out_captured: *mut bool,
) -> i32 {
    ffi_status(|| {
        if handle.is_null() || buffer.is_null() || out_captured.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }
        unsafe {
            *out_captured = false;
        }

        #[cfg(windows)]
        {
            let session = unsafe { &mut *handle.cast::<windows_impl::CaptureSession>() };
            match session.capture_frame(buffer, buffer_len, cursor) {
                Ok(captured) => {
                    unsafe {
                        *out_captured = captured;
                    }
                    POLYGLANCE_OK
                }
                Err(_) => POLYGLANCE_ERR_INIT,
            }
        }
        #[cfg(not(windows))]
        {
            let _ = (buffer_len, cursor);
            POLYGLANCE_ERR_INIT
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_capture_free(handle: *mut c_void) {
    ffi_void(|| {
        if handle.is_null() {
            return;
        }
        #[cfg(windows)]
        {
            unsafe {
                drop(Box::from_raw(handle.cast::<windows_impl::CaptureSession>()));
            }
        }
    });
}

#[cfg(windows)]
mod windows_impl {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};
    use windows::Foundation::TypedEventHandler;
    use windows::Graphics::Capture::{
        Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession,
    };
    use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
    use windows::Graphics::DirectX::DirectXPixelFormat;
    use windows::Win32::Foundation::RECT;
    use windows::Win32::Graphics::Direct3D::{
        D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP, D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
    };
    use windows::Win32::Graphics::Direct3D11::{
        D3D11_BOX, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAP_READ,
        D3D11_MAPPED_SUBRESOURCE, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING, D3D11CreateDevice,
        ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
    };
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
    use windows::Win32::Graphics::Dxgi::IDXGIDevice;
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromRect,
    };
    use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize};
    use windows::Win32::System::WinRT::Direct3D11::{
        CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess,
    };
    use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
    use windows::core::{Interface, Result};

    pub struct CaptureSession {
        context: ID3D11DeviceContext,
        staging_texture: ID3D11Texture2D,
        frame_pool: Direct3D11CaptureFramePool,
        session: GraphicsCaptureSession,
        crop_box: D3D11_BOX,
        width: u32,
        height: u32,
        arrived_flag: Arc<AtomicBool>,
        has_captured_any: bool,
    }

    impl CaptureSession {
        pub fn new(x: i32, y: i32, width: i32, height: i32, cursor: bool) -> Result<Self> {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }

            // 确定目标屏幕及在其坐标系下的相对位置
            let target_rect = RECT {
                left: x,
                top: y,
                right: x + width,
                bottom: y + height,
            };
            let hmonitor = unsafe { MonitorFromRect(&target_rect, MONITOR_DEFAULTTONEAREST) };
            let mut mi = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            unsafe {
                GetMonitorInfoW(hmonitor, &mut mi).ok()?;
            }

            let mon_x = mi.rcMonitor.left;
            let mon_y = mi.rcMonitor.top;
            let mon_w = (mi.rcMonitor.right - mi.rcMonitor.left).max(1) as u32;
            let mon_h = (mi.rcMonitor.bottom - mi.rcMonitor.top).max(1) as u32;

            let rel_x = (x - mon_x).clamp(0, mon_w as i32) as u32;
            let rel_y = (y - mon_y).clamp(0, mon_h as i32) as u32;
            let crop_w = (width as u32).min(mon_w.saturating_sub(rel_x));
            let crop_h = (height as u32).min(mon_h.saturating_sub(rel_y));

            let crop_box = D3D11_BOX {
                left: rel_x,
                top: rel_y,
                front: 0,
                right: rel_x + crop_w,
                bottom: rel_y + crop_h,
                back: 1,
            };

            // 创建 Direct3D 11 设备 (优先硬件，回退 WARP)
            let mut d3d_device: Option<ID3D11Device> = None;
            let mut d3d_context: Option<ID3D11DeviceContext> = None;
            let feature_levels = [
                D3D_FEATURE_LEVEL_11_1,
                D3D_FEATURE_LEVEL_11_0,
                D3D_FEATURE_LEVEL_10_1,
                D3D_FEATURE_LEVEL_10_0,
            ];

            let device_created = unsafe {
                D3D11CreateDevice(
                    None,
                    D3D_DRIVER_TYPE_HARDWARE,
                    None,
                    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    Some(&feature_levels),
                    windows::Win32::Graphics::Direct3D11::D3D11_SDK_VERSION,
                    Some(&mut d3d_device),
                    None,
                    Some(&mut d3d_context),
                )
            };

            if device_created.is_err() {
                unsafe {
                    D3D11CreateDevice(
                        None,
                        D3D_DRIVER_TYPE_WARP,
                        None,
                        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                        Some(&feature_levels),
                        windows::Win32::Graphics::Direct3D11::D3D11_SDK_VERSION,
                        Some(&mut d3d_device),
                        None,
                        Some(&mut d3d_context),
                    )?;
                }
            }

            let device = d3d_device.unwrap();
            let context = d3d_context.unwrap();

            // 创建 WinRT IDirect3DDevice
            let dxgi_device: IDXGIDevice = device.cast()?;
            let inspectable = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi_device)? };
            let winrt_device: IDirect3DDevice = inspectable.cast()?;

            // 获取目标显示器的 GraphicsCaptureItem
            let interop: IGraphicsCaptureItemInterop =
                windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
            let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(hmonitor)? };
            let item_size = item.Size()?;

            // 创建用于 GPU 回读的 Staging 纹理
            let staging_desc = D3D11_TEXTURE2D_DESC {
                Width: width as u32,
                Height: height as u32,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC {
                    Count: 1,
                    Quality: 0,
                },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };

            let mut staging_opt = None;
            unsafe {
                device.CreateTexture2D(&staging_desc, None, Some(&mut staging_opt))?;
            }
            let staging_texture = staging_opt.unwrap();

            // 创建 FreeThreaded FramePool 并配置 Session
            let frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                &winrt_device,
                DirectXPixelFormat::B8G8R8A8UIntNormalized,
                2,
                item_size,
            )?;

            let arrived_flag = Arc::new(AtomicBool::new(false));
            let flag_clone = arrived_flag.clone();
            let _ = frame_pool.FrameArrived(&TypedEventHandler::new(move |_, _| {
                flag_clone.store(true, Ordering::Release);
                Ok(())
            }));

            let session = frame_pool.CreateCaptureSession(&item)?;
            let _ = session.SetIsBorderRequired(false);
            let _ = session.SetIsCursorCaptureEnabled(cursor);
            session.StartCapture()?;

            Ok(Self {
                context,
                staging_texture,
                frame_pool,
                session,
                crop_box,
                width: width as u32,
                height: height as u32,
                arrived_flag,
                has_captured_any: false,
            })
        }

        pub fn capture_frame(
            &mut self,
            buffer: *mut u8,
            buffer_len: usize,
            _cursor: bool,
        ) -> Result<bool> {
            let row_bytes = (self.width * 4) as usize;
            let expected_len = row_bytes * self.height as usize;
            if buffer_len < expected_len {
                return Err(windows::core::Error::from_hresult(
                    windows::Win32::Foundation::E_INVALIDARG,
                ));
            }

            // 首次捕获允许短暂等待首帧到达（最多 300ms）
            if !self.has_captured_any {
                let start = Instant::now();
                while !self.arrived_flag.load(Ordering::Acquire)
                    && start.elapsed() < Duration::from_millis(300)
                {
                    std::thread::sleep(Duration::from_millis(5));
                }
            }

            // 尝试获取新帧
            let frame = match self.frame_pool.TryGetNextFrame() {
                Ok(f) => f,
                Err(_) => {
                    // 无新帧，复用现有缓冲
                    return Ok(false);
                }
            };
            self.arrived_flag.store(false, Ordering::Release);

            let surface = frame.Surface()?;
            let access: IDirect3DDxgiInterfaceAccess = surface.cast()?;
            let texture: ID3D11Texture2D = unsafe { access.GetInterface()? };

            unsafe {
                self.context.CopySubresourceRegion(
                    &self.staging_texture,
                    0,
                    0,
                    0,
                    0,
                    &texture,
                    0,
                    Some(&self.crop_box),
                );

                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                self.context.Map(
                    &self.staging_texture,
                    0,
                    D3D11_MAP_READ,
                    0,
                    Some(&mut mapped),
                )?;

                let src_ptr = mapped.pData as *const u8;
                for row in 0..self.height as usize {
                    std::ptr::copy_nonoverlapping(
                        src_ptr.add(row * mapped.RowPitch as usize),
                        buffer.add(row * row_bytes),
                        row_bytes,
                    );
                }

                self.context.Unmap(&self.staging_texture, 0);
            }

            self.has_captured_any = true;
            Ok(true)
        }
    }

    impl Drop for CaptureSession {
        fn drop(&mut self) {
            let _ = self.session.Close();
            let _ = self.frame_pool.Close();
            unsafe {
                CoUninitialize();
            }
        }
    }
}
