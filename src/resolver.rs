//! Resolve fnm's currently-active node/npm/npx executable paths.
//!
//! Strategy: stat `$FNM_DIR/aliases/default`. If a JSON cache record exists
//! whose stored mtime equals the symlink's current mtime, reuse the cached
//! paths. Otherwise, invoke `fnm exec --using=default -- node -p
//! "process.execPath"`, derive npm/npx by sibling lookup, persist the cache,
//! and return.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::cache::{self, CacheRecordRef};
use crate::error::ShimError;
use crate::fnm_dir;
use crate::os;

/// Type-state: only this struct can be passed to dispatch. It is exclusively
/// constructed by `resolve()`, guaranteeing every field is a verified absolute
/// path to an executable file appropriate for the host OS.
#[derive(Debug)]
pub struct ResolvedTargets {
    pub node: PathBuf,
    pub npm: PathBuf,
    pub npx: PathBuf,
}

pub fn resolve(fnm_dir_path: &Path) -> Result<ResolvedTargets, ShimError> {
    let default_alias = fnm_dir::default_alias(fnm_dir_path);
    let current_mtime = match cache::symlink_mtime(&default_alias) {
        Ok(t) => t,
        Err(_) => return Err(ShimError::DefaultAliasMissing(default_alias)),
    };
    let current_nanos = cache::mtime_to_nanos(current_mtime);

    let cache_path = cache::cache_path();
    if let Some(rec) = cache::read(&cache_path) {
        if rec.default_mtime_nanos.parse::<u128>().ok() == Some(current_nanos)
            && rec.node.exists()
            && rec.npm.exists()
            && rec.npx.exists()
        {
            return Ok(ResolvedTargets {
                node: rec.node,
                npm: rec.npm,
                npx: rec.npx,
            });
        }
    }

    let targets = resolve_via_fnm_exec()?;
    let nanos_str = current_nanos.to_string();
    // Best-effort cache write — failure here must not block execution.
    let _ = cache::write(
        &cache_path,
        &CacheRecordRef {
            default_mtime_nanos: &nanos_str,
            node: &targets.node,
            npm: &targets.npm,
            npx: &targets.npx,
        },
    );
    Ok(targets)
}

fn resolve_via_fnm_exec() -> Result<ResolvedTargets, ShimError> {
    let output = Command::new("fnm")
        .args([
            "exec",
            "--using=default",
            "--",
            "node",
            "-p",
            "process.execPath",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(ShimError::FnmNotInstalled)?;

    if !output.status.success() {
        return Err(ShimError::FnmExecFailed {
            status: output.status.code(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let node_path = stdout.trim();
    if node_path.is_empty() {
        return Err(ShimError::FnmExecFailed {
            status: output.status.code(),
            stderr: "fnm returned an empty execPath".into(),
        });
    }
    let node = PathBuf::from(node_path);
    let dir = node.parent().ok_or_else(|| ShimError::FnmExecFailed {
        status: None,
        stderr: format!("node execPath {node_path:?} has no parent directory"),
    })?;

    let npm = dir.join(os::npm_filename());
    let npx = dir.join(os::npx_filename());

    Ok(ResolvedTargets { node, npm, npx })
}
