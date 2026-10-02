//! Versioned SQLite snapshots, validated imports and atomic recovery.
use super::*;
use rusqlite::{OpenFlags, OptionalExtension, backup::Backup};
use std::{
    fs,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RestoreMode {
    Merge,
    Replace,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BackupInfo {
    pub schema_version: u32,
    pub items: u32,
    pub bytes: u64,
    pub pinned_items: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RestoreReport {
    pub added: u32,
    pub merged: u32,
    pub evicted: u32,
    pub items: u32,
}

fn source(path: &Path) -> Result<(Connection, i64), Error> {
    if fs::metadata(path)?.len() > 3 * 1024 * 1024 * 1024 {
        return Err(Error::TooLarge);
    }
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(database_error)?;
    connection.execute_batch("PRAGMA trusted_schema=OFF;")?;
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(database_error)?;
    if version > SCHEMA_VERSION {
        return Err(Error::UnsupportedSchema);
    }
    if !(1..=SCHEMA_VERSION).contains(&version) {
        return Err(Error::Corrupt);
    }
    check_integrity(&connection)?;
    validate_schema(&connection, version)?;
    let orphans:u32=connection.query_row("SELECT count(*) FROM representations r LEFT JOIN entries e ON e.id=r.entry_id WHERE e.id IS NULL",[],|r|r.get(0))?;
    if orphans > 0 {
        return Err(Error::Corrupt);
    }
    let malformed:u32=connection.query_row("SELECT count(*) FROM entries WHERE id<=0 OR copied_at<0 OR pinned NOT IN (0,1) OR length(CAST(source AS BLOB))>512",[],|r|r.get(0))?;
    if malformed > 0 {
        return Err(Error::Corrupt);
    }
    if version == 2 {
        let invalid:u32=connection.query_row("SELECT count(*) FROM entries WHERE length(CAST(title AS BLOB))>512 OR length(CAST(tags AS BLOB))>10000 OR length(CAST(ocr_text AS BLOB))>1000000 OR ocr_state NOT IN (0,1,2)",[],|r|r.get(0))?;
        if invalid > 0 {
            return Err(Error::Corrupt);
        }
    }
    Ok((connection, version))
}
pub fn inspect_backup(path: impl AsRef<Path>) -> Result<BackupInfo, Error> {
    let (connection, version) = source(path.as_ref())?;
    inspect_source(&connection, version)
}
fn inspect_source(connection: &Connection, version: i64) -> Result<BackupInfo, Error> {
    let (items, pinned_items): (u32, u32) = connection.query_row(
        "SELECT count(*),coalesce(sum(pinned),0) FROM entries",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if items > 10_000 {
        return Err(Error::TooLarge);
    }
    let bytes: i64 = connection.query_row(
        "SELECT coalesce(sum(length(data)),0) FROM representations",
        [],
        |r| r.get(0),
    )?;
    if bytes > 2 * 1024 * 1024 * 1024 {
        return Err(Error::TooLarge);
    }
    Ok(BackupInfo {
        schema_version: version as u32,
        items,
        bytes: bytes as u64,
        pinned_items,
    })
}
impl History {
    pub fn export_backup(&self, path: impl AsRef<Path>) -> Result<BackupInfo, Error> {
        let path = path.as_ref();
        if same_file(&self.path, path) {
            return Err(Error::InvalidInput);
        }
        let parent = parent(path);
        let temporary = tempfile::NamedTempFile::new_in(parent)?;
        {
            let mut destination = Connection::open(temporary.path())?;
            let backup = Backup::new(&self.connection, &mut destination)?;
            // A locked destination/source must not hang the worker indefinitely.
            let deadline = Instant::now() + Duration::from_secs(30);
            loop {
                match backup.step(256)? {
                    rusqlite::backup::StepResult::Done => break,
                    rusqlite::backup::StepResult::More => {}
                    rusqlite::backup::StepResult::Busy | rusqlite::backup::StepResult::Locked => {
                        if Instant::now() > deadline {
                            return Err(Error::Io(std::io::Error::new(
                                std::io::ErrorKind::TimedOut,
                                "backup database busy",
                            )));
                        }
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    _ => return Err(Error::Corrupt),
                }
            }
        }
        let info = inspect_backup(temporary.path())?;
        temporary.as_file().sync_all()?;
        temporary.persist(path).map_err(|e| Error::Io(e.error))?;
        Ok(info)
    }
    /// Validate every item, reconstruct fingerprints and commit the whole import atomically.
    pub fn import_backup(
        &mut self,
        path: impl AsRef<Path>,
        mode: RestoreMode,
        now_ms: u64,
    ) -> Result<RestoreReport, Error> {
        if same_file(&self.path, path.as_ref()) {
            return Err(Error::InvalidInput);
        }
        let (source, version) = source(path.as_ref())?;
        inspect_source(&source, version)?;
        let sql = if version == 1 {
            "SELECT id,source,copied_at,pinned,'','[]','',0 FROM entries ORDER BY copied_at,id"
        } else {
            "SELECT id,source,copied_at,pinned,title,tags,ocr_text,ocr_state FROM entries ORDER BY copied_at,id"
        };
        let tx = self.connection.transaction()?;
        if mode == RestoreMode::Replace {
            tx.execute("DELETE FROM entries", [])?;
        }
        let before = stats(&tx)?.items;
        let mut added = 0u32;
        let mut merged = 0u32;
        let mut statement = source.prepare(sql)?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let source_id = row.get::<_, i64>(0)? as u64;
            let items = read_bundle(&source, source_id, version, self.limits.maximum_item_bytes)?;
            let input = BundleInput {
                items,
                source_application: row.get(1)?,
                observed_types: vec![],
                copied_at_ms: row.get::<_, i64>(2)? as u64,
            };
            let Some(p) = prepare(input, self.limits)? else {
                return Err(Error::Corrupt);
            };
            let title: String = row.get(4)?;
            let tags: String = row.get(5)?;
            let ocr: String = row.get(6)?;
            let tags: Vec<String> = serde_json::from_str(&tags).map_err(|_| Error::Corrupt)?;
            let imported = validated_annotation(&title, &tags, &ocr)?;
            let indexed: i64 = row.get(7)?;
            let has_image = p
                .input
                .items
                .iter()
                .any(|i| i.representations.iter().any(|r| r.format == "image/png"));
            if (!ocr.is_empty() || indexed != 0) && !has_image {
                return Err(Error::Corrupt);
            }
            let existing: Option<(u64, u64)> = tx
                .query_row(
                    "SELECT id,copied_at FROM entries WHERE fingerprint=?1",
                    [&p.fingerprint],
                    |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64)),
                )
                .optional()?;
            let id = if let Some((id, time)) = existing {
                merged += 1;
                if p.input.copied_at_ms >= time {
                    insert_prepared(&tx, &p)?;
                }
                id
            } else {
                added += 1;
                insert_prepared(&tx, &p)?
            };
            let (current_title, current_tags, current_ocr, state): (String, String, String, i64) =
                tx.query_row(
                    "SELECT title,tags,ocr_text,ocr_state FROM entries WHERE id=?1",
                    [timestamp(id)?],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )?;
            let current_tags: Vec<String> =
                serde_json::from_str(&current_tags).map_err(|_| Error::Corrupt)?;
            let old = Annotation {
                title: current_title,
                tags: current_tags,
                ocr_text: current_ocr,
            };
            let title = if old.title.is_empty() {
                &imported.title
            } else {
                &old.title
            };
            let mut tags = old.tags.clone();
            for t in imported.tags {
                if !tags.contains(&t) {
                    tags.push(t);
                }
            }
            let text = if state == 1 {
                &old.ocr_text
            } else {
                &imported.ocr_text
            };
            let annotation = validated_annotation(title, &tags, text)?;
            let delta = annotation_bytes(&annotation) as i64 - annotation_bytes(&old) as i64;
            let pinned: bool = row.get(3)?;
            tx.execute(
                "UPDATE entries SET title=?1,tags=?2,metadata_search=?3,ocr_text=?4,ocr_search=?5,
                ocr_state=?6,pinned=(pinned OR ?7),byte_count=byte_count+?8 WHERE id=?9",
                params![
                    annotation.title,
                    serde_json::to_string(&annotation.tags).map_err(|_| Error::InvalidInput)?,
                    metadata_search(&annotation),
                    annotation.ocr_text,
                    annotation.ocr_text.to_lowercase(),
                    if state == 1 || indexed == 1 { 1 } else { 0 },
                    pinned,
                    delta,
                    timestamp(id)?
                ],
            )?;
        }
        enforce_limits(&tx, self.limits, now_ms, None)?;
        let after = stats(&tx)?.items;
        tx.commit()?;
        self.reclaim_pages();
        Ok(RestoreReport {
            added,
            merged,
            evicted: before + added - after,
            items: after,
        })
    }
}
/// Used only after the platform has closed the damaged engine and the user selected replacement.
/// The old database is retained in a private sibling file before atomic replacement.
pub fn recover_database(
    path: impl AsRef<Path>,
    backup: impl AsRef<Path>,
    limits: Limits,
    now_ms: u64,
) -> Result<RestoreReport, Error> {
    let path = path.as_ref();
    let backup = backup.as_ref();
    if same_file(path, backup) {
        return Err(Error::InvalidInput);
    }
    let temporary = tempfile::NamedTempFile::new_in(parent(path))?;
    let report = {
        let mut fresh = History::open(temporary.path(), limits, now_ms)?;
        fresh.import_backup(backup, RestoreMode::Replace, now_ms)?
    };
    if path.exists() {
        let damaged = tempfile::Builder::new()
            .prefix("history-damaged-")
            .suffix(".sqlite3")
            .tempfile_in(parent(path))?;
        fs::copy(path, damaged.path())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(damaged.path(), fs::Permissions::from_mode(0o600))?;
        }
        damaged.as_file().sync_all()?;
        damaged.keep().map_err(|e| Error::Io(e.error))?;
    }
    temporary.as_file().sync_all()?;
    temporary.persist(path).map_err(|e| Error::Io(e.error))?;
    Ok(report)
}
fn parent(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
}
fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}
