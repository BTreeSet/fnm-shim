//! The canonical `fnm-shim` binary. Delegates to the shared library entry,
//! which intentionally errors when invoked under the canonical name (no
//! routing target). Useful for `--version` checks via a wrapper script or
//! diagnostic inspection.

fn main() -> std::process::ExitCode {
    fnm_shim::entry()
}
