#!/usr/bin/env bash
# Platform detection and cross-platform utilities.
#
# Source this at the top of scripts that invoke CLI tools from bash on Windows
# (WSL or Git Bash). After sourcing, call tf / helm / kubectl as normal —
# the wrappers handle binary detection and path conversion transparently.
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

# ── Binary detection ───────────────────────────────────────────────────────────
# On Windows bash environments (WSL, Git Bash), the native Linux binary may be
# absent while the .exe Windows binary is reachable via PATH interop.
# Each variable is set at source time; wrappers below use them at call time.

_find_bin() {
  local name="$1" required="${2:-false}"
  if command -v "$name" &>/dev/null; then
    echo "$name"
  elif command -v "${name}.exe" &>/dev/null; then
    echo "${name}.exe"
  elif [[ "$required" == "true" ]]; then
    echo "ERROR: $name not found in PATH. Install $name and ensure it is accessible from bash." >&2
    exit 1
  else
    echo ""
  fi
}

_TF_BIN=$(_find_bin terraform true)   # required — exit if missing
_HELM_BIN=$(_find_bin helm)            # lazy — error only when helm() is called
_KUBECTL_BIN=$(_find_bin kubectl)      # lazy — error only when kubectl() is called

# ── Path conversion ────────────────────────────────────────────────────────────
# Windows-native binaries require Windows-style paths (C:\...).
# WSL paths look like /mnt/c/...; Git Bash paths look like /c/...
# Passes through stdin placeholder "-" and non-path strings unchanged.

to_native_path() {
  local path="$1"
  # Stdin placeholder and empty strings are never file paths
  [[ "$path" == "-" || -z "$path" ]] && echo "$path" && return
  case "$_PLATFORM" in
    wsl)     wslpath -w "$path" 2>/dev/null || echo "$path" ;;
    gitbash) cygpath -w "$path" 2>/dev/null || echo "$path" ;;
    *)       echo "$path" ;;
  esac
}

# ── terraform wrapper ──────────────────────────────────────────────────────────
# Intercepts -chdir=<path> and converts to native format for terraform.exe.

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

# ── helm wrapper ───────────────────────────────────────────────────────────────
# Handles binary detection. Chart references (e.g. eks/aws-load-balancer-controller)
# are not file paths and are passed through unchanged. Local chart paths and
# -f/--values file args are converted when using helm.exe from WSL/Git Bash.

helm() {
  [[ -z "$_HELM_BIN" ]] && { echo "ERROR: helm not found in PATH. Install helm >= 3.x." >&2; return 1; }
  if [[ "$_HELM_BIN" == "helm.exe" ]]; then
    local args=() next_is_file=false
    for arg in "$@"; do
      if $next_is_file; then
        args+=("$(to_native_path "$arg")")
        next_is_file=false
      elif [[ "$arg" == "-f" || "$arg" == "--values" ]]; then
        args+=("$arg"); next_is_file=true
      elif [[ "$arg" == -f=* ]]; then
        args+=("-f=$(to_native_path "${arg#-f=}")")
      elif [[ "$arg" == --values=* ]]; then
        args+=("--values=$(to_native_path "${arg#--values=}")")
      else
        args+=("$arg")
      fi
    done
    command "$_HELM_BIN" "${args[@]}"
  else
    command "$_HELM_BIN" "$@"
  fi
}

# ── kubectl wrapper ────────────────────────────────────────────────────────────
# Handles binary detection and converts -f/--filename paths for kubectl.exe.
# Stdin placeholder "-f -" is passed through unchanged.

kubectl() {
  [[ -z "$_KUBECTL_BIN" ]] && { echo "ERROR: kubectl not found in PATH. Install kubectl." >&2; return 1; }
  if [[ "$_KUBECTL_BIN" == "kubectl.exe" ]]; then
    local args=() next_is_file=false
    for arg in "$@"; do
      if $next_is_file; then
        [[ "$arg" == "-" ]] && args+=("-") || args+=("$(to_native_path "$arg")")
        next_is_file=false
      elif [[ "$arg" == "-f" || "$arg" == "--filename" ]]; then
        args+=("$arg"); next_is_file=true
      elif [[ "$arg" == -f=* ]]; then
        args+=("-f=$(to_native_path "${arg#-f=}")")
      elif [[ "$arg" == --filename=* ]]; then
        args+=("--filename=$(to_native_path "${arg#--filename=}")")
      else
        args+=("$arg")
      fi
    done
    command "$_KUBECTL_BIN" "${args[@]}"
  else
    command "$_KUBECTL_BIN" "$@"
  fi
}

# ── aws wrapper ────────────────────────────────────────────────────────────────
# On Git Bash (Windows), MSYS automatically converts arguments that start with /
# to Windows paths before passing them to native executables. This breaks AWS CLI
# calls with slash-prefixed resource names (SSM parameter paths, ARN prefixes,
# S3 object keys, etc.) — e.g., /petclinic/dev/alb-dns-name becomes
# C:\petclinic\dev\alb-dns-name and the call fails with ValidationException.
#
# MSYS_NO_PATHCONV=1 disables this conversion for the duration of the command.
# It is a no-op on Linux and macOS so this wrapper is safe on all platforms.

aws() {
  if [[ "$_PLATFORM" == "gitbash" ]]; then
    MSYS_NO_PATHCONV=1 command aws "$@"
  else
    command aws "$@"
  fi
}
