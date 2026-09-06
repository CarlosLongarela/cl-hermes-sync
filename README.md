# cl-hermes-sync

**Export and restore a Hermes Agent installation across machines and operating systems.**

`cl-hermes-sync.sh` packages your Hermes Agent config, `SOUL.md`, skills, memories,
cron jobs and plugin configs (and, opt-in, auth / sync / session state) into a
portable directory or `.tar.gz`. Move it to another machine, run `import`, and
Hermes comes back up with the paths already rewritten for that OS.

- **License:** GPL-2.0-or-later (see [LICENSE](LICENSE))
- **Package format:** v2

## What's new in v2

- **Configuration file** (`cl-hermes-sync.conf`, next to the script) defines what
  is synced by default and the per-OS path constants. Every setting is still
  overridable from the command line.
- **Portable paths.** On export, absolute paths inside `config.yaml`, `cron/`
  and `memories/` are replaced with placeholders such as `@@CL_HERMES_HOME@@`
  and `@@CL_HERMES_OBSIDIAN_VAULT@@`. On import they are expanded to the correct
  path for the **target** OS.
- **Clear summaries.** Export and import print exactly what happened. Import
  shows the detected OS and the placeholder table and lets you correct the OS
  if the detection is wrong.
- **Integrity.** Every package ships a `CHECKSUMS.sha256`; `import` verifies it
  before touching anything (and refuses to continue non-interactively on a
  mismatch unless you pass `--no-verify`).
- **Encrypted secrets.** `auth.json` / `.env` are encrypted in the package by
  default (`age` or `openssl`), with the passphrase asked on the terminal or
  read from `$CL_HERMES_SECRETS_PASSPHRASE`.
- **Signed packages.** `--sign` adds a GPG detached signature over
  `CHECKSUMS.sha256`; `import` verifies it when present.
- **Windows path style.** Native `C:\Users\x` input in the config is accepted;
  on a Windows import you choose `msys` (`/c/Users/x`, default) or `native`
  output.
- **Post-import checks.** After restoring, `import` warns about absolute paths
  in `config.yaml` (and resolved placeholder targets) that don't exist on the
  destination machine.

## Quick start

```bash
# 1. Configure (once)
cp cl-hermes-sync.conf.example cl-hermes-sync.conf
chmod 600 cl-hermes-sync.conf
$EDITOR cl-hermes-sync.conf        # set the per-OS HOME / vault paths

# 2. Export
./cl-hermes-sync.sh export --tar --output ~/hermes-$(date +%F).tgz

# 3. Inspect
./cl-hermes-sync.sh list ~/hermes-2026-09-06.tgz

# 4. On the other machine
./cl-hermes-sync.sh import ~/hermes-2026-09-06.tgz
```

## Configuration file

Sourced as Bash, so keep it to `VAR="value"` assignments. Searched in this order:

1. `--config <path>`
2. `$CL_HERMES_SYNC_CONFIG`
3. `./cl-hermes-sync.conf` next to the script *(documented default)*
4. `$XDG_CONFIG_HOME/cl-hermes-sync/config.conf`
5. `$HOME/.cl-hermes-sync.conf`

It must be owned by you and not group/world-writable (`chmod 600`), otherwise it
is ignored with a warning. See [`cl-hermes-sync.conf.example`](cl-hermes-sync.conf.example)
for every option.

Key groups:

| Group | Variables | Purpose |
|---|---|---|
| What to sync | `CL_HERMES_SYNC_CONFIG`, `..._SKILLS`, `..._MEMORIES`, `..._CRON`, `..._PLUGINS`, `..._SYNC`, `..._SESSIONS`, `..._SECRETS`, `..._SOUL` | Default component set |
| Hermes home | `CL_HERMES_HOME_DIR` | Where the install lives |
| Templatize | `CL_HERMES_TEMPLATIZE_TARGETS` | Which parts get placeholder substitution |
| User home | `CL_HERMES_HOME_{LINUX,MACOS,WINDOWS}` | `@@CL_HERMES_HOME@@` |
| Obsidian vault | `CL_HERMES_OBSIDIAN_VAULT_{LINUX,MACOS,WINDOWS}` | `@@CL_HERMES_OBSIDIAN_VAULT@@` |
| Custom | `CL_HERMES_EXTRA_PLACEHOLDERS=(NAME ...)` + `CL_HERMES_<NAME>_{LINUX,MACOS,WINDOWS}` | `@@CL_HERMES_<NAME>@@` |
| Secrets | `CL_HERMES_SECRETS_ENCRYPT` | Encrypt `auth.json` / `.env` in the package |
| Signing | `CL_HERMES_SIGN`, `CL_HERMES_GPG_KEY` | GPG detached signature over `CHECKSUMS.sha256` |
| Windows paths | `CL_HERMES_WINDOWS_PATH_STYLE` | `msys` (`/c/Users/x`) or `native` (`C:\Users\x`) |
| Post-import | `CL_HERMES_POST_IMPORT_CHECKS` | Warn about missing paths after restore |

## Path templatization

On **export** (say, from Linux) the source-OS values and the live `$HOME` are
replaced with placeholders. Longer paths win, so a vault located inside `$HOME`
still collapses to `@@CL_HERMES_OBSIDIAN_VAULT@@`, not `@@CL_HERMES_HOME@@/...`.

On **import** the placeholders are expanded using, in priority order:

1. `--set NAME=PATH` on the command line
2. the target machine's own config file (if present or `--config`)
3. the `paths.map` shipped inside the package
4. an interactive prompt if a placeholder is still unset

`skills/` and `plugins/` are never rewritten.

## Commands

### `export [options]`

| Option | Meaning |
|---|---|
| `--output PATH` | Destination directory, or archive path with `--tar` |
| `--tar` | Produce a `.tar.gz` (path must end in `.tgz`/`.tar.gz`) |
| `--os NAME` | Force the source OS: `linux` \| `macos` \| `windows` |
| `--config PATH` | Use this configuration file |
| `--with LIST` / `--without LIST` | Force-include / exclude components (comma list) |
| `--no-secrets` | Shortcut for `--without secrets` |
| `--encrypt-secrets` / `--no-encrypt-secrets` | Encrypt `auth.json` / `.env` (default: on) |
| `--sign` / `--no-sign` | GPG detached-sign `CHECKSUMS.sha256` |
| `--gpg-key ID` | Key id / uid to sign with |
| `--no-templatize` | Do not create placeholders |
| `--force` | Overwrite a non-package output path without asking |
| `--yes` | Non-interactive: take defaults, never prompt |
| `-q, --quiet` | Minimal output (prints only the package path) |

### `import <package> [options]`

| Option | Meaning |
|---|---|
| `--os NAME` | Force the target OS |
| `--config PATH` | Config file to read placeholder values from |
| `--set NAME=PATH` | Override one placeholder value (repeatable; native `C:\` accepted) |
| `--hermes-home PATH` | Target Hermes home (default `$HERMES_HOME` or `~/.hermes`) |
| `--windows-path-style msys\|native` | Path form when expanding for a Windows target |
| `--with LIST` / `--without LIST` | Restrict which components are restored |
| `--no-templatize` | Restore files without expanding placeholders |
| `--no-backup` | Do not back up an existing Hermes home |
| `--no-verify` | Skip checksum **and** signature verification |
| `--no-verify-sig` | Skip only the GPG signature check |
| `--dry-run` | Show the plan, change nothing |
| `--yes` | Non-interactive |
| `-q, --quiet` | Minimal output |

Import always backs up an existing home to `~/.hermes.bak.<timestamp>` first
(unless `--no-backup`), then restores `config.yaml`, `SOUL.md`, `skills/`,
`memories/`, `cron/`, `plugins/`, and any opt-in extras present in the package.

### `list <package>`

Prints the manifest: format, source device/OS, contents, the placeholder table
for all three OSes, and the integrity file count. Works on a directory or an
archive.

### `version` / `help`

## Components

| Token | Source | Default |
|---|---|---|
| `config` | `config.yaml` | on |
| `soul` | `SOUL.md` | on |
| `skills` | `skills/` (minus `.skills_prompt_snapshot.json`) | on |
| `memories` | `memories/` | on |
| `cron` | `cron/` | on |
| `plugins` | `plugins/` (`*.yaml *.yml *.json *.toml` only) | on |
| `sync` | `sync/` (minus `*.db-wal` / `*.db-shm`) | off |
| `sessions` | `sessions/` + `state.db` | off |
| `secrets` | `auth.json` + `.env` (encrypted `.enc` by default) | off (each still confirmed on export) |

## Package layout

```
cl-hermes-sync/
├── manifest.json        metadata (format v2, contents, placeholders used)
├── CHECKSUMS.sha256      integrity hashes for every file
├── paths.map            per-OS placeholder table (sourced by import)
├── CHECKSUMS.sha256.asc  GPG detached signature (only with --sign)
├── config.yaml
├── SOUL.md
├── skills/  memories/  cron/  plugins/
├── auth/                auth.json(.enc) + .env(.enc)   (only if --with secrets)
├── cl-hermes-sync.sh    a copy of this tool
├── setup.sh             thin wrapper: runs the bundled tool in import mode
└── README.md
```

## Requirements

- **Bash 4+** (Linux, macOS, WSL, Git Bash / MSYS2 / Cygwin on Windows)
- `tar`, `awk`, `grep`, `sed`, `find`
- One of `sha256sum` / `shasum` / `openssl`
- `rsync` is used when present; the tool falls back to `tar` piping otherwise
- `age` or `openssl` for secret encryption; `gpg` for `--sign` / signature checks
  (all optional — features degrade gracefully with a warning)

No Python or `jq` required.

Hermes Agent core must be installed separately on the target machine before
`import`.

## Security notes

- The script runs with `umask 077`; packages and the files inside them are
  created private to your user. `auth.json` / `.env` are `chmod 600` in the
  package and on restore.
- Secrets are encrypted at rest in the package by default (AES-256 via
  `openssl -pbkdf2`, or `age`). The passphrase never lands on disk or in
  `argv` (asked on the tty, or via `$CL_HERMES_SECRETS_PASSPHRASE`).
- `--sign` adds a GPG detached signature over `CHECKSUMS.sha256`; a signed
  package whose signature fails to verify is refused non-interactively.
- The configuration file is only sourced if you own it and it is not
  group/world-writable.
- `import` verifies `CHECKSUMS.sha256` before making changes and rejects
  archives containing absolute or `../` paths.
- Recursive deletes during restore are guarded to stay strictly inside the
  target Hermes home.
- Secrets are never included unless you pass `--with secrets` (and, when
  interactive, confirm each file).

## License

GNU General Public License v2.0 or later. See [LICENSE](LICENSE).

Copyright (C) 2026 Carlos Longarela.
