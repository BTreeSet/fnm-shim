//! Multicall dispatch: parse `argv[0]` into a typed `Mode`.

use std::ffi::OsStr;
use std::path::Path;

use crate::error::ShimError;
use crate::resolver::ResolvedTargets;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Node,
    Npm,
    Npx,
}

impl Mode {
    /// Derive the behavioral mode strictly from the binary's invocation name.
    ///
    /// On Windows this is case-insensitive and strips a `.exe` suffix.
    pub fn from_argv0(argv0: &OsStr) -> Result<Self, ShimError> {
        let path = Path::new(argv0);
        // `file_stem` strips ONE extension; this gives us "node" from "node.exe"
        // and "node" from "node" alike. For platforms that allow weird suffixes
        // we additionally normalize.
        let stem = path.file_stem().and_then(|s| s.to_str()).ok_or_else(|| {
            ShimError::UnsupportedInvocation(argv0.to_string_lossy().into_owned())
        })?;

        let normalized = stem.to_ascii_lowercase();
        match normalized.as_str() {
            "node" => Ok(Mode::Node),
            "npm" => Ok(Mode::Npm),
            "npx" => Ok(Mode::Npx),
            // Special-case: invoked as the canonical binary name. Without a
            // routing target, fall through to a clear error.
            other => Err(ShimError::UnsupportedInvocation(other.to_string())),
        }
    }

    /// Total function: every `Mode` maps to exactly one resolved target. The
    /// type system guarantees no invalid combination is constructable.
    pub fn target<'t>(&self, targets: &'t ResolvedTargets) -> &'t Path {
        match self {
            Mode::Node => &targets.node,
            Mode::Npm => &targets.npm,
            Mode::Npx => &targets.npx,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    #[test]
    fn parses_plain_unix_names() {
        assert_eq!(Mode::from_argv0(OsStr::new("node")).unwrap(), Mode::Node);
        assert_eq!(Mode::from_argv0(OsStr::new("npm")).unwrap(), Mode::Npm);
        assert_eq!(Mode::from_argv0(OsStr::new("npx")).unwrap(), Mode::Npx);
    }

    #[test]
    fn parses_windows_exe_names_case_insensitively() {
        assert_eq!(
            Mode::from_argv0(OsStr::new("Node.EXE")).unwrap(),
            Mode::Node
        );
        assert_eq!(Mode::from_argv0(OsStr::new("NPM.exe")).unwrap(), Mode::Npm);
        assert_eq!(Mode::from_argv0(OsStr::new("npx.Exe")).unwrap(), Mode::Npx);
    }

    #[test]
    fn parses_from_unix_full_path() {
        let p: OsString = "/usr/local/bin/npm".into();
        assert_eq!(Mode::from_argv0(&p).unwrap(), Mode::Npm);
    }

    #[cfg(windows)]
    #[test]
    fn parses_from_windows_full_path() {
        let w: OsString = r"C:\Users\me\.fnm-shim\node.exe".into();
        assert_eq!(Mode::from_argv0(&w).unwrap(), Mode::Node);
    }

    #[test]
    fn rejects_unsupported_names() {
        let err = Mode::from_argv0(OsStr::new("invalid-shim")).unwrap_err();
        assert!(matches!(err, ShimError::UnsupportedInvocation(_)));
    }

    #[test]
    fn rejects_fnm_shim_self_invocation() {
        // The canonical name has no routing target; must error clearly.
        let err = Mode::from_argv0(OsStr::new("fnm-shim")).unwrap_err();
        assert!(matches!(err, ShimError::UnsupportedInvocation(_)));
    }
}
