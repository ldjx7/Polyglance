//! A second launch activates the existing resident process instead of adding
//! another tray icon or competing for the same global shortcuts.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use windows::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, WAIT_OBJECT_0,
};
use windows::Win32::System::Threading::{CreateEventW, INFINITE, SetEvent, WaitForSingleObject};
use windows::core::PCWSTR;

pub struct ActivationEvent {
    handle: HANDLE,
    stopping: Arc<AtomicBool>,
    listener: Option<JoinHandle<()>>,
}

impl ActivationEvent {
    pub fn acquire() -> Result<Option<Self>, String> {
        let name: Vec<u16> = "Local\\PolyglanceRustPreviewActivate"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let handle = unsafe { CreateEventW(None, false, false, PCWSTR(name.as_ptr())) }
            .map_err(|error| error.to_string())?;
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            unsafe {
                let _ = SetEvent(handle);
                let _ = CloseHandle(handle);
            }
            return Ok(None);
        }
        Ok(Some(Self {
            handle,
            stopping: Arc::new(AtomicBool::new(false)),
            listener: None,
        }))
    }

    pub fn listen(&mut self, activate: impl Fn() + Send + 'static) -> Result<(), String> {
        let raw_handle = self.handle.0 as isize;
        let stopping = self.stopping.clone();
        self.listener = Some(
            std::thread::Builder::new()
                .name("polyglance-activation".into())
                .spawn(move || {
                    let handle = HANDLE(raw_handle as *mut std::ffi::c_void);
                    loop {
                        if unsafe { WaitForSingleObject(handle, INFINITE) } != WAIT_OBJECT_0 {
                            break;
                        }
                        if stopping.load(Ordering::Acquire) {
                            break;
                        }
                        activate();
                    }
                })
                .map_err(|error| error.to_string())?,
        );
        Ok(())
    }
}

impl Drop for ActivationEvent {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        unsafe {
            let _ = SetEvent(self.handle);
        }
        if let Some(listener) = self.listener.take() {
            let _ = listener.join();
        }
        unsafe {
            let _ = CloseHandle(self.handle);
        }
    }
}
