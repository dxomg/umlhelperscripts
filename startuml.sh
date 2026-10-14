#!/bin/bash
#Based from LNQuang
# startuml.sh - boot-only launcher. Works on Pterodactyl AND standard Linux.
# For install + boot in one step, use run.sh.
# Env vars: UML_DATA_DIR, UML_ARCH, UML_ENV=auto|pterodactyl|standard,
#           UML_CONSOLE=fd|xterm|none, UML_MODE=seccomp|skas0|auto,
#           MEMORY, NCPUS, TMP_DIR
set -euo pipefail
dir_usable() { # mkdir + create/delete probe; needs no getcwd
  [ -n "${1:-}" ] || return 1
  mkdir -p "$1" 2>/dev/null || return 1
  local t="$1/.uml_write_test_$$"
  : > "$t" 2>/dev/null || return 1
  rm -f "$t" 2>/dev/null || true
  return 0
}
resolve_base() {
  local src="${BASH_SOURCE[0]:-$0}"
  case "$src" in
    bash|sh|dash|*busybox*|"") src="" ;;
  esac
  local dd="" name="" cand=""
  if [ -n "$src" ]; then
    dd="$(dirname "$src")"; name="$(basename "$src")"
    if [ -n "${PWD:-}" ]; then case "$PWD" in /*)
      case "$dd" in
        .) cand="$PWD" ;;
        /*) cand="$dd" ;;
        *) cand="$PWD/$dd" ;;
      esac
      [ -f "$cand/$name" ] && { echo "$cand"; return 0; }
    ;; esac; fi
    if [ -f "$src" ]; then
      cand="$(cd "$dd" 2>/dev/null && pwd -P 2>/dev/null)" || cand=""
      case "$cand" in /*) [ -f "$cand/$name" ] && { echo "$cand"; return 0; } ;; esac
    fi
  fi
  if [ -n "${PWD:-}" ]; then case "$PWD" in /*)
    dir_usable "$PWD" && { echo "$PWD"; return 0; }
  ;; esac; fi
  echo "."
}
BASE="$(resolve_base)"
cd "$BASE" 2>/dev/null || true
if ! dir_usable "$BASE"; then
  echo "[ERROR] Working dir '$BASE' is not writable." >&2
  echo "        cd to a real, writable directory first." >&2
  exit 1
fi
if ! pwd >/dev/null 2>&1; then
  echo "[!] Note: getcwd() fails in this shell (deleted cwd or Android/bionic);" >&2
  echo "    continuing in $BASE - all paths work without it." >&2
fi
DATA_DIR="${UML_DATA_DIR:-$BASE}"
KERNEL="$DATA_DIR/linux"
ROOTFS="$DATA_DIR/base.img"
CONFIG="$DATA_DIR/config.yaml"
[ -f "$CONFIG" ] || [ "$DATA_DIR" = "$BASE" ] || [ ! -f "$BASE/config.yaml" ] || CONFIG="$BASE/config.yaml"

# --- Arch (display + asset sanity; kernel itself is arch-specific) ---
UNAME_M="${UML_ARCH:-$(uname -m 2>/dev/null || echo x86_64)}"
case "$UNAME_M" in
  amd64) UNAME_M="x86_64" ;;
  aarch64) UNAME_M="arm64" ;;
esac
case "$UNAME_M" in
  x86_64|amd64) ARCH_LABEL="x86_64" ;;
  arm64|aarch64) ARCH_LABEL="arm64" ;;
  *) echo "[WARN] Unknown arch $UNAME_M, continuing anyway" >&2; ARCH_LABEL="$UNAME_M" ;;
esac
# Optional explicit override: ./startuml.sh --arch arm64 2G 1
if [ "${1:-}" = "--arch" ] || [ "${1:-}" = "-a" ]; then
  case "${2:-}" in
    x86_64|amd64) ARCH_LABEL="x86_64" ;;
    arm64|aarch64) ARCH_LABEL="arm64" ;;
    *) echo "[ERROR] Invalid --arch: ${2:-} (use x86_64|arm64)" >&2; exit 1 ;;
  esac
  shift 2
fi
if [ "${1:-}" = "--env" ]; then UML_ENV="${2:-auto}"; shift 2; fi
if [ "${1:-}" = "--console" ]; then UML_CONSOLE="${2:-fd}"; shift 2; fi
if [ "${1:-}" = "--init" ]; then UML_INIT_ARG="${2:-}"; shift 2; fi
if [ "${1:-}" = "--data-dir" ]; then
  DATA_DIR="$2"; KERNEL="$DATA_DIR/linux"; ROOTFS="$DATA_DIR/base.img"; CONFIG="$DATA_DIR/config.yaml"
  shift 2
fi

detect_env() {
  case "${UML_ENV:-auto}" in
    pterodactyl|standard) echo "${UML_ENV}"; return 0 ;;
  esac
  if [ -n "${PTERODACTYL:-}" ] || [ -n "${SERVER_MEMORY:-}" ]; then echo "pterodactyl"; return 0; fi
  case "$BASE$DATA_DIR" in
    */home/container*) echo "pterodactyl"; return 0 ;;
  esac
  echo "standard"
}
ENV_KIND="$(detect_env)"
UML_CONSOLE="${UML_CONSOLE:-fd}"
is_android() {
  [ -n "${PREFIX:-}" ] && case "$PREFIX" in *com.termux*) return 0 ;; esac
  [ -d "/system/app" ] && [ ! -d "/usr/bin" ] && return 0
  [ -f "/system/build.prop" ] && ! command -v dpkg >/dev/null 2>&1 && return 0
  [ "$(uname -o 2>/dev/null)" = "Android" ] && return 0
  return 1
}
yaml_val() {
    # Always succeeds (empty when absent): callers run under `set -e`.
    grep -E "^${1}:" "$CONFIG" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' || true
}

# Userspace mode resolution order: UML_MODE env > config.yaml > default
# (skas0 on Android, seccomp elsewhere). run.sh --reinstall saves the
# install-time pick into config.yaml so plain ./startuml.sh reuses it.

# --- arguments: [memory] [ncpus]  (both optional, config.yaml overrides; env wins) ---
MEMORY="${1:-${MEMORY:-$(yaml_val memory)}}"
MEMORY="${MEMORY:-2G}"
NCPUS="${2:-${NCPUS:-$(yaml_val ncpus)}}"
NCPUS="${NCPUS:-1}"
# coerce to a positive integer (ignore garbage from config/argv)
case "$NCPUS" in
    ''|*[!0-9]*) NCPUS=1 ;;
esac
[ "$NCPUS" -lt 1 ] && NCPUS=1

if [ -z "${UML_MODE:-}" ]; then
  UML_MODE="$(yaml_val mode)"
  if [ -z "$UML_MODE" ]; then
    if is_android; then UML_MODE="skas0"; else UML_MODE="seccomp"; fi
  fi
fi
# Guest init: --init flag > UML_INIT env > config `init:` > systemd.
INIT_BIN="${UML_INIT_ARG:-${UML_INIT:-$(yaml_val init)}}"
INIT_BIN="${INIT_BIN:-/lib/systemd/systemd}"

for f in "$KERNEL" "$ROOTFS" "$DATA_DIR/vde_plug"; do
    if [ ! -f "$f" ]; then echo "[ERROR] Missing: $f (run ./run.sh --reinstall or ./install.sh first)"; exit 1; fi
done
# Android needs the extra bionic helpers beside the kernel (non-fatal here:
# run.sh fetches them automatically at boot; install.sh at install).
if is_android; then
    for _h in "$DATA_DIR/slirp" "$DATA_DIR/stub_exe_bionic"; do
        if [ ! -f "$_h" ]; then
            echo "[!] Android helper missing: $_h" >&2
            echo "    Refresh with: ./run.sh (auto-fetches bionic helpers) or ./install.sh" >&2
        fi
    done
    if [ ! -f "$DATA_DIR/stub_exe" ] && [ -f "$DATA_DIR/stub_exe_bionic" ]; then
        ln -sf stub_exe_bionic "$DATA_DIR/stub_exe" 2>/dev/null \
            || cp -f "$DATA_DIR/stub_exe_bionic" "$DATA_DIR/stub_exe" 2>/dev/null || true
    fi
fi
if [ ! -x "$DATA_DIR/vde_plug" ]; then chmod +x "$DATA_DIR/vde_plug"; fi
chmod +x "$KERNEL" 2>/dev/null || true
if [ ! -x "$KERNEL" ]; then
    echo "[ERROR] Cannot make executable: $KERNEL (noexec mount? move files to an exec-allowed dir" >&2
    echo "        or set UML_DATA_DIR to one)." >&2
    exit 1
fi
if ! head -c 4 "$KERNEL" 2>/dev/null | grep -q ELF; then
    echo "[ERROR] $KERNEL is not an ELF binary - re-download (./run.sh --reinstall)." >&2
    exit 1
fi
# Dry-run: predicts missing-loader/noexec failures (notably Android/bionic)
# with a clear message instead of cryptic `No such file or directory`.
# NOTE: `rc=$?` must come from `||` ($? after `if ! cmd` is always 0).
rc=0
if [ -z "${UML_IGNORE_PREFLIGHT:-}" ]; then
  "$KERNEL" --help >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
      echo "[ERROR] Cannot execute $KERNEL (exit $rc: missing loader or noexec mount)." >&2
      if [ -d "/system/app" ] || [ "$(uname -o 2>/dev/null)" = "Android" ]; then
          echo "        Android detected (bionic): run inside a glibc proot distro" >&2
          echo "        (e.g. proot-distro login debian) instead of directly." >&2
      fi
      exit 1
  fi
fi

# --- detect whether the kernel was built with SMP ---
KERNEL_HAS_SMP=0
if command -v strings >/dev/null 2>&1 && strings "$KERNEL" 2>/dev/null | grep -q '^CONFIG_SMP=y'; then
    KERNEL_HAS_SMP=1
fi

# --- /dev/shm usable? (used for skas0 PTRACE fallback decision) ---
SHM_OK=1
SHM_TEST=$(mktemp /dev/shm/.uml_XXXXXX 2>/dev/null) || SHM_TEST=""
if [ -n "$SHM_TEST" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$SHM_TEST"
    chmod +x "$SHM_TEST" 2>/dev/null
    if "$SHM_TEST" 2>/dev/null; then SHM_OK=1; else SHM_OK=0; fi
    rm -f "$SHM_TEST"
else
    SHM_OK=0
fi

# --- build the kernel cmdline (same rules as run.sh) ---
SMP_ARGS=""
SKAS_MODE=""
case "$UML_MODE" in
    seccomp)
        if [ "$KERNEL_HAS_SMP" -eq 1 ]; then SMP_ARGS="ncpus=$NCPUS seccomp=on"
        else SMP_ARGS="seccomp=on"; fi
        ;;
    skas0)
        if [ "$SHM_OK" -eq 0 ]; then SKAS_MODE="mode=skas0"; fi
        if [ "$KERNEL_HAS_SMP" -eq 1 ]; then SMP_ARGS="ncpus=$NCPUS"; fi
        ;;
    auto)
        if [ "$KERNEL_HAS_SMP" -eq 1 ]; then SMP_ARGS="ncpus=$NCPUS seccomp=on"
        elif [ "$SHM_OK" -eq 0 ]; then SKAS_MODE="mode=skas0"; fi
        ;;
    *) echo "[ERROR] Invalid mode: $UML_MODE (use seccomp|skas0|auto; check UML_MODE, $CONFIG)" >&2; exit 1 ;;
esac

# --- tmpdir: pterodactyl pins $DATA_DIR/.uml_tmp; standard prefers exec-tested /tmp ---
setup_tmpdir() {
  if [ -n "${TMP_DIR:-}" ]; then mkdir -p "$TMP_DIR" && echo "$TMP_DIR" && return 0; fi
  if [ "$ENV_KIND" = "pterodactyl" ]; then mkdir -p "$DATA_DIR/.uml_tmp" && echo "$DATA_DIR/.uml_tmp" && return 0; fi
  local cand _user
  _user="${USER:-$(id -un 2>/dev/null || echo host)}"
  for cand in "${XDG_RUNTIME_DIR:-}/uml-tmp" "/tmp/uml-$_user" "$DATA_DIR/.uml_tmp"; do
    [ -n "$cand" ] && [ "$cand" != "/uml-tmp" ] || continue
    if mkdir -p "$cand" 2>/dev/null; then
      local t; t=$(mktemp "$cand/.exec_XXXXXX" 2>/dev/null) || continue
      printf '#!/bin/sh\nexit 0\n' > "$t"; chmod +x "$t" 2>/dev/null
      if "$t" 2>/dev/null; then rm -f "$t"; echo "$cand"; return 0; fi
      rm -f "$t"
    fi
  done
  mkdir -p "$DATA_DIR/.uml_tmp" && echo "$DATA_DIR/.uml_tmp"
}
UML_TMPDIR="$(setup_tmpdir)"
export TMP="$UML_TMPDIR" TMPDIR="$UML_TMPDIR" TEMP="$UML_TMPDIR"
# Best effort: allow exec on /dev/shm when privileged (harmless if denied).
if command -v sudo >/dev/null 2>&1 && [ "$ENV_KIND" = "standard" ]; then
  sudo mount -o remount,exec /dev/shm 2>/dev/null || mount -o remount,exec /dev/shm 2>/dev/null || true
else
  mount -o remount,exec /dev/shm 2>/dev/null || true
fi

export PATH="$DATA_DIR:$BASE:$PATH"

echo "========================================"
echo "  UML Virtual Machine ($ENV_KIND / $ARCH_LABEL)"
echo "----------------------------------------"
if [ "$KERNEL_HAS_SMP" -eq 1 ] && [ "$NCPUS" -gt 1 ]; then
    echo "  CPUs     : $NCPUS (SMP, seccomp userspace)"
elif [ "$KERNEL_HAS_SMP" -eq 1 ]; then
    echo "  CPUs     : 1 (SMP kernel, 1 vCPU)"
else
    echo "  CPUs     : 1 (UP kernel)"
fi
echo "  Memory   : $MEMORY"
echo "  Network  : VDE VECTOR + libslirp NAT"
if [ -n "$SKAS_MODE" ]; then echo "  Userspace: skas0 (slow /dev/shm fallback)"; else echo "  Userspace: seccomp"; fi
echo "  Init     : $INIT_BIN"
echo "  Config   : $CONFIG"
echo "  Data     : $DATA_DIR"
echo "----------------------------------------"
echo "  Login: root / root"
echo "========================================"
echo ""

cleanup() {
  case "$UML_TMPDIR" in
    "$DATA_DIR/.uml_tmp"|"$BASE/.uml_tmp") rm -rf "$UML_TMPDIR" 2>/dev/null || true ;;
    /tmp/uml-*|/run/user/*/uml-tmp) rm -rf "$UML_TMPDIR" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT

CON_ARGS=""
case "$UML_CONSOLE" in
  fd) CON_ARGS="con0=fd:0,fd:1 con=null" ;;
  xterm) CON_ARGS="con0=xterm con=null" ;;
  none) CON_ARGS="con=null con0=null" ;;
  *) echo "[ERROR] Invalid UML_CONSOLE: $UML_CONSOLE (use fd|xterm|none)" >&2; exit 1 ;;
esac

if [ "$ENV_KIND" = "pterodactyl" ]; then
  # Pterodactyl startup detection: egg "startup": {"done": "Server started"}
  echo "Server started"
else
  echo "Starting UML ($ARCH_LABEL)... press Ctrl+C to stop."
fi

# shellcheck disable=SC2086
exec "$KERNEL" \
    mem="$MEMORY" \
    $SKAS_MODE \
    $SMP_ARGS \
    ubd0="$ROOTFS" \
    root=/dev/ubda rw \
    init="$INIT_BIN" \
    "vec0:transport=vde,vnl=slirp://" \
    $CON_ARGS
