//! Metadata-validated file cache for resolved fnm executable paths.
//!
//! The cache stores absolute paths to `node`, `npm`, and `npx`, keyed by the
//! `mtime` of the fnm default alias symlink. When the user runs `fnm default
//! <ver>`, that symlink's mtime changes, automatically invalidating the cache.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CacheRecord {
    /// Symlink mtime as nanoseconds since UNIX_EPOCH. Stored as string to
    /// preserve full u128 precision across JSON.
    pub default_mtime_nanos: String,
    pub node: PathBuf,
    pub npm: PathBuf,
    pub npx: PathBuf,
}

pub fn cache_path() -> PathBuf {
    std::env::temp_dir().join("fnm-shim-cache.json")
}

/// Returns the symlink's own mtime (not the target's). This is intentional:
/// when fnm rewrites the symlink, its own metadata changes.
pub fn symlink_mtime(symlink: &Path) -> std::io::Result<SystemTime> {
    let md = std::fs::symlink_metadata(symlink)?;
    md.modified()
}

pub fn mtime_to_nanos(t: SystemTime) -> u128 {
    match t.duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => d.as_nanos(),
        // Pre-epoch (shouldn't happen on real filesystems); use 0.
        Err(_) => 0,
    }
}

pub fn read(path: &Path) -> Option<CacheRecord> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

pub fn write(path: &Path, record: &CacheRecord) -> std::io::Result<()> {
    // Atomic-ish write: serialize to sibling temp, rename into place.
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let tmp = path.with_extension("json.tmp");
    let data = serde_json::to_vec(record)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(&tmp, &data)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn record_roundtrips_via_json() {
        let r = CacheRecord {
            default_mtime_nanos: "1234567890".into(),
            node: PathBuf::from("/x/node"),
            npm: PathBuf::from("/x/npm"),
            npx: PathBuf::from("/x/npx"),
        };
        let b = serde_json::to_vec(&r).unwrap();
        let r2: CacheRecord = serde_json::from_slice(&b).unwrap();
        assert_eq!(r, r2);
    }

    #[test]
    fn nanos_conversion_handles_known_value() {
        // NOTE: must be aligned to 100ns because Windows `SystemTime` is
        // backed by `FILETIME` (100ns granularity). Sub-100ns components are
        // truncated on construction, which would otherwise make this test
        // flake on Windows runners.
        let t = UNIX_EPOCH + Duration::from_nanos(42_000_000_100);
        assert_eq!(mtime_to_nanos(t), 42_000_000_100u128);
    }

    #[test]
    fn write_then_read_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("c.json");
        let r = CacheRecord {
            default_mtime_nanos: "9".into(),
            node: PathBuf::from("/a"),
            npm: PathBuf::from("/b"),
            npx: PathBuf::from("/c"),
        };
        write(&p, &r).unwrap();
        let r2 = read(&p).unwrap();
        assert_eq!(r, r2);
    }
}
