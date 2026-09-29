//! Persistent translation history storage compatible with existing Polyglance clients.

use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranslationRecord {
    pub id: String,
    pub timestamp: String,
    pub source_text: String,
    pub target_text: String,
    pub source_lang: String,
    pub target_lang: String,
    pub provider: String,
    pub is_favorite: bool,
}

impl TranslationRecord {
    pub fn new(
        source_text: impl Into<String>,
        target_text: impl Into<String>,
        source_lang: impl Into<String>,
        target_lang: impl Into<String>,
        provider: impl Into<String>,
    ) -> Self {
        let id = Uuid::new_v4().to_string();
        let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);

        Self {
            id,
            timestamp,
            source_text: source_text.into(),
            target_text: target_text.into(),
            source_lang: source_lang.into(),
            target_lang: target_lang.into(),
            provider: provider.into(),
            is_favorite: false,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TranslationHistory {
    records: Vec<TranslationRecord>,
}

impl TranslationHistory {
    pub fn new() -> Self {
        Self {
            records: Vec::new(),
        }
    }

    pub fn load_from_file(path: &Path) -> Self {
        Self::try_load_from_file(path).unwrap_or_default()
    }

    pub fn try_load_from_file(path: &Path) -> io::Result<Self> {
        let content = match fs::read_to_string(path) {
            Ok(content) => content,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Self::new()),
            Err(error) => return Err(error),
        };
        let records = serde_json::from_str::<Vec<TranslationRecord>>(&content)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        Ok(Self { records })
    }

    pub fn save_to_file(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_vec_pretty(&self.records)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let temporary = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?;
            file.write_all(&json)?;
            file.sync_all()?;
            fs::rename(&temporary, path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    pub fn records(&self) -> &[TranslationRecord] {
        &self.records
    }

    pub fn add_record(&mut self, record: TranslationRecord) {
        if record.source_text.trim().is_empty() || record.target_text.trim().is_empty() {
            return;
        }
        if self.records.first().is_some_and(|previous| {
            previous.source_text.trim() == record.source_text.trim()
                && previous.target_text.trim() == record.target_text.trim()
        }) {
            return;
        }
        self.records.insert(0, record);
        if self.records.len() > 100 {
            self.records.truncate(100);
        }
    }

    pub fn toggle_favorite(&mut self, id: &str) -> bool {
        if let Some(record) = self.records.iter_mut().find(|r| r.id == id) {
            record.is_favorite = !record.is_favorite;
            true
        } else {
            false
        }
    }

    pub fn delete_record(&mut self, id: &str) -> bool {
        if let Some(index) = self.records.iter().position(|r| r.id == id) {
            self.records.remove(index);
            true
        } else {
            false
        }
    }

    pub fn clear(&mut self) {
        self.records.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_serialization_round_trip() {
        let record = TranslationRecord::new("Hello", "你好", "en", "zh-CN", "free-ai");
        let json = serde_json::to_string(&record).unwrap();
        let deserialized: TranslationRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(record.source_text, deserialized.source_text);
        assert_eq!(record.target_text, deserialized.target_text);
        assert_eq!(record.provider, deserialized.provider);
        assert!(!deserialized.is_favorite);
    }

    #[test]
    fn history_crud_operations() {
        let mut history = TranslationHistory::new();
        let r1 = TranslationRecord::new("One", "一", "en", "zh-CN", "google");
        let id1 = r1.id.clone();
        history.add_record(r1);

        assert_eq!(history.records().len(), 1);
        assert!(history.toggle_favorite(&id1));
        assert!(history.records()[0].is_favorite);

        assert!(history.delete_record(&id1));
        assert_eq!(history.records().len(), 0);
    }

    #[test]
    fn new_records_use_windows_compatible_id_and_timestamp() {
        let record = TranslationRecord::new("One", "一", "en", "zh-CN", "google");
        assert_eq!(record.id.len(), 36);
        assert_eq!(record.id.chars().filter(|c| *c == '-').count(), 4);
        assert!(record.timestamp.contains('T'));
        assert!(record.timestamp.ends_with('Z'));
    }

    #[test]
    fn history_keeps_latest_first_and_caps_at_windows_limit() {
        let mut history = TranslationHistory::new();
        for i in 0..101 {
            history.add_record(TranslationRecord::new(
                i.to_string(),
                "译文",
                "en",
                "zh-CN",
                "google",
            ));
        }
        assert_eq!(history.records().len(), 100);
        assert_eq!(history.records()[0].source_text, "100");
        assert_eq!(history.records()[99].source_text, "1");
    }

    #[test]
    fn loads_existing_windows_history_file() {
        let dir =
            std::env::temp_dir().join(format!("polyglance-history-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("translation_history.json");
        std::fs::write(&path, r#"[{"id":"123e4567-e89b-12d3-a456-426614174000","timestamp":"2026-09-28T10:20:30+00:00","source_text":"Hello","target_text":"你好","source_lang":"en","target_lang":"zh-CN","provider":"google","is_favorite":true}]"#).unwrap();
        let loaded = TranslationHistory::load_from_file(&path);
        assert_eq!(loaded.records().len(), 1);
        assert_eq!(loaded.records()[0].target_text, "你好");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn corrupt_history_is_reported_and_left_untouched() {
        let path = std::env::temp_dir().join(format!(
            "polyglance-corrupt-history-{}.json",
            Uuid::new_v4()
        ));
        let original = b"not valid json";
        std::fs::write(&path, original).unwrap();
        assert!(TranslationHistory::try_load_from_file(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(path).unwrap();
    }
}
