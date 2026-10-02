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
}
impl From<ClipboardPolicy> for core::CapturePolicy {
    fn from(v: ClipboardPolicy) -> Self {
        Self {
            enabled: v.enabled,
            ignored_applications: v.ignored_applications,
            ignored_types: v.ignored_types,
        }
    }
}
impl From<core::CapturePolicy> for ClipboardPolicy {
    fn from(v: core::CapturePolicy) -> Self {
        Self {
            enabled: v.enabled,
            ignored_applications: v.ignored_applications,
            ignored_types: v.ignored_types,
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
}
impl From<core::Kind> for ClipboardKind {
    fn from(v: core::Kind) -> Self {
        match v {
            core::Kind::Text => Self::Text,
            core::Kind::Image => Self::Image,
        }
    }
}
impl From<ClipboardKind> for core::Kind {
    fn from(v: ClipboardKind) -> Self {
        match v {
            ClipboardKind::Text => Self::Text,
            ClipboardKind::Image => Self::Image,
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
}
impl From<core::Error> for ClipboardFailure {
    fn from(v: core::Error) -> Self {
        match v {
            core::Error::InvalidInput => Self::InvalidInput,
            core::Error::UnsupportedSchema => Self::UnsupportedSchema,
            core::Error::TooLarge => Self::TooLarge,
            core::Error::Capacity => Self::Capacity,
            core::Error::NotFound => Self::NotFound,
            core::Error::Storage(_) => Self::Storage,
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
