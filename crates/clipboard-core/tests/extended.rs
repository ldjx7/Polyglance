use clipboard_core::*;
fn policy() -> CapturePolicy {
    CapturePolicy {
        enabled: true,
        ..Default::default()
    }
}
fn item(format: &str, value: &[u8]) -> ClipboardItem {
    ClipboardItem {
        representations: vec![Representation {
            format: format.into(),
            bytes: value.to_vec(),
        }],
    }
}
fn bundle(items: Vec<ClipboardItem>, time: u64) -> BundleInput {
    BundleInput {
        items,
        source_application: "example.app".into(),
        observed_types: vec![],
        copied_at_ms: time,
    }
}
fn save(h: &mut History, value: &str, time: u64) -> u64 {
    h.record_bundle(
        bundle(vec![item("text/plain", value.as_bytes())], time),
        &policy(),
    )
    .unwrap()
    .unwrap()
}
fn rows(h: &mut History, filter: Filter) -> Vec<Entry> {
    h.list_filtered(&filter, 0, 100, 100).unwrap()
}
#[test]
fn ordered_files_and_multiple_items_roundtrip_and_deduplicate() {
    let mut h = History::open(":memory:", Limits::default(), 100).unwrap();
    let input = bundle(
        vec![
            item("text/uri-list", b"file:///tmp/%E4%BD%A0%E5%A5%BD.txt"),
            item("text/plain", b"second"),
        ],
        10,
    );
    let id = h.record_bundle(input.clone(), &policy()).unwrap().unwrap();
    let e = &rows(&mut h, Filter::default())[0];
    assert_eq!(e.kind, Kind::Multiple);
    assert_eq!(e.item_count, 2);
    assert_eq!(h.bundle(id).unwrap(), input.items);
    assert!(h.payload(id).is_err());
    for kind in [Kind::File, Kind::Text, Kind::Multiple] {
        assert_eq!(
            rows(
                &mut h,
                Filter {
                    kind: Some(kind),
                    ..Default::default()
                }
            )[0]
            .id,
            id
        );
    }
    assert_eq!(
        rows(
            &mut h,
            Filter {
                query: "你好".into(),
                ..Default::default()
            }
        )[0]
        .id,
        id
    );
    assert_eq!(h.record_bundle(input.clone(), &policy()).unwrap(), Some(id));
    let mut reversed = input;
    reversed.items.reverse();
    assert_ne!(h.record_bundle(reversed, &policy()).unwrap(), Some(id));
    assert_eq!(h.stats().unwrap().items, 2);
}

#[test]
fn ten_thousand_items_paginate_without_duplicates_and_evict_at_the_limit() {
    let limits = Limits {
        maximum_items: 10_000,
        retention_days: 0,
        ..Default::default()
    };
    let mut h = History::open(":memory:", limits, 0).unwrap();
    let ids: Vec<u64> = (1..=10_000)
        .map(|i| save(&mut h, &format!("record {i}"), i))
        .collect();
    assert_eq!(h.stats().unwrap().items, 10_000);
    let mut listed = Vec::new();
    for offset in (0..10_000).step_by(100) {
        let page = h.list("", false, offset, 1000, 10_000).unwrap();
        assert_eq!(page.len(), 100);
        listed.extend(page.into_iter().map(|e| e.id));
    }
    assert_eq!(listed, ids.iter().copied().rev().collect::<Vec<_>>());
    save(&mut h, "newest", 10_001);
    assert_eq!(h.stats().unwrap().items, 10_000);
    assert!(matches!(h.bundle(ids[0]), Err(Error::NotFound)));
    assert_eq!(
        h.list("record 9999", false, 0, 100, 10_001).unwrap()[0].id,
        ids[9998]
    );
}

#[test]
fn restore_rolls_back_when_pins_exceed_the_current_capacity() {
    let d = tempfile::tempdir().unwrap();
    let backup = d.path().join("pinned.polyclipboard");
    let mut source = History::open(d.path().join("source"), Limits::default(), 100).unwrap();
    for (value, time) in [("a", 1), ("b", 2)] {
        let id = save(&mut source, value, time);
        source.set_pinned(id, true, 100).unwrap();
    }
    source.export_backup(&backup).unwrap();
    let mut target = History::open(
        d.path().join("target"),
        Limits {
            maximum_items: 1,
            ..Default::default()
        },
        100,
    )
    .unwrap();
    let id = save(&mut target, "keep", 1);
    let before = target.stats().unwrap();
    for mode in [RestoreMode::Merge, RestoreMode::Replace] {
        assert!(matches!(
            target.import_backup(&backup, mode, 100),
            Err(Error::Capacity)
        ));
        assert_eq!(target.stats().unwrap(), before);
        assert_eq!(
            target.bundle(id).unwrap()[0].representations[0].bytes,
            b"keep"
        );
    }
}

#[test]
fn oversized_backup_payload_is_rejected_without_replacing_history() {
    let d = tempfile::tempdir().unwrap();
    let backup = d.path().join("oversized.polyclipboard");
    let mut source = History::open(d.path().join("source"), Limits::default(), 100).unwrap();
    save(&mut source, "a", 1);
    source.export_backup(&backup).unwrap();
    let c = rusqlite::Connection::open(&backup).unwrap();
    c.execute("UPDATE representations SET data=zeroblob(17*1024*1024)", [])
        .unwrap();
    drop(c);
    let mut target = History::open(d.path().join("target"), Limits::default(), 100).unwrap();
    let id = save(&mut target, "keep", 1);
    assert!(matches!(
        target.import_backup(&backup, RestoreMode::Replace, 100),
        Err(Error::TooLarge)
    ));
    assert_eq!(
        target.bundle(id).unwrap()[0].representations[0].bytes,
        b"keep"
    );
}
#[test]
fn rejects_nonfile_urls_and_sensitive_multi_item_capture_atomically() {
    let mut h = History::open(":memory:", Limits::default(), 100).unwrap();
    for url in [
        "https://example.com/a",
        "file:///tmp/a#fragment",
        "file:///tmp/a?query",
    ] {
        assert!(
            h.record_bundle(
                bundle(vec![item("text/uri-list", url.as_bytes())], 10),
                &policy()
            )
            .is_err()
        );
    }
    let mut input = bundle(
        vec![item("text/plain", b"first"), item("text/plain", b"secret")],
        10,
    );
    input
        .observed_types
        .push("polyglance.clipboard.confidential".into());
    assert_eq!(h.record_bundle(input, &policy()).unwrap(), None);
    assert_eq!(h.stats().unwrap().items, 0);
}
#[test]
fn labels_unicode_tags_filters_and_ocr_survive_recapture() {
    let mut h = History::open(":memory:", Limits::default(), 100).unwrap();
    let input = bundle(vec![item("image/png", b"\x89PNG\r\n\x1a\nfixture")], 10);
    let id = h.record_bundle(input.clone(), &policy()).unwrap().unwrap();
    h.set_annotation(
        id,
        "图片 ÄBC",
        &["项目".into(), " ÄBC ".into(), "äbc".into()],
        100,
    )
    .unwrap();
    assert_eq!(h.annotation(id).unwrap().tags, vec!["项目", "äbc"]);
    assert_eq!(h.pending_ocr(10).unwrap(), vec![id]);
    h.store_ocr(id, "识别出来的 ÄBC", 100).unwrap();
    assert!(h.pending_ocr(10).unwrap().is_empty());
    assert_eq!(
        rows(
            &mut h,
            Filter {
                query: "识别".into(),
                kind: Some(Kind::Image),
                tag: Some("项目".into()),
                source: Some("example.app".into()),
                ..Default::default()
            }
        )[0]
        .id,
        id
    );
    let annotation = h.annotation(id).unwrap();
    let bytes = h.stats().unwrap().bytes;
    assert_eq!(h.record_bundle(input, &policy()).unwrap(), Some(id));
    assert_eq!(h.annotation(id).unwrap(), annotation);
    assert_eq!(h.stats().unwrap().bytes, bytes);
    assert!(
        rows(
            &mut h,
            Filter {
                kind: Some(Kind::Text),
                ..Default::default()
            }
        )
        .is_empty()
    );
    assert_eq!(h.sources().unwrap(), vec!["example.app"]);
    assert_eq!(h.tags().unwrap().len(), 2);
}
#[test]
fn metadata_capacity_failure_rolls_back_and_clear_preview_preserves_pins() {
    let limits = Limits {
        maximum_bytes: 60,
        maximum_item_bytes: 30,
        ..Default::default()
    };
    let mut h = History::open(":memory:", limits, 100).unwrap();
    let a = save(&mut h, "a", 1);
    let b = save(&mut h, "b", 2);
    h.set_pinned(a, true, 100).unwrap();
    h.set_pinned(b, true, 100).unwrap();
    let before = h.stats().unwrap();
    assert!(matches!(
        h.set_annotation(a, &"x".repeat(100), &[], 100),
        Err(Error::Capacity)
    ));
    assert_eq!(h.annotation(a).unwrap(), Annotation::default());
    assert_eq!(h.stats().unwrap(), before);
    assert_eq!(h.clear_preview(false).unwrap().items, 0);
    assert_eq!(h.clear_preview(true).unwrap().pinned_items, 2);
}
#[test]
fn migrates_v1_database_without_losing_ids_pins_or_formats() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("v1.sqlite3");
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch("CREATE TABLE entries(id INTEGER PRIMARY KEY AUTOINCREMENT,fingerprint TEXT UNIQUE NOT NULL,kind INTEGER NOT NULL,preview TEXT NOT NULL,search_text TEXT NOT NULL,source TEXT NOT NULL,copied_at INTEGER NOT NULL,pinned INTEGER NOT NULL,byte_count INTEGER NOT NULL);
        CREATE TABLE representations(entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,format TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(entry_id,format));
        CREATE INDEX entries_recency ON entries(pinned DESC,copied_at DESC,id DESC);
        INSERT INTO entries VALUES(42,'legacy',0,'hello','hello','old.app',10,1,20);
        INSERT INTO representations VALUES(42,'text/plain',X'68656c6c6f');PRAGMA user_version=1;").unwrap();
    drop(c);
    let mut h = History::open(&path, Limits::default(), 100).unwrap();
    let e = &rows(&mut h, Filter::default())[0];
    assert_eq!(e.id, 42);
    assert!(e.pinned);
    assert_eq!(e.item_count, 1);
    assert_eq!(h.bundle(42).unwrap()[0].representations[0].bytes, b"hello");
    h.set_annotation(42, "renamed", &["tag".into()], 100)
        .unwrap();
    drop(h);
    let h = History::open(path, Limits::default(), 100).unwrap();
    assert_eq!(h.annotation(42).unwrap().title, "renamed");
}
#[test]
fn backup_merge_replace_and_ocr_metadata_roundtrip() {
    let d = tempfile::tempdir().unwrap();
    let backup = d.path().join("backup.polyclipboard");
    let mut original = History::open(d.path().join("original"), Limits::default(), 100).unwrap();
    let a = save(&mut original, "original", 1);
    original.set_pinned(a, true, 100).unwrap();
    original
        .set_annotation(a, "title", &["tag".into()], 100)
        .unwrap();
    let image = original
        .record_bundle(
            bundle(vec![item("image/png", b"\x89PNG\r\n\x1a\nfixture")], 2),
            &policy(),
        )
        .unwrap()
        .unwrap();
    original.store_ocr(image, "OCR 中文", 100).unwrap();
    let info = original.export_backup(&backup).unwrap();
    assert_eq!(info.items, 2);
    assert_eq!(info.pinned_items, 1);
    let mut destination =
        History::open(d.path().join("destination"), Limits::default(), 100).unwrap();
    save(&mut destination, "other", 3);
    let existing = save(&mut destination, "original", 4);
    destination
        .set_annotation(existing, "keep current", &["new".into()], 100)
        .unwrap();
    let r = destination
        .import_backup(&backup, RestoreMode::Merge, 100)
        .unwrap();
    assert_eq!(r.added, 1);
    assert_eq!(r.merged, 1);
    assert_eq!(r.items, 3);
    let a = destination.annotation(existing).unwrap();
    assert_eq!(a.title, "keep current");
    assert_eq!(a.tags, vec!["new", "tag"]);
    assert!(
        rows(
            &mut destination,
            Filter {
                query: "OCR 中文".into(),
                ..Default::default()
            }
        )
        .iter()
        .any(|r| r.kind == Kind::Image)
    );
    let r = destination
        .import_backup(&backup, RestoreMode::Replace, 100)
        .unwrap();
    assert_eq!(r.items, 2);
    assert!(
        rows(
            &mut destination,
            Filter {
                query: "other".into(),
                ..Default::default()
            }
        )
        .is_empty()
    );
}
#[test]
fn invalid_import_rolls_back_even_replace_and_future_schema_is_protected() {
    let d = tempfile::tempdir().unwrap();
    let backup = d.path().join("bad");
    let mut source = History::open(d.path().join("source"), Limits::default(), 100).unwrap();
    save(&mut source, "a", 1);
    save(&mut source, "b", 2);
    source.export_backup(&backup).unwrap();
    let c = rusqlite::Connection::open(&backup).unwrap();
    c.execute("UPDATE representations SET data=X'ff' WHERE entry_id=2", [])
        .unwrap();
    drop(c);
    let mut target = History::open(d.path().join("target"), Limits::default(), 100).unwrap();
    let id = save(&mut target, "keep", 1);
    assert!(
        target
            .import_backup(&backup, RestoreMode::Replace, 100)
            .is_err()
    );
    assert_eq!(target.payload(id).unwrap()[0].bytes, b"keep");
    let c = rusqlite::Connection::open(&backup).unwrap();
    c.execute_batch("PRAGMA user_version=99").unwrap();
    drop(c);
    assert!(matches!(
        target.import_backup(&backup, RestoreMode::Merge, 100),
        Err(Error::UnsupportedSchema)
    ));
}
#[test]
fn recovery_preserves_damaged_database_and_validates_backup_before_replacement() {
    let d = tempfile::tempdir().unwrap();
    let backup = d.path().join("backup");
    let damaged = d.path().join("damaged");
    let mut h = History::open(d.path().join("good"), Limits::default(), 100).unwrap();
    save(&mut h, "recover", 1);
    h.export_backup(&backup).unwrap();
    std::fs::write(&damaged, b"damaged database").unwrap();
    assert!(matches!(
        History::open(&damaged, Limits::default(), 100),
        Err(Error::Corrupt)
    ));
    recover_database(&damaged, &backup, Limits::default(), 100).unwrap();
    let mut recovered = History::open(&damaged, Limits::default(), 100).unwrap();
    assert_eq!(
        rows(&mut recovered, Filter::default())[0].preview,
        "recover"
    );
    assert!(std::fs::read_dir(d.path()).unwrap().any(|p| {
        p.unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("history-damaged-")
    }));
    assert!(recovered.export_backup(&damaged).is_err());
}
#[test]
fn failed_ocr_can_be_retried_and_expired_items_disappear_from_indexes() {
    let mut h = History::open(
        ":memory:",
        Limits {
            retention_days: 1,
            ..Default::default()
        },
        100,
    )
    .unwrap();
    let id = h
        .record_bundle(
            bundle(vec![item("image/png", b"\x89PNG\r\n\x1a\nfixture")], 1),
            &policy(),
        )
        .unwrap()
        .unwrap();
    h.mark_ocr_failed(id).unwrap();
    assert!(h.pending_ocr(10).unwrap().is_empty());
    h.retry_ocr().unwrap();
    assert_eq!(h.pending_ocr(10).unwrap(), vec![id]);
    h.store_ocr(id, "searchable", 100).unwrap();
    h.list("", false, 0, 100, 2 * 86400000).unwrap();
    assert!(h.annotation(id).is_err());
}
