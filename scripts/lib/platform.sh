#!/usr/bin/env bash
# Platform detection and cross-platform utilities.
#
# Source this at the top of scripts that invoke Windows-native binaries
# (terraform.exe) from bash running inside WSL or Git Bash.
#
# After sourcing, use:
#   tf -chdir=/some/path output -raw foo     (auto-converts path for terraform.exe)
#   to_native_path /some/unix/path           (returns C:\... on Windows, unchanged on Linux/macOS)
#
# Detection logic:
#   WSL      — WSL_DISTRO_NAME env var is set, or /proc/version contains "microsoft"
#   Git Bash — MSYSTEM env var is set (MINGW64, MINGW32, MSYS, etc.)
#   Unix     — everything else (Linux, macOS, CI runners)

# ── Environment detection ──────────────────────────────────────────────────────

if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
  _PLATFORM="wsl"
elif [[ -n "${MSYSTEM:-}" ]]; then
  _PLATFORM="gitbash"
else
  _PLATFORM="unix"
fi

# ── Terraform binary ───────────────────────────────────────────────────────────
# WSL and Git Bash can see terraform.exe via PATH interop even when the native
# Linux terraform binary is not installed.

if command -v terraform &>/dev/null; then
  _TF_BIN="terraform"
elif command -v terraform.exe &>/dev/null; then
  _TF_BIN="terraform.exe"
else
  echo "ERROR: terraform not found in PATH. Install terraform and ensure it is accessible from bash." >&2
  exit 1
fi

# ── Path conversion ────────────────────────────────────────────────────────────
# Windows-native binaries (terraform.exe) require Windows-style paths (C:\...).
# WSL paths look like /mnt/c/...; Git Bash paths look like /c/...
# Both wslpath and cygpath convert to the correct Windows format.

to_native_path() {
  case "$_PLATFORM" in
    wsl)     wslpath -w "$1" 2>/dev/null || echo "$1" ;;
    gitbash) cygpath -w "$1" 2>/dev/null || echo "$1" ;;
    *)       echo "$1" ;;
  esac
}

# ── Terraform wrapper ──────────────────────────────────────────────────────────
# Drop-in replacement for 'terraform'. Converts -chdir=<path> to a native path
# when terraform.exe is in use. All other arguments are passed through unchanged.

tf() {
  local args=()
  for arg in "$@"; do
    if [[ "$arg" == -chdir=* ]]; then
      local dir="${arg#-chdir=}"
      args+=("-chdir=$(to_native_path "$dir")")
    else
      args+=("$arg")
    fi
  done
  "$_TF_BIN" "${args[@]}"
}
