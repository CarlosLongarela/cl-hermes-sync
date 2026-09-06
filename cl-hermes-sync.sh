#!/usr/bin/env bash
#
# cl-hermes-sync.sh - Hermes Agent portable export / import tool
#
# Exports and restores a Hermes Agent installation (config, SOUL, skills,
# memories, cron jobs, plugin configs and - opt-in - auth/sync/session state)
# as a portable directory or .tar.gz package, so Hermes can be moved between
# machines and operating systems.
#
# What is new in format version 2:
#   * Configuration file (cl-hermes-sync.conf) next to this script defines,
#     by default, WHAT is synced and the per-OS path constants. Every setting
#     can still be overridden from the command line.
#   * Absolute paths inside config/cron/memories are replaced with portable
#     placeholders on export (for example @@CL_HERMES_HOME@@) and expanded
#     back to the right path for the target OS on import.
#   * Export and import print a clear summary. Import shows the detected OS
#     and the placeholder table, and lets you correct the OS if it is wrong.
#
# Usage:
#   cl-hermes-sync.sh export [options]
#   cl-hermes-sync.sh import <package> [options]
#   cl-hermes-sync.sh list   <package>
#   cl-hermes-sync.sh version
#   cl-hermes-sync.sh help
#
# License: GPL-2.0-or-later. See the LICENSE file.
# Copyright (C) 2026 Carlos Longarela
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation; either version 2 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#

set -euo pipefail

# Private-by-default: everything this script creates is only readable by the
# current user unless it is explicitly relaxed later.
umask 077

# --- Constants -------------------------------------------------------------

VERSION="2.0.0"
FORMAT_VERSION=2
PACKAGE_ROOT_NAME="cl-hermes-sync"          # top-level dir name inside a package
PLACEHOLDER_PREFIX="@@CL_HERMES_"
PLACEHOLDER_SUFFIX="@@"

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Resolve the real directory of this script (following symlinks) so the
# sibling configuration file can be found even when the script is symlinked
# into a directory on PATH.
_resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -h "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
SCRIPT_DIR="$(_resolve_script_dir)"

# --- Colors --------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

QUIET=false
ASSUME_YES=false

log_info()  { $QUIET || echo -e "${BLUE}i${NC} $*"; }
log_ok()    { $QUIET || echo -e "${GREEN}+${NC} $*"; }
log_warn()  { echo -e "${YELLOW}!${NC} $*" >&2; }
log_error() { echo -e "${RED}x${NC} $*" >&2; }
log_step()  { $QUIET || echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
die()       { log_error "$*"; exit 1; }

# --- Temp dir tracking ---------------------------------------------------

_TMP_DIRS=()
_cleanup() {
    local ec=$? d
    for d in "${_TMP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
    return "$ec"
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_mktemp_dir() {
    local d
    d="$(mktemp -d 2>/dev/null || mktemp -d -t cl-hermes-sync.XXXXXX)"
    [[ -n "$d" && -d "$d" ]] || die "Could not create a temporary directory"
    _TMP_DIRS+=("$d")
    printf '%s' "$d"
}

# --- Small helpers -----------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Detect the current operating system family.
detect_os() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"
    case "$uname_s" in
        Linux*)               echo "linux" ;;
        Darwin*)              echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
        *)                    echo "unknown" ;;
    esac
}

# Portable SHA-256 of a file -> lowercase hex on stdout.
sha256_file() {
    local f="$1"
    if have sha256sum; then
        sha256sum -- "$f" | cut -d' ' -f1
    elif have shasum; then
        shasum -a 256 -- "$f" | cut -d' ' -f1
    elif have openssl; then
        openssl dgst -sha256 -- "$f" | sed 's/^.*= //'
    else
        die "Need one of: sha256sum, shasum, openssl"
    fi
}

# True if the file looks like text (no NUL bytes).
is_text_file() {
    [[ -f "$1" ]] || return 1
    grep -Iq . "$1" 2>/dev/null
}

# --- Windows path style ------------------------------------------------

# "C:\Users\x" or "C:/Users/x"  ->  "/c/Users/x"  (MSYS / Git Bash style).
# Anything already POSIX is returned unchanged.
to_msys_path() {
    local p="$1"
    if [[ "$p" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
        drive="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
        rest="${rest//\\//}"
        printf '/%s/%s' "$drive" "$rest"
    else
        printf '%s' "$p"
    fi
}

# "/c/Users/x"  ->  "C:\Users\x"  (native Windows style).
to_native_win_path() {
    local p="$1"
    if [[ "$p" =~ ^/([A-Za-z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
        drive="$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')"
        rest="${rest//\//\\}"
        printf '%s:\\%s' "$drive" "$rest"
    else
        printf '%s' "$p"
    fi
}

# --- Crypto: secret encryption + package signing --------------------

# True if a usable secret encryption backend exists.
crypto_backend() {
    if have age; then echo age
    elif have openssl; then echo openssl
    else echo ""; fi
}

# Read a passphrase. $1 = "confirm" to ask twice (export). Falls back to
# $CL_HERMES_SECRETS_PASSPHRASE for non-interactive use.
prompt_passphrase() {
    local mode="${1:-}"
    if [[ -n "${CL_HERMES_SECRETS_PASSPHRASE:-}" ]]; then
        printf '%s' "$CL_HERMES_SECRETS_PASSPHRASE"; return 0
    fi
    [[ -r /dev/tty ]] || return 1
    local p1 p2
    printf 'Passphrase for secrets: ' > /dev/tty
    IFS= read -rs p1 < /dev/tty; echo > /dev/tty
    [[ -n "$p1" ]] || return 1
    if [[ "$mode" == "confirm" ]]; then
        printf 'Repeat passphrase: ' > /dev/tty
        IFS= read -rs p2 < /dev/tty; echo > /dev/tty
        [[ "$p1" == "$p2" ]] || { log_error "Passphrases do not match."; return 1; }
    fi
    printf '%s' "$p1"
}

# encrypt_file <backend> <in> <out> <passphrase>
encrypt_file() {
    local backend="$1" in="$2" out="$3" pass="$4"
    case "$backend" in
        age)
            printf '%s' "$pass" | age -p -o "$out" "$in" >/dev/null 2>&1 \
                || AGE_PASSPHRASE="$pass" age -p -o "$out" "$in" ;;
        openssl)
            printf '%s' "$pass" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
                -in "$in" -out "$out" -pass stdin ;;
        *) return 1 ;;
    esac
}

# decrypt_file <backend> <in> <out> <passphrase>
decrypt_file() {
    local backend="$1" in="$2" out="$3" pass="$4"
    case "$backend" in
        age)
            printf '%s' "$pass" | age -d -o "$out" "$in" >/dev/null 2>&1 \
                || AGE_PASSPHRASE="$pass" age -d -o "$out" "$in" ;;
        openssl)
            printf '%s' "$pass" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
                -in "$in" -out "$out" -pass stdin ;;
        *) return 1 ;;
    esac
}

# True if gpg is present and holds at least one secret key.
gpg_can_sign() {
    have gpg || return 1
    gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'
}

# Recursively copy a directory tree. Extra args are exclude patterns.
# Uses rsync when available (better filtering); falls back to tar piping.
copy_tree() {
    local src="$1" dst="$2"; shift 2
    local excludes=("$@")
    mkdir -p "$dst"
    if have rsync; then
        local args=(-a)
        local e
        for e in "${excludes[@]:-}"; do
            [[ -n "$e" ]] && args+=(--exclude="$e")
        done
        rsync "${args[@]}" "$src"/ "$dst"/
    else
        local tar_excl=()
        local e
        for e in "${excludes[@]:-}"; do
            [[ -n "$e" ]] && tar_excl+=(--exclude="$e")
        done
        ( cd "$src" && tar -cf - "${tar_excl[@]}" . ) | ( cd "$dst" && tar -xf - )
    fi
}

# Replace every literal occurrence of $2 with $3 inside file $1.
# Uses awk with index()/substr() so neither the needle nor the
# replacement is interpreted as a regular expression.
replace_literal() {
    local file="$1" search="$2" repl="$3" tmp
    [[ -n "$search" ]] || return 0
    grep -Fq -- "$search" "$file" 2>/dev/null || return 0
    tmp="$(mktemp "${file}.XXXXXX")"
    # Pass needle/replacement through the environment: awk does NOT process
    # backslash escapes in ENVIRON values (unlike -v assignments), so a
    # Windows path like C:\Users\x survives intact.
    _RL_S="$search" _RL_R="$repl" awk '
        BEGIN { s = ENVIRON["_RL_S"]; r = ENVIRON["_RL_R"] }
        {
            line = $0; out = ""
            while ( (p = index(line, s)) > 0 ) {
                out  = out substr(line, 1, p - 1) r
                line = substr(line, p + length(s))
            }
            print out line
        }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Ask a question on the controlling terminal. Echoes the answer (or the
# default) on stdout. Honors --yes and non-interactive stdin.
ask() {
    local prompt="$1" default="${2:-}"
    if $ASSUME_YES || [[ ! -r /dev/tty ]]; then
        printf '%s' "$default"; return 0
    fi
    local ans=""
    printf '%b' "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=""
    [[ -z "$ans" ]] && ans="$default"
    printf '%s' "$ans"
}

# Yes/No confirmation. Second arg "true" makes Yes the default.
confirm() {
    local msg="$1" default_yes="${2:-false}" hint def ans
    if [[ "$default_yes" == "true" ]]; then hint="[Y/n]"; def="y"; else hint="[y/N]"; def="n"; fi
    $ASSUME_YES && return 0
    ans="$(ask "$(printf '%b?%b %s %s ' "$YELLOW" "$NC" "$msg" "$hint")" "$def")"
    case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# Minimal flat-scalar JSON reader: json_get <file> <key>
json_get() {
    local file="$1" key="$2"
    grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}[:space:]]+)" "$file" 2>/dev/null \
        | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//'
}

# Read a flat JSON array of strings: json_get_array <file> <key> -> space-joined.
json_get_array() {
    local file="$1" key="$2"
    grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\[[^]]*\]" "$file" 2>/dev/null \
        | head -1 | sed 's/^[^[]*\[//; s/\]$//; s/"//g; s/,/ /g'
}

# JSON-escape a string value.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Guarded recursive delete: refuses to remove anything not strictly below
# $2. Prevents an empty/typo variable turning into "rm -rf /...".
rm_rf_under() {
    local target="$1" under="$2"
    [[ -n "$target" ]] || die "internal error: empty delete target"
    [[ -n "$under"  ]] || die "internal error: empty delete guard"
    case "$target" in
        "$under"/*) : ;;
        *) die "internal error: refusing to delete '$target' (outside '$under')" ;;
    esac
    rm -rf -- "$target"
}

# --- Configuration ---------------------------------------------------------

# Defaults (used when no config file, or config leaves a value unset).
CFG_SYNC_CONFIG=true
CFG_SYNC_SOUL=true
CFG_SYNC_SKILLS=true
CFG_SYNC_MEMORIES=true
CFG_SYNC_CRON=true
CFG_SYNC_PLUGINS=true
CFG_SYNC_SYNC=false
CFG_SYNC_SESSIONS=false
CFG_SYNC_SECRETS=false

CFG_HERMES_HOME=""                      # where the Hermes install lives
CFG_TEMPLATIZE_TARGETS="config cron memories"
CFG_SECRETS_ENCRYPT=true                # encrypt auth.json / .env inside the package
CFG_SIGN=false                          # detached-sign CHECKSUMS.sha256 with gpg
CFG_GPG_KEY=""                          # optional gpg key id / uid to sign with
CFG_WINDOWS_PATH_STYLE="msys"           # msys (/c/Users/x) | native (C:\Users\x)
CFG_POST_IMPORT_CHECKS=true             # warn about missing paths after import

# Per-OS path constants. Filled from the config file; sensible guesses
# otherwise. Order of PLACEHOLDER_NAMES matters only for display.
declare -A PH_LINUX PH_MACOS PH_WINDOWS
PLACEHOLDER_NAMES=(HOME OBSIDIAN_VAULT)

_default_home_for() {
    local os="$1" user="${USER:-${USERNAME:-user}}"
    case "$os" in
        linux)   printf '/home/%s' "$user" ;;
        macos)   printf '/Users/%s' "$user" ;;
        windows) printf '/c/Users/%s' "$user" ;;
    esac
}

CONFIG_FILE=""      # resolved config path (may stay empty)
CONFIG_SOURCE=""    # human description of where it came from

# Locate the configuration file. Priority:
#   1. --config <path>              (CLI, set before this runs)
#   2. $CL_HERMES_SYNC_CONFIG env var
#   3. cl-hermes-sync.conf next to this script   (documented default)
#   4. $XDG_CONFIG_HOME/cl-hermes-sync/config.conf  (fallback)
#   5. $HOME/.cl-hermes-sync.conf                    (fallback)
resolve_config_file() {
    if [[ -n "$CONFIG_FILE" ]]; then
        [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
        CONFIG_SOURCE="--config"
        return
    fi
    if [[ -n "${CL_HERMES_SYNC_CONFIG:-}" && -f "${CL_HERMES_SYNC_CONFIG:-}" ]]; then
        CONFIG_FILE="$CL_HERMES_SYNC_CONFIG"; CONFIG_SOURCE="\$CL_HERMES_SYNC_CONFIG"; return
    fi
    local candidates=(
        "$SCRIPT_DIR/cl-hermes-sync.conf"
        "${XDG_CONFIG_HOME:-$HOME/.config}/cl-hermes-sync/config.conf"
        "$HOME/.cl-hermes-sync.conf"
    )
    local c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then CONFIG_FILE="$c"; CONFIG_SOURCE="$c"; return; fi
    done
    CONFIG_FILE=""; CONFIG_SOURCE="(none - built-in defaults)"
}

# Sanity-check permissions before sourcing an executable config file.
config_is_safe() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    if have stat; then
        local owner mode
        owner="$(stat -c '%u' "$f" 2>/dev/null || stat -f '%u' "$f" 2>/dev/null || echo -1)"
        mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo '')"
        local me
        me="$(id -u 2>/dev/null || echo -2)"
        if [[ "$owner" != "-1" && "$owner" != "$me" ]]; then
            log_warn "Config $f is not owned by you - ignoring it."
            return 1
        fi
        # Reject if the group or "other" octal digit has the write bit set.
        if [[ "$mode" =~ ^[0-7]*([0-7])([0-7])$ ]]; then
            local grp="${BASH_REMATCH[1]}" oth="${BASH_REMATCH[2]}"
            if [[ "$grp" == [2367] || "$oth" == [2367] ]]; then
                log_warn "Config $f is group/world-writable ($mode) - ignoring it. Run: chmod 600 '$f'"
                return 1
            fi
        fi
    fi
    return 0
}

load_config() {
    resolve_config_file

    if [[ -n "$CONFIG_FILE" ]] && config_is_safe "$CONFIG_FILE"; then
        # shellcheck disable=SC1090
        set +u
        # Namespaced variables set by the file:
        #   CL_HERMES_SYNC_{CONFIG,SOUL,SKILLS,MEMORIES,CRON,PLUGINS,SYNC,SESSIONS,SECRETS}
        #   CL_HERMES_HOME_DIR
        #   CL_HERMES_TEMPLATIZE_TARGETS
        #   CL_HERMES_HOME_{LINUX,MACOS,WINDOWS}
        #   CL_HERMES_OBSIDIAN_VAULT_{LINUX,MACOS,WINDOWS}
        #   CL_HERMES_EXTRA_PLACEHOLDERS=(NAME ...)  + CL_HERMES_<NAME>_{LINUX,MACOS,WINDOWS}
        source "$CONFIG_FILE"
        set -u

        _cfg_bool() { case "${1:-}" in true|TRUE|1|yes|on) echo true ;; false|FALSE|0|no|off) echo false ;; *) echo "$2" ;; esac; }
        CFG_SYNC_CONFIG=$(_cfg_bool "${CL_HERMES_SYNC_CONFIG:-}"   "$CFG_SYNC_CONFIG")
        CFG_SYNC_SOUL=$(_cfg_bool   "${CL_HERMES_SYNC_SOUL:-}"     "$CFG_SYNC_SOUL")
        CFG_SYNC_SKILLS=$(_cfg_bool "${CL_HERMES_SYNC_SKILLS:-}"   "$CFG_SYNC_SKILLS")
        CFG_SYNC_MEMORIES=$(_cfg_bool "${CL_HERMES_SYNC_MEMORIES:-}" "$CFG_SYNC_MEMORIES")
        CFG_SYNC_CRON=$(_cfg_bool   "${CL_HERMES_SYNC_CRON:-}"     "$CFG_SYNC_CRON")
        CFG_SYNC_PLUGINS=$(_cfg_bool "${CL_HERMES_SYNC_PLUGINS:-}" "$CFG_SYNC_PLUGINS")
        CFG_SYNC_SYNC=$(_cfg_bool   "${CL_HERMES_SYNC_SYNC:-}"     "$CFG_SYNC_SYNC")
        CFG_SYNC_SESSIONS=$(_cfg_bool "${CL_HERMES_SYNC_SESSIONS:-}" "$CFG_SYNC_SESSIONS")
        CFG_SYNC_SECRETS=$(_cfg_bool "${CL_HERMES_SYNC_SECRETS:-}" "$CFG_SYNC_SECRETS")

        [[ -n "${CL_HERMES_HOME_DIR:-}" ]] && CFG_HERMES_HOME="$CL_HERMES_HOME_DIR"
        [[ -n "${CL_HERMES_TEMPLATIZE_TARGETS:-}" ]] && CFG_TEMPLATIZE_TARGETS="$CL_HERMES_TEMPLATIZE_TARGETS"
        CFG_SECRETS_ENCRYPT=$(_cfg_bool "${CL_HERMES_SECRETS_ENCRYPT:-}" "$CFG_SECRETS_ENCRYPT")
        CFG_SIGN=$(_cfg_bool "${CL_HERMES_SIGN:-}" "$CFG_SIGN")
        CFG_POST_IMPORT_CHECKS=$(_cfg_bool "${CL_HERMES_POST_IMPORT_CHECKS:-}" "$CFG_POST_IMPORT_CHECKS")
        [[ -n "${CL_HERMES_GPG_KEY:-}" ]] && CFG_GPG_KEY="$CL_HERMES_GPG_KEY"
        case "${CL_HERMES_WINDOWS_PATH_STYLE:-}" in
            msys|native) CFG_WINDOWS_PATH_STYLE="$CL_HERMES_WINDOWS_PATH_STYLE" ;;
        esac

        if [[ -n "${CL_HERMES_EXTRA_PLACEHOLDERS:-}" ]]; then
            local extra
            for extra in "${CL_HERMES_EXTRA_PLACEHOLDERS[@]}"; do
                [[ -n "$extra" ]] || continue
                extra="$(printf '%s' "$extra" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
                PLACEHOLDER_NAMES+=("$extra")
            done
        fi
    fi

    # Resolve the per-OS value for every placeholder name.
    local name os cfgvar val
    for name in "${PLACEHOLDER_NAMES[@]}"; do
        for os in LINUX MACOS WINDOWS; do
            cfgvar="CL_HERMES_${name}_${os}"
            val="${!cfgvar:-}"
            if [[ -z "$val" && "$name" == "HOME" ]]; then
                val="$(_default_home_for "$(echo "$os" | tr '[:upper:]' '[:lower:]')")"
            fi
            # Accept native Windows input (C:\Users\x) in the config; store MSYS form.
            [[ -n "$val" ]] && val="$(to_msys_path "$val")"
            case "$os" in
                LINUX)   PH_LINUX[$name]="$val" ;;
                MACOS)   PH_MACOS[$name]="$val" ;;
                WINDOWS) PH_WINDOWS[$name]="$val" ;;
            esac
        done
    done

    # Hermes home: config > $HERMES_HOME env > default.
    if [[ -z "$CFG_HERMES_HOME" ]]; then
        CFG_HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
    fi
}

# Return the placeholder value for <name> on <os> (linux|macos|windows).
ph_value() {
    local name="$1" os="$2"
    case "$os" in
        linux)   printf '%s' "${PH_LINUX[$name]:-}" ;;
        macos)   printf '%s' "${PH_MACOS[$name]:-}" ;;
        windows) printf '%s' "${PH_WINDOWS[$name]:-}" ;;
    esac
}

ph_token() { printf '%s%s%s' "$PLACEHOLDER_PREFIX" "$1" "$PLACEHOLDER_SUFFIX"; }

# --- Component <-> variable mapping --------------------------------------

# Echo the CFG_* variable name backing a component token.
component_var() {
    case "$1" in
        config)   echo CFG_SYNC_CONFIG ;;
        soul)     echo CFG_SYNC_SOUL ;;
        skills)   echo CFG_SYNC_SKILLS ;;
        memories) echo CFG_SYNC_MEMORIES ;;
        cron)     echo CFG_SYNC_CRON ;;
        plugins)  echo CFG_SYNC_PLUGINS ;;
        sync)     echo CFG_SYNC_SYNC ;;
        sessions) echo CFG_SYNC_SESSIONS ;;
        secrets)  echo CFG_SYNC_SECRETS ;;
        *) return 1 ;;
    esac
}

ALL_COMPONENTS=(config soul skills memories cron plugins sync sessions secrets)

component_enabled() {
    local var; var="$(component_var "$1")" || return 1
    [[ "${!var}" == "true" ]]
}

# Apply "--with a,b" / "--without c,d" style overrides.
apply_component_override() {
    local value="$1" csv="$2" tok var
    local toks=()
    IFS=',' read -r -a toks <<< "$csv"
    for tok in "${toks[@]}"; do
        tok="$(echo "$tok" | tr -d '[:space:]')"
        [[ -z "$tok" ]] && continue
        if ! var="$(component_var "$tok")"; then
            die "Unknown component: '$tok' (valid: ${ALL_COMPONENTS[*]})"
        fi
        printf -v "$var" '%s' "$value"
    done
}

# --- Help / version ----------------------------------------------------

show_version() {
    echo "cl-hermes-sync $VERSION (package format v$FORMAT_VERSION)"
    echo "License GPL-2.0-or-later. Copyright (C) 2026 Carlos Longarela."
}

show_help() {
    cat <<EOF
${BOLD}cl-hermes-sync $VERSION${NC} - Hermes Agent portable export / import

${BOLD}USAGE${NC}
    $SCRIPT_NAME export [options]
    $SCRIPT_NAME import <package> [options]
    $SCRIPT_NAME list   <package>
    $SCRIPT_NAME version
    $SCRIPT_NAME help

${BOLD}EXPORT OPTIONS${NC}
    --output PATH        Destination directory, or archive path with --tar
    --tar                Produce a .tar.gz archive (default: a directory)
    --os NAME            Force the SOURCE OS: linux | macos | windows
    --config PATH        Use this configuration file
    --with LIST          Force-include components (comma list)
    --without LIST       Force-exclude components (comma list)
    --no-secrets         Shortcut for --without secrets
    --encrypt-secrets / --no-encrypt-secrets
                         Encrypt auth.json / .env in the package (default: on;
                         needs age or openssl; passphrase asked on the tty or
                         taken from \$CL_HERMES_SECRETS_PASSPHRASE)
    --sign / --no-sign   GPG detached-sign CHECKSUMS.sha256 (needs a secret key)
    --gpg-key ID         Key id / uid to sign with
    --no-templatize      Do not turn paths into @@CL_HERMES_*@@ placeholders
    --force              Overwrite a non-package output path without asking
    --yes               Non-interactive: take defaults, never prompt
    -q, --quiet          Minimal output

    Components: ${ALL_COMPONENTS[*]}

${BOLD}IMPORT OPTIONS${NC}
    --os NAME            Force the TARGET OS: linux | macos | windows
    --config PATH        Config file to read placeholder values from
    --set NAME=PATH      Override one placeholder value (repeatable)
    --hermes-home PATH   Target Hermes home (default: \$HERMES_HOME or ~/.hermes)
    --windows-path-style msys|native
                         Path form when expanding for a Windows target
                         (msys: /c/Users/x  -  native: C:\\Users\\x)
    --with / --without LIST   Restrict which components are restored
    --no-templatize      Restore files without expanding placeholders
    --no-backup          Do not back up an existing Hermes home
    --no-verify          Skip checksum AND signature verification
    --no-verify-sig      Skip only the GPG signature check
    --dry-run            Show what would happen, change nothing
    --yes               Non-interactive
    -q, --quiet          Minimal output

${BOLD}CONFIG FILE${NC}
    Default location: cl-hermes-sync.conf next to this script.
    Copy cl-hermes-sync.conf.example to get started. It defines what is
    synced by default and the per-OS HOME / Obsidian vault / custom paths.

${BOLD}EXAMPLES${NC}
    $SCRIPT_NAME export --tar --output ~/hermes-\$(date +%F).tgz
    $SCRIPT_NAME export --without sessions,sync --no-secrets
    $SCRIPT_NAME export --with secrets --sign
    $SCRIPT_NAME list ~/hermes-2026-09-06.tgz
    $SCRIPT_NAME import ~/hermes-2026-09-06.tgz --os macos
    $SCRIPT_NAME import ./cl-hermes-sync --set HOME=/Users/carlos --dry-run
EOF
}

# --- Placeholder application ------------------------------------------

# Build the ordered list of "name<TAB>value" pairs for a given OS,
# longest value first so nested paths (vault under home) collapse cleanly.
_ordered_pairs_for_os() {
    local os="$1" name val
    for name in "${PLACEHOLDER_NAMES[@]}"; do
        val="$(ph_value "$name" "$os")"
        [[ -z "$val" || "$val" == "/" || ${#val} -lt 4 ]] && continue
        printf '%s\t%s\t%s\n' "${#val}" "$name" "$val"
    done | sort -rn | cut -f2-
}

# EXPORT: replace real paths with placeholders inside the package.
# Also collapses $HOME (the running user's home) for the HOME placeholder.
templatize_package() {
    local pkg_dir="$1" source_os="$2"
    shift 2
    local targets=("$@")
    local -a files=()
    local part sub name val token line

    for part in "${targets[@]}"; do
        case "$part" in
            config)   [[ -f "$pkg_dir/config.yaml" ]] && files+=("$pkg_dir/config.yaml") ;;
            cron|memories|plugins|skills|sync)
                if [[ -d "$pkg_dir/$part" ]]; then
                    while IFS= read -r -d '' sub; do files+=("$sub"); done \
                        < <(find "$pkg_dir/$part" -type f -print0)
                fi ;;
        esac
    done

    local count=0 f
    for f in "${files[@]:-}"; do
        [[ -n "$f" ]] || continue
        is_text_file "$f" || continue
        local changed_here=false
        while IFS=$'\t' read -r name val; do
            [[ -n "$name" ]] || continue
            token="$(ph_token "$name")"
            if grep -Fq -- "$val" "$f" 2>/dev/null; then
                replace_literal "$f" "$val" "$token"
                changed_here=true
                PLACEHOLDERS_USED[$name]=1
            fi
        done < <(_ordered_pairs_for_os "$source_os")

        # Also fold the live $HOME into @@CL_HERMES_HOME@@.
        if [[ -n "${HOME:-}" && ${#HOME} -ge 4 && "$HOME" != "/" ]]; then
            token="$(ph_token HOME)"
            if grep -Fq -- "$HOME" "$f" 2>/dev/null; then
                replace_literal "$f" "$HOME" "$token"
                changed_here=true
                PLACEHOLDERS_USED[HOME]=1
            fi
        fi
        if $changed_here; then count=$((count + 1)); fi
    done
    TEMPLATIZED_FILE_COUNT=$count
}

# IMPORT: expand placeholders back to real paths for the target OS.
expand_package() {
    local pkg_dir="$1" target_os="$2"
    shift 2
    local targets=("$@")
    local -a files=()
    local part sub name token val

    for part in "${targets[@]}"; do
        case "$part" in
            config)   [[ -f "$pkg_dir/config.yaml" ]] && files+=("$pkg_dir/config.yaml") ;;
            cron|memories|plugins|skills|sync)
                if [[ -d "$pkg_dir/$part" ]]; then
                    while IFS= read -r -d '' sub; do files+=("$sub"); done \
                        < <(find "$pkg_dir/$part" -type f -print0)
                fi ;;
        esac
    done

    local count=0 f
    for f in "${files[@]:-}"; do
        [[ -n "$f" ]] || continue
        is_text_file "$f" || continue
        local changed_here=false
        for name in "${PLACEHOLDER_NAMES[@]}"; do
            token="$(ph_token "$name")"
            grep -Fq -- "$token" "$f" 2>/dev/null || continue
            val="$(ph_value "$name" "$target_os")"
            if [[ -z "$val" ]]; then
                log_warn "Placeholder $token in $(basename "$f") has no value for '$target_os' - left as-is."
                continue
            fi
            if [[ "$target_os" == "windows" && "$CFG_WINDOWS_PATH_STYLE" == "native" ]]; then
                val="$(to_native_win_path "$val")"
            fi
            replace_literal "$f" "$token" "$val"
            changed_here=true
        done
        if $changed_here; then count=$((count + 1)); fi
    done
    EXPANDED_FILE_COUNT=$count
}

# --- paths.map (portable placeholder table shipped in the package) ------

write_paths_map() {
    local path="$1" name
    {
        echo "# cl-hermes-sync placeholder table - auto-generated, do not edit."
        echo "# Sourced by 'import' to expand @@CL_HERMES_*@@ placeholders."
        echo "CL_HERMES_PLACEHOLDER_NAMES=(${PLACEHOLDER_NAMES[*]})"
        printf 'CL_HERMES_WINDOWS_PATH_STYLE=%q\n' "$CFG_WINDOWS_PATH_STYLE"
        for name in "${PLACEHOLDER_NAMES[@]}"; do
            printf 'CL_HERMES_%s_LINUX=%q\n'   "$name" "${PH_LINUX[$name]:-}"
            printf 'CL_HERMES_%s_MACOS=%q\n'   "$name" "${PH_MACOS[$name]:-}"
            printf 'CL_HERMES_%s_WINDOWS=%q\n' "$name" "${PH_WINDOWS[$name]:-}"
        done
    } > "$path"
}

# Load a package paths.map into PH_* (safe: values are %q-quoted scalars).
load_paths_map() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    if have grep && grep -qvE '^[[:space:]]*(#|CL_HERMES_[A-Z0-9_]+=|CL_HERMES_PLACEHOLDER_NAMES=\(|$)' "$path"; then
        log_warn "paths.map has unexpected content - ignoring it."
        return 1
    fi
    set +u
    # shellcheck disable=SC1090
    source "$path"
    set -u
    case "${CL_HERMES_WINDOWS_PATH_STYLE:-}" in
        msys|native) CFG_WINDOWS_PATH_STYLE="$CL_HERMES_WINDOWS_PATH_STYLE" ;;
    esac
    local name
    PLACEHOLDER_NAMES=(${CL_HERMES_PLACEHOLDER_NAMES[@]:-HOME OBSIDIAN_VAULT})
    for name in "${PLACEHOLDER_NAMES[@]}"; do
        local l="CL_HERMES_${name}_LINUX" m="CL_HERMES_${name}_MACOS" w="CL_HERMES_${name}_WINDOWS"
        PH_LINUX[$name]="${!l:-}"
        PH_MACOS[$name]="${!m:-}"
        PH_WINDOWS[$name]="${!w:-}"
    done
}

# --- CHECKSUMS --------------------------------------------------------

write_checksums() {
    local pkg_dir="$1" out="$pkg_dir/CHECKSUMS.sha256" rel
    ( cd "$pkg_dir" && find . -type f ! -name CHECKSUMS.sha256 -print0 \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' rel; do
              printf '%s  %s\n' "$(sha256_file "$rel")" "${rel#./}"
          done ) > "$out"
}

verify_checksums() {
    local pkg_dir="$1" file="$pkg_dir/CHECKSUMS.sha256" bad=0 hash rel got
    [[ -f "$file" ]] || { log_warn "No CHECKSUMS.sha256 in package - cannot verify integrity."; return 0; }
    while read -r hash rel; do
        [[ -n "$hash" && -n "$rel" ]] || continue
        if [[ ! -f "$pkg_dir/$rel" ]]; then
            log_error "Missing file listed in checksums: $rel"; bad=$((bad + 1)); continue
        fi
        got="$(sha256_file "$pkg_dir/$rel")"
        if [[ "$got" != "$hash" ]]; then
            log_error "Checksum mismatch: $rel"; bad=$((bad + 1))
        fi
    done < "$file"
    if [[ $bad -gt 0 ]]; then
        return 1
    fi
    log_ok "Package integrity verified ($(wc -l < "$file" | tr -d ' ') files)."
    return 0
}

# --- Post-import path checks ----------------------------------------

# Warn about absolute paths in the restored config that do not exist on
# this machine, plus any resolved placeholder target that is missing.
post_import_checks() {
    local hermes_home="$1" target_os="$2"
    local missing=() seen=" " p name val cfg="$hermes_home/config.yaml"

    if [[ -f "$cfg" ]]; then
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            case "$seen" in *" $p "*) continue ;; esac
            seen="$seen$p "
            [[ -e "$p" ]] || missing+=("$p  (config.yaml)")
        done < <(grep -oE '(/[A-Za-z0-9._-]+)+|[A-Za-z]:\\[^"'"'"' ]+' "$cfg" 2>/dev/null \
                    | grep -vE '^/(bin|usr|etc|opt|var|tmp|dev|proc|sys)(/|$)' || true)
    fi

    for name in "${PLACEHOLDER_NAMES[@]}"; do
        val="$(ph_value "$name" "$target_os")"
        [[ -n "$val" ]] || continue
        case "$seen" in *" $val "*) continue ;; esac
        seen="$seen$val "
        [[ -e "$val" ]] || missing+=("$val  ($(ph_token "$name"))")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Post-import: these paths do not exist on this machine:"
        for p in "${missing[@]}"; do echo "    - $p" >&2; done
        log_warn "Create them, or fix config.yaml / re-run with --set NAME=PATH."
    else
        $QUIET || log_ok "Post-import checks: all referenced paths exist."
    fi
}

# --- tarball helpers ------------------------------------------------

# Refuse archives with absolute or parent-traversing members.
tar_is_safe() {
    local archive="$1" member
    while IFS= read -r member; do
        case "$member" in
            /*|*/../*|../*|*/..) log_error "Unsafe path in archive: $member"; return 1 ;;
        esac
    done < <(tar -tzf "$archive")
    return 0
}

extract_package() {
    local archive="$1" dest="$2"
    tar_is_safe "$archive" || die "Refusing to extract '$archive'."
    tar -xzf "$archive" -C "$dest" --no-same-owner 2>/dev/null \
        || tar -xzf "$archive" -C "$dest"
}

# Given a path (dir or archive), return a ready-to-read package dir.
stage_package() {
    local src="$1" tmp pkg
    [[ -e "$src" ]] || die "Package not found: $src"
    if [[ -d "$src" ]]; then
        [[ -f "$src/manifest.json" ]] || die "Not a cl-hermes-sync package (no manifest.json): $src"
        printf '%s' "$src"; return
    fi
    case "$src" in
        *.tgz|*.tar.gz|*.tar)
            tmp="$(_mktemp_dir)"
            extract_package "$src" "$tmp"
            if [[ -f "$tmp/$PACKAGE_ROOT_NAME/manifest.json" ]]; then
                pkg="$tmp/$PACKAGE_ROOT_NAME"
            else
                pkg="$(find "$tmp" -maxdepth 3 -name manifest.json -exec dirname {} \; 2>/dev/null | head -1)"
            fi
            [[ -n "$pkg" && -f "$pkg/manifest.json" ]] || die "No manifest.json inside archive: $src"
            printf '%s' "$pkg" ;;
        *)
            die "Unrecognized package type: $src (expected a directory or .tgz/.tar.gz)" ;;
    esac
}

# --- EXPORT -----------------------------------------------------------

declare -A PLACEHOLDERS_USED
TEMPLATIZED_FILE_COUNT=0
EXPANDED_FILE_COUNT=0
SIGNED=false

do_export() {
    local output="" do_tar=false force=false no_templatize=false
    local source_os=""
    local encrypt_secrets="" sign_pkg="" gpg_key=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)        output="${2:?--output needs a path}"; shift 2 ;;
            --output=*)      output="${1#*=}"; shift ;;
            --tar)           do_tar=true; shift ;;
            --os)            source_os="${2:?--os needs a value}"; shift 2 ;;
            --os=*)          source_os="${1#*=}"; shift ;;
            --config)        CONFIG_FILE="${2:?}"; shift 2 ;;
            --config=*)      CONFIG_FILE="${1#*=}"; shift ;;
            --with)          _pending_with="${2:?}"; shift 2 ;;
            --with=*)        _pending_with="${1#*=}"; shift ;;
            --without)       _pending_without="${2:?}"; shift 2 ;;
            --without=*)     _pending_without="${1#*=}"; shift ;;
            --no-secrets)    _pending_without="${_pending_without:+$_pending_without,}secrets"; shift ;;
            --encrypt-secrets)    encrypt_secrets=true; shift ;;
            --no-encrypt-secrets) encrypt_secrets=false; shift ;;
            --sign)          sign_pkg=true; shift ;;
            --no-sign)       sign_pkg=false; shift ;;
            --gpg-key)       gpg_key="${2:?}"; shift 2 ;;
            --gpg-key=*)     gpg_key="${1#*=}"; shift ;;
            --no-templatize) no_templatize=true; shift ;;
            --force)         force=true; shift ;;
            --yes|-y)        ASSUME_YES=true; shift ;;
            -q|--quiet)      QUIET=true; shift ;;
            -h|--help)       show_help; exit 0 ;;
            *) die "Unknown export option: $1" ;;
        esac
    done

    load_config
    [[ -n "$encrypt_secrets" ]] && CFG_SECRETS_ENCRYPT="$encrypt_secrets"
    [[ -n "$sign_pkg" ]]        && CFG_SIGN="$sign_pkg"
    [[ -n "$gpg_key" ]]         && CFG_GPG_KEY="$gpg_key"
    encrypt_secrets="$CFG_SECRETS_ENCRYPT"

    # Decide up front whether the package will be signed.
    if [[ "$CFG_SIGN" == "true" ]]; then
        if gpg_can_sign; then
            SIGNED=true
        else
            log_warn "--sign requested but gpg has no usable secret key - package will be UNSIGNED."
        fi
    fi
    [[ -n "${_pending_with:-}" ]]    && apply_component_override true  "$_pending_with"
    [[ -n "${_pending_without:-}" ]] && apply_component_override false "$_pending_without"

    [[ -z "$source_os" ]] && source_os="$(detect_os)"
    case "$source_os" in
        linux|macos|windows) : ;;
        unknown) die "Could not detect the OS. Pass --os linux|macos|windows." ;;
        *) die "Invalid --os '$source_os' (linux|macos|windows)" ;;
    esac

    local hermes_home="$CFG_HERMES_HOME"
    [[ -d "$hermes_home" ]] || die "Hermes home not found: $hermes_home (set CL_HERMES_HOME_DIR, \$HERMES_HOME, or --config)"

    # Resolve output path.
    if [[ -z "$output" ]]; then
        if $do_tar; then
            output="cl-hermes-sync-$(date +%Y%m%d-%H%M%S).tgz"
        else
            output="cl-hermes-sync"
        fi
    fi
    # Make it absolute: finalize runs tar from inside a temp dir.
    case "$output" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *) output="$PWD/$output" ;;
    esac

    local templatize_targets=()
    read -r -a templatize_targets <<< "$CFG_TEMPLATIZE_TARGETS"
    if $no_templatize; then templatize_targets=(); fi

    log_step "Exporting Hermes Agent from $hermes_home"

    local temp_dir pkg_dir
    temp_dir="$(_mktemp_dir)"
    pkg_dir="$temp_dir/$PACKAGE_ROOT_NAME"
    mkdir -p "$pkg_dir"

    # --- config.yaml ---
    if component_enabled config && [[ -f "$hermes_home/config.yaml" ]]; then
        cp "$hermes_home/config.yaml" "$pkg_dir/config.yaml"
        log_ok "config.yaml ($(wc -c < "$pkg_dir/config.yaml" | tr -d ' ') bytes)"
    elif component_enabled config; then
        log_warn "config.yaml not found in $hermes_home"
    fi

    # --- SOUL.md ---
    if component_enabled soul && [[ -f "$hermes_home/SOUL.md" ]]; then
        cp "$hermes_home/SOUL.md" "$pkg_dir/SOUL.md"
        log_ok "SOUL.md ($(wc -c < "$pkg_dir/SOUL.md" | tr -d ' ') bytes)"
    fi

    # --- skills/ ---
    if component_enabled skills && [[ -d "$hermes_home/skills" ]]; then
        copy_tree "$hermes_home/skills" "$pkg_dir/skills" ".skills_prompt_snapshot.json"
        log_ok "skills/ ($(find "$pkg_dir/skills" -type f | wc -l | tr -d ' ') files)"
    fi

    # --- memories/ ---
    if component_enabled memories && [[ -d "$hermes_home/memories" ]]; then
        copy_tree "$hermes_home/memories" "$pkg_dir/memories"
        log_ok "memories/ ($(find "$pkg_dir/memories" -type f | wc -l | tr -d ' ') files)"
    fi

    # --- cron/ ---
    if component_enabled cron && [[ -d "$hermes_home/cron" ]]; then
        copy_tree "$hermes_home/cron" "$pkg_dir/cron"
        log_ok "cron/ ($(find "$pkg_dir/cron" -type f | wc -l | tr -d ' ') jobs)"
    fi

    # --- plugins/ (config files only) ---
    if component_enabled plugins && [[ -d "$hermes_home/plugins" ]]; then
        mkdir -p "$pkg_dir/plugins"
        local rel
        while IFS= read -r -d '' rel; do
            rel="${rel#"$hermes_home"/}"
            mkdir -p "$pkg_dir/$(dirname "$rel")"
            cp "$hermes_home/$rel" "$pkg_dir/$rel"
        done < <(find "$hermes_home/plugins" -type f \
                    \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.toml' \) -print0)
        log_ok "plugins/ ($(find "$pkg_dir/plugins" -type f 2>/dev/null | wc -l | tr -d ' ') config files)"
    fi

    # --- sync/ (opt-in) ---
    if component_enabled sync && [[ -d "$hermes_home/sync" ]]; then
        copy_tree "$hermes_home/sync" "$pkg_dir/sync" "*.db-wal" "*.db-shm"
        log_ok "sync/ ($(find "$pkg_dir/sync" -type f | wc -l | tr -d ' ') files)"
    elif component_enabled sync; then
        log_info "sync/ requested but $hermes_home/sync does not exist."
    else
        log_info "sync/ excluded (enable with --with sync)."
    fi

    # --- sessions/ + state.db (opt-in) ---
    if component_enabled sessions && [[ -d "$hermes_home/sessions" ]]; then
        copy_tree "$hermes_home/sessions" "$pkg_dir/sessions"
        log_ok "sessions/ included"
        if [[ -f "$hermes_home/state.db" ]]; then
            cp "$hermes_home/state.db" "$pkg_dir/state.db" 2>/dev/null \
                && log_ok "state.db included" \
                || log_warn "state.db is busy (Hermes running?) - skipped."
        fi
    else
        log_info "sessions/ excluded (enable with --with sessions)."
    fi

    # --- secrets (opt-in, always confirmed unless --yes) ---
    local has_auth=false has_env=false secrets_encryption="none"
    if component_enabled secrets; then
        mkdir -p "$pkg_dir/auth"

        # Decide on encryption.
        local enc_backend="" enc_pass=""
        if $encrypt_secrets; then
            enc_backend="$(crypto_backend)"
            if [[ -z "$enc_backend" ]]; then
                log_warn "No 'age' or 'openssl' found - secrets would be stored in PLAINTEXT."
                if $ASSUME_YES; then
                    die "Refusing to package plaintext secrets non-interactively. Install age/openssl or pass --no-encrypt-secrets."
                fi
                confirm "Store secrets unencrypted?" false || die "Aborted."
            else
                enc_pass="$(prompt_passphrase confirm || true)"
                if [[ -z "$enc_pass" ]]; then
                    $ASSUME_YES && die "No passphrase for secret encryption (set \$CL_HERMES_SECRETS_PASSPHRASE)."
                    confirm "No passphrase given. Store secrets unencrypted?" false || die "Aborted."
                    enc_backend=""
                else
                    secrets_encryption="$enc_backend"
                fi
            fi
        else
            log_warn "--no-encrypt-secrets: auth.json / .env will be stored in PLAINTEXT."
        fi

        _pack_secret() {
            local src="$1" base="$2" label="$3"
            [[ -f "$src" ]] || return 0
            $ASSUME_YES || confirm "Include $label?" false || return 0
            if [[ -n "$enc_backend" && -n "$enc_pass" ]]; then
                if encrypt_file "$enc_backend" "$src" "$pkg_dir/auth/$base.enc" "$enc_pass"; then
                    chmod 600 "$pkg_dir/auth/$base.enc"; log_ok "$base included (encrypted, $enc_backend)"
                else
                    log_error "Encryption of $base failed - skipped."; return 0
                fi
            else
                cp "$src" "$pkg_dir/auth/$base"; chmod 600 "$pkg_dir/auth/$base"
                log_warn "$base included UNENCRYPTED."
            fi
            return 0
        }
        _pack_secret "$hermes_home/auth.json" "auth.json" "auth.json (login tokens)" && \
            { [[ -e "$pkg_dir/auth/auth.json" || -e "$pkg_dir/auth/auth.json.enc" ]] && has_auth=true; }
        _pack_secret "$hermes_home/.env" ".env" ".env (API keys - real secrets)" && \
            { [[ -e "$pkg_dir/auth/.env" || -e "$pkg_dir/auth/.env.enc" ]] && has_env=true; }

        [[ "$has_auth" == "false" && "$has_env" == "false" ]] && rmdir "$pkg_dir/auth" 2>/dev/null || true
    else
        log_info "secrets excluded (enable with --with secrets)."
    fi

    # --- path templatization ---
    if [[ ${#templatize_targets[@]} -gt 0 ]]; then
        log_step "Replacing machine paths with placeholders (${templatize_targets[*]})"
        templatize_package "$pkg_dir" "$source_os" "${templatize_targets[@]}"
        if [[ $TEMPLATIZED_FILE_COUNT -gt 0 ]]; then
            log_ok "Templatized $TEMPLATIZED_FILE_COUNT file(s): ${!PLACEHOLDERS_USED[*]}"
        else
            log_info "No paths matched - nothing to templatize."
        fi
    else
        log_info "Path templatization disabled."
    fi

    # --- paths.map ---
    write_paths_map "$pkg_dir/paths.map"

    # --- manifest.json ---
    local hermes_ver host_str
    hermes_ver="$(hermes --version 2>/dev/null | head -1 | tr -d '\r\n' || echo unknown)"
    host_str="$(hostname 2>/dev/null || echo unknown)"

    {
        printf '{\n'
        printf '  "format_version": %s,\n' "$FORMAT_VERSION"
        printf '  "tool_version": "%s",\n' "$VERSION"
        printf '  "exported_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "source_device": "%s",\n' "$(json_escape "$host_str")"
        printf '  "source_os": "%s",\n' "$source_os"
        printf '  "hermes_version": "%s",\n' "$(json_escape "$hermes_ver")"
        printf '  "templatized_targets": [%s],\n' \
            "$( [[ ${#templatize_targets[@]} -gt 0 ]] && printf '"%s"' "${templatize_targets[0]}" && \
                for t in "${templatize_targets[@]:1}"; do printf ', "%s"' "$t"; done )"
        printf '  "placeholders_used": [%s],\n' \
            "$( first=true; for k in "${!PLACEHOLDERS_USED[@]}"; do
                    $first && first=false || printf ', '; printf '"%s"' "$k"; done )"
        printf '  "contents": {\n'
        local c first=true
        for c in "${ALL_COMPONENTS[@]}"; do
            $first && first=false || printf ',\n'
            printf '    "%s": %s' "$c" "$(component_enabled "$c" && echo true || echo false)"
        done
        printf '\n  },\n'
        printf '  "secrets": { "auth": %s, "env": %s },\n' "$has_auth" "$has_env"
        printf '  "secrets_encryption": "%s",\n' "$secrets_encryption"
        printf '  "windows_path_style": "%s",\n' "$CFG_WINDOWS_PATH_STYLE"
        printf '  "signed": %s,\n' "$SIGNED"
        printf '  "summary": {\n'
        printf '    "skills_files": %s,\n'   "$(find "$pkg_dir/skills"   -type f 2>/dev/null | wc -l | tr -d ' ')"
        printf '    "memories_files": %s,\n' "$(find "$pkg_dir/memories" -type f 2>/dev/null | wc -l | tr -d ' ')"
        printf '    "cron_files": %s\n'      "$(find "$pkg_dir/cron"     -type f 2>/dev/null | wc -l | tr -d ' ')"
        printf '  }\n'
        printf '}\n'
    } > "$pkg_dir/manifest.json"

    # --- bundled restore helpers ---
    cp "${BASH_SOURCE[0]}" "$pkg_dir/cl-hermes-sync.sh"
    chmod +x "$pkg_dir/cl-hermes-sync.sh"
    cat > "$pkg_dir/setup.sh" <<'SETUP_EOF'
#!/bin/sh
# Auto-generated thin wrapper. Restores this package on the current machine.
# It simply calls the bundled cl-hermes-sync.sh in import mode.
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec bash "$d/cl-hermes-sync.sh" import "$d" "$@"
SETUP_EOF
    chmod +x "$pkg_dir/setup.sh"

    {
        echo "# Hermes Agent portable package (format v$FORMAT_VERSION)"
        echo
        echo "Exported from $host_str ($source_os) at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
        echo
        echo "## Restore"
        echo
        echo '    ./setup.sh                 # uses the bundled tool'
        echo "    cl-hermes-sync.sh import .  # if the tool is already installed"
        echo
        echo "Import auto-detects the target OS and expands @@CL_HERMES_*@@"
        echo "placeholders using paths.map. Override with --os / --set NAME=PATH."
        echo
        echo "## Notes"
        echo
        echo "- Hermes Agent core must be installed separately on the target."
        echo "- manifest.json holds metadata; CHECKSUMS.sha256 holds integrity hashes."
    } > "$pkg_dir/README.md"

    # --- checksums (last, so every shipped file is covered) ---
    write_checksums "$pkg_dir"

    # --- signature (detached, over CHECKSUMS.sha256) ---
    if [[ "$SIGNED" == "true" ]]; then
        local gpg_args=(--armor --batch --yes --detach-sign
                        --output "$pkg_dir/CHECKSUMS.sha256.asc")
        [[ -n "$CFG_GPG_KEY" ]] && gpg_args+=(--local-user "$CFG_GPG_KEY")
        if gpg "${gpg_args[@]}" "$pkg_dir/CHECKSUMS.sha256" 2>/dev/null; then
            log_ok "Signed CHECKSUMS.sha256 (CHECKSUMS.sha256.asc)."
        else
            log_warn "gpg signing failed - package left unsigned."
            SIGNED=false
        fi
    fi

    # --- finalize (directory or archive) ---
    local final_size
    if $do_tar; then
        [[ "$output" == *.tgz || "$output" == *.tar.gz ]] \
            || die "--tar output must end in .tgz or .tar.gz (got: $output)"
        mkdir -p "$(dirname "$output")"
        if [[ -e "$output" ]] && ! $force; then
            confirm "Overwrite existing file $output?" false || die "Aborted."
        fi
        ( cd "$temp_dir" && tar -czf "$output" "$PACKAGE_ROOT_NAME/" )
        final_size="$(du -h "$output" | cut -f1)"
    else
        mkdir -p "$(dirname "$output")"
        if [[ -e "$output" ]]; then
            if [[ -f "$output/manifest.json" ]] || $force; then
                rm -rf -- "$output"
            elif confirm "Path $output exists and is not a package. Overwrite?" false; then
                rm -rf -- "$output"
            else
                die "Aborted."
            fi
        fi
        mv "$pkg_dir" "$output"
        final_size="$(du -sh "$output" | cut -f1)"
    fi

    # --- summary ---
    if ! $QUIET; then
        echo
        echo -e "${GREEN}${BOLD}  Export complete${NC}"
        echo    "  ---------------------------------------------"
        printf  "  Source OS      : %s\n" "$source_os"
        printf  "  Hermes home    : %s\n" "$hermes_home"
        printf  "  Hermes version : %s\n" "$hermes_ver"
        printf  "  Config file    : %s\n" "$CONFIG_SOURCE"
        printf  "  Components     : "
        local shown=false
        for c in "${ALL_COMPONENTS[@]}"; do component_enabled "$c" && { printf '%s ' "$c"; shown=true; }; done
        $shown || printf '(none)'; echo
        if [[ "$has_auth" == "true" || "$has_env" == "true" ]]; then
            printf  "  Secrets        : %s\n" \
                "$( [[ "$secrets_encryption" == "none" ]] && echo 'PLAINTEXT (!)' || echo "encrypted ($secrets_encryption)")"
        fi
        printf  "  Signature      : %s\n" "$( [[ "$SIGNED" == "true" ]] && echo 'gpg detached (CHECKSUMS.sha256.asc)' || echo 'none')"
        if [[ ${#PLACEHOLDERS_USED[@]} -gt 0 ]]; then
            printf  "  Placeholders   : %s (%d file(s))\n" "${!PLACEHOLDERS_USED[*]}" "$TEMPLATIZED_FILE_COUNT"
            for k in "${!PLACEHOLDERS_USED[@]}"; do
                printf '    %s -> %s\n' "$(ph_token "$k")" "$(ph_value "$k" "$source_os")"
            done
        fi
        printf  "  Package        : %s (%s)\n" "$output" "$final_size"
        echo    "  ---------------------------------------------"
        echo    "  Restore elsewhere:"
        echo    "    cl-hermes-sync.sh import $output"
        echo
    else
        echo "$output"
    fi
}

# --- IMPORT ---------------------------------------------------------

do_import() {
    local src="" target_os="" hermes_home="" no_templatize=false
    local no_backup=false no_verify=false no_verify_sig=false dry_run=false
    local win_style_override=""
    local -a set_overrides=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --os)            target_os="${2:?}"; shift 2 ;;
            --os=*)          target_os="${1#*=}"; shift ;;
            --config)        CONFIG_FILE="${2:?}"; shift 2 ;;
            --config=*)      CONFIG_FILE="${1#*=}"; shift ;;
            --set)           set_overrides+=("${2:?}"); shift 2 ;;
            --set=*)         set_overrides+=("${1#*=}"); shift ;;
            --hermes-home)   hermes_home="${2:?}"; shift 2 ;;
            --hermes-home=*) hermes_home="${1#*=}"; shift ;;
            --windows-path-style)   win_style_override="${2:?}"; shift 2 ;;
            --windows-path-style=*) win_style_override="${1#*=}"; shift ;;
            --with)          _pending_with="${2:?}"; shift 2 ;;
            --with=*)        _pending_with="${1#*=}"; shift ;;
            --without)       _pending_without="${2:?}"; shift 2 ;;
            --without=*)     _pending_without="${1#*=}"; shift ;;
            --no-templatize) no_templatize=true; shift ;;
            --no-backup)     no_backup=true; shift ;;
            --no-verify)     no_verify=true; shift ;;
            --no-verify-sig) no_verify_sig=true; shift ;;
            --dry-run)       dry_run=true; shift ;;
            --yes|-y)        ASSUME_YES=true; shift ;;
            -q|--quiet)      QUIET=true; shift ;;
            -h|--help)       show_help; exit 0 ;;
            -*)              die "Unknown import option: $1" ;;
            *)               [[ -z "$src" ]] && src="$1" || die "Unexpected argument: $1"; shift ;;
        esac
    done

    [[ -n "$hermes_home" ]] && hermes_home="$(to_msys_path "$hermes_home")"

    [[ -n "$src" ]] || die "Usage: $SCRIPT_NAME import <package> [options]"

    load_config

    [[ -n "$hermes_home" ]] || hermes_home="$CFG_HERMES_HOME"
    [[ -n "$hermes_home" && "$hermes_home" != "/" ]] || die "Refusing to use Hermes home '$hermes_home'"

    local pkg_dir
    pkg_dir="$(stage_package "$src")"

    # Format gate.
    local fmt
    fmt="$(json_get "$pkg_dir/manifest.json" format_version)"
    if [[ "$fmt" != "$FORMAT_VERSION" ]]; then
        die "Package format v${fmt:-?} is not supported by cl-hermes-sync $VERSION (needs v$FORMAT_VERSION). Re-export with a matching tool."
    fi

    # On import, default to restoring exactly what the package contains;
    # --with / --without still let the user narrow or widen that.
    local _c _cv
    for _c in "${ALL_COMPONENTS[@]}"; do
        _cv="$(component_var "$_c")"
        if [[ "$(json_get "$pkg_dir/manifest.json" "$_c")" == "true" ]]; then
            printf -v "$_cv" 'true'
        else
            printf -v "$_cv" 'false'
        fi
    done
    [[ -n "${_pending_with:-}" ]]    && apply_component_override true  "$_pending_with"
    [[ -n "${_pending_without:-}" ]] && apply_component_override false "$_pending_without"

    # Integrity + authenticity.
    if ! $no_verify; then
        log_step "Verifying package integrity"
        if ! verify_checksums "$pkg_dir"; then
            $ASSUME_YES && die "Package integrity check failed (pass --no-verify to override deliberately)."
            confirm "Checksum problems found. Continue anyway?" false || die "Aborted."
        fi
        if [[ -f "$pkg_dir/CHECKSUMS.sha256.asc" ]] && ! $no_verify_sig; then
            if have gpg; then
                if gpg --verify "$pkg_dir/CHECKSUMS.sha256.asc" "$pkg_dir/CHECKSUMS.sha256" >/dev/null 2>&1; then
                    log_ok "GPG signature valid."
                else
                    log_error "GPG signature verification FAILED."
                    $ASSUME_YES && die "Refusing to import an unverifiable signed package (pass --no-verify-sig to override)."
                    confirm "Signature invalid. Continue anyway?" false || die "Aborted."
                fi
            else
                log_warn "Package is signed but 'gpg' is not installed - cannot verify authenticity."
            fi
        fi
    fi

    # Work on a private copy so a failed run never leaves half-written files.
    local work
    work="$(_mktemp_dir)"
    copy_tree "$pkg_dir" "$work/pkg"
    local wpkg="$work/pkg"

    # Placeholder table: package paths.map -> local config -> --set.
    load_paths_map "$wpkg/paths.map" || log_warn "Could not load paths.map from package."
    case "$win_style_override" in
        msys|native) CFG_WINDOWS_PATH_STYLE="$win_style_override" ;;
        "") : ;;
        *) die "--windows-path-style expects 'msys' or 'native'" ;;
    esac
    # Local config values (for the resolved target OS) win over the package's.
    local ov name val os_upper
    [[ -z "$target_os" ]] && target_os="$(detect_os)"

    _apply_local_config_over_map() {
        local n u
        for n in "${PLACEHOLDER_NAMES[@]}"; do
            for u in LINUX MACOS WINDOWS; do
                local cv="CL_HERMES_${n}_${u}"
                [[ -n "${!cv:-}" ]] || continue
                case "$u" in
                    LINUX)   PH_LINUX[$n]="${!cv}" ;;
                    MACOS)   PH_MACOS[$n]="${!cv}" ;;
                    WINDOWS) PH_WINDOWS[$n]="${!cv}" ;;
                esac
            done
        done
    }
    [[ -n "$CONFIG_FILE" ]] && _apply_local_config_over_map

    for ov in "${set_overrides[@]:-}"; do
        [[ -z "$ov" ]] && continue
        name="${ov%%=*}"; val="${ov#*=}"
        name="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
        [[ "$ov" == *=* && -n "$name" ]] || die "--set expects NAME=PATH (got: $ov)"
        val="$(to_msys_path "$val")"
        PH_LINUX[$name]="$val"; PH_MACOS[$name]="$val"; PH_WINDOWS[$name]="$val"
        case " ${PLACEHOLDER_NAMES[*]} " in *" $name "*) : ;; *) PLACEHOLDER_NAMES+=("$name") ;; esac
    done

    # --- interactive OS confirmation -----------------------------------
    _print_import_plan() {
        local os="$1" n
        echo
        echo -e "${CYAN}${BOLD}  Hermes Agent import${NC}"
        echo    "  ---------------------------------------------"
        printf  "  Package     : %s\n" "$src"
        printf  "  From        : %s @ %s\n" \
            "$(json_get "$pkg_dir/manifest.json" source_device)" \
            "$(json_get "$pkg_dir/manifest.json" exported_at)"
        printf  "  Source OS   : %s\n" "$(json_get "$pkg_dir/manifest.json" source_os)"
        printf  "  Target OS   : ${BOLD}%s${NC}%s\n" "$os" \
            "$( [[ -n "${_os_forced:-}" ]] && echo '  (forced with --os)' || echo '  (auto-detected)')"
        local _enc _sig
        _enc="$(json_get "$pkg_dir/manifest.json" secrets_encryption)"
        [[ -f "$pkg_dir/CHECKSUMS.sha256.asc" ]] && _sig="present" || _sig="none"
        [[ -d "$wpkg/auth" || -d "$pkg_dir/auth" ]] && \
            printf  "  Secrets     : %s\n" "$( [[ -z "$_enc" || "$_enc" == none ]] && echo 'PLAINTEXT (!)' || echo "encrypted ($_enc)")"
        printf  "  Signature   : %s\n" "$_sig"
        [[ "$os" == "windows" ]] && printf  "  Win paths   : %s\n" "$CFG_WINDOWS_PATH_STYLE"
        printf  "  Hermes home : %s\n" "$hermes_home"
        printf  "  Restore     : "
        local any=false c
        for c in "${ALL_COMPONENTS[@]}"; do
            if component_enabled "$c"; then printf '%s ' "$c"; any=true; fi
        done
        $any || printf '(nothing selected)'; echo
        echo    "  Placeholder table for $os:"
        for n in "${PLACEHOLDER_NAMES[@]}"; do
            printf '    %-28s -> %s\n' "$(ph_token "$n")" "$(ph_value "$n" "$os" || echo '(unset)')"
        done
        echo    "  ---------------------------------------------"
    }

    [[ "$target_os" != "$(detect_os)" ]] && _os_forced=1
    case "$target_os" in linux|macos|windows) : ;; *) target_os="unknown" ;; esac

    while :; do
        [[ "$target_os" == "unknown" ]] && { log_warn "OS not detected."; target_os=linux; }
        { $QUIET && $ASSUME_YES; } || _print_import_plan "$target_os"
        if $ASSUME_YES; then break; fi
        if confirm "Is the target OS correct ($target_os)?" true; then break; fi
        local pick
        pick="$(ask "$(printf '  Choose OS [linux/macos/windows]: ')" "$target_os")"
        case "$pick" in linux|macos|windows) target_os="$pick"; _os_forced=1 ;; *) log_warn "Invalid choice." ;; esac
    done

    # Warn about placeholders that will be used but have no value.
    local missing=()
    local tok
    for name in "${PLACEHOLDER_NAMES[@]}"; do
        tok="$(ph_token "$name")"
        if grep -rIlq -- "$tok" "$wpkg" 2>/dev/null && [[ -z "$(ph_value "$name" "$target_os")" ]]; then
            missing+=("$name")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "No value for placeholders on $target_os: ${missing[*]}"
        log_warn "Provide them with --set NAME=PATH or a config file, or they stay literal."
        $ASSUME_YES || confirm "Continue regardless?" false || die "Aborted."
    fi

    if $dry_run; then
        echo
        log_info "Dry run - no changes made."
        return 0
    fi

    $ASSUME_YES || confirm "Proceed with the restore?" false || die "Aborted."

    # --- expand placeholders in the working copy ----------------------
    if ! $no_templatize; then
        local targets=()
        read -r -a targets <<< "$(json_get_array "$pkg_dir/manifest.json" templatized_targets)"
        [[ ${#targets[@]} -eq 0 ]] && read -r -a targets <<< "$CFG_TEMPLATIZE_TARGETS"
        log_step "Expanding placeholders for $target_os (${targets[*]})"
        expand_package "$wpkg" "$target_os" "${targets[@]}"
        log_ok "Expanded $EXPANDED_FILE_COUNT file(s)."
    fi

    # --- backup existing home ---------------------------------------
    if [[ -d "$hermes_home" ]] && ! $no_backup; then
        local backup="${hermes_home}.bak.$(date +%Y%m%d-%H%M%S)"
        log_step "Backing up $hermes_home -> $backup"
        mkdir -p "$backup"
        local item
        for item in config.yaml SOUL.md skills memories cron plugins sync auth.json .env state.db; do
            [[ -e "$hermes_home/$item" ]] && cp -r "$hermes_home/$item" "$backup/" 2>/dev/null || true
        done
        log_ok "Backup created."
    fi
    mkdir -p "$hermes_home"

    # --- restore components ---------------------------------------
    _restore_file() {
        local rel="$1"
        [[ -f "$wpkg/$rel" ]] || return 0
        mkdir -p "$hermes_home/$(dirname "$rel")"
        cp "$wpkg/$rel" "$hermes_home/$rel"
        log_ok "$rel restored"
    }
    _restore_dir() {
        local rel="$1"
        [[ -d "$wpkg/$rel" ]] || return 0
        rm_rf_under "$hermes_home/$rel" "$hermes_home"
        mkdir -p "$hermes_home/$rel"
        copy_tree "$wpkg/$rel" "$hermes_home/$rel"
        log_ok "$rel/ restored ($(find "$hermes_home/$rel" -type f | wc -l | tr -d ' ') files)"
    }

    log_step "Restoring into $hermes_home"
    if component_enabled config;   then _restore_file "config.yaml"; fi
    if component_enabled soul;     then _restore_file "SOUL.md";     fi
    if component_enabled skills;   then _restore_dir  "skills";      fi
    if component_enabled memories; then _restore_dir  "memories";    fi
    if component_enabled cron;     then _restore_dir  "cron";        fi
    if component_enabled plugins;  then _restore_dir  "plugins";     fi
    if component_enabled sync;     then _restore_dir  "sync";        fi
    if component_enabled sessions; then _restore_dir  "sessions";    fi
    if component_enabled sessions && [[ -f "$wpkg/state.db" ]]; then
        if [[ -f "$hermes_home/state.db" ]]; then
            log_warn "state.db already exists - kept the current one."
        else
            cp "$wpkg/state.db" "$hermes_home/state.db"; log_ok "state.db restored"
        fi
    fi
    if component_enabled secrets && [[ -d "$wpkg/auth" ]]; then
        local enc_method pass=""
        enc_method="$(json_get "$pkg_dir/manifest.json" secrets_encryption)"
        if [[ -n "$enc_method" && "$enc_method" != "none" ]]; then
            if ! have "$enc_method"; then
                log_warn "Secrets are encrypted with '$enc_method' but it is not installed - skipping auth.json / .env."
            else
                pass="$(prompt_passphrase || true)"
                if [[ -z "$pass" ]]; then
                    log_warn "No passphrase available - skipping encrypted secrets. Set \$CL_HERMES_SECRETS_PASSPHRASE or run interactively."
                fi
            fi
        fi
        _restore_secret() {
            local base="$1" dst="$2"
            if [[ -n "$enc_method" && "$enc_method" != "none" ]]; then
                [[ -f "$wpkg/auth/$base.enc" && -n "$pass" ]] || return 0
                if decrypt_file "$enc_method" "$wpkg/auth/$base.enc" "$hermes_home/$dst" "$pass" 2>/dev/null; then
                    chmod 600 "$hermes_home/$dst"; log_ok "$dst restored (decrypted)"
                else
                    log_error "Could not decrypt $base.enc (wrong passphrase?) - skipped."
                fi
            else
                [[ -f "$wpkg/auth/$base" ]] || return 0
                cp "$wpkg/auth/$base" "$hermes_home/$dst"; chmod 600 "$hermes_home/$dst"
                log_ok "$dst restored"
            fi
        }
        _restore_secret "auth.json" "auth.json"
        _restore_secret ".env" ".env"
    fi

    # --- post-import path checks ---------------------------------------
    if [[ "$CFG_POST_IMPORT_CHECKS" == "true" ]]; then
        post_import_checks "$hermes_home" "$target_os"
    fi

    if ! $QUIET; then
        echo
        echo -e "${GREEN}${BOLD}  Restore complete${NC}"
        printf  "  Hermes home : %s\n" "$hermes_home"
        printf  "  Target OS   : %s\n" "$target_os"
        echo    "  Next: 'hermes status' to verify, and restart the gateway if you use it."
        echo
    fi
}

# --- LIST -----------------------------------------------------------

do_list() {
    local src="${1:-}"
    [[ -n "$src" ]] || die "Usage: $SCRIPT_NAME list <package>"
    local pkg_dir
    pkg_dir="$(stage_package "$src")"

    local m="$pkg_dir/manifest.json"
    local src_os tgt_os
    src_os="$(json_get "$m" source_os)"
    tgt_os="$(detect_os)"

    echo
    echo "cl-hermes-sync package"
    echo "======================================"
    printf "  Format      : v%s\n"  "$(json_get "$m" format_version)"
    printf "  Tool        : %s\n"   "$(json_get "$m" tool_version)"
    printf "  Exported    : %s\n"   "$(json_get "$m" exported_at)"
    printf "  From device : %s\n"   "$(json_get "$m" source_device)"
    printf "  Source OS   : %s\n"   "$src_os"
    printf "  This OS     : %s\n"   "$tgt_os"
    [[ -n "$src_os" && "$src_os" != "$tgt_os" ]] && \
        printf "  Note        : cross-OS import - placeholders will be re-expanded\n"
    printf "  Hermes ver  : %s\n"   "$(json_get "$m" hermes_version)"
    echo
    echo "  Contents:"
    local c
    for c in "${ALL_COMPONENTS[@]}"; do
        case "$(json_get "$m" "$c")" in
            true)  printf "    [x] %s\n" "$c" ;;
            false) printf "    [ ] %s\n" "$c" ;;
            *)     printf "    [?] %s\n" "$c" ;;
        esac
    done
    echo
    printf "  Templatized : %s\n" "$(json_get_array "$m" templatized_targets)"
    printf "  Placeholders: %s\n" "$(json_get_array "$m" placeholders_used)"
    printf "  Win paths   : %s\n" "$(json_get "$m" windows_path_style)"
    local _enc; _enc="$(json_get "$m" secrets_encryption)"
    [[ -n "$_enc" && "$_enc" != none ]] && printf "  Secrets     : encrypted (%s)\n" "$_enc"
    [[ -f "$pkg_dir/CHECKSUMS.sha256.asc" ]] && printf "  Signature   : present (gpg detached)\n"
    if [[ -f "$pkg_dir/paths.map" ]]; then
        load_paths_map "$pkg_dir/paths.map" 2>/dev/null || true
        local n
        for n in "${PLACEHOLDER_NAMES[@]}"; do
            printf "    %-22s L:%s  M:%s  W:%s\n" "$n" \
                "${PH_LINUX[$n]:-}" "${PH_MACOS[$n]:-}" "${PH_WINDOWS[$n]:-}"
        done
    fi
    echo
    printf "  Skills   : %s files\n"   "$(json_get "$m" skills_files)"
    printf "  Memories : %s files\n"   "$(json_get "$m" memories_files)"
    if [[ -f "$pkg_dir/CHECKSUMS.sha256" ]]; then
        printf "  Integrity: %s files hashed (run 'import' to verify)\n" \
            "$(wc -l < "$pkg_dir/CHECKSUMS.sha256" | tr -d ' ')"
    fi
    echo
}

# --- Main -----------------------------------------------------------

main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }
    local cmd="$1"; shift
    case "$cmd" in
        export)          do_export "$@" ;;
        import)          do_import "$@" ;;
        list)            do_list "$@" ;;
        version|--version|-V) show_version ;;
        help|--help|-h)  show_help ;;
        *) die "Unknown command: $cmd (try '$SCRIPT_NAME help')" ;;
    esac
}

main "$@"
