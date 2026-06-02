//! Library entry for fnm-shim. The four binary targets (`fnm-shim`, `node`,
//! `npm`, `npx`) each delegate to [`entry`], which parses `argv[0]` and
//! dispatches.

pub mod cache;
pub mod cli;
pub mod error;
pub mod fnm_dir;
pub mod os;
pub mod resolver;

use std::process::ExitCode;

use crate::cli::Mode;
use crate::error::ShimError;

pub fn entry() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(clamp_exit(code)),
        Err(err) => {
            eprintln!("fnm-shim: {err}");
            ExitCode::from(127)
        }
    }
}

fn run() -> Result<i32, ShimError> {
    let argv0 = std::env::args_os().next().ok_or(ShimError::MissingArgv0)?;
    let mode = Mode::from_argv0(&argv0)?;

    let fnm_dir = fnm_dir::resolve()?;
    let targets = resolver::resolve(&fnm_dir)?;
    let target = mode.target(&targets);

    let args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    os::exec::run(target, &args).map_err(ShimError::Spawn)
}

#[inline]
fn clamp_exit(code: i32) -> u8 {
    if code < 0 { 128 } else { (code & 0xFF) as u8 }
}
