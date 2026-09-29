//! Windows global shortcuts. The Slint tray and windows stay on the UI thread;
//! this thread only receives WM_HOTKEY and forwards an action to that thread.

use std::sync::mpsc;
use std::thread::JoinHandle;
use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    MOD_ALT, MOD_NOREPEAT, RegisterHotKey, UnregisterHotKey,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetMessageW, MSG, PM_NOREMOVE, PeekMessageW, PostThreadMessageW, WM_HOTKEY, WM_QUIT,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShortcutAction {
    Screenshot,
    ScreenTranslate,
    Ocr,
    ShowTranslator,
}

impl ShortcutAction {
    fn from_id(id: usize) -> Option<Self> {
        Some(match id {
            101 => Self::Screenshot,
            102 => Self::ScreenTranslate,
            103 => Self::Ocr,
            104 => Self::ShowTranslator,
            _ => return None,
        })
    }
}

const SHORTCUTS: [(i32, u8, &str); 4] = [
    (101, b'C', "Alt+C 截图识别"),
    (102, b'S', "Alt+S 截图翻译"),
    (103, b'O', "Alt+O 文字识别"),
    (104, b'T', "Alt+T 输入翻译"),
];

pub struct Hotkeys {
    thread_id: u32,
    worker: Option<JoinHandle<()>>,
}

impl Hotkeys {
    pub fn start(
        dispatch: impl Fn(ShortcutAction) + Send + 'static,
    ) -> Result<(Self, Vec<String>), String> {
        let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
        let worker = std::thread::Builder::new()
            .name("polyglance-hotkeys".into())
            .spawn(move || {
                let thread_id = unsafe { GetCurrentThreadId() };
                let mut message = MSG::default();
                unsafe {
                    // A thread message can only be posted after USER32 creates the queue.
                    let _ = PeekMessageW(&mut message, None, 0, 0, PM_NOREMOVE);
                }
                let mut failures = Vec::new();
                let mut registered = Vec::new();
                for (id, key, label) in SHORTCUTS {
                    if unsafe { RegisterHotKey(None, id, MOD_ALT | MOD_NOREPEAT, key as u32) }
                        .is_ok()
                    {
                        registered.push(id);
                    } else {
                        failures.push(format!("{label} 已被其他程序占用"));
                    }
                }
                if ready_sender.send((thread_id, failures)).is_err() {
                    return;
                }
                unsafe {
                    loop {
                        let result = GetMessageW(&mut message, None, 0, 0);
                        if result.0 <= 0 {
                            break;
                        }
                        if message.message == WM_HOTKEY {
                            if let Some(action) = ShortcutAction::from_id(message.wParam.0) {
                                dispatch(action);
                            }
                        }
                    }
                    for id in registered {
                        let _ = UnregisterHotKey(None, id);
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        let (thread_id, failures) = ready_receiver
            .recv()
            .map_err(|error| format!("快捷键监听启动失败: {error}"))?;
        Ok((
            Self {
                thread_id,
                worker: Some(worker),
            },
            failures,
        ))
    }
}

impl Drop for Hotkeys {
    fn drop(&mut self) {
        unsafe {
            let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{SHORTCUTS, ShortcutAction};

    #[test]
    fn each_registered_shortcut_has_a_unique_action() {
        let actions: Vec<_> = SHORTCUTS
            .iter()
            .map(|(id, _, _)| ShortcutAction::from_id(*id as usize).unwrap())
            .collect();
        assert_eq!(actions.len(), 4);
        for (index, action) in actions.iter().enumerate() {
            assert!(!actions[..index].contains(action));
        }
        assert_eq!(ShortcutAction::from_id(999), None);
    }
}
