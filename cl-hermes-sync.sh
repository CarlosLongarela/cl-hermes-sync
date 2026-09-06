#!/bin/bash
#
# cl-hermes-sync.sh - Hermes Agent Sync Export/Import Tool
#
# Exports/imports Hermes Agent config, skills, memories, plugins, cron,
# auth, and sync state into a portable directory or .tar.gz package.
# Use this to migrate Hermes between machines.
#
# Usage:
#   cl-hermes-sync.sh export [--output <path>] [--yes] [--no-secrets] [--tar] [--include-sync]
#   cl-hermes-sync.sh import <package-path>
#   cl-hermes-sync.sh list  <package-path>
#   cl-hermes-sync.sh help
#
# Examples:
#   cl-hermes-sync.sh export                              # export to .hermes-sync/
#   cl-hermes-sync.sh export --tar --output ~/hermes.tgz  # export as tgz
#   cl-hermes-sync.sh export --no-secrets                 # skip auth.json + .env
#   cl-hermes-sync.sh import .hermes-sync                  # restore on new machine
#   cl-hermes-sync.sh import ~/hermes.tgz                  # restore from tgz
#
# Package structure (.hermes-sync/):
#   manifest.json    - metadata + checksums
#   config.yaml      - ~/.hermes/config.yaml
#   SOUL.md          - persona file
#   skills/          - all custom skills
#   memories/        - MEMORY.md + USER.md
#   cron/            - cron job definitions
#   plugins/         - plugin configs (not code)
#   sync/            - hermes-sync state (optional, --include-sync)
#   auth/auth.json   - auth tokens (opt-in)
#   auth/.env        - API keys (opt-in)
#   setup.sh         - self-contained restore script
#   README.md        - instructions
#

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
FORMAT_VERSION=1
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# --- Colors ----------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}ℹ${NC} $*"; }
log_ok()    { echo -e "${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}==>${NC} $*"; }

# --- Help ------------------------------------
show_help() {
    cat <<EOF
${CYAN}hm-portable.sh - Hermes Agent Portable Export/Import Tool${NC}

Migrate Hermes Agent between machines. Packages config, skills,
memories, plugins, cron, and optionally auth/sync state.

USAGE:
    ${SCRIPT_NAME} export [OPTIONS]
    ${SCRIPT_NAME} import <package-path>
    ${SCRIPT_NAME} list  <package-path>
    ${SCRIPT_NAME} help

EXPORT OPTIONS:
    --output PATH     Output path (default: ./.hm-portable)
    --yes             Non-interactive mode (skip auth/.env by default)
    --no-secrets      Skip auth.json and .env (API keys)
    --tar             Package as .tar.gz (output path must end in .tgz or .tar.gz)
    --include-sync    Include hermes-sync state directory (~44MB)
    --include-sessions Include session history (~75MB)
    -q, --quiet       Minimal output

EXAMPLES:
    ${SCRIPT_NAME} export
    ${SCRIPT_NAME} export --tar --output ~/hermes-backup-$(date +%F).tgz
    ${SCRIPT_NAME} export --no-secrets --output /mnt/d/hermes-export
    ${SCRIPT_NAME} import ~/hermes-backup.tgz
    ${SCRIPT_NAME} import /mnt/d/hermes-export

EOF
}

# --- Utility: checksum ---------------------------------
sha256_file() {
    sha256sum "$1" | cut -d' ' -f1
}

# --- Export ----------------------------------
do_export() {
    local output_dir=""
    local yes_mode=false
    local no_secrets=false
    local do_tar=false
    local include_sync=false
    local include_sessions=false
    local quiet=false

    # Parse export args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output_dir="$2"; shift 2 ;;
            --yes) yes_mode=true; shift ;;
            --no-secrets) no_secrets=true; shift ;;
            --tar) do_tar=true; shift ;;
            --include-sync) include_sync=true; shift ;;
            --include-sessions) include_sessions=true; shift ;;
            -q|--quiet) quiet=true; shift ;;
            *) log_error "Unknown export option: $1"; exit 1 ;;
        esac
    done

    # Default output
    if [[ -z "$output_dir" ]]; then
        if $do_tar; then
            output_dir="${PWD}/hermes-portable-$(date +%Y%m%d-%H%M%S).tgz"
        else
            output_dir="${PWD}/.hm-portable"
        fi
    fi

    # Validate HERMES_HOME
    if [[ ! -d "$HERMES_HOME" ]]; then
        log_error "Hermes home not found: $HERMES_HOME"
        log_error "Set HERMES_HOME or run from the correct machine."
        exit 1
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"
    local pkg_dir="${temp_dir}/hm-portable"

    mkdir -p "$pkg_dir"/{skills,memories,cron,plugins,auth}
    if $include_sync; then
        mkdir -p "$pkg_dir/sync"
    fi

    $quiet || log_step "Exporting Hermes Agent from ${HERMES_HOME}"

    # --- Config ---
    if [[ -f "$HERMES_HOME/config.yaml" ]]; then
        cp "$HERMES_HOME/config.yaml" "$pkg_dir/config.yaml"
        $quiet || log_ok "config.yaml ($(wc -c < "$HERMES_HOME/config.yaml") bytes)"
    else
        log_warn "config.yaml not found"
    fi

    # --- SOUL.md ---
    if [[ -f "$HERMES_HOME/SOUL.md" ]]; then
        cp "$HERMES_HOME/SOUL.md" "$pkg_dir/SOUL.md"
        $quiet || log_ok "SOUL.md ($(wc -c < "$HERMES_HOME/SOUL.md") bytes)"
    fi

    # --- Skills ---
    if [[ -d "$HERMES_HOME/skills" ]] && [[ -n "$(ls -A "$HERMES_HOME/skills" 2>/dev/null)" ]]; then
        local skill_count
        skill_count=$(find "$HERMES_HOME/skills" -type f | wc -l)
        # Use cp -a to preserve structure; exclude large generated files
        rsync -a --filter='exclude .skills_prompt_snapshot.json' "$HERMES_HOME/skills/" "$pkg_dir/skills/"
        $quiet || log_ok "skills/ ($skill_count files)"
    fi

    # --- Memories ---
    mkdir -p "$pkg_dir/memories"
    if ls "$HERMES_HOME/memories/"*.md &>/dev/null 2>&1; then
        cp "$HERMES_HOME/memories/"*.md "$pkg_dir/memories/"
        local mem_count
        mem_count=$(ls "$HERMES_HOME/memories/"*.md 2>/dev/null | wc -l)
        $quiet || log_ok "memories/ ($mem_count files)"
    fi

    # --- Cron ---
    if [[ -d "$HERMES_HOME/cron" ]] && [[ -n "$(ls -A "$HERMES_HOME/cron" 2>/dev/null)" ]]; then
        rsync -a "$HERMES_HOME/cron/" "$pkg_dir/cron/"
        local cron_count
        cron_count=$(find "$HERMES_HOME/cron" -type f | wc -l)
        $quiet || log_ok "cron/ ($cron_count jobs)"
    fi

    # --- Plugins (config only) ---
    if [[ -d "$HERMES_HOME/plugins" ]]; then
        # Only copy config files, not actual plugin code - use relative paths
        (cd "$HERMES_HOME" && find "plugins" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.toml' \) \
            -exec sh -c 'mkdir -p "$1/$(dirname "{}")" && cp "$2/{}" "$1/{}"' _ "$pkg_dir" "$HERMES_HOME" \; ) 2>/dev/null || true
        local plugin_count
        plugin_count=$(find "$pkg_dir/plugins" -type f 2>/dev/null | wc -l)
        $quiet || log_ok "plugins/ ($plugin_count config files)"
    fi

    # --- Auth (opt-in) ---
    local has_auth=false
    local has_env=false

    if ! $no_secrets; then
        if [[ -f "$HERMES_HOME/auth.json" ]]; then
            if $yes_mode; then
                cp "$HERMES_HOME/auth.json" "$pkg_dir/auth/auth.json"
                has_auth=true
                $quiet || log_ok "auth.json included (--yes mode)"
            else
                read -r -p "$(echo -e "${YELLOW}?${NC} Include auth.json (tokens)? [y/N] ")" include_auth
                if [[ "$include_auth" == "y" || "$include_auth" == "Y" ]]; then
                    cp "$HERMES_HOME/auth.json" "$pkg_dir/auth/auth.json"
                    has_auth=true
                fi
            fi
        fi

        if [[ -f "$HERMES_HOME/.env" ]]; then
            if $yes_mode; then
                cp "$HERMES_HOME/.env" "$pkg_dir/auth/.env"
                has_env=true
                $quiet || log_info ".env included (--yes mode) - contains API keys!"
            else
                read -r -p "$(echo -e "${YELLOW}?${NC} Include .env (API keys)? This contains secrets! [y/N] ")" include_env
                if [[ "$include_env" == "y" || "$include_env" == "Y" ]]; then
                    cp "$HERMES_HOME/.env" "$pkg_dir/auth/.env"
                    has_env=true
                    log_warn "API keys included in package. Handle with care!"
                fi
            fi
        fi
    else
        $quiet || log_info "Skipping secrets (--no-secrets)"
    fi

    # --- Sync state (opt-in, ~44MB) ---
    if $include_sync && [[ -d "$HERMES_HOME/sync" ]]; then
        rsync -a --filter='exclude *.db-wal' --filter='exclude *.db-shm' "$HERMES_HOME/sync/" "$pkg_dir/sync/"
        local sync_count
        sync_count=$(find "$pkg_dir/sync" -type f 2>/dev/null | wc -l)
        $quiet || log_ok "sync/ included ($sync_count files)"
    else
        $quiet || log_info "Sync state excluded (use --include-sync to include)"
    fi

    # --- Sessions (opt-in, ~75MB) ---
    if $include_sessions && [[ -d "$HERMES_HOME/sessions" ]]; then
        mkdir -p "$pkg_dir/sessions"
        rsync -a "$HERMES_HOME/sessions/" "$pkg_dir/sessions/"
        $quiet || log_ok "sessions/ included"
    fi

    # --- State DB (if requested) ---
    if $include_sessions && [[ -f "$HERMES_HOME/state.db" ]]; then
        cp "$HERMES_HOME/state.db" "$pkg_dir/state.db" 2>/dev/null || log_warn "state.db busy (Hermes running?)"
    fi

    # --- Write manifest ---
    local hermes_ver
    hermes_ver=$(hermes --version 2>/dev/null | head -1 | tr -d '\n\r' || echo "unknown")
    local hostname_str
    hostname_str=$(hostname 2>/dev/null || echo "unknown")

    # Calculate checksums
    local config_hash="" soul_hash=""
    [[ -f "$pkg_dir/config.yaml" ]] && config_hash=$(sha256_file "$pkg_dir/config.yaml")
    [[ -f "$pkg_dir/SOUL.md" ]] && soul_hash=$(sha256_file "$pkg_dir/SOUL.md")

    cat > "$pkg_dir/manifest.json" <<MANIFEST_EOF
{
    "format_version": ${FORMAT_VERSION},
    "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source_device": "${hostname_str}",
    "source_os": "$(uname -s)",
    "hermes_home": "${HERMES_HOME}",
    "hermes_version": "${hermes_ver}",
    "contents": {
        "config": true,
        "soul": $( [[ -f "$HERMES_HOME/SOUL.md" ]] && echo 'true' || echo 'false' ),
        "skills": true,
        "memories": true,
        "cron": $( [[ -d "$HERMES_HOME/cron" ]] && ls -A "$HERMES_HOME/cron" &>/dev/null && echo 'true' || echo 'false' ),
        "plugins": true,
        "sync": ${include_sync},
        "sessions": ${include_sessions},
        "auth": ${has_auth},
        "env": ${has_env}
    },
    "checksums": {
        "config.yaml": "${config_hash}",
        "SOUL.md": "${soul_hash}"
    },
    "summary": {
        "skills_files": $(find "$pkg_dir/skills" -type f 2>/dev/null | wc -l),
        "memories_files": $(find "$pkg_dir/memories" -type f 2>/dev/null | wc -l),
        "cron_files": $(find "$pkg_dir/cron" -type f 2>/dev/null | wc -l),
        "total_size_bytes": $(du -sb "$pkg_dir" 2>/dev/null | cut -f1)
    }
}
MANIFEST_EOF

    # --- Write setup.sh (self-contained restore script) ---
    cat > "$pkg_dir/setup.sh" <<'SETUP_EOF'
#!/bin/bash
# hm-portable restore script - auto-generated
# Run this on the target machine to restore Hermes Agent configuration.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}ℹ${NC} $*"; }
log_ok()    { echo -e "${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}==>${NC} $*"; }

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
MANIFEST="${PKG_DIR}/manifest.json"

# --- OS Detection ---------------------------------
detect_os() {
    case "$(uname -s)" in
        Linux*)     echo "linux" ;;
        Darwin*)    echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)          echo "unknown" ;;
    esac
}
TARGET_OS=$(detect_os)

echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  Hermes Agent Portable Restore           ${NC}"
echo -e "${CYAN}==========================================${NC}"
echo ""
echo -e "  Target OS: ${YELLOW}${TARGET_OS}${NC}"
echo -e "  Source:    ${BLUE}$(python3 -c "
import json
try:
    m = json.load(open('$MANIFEST'))
    print(f\"{m.get('source_device','?')} @ {m.get('exported_at','?')}\")
except: print('(unknown)')" 2>/dev/null || echo '(unknown)')${NC}"
echo ""

# --- OS Compatibility Check ----------------------
OS_ADJUSTMENTS=""
os_check() {
    local config_file="$1"
    local adjustments=""

    if [[ "$TARGET_OS" == "macos" ]]; then
        if grep -q 'auto_source_bashrc: true' "$config_file" 2>/dev/null; then
            sed -i 's/auto_source_bashrc: true/auto_source_bashrc: false  # adjusted for macOS/' "$config_file"
            adjustments="${adjustments}  • auto_source_bashrc → false (macOS uses .zshrc/.bash_profile)\n"
        fi
        if grep -q 'persistent_shell: true' "$config_file" 2>/dev/null; then
            sed -i 's/persistent_shell: true/persistent_shell: true  # verify on macOS/' "$config_file"
        fi
    elif [[ "$TARGET_OS" == "windows" ]]; then
        if grep -q 'auto_source_bashrc: true' "$config_file" 2>/dev/null; then
            sed -i 's/auto_source_bashrc: true/auto_source_bashrc: false  # adjusted for Windows/' "$config_file"
            adjustments="${adjustments}  • auto_source_bashrc → false (Windows has no .bashrc)\n"
        fi
        if grep -q 'persistent_shell: true' "$config_file" 2>/dev/null; then
            sed -i 's/persistent_shell: true/persistent_shell: false  # adjusted for Windows/' "$config_file"
            adjustments="${adjustments}  • persistent_shell → false (Windows shell model)\n"
        fi
    fi

    # Cross-OS: check sync remote_path if sync data was included
    if grep -q '"sync": true' "$MANIFEST" 2>/dev/null; then
        if grep -q 'remote_path:' "$config_file" 2>/dev/null; then
            local old_path
            old_path=$(grep 'remote_path:' "$config_file" | head -1 | sed 's/.*remote_path: *//' | tr -d ' ')
            if [[ ! -d "$old_path" ]]; then
                adjustments="${adjustments}  • remote_path '$old_path' does not exist (verify or update)\n"
                adjustments="${adjustments}    Set: hermes config set sync.remote_path /new/path\n"
            fi
        fi
    fi

    echo -e "$adjustments"
    OS_ADJUSTMENTS="$adjustments"
}


echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  Hermes Agent Portable Restore           ${NC}"
echo -e "${CYAN}==========================================${NC}"
echo ""
echo -e "  Target OS: ${YELLOW}${TARGET_OS}${NC}"

# Check for existing installation
if [[ -d "$HERMES_HOME" ]]; then
    log_warn "Hermes home already exists: $HERMES_HOME"
    echo ""
    echo "  This will OVERWRITE the following in your existing Hermes:"
    echo "    - config.yaml"
    grep -q '"soul": true' "$MANIFEST" 2>/dev/null && echo "    - SOUL.md"
    echo "    - skills/ (full replace)"
    echo "    - memories/ (full replace)"
    grep -q '"cron": true' "$MANIFEST" 2>/dev/null && echo "    - cron/"
    echo "    - plugins/ (full replace)"
    grep -q '"sync": true' "$MANIFEST" 2>/dev/null && echo "    - sync/"
    grep -q '"auth": true' "$MANIFEST" 2>/dev/null && echo "    - auth.json"
    grep -q '"env": true' "$MANIFEST" 2>/dev/null && echo "    - .env"
    echo ""
    echo "  Your sessions/, logs/, state.db will be preserved."
    echo "  A backup will be created at: ${HERMES_HOME}.bak.$(date +%Y%m%d-%H%M%S)"
    echo ""

    read -r -p "$(echo -e "${YELLOW}?${NC} Continue with restore? [y/N] ")" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi

    # Backup existing
    local backup_path="${HERMES_HOME}.bak.$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up existing Hermes home to ${backup_path}..."
    mkdir -p "$backup_path"
    for item in config.yaml SOUL.md skills memories cron plugins sync; do
        [[ -e "$HERMES_HOME/$item" ]] && cp -r "$HERMES_HOME/$item" "$backup_path/" 2>/dev/null || true
    done
    [[ -f "$HERMES_HOME/auth.json" ]] && cp "$HERMES_HOME/auth.json" "$backup_path/" 2>/dev/null || true
    [[ -f "$HERMES_HOME/.env" ]] && cp "$HERMES_HOME/.env" "$backup_path/" 2>/dev/null || true
    log_ok "Backup saved"
fi

# Restore each component
restore_item() {
    local src="$1"
    local dst="$2"
    local name="$3"

    if [[ -e "$PKG_DIR/$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        if [[ -d "$PKG_DIR/$src" ]]; then
            rm -rf "$dst" 2>/dev/null || true
            cp -r "$PKG_DIR/$src" "$dst"
        else
            cp "$PKG_DIR/$src" "$dst"
        fi
        log_ok "$name restored"
    fi
}

log_step "Restoring Hermes Agent configuration..."

restore_item "config.yaml" "$HERMES_HOME/config.yaml" "config.yaml"

# --- Run OS compatibility check on restored config ---
if [[ -f "$HERMES_HOME/config.yaml" ]]; then
    log_step "Checking OS compatibility..."
    os_check "$HERMES_HOME/config.yaml"
fi
restore_item "SOUL.md" "$HERMES_HOME/SOUL.md" "SOUL.md"
restore_item "skills" "$HERMES_HOME/skills" "skills/"
restore_item "memories" "$HERMES_HOME/memories" "memories/"
restore_item "cron" "$HERMES_HOME/cron" "cron/"
restore_item "plugins" "$HERMES_HOME/plugins" "plugins/"
restore_item "sync" "$HERMES_HOME/sync" "sync/"

# Auth files
if [[ -f "$PKG_DIR/auth/auth.json" ]]; then
    cp "$PKG_DIR/auth/auth.json" "$HERMES_HOME/auth.json"
    chmod 600 "$HERMES_HOME/auth.json"
    log_ok "auth.json restored"
fi
if [[ -f "$PKG_DIR/auth/.env" ]]; then
    cp "$PKG_DIR/auth/.env" "$HERMES_HOME/.env"
    chmod 600 "$HERMES_HOME/.env"
    log_ok ".env restored"
fi

# State DB
if [[ -f "$PKG_DIR/state.db" ]]; then
    if [[ -f "$HERMES_HOME/state.db" ]]; then
        log_warn "state.db exists, skipping (keep existing session history)"
    else
        cp "$PKG_DIR/state.db" "$HERMES_HOME/state.db"
        log_ok "state.db restored"
    fi
fi

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  Restore complete!                        ${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""

if [[ -n "$OS_ADJUSTMENTS" ]]; then
    echo -e "${YELLOW}  OS Compatibility Adjustments:${NC}"
    echo -e "$OS_ADJUSTMENTS"
    echo "  (These are automatically applied. Review with: hermes config list)"
    echo ""
fi

echo "  Next steps on the new machine:"
echo "    1. Ensure Hermes Agent is installed:"
echo "       pip install hermes-agent"
echo "    2. Verify config:"
echo "       hermes status"
echo "    3. Restart the gateway if you use it:"
echo "       hermes gateway restart"
echo "    4. Check cron jobs:"
echo "       hermes cron list"
echo ""

SETUP_EOF
    chmod +x "$pkg_dir/setup.sh"

    # --- Write README ---
    # --- Write README (pre-compute dynamic values to avoid heredoc expansion issues) ---
    local readme_export_note="Exported from ${hostname_str} ($(uname -s)) at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    local readme_os_note="Cross-OS migration supported: setup.sh auto-detects Linux/macOS/Windows and adjusts config."
    {
        echo "# Hermes Agent Portable Package"
        echo ""
        echo "${readme_export_note}"
        echo "${readme_os_note}"
        echo ""
        echo "## Contents"
        echo ""
        echo "- \`config.yaml\` - Hermes configuration"
        echo "- \`SOUL.md\` - Persona definition"
        local skill_count_readme
        skill_count_readme=$(find "$pkg_dir/skills" -type f 2>/dev/null | wc -l)
        echo "- \`skills/\` - All custom skills (${skill_count_readme} files)"
        echo "- \`memories/\` - MEMORY.md + USER.md"
        echo "- \`cron/\` - Cron job definitions"
        echo "- \`plugins/\` - Plugin configs"
        echo "- \`auth/\` - Auth tokens and environment variables (if included)"
        echo "- \`setup.sh\` - Self-contained restore script"
        echo ""
        echo "## Restore"
        echo ""
        echo 'On the target machine:'
        echo ""
        echo '```bash'
        echo '# Option A: Run the bundled setup script'
        echo './setup.sh'
        echo ''
        echo '# Option B: Use hm-portable import'
        echo 'hm-portable.sh import /path/to/package'
        echo '```'
        echo ""
        echo "## Notes"
        echo ""
        echo '- Hermes Agent core must be installed separately (pip install or git clone)'
        echo '- Session history is NOT included by default'
        echo '- Check \`manifest.json\` for checksums and metadata'
    } > "$pkg_dir/README.md"

    # --- Final output ---
    if $do_tar; then
        local final_path="${output_dir}"
        mkdir -p "$(dirname "$final_path")"
        (cd "$temp_dir" && tar czf "$final_path" hm-portable/)
        local pkg_size
        pkg_size=$(du -h "$final_path" | cut -f1)
        rm -rf "$temp_dir"
        echo ""
        echo -e "${GREEN}==========================================${NC}"
        echo -e "${GREEN}  Export complete!                         ${NC}"
        echo -e "${GREEN}==========================================${NC}"
        echo ""
        echo "  Package: ${final_path} (${pkg_size})"
        echo "  To restore on another machine:"
        echo "    hm-portable.sh import ${final_path}"
        echo ""
    else
        # Move from temp to final location
        local final_path="${output_dir}"
        if [[ -d "$final_path" ]]; then
            rm -rf "$final_path"
        fi
        mkdir -p "$(dirname "$final_path")"
        mv "$pkg_dir" "$final_path"
        rm -rf "$temp_dir"

        local pkg_size
        pkg_size=$(du -sh "$final_path" | cut -f1)
        echo ""
        echo -e "${GREEN}==========================================${NC}"
        echo -e "${GREEN}  Export complete!                         ${NC}"
        echo -e "${GREEN}==========================================${NC}"
        echo ""
        echo "  Package: ${final_path}/ (${pkg_size})"
        echo "  To restore on another machine:"
        echo "    hm-portable.sh import ${final_path}"
        echo "  Or to create a tarball for transfer:"
        echo "    tar czf hermes-portable.tgz -C ${final_path%/*} ${final_path##*/}"
        echo ""
    fi
}

# --- Import ----------------------------------
do_import() {
    local src_path="$1"

    if [[ ! -e "$src_path" ]]; then
        log_error "Package not found: $src_path"
        exit 1
    fi

    local temp_dir=""
    local pkg_dir=""

    # If it's a tar.gz, extract first
    if [[ "$src_path" == *.tgz || "$src_path" == *.tar.gz ]]; then
        log_step "Extracting package..."
        temp_dir="$(mktemp -d)"
        tar xzf "$src_path" -C "$temp_dir"
        pkg_dir="$temp_dir/hm-portable"
        if [[ ! -d "$pkg_dir" ]]; then
            # Maybe it was extracted to a different name
            pkg_dir=$(find "$temp_dir" -name "manifest.json" -exec dirname {} \; 2>/dev/null | head -1)
            if [[ -z "$pkg_dir" ]]; then
                log_error "Could not find manifest.json in extracted package"
                rm -rf "$temp_dir"
                exit 1
            fi
        fi
    else
        pkg_dir="$src_path"
    fi

    # Verify manifest
    if [[ ! -f "$pkg_dir/manifest.json" ]]; then
        log_error "Invalid package: manifest.json not found"
        [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
        exit 1
    fi

    local source_device
    source_device=$(python3 -c "import json; print(json.load(open('$pkg_dir/manifest.json')).get('source_device','unknown'))" 2>/dev/null || echo "unknown")
    local exported_at
    exported_at=$(python3 -c "import json; print(json.load(open('$pkg_dir/manifest.json')).get('exported_at','unknown'))" 2>/dev/null || echo "unknown")

    echo ""
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}  Hermes Agent Portable Import             ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo ""
    echo "  Source: ${source_device} @ ${exported_at}"
    echo "  Target: ${HERMES_HOME}"
    echo ""

    # Run the bundled setup script if it exists
    if [[ -f "$pkg_dir/setup.sh" ]]; then
        log_step "Running bundled restore script..."
        bash "$pkg_dir/setup.sh"
        local exit_code=$?
        [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
        return $exit_code
    else
        log_error "No setup.sh found in package (possibly corrupted)"
        [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
        exit 1
    fi
}

# --- List package contents ------------------------------
do_list() {
    local src_path="$1"
    local temp_dir=""
    local pkg_dir=""

    if [[ ! -e "$src_path" ]]; then
        log_error "Package not found: $src_path"
        exit 1
    fi

    if [[ "$src_path" == *.tgz || "$src_path" == *.tar.gz ]]; then
        temp_dir="$(mktemp -d)"
        tar xzf "$src_path" -C "$temp_dir"
        pkg_dir="$temp_dir/hm-portable"
        if [[ ! -d "$pkg_dir" ]]; then
            pkg_dir=$(find "$temp_dir" -name "manifest.json" -exec dirname {} \; 2>/dev/null | head -1)
            if [[ -z "$pkg_dir" ]]; then
                log_error "Could not find manifest.json"
                rm -rf "$temp_dir"
                exit 1
            fi
        fi
    else
        pkg_dir="$src_path"
    fi

    if [[ ! -f "$pkg_dir/manifest.json" ]]; then
        log_error "No manifest.json found"
        [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
        exit 1
    fi

    python3 -c "
import json, os, platform
m = json.load(open('$pkg_dir/manifest.json'))
source_os = m.get('source_os', 'unknown')
target_os = platform.system()
print()
print('Hermes Agent Portable Package')
print('=' * 40)
print(f'  Exported:   {m.get(\"exported_at\",\"?\")}')
print(f'  Source OS:  {source_os}')
print(f'  Target OS:  {target_os}')
if source_os != target_os:
    print(f'  ⚠ Cross-OS migration - setup.sh will auto-adjust config')
print(f'  From:       {m.get(\"source_device\",\"?\")}')
print(f'  Version:    {m.get(\"hermes_version\",\"?\")}')
print()
print('Contents:')
c = m.get('contents', {})
for k in ['config','soul','skills','memories','cron','plugins','sync','sessions','auth','env']:
    if c.get(k):
        print(f'    ✓ {k}')
    elif k in c:
        print(f'    ✗ {k} (not included)')
    else:
        print(f'    ? {k}')
print()
print(f'Skills: {m.get(\"summary\",{}).get(\"skills_files\",\"?\")} files')
print(f'Memories: {m.get(\"summary\",{}).get(\"memories_files\",\"?\")} files')
size = m.get('summary',{}).get('total_size_bytes',0)
if size:
    print(f'Total: {size/1024/1024:.1f} MB' if size > 1024*1024 else f'Total: {size/1024:.0f} KB')
print()
" 2>/dev/null || {
        echo "Package contents:"
        ls -la "$pkg_dir/"
    }

    [[ -n "$temp_dir" ]] && rm -rf "$temp_dir"
    return 0
}

# --- Main -----------------------------------
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        export)
            do_export "$@"
            ;;
        import)
            if [[ $# -lt 1 ]]; then
                log_error "Usage: ${SCRIPT_NAME} import <package-path>"
                exit 1
            fi
            do_import "$1"
            ;;
        list)
            if [[ $# -lt 1 ]]; then
                log_error "Usage: ${SCRIPT_NAME} list <package-path>"
                exit 1
            fi
            do_list "$1"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $cmd"
            echo "Usage: ${SCRIPT_NAME} {export|import|list|help}"
            exit 1
            ;;
    esac
}

main "$@"
