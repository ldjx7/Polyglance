//! Read a selection from the previously active Windows application.
//! The clipboard is restored through OLE so rich clipboard formats survive Ctrl+C.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{
    COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize, IDataObject,
};
use windows::Win32::System::DataExchange::GetClipboardSequenceNumber;
use windows::Win32::System::Ole::{OleGetClipboard, OleSetClipboard};
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, SendInput,
    VK_CONTROL, VK_MENU, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetClassNameW, GetForegroundWindow, GetWindowThreadProcessId, IsWindow, SetForegroundWindow,
};

fn normalize(text: String) -> Option<String> {
    let text = text.trim().to_owned();
    (!text.is_empty()).then_some(text)
}

fn should_restore(after_copy: u32, current: u32) -> bool {
    after_copy == current
}

pub fn start_foreground_tracker() -> (Arc<AtomicIsize>, Arc<AtomicBool>, JoinHandle<()>) {
    let target = Arc::new(AtomicIsize::new(0));
    let running = Arc::new(AtomicBool::new(true));
    let target_worker = target.clone();
    let running_worker = running.clone();
    let worker = std::thread::spawn(move || {
        while running_worker.load(Ordering::Acquire) {
            unsafe {
                let hwnd = GetForegroundWindow();
                if !hwnd.is_invalid() {
                    let mut pid = 0;
                    GetWindowThreadProcessId(hwnd, Some(&mut pid));
                    let mut class_name = [0u16; 80];
                    let class_len = GetClassNameW(hwnd, &mut class_name).max(0) as usize;
                    let class_name = String::from_utf16_lossy(&class_name[..class_len]);
                    if pid != GetCurrentProcessId()
                        && !matches!(
                            class_name.as_str(),
                            "Shell_TrayWnd" | "Shell_SecondaryTrayWnd" | "NotifyIconOverflowWindow"
                        )
                    {
                        target_worker.store(hwnd.0 as isize, Ordering::Release);
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    (target, running, worker)
}

fn key_input(key: u16, release: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY(key),
                dwFlags: if release {
                    KEYEVENTF_KEYUP
                } else {
                    Default::default()
                },
                ..Default::default()
            },
        },
    }
}

struct ComGuard;
impl Drop for ComGuard {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}

pub fn read_selected_text(target: isize) -> Result<String, String> {
    unsafe {
        let hwnd = HWND(target as *mut std::ffi::c_void);
        if target == 0 || !IsWindow(hwnd).as_bool() {
            return Err("未找到刚才使用的窗口，请先在其他程序中选中文字".into());
        }
        CoInitializeEx(None, COINIT_APARTMENTTHREADED)
            .ok()
            .map_err(|error| format!("无法初始化剪贴板访问: {error}"))?;
        let _com = ComGuard;
        if !SetForegroundWindow(hwnd).as_bool() {
            return Err("无法切回选中文字的窗口".into());
        }
        std::thread::sleep(Duration::from_millis(120));
        for _ in 0..25 {
            if [VK_SHIFT.0, VK_CONTROL.0, VK_MENU.0]
                .iter()
                .all(|key| GetAsyncKeyState(*key as i32) & i16::MIN == 0)
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if [VK_SHIFT.0, VK_CONTROL.0, VK_MENU.0]
            .iter()
            .any(|key| GetAsyncKeyState(*key as i32) & i16::MIN != 0)
        {
            return Err("请松开快捷键后重试划词翻译".into());
        }
        let saved: IDataObject = OleGetClipboard()
            .map_err(|error| format!("无法备份剪贴板，已取消划词翻译: {error}"))?;
        OleSetClipboard(None::<&IDataObject>)
            .map_err(|error| format!("无法准备剪贴板: {error}"))?;
        let cleared = GetClipboardSequenceNumber();
        let inputs = [
            key_input(VK_CONTROL.0, false),
            key_input(b'C' as u16, false),
            key_input(b'C' as u16, true),
            key_input(VK_CONTROL.0, true),
        ];
        if SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) != inputs.len() as u32 {
            let _ = OleSetClipboard(&saved);
            return Err("无法向目标程序发送复制快捷键".into());
        }
        let mut changed = false;
        for _ in 0..25 {
            if GetClipboardSequenceNumber() != cleared {
                changed = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let after_copy = GetClipboardSequenceNumber();
        let text = if changed {
            arboard::Clipboard::new()
                .ok()
                .and_then(|mut cb| cb.get_text().ok())
                .and_then(normalize)
        } else {
            None
        };
        if should_restore(after_copy, GetClipboardSequenceNumber()) {
            let _ = OleSetClipboard(&saved);
        }
        text.ok_or_else(|| "未读取到选中的文字".into())
    }
}

#[cfg(test)]
mod tests {
    use super::{normalize, should_restore};

    #[test]
    fn selection_requires_nonempty_text() {
        assert_eq!(normalize(" 你好 \r\n".into()), Some("你好".into()));
        assert_eq!(normalize(" \n\t".into()), None);
    }

    #[test]
    fn a_newer_clipboard_change_must_not_be_overwritten() {
        assert!(should_restore(11, 11));
        assert!(!should_restore(11, 12));
    }
}
