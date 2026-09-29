//! Check GitHub releases for an independently packaged Rust preview.
//! Never offer a WPF release as an update for this executable.

use semver::Version;
use serde_json::Value;

const RELEASES_URL: &str = "https://api.github.com/repos/ldjx7/Polyglance/releases?per_page=20";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreviewRelease {
    pub version: Version,
    pub url: String,
}

fn parse_preview_release(releases: &Value, current: &Version) -> Option<PreviewRelease> {
    releases
        .as_array()?
        .iter()
        .filter_map(|release| {
            if release.get("draft")?.as_bool()? {
                return None;
            }
            let tag = release
                .get("tag_name")?
                .as_str()?
                .trim_start_matches(['v', 'V']);
            let version = Version::parse(tag).ok()?;
            if version <= *current {
                return None;
            }
            let has_preview_package = release.get("assets")?.as_array()?.iter().any(|asset| {
                asset
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|name| {
                        name.contains("Windows-Rust-")
                            && (name.ends_with("-Setup.exe") || name.ends_with("-Portable.zip"))
                    })
            });
            if !has_preview_package {
                return None;
            }
            Some(PreviewRelease {
                version,
                url: release.get("html_url")?.as_str()?.to_owned(),
            })
        })
        .max_by(|left, right| left.version.cmp(&right.version))
}

pub async fn check() -> Result<Option<PreviewRelease>, String> {
    let current = Version::parse(env!("CARGO_PKG_VERSION"))
        .map_err(|error| format!("当前版本号无效: {error}"))?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("Polyglance-Rust-Preview")
        .build()
        .map_err(|error| error.to_string())?;
    let response = client
        .get(RELEASES_URL)
        .send()
        .await
        .map_err(|error| format!("检查更新失败: {error}"))?
        .error_for_status()
        .map_err(|error| format!("更新服务返回错误: {error}"))?;
    let releases: Value = response
        .json()
        .await
        .map_err(|error| format!("无法解析更新信息: {error}"))?;
    Ok(parse_preview_release(&releases, &current))
}

#[cfg(test)]
mod tests {
    use super::parse_preview_release;
    use semver::Version;
    use serde_json::json;

    #[test]
    fn only_a_newer_rust_package_is_an_update() {
        let releases = json!([
            {"tag_name":"v1.3.0","draft":false,"html_url":"https://example.com/wpf","assets":[{"name":"Polyglance-Windows-x64-Setup.exe"}]},
            {"tag_name":"v1.2.0","draft":false,"html_url":"https://example.com/rust","assets":[{"name":"Polyglance-1.2.0-Windows-Rust-Portable.zip"}]},
            {"tag_name":"v1.1.0","draft":false,"html_url":"https://example.com/old","assets":[{"name":"Polyglance-1.1.0-Windows-Rust-Setup.exe"}]}
        ]);
        let found = parse_preview_release(&releases, &Version::parse("1.1.0").unwrap()).unwrap();
        assert_eq!(found.version, Version::parse("1.2.0").unwrap());
        assert_eq!(found.url, "https://example.com/rust");
    }

    #[test]
    fn no_rust_asset_does_not_report_wpf_release_as_current() {
        let releases = json!([{"tag_name":"v2.0.0","draft":false,"html_url":"https://example.com/wpf","assets":[{"name":"Polyglance-Windows-x64-Portable.zip"}]}]);
        assert!(parse_preview_release(&releases, &Version::parse("1.0.0").unwrap()).is_none());
    }
}
