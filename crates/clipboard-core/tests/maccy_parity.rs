use clipboard_core::*;

fn policy() -> CapturePolicy { CapturePolicy { enabled:true, ..Default::default() } }
fn text(value:&str,time:u64) -> Input {
    Input { representations:vec![Representation {format:"text/plain".into(),bytes:value.as_bytes().to_vec()}],source_application:"test.app".into(),observed_types:vec![],copied_at_ms:time }
}
fn history() -> History { History::open(":memory:",Limits::default(),100).unwrap() }

#[test]
fn exclusions_are_applied_to_full_text_before_storage() {
    let mut h=history();
    let p=CapturePolicy { ignored_patterns:vec![r"(?i)^secret:".into(),"密码".into()], ..policy() };
    assert_eq!(h.record(text("SECRET: don't retain",1),&p).unwrap(),None);
    assert_eq!(h.record(text("用户密码",2),&p).unwrap(),None);
    assert!(h.record(text("ordinary",3),&p).unwrap().is_some());
    assert_eq!(h.stats().unwrap().items,1);
    assert!(validate_ignored_patterns(&["[".into()]).is_err());
    assert!(validate_ignored_patterns(&vec!["a".into();33]).is_err());
    let invalid=CapturePolicy {ignored_patterns:vec!["[".into()],..policy()};
    assert!(matches!(h.record(text("must not be stored",4),&invalid),Err(Error::InvalidPattern)));
    assert_eq!(h.stats().unwrap().items,1);
}

#[test]
fn matching_any_item_excludes_the_whole_bundle() {
    let mut h=history();
    let p=CapturePolicy { ignored_patterns:vec!["token=".into()],..policy() };
    let input=BundleInput {items:vec![ClipboardItem {representations:text("normal",1).representations},ClipboardItem {representations:text("token=abc",1).representations}],source_application:"test.app".into(),observed_types:vec![],copied_at_ms:1};
    assert_eq!(h.record_bundle(input,&p).unwrap(),None);
    assert_eq!(h.stats().unwrap().items,0);
}

#[test]
fn editing_keeps_id_annotations_pin_and_key_but_updates_search_and_formats() {
    let mut h=history();
    let mut input=text("before",1);
    input.representations.push(Representation {format:"text/html".into(),bytes:b"<b>before</b>".to_vec()});
    let id=h.record(input,&policy()).unwrap().unwrap();
    h.set_pinned(id,true,2).unwrap();
    h.set_annotation(id,"snippet",&["work".into()],3).unwrap();
    h.set_pin_shortcut(id,"B").unwrap();
    h.edit_pinned_text(id,"修改后\ncomplete text",4).unwrap();
    let rows=h.list("修改后",false,0,100,4).unwrap();
    assert_eq!(rows.len(),1); assert_eq!(rows[0].id,id); assert!(rows[0].pinned);
    assert_eq!(h.annotation(id).unwrap().title,"snippet");
    assert_eq!(h.pin_shortcuts().unwrap()[0].key,"b");
    let payload=h.payload(id).unwrap(); assert_eq!(payload.len(),1); assert_eq!(payload[0].format,"text/plain");
    assert!(h.list("before",false,0,100,4).unwrap().is_empty());
    assert_eq!(h.record(text("修改后\ncomplete text",5),&policy()).unwrap(),Some(id));
}

#[test]
fn edits_reject_unpinned_blank_duplicate_and_over_capacity_without_data_loss() {
    let mut h=history();
    let first=h.record(text("keep",1),&policy()).unwrap().unwrap();
    let second=h.record(text("duplicate",2),&policy()).unwrap().unwrap();
    assert!(matches!(h.edit_pinned_text(first,"changed",3),Err(Error::InvalidInput)));
    h.set_pinned(first,true,3).unwrap();
    assert!(matches!(h.edit_pinned_text(first,"duplicate",4),Err(Error::ContentConflict)));
    assert!(h.edit_pinned_text(first,"   ",4).is_err());
    assert_eq!(h.payload(first).unwrap()[0].bytes,b"keep");
    assert_eq!(h.payload(second).unwrap()[0].bytes,b"duplicate");
    h.set_pinned(second,true,4).unwrap();
    let limits=Limits {maximum_items:2,maximum_bytes:100,maximum_item_bytes:100,retention_days:0};
    h.configure(limits,5).unwrap();
    assert!(h.edit_pinned_text(first,&"x".repeat(40),6).is_err());
    assert_eq!(h.payload(first).unwrap()[0].bytes,b"keep");
}

#[test]
fn pin_keys_are_unique_validated_and_removed_on_unpin_or_delete() {
    let mut h=history();
    let a=h.record(text("a",1),&policy()).unwrap().unwrap();
    let b=h.record(text("b",2),&policy()).unwrap().unwrap();
    h.set_pinned(a,true,3).unwrap(); h.set_pinned(b,true,3).unwrap();
    h.set_pin_shortcut(a,"b").unwrap();
    assert!(matches!(h.set_pin_shortcut(b,"b"),Err(Error::ShortcutConflict)));
    assert!(h.set_pin_shortcut(b,"v").is_err());
    h.set_pinned(a,false,4).unwrap(); h.set_pin_shortcut(b,"b").unwrap();
    h.delete(b).unwrap(); assert!(h.pin_shortcuts().unwrap().is_empty());
}

#[test]
fn clearing_only_removes_the_exact_capture_even_when_pinned() {
    let mut h=history();
    let id=h.record(text("temporary",1),&policy()).unwrap().unwrap();
    let old=h.capture_token(id).unwrap();
    h.record(text("temporary",2),&policy()).unwrap();
    assert!(!h.delete_if_capture_matches(id,&old).unwrap());
    let current=h.capture_token(id).unwrap();
    h.set_pinned(id,true,3).unwrap();
    h.edit_pinned_text(id,"edited",4).unwrap();
    assert!(!h.delete_if_capture_matches(id,&current).unwrap());
    let edited=h.capture_token(id).unwrap();
    assert!(h.delete_if_capture_matches(id,&edited).unwrap());
    assert!(!h.delete_if_capture_matches(id,&edited).unwrap());
}

#[test]
fn pin_keys_survive_reopen_backup_and_merge_conflicts_preserve_existing_keys() {
    let directory=tempfile::tempdir().unwrap(); let path=directory.path().join("history.sqlite3"); let backup=directory.path().join("backup.sqlite3");
    let mut source=History::open(&path,Limits::default(),100).unwrap();
    let id=source.record(text("saved",1),&policy()).unwrap().unwrap();
    source.set_pinned(id,true,2).unwrap(); source.set_pin_shortcut(id,"b").unwrap();
    source.export_backup(&backup).unwrap(); drop(source);
    assert_eq!(History::open(&path,Limits::default(),100).unwrap().pin_shortcuts().unwrap()[0].key,"b");
    let mut target=history();
    let own=target.record(text("own",1),&policy()).unwrap().unwrap();
    target.set_pinned(own,true,2).unwrap(); target.set_pin_shortcut(own,"b").unwrap();
    target.import_backup(&backup,RestoreMode::Merge,100).unwrap();
    assert_eq!(target.stats().unwrap().items,2);
    assert_eq!(target.pin_shortcuts().unwrap(),vec![PinShortcut {entry_id:own,key:"b".into()}]);
    target.import_backup(&backup,RestoreMode::Replace,100).unwrap();
    assert_eq!(target.pin_shortcuts().unwrap()[0].key,"b");
}

#[test]
fn v2_history_migrates_without_changing_payloads_or_pins() {
    let directory=tempfile::tempdir().unwrap(); let path=directory.path().join("v2.sqlite3");
    let mut h=History::open(&path,Limits::default(),100).unwrap();
    let id=h.record(text("legacy",1),&policy()).unwrap().unwrap(); h.set_pinned(id,true,2).unwrap(); drop(h);
    let connection=rusqlite::Connection::open(&path).unwrap(); connection.execute_batch("DROP TABLE pin_shortcuts; PRAGMA user_version=2;").unwrap(); drop(connection);
    let mut h=History::open(&path,Limits::default(),100).unwrap();
    assert_eq!(h.payload(id).unwrap()[0].bytes,b"legacy"); assert!(h.list("",false,0,100,100).unwrap()[0].pinned);
    h.set_pin_shortcut(id,"b").unwrap();
}
