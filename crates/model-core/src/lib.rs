//! User-installed ONNX models shared by the Windows and Linux Rust clients.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

#[cfg(any(windows, target_os = "linux"))]
pub mod ocr;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstalledModel {
    pub name: String,
    pub file: PathBuf,
    pub size_bytes: u64,
    pub sha256: String,
}

pub fn default_model_directory() -> PathBuf {
    if let Some(path) = std::env::var_os("POLYGLANCE_MODEL_DIRECTORY") {
        return PathBuf::from(path);
    }
    #[cfg(windows)]
    if let Some(appdata) = std::env::var_os("APPDATA") {
        return PathBuf::from(appdata).join("Polyglance").join("models");
    }
    #[cfg(target_os = "linux")]
    if let Some(data_home) = std::env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(data_home).join("polyglance").join("models");
    }
    #[cfg(target_os = "linux")]
    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home).join(".local/share/polyglance/models");
    }
    PathBuf::from("models")
}

pub fn destination_directory_for(source: &Path) -> PathBuf {
    let root = default_model_directory();
    match source.file_name().and_then(|name| name.to_str()) {
        Some(
            "det.onnx"
            | "rec.onnx"
            | "keys.txt"
            | "ch_PP-OCRv4_det_infer.onnx"
            | "ch_PP-OCRv4_rec_infer.onnx"
            | "ppocr_keys_v1.txt",
        ) => root.join("ocr"),
        _ => root,
    }
}

pub fn list_model_files(directory: &Path) -> io::Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for folder in [directory.to_path_buf(), directory.join("ocr")] {
        let entries = match fs::read_dir(folder) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        for entry in entries {
            let path = entry?.path();
            if path.is_file() && path.extension().and_then(|ext| ext.to_str()) == Some("onnx") {
                files.push(path);
            }
        }
    }
    files.sort();
    Ok(files)
}

pub fn runtime_filename() -> &'static str {
    #[cfg(windows)]
    {
        return "onnxruntime.dll";
    }
    #[cfg(target_os = "linux")]
    {
        return "libonnxruntime.so";
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        "onnxruntime.unavailable"
    }
}

pub fn default_runtime_path() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("POLYGLANCE_ONNXRUNTIME_PATH") {
        return Ok(PathBuf::from(path));
    }
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    Ok(executable
        .parent()
        .ok_or("executable directory unavailable")?
        .join(runtime_filename()))
}

pub fn inspect_model(path: &Path, runtime_path: &Path) -> Result<Vec<String>, String> {
    if !path.is_file() {
        return Err(format!("model file does not exist: {}", path.display()));
    }
    if !runtime_path.is_file() {
        return Err(format!(
            "ONNX Runtime library does not exist: {}",
            runtime_path.display()
        ));
    }
    #[cfg(any(windows, target_os = "linux"))]
    {
        initialize_runtime(runtime_path)?;
        let session = ort::session::Session::builder()
            .map_err(|error| error.to_string())?
            .commit_from_file(path)
            .map_err(|error| error.to_string())?;
        return Ok(session
            .inputs()
            .iter()
            .map(|input| input.name().to_string())
            .collect());
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    Err("ONNX Runtime is supported by the Windows and Linux Rust clients".into())
}

#[cfg(any(windows, target_os = "linux"))]
pub(crate) fn initialize_runtime(path: &Path) -> Result<(), String> {
    use std::sync::Mutex;
    static INITIALIZED: Mutex<Option<PathBuf>> = Mutex::new(None);
    let canonical = path.canonicalize().map_err(|error| error.to_string())?;
    let mut state = INITIALIZED.lock().map_err(|error| error.to_string())?;
    if let Some(existing) = state.as_ref() {
        if existing != &canonical {
            return Err("ONNX Runtime was already initialized from another library".into());
        }
        return Ok(());
    }
    if !ort::init_from(&canonical)
        .map_err(|error| error.to_string())?
        .commit()
    {
        return Err("ONNX Runtime was initialized before the requested library".into());
    }
    *state = Some(canonical);
    Ok(())
}

/// Copies a user-selected model into the shared data directory and records a checksum.
/// Existing files are never overwritten.
pub fn install_model(source: &Path, directory: &Path) -> Result<InstalledModel, String> {
    if !source.is_file() {
        return Err("model file does not exist".into());
    }
    let allowed = matches!(
        source.extension().and_then(|part| part.to_str()),
        Some("onnx")
    ) || matches!(
        source.file_name().and_then(|part| part.to_str()),
        Some("keys.txt" | "ppocr_keys_v1.txt")
    );
    if !allowed {
        return Err("only .onnx models and PP-OCR key files are accepted".into());
    }
    let name = source
        .file_name()
        .and_then(|part| part.to_str())
        .ok_or("model filename is not valid UTF-8")?
        .to_string();
    fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let destination = directory.join(&name);
    let mut input = File::open(source).map_err(|error| error.to_string())?;
    let mut output = File::options()
        .write(true)
        .create_new(true)
        .open(&destination)
        .map_err(|error| error.to_string())?;
    let result = (|| -> io::Result<(u64, String)> {
        let mut hash = Sha256::new();
        let mut size = 0u64;
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let read = input.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            output.write_all(&buffer[..read])?;
            hash.update(&buffer[..read]);
            size += read as u64;
        }
        output.sync_all()?;
        Ok((size, format!("{:x}", hash.finalize())))
    })();
    match result {
        Ok((size_bytes, sha256)) if size_bytes > 0 => Ok(InstalledModel {
            name,
            file: destination,
            size_bytes,
            sha256,
        }),
        Ok(_) => {
            let _ = fs::remove_file(&destination);
            Err("empty model file".into())
        }
        Err(error) => {
            let _ = fs::remove_file(&destination);
            Err(error.to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_model_copies_and_hashes_without_overwrite() {
        let root =
            std::env::temp_dir().join(format!("polyglance-model-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let input = root.join("test.onnx");
        let output = root.join("installed");
        fs::write(&input, b"sample model bytes").unwrap();
        let installed = install_model(&input, &output).unwrap();
        assert_eq!(installed.size_bytes, 18);
        assert_eq!(fs::read(&installed.file).unwrap(), b"sample model bytes");
        assert!(install_model(&input, &output).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn ocr_dictionary_is_accepted_but_arbitrary_text_is_rejected() {
        let root =
            std::env::temp_dir().join(format!("polyglance-model-keys-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let keys = root.join("ppocr_keys_v1.txt");
        fs::write(&keys, "你\n好\n").unwrap();
        assert!(install_model(&keys, &root.join("installed")).is_ok());
        let unrelated = root.join("notes.txt");
        fs::write(&unrelated, "text").unwrap();
        assert!(install_model(&unrelated, &root.join("installed")).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
