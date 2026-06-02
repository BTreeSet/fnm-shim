# fnm-shim

A stable, shell-independent Rust multicall binary that routes `node`, `npm`,
and `npx` invocations to the currently-active [`fnm`](https://github.com/Schniz/fnm)
default Node.js installation — without depending on `fnm env` shell hooks.

> **Why?** IDEs, build daemons, GUI launchers, scheduled tasks, and Windows
> services frequently invoke `node`/`npm`/`npx` outside of an interactive
> shell. In those contexts `fnm`'s shell-evaluated `PATH` machinery is absent,
> and the legitimate active version is unreachable. `fnm-shim` provides a
> shell-less bridge.

## Install

1. Build (or download a prebuilt release) and place the binary anywhere on
   your `$PATH`.
2. Create entries named `node`, `npm`, and `npx` that point at the binary —
   symlinks, hardlinks, or plain copies all work.
3. Ensure your `fnm` directory is discoverable via `$FNM_DIR` or the platform
   default (`%APPDATA%\fnm` on Windows, `~/Library/Application Support/fnm` on
   macOS, `${XDG_DATA_HOME:-~/.local/share}/fnm` on Linux).
4. Set a default: `fnm default <version>`.

```sh
# Linux/macOS example
ln -sf "$(which fnm-shim)" ~/.local/bin/node
ln -sf "$(which fnm-shim)" ~/.local/bin/npm
ln -sf "$(which fnm-shim)" ~/.local/bin/npx
```

```powershell
# Windows example
$shim = (Get-Command fnm-shim).Source
New-Item -ItemType HardLink -Path "$Env:USERPROFILE\.fnm-shim\node.exe" -Value $shim
New-Item -ItemType HardLink -Path "$Env:USERPROFILE\.fnm-shim\npm.exe"  -Value $shim
New-Item -ItemType HardLink -Path "$Env:USERPROFILE\.fnm-shim\npx.exe"  -Value $shim
```

## How it works

1. Dispatch on `argv[0]` to determine the target executable (`node`, `npm`,
   or `npx`).
2. Stat `$FNM_DIR/aliases/default`. If a JSON cache record exists with a
   matching `mtime`, reuse the previously-resolved absolute paths.
3. On a cache miss, invoke
   `fnm exec --using=default -- node -p "process.execPath"` to get the
   absolute path to `node`, then derive `npm`/`npx` (or `npm.cmd`/`npx.cmd`
   on Windows) from its sibling directory.
4. Forward all CLI arguments, inherit stdio, and bubble up the exact exit
   code.

## Architectural Invariants

- The shim never relies on `AppData\Local\fnm_multishells\`.
- On Windows it always invokes `npm.cmd`/`npx.cmd` by absolute path.
- The cache is automatically invalidated when `fnm default <ver>` rewrites
  the default symlink.

## License

MIT
