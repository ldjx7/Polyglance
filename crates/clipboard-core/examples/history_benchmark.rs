//! Disk-backed synthetic workload. Never opens the application's history or system clipboard.
use clipboard_core::{CapturePolicy, Filter, History, Input, Kind, Limits, Representation};
use serde_json::{Value, json};
use std::{error::Error, hint::black_box, time::Instant};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn input(index: u32, time: u64) -> Input {
    let text = format!(
        "entry-{index:05}\n中文测试，保留换行与空格。\n{}",
        "Clipboard history search and replay sample. ".repeat(16)
    );
    let mut representations = vec![Representation {
        format: "text/plain".into(),
        bytes: text.as_bytes().to_vec(),
    }];
    if index % 4 == 0 {
        representations.push(Representation {
            format: "text/html".into(),
            bytes: format!("<pre>{text}</pre>").into_bytes(),
        });
    }
    Input {
        representations,
        source_application: format!("benchmark.app.{}", index % 8),
        observed_types: vec![],
        copied_at_ms: time,
    }
}

fn measure(samples: u32, mut operation: impl FnMut() -> Result<()>) -> Result<Value> {
    // Warm the same operation explicitly; these are warm-process timings, not cold startup.
    for _ in 0..5 {
        operation()?;
    }
    let mut elapsed = Vec::with_capacity(samples as usize);
    for _ in 0..samples {
        let start = Instant::now();
        operation()?;
        elapsed.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    elapsed.sort_by(f64::total_cmp);
    let percentile = |p: f64| elapsed[((elapsed.len() as f64 * p).ceil() as usize) - 1];
    Ok(json!({
        "samples": samples,
        "min": elapsed[0],
        "median": percentile(0.5),
        "p95": percentile(0.95),
        "p99": percentile(0.99),
        "max": elapsed[elapsed.len() - 1],
        "mean": elapsed.iter().sum::<f64>() / elapsed.len() as f64,
    }))
}

fn main() -> Result<()> {
    let (mut items, mut samples) = (500u32, 100u32);
    let mut fixture_directory = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--items" => items = args.next().ok_or("--items requires a value")?.parse()?,
            "--samples" => samples = args.next().ok_or("--samples requires a value")?.parse()?,
            "--export-fixture" => {
                fixture_directory = Some(std::path::PathBuf::from(
                    args.next()
                        .ok_or("--export-fixture requires a new directory")?,
                ));
            }
            "--help" => {
                println!(
                    "history_benchmark [--items 100..10000] [--samples 1..1000] [--export-fixture NEW_DIRECTORY]\nWrites a JSON report to stdout; uses a disposable temporary database.\nOptional fixture export creates a new directory and never replaces an existing directory."
                );
                return Ok(());
            }
            _ => return Err(format!("unknown argument: {arg}").into()),
        }
    }
    if !(100..=10_000).contains(&items) || !(1..=1000).contains(&samples) {
        return Err("items must be 100..10000 and samples must be 1..1000".into());
    }
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("synthetic-history.sqlite3");
    let now = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_millis(),
    )?;
    let mut history = History::open(
        &path,
        Limits {
            maximum_items: items,
            retention_days: 0,
            ..Limits::default()
        },
        now,
    )?;
    let policy = CapturePolicy {
        enabled: true,
        ..Default::default()
    };
    let population_start = Instant::now();
    for index in 0..items {
        let id = history
            .record(input(index, now - u64::from(items - index)), &policy)?
            .ok_or("capture rejected")?;
        if index % 10 == 0 {
            history.set_annotation(
                id,
                &format!("示例 {index}"),
                &[format!("组{}", index % 4)],
                now,
            )?;
        }
        if index % 20 == 0 {
            history.set_pinned(id, true, now)?;
        }
    }
    let population_ms = population_start.elapsed().as_secs_f64() * 1000.0;
    if history.stats()?.items != items {
        return Err("synthetic dataset unexpectedly exceeded the byte budget".into());
    }
    let needle = format!("entry-{:05}", items / 2);
    let selected = history.list(&needle, false, 0, 100, now)?;
    if selected.len() != 1 {
        return Err("synthetic search fixture must match exactly one entry".into());
    }
    let selected_id = selected[0].id;
    let mut measurements = serde_json::Map::new();
    for (name, query, offset) in [
        ("first_page", "", 0),
        ("last_page", "", items - 100),
        ("search_one", needle.as_str(), 0),
        ("search_chinese", "中文测试", 0),
        ("search_missing", "not-present-7d53", 0),
    ] {
        measurements.insert(
            name.into(),
            measure(samples, || {
                let rows = history.list(query, false, offset, 100, now)?;
                let expected = match name {
                    "search_one" => 1,
                    "search_missing" => 0,
                    _ => 100,
                };
                if rows.len() != expected {
                    return Err("unexpected search/page result".into());
                }
                black_box(rows);
                Ok(())
            })?,
        );
    }
    let filter = Filter {
        kind: Some(Kind::Text),
        source: Some("benchmark.app.0".into()),
        tag: Some("组0".into()),
        ..Default::default()
    };
    measurements.insert(
        "combined_filter".into(),
        measure(samples, || {
            let rows = history.list_filtered(&filter, 0, 100, now)?;
            if rows.is_empty() {
                return Err("combined filter fixture must have matches".into());
            }
            black_box(rows);
            Ok(())
        })?,
    );
    // Mirrors the native refresh's database calls, excluding actor, FFI and UI costs.
    measurements.insert(
        "refresh_database_calls".into(),
        measure(samples, || {
            black_box(history.list("", false, 0, 100, now)?);
            black_box(history.stats()?);
            black_box(history.pin_shortcuts()?);
            black_box(history.sources()?);
            black_box(history.tags()?);
            Ok(())
        })?,
    );
    measurements.insert(
        "read_selected_payload".into(),
        measure(samples, || {
            black_box(history.bundle(selected_id)?);
            black_box(history.annotation(selected_id)?);
            Ok(())
        })?,
    );
    let duplicate = input(items / 2, now);
    measurements.insert(
        "record_duplicate".into(),
        measure(samples, || {
            if history.record(duplicate.clone(), &policy)? != Some(selected_id) {
                return Err("duplicate must retain its entry ID".into());
            }
            Ok(())
        })?,
    );
    let mut next = items;
    measurements.insert(
        "record_new_with_eviction".into(),
        measure(samples, || {
            let record = input(next, now);
            next += 1;
            if history.record(record, &policy)?.is_none() {
                return Err("capture rejected".into());
            }
            Ok(())
        })?,
    );
    let stats = history.stats()?;
    if stats.items != items {
        return Err("eviction must maintain the configured item count".into());
    }
    if let Some(directory) = &fixture_directory {
        // create_dir fails atomically for an existing directory; only synthetic data is exported.
        std::fs::create_dir(directory)?;
        let backup = directory.join(format!("clipboard-{items}.polyclipboard"));
        history.export_backup(&backup)?;
        let mut restored = History::open(
            ":memory:",
            Limits {
                maximum_items: items,
                ..Limits::default()
            },
            now,
        )?;
        if restored
            .import_backup(backup, clipboard_core::RestoreMode::Replace, now)?
            .items
            != items
        {
            return Err(
                "fixture must restore its full item count with the default retention period".into(),
            );
        }
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "schema_version": 1,
            "workload": "clipboard-text-rich-metadata-v1",
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "available_parallelism": std::thread::available_parallelism()?.get(),
            "debug_assertions": cfg!(debug_assertions),
            "commit": std::env::var("GITHUB_SHA").ok(),
            "generated_at_ms": now,
            "items": items,
            "page_size": 100,
            "warmup_iterations": 5,
            "population_ms": population_ms,
            "database_file_bytes": std::fs::metadata(&path)?.len(),
            "accounted_content_bytes": stats.bytes,
            "measurements_ms": measurements,
        }))?
    );
    Ok(())
}
