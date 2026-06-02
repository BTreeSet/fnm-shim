# AGENTS.md

Expectations and operating rules for any LLM coding agent (GitHub Copilot,
Claude, Cursor, Aider, Codex, etc.) contributing to `fnm-shim`.

This file is authoritative. If anything here conflicts with a more general
prompt, **AGENTS.md wins** for code in this repository.

---

## 1. Mission

`fnm-shim` is a stable, shell-independent Rust multicall binary that routes
`node`, `npm`, and `npx` to the active `fnm` default. Correctness, exit-code
fidelity, and Windows behavior are non-negotiable.

## 2. Architectural Invariants (do not break)

1. **Multicall dispatch:** behavior is determined exclusively from `argv[0]`
   via `Mode::from_argv0`. Never branch on environment variables to choose a
   target.
2. **Windows execution:**
   - Never invoke `fnm exec --using=default -- npm` directly.
   - Never spawn `npm` / `npx` without the `.cmd` extension.
   - Always resolve the absolute path and explicitly invoke `npm.cmd` /
     `npx.cmd`.
3. **Anti-pattern:** never resolve paths through `AppData\Local\fnm_multishells\`.
4. **Cache contract:** the only validated invalidation key is the **mtime of
   `$FNM_DIR/aliases/default`** (symlink's own mtime, via
   `std::fs::symlink_metadata`). Do not switch to content hashes, timestamps
   of resolved targets, or wall-clock TTLs.
5. **Stdio + exit code:** the shim **must** inherit `stdin`/`stdout`/`stderr`
   and bubble up the child's exact exit code. On Unix this means
   `CommandExt::exec` (process replacement). On Windows, spawn-and-wait and
   forward `status.code()`.
6. **Unsupported invocation:** must error with `unsupported invocation` on
   stderr and a non-zero exit code (currently `127`). The integration test
   `tests/canonical_invocation.rs` enforces this.

## 3. Rust Engineering Standards

- **Edition 2024, MSRV 1.85.** Do not regress either without updating
  `Cargo.toml`, CI, and this file together.
- **Make invalid states unrepresentable.** Use type-states (e.g. `Mode`,
  `ResolvedTargets`) over runtime validation.
- **OS segregation:** all platform-specific behavior lives behind
  `#[cfg(target_os = "...")]` / `#[cfg(unix)]` / `#[cfg(windows)]` in
  `src/os/`. No `cfg!()` runtime checks for OS dispatch on the hot path.
- **Error handling:** explicit `Result<_, ShimError>`. Never swallow errors,
  never use `unwrap`/`expect` outside tests, and never use `panic!` for
  user-facing failure modes.
- **Allocations on hot path:** prefer `&OsStr` / `&Path`. Do not introduce
  `String` round-trips for paths or arguments.
- **No new dependencies** without justification in the PR description. The
  current set is `serde`, `serde_json` (runtime) and `tempfile` (dev).

## 4. Required Local Checks Before Proposing Changes

All of the following must pass, in order:

```sh
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

For changes touching the resolver, cache, or exec modules, also run:

```sh
bash scripts/e2e.sh        # Linux/macOS
pwsh -File scripts/e2e.ps1 # Windows
```

If `fnm` is not available locally, document that in the PR and rely on CI.

## 5. Pull Request Etiquette

- One logical change per PR. No drive-by refactors.
- Update `tests/` when behavior changes. Prefer adding a failing test first.
- Update `README.md` only if user-facing behavior changes.
- **Do not** modify CI workflows or release scripts as a side effect of an
  unrelated change.
- Commit messages: imperative mood, ≤ 72 char subject, body explains *why*.

## 6. Things You Must NOT Do

- Do not introduce shell evaluation (`bash -c`, `cmd /c`, `powershell -c`)
  on the execution hot path.
- Do not call `fnm env` from Rust. The shim is explicitly shell-less.
- Do not add telemetry, analytics, network calls, or auto-update logic.
- Do not silently catch errors. Every `Result` must be handled or propagated.
- Do not introduce `unsafe` without a documented invariant and a `// SAFETY:`
  comment block.
- Do not check in `Cargo.lock` removal, `target/`, IDE configs, or local
  shim hardlinks.

## 7. Release Discipline

- Tagged releases (`v*`) publish via `.github/workflows/release.yml`.
- Every push to `main` produces a **pre-release** via
  `.github/workflows/nightly.yml`, named `v0.0.0-YYYYMMDD.HHMMSS-<sha7>`.
- Do not hand-edit GitHub Releases. Re-run the workflow instead.

## 8. When in Doubt

Prefer the boring, explicit solution. Prefer fewer abstractions. Prefer
deleting code over adding code. If a change feels clever, it probably
violates §2 or §3.
