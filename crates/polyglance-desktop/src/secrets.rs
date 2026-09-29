//! Windows credential persistence. The JSON settings file never contains API keys.

#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct ApiSecrets {
    pub openai_key: String,
    pub deepl_key: String,
}

#[cfg(windows)]
mod windows_store {
    use super::ApiSecrets;
    use std::fs;
    use std::path::PathBuf;
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
    };
    use windows::core::PCWSTR;

    const RUST_ENTROPY: &[u8] = b"Polyglance.Rust.v1";
    const LEGACY_ENTROPY: &[u8] = b"Polyglance.CustomAI.v1";

    fn root() -> Result<PathBuf, String> {
        std::env::var_os("LOCALAPPDATA")
            .map(|path| PathBuf::from(path).join("Polyglance"))
            .ok_or_else(|| "LOCALAPPDATA is unavailable".to_string())
    }

    fn crypt(input: &[u8], entropy: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
        let mut input = input.to_vec();
        let mut entropy = entropy.to_vec();
        let input_blob = CRYPT_INTEGER_BLOB {
            cbData: input.len() as u32,
            pbData: input.as_mut_ptr(),
        };
        let entropy_blob = CRYPT_INTEGER_BLOB {
            cbData: entropy.len() as u32,
            pbData: entropy.as_mut_ptr(),
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        let result = unsafe {
            if encrypt {
                CryptProtectData(
                    &input_blob,
                    PCWSTR::null(),
                    Some(&entropy_blob),
                    None,
                    None,
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            } else {
                CryptUnprotectData(
                    &input_blob,
                    None,
                    Some(&entropy_blob),
                    None,
                    None,
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            }
        };
        result.map_err(|error| error.to_string())?;
        let bytes =
            unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
        unsafe {
            let _ = LocalFree(HLOCAL(output.pbData.cast()));
        }
        Ok(bytes)
    }

    pub fn load() -> Result<ApiSecrets, String> {
        let own_path = root()?.join("rust-credentials.dat");
        if own_path.exists() {
            let encrypted = fs::read(own_path).map_err(|error| error.to_string())?;
            let plain = crypt(&encrypted, RUST_ENTROPY, false)?;
            return serde_json::from_slice(&plain).map_err(|error| error.to_string());
        }
        let legacy_path = root()?.join("credentials.dat");
        if legacy_path.exists() {
            let encrypted = fs::read(legacy_path).map_err(|error| error.to_string())?;
            let plain = crypt(&encrypted, LEGACY_ENTROPY, false)?;
            return Ok(ApiSecrets {
                openai_key: String::from_utf8(plain).map_err(|error| error.to_string())?,
                deepl_key: String::new(),
            });
        }
        Ok(ApiSecrets::default())
    }

    pub fn save(secrets: &ApiSecrets) -> Result<(), String> {
        let root = root()?;
        fs::create_dir_all(&root).map_err(|error| error.to_string())?;
        let plain = serde_json::to_vec(secrets).map_err(|error| error.to_string())?;
        let encrypted = crypt(&plain, RUST_ENTROPY, true)?;
        let path = root.join("rust-credentials.dat");
        let temporary = root.join(format!("rust-credentials.{}.tmp", std::process::id()));
        fs::write(&temporary, encrypted).map_err(|error| error.to_string())?;
        if let Err(error) = fs::rename(&temporary, &path) {
            let _ = fs::remove_file(&temporary);
            return Err(error.to_string());
        }
        Ok(())
    }
}

#[cfg(windows)]
pub use windows_store::{load, save};

#[cfg(not(windows))]
pub fn load() -> Result<ApiSecrets, String> {
    Ok(ApiSecrets::default())
}

#[cfg(not(windows))]
pub fn save(secrets: &ApiSecrets) -> Result<(), String> {
    if secrets.openai_key.is_empty() && secrets.deepl_key.is_empty() {
        Ok(())
    } else {
        Err("当前平台尚未配置系统凭据存储，API Key 仅在本次运行中可用".into())
    }
}
