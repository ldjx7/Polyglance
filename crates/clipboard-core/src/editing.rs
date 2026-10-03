use super::*;
use rusqlite::OptionalExtension;

impl History {
    pub fn pin_shortcuts(&self) -> Result<Vec<PinShortcut>, Error> {
        let mut s = self.connection.prepare("SELECT s.entry_id,s.key FROM pin_shortcuts s JOIN entries e ON e.id=s.entry_id WHERE e.pinned=1 ORDER BY s.key")?;
        s.query_map([], |r| Ok(PinShortcut { entry_id: r.get::<_,i64>(0)? as u64, key: r.get(1)? }))?
            .collect::<Result<Vec<_>,_>>().map_err(Into::into)
    }

    pub fn set_pin_shortcut(&mut self, id: u64, key: &str) -> Result<(), Error> {
        let key = validate_pin_shortcut(key)?;
        let tx = self.connection.transaction()?;
        let pinned: Option<bool> = tx.query_row("SELECT pinned FROM entries WHERE id=?1", [timestamp(id)?], |r| r.get(0)).optional()?;
        match pinned { None => return Err(Error::NotFound), Some(false) => return Err(Error::InvalidInput), _ => {} }
        if key.is_empty() { tx.execute("DELETE FROM pin_shortcuts WHERE entry_id=?1", [timestamp(id)?])?; }
        else {
            let conflict: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM pin_shortcuts WHERE key=?1 AND entry_id!=?2)", params![key,timestamp(id)?], |r| r.get(0))?;
            if conflict { return Err(Error::ShortcutConflict); }
            tx.execute("INSERT INTO pin_shortcuts VALUES (?1,?2) ON CONFLICT(entry_id) DO UPDATE SET key=excluded.key", params![timestamp(id)?,key])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Editing changes a text snippet to plain text. Conflicts and capacity failures leave both records intact.
    pub fn edit_pinned_text(&mut self, id: u64, text: &str, now_ms: u64) -> Result<(), Error> {
        let (pinned, source, copied_at): (bool,String,u64) = self.connection.query_row(
            "SELECT pinned,source,copied_at FROM entries WHERE id=?1", [timestamp(id)?],
            |r| Ok((r.get(0)?,r.get(1)?,r.get::<_,i64>(2)? as u64)))
            .map_err(|e| if matches!(e,rusqlite::Error::QueryReturnedNoRows) { Error::NotFound } else { e.into() })?;
        let old = self.bundle(id)?;
        if !pinned || old.len()!=1 || old[0].representations.iter().any(|r| !r.format.starts_with("text/") || r.format==FILE_FORMAT)
            || plain_text(&old).is_none() { return Err(Error::InvalidInput); }
        if plain_text(&old).as_deref()==Some(text) { return Ok(()); }
        let p = prepare(BundleInput { items: vec![ClipboardItem { representations: vec![Representation { format:"text/plain".into(), bytes:text.as_bytes().to_vec() }] }], source_application: source, observed_types:vec![], copied_at_ms:copied_at }, self.limits)?.ok_or(Error::InvalidInput)?;
        let annotation = self.annotation(id)?;
        let tx = self.connection.transaction()?;
        let conflict: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM entries WHERE fingerprint=?1 AND id!=?2)",params![p.fingerprint,timestamp(id)?],|r|r.get(0))?;
        if conflict { return Err(Error::ContentConflict); }
        tx.execute("UPDATE entries SET fingerprint=?1,preview=?2,search_text=?3,byte_count=?4 WHERE id=?5",params![p.fingerprint,p.preview,p.search,(p.byte_count+annotation_bytes(&annotation)) as i64,timestamp(id)?])?;
        tx.execute("DELETE FROM representations WHERE entry_id=?1",[timestamp(id)?])?;
        tx.execute("INSERT INTO representations VALUES (?1,0,'text/plain',?2)",params![timestamp(id)?,text.as_bytes()])?;
        enforce_limits(&tx,self.limits,now_ms,Some(id))?;
        tx.commit()?;
        self.reclaim_pages();
        Ok(())
    }

    pub fn capture_token(&self, id: u64) -> Result<String, Error> {
        self.connection.query_row("SELECT fingerprint || ':' || copied_at FROM entries WHERE id=?1", [timestamp(id)?], |r|r.get(0))
            .map_err(|e| if matches!(e,rusqlite::Error::QueryReturnedNoRows) { Error::NotFound } else { e.into() })
    }

    /// The native observer supplies the token from its last capture; a newer copy or edit cannot be removed accidentally.
    pub fn delete_if_capture_matches(&mut self, id: u64, token: &str) -> Result<bool, Error> {
        if token.len()>100 { return Err(Error::InvalidInput); }
        let deleted=self.connection.execute("DELETE FROM entries WHERE id=?1 AND fingerprint || ':' || copied_at=?2",params![timestamp(id)?,token])?>0;
        if deleted { self.reclaim_pages(); }
        Ok(deleted)
    }
}
