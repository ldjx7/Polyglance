//! Current-user startup registration for the Rust preview track.
//! A separate registry value leaves the WPF client's startup preference alone.

use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SZ, RegCloseKey, RegDeleteValueW,
    RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
};
use windows::core::{PCWSTR, w};

const VALUE_NAME: PCWSTR = w!("PolyglanceRustPreview");
const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

fn expected_command(path: &std::path::Path) -> String {
    format!("\"{}\" --autostart", path.display())
}

fn open_run_key() -> Result<HKEY, String> {
    let mut key = HKEY::default();
    let result = unsafe {
        RegOpenKeyExW(
            HKEY_CURRENT_USER,
            RUN_KEY,
            0,
            KEY_QUERY_VALUE | KEY_SET_VALUE,
            &mut key,
        )
    };
    if result == ERROR_SUCCESS {
        Ok(key)
    } else {
        Err(format!("无法打开开机启动注册表项: {result:?}"))
    }
}

pub fn is_enabled() -> Result<bool, String> {
    let key = open_run_key()?;
    let mut size = 0u32;
    let result = unsafe { RegQueryValueExW(key, VALUE_NAME, None, None, None, Some(&mut size)) };
    if result == ERROR_FILE_NOT_FOUND {
        unsafe {
            let _ = RegCloseKey(key);
        }
        return Ok(false);
    }
    if result != ERROR_SUCCESS {
        unsafe {
            let _ = RegCloseKey(key);
        }
        return Err(format!("无法读取开机启动配置: {result:?}"));
    }
    let mut bytes = vec![0u8; size as usize];
    let result = unsafe {
        RegQueryValueExW(
            key,
            VALUE_NAME,
            None,
            None,
            Some(bytes.as_mut_ptr()),
            Some(&mut size),
        )
    };
    unsafe {
        let _ = RegCloseKey(key);
    }
    if result != ERROR_SUCCESS {
        return Err(format!("无法读取开机启动命令: {result:?}"));
    }
    let utf16: Vec<u16> = bytes[..size as usize]
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .take_while(|unit| *unit != 0)
        .collect();
    let stored = String::from_utf16_lossy(&utf16);
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    Ok(stored.eq_ignore_ascii_case(&expected_command(&executable)))
}

pub fn set_enabled(enabled: bool) -> Result<(), String> {
    let key = open_run_key()?;
    let result = if enabled {
        let executable = std::env::current_exe().map_err(|error| error.to_string())?;
        let command: Vec<u16> = expected_command(&executable)
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let bytes =
            unsafe { std::slice::from_raw_parts(command.as_ptr() as *const u8, command.len() * 2) };
        unsafe { RegSetValueExW(key, VALUE_NAME, 0, REG_SZ, Some(bytes)) }
    } else {
        unsafe { RegDeleteValueW(key, VALUE_NAME) }
    };
    unsafe {
        let _ = RegCloseKey(key);
    }
    if result == ERROR_SUCCESS || (!enabled && result == ERROR_FILE_NOT_FOUND) {
        Ok(())
    } else {
        Err(format!("无法更新开机启动配置: {result:?}"))
    }
}

#[cfg(test)]
mod tests {
    use super::expected_command;

    #[test]
    fn startup_path_is_quoted_and_stays_on_preview_track() {
        let path = std::path::Path::new(r"C:\Program Files\Polyglance Rust\polyglance-desktop.exe");
        assert_eq!(
            expected_command(path),
            r#""C:\Program Files\Polyglance Rust\polyglance-desktop.exe" --autostart"#
        );
    }
}
