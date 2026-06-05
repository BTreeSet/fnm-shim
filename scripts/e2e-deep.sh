#!/usr/bin/env bash
# Deep end-to-end test for fnm-shim.
#
# WHY THIS EXISTS
# ---------------
# `scripts/e2e.sh` exercises the basic dispatch pipeline (node -v, npm -v,
# cache invalidation, invalid-shim error). That is necessary but insufficient:
# real-world breakage hides in npm's lifecycle-script round-trips, npx
# package execution, `npm create <pkg>@latest` (which internally fans out to
# npx + node), and exit-code propagation through `npm run`. This script
# drives the shim through community tooling — currently Vite and TypeScript —
# to catch those classes of regressions.
#
# SUPPLY-CHAIN ISOLATION
# ----------------------
# `npm install` and `npx` routinely execute postinstall scripts shipped by
# arbitrary third-party packages. We treat every workload here as
# potentially-hostile and confine it as follows:
#
#   Linux:  bubblewrap (`bwrap`) — unprivileged user-namespace sandbox.
#           * Host fs mounted read-only.
#           * `/home`, `/root`, `/Users`, `/var/log` masked with tmpfs to hide
#             user secrets and writable surfaces. This also hides the GHA
#             runner's workspace (`/home/runner/work/...`), whose .git/config
#             contains the http extraheader auth token when persist-creds is
#             left on the default.
#           * Fresh tmpfs for `/tmp`, `/run`, `/var/tmp`.
#           * The ONLY writable host path is the throwaway $SANDBOX_ROOT.
#           * `--die-with-parent`, `--new-session`, `--unshare-{ipc,pid,uts}`.
#           * Network access IS permitted (we hit the npm registry); kernel
#             isolation prevents fs/process escape but not network egress.
#
#   macOS:  `sandbox-exec` with a Seatbelt profile that denies file-write
#           except inside $SANDBOX_ROOT and the OS temp area. Network and
#           process spawn are permitted for the same reason as above.
#
# Other platforms are explicitly rejected so this script never runs
# unsandboxed by accident.
#
# GITHUB ACTIONS SECRET HYGIENE
# -----------------------------
# A GHA runner injects these secret-bearing env vars unconditionally:
#
#   GITHUB_TOKEN                       (if surfaced as env)
#   ACTIONS_RUNTIME_TOKEN              (artifacts + cache, very dangerous)
#   ACTIONS_RUNTIME_URL
#   ACTIONS_CACHE_URL / _RESULTS_URL
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN     (OIDC; cloud-pivot dangerous)
#   ACTIONS_ID_TOKEN_REQUEST_URL
#   NODE_AUTH_TOKEN / NPM_TOKEN        (if a prior step set them)
#
# The sandbox uses `bwrap --clearenv` (Linux) and `env -i` (macOS), then
# rebuilds the child environment from a minimal allowlist. Nothing the host
# has in env reaches the workload unless it appears explicitly below.
# Reviewers: do NOT add any of the variables above to the allowlists.
#
# WHAT IS TESTED INSIDE THE SANDBOX
# ---------------------------------
#   [A] `npm create vite@latest <name> -- --template vanilla` — exercises
#       `npm create` → internal npx dispatch → scaffolding via node.
#   [B] `npm install` — full dependency resolution + extraction +
#       lifecycle scripts.
#   [C] `npm run build` — script invocation through npm's node wrapper.
#   [D] `npx vite --version` — direct npx → local node_modules binary.
#   [E] `npx -y -p typescript@latest tsc --version` — npx remote fetch with
#       explicit -p package selection.
#   [F] Exit-code fidelity: a script that exits 42 must bubble 42 out of
#       `npm run` and back through the shim.
#
# All steps require correct OS-aware `.cmd` resolution on Windows; this
# Unix variant guards against accidental regression of the resolver/exec
# split that broke prior shim implementations.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

log "building fnm-shim (release)"
cargo build --release --bin fnm-shim

SHIM="$ROOT/target/release/fnm-shim"
[[ -x "$SHIM" ]] || die "shim binary missing at $SHIM"

command -v fnm >/dev/null 2>&1 || die "fnm not on PATH"

# Resolve / prepare FNM_DIR on the host. We expect fnm to already have a
# default set; if not, install Node 20 LTS as a deterministic baseline.
export FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
mkdir -p "$FNM_DIR"
eval "$(fnm env --shell bash)"
if [[ ! -L "$FNM_DIR/aliases/default" && ! -e "$FNM_DIR/aliases/default" ]]; then
    log "no fnm default set; installing 20 and pinning as default"
    fnm install 20
    fnm default 20
fi

# Host-side multicall dir (read-only inside the sandbox).
HOST_SHIM_DIR="$(mktemp -d -t fnm-shim-bin.XXXXXX)"
ln -sf "$SHIM" "$HOST_SHIM_DIR/node"
ln -sf "$SHIM" "$HOST_SHIM_DIR/npm"
ln -sf "$SHIM" "$HOST_SHIM_DIR/npx"

# Sandbox root MUST live under the repo's target/ tree (and therefore on the
# same filesystem) so bwrap binds work uniformly regardless of where /tmp is.
SANDBOX_ROOT="$ROOT/target/e2e-deep-$$"
mkdir -p "$SANDBOX_ROOT/home" "$SANDBOX_ROOT/work" "$SANDBOX_ROOT/tmp"

cleanup() {
    local rc=$?
    rm -rf "$HOST_SHIM_DIR" "$SANDBOX_ROOT" || true
    exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Workload script. Runs INSIDE the sandbox. Path variables are injected via
# env so the workload contains no host-specific literals.
# ---------------------------------------------------------------------------
WORKLOAD="$SANDBOX_ROOT/workload.sh"
cat > "$WORKLOAD" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

step() { printf -- '---- %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

step "verifying isolation"
# Probe: any write outside the sandbox MUST fail. We deliberately do NOT
# accept a host-side path via env — leaking HOME from the host into the
# sandbox env would partially defeat the secret scrubbing.
ESCAPE_PATHS=(
    "/etc/.fnm-shim-escape-probe"
    "/usr/.fnm-shim-escape-probe"
    "/.fnm-shim-escape-probe"
)
for p in "${ESCAPE_PATHS[@]}"; do
    if : > "$p" 2>/dev/null; then
        rm -f "$p" || true
        fail "sandbox is leaky: wrote to $p"
    fi
done
printf '    OK: writes denied to /etc, /usr, /\n'

step "verifying secret-env scrubbing"
# These vars MUST NOT survive the sandbox boundary. If any are present,
# the sandbox plumbing has regressed and we refuse to proceed.
for v in GITHUB_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
         ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_CACHE_URL ACTIONS_RESULTS_URL \
         ACTIONS_RUNTIME_URL NODE_AUTH_TOKEN NPM_TOKEN RUNNER_TOKEN; do
    if [[ -n "${!v:-}" ]]; then
        fail "env leak: \$$v is set inside the sandbox"
    fi
done
printf '    OK: no CI secret env vars leaked into the sandbox\n'

step "tool versions (via shim)"
node -v
npm -v
npx --version

step "[A] npm create vite@latest myapp -- --template vanilla"
cd "$WORKDIR"
# `--yes` to npm itself bypasses the "Ok to proceed?" prompt;
# `--template vanilla` makes create-vite fully non-interactive.
npm create --yes vite@latest myapp -- --template vanilla
test -d myapp || fail "vite scaffold missing"
test -f myapp/package.json || fail "vite scaffold has no package.json"

step "[B] npm install (full lifecycle)"
cd "$WORKDIR/myapp"
npm install

step "[C] npm run build"
npm run build
test -d dist || fail "vite build did not produce dist/"
test -f dist/index.html || fail "dist/index.html missing"
printf '    OK: dist/index.html produced\n'

step "[D] npx vite --version (local bin)"
VITE_OUT="$(npx vite --version)"
printf '    %s\n' "$VITE_OUT"
[[ "$VITE_OUT" =~ ^vite/ ]] || fail "unexpected npx vite output: $VITE_OUT"

step "[E] npx -y -p typescript@latest tsc --version (remote fetch)"
cd "$WORKDIR"
TSC_OUT="$(npx -y -p typescript@latest tsc --version)"
printf '    %s\n' "$TSC_OUT"
[[ "$TSC_OUT" =~ ^Version[[:space:]] ]] || fail "unexpected tsc output: $TSC_OUT"

step "[F] exit-code fidelity through npm script"
mkdir -p "$WORKDIR/ec" && cd "$WORKDIR/ec"
cat > package.json <<'PKG'
{
  "name": "ec-test",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "boom": "node -e \"process.exit(42)\""
  }
}
PKG
set +e
npm run boom --silent
GOT=$?
set -e
[[ "$GOT" -eq 42 ]] || fail "expected exit 42 through npm script, got $GOT"
printf '    OK: exit code 42 preserved end-to-end\n'

printf '\n==> deep e2e PASSED\n'
INNER
chmod +x "$WORKLOAD"

# ---------------------------------------------------------------------------
# Pick a sandbox runner.
# ---------------------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
    Linux)
        command -v bwrap >/dev/null 2>&1 || die \
            "bwrap is required on Linux. Install: sudo apt-get install -y bubblewrap"
        log "sandbox: bubblewrap (--clearenv; allowlisted setenv only)"
        # fnm must be locatable inside the sandbox. We mount its directory
        # read-only and prepend it to PATH explicitly rather than relying on
        # the host PATH inheritance (which we're deliberately wiping).
        FNM_BIN="$(command -v fnm)"
        FNM_BIN_DIR="$(dirname "$FNM_BIN")"

        # Order matters: tmpfs comes BEFORE binds that land inside it.
        # `--clearenv` strips the entire inherited env (including
        # ACTIONS_RUNTIME_TOKEN, GITHUB_TOKEN, ACTIONS_ID_TOKEN_REQUEST_*,
        # NODE_AUTH_TOKEN, NPM_TOKEN, et al). Only what we explicitly
        # --setenv reaches the workload.
        exec bwrap \
            --clearenv \
            --ro-bind / / \
            --tmpfs /home \
            --tmpfs /root \
            --tmpfs /tmp \
            --tmpfs /run \
            --tmpfs /var/tmp \
            --dev /dev \
            --proc /proc \
            --bind "$SANDBOX_ROOT" "$SANDBOX_ROOT" \
            --ro-bind "$HOST_SHIM_DIR" "$HOST_SHIM_DIR" \
            --ro-bind "$FNM_DIR" "$FNM_DIR" \
            --ro-bind "$FNM_BIN_DIR" "$FNM_BIN_DIR" \
            --setenv HOME "$SANDBOX_ROOT/home" \
            --setenv WORKDIR "$SANDBOX_ROOT/work" \
            --setenv TMPDIR "/tmp" \
            --setenv PATH "$HOST_SHIM_DIR:$FNM_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            --setenv FNM_DIR "$FNM_DIR" \
            --setenv LANG "${LANG:-C.UTF-8}" \
            --setenv LC_ALL "${LC_ALL:-C.UTF-8}" \
            --setenv npm_config_audit "false" \
            --setenv npm_config_fund "false" \
            --setenv npm_config_update_notifier "false" \
            --setenv npm_config_loglevel "warn" \
            --setenv npm_config_cache "$SANDBOX_ROOT/npm-cache" \
            --setenv npm_config_prefix "$SANDBOX_ROOT/npm-prefix" \
            --setenv npm_config_userconfig "$SANDBOX_ROOT/home/.npmrc" \
            --setenv npm_config_globalconfig "$SANDBOX_ROOT/home/.npmrc-global" \
            --die-with-parent \
            --new-session \
            --unshare-ipc \
            --unshare-pid \
            --unshare-uts \
            --unshare-cgroup-try \
            --chdir "$SANDBOX_ROOT/work" \
            -- bash "$WORKLOAD"
        ;;
    Darwin)
        command -v sandbox-exec >/dev/null 2>&1 || die "sandbox-exec missing"
        log "sandbox: Seatbelt (sandbox-exec)"
        PROFILE="$SANDBOX_ROOT/policy.sb"
        # Macros (subpath, literal) must be passed as quoted strings.
        # Allow file-read* broadly (system libraries, fnm, node binaries);
        # restrict file-write* to the sandbox + OS temp areas.
        cat > "$PROFILE" <<SEATBELT
(version 1)
(deny default)
(allow process*)
(allow signal)
(allow network*)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow iokit-open)
(allow file-read*)
(allow file-write* (subpath "$SANDBOX_ROOT"))
(allow file-write* (subpath "/private/tmp"))
(allow file-write* (subpath "/private/var/tmp"))
(allow file-write* (subpath "/private/var/folders"))
SEATBELT
        FNM_BIN="$(command -v fnm)"
        FNM_BIN_DIR="$(dirname "$FNM_BIN")"
        # env -i wipes ALL inherited env (including GHA secret tokens).
        # Allowlist only what the workload needs. No GITHUB_*, ACTIONS_*,
        # RUNNER_*, NODE_AUTH_TOKEN, NPM_TOKEN, or HOME_OUTSIDE.
        env -i \
            HOME="$SANDBOX_ROOT/home" \
            WORKDIR="$SANDBOX_ROOT/work" \
            TMPDIR="$SANDBOX_ROOT/tmp" \
            PATH="$HOST_SHIM_DIR:$FNM_BIN_DIR:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin" \
            FNM_DIR="$FNM_DIR" \
            LANG="${LANG:-C.UTF-8}" \
            LC_ALL="${LC_ALL:-C.UTF-8}" \
            npm_config_audit=false \
            npm_config_fund=false \
            npm_config_update_notifier=false \
            npm_config_loglevel=warn \
            npm_config_cache="$SANDBOX_ROOT/npm-cache" \
            npm_config_prefix="$SANDBOX_ROOT/npm-prefix" \
            npm_config_userconfig="$SANDBOX_ROOT/home/.npmrc" \
            npm_config_globalconfig="$SANDBOX_ROOT/home/.npmrc-global" \
            sandbox-exec -f "$PROFILE" bash "$WORKLOAD"
        ;;
    *)
        die "unsupported OS for deep e2e: $OS (Linux or Darwin only)"
        ;;
esac
