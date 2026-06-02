//! Cross-platform child process execution that transparently forwards stdio
//! and surfaces the exact exit code.

use std::ffi::OsString;
use std::path::Path;

/// Run `program` with `args`, inheriting stdio. Returns the child's exit code.
///
/// On Unix this `exec`s in-place, replacing the current process image. The
/// return only occurs on failure to exec; on success the process is replaced
/// and this function never returns.
///
/// On Windows we cannot replace the process image, so we spawn and wait, then
/// return the child's exit code byte-for-byte.
pub fn run(program: &Path, args: &[OsString]) -> std::io::Result<i32> {
    imp::run(program, args)
}

#[cfg(unix)]
mod imp {
    use std::ffi::OsString;
    use std::os::unix::process::CommandExt;
    use std::path::Path;
    use std::process::Command;

    pub fn run(program: &Path, args: &[OsString]) -> std::io::Result<i32> {
        // `exec` replaces the current process on success and only returns on
        // failure. This preserves PID, signals, and avoids a wait() round-trip.
        let err = Command::new(program).args(args).exec();
        Err(err)
    }
}

#[cfg(windows)]
mod imp {
    use std::ffi::OsString;
    use std::path::Path;
    use std::process::Command;

    pub fn run(program: &Path, args: &[OsString]) -> std::io::Result<i32> {
        // We've already resolved the absolute path WITH extension (.exe / .cmd),
        // so CreateProcess will accept it directly. stdio is inherited by
        // default. We deliberately do NOT pipe streams.
        let status = Command::new(program).args(args).status()?;
        // On Windows `ExitStatus::code()` is always `Some` for normal child
        // termination; the only way it can be `None` is if the OS reported a
        // non-standard status. Map that case to 1 deterministically.
        Ok(status.code().unwrap_or(1))
    }
}
