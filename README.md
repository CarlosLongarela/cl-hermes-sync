# Hermes Portable

**Export and restore your Hermes Agent configuration across machines — including across different operating systems.**

`hm-portable.sh` packages your Hermes Agent config, skills, memory, cron jobs, and plugin configs into a portable directory or `.tar.gz` archive. Move it to another machine, run `import`, and your Hermes is ready — same config, same skills, same memory.

## Features

- **Export** — collect config.yaml, SOUL.md, skills (1300+ files), memories, cron, plugins into a portable package
- **Import** — restore everything on a new machine with automatic backup of existing config
- **Cross-OS** — auto-detects Linux, macOS, Windows; adjusts OS-specific settings (`auto_source_bashrc`, `persistent_shell`) so you don't have to
- **Flexible** — export as a directory for inspection, or as a `.tar.gz` for easy transfer (scp, Dropbox, USB)
- **Secure by default** — auth tokens and `.env` API keys require explicit opt-in. Full `--no-secrets` mode for CI/scripted use
- **Self-contained** — the package includes `setup.sh` that runs standalone. No tool dependency, just `bash`

## Quick Start

```bash
# Install (one-line)
curl -fsSL https://raw.githubusercontent.com/zpage/hermes-portable/main/hm-portable.sh \
  -o /usr/local/bin/hm-portable.sh && chmod +x /usr/local/bin/hm-portable.sh

# Export your Hermes config
hm-portable.sh export --tar --output ~/hermes-backup.tgz

# See what's in the package
hm-portable.sh list ~/hermes-backup.tgz

# Move it to another machine (scp, Dropbox, USB...)
# Then import:
hm-portable.sh import ~/hermes-backup.tgz
```

## Why

Hermes Agent stores all its configuration in `~/.hermes/` — skills (1300+ files), memories, cron jobs, auth tokens. Moving to a new machine means manually copying all of this and adjusting for OS differences. This tool automates it:

| Concern | Manual | With hm-portable |
|---|---|---|
| Copy skills/ | `rsync` across 1300 files | Included |
| Adjust `auto_source_bashrc` for macOS | Edit config.yaml by hand | ⚡ Auto-detected |
| Adjust `persistent_shell` for Windows | Edit config.yaml by hand | ⚡ Auto-detected |
| Remember what to include | Usually forget auth.json | Opt-in, explicit |
| Verify integrity | Hope it works | SHA256 checksums in manifest |
| Disaster recovery | Hope you have a backup | Auto-backup before restore |

## Usage

### Export

```bash
# Basic — directory mode
hm-portable.sh export

# Tar.gz mode (ready for transfer)
hm-portable.sh export --tar --output ~/hermes-$(date +%F).tgz

# Non-interactive (skip auth/.env prompts)
hm-portable.sh export --yes

# Skip secrets entirely (CI-safe)
hm-portable.sh export --no-secrets

# Include sync state and session history
hm-portable.sh export --include-sync --include-sessions
```

### List

```bash
hm-portable.sh list ~/hermes-backup.tgz
```

Output:
```
  Exported:   2026-05-28T02:33:30Z
  Source OS:  Linux
  Target OS:  Linux
  From:       my-workstation
  Version:    Hermes Agent v0.14.0

Contents:
    ✓ config
    ✓ soul
    ✓ skills
    ✓ memories
    ✓ cron
    ✓ plugins
    ✗ sync (not included)
    ✗ sessions (not included)
    ✗ auth (not included)
    ✗ env (not included)

Skills: 1336 files
Memories: 2 files
Total: 121.6 MB
```

### Import

```bash
# From a directory
hm-portable.sh import /path/to/.hm-portable

# From a tarball
hm-portable.sh import ~/hermes-backup.tgz
```

The import script:
1. Backs up your existing `~/.hermes` to `~/.hermes.bak.<timestamp>`
2. Detects your OS (Linux / macOS / Windows)
3. Restores config, skills, memories, cron, plugin configs
4. Auto-adjusts OS-specific settings in config.yaml
5. Restores auth/`.env` if included in the package

## What's Included

| Item | Size | Included by default |
|---|---|---|
| `config.yaml` | ~15 KB | ✅ |
| `SOUL.md` | ~2 KB | ✅ |
| `skills/` | ~112 MB (1300+ files) | ✅ |
| `memories/` | ~12 KB | ✅ |
| `cron/` (job definitions) | ~36 KB | ✅ |
| `plugins/` (config only) | ~712 KB | ✅ |
| `auth.json` | ~10 KB | ❌ (opt-in) |
| `.env` (API keys) | ~21 KB | ❌ (opt-in) |
| `sync/` (hermes-sync state) | ~44 MB | ❌ (`--include-sync`) |
| `sessions/` | ~75 MB | ❌ (`--include-sessions`) |
| `state.db` | ~69 MB | ❌ (`--include-sessions`) |

**Not included (must install separately on target machine):**
- Hermes Agent core (`pip install hermes-agent`)
- hermes-agent source code (~2.2 GB)
- Node.js runtime (~1.4 GB)
- `logs/`, `cache/` — machine-specific, regenerated

## Cross-OS Migration

The `setup.sh` bundled in every package detects the target OS and auto-adjusts config:

| Setting | Linux | macOS | Windows |
|---|---|---|---|
| `auto_source_bashrc` | kept as-is | → `false` | → `false` |
| `persistent_shell` | kept as-is | kept as-is (with a note) | → `false` |
| sync `remote_path` | kept as-is | checked for existence | checked for existence |

No manual editing required. The adjustments are printed during import so you know what changed.

## Project Structure

```
hermes-portable/
├── hm-portable.sh     # Main CLI tool (single file, ~30 KB)
├── README.md          # This file
├── README.zh.md       # Chinese documentation
└── LICENSE            # MIT
```

## Requirements

- **Bash** 4+ (Linux, macOS, WSL)
- **Python 3** (for manifest display in `list` command)
- Common POSIX tools: `curl`, `tar`, `sed`, `grep`, `find`

Hermes Agent must be installed on the target machine before import.

## License

MIT
