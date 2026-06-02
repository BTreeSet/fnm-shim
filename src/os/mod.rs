//! OS-segregated execution and filename details.

pub mod exec;

#[cfg(target_os = "windows")]
pub fn npm_filename() -> &'static str {
    "npm.cmd"
}
#[cfg(target_os = "windows")]
pub fn npx_filename() -> &'static str {
    "npx.cmd"
}

#[cfg(not(target_os = "windows"))]
pub fn npm_filename() -> &'static str {
    "npm"
}
#[cfg(not(target_os = "windows"))]
pub fn npx_filename() -> &'static str {
    "npx"
}
