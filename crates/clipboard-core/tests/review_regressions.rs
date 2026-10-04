use clipboard_core::*;

const AT_PIXEL_LIMIT: &[u8] = include_bytes!("fixtures/at-pixel-limit.png");
const OVER_PIXEL_LIMIT: &[u8] = include_bytes!("fixtures/over-pixel-limit.png");

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
fn all_image_representations_enforce_the_pixel_budget_before_capture() {
    let mut history = History::open(":memory:", Limits::default(), 100).unwrap();
    let id = history.record(text(1), &policy()).unwrap().unwrap();
    let before = history.stats().unwrap();
    let image = ClipboardItem {
        representations: vec![Representation {
            format: "image/png".into(),
            bytes: OVER_PIXEL_LIMIT.to_vec(),
        }],
    };
    for items in [
        vec![image.clone()],
        vec![ClipboardItem {
            representations: mixed(2, OVER_PIXEL_LIMIT).representations,
        }],
        vec![
            ClipboardItem {
                representations: text(2).representations,
            },
            image,
        ],
    ] {
        let result = history.record_bundle(
            BundleInput {
                items,
                source_application: "review.fixture".into(),
                observed_types: vec![],
                copied_at_ms: 2,
            },
            &policy(),
        );
        assert!(matches!(result, Err(Error::TooLarge)));
        assert_eq!(history.stats().unwrap(), before);
        assert_eq!(history.payload(id).unwrap(), text(1).representations);
    }
    // The boundary is inclusive, regardless of the small compressed file size.
    history
        .record(mixed(3, AT_PIXEL_LIMIT), &policy())
        .unwrap()
        .unwrap();
    let directory = tempfile::tempdir().unwrap();
    let backup = directory.path().join("boundary.polyclipboard");
    history.export_backup(&backup).unwrap();
    let mut restored = History::open(":memory:", Limits::default(), 100).unwrap();
    restored
        .import_backup(backup, RestoreMode::Replace, 100)
        .unwrap();
    let restored_id = restored.list("", false, 0, 100, 100).unwrap()[0].id;
    assert_eq!(
        restored.bundle(restored_id).unwrap(),
        history.bundle(id).unwrap()
    );
}

#[test]
fn oversized_images_in_legacy_backups_roll_back_merge_and_replace() {
    let directory = tempfile::tempdir().unwrap();
    let backup = directory.path().join("legacy.polyclipboard");
    let mut source = History::open(":memory:", Limits::default(), 100).unwrap();
    let source_id = source.record(text(1), &policy()).unwrap().unwrap();
    source
        .set_annotation(source_id, "imported title", &[], 100)
        .unwrap();
    let mut later = mixed(3, PNG);
    later.representations[0].bytes = b"later image".to_vec();
    source.record(later, &policy()).unwrap();
    source.export_backup(&backup).unwrap();
    // Earlier versions could export this valid, highly compressed oversized PNG.
    rusqlite::Connection::open(&backup)
        .unwrap()
        .execute(
            "UPDATE representations SET data=?1 WHERE format='image/png'",
            [OVER_PIXEL_LIMIT],
        )
        .unwrap();
    for mode in [RestoreMode::Merge, RestoreMode::Replace] {
        let mut target = History::open(":memory:", Limits::default(), 100).unwrap();
        let id = target.record(text(0), &policy()).unwrap().unwrap();
        target.set_pinned(id, true, 100).unwrap();
        target.set_pin_shortcut(id, "b").unwrap();
        let before = target.stats().unwrap();
        let token = target.capture_token(id).unwrap();
        assert!(matches!(
            target.import_backup(&backup, mode, 100),
            Err(Error::TooLarge)
        ));
        assert_eq!(target.stats().unwrap(), before);
        assert_eq!(target.capture_token(id).unwrap(), token);
        assert!(target.entry(id, 100).unwrap().unwrap().pinned);
        assert!(target.annotation(id).unwrap().title.is_empty());
        assert_eq!(target.pin_shortcuts().unwrap()[0].key, "b");
        assert_eq!(target.payload(id).unwrap(), text(0).representations);
    }
}

#[test]
fn incomplete_or_malformed_png_dimension_headers_are_rejected() {
    let mut wrong_chunk = PNG.to_vec();
    wrong_chunk[12..16].copy_from_slice(b"IDAT");
    let mut wrong_length = PNG.to_vec();
    wrong_length[11] = 12;
    let mut zero_width = PNG.to_vec();
    zero_width[16..20].fill(0);
    let mut maximum_dimensions = PNG.to_vec();
    maximum_dimensions[16..24].fill(255);
    for bytes in [
        PNG[..8].to_vec(),
        PNG[..32].to_vec(),
        wrong_chunk,
        wrong_length,
        zero_width,
        maximum_dimensions,
    ] {
        let mut history = History::open(":memory:", Limits::default(), 100).unwrap();
        assert!(history.record(mixed(1, &bytes), &policy()).is_err());
        assert_eq!(history.stats().unwrap().items, 0);
    }
}

#[test]
fn saving_unchanged_pinned_rich_text_removes_formatting_and_invalidates_old_tokens() {
    let mut history = History::open(":memory:", Limits::default(), 100).unwrap();
    let mut input = text(1);
    for (format, bytes) in [
        ("text/html", "<b>same text</b>"),
        ("text/rtf", "{\\rtf1 same text}"),
    ] {
        input.representations.push(Representation {
            format: format.into(),
            bytes: bytes.as_bytes().to_vec(),
        });
    }
    let id = history.record(input, &policy()).unwrap().unwrap();
    history.set_pinned(id, true, 100).unwrap();
    history
        .set_annotation(id, "snippet", &["work".into()], 100)
        .unwrap();
    history.set_pin_shortcut(id, "e").unwrap();
    let annotation = history.annotation(id).unwrap();
    let token = history.capture_token(id).unwrap();
    let before_bytes = history.stats().unwrap().bytes;
    history.edit_pinned_text(id, "same text", 100).unwrap();
    assert_eq!(history.payload(id).unwrap(), text(1).representations);
    assert_eq!(history.annotation(id).unwrap(), annotation);
    assert_eq!(history.pin_shortcuts().unwrap()[0].key, "e");
    let row = history
        .list("same text", false, 0, 100, 100)
        .unwrap()
        .remove(0);
    assert_eq!(row.id, id);
    assert!(row.pinned);
    assert_eq!(row.copied_at_ms, 1);
    assert_eq!(
        before_bytes - history.stats().unwrap().bytes,
        (b"<b>same text</b>".len() + b"{\\rtf1 same text}".len()) as u64
    );
    assert!(!history.delete_if_capture_matches(id, &token).unwrap());
    let plain_token = history.capture_token(id).unwrap();
    let plain_bytes = history.stats().unwrap().bytes;
    history.edit_pinned_text(id, "same text", 100).unwrap();
    assert_eq!(
        history.capture_token(id).unwrap(),
        plain_token,
        "An already plain unchanged snippet is a no-op."
    );
    assert_eq!(history.stats().unwrap().bytes, plain_bytes);
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
