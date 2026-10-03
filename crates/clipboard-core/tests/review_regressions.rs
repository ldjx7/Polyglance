use clipboard_core::*;

const PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0,
    0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 248, 15, 4, 0, 9, 251, 3,
    253, 251, 94, 107, 43, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

fn policy() -> CapturePolicy {
    CapturePolicy {
        enabled: true,
        ..Default::default()
    }
}

fn text(time: u64) -> Input {
    Input {
        representations: vec![Representation {
            format: "text/plain".into(),
            bytes: b"same text".to_vec(),
        }],
        source_application: "review.fixture".into(),
        observed_types: vec![],
        copied_at_ms: time,
    }
}

fn indexed_mixed_entry() -> (History, u64) {
    let mut history = History::open(":memory:", Limits::default(), 100).unwrap();
    let id = history.record(mixed(1, PNG), &policy()).unwrap().unwrap();
    history.store_ocr(id, "old raster secret", 100).unwrap();
    (history, id)
}

fn mixed(time: u64, png: &[u8]) -> Input {
    let mut input = text(time);
    input.representations.push(Representation {
        format: "image/png".into(),
        bytes: png.to_vec(),
    });
    input
}

#[test]
fn recapturing_text_without_its_old_image_invalidates_ocr() {
    let (mut history, id) = indexed_mixed_entry();
    assert_eq!(history.record(text(2), &policy()).unwrap(), Some(id));
    assert!(
        history.annotation(id).unwrap().ocr_text.is_empty(),
        "OCR from a removed representation must not survive"
    );
    assert!(!history.entry(id, 100).unwrap().unwrap().ocr_indexed);
    assert!(
        history
            .list("old raster secret", false, 0, 100, 100)
            .unwrap()
            .is_empty()
    );
    let mut fresh = History::open(":memory:", Limits::default(), 100).unwrap();
    fresh.record(text(2), &policy()).unwrap();
    assert_eq!(history.stats().unwrap().bytes, fresh.stats().unwrap().bytes);
}

#[test]
fn backup_remains_restorable_after_a_duplicate_drops_its_image() {
    let (mut history, id) = indexed_mixed_entry();
    assert_eq!(history.record(text(2), &policy()).unwrap(), Some(id));
    let directory = tempfile::tempdir().unwrap();
    let backup = directory.path().join("own-backup.polyclipboard");
    history.export_backup(&backup).unwrap();
    let mut restored = History::open(":memory:", Limits::default(), 100).unwrap();
    restored
        .import_backup(&backup, RestoreMode::Replace, 100)
        .expect("a freshly exported backup must restore");
}

#[test]
fn accepted_unicode_tag_remains_valid_in_its_own_backup() {
    let mut history = History::open(":memory:", Limits::default(), 100).unwrap();
    let id = history.record(text(1), &policy()).unwrap().unwrap();
    // 32 uppercase dotted Is normalize to exactly 64 Unicode scalars.
    history
        .set_annotation(id, "", &["İ".repeat(32)], 100)
        .unwrap();
    let original = history.annotation(id).unwrap();
    assert!(matches!(
        history.set_annotation(id, "", &["İ".repeat(64)], 100),
        Err(Error::InvalidInput)
    ));
    assert_eq!(
        history.annotation(id).unwrap(),
        original,
        "invalid tags must not change metadata"
    );
    let directory = tempfile::tempdir().unwrap();
    let backup = directory.path().join("own-backup.polyclipboard");
    history.export_backup(&backup).unwrap();
    let mut restored = History::open(":memory:", Limits::default(), 100).unwrap();
    restored
        .import_backup(&backup, RestoreMode::Replace, 100)
        .expect("an accepted tag must survive export/import");
    let restored_id = restored.list("", false, 0, 100, 100).unwrap()[0].id;
    assert_eq!(restored.annotation(restored_id).unwrap(), original);
}

#[test]
fn recapture_retains_identical_image_cache_but_rejects_late_results_for_changed_images() {
    let (mut history, id) = indexed_mixed_entry();
    let bytes = history.stats().unwrap().bytes;
    history.record(mixed(2, PNG), &policy()).unwrap();
    assert_eq!(
        history.annotation(id).unwrap().ocr_text,
        "old raster secret"
    );
    assert_eq!(history.stats().unwrap().bytes, bytes);
    assert!(history.pending_ocr(10).unwrap().is_empty());

    let token = history.capture_token(id).unwrap();
    let mut changed = PNG.to_vec();
    changed.extend_from_slice(b"different image representation");
    history.record(mixed(3, &changed), &policy()).unwrap();
    assert_eq!(history.pending_ocr(10).unwrap(), vec![id]);
    assert!(history.annotation(id).unwrap().ocr_text.is_empty());
    assert!(
        !history
            .store_ocr_if_capture_matches(id, &token, "late result", 100)
            .unwrap()
    );
    assert!(
        !history
            .mark_ocr_failed_if_capture_matches(id, &token)
            .unwrap()
    );
    assert_eq!(history.pending_ocr(10).unwrap(), vec![id]);
    let token = history.capture_token(id).unwrap();
    assert!(
        history
            .store_ocr_if_capture_matches(id, &token, "current result", 100)
            .unwrap()
    );
    history.delete(id).unwrap();
    assert!(
        !history
            .store_ocr_if_capture_matches(id, &token, "deleted result", 100)
            .unwrap()
    );
}

#[test]
fn older_backup_cannot_attach_ocr_to_a_different_current_payload() {
    let (history, _) = indexed_mixed_entry();
    let directory = tempfile::tempdir().unwrap();
    let backup = directory.path().join("older.polyclipboard");
    history.export_backup(&backup).unwrap();
    for with_image in [false, true] {
        let mut current = History::open(":memory:", Limits::default(), 100).unwrap();
        let mut changed = PNG.to_vec();
        changed.extend_from_slice(b"new payload");
        let input = if with_image {
            mixed(20, &changed)
        } else {
            text(20)
        };
        let id = current.record(input, &policy()).unwrap().unwrap();
        current
            .import_backup(&backup, RestoreMode::Merge, 100)
            .unwrap();
        assert!(current.annotation(id).unwrap().ocr_text.is_empty());
        assert!(!current.entry(id, 100).unwrap().unwrap().ocr_indexed);
        let roundtrip = directory.path().join("roundtrip.polyclipboard");
        current.export_backup(&roundtrip).unwrap();
        let mut restored = History::open(":memory:", Limits::default(), 100).unwrap();
        restored
            .import_backup(roundtrip, RestoreMode::Replace, 100)
            .unwrap();
    }
}

#[test]
fn legacy_backup_with_orphaned_ocr_restores_original_text() {
    let (history, _) = indexed_mixed_entry();
    let directory = tempfile::tempdir().unwrap();
    let backup = directory.path().join("legacy.polyclipboard");
    history.export_backup(&backup).unwrap();
    // Reproduce the earlier duplicate bug without relying on the corrected writer.
    let connection = rusqlite::Connection::open(&backup).unwrap();
    connection
        .execute("DELETE FROM representations WHERE format='image/png'", [])
        .unwrap();
    drop(connection);
    let mut restored = History::open(":memory:", Limits::default(), 100).unwrap();
    restored
        .import_backup(&backup, RestoreMode::Replace, 100)
        .unwrap();
    let rows = restored.list("", false, 0, 100, 100).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].preview, "same text");
    assert!(restored.annotation(rows[0].id).unwrap().ocr_text.is_empty());
    restored
        .export_backup(directory.path().join("repaired.polyclipboard"))
        .unwrap();
}

#[test]
fn reopening_legacy_history_removes_orphaned_ocr_without_losing_user_metadata() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("history.sqlite3");
    let mut history = History::open(&path, Limits::default(), 100).unwrap();
    let id = history.record(mixed(1, PNG), &policy()).unwrap().unwrap();
    history.set_pinned(id, true, 100).unwrap();
    history
        .set_annotation(id, "keep title", &["tag".into()], 100)
        .unwrap();
    history.store_ocr(id, "old OCR", 100).unwrap();
    drop(history);
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute("DELETE FROM representations WHERE format='image/png'", [])
        .unwrap();
    connection
        .execute(
            "UPDATE entries SET byte_count=byte_count-?1",
            [PNG.len() as i64],
        )
        .unwrap();
    drop(connection);
    let history = History::open(&path, Limits::default(), 100).unwrap();
    let annotation = history.annotation(id).unwrap();
    assert_eq!(annotation.title, "keep title");
    assert_eq!(annotation.tags, vec!["tag"]);
    assert!(annotation.ocr_text.is_empty());
    let mut fresh = History::open(":memory:", Limits::default(), 100).unwrap();
    let fresh_id = fresh.record(text(1), &policy()).unwrap().unwrap();
    fresh.set_pinned(fresh_id, true, 100).unwrap();
    fresh
        .set_annotation(fresh_id, "keep title", &["tag".into()], 100)
        .unwrap();
    assert_eq!(history.stats().unwrap(), fresh.stats().unwrap());
    assert_eq!(history.clear_preview(false).unwrap().items, 0);
}
