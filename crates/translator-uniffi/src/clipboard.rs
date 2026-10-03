//! Thin Swift bindings for clipboard-core. Policy and persistence live in the core.
use clipboard_core as core;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardLimits {
    pub maximum_items: u32,
    pub maximum_bytes: u64,
    pub maximum_item_bytes: u64,
    pub retention_days: u32,
}
impl From<ClipboardLimits> for core::Limits {
    fn from(v: ClipboardLimits) -> Self {
        Self {
            maximum_items: v.maximum_items,
            maximum_bytes: v.maximum_bytes,
            maximum_item_bytes: v.maximum_item_bytes,
            retention_days: v.retention_days,
        }
    }
}
impl From<core::Limits> for ClipboardLimits {
    fn from(v: core::Limits) -> Self {
        Self {
            maximum_items: v.maximum_items,
            maximum_bytes: v.maximum_bytes,
            maximum_item_bytes: v.maximum_item_bytes,
            retention_days: v.retention_days,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardPolicy {
    pub enabled: bool,
    pub ignored_applications: Vec<String>,
    pub ignored_types: Vec<String>,
    pub ignored_patterns: Vec<String>,
}
impl From<ClipboardPolicy> for core::CapturePolicy {
    fn from(v: ClipboardPolicy) -> Self {
        Self {
            enabled: v.enabled,
            ignored_applications: v.ignored_applications,
            ignored_types: v.ignored_types,
            ignored_patterns: v.ignored_patterns,
        }
    }
}
impl From<core::CapturePolicy> for ClipboardPolicy {
    fn from(v: core::CapturePolicy) -> Self {
        Self {
            enabled: v.enabled,
            ignored_applications: v.ignored_applications,
            ignored_types: v.ignored_types,
            ignored_patterns: v.ignored_patterns,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardRepresentation {
    pub format: String,
    pub bytes: Vec<u8>,
}
impl From<ClipboardRepresentation> for core::Representation {
    fn from(v: ClipboardRepresentation) -> Self {
        Self {
            format: v.format,
            bytes: v.bytes,
        }
    }
}
impl From<core::Representation> for ClipboardRepresentation {
    fn from(v: core::Representation) -> Self {
        Self {
            format: v.format,
            bytes: v.bytes,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardInput {
    pub representations: Vec<ClipboardRepresentation>,
    pub source_application: String,
    pub observed_types: Vec<String>,
    pub copied_at_ms: u64,
}
impl From<ClipboardInput> for core::Input {
    fn from(v: ClipboardInput) -> Self {
        Self {
            representations: v.representations.into_iter().map(Into::into).collect(),
            source_application: v.source_application,
            observed_types: v.observed_types,
            copied_at_ms: v.copied_at_ms,
        }
    }
}
impl From<core::Input> for ClipboardInput {
    fn from(v: core::Input) -> Self {
        Self {
            representations: v.representations.into_iter().map(Into::into).collect(),
            source_application: v.source_application,
            observed_types: v.observed_types,
            copied_at_ms: v.copied_at_ms,
        }
    }
}
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum ClipboardKind {
    Text,
    Image,
    File,
    Multiple,
}
impl From<core::Kind> for ClipboardKind {
    fn from(v: core::Kind) -> Self {
        match v {
            core::Kind::Text => Self::Text,
            core::Kind::Image => Self::Image,
            core::Kind::File => Self::File,
            core::Kind::Multiple => Self::Multiple,
        }
    }
}
impl From<ClipboardKind> for core::Kind {
    fn from(v: ClipboardKind) -> Self {
        match v {
            ClipboardKind::Text => Self::Text,
            ClipboardKind::Image => Self::Image,
            ClipboardKind::File => Self::File,
            ClipboardKind::Multiple => Self::Multiple,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardEntry {
    pub id: u64,
    pub kind: ClipboardKind,
    pub preview: String,
    pub source_application: String,
    pub copied_at_ms: u64,
    pub pinned: bool,
    pub byte_count: u64,
    pub title: String,
    pub tags: Vec<String>,
    pub item_count: u32,
    pub ocr_indexed: bool,
}
impl From<core::Entry> for ClipboardEntry {
    fn from(v: core::Entry) -> Self {
        Self {
            id: v.id,
            kind: v.kind.into(),
            preview: v.preview,
            source_application: v.source_application,
            copied_at_ms: v.copied_at_ms,
            pinned: v.pinned,
            byte_count: v.byte_count,
            title: v.title,
            tags: v.tags,
            item_count: v.item_count,
            ocr_indexed: v.ocr_indexed,
        }
    }
}
impl From<ClipboardEntry> for core::Entry {
    fn from(v: ClipboardEntry) -> Self {
        Self {
            id: v.id,
            kind: v.kind.into(),
            preview: v.preview,
            source_application: v.source_application,
            copied_at_ms: v.copied_at_ms,
            pinned: v.pinned,
            byte_count: v.byte_count,
            title: v.title,
            tags: v.tags,
            item_count: v.item_count,
            ocr_indexed: v.ocr_indexed,
        }
    }
}
#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct ClipboardStats {
    pub items: u32,
    pub bytes: u64,
}
impl From<core::Stats> for ClipboardStats {
    fn from(v: core::Stats) -> Self {
        Self {
            items: v.items,
            bytes: v.bytes,
        }
    }
}
impl From<ClipboardStats> for core::Stats {
    fn from(v: ClipboardStats) -> Self {
        Self {
            items: v.items,
            bytes: v.bytes,
        }
    }
}
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ClipboardFailure {
    #[error("invalid exclusion expression")]
    InvalidPattern,
    #[error("pinned shortcut is already assigned")]
    ShortcutConflict,
    #[error("edited content already exists")]
    ContentConflict,
    #[error("invalid input")]
    InvalidInput,
    #[error("unsupported schema")]
    UnsupportedSchema,
    #[error("item too large")]
    TooLarge,
    #[error("history capacity reached")]
    Capacity,
    #[error("item not found")]
    NotFound,
    #[error("storage failed")]
    Storage,
    #[error("damaged database or backup")]
    Corrupt,
}
impl From<core::Error> for ClipboardFailure {
    fn from(v: core::Error) -> Self {
        match v {
            core::Error::InvalidPattern => Self::InvalidPattern,
            core::Error::ShortcutConflict => Self::ShortcutConflict,
            core::Error::ContentConflict => Self::ContentConflict,
            core::Error::InvalidInput => Self::InvalidInput,
            core::Error::UnsupportedSchema => Self::UnsupportedSchema,
            core::Error::TooLarge => Self::TooLarge,
            core::Error::Capacity => Self::Capacity,
            core::Error::NotFound => Self::NotFound,
            core::Error::Storage(_) | core::Error::Io(_) => Self::Storage,
            core::Error::Corrupt => Self::Corrupt,
        }
    }
}
#[uniffi::export]
pub fn clipboard_default_limits() -> ClipboardLimits {
    core::Limits::default().into()
}
#[uniffi::export]
pub fn clipboard_should_capture(
    policy: ClipboardPolicy,
    source: String,
    types: Vec<String>,
) -> bool {
    core::should_capture(&policy.into(), &source, &types)
}
#[derive(uniffi::Object)]
pub struct ClipboardHistory {
    inner: Mutex<core::History>,
}
impl ClipboardHistory {
    fn lock(&self) -> Result<MutexGuard<'_, core::History>, ClipboardFailure> {
        self.inner.lock().map_err(|_| ClipboardFailure::Storage)
    }
}
#[uniffi::export]
impl ClipboardHistory {
    #[uniffi::constructor]
    pub fn new(
        path: String,
        limits: ClipboardLimits,
        now_ms: u64,
    ) -> Result<Arc<Self>, ClipboardFailure> {
        Ok(Arc::new(Self {
            inner: Mutex::new(
                core::History::open(path, limits.into(), now_ms).map_err(ClipboardFailure::from)?,
            ),
        }))
    }
    pub fn configure(&self, limits: ClipboardLimits, now_ms: u64) -> Result<(), ClipboardFailure> {
        self.lock()?
            .configure(limits.into(), now_ms)
            .map_err(Into::into)
    }
    pub fn record(
        &self,
        input: ClipboardInput,
        policy: ClipboardPolicy,
    ) -> Result<Option<u64>, ClipboardFailure> {
        self.lock()?
            .record(input.into(), &policy.into())
            .map_err(Into::into)
    }
    pub fn list(
        &self,
        query: String,
        pinned_only: bool,
        offset: u32,
        limit: u32,
        now_ms: u64,
    ) -> Result<Vec<ClipboardEntry>, ClipboardFailure> {
        self.lock()?
            .list(&query, pinned_only, offset, limit, now_ms)
            .map(|entries| entries.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
    pub fn payload(&self, id: u64) -> Result<Vec<ClipboardRepresentation>, ClipboardFailure> {
        self.lock()?
            .payload(id)
            .map(|items| items.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
    pub fn set_pinned(&self, id: u64, pinned: bool, now_ms: u64) -> Result<(), ClipboardFailure> {
        self.lock()?
            .set_pinned(id, pinned, now_ms)
            .map_err(Into::into)
    }
    pub fn delete(&self, id: u64) -> Result<(), ClipboardFailure> {
        self.lock()?.delete(id).map_err(Into::into)
    }
    pub fn clear(&self, include_pinned: bool) -> Result<(), ClipboardFailure> {
        self.lock()?.clear(include_pinned).map_err(Into::into)
    }
    pub fn stats(&self) -> Result<ClipboardStats, ClipboardFailure> {
        self.lock()?.stats().map(Into::into).map_err(Into::into)
    }
}

#[uniffi::export]
pub fn clipboard_image_dimensions_allowed(width: u64, height: u64) -> bool {
    core::image_dimensions_allowed(width, height)
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardItem {
    pub representations: Vec<ClipboardRepresentation>,
}
impl From<ClipboardItem> for core::ClipboardItem {
    fn from(v: ClipboardItem) -> Self {
        Self {
            representations: v.representations.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<core::ClipboardItem> for ClipboardItem {
    fn from(v: core::ClipboardItem) -> Self {
        Self {
            representations: v.representations.into_iter().map(Into::into).collect(),
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardBundleInput {
    pub items: Vec<ClipboardItem>,
    pub source_application: String,
    pub observed_types: Vec<String>,
    pub copied_at_ms: u64,
}
impl From<ClipboardBundleInput> for core::BundleInput {
    fn from(v: ClipboardBundleInput) -> Self {
        Self {
            items: v.items.into_iter().map(Into::into).collect(),
            source_application: v.source_application,
            observed_types: v.observed_types,
            copied_at_ms: v.copied_at_ms,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardFilter {
    pub query: String,
    pub kind: Option<ClipboardKind>,
    pub source: Option<String>,
    pub tag: Option<String>,
    pub pinned_only: bool,
}
impl From<ClipboardFilter> for core::Filter {
    fn from(v: ClipboardFilter) -> Self {
        Self {
            query: v.query,
            kind: v.kind.map(Into::into),
            source: v.source,
            tag: v.tag,
            pinned_only: v.pinned_only,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardAnnotation {
    pub title: String,
    pub tags: Vec<String>,
    pub ocr_text: String,
}
impl From<core::Annotation> for ClipboardAnnotation {
    fn from(v: core::Annotation) -> Self {
        Self {
            title: v.title,
            tags: v.tags,
            ocr_text: v.ocr_text,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardClearPreview {
    pub items: u32,
    pub bytes: u64,
    pub pinned_items: u32,
}
impl From<core::ClearPreview> for ClipboardClearPreview {
    fn from(v: core::ClearPreview) -> Self {
        Self {
            items: v.items,
            bytes: v.bytes,
            pinned_items: v.pinned_items,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardBackupInfo {
    pub schema_version: u32,
    pub items: u32,
    pub bytes: u64,
    pub pinned_items: u32,
}
impl From<core::BackupInfo> for ClipboardBackupInfo {
    fn from(v: core::BackupInfo) -> Self {
        Self {
            schema_version: v.schema_version,
            items: v.items,
            bytes: v.bytes,
            pinned_items: v.pinned_items,
        }
    }
}
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum ClipboardRestoreMode {
    Merge,
    Replace,
}
impl From<ClipboardRestoreMode> for core::RestoreMode {
    fn from(v: ClipboardRestoreMode) -> Self {
        match v {
            ClipboardRestoreMode::Merge => Self::Merge,
            ClipboardRestoreMode::Replace => Self::Replace,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardRestoreReport {
    pub added: u32,
    pub merged: u32,
    pub evicted: u32,
    pub items: u32,
}
impl From<core::RestoreReport> for ClipboardRestoreReport {
    fn from(v: core::RestoreReport) -> Self {
        Self {
            added: v.added,
            merged: v.merged,
            evicted: v.evicted,
            items: v.items,
        }
    }
}
#[uniffi::export]
impl ClipboardHistory {
    pub fn record_bundle(
        &self,
        input: ClipboardBundleInput,
        policy: ClipboardPolicy,
    ) -> Result<Option<u64>, ClipboardFailure> {
        self.lock()?
            .record_bundle(input.into(), &policy.into())
            .map_err(Into::into)
    }
    pub fn bundle(&self, id: u64) -> Result<Vec<ClipboardItem>, ClipboardFailure> {
        self.lock()?
            .bundle(id)
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
    pub fn list_filtered(
        &self,
        filter: ClipboardFilter,
        offset: u32,
        limit: u32,
        now_ms: u64,
    ) -> Result<Vec<ClipboardEntry>, ClipboardFailure> {
        self.lock()?
            .list_filtered(&filter.into(), offset, limit, now_ms)
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
    pub fn annotation(&self, id: u64) -> Result<ClipboardAnnotation, ClipboardFailure> {
        self.lock()?
            .annotation(id)
            .map(Into::into)
            .map_err(Into::into)
    }
    pub fn set_annotation(
        &self,
        id: u64,
        title: String,
        tags: Vec<String>,
        now_ms: u64,
    ) -> Result<(), ClipboardFailure> {
        self.lock()?
            .set_annotation(id, &title, &tags, now_ms)
            .map_err(Into::into)
    }
    pub fn pending_ocr(&self, limit: u32) -> Result<Vec<u64>, ClipboardFailure> {
        self.lock()?.pending_ocr(limit).map_err(Into::into)
    }
    pub fn store_ocr(&self, id: u64, text: String, now_ms: u64) -> Result<(), ClipboardFailure> {
        self.lock()?
            .store_ocr(id, &text, now_ms)
            .map_err(Into::into)
    }
    pub fn mark_ocr_failed(&self, id: u64) -> Result<(), ClipboardFailure> {
        self.lock()?.mark_ocr_failed(id).map_err(Into::into)
    }
    pub fn retry_ocr(&self) -> Result<(), ClipboardFailure> {
        self.lock()?.retry_ocr().map_err(Into::into)
    }
    pub fn sources(&self) -> Result<Vec<String>, ClipboardFailure> {
        self.lock()?.sources().map_err(Into::into)
    }
    pub fn tags(&self) -> Result<Vec<String>, ClipboardFailure> {
        self.lock()?.tags().map_err(Into::into)
    }
    pub fn clear_preview(
        &self,
        include_pinned: bool,
    ) -> Result<ClipboardClearPreview, ClipboardFailure> {
        self.lock()?
            .clear_preview(include_pinned)
            .map(Into::into)
            .map_err(Into::into)
    }
    pub fn export_backup(&self, path: String) -> Result<ClipboardBackupInfo, ClipboardFailure> {
        self.lock()?
            .export_backup(path)
            .map(Into::into)
            .map_err(Into::into)
    }
    pub fn import_backup(
        &self,
        path: String,
        mode: ClipboardRestoreMode,
        now_ms: u64,
    ) -> Result<ClipboardRestoreReport, ClipboardFailure> {
        self.lock()?
            .import_backup(path, mode.into(), now_ms)
            .map(Into::into)
            .map_err(Into::into)
    }
}
#[uniffi::export]
pub fn clipboard_inspect_backup(path: String) -> Result<ClipboardBackupInfo, ClipboardFailure> {
    core::inspect_backup(path)
        .map(Into::into)
        .map_err(Into::into)
}
#[uniffi::export]
pub fn clipboard_recover_database(
    path: String,
    backup: String,
    limits: ClipboardLimits,
    now_ms: u64,
) -> Result<ClipboardRestoreReport, ClipboardFailure> {
    core::recover_database(path, backup, limits.into(), now_ms)
        .map(Into::into)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn clipboard_plain_text(items: Vec<ClipboardItem>) -> Option<String> {
    core::plain_text(&items.into_iter().map(Into::into).collect::<Vec<_>>())
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ClipboardPinShortcut { pub entry_id: u64, pub key: String }

#[uniffi::export]
pub fn clipboard_validate_ignored_patterns(patterns: Vec<String>) -> Result<(), ClipboardFailure> {
    core::validate_ignored_patterns(&patterns).map_err(Into::into)
}

#[uniffi::export]
impl ClipboardHistory {
    pub fn pin_shortcuts(&self) -> Result<Vec<ClipboardPinShortcut>, ClipboardFailure> {
        self.lock()?.pin_shortcuts().map(|v|v.into_iter().map(|s|ClipboardPinShortcut {entry_id:s.entry_id,key:s.key}).collect()).map_err(Into::into)
    }
    pub fn set_pin_shortcut(&self, id:u64, key:String) -> Result<(),ClipboardFailure> {
        self.lock()?.set_pin_shortcut(id,&key).map_err(Into::into)
    }
    pub fn edit_pinned_text(&self,id:u64,text:String,now_ms:u64) -> Result<(),ClipboardFailure> {
        self.lock()?.edit_pinned_text(id,&text,now_ms).map_err(Into::into)
    }
    pub fn capture_token(&self,id:u64) -> Result<String,ClipboardFailure> {
        self.lock()?.capture_token(id).map_err(Into::into)
    }
    pub fn entry(&self,id:u64,now_ms:u64) -> Result<Option<ClipboardEntry>,ClipboardFailure> {
        self.lock()?.entry(id,now_ms).map(|v|v.map(Into::into)).map_err(Into::into)
    }
    pub fn delete_if_capture_matches(&self,id:u64,token:String) -> Result<bool,ClipboardFailure> {
        self.lock()?.delete_if_capture_matches(id,&token).map_err(Into::into)
    }
}
