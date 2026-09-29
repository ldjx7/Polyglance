use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

static LOG_FILE: Mutex<Option<File>> = Mutex::new(None);

pub fn init() {
    let log_dir = if let Ok(appdata) = std::env::var("APPDATA") {
        PathBuf::from(appdata).join("Polyglance").join("logs")
    } else {
        PathBuf::from("logs")
    };
    let _ = std::fs::create_dir_all(&log_dir);
    let log_path = log_dir.join("polyglance.log");
    if let Ok(file) = OpenOptions::new()
        .create(true)
        .write(true)
        .append(true)
        .open(&log_path)
    {
        *LOG_FILE.lock().unwrap() = Some(file);
    }
}

pub fn log(level: &str, target: &str, message: &str) {
    let now = match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => {
            let secs = d.as_secs();
            let millis = d.subsec_millis();
            let s = secs % 86400;
            let h = (s / 3600 + 8) % 24; // UTC+8 display
            let m = (s % 3600) / 60;
            let sec = s % 60;
            format!("{:02}:{:02}:{:02}.{:03}", h, m, sec, millis)
        }
        Err(_) => "00:00:00.000".to_string(),
    };
    let line = format!("[{now}][{level}][{target}] {message}\n");
    eprint!("{line}");
    if let Ok(mut guard) = LOG_FILE.lock() {
        if let Some(file) = guard.as_mut() {
            let _ = file.write_all(line.as_bytes());
            let _ = file.flush();
        }
    }
}

#[macro_export]
macro_rules! log_info {
    ($target:expr, $($arg:tt)*) => {
        $crate::logger::log("INFO", $target, &format!($($arg)*))
    };
}

#[macro_export]
macro_rules! log_warn {
    ($target:expr, $($arg:tt)*) => {
        $crate::logger::log("WARN", $target, &format!($($arg)*))
    };
}

#[macro_export]
macro_rules! log_error {
    ($target:expr, $($arg:tt)*) => {
        $crate::logger::log("ERROR", $target, &format!($($arg)*))
    };
}

#[macro_export]
macro_rules! log_debug {
    ($target:expr, $($arg:tt)*) => {
        $crate::logger::log("DEBUG", $target, &format!($($arg)*))
    };
}
