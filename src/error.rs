use std::fmt;
use std::io;

#[derive(Debug)]
pub enum ShimError {
    MissingArgv0,
    UnsupportedInvocation(String),
    FnmDirNotFound,
    DefaultAliasMissing(std::path::PathBuf),
    FnmExecFailed { status: Option<i32>, stderr: String },
    FnmNotInstalled(io::Error),
    Io(io::Error),
    CacheWrite(io::Error),
    Spawn(io::Error),
}

impl fmt::Display for ShimError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ShimError::MissingArgv0 => write!(f, "argv[0] was not provided by the OS"),
            ShimError::UnsupportedInvocation(name) => write!(
                f,
                "unsupported invocation '{name}': fnm-shim only routes 'node', 'npm', or 'npx'"
            ),
            ShimError::FnmDirNotFound => write!(
                f,
                "could not determine FNM_DIR; set the FNM_DIR environment variable"
            ),
            ShimError::DefaultAliasMissing(p) => write!(
                f,
                "fnm default alias is missing at {} (run `fnm default <version>`)",
                p.display()
            ),
            ShimError::FnmExecFailed { status, stderr } => match status {
                Some(c) => write!(f, "`fnm exec` failed with exit code {c}: {}", stderr.trim()),
                None => write!(f, "`fnm exec` terminated by signal: {}", stderr.trim()),
            },
            ShimError::FnmNotInstalled(e) => {
                write!(f, "failed to invoke `fnm` (is it on PATH?): {e}")
            }
            ShimError::Io(e) => write!(f, "io error: {e}"),
            ShimError::CacheWrite(e) => write!(f, "failed to write cache: {e}"),
            ShimError::Spawn(e) => write!(f, "failed to spawn target process: {e}"),
        }
    }
}

impl std::error::Error for ShimError {}

impl From<io::Error> for ShimError {
    fn from(e: io::Error) -> Self {
        ShimError::Io(e)
    }
}
