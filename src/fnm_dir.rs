//! Locate the fnm configuration directory.
//!
//! Resolution order:
//!   1. `$FNM_DIR` (any OS).
//!   2. Windows: `%APPDATA%\fnm`.
//!   3. macOS:   `$HOME/Library/Application Support/fnm`.
//!   4. Linux:   `$XDG_DATA_HOME/fnm` or `$HOME/.local/share/fnm`.

use std::path::PathBuf;

use crate::error::ShimError;

pub fn resolve() -> Result<PathBuf, ShimError> {
    if let Some(dir) = std::env::var_os("FNM_DIR") {
        return Ok(PathBuf::from(dir));
    }
    platform_default().ok_or(ShimError::FnmDirNotFound)
}

#[cfg(target_os = "windows")]
fn platform_default() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|p| PathBuf::from(p).join("fnm"))
}

#[cfg(target_os = "macos")]
fn platform_default() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("fnm")
    })
}

#[cfg(all(unix, not(target_os = "macos")))]
fn platform_default() -> Option<PathBuf> {
    if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
        return Some(PathBuf::from(xdg).join("fnm"));
    }
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share/fnm"))
}

/// Path of the "default" alias symlink that fnm updates when `fnm default` runs.
pub fn default_alias(fnm_dir: &std::path::Path) -> PathBuf {
    fnm_dir.join("aliases").join("default")
}
