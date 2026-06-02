//! Integration test: verifies the canonical `fnm-shim` binary exits with a
//! clear "unsupported invocation" error when invoked under its own name.
//!
//! This exercises the full main() pipeline without requiring `fnm` to be
//! installed on the test runner.

use std::process::Command;

fn shim_path() -> std::path::PathBuf {
    // CARGO sets this; cargo test always builds dependencies first.
    let mut p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    });
    p.push(if cfg!(windows) {
        "fnm-shim.exe"
    } else {
        "fnm-shim"
    });
    p
}

#[test]
fn canonical_invocation_errors_clearly() {
    let bin = shim_path();
    if !bin.exists() {
        // `cargo test` builds the lib's test binary but not necessarily the
        // bin binary in older cargo versions. Build it explicitly.
        let status = Command::new(env!("CARGO"))
            .args(["build", "--bin", "fnm-shim"])
            .status()
            .expect("cargo build");
        assert!(status.success(), "failed to build fnm-shim bin");
    }
    assert!(bin.exists(), "expected built binary at {}", bin.display());

    let out = Command::new(&bin).output().expect("spawn fnm-shim");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "expected non-zero exit");
    assert!(
        stderr.to_lowercase().contains("unsupported invocation"),
        "expected 'unsupported invocation' in stderr, got: {stderr}"
    );
}
