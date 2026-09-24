use std::ffi::c_char;
use crate::{ffi_status, POLYGLANCE_ERR_NULL_PTR};

#[cfg(not(windows))]
use crate::POLYGLANCE_ERR_INIT;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_store_check_updates(
    owner_hwnd: isize,
    out_update_json: *mut *mut c_char,
) -> i32 {
    ffi_status(|| {
        if out_update_json.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }

        #[cfg(windows)]
        {
            unsafe { windows_impl::check_updates(owner_hwnd, out_update_json) }
        }

        #[cfg(not(windows))]
        {
            let _ = (owner_hwnd, out_update_json);
            POLYGLANCE_ERR_INIT
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_store_install_updates(
    owner_hwnd: isize,
    out_result_json: *mut *mut c_char,
) -> i32 {
    ffi_status(|| {
        if out_result_json.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }

        #[cfg(windows)]
        {
            unsafe { windows_impl::install_updates(owner_hwnd, out_result_json) }
        }

        #[cfg(not(windows))]
        {
            let _ = (owner_hwnd, out_result_json);
            POLYGLANCE_ERR_INIT
        }
    })
}

#[cfg(windows)]
mod windows_impl {
    use std::ffi::c_char;
    use serde::Serialize;
    use windows::core::Interface;
    use windows::Services::Store::StoreContext;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::Shell::IInitializeWithWindow;
    use crate::{string_to_c_char, POLYGLANCE_ERR_INIT, POLYGLANCE_OK};

    #[derive(Serialize)]
    pub struct StoreUpdateCheckInfo {
        pub has_update: bool,
        pub version: String,
        pub title: String,
    }

    #[derive(Serialize)]
    pub struct StoreUpdateInstallInfo {
        pub success: bool,
        pub cancelled: bool,
        pub message: String,
    }

    pub unsafe fn check_updates(
        owner_hwnd: isize,
        out_update_json: *mut *mut c_char,
    ) -> i32 {
        let worker = std::thread::spawn(move || {
            run_check_updates(owner_hwnd)
        });

        match worker.join() {
            Ok(Ok(json)) => {
                unsafe { *out_update_json = string_to_c_char(json) };
                POLYGLANCE_OK
            }
            _ => POLYGLANCE_ERR_INIT,
        }
    }

    fn run_check_updates(owner_hwnd: isize) -> Result<String, String> {
        let context = get_context(owner_hwnd)
            .map_err(|e| format!("get_context failed: {e}"))?;

        let updates_op = context.GetAppAndOptionalStorePackageUpdatesAsync()
            .map_err(|e| format!("GetAppAndOptionalStorePackageUpdatesAsync failed: {e}"))?;

        let updates = updates_op.get()
            .map_err(|e| format!("updates_op get failed: {e}"))?;

        let count = updates.Size().unwrap_or(0);
        if count == 0 {
            let info = StoreUpdateCheckInfo {
                has_update: false,
                version: String::new(),
                title: String::new(),
            };
            return serde_json::to_string(&info).map_err(|e| e.to_string());
        }

        let mut version = String::new();
        let mut title = "Microsoft Store 新版本可用".to_string();

        for update in updates {
            if let Ok(pkg) = update.Package() {
                if let Ok(id) = pkg.Id() {
                    if let Ok(ver) = id.Version() {
                        version = format!("{}.{}.{}.{}", ver.Major, ver.Minor, ver.Build, ver.Revision);
                    }
                }
                if let Ok(name) = pkg.DisplayName() {
                    let s = name.to_string();
                    if !s.is_empty() {
                        title = s;
                    }
                }
                break;
            }
        }

        let info = StoreUpdateCheckInfo {
            has_update: true,
            version: if version.is_empty() { "最新版".to_string() } else { version },
            title,
        };
        serde_json::to_string(&info).map_err(|e| e.to_string())
    }

    pub unsafe fn install_updates(
        owner_hwnd: isize,
        out_result_json: *mut *mut c_char,
    ) -> i32 {
        let worker = std::thread::spawn(move || {
            run_install_updates(owner_hwnd)
        });

        match worker.join() {
            Ok(Ok(json)) => {
                unsafe { *out_result_json = string_to_c_char(json) };
                POLYGLANCE_OK
            }
            _ => POLYGLANCE_ERR_INIT,
        }
    }

    fn run_install_updates(owner_hwnd: isize) -> Result<String, String> {
        let context = get_context(owner_hwnd)
            .map_err(|e| format!("get_context failed: {e}"))?;

        let updates_op = context.GetAppAndOptionalStorePackageUpdatesAsync()
            .map_err(|e| format!("GetAppAndOptionalStorePackageUpdatesAsync failed: {e}"))?;

        let updates = updates_op.get()
            .map_err(|e| format!("updates_op get failed: {e}"))?;

        if updates.Size().unwrap_or(0) == 0 {
            let info = StoreUpdateInstallInfo {
                success: false,
                cancelled: false,
                message: "当前没有可用的 Microsoft Store 更新包。".to_string(),
            };
            return serde_json::to_string(&info).map_err(|e| e.to_string());
        }

        let download_op = context.RequestDownloadAndInstallStorePackageUpdatesAsync(&updates)
            .map_err(|e| format!("RequestDownloadAndInstallStorePackageUpdatesAsync failed: {e}"))?;

        let result = download_op.get()
            .map_err(|e| format!("download_op get failed: {e}"))?;

        use windows::Services::Store::StorePackageUpdateState;
        let state = result.OverallState().unwrap_or(StorePackageUpdateState::OtherError);
        let info = match state {
            StorePackageUpdateState::Completed => StoreUpdateInstallInfo {
                success: true,
                cancelled: false,
                message: "Microsoft Store 更新已完成。".to_string(),
            },
            StorePackageUpdateState::Canceled => StoreUpdateInstallInfo {
                success: false,
                cancelled: true,
                message: "用户取消了 Microsoft Store 安装操作。".to_string(),
            },
            _ => StoreUpdateInstallInfo {
                success: false,
                cancelled: false,
                message: format!("Microsoft Store 更新未完成 (状态: {state:?})。"),
            },
        };

        serde_json::to_string(&info).map_err(|e| e.to_string())
    }

    fn get_context(owner_hwnd: isize) -> Result<StoreContext, String> {
        let context = StoreContext::GetDefault()
            .map_err(|e| format!("StoreContext::GetDefault failed: {e}"))?;

        if owner_hwnd != 0 {
            if let Ok(init) = context.cast::<IInitializeWithWindow>() {
                unsafe {
                    let _ = init.Initialize(HWND(owner_hwnd as _));
                }
            }
        }

        Ok(context)
    }
}
