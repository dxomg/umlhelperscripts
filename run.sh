#!/bin/bash
# run.sh - merged installer + launcher (Pterodactyl + standard Linux).
#   First run: picks/downloads kernel, tools, rootfs image (-> base.img).
#   Every run: boots UML.
# Works in Pterodactyl containers AND on a regular Linux host/VM.
# Architecture-aware: x86_64 and arm64 (aarch64), override via --arch / UML_ARCH.
# Based from LNQuang
set -euo pipefail

# Resolve the repo dir without depending on getcwd(): on some systems
# (deleted cwd, Android/bionic ERANGE) `pwd` fails AND bash's `cd` reports
# failure even when the directory is perfectly usable. So: build candidate
# paths as strings and validate with file probes only.
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
    # 1) $PWD-anchored: pure string math + file probe, no cd/pwd/getcwd.
    if [ -n "${PWD:-}" ]; then case "$PWD" in /*)
      case "$dd" in
        .) cand="$PWD" ;;
        /*) cand="$dd" ;;
        *) cand="$PWD/$dd" ;;
      esac
      [ -f "$cand/$name" ] && { echo "$cand"; return 0; }
    ;; esac; fi
    # 2) Classic cd+pwd (healthy systems; also repairs a stale $PWD).
    if [ -f "$src" ]; then
      cand="$(cd "$dd" 2>/dev/null && pwd -P 2>/dev/null)" || cand=""
      case "$cand" in /*) [ -f "$cand/$name" ] && { echo "$cand"; return 0; } ;; esac
    fi
  fi
  # 3) Piped mode / anything else: current dir, validated by usability probe.
  if [ -n "${PWD:-}" ]; then case "$PWD" in /*)
    dir_usable "$PWD" && { echo "$PWD"; return 0; }
  ;; esac; fi
  # 4) Last resort: relative operation. All file ops below resolve against
  #    the live cwd fd, which works even with a broken getcwd().
  echo "."
}
BASE="$(resolve_base)"
# Best-effort anchor: `cd` may *report* failure when getcwd is broken even
# though the chdir worked, so ignore its status and verify by file probe.
cd "$BASE" 2>/dev/null || true
if ! dir_usable "$BASE"; then
  echo "[ERROR] Working dir '$BASE' is not writable." >&2
  echo "        cd to a real, writable directory first, e.g.:" >&2
  echo "          mkdir -p /data/adb/uml && cd /data/adb/uml" >&2
  exit 1
fi
if ! pwd >/dev/null 2>&1; then
  echo "[!] Note: getcwd() fails in this shell (deleted cwd or Android/bionic);" >&2
  echo "    continuing in $BASE - all paths work without it." >&2
fi
# Allow regular-env users to keep data outside the repo checkout:
#   UML_DATA_DIR=~/.local/share/uml ./run.sh
DATA_DIR="${UML_DATA_DIR:-$BASE}"
mkdir -p "$DATA_DIR" 2>/dev/null || {
  echo "[ERROR] Data dir not writable: $DATA_DIR (set UML_DATA_DIR to a writable path)" >&2
  exit 1
}
KERNEL="$DATA_DIR/linux"
ROOTFS="$DATA_DIR/base.img"
CONFIG="$DATA_DIR/config.yaml"
# Legacy in-repo config still honoured if DATA_DIR config is missing.
[ -f "$CONFIG" ] || [ "$DATA_DIR" = "$BASE" ] || [ ! -f "$BASE/config.yaml" ] || CONFIG="$BASE/config.yaml"

REPO="dxomg/uml-kernel-build"
BASE_URL="https://github.com/${REPO}/releases/latest/download"
HELPER_URL="https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main"

# --- Architecture detection (override: --arch / UML_ARCH) ---
# Normalises: x86_64/amd64 -> x86_64, aarch64/arm64 -> arm64.
# On Android arm64 the glibc assets cannot exec (no /lib/ld-linux); use the
# statically-linked bionic set instead (verified AArch64/NDK-static):
# linux-bionic + vde_plug_bionic (C vde_plug with built-in libvdeslirp, so it
# understands vnl=slirp://) + slirp_bionic (standalone helper) +
# stub_exe_bionic (UML stub process image, kept beside the kernel).
is_android() {
  [ -n "${PREFIX:-}" ] && case "$PREFIX" in *com.termux*) return 0 ;; esac
  [ -d "/system/app" ] && [ ! -d "/usr/bin" ] && return 0
  [ -f "/system/build.prop" ] && ! command -v dpkg >/dev/null 2>&1 && return 0
  [ "$(uname -o 2>/dev/null)" = "Android" ] && return 0
  return 1
}
apply_arch() {
  SLIRP_ASSET=""; STUB_ASSET=""
  case "$1" in
    x86_64|amd64)
      ARCH_LABEL="x86_64"; IMG_SUFFIX=""; KERNEL_ASSET="linux-uml"; VDE_ASSET="vde_plug-x86_64"
      LIB_TRIPLET="x86_64-linux-gnu"
      ;;
    arm64|aarch64)
      ARCH_LABEL="arm64"; IMG_SUFFIX="-arm64"; KERNEL_ASSET="linux-uml-arm64"; VDE_ASSET="vde_plug-arm64"
      LIB_TRIPLET="aarch64-linux-gnu"
      if is_android; then
        KERNEL_ASSET="linux-bionic"; VDE_ASSET="vde_plug_bionic"
        SLIRP_ASSET="slirp_bionic"; STUB_ASSET="stub_exe_bionic"
      fi
      ;;
    *)
      echo "Unsupported architecture: $1 (expected x86_64 or aarch64; override with --arch x86_64|arm64)" >&2
      return 1
      ;;
  esac
  UNAME_M="$1"
}
UNAME_M="${UML_ARCH:-$(uname -m 2>/dev/null || echo x86_64)}"
# Accept Debian-style arch names too.
case "$UNAME_M" in
  amd64) UNAME_M="x86_64" ;;
  aarch64) UNAME_M="arm64" ;;
esac
apply_arch "$UNAME_M" || exit 1

# --- Environment detection (override: --env / UML_ENV=auto|pterodactyl|standard) ---
# pterodactyl: /home/container checkout, no sudo, needs .uml_tmp + "Server started" marker.
# standard:    regular host/VM/VPS, sudo + system package manager available.
detect_env() {
  case "${UML_ENV:-auto}" in
    pterodactyl|standard) echo "${UML_ENV}"; return 0 ;;
  esac
  if [ -n "${PTERODACTYL:-}" ] || [ -n "${SERVER_MEMORY:-}" ]; then echo "pterodactyl"; return 0; fi
  case "$BASE$DATA_DIR" in
    */home/container*) echo "pterodactyl"; return 0 ;;
  esac
  if [ -f "/.dockerenv" ] && [ ! -w "/usr" ] && [ -d "/home/container" ]; then echo "pterodactyl"; return 0; fi
  echo "standard"
}
ENV_KIND="$(detect_env)"

# Downloader: wget preferred (progress), curl fallback (standard hosts often have one).
download() { # download URL DEST
  if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "$2" "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fSL --progress-bar -o "$2" "$1"
  else
    echo "[ERROR] Need wget or curl to download $1" >&2
    return 1
  fi
}

# Standard hosts: fail fast with install hints instead of cryptic errors.
ensure_host_deps() {
  local missing=""
  for t in gunzip truncate stat; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || missing="$missing wget|curl"
  if [ -n "$missing" ] && [ "$ENV_KIND" = "standard" ]; then
    echo "[ERROR] Missing host tools:$missing" >&2
    if command -v apt-get >/dev/null 2>&1; then
      echo "  Fix: sudo apt-get update && sudo apt-get install -y wget gzip coreutils e2fsprogs binutils" >&2
    elif command -v dnf >/dev/null 2>&1; then
      echo "  Fix: sudo dnf install -y wget gzip coreutils e2fsprogs binutils" >&2
    elif command -v pacman >/dev/null 2>&1; then
      echo "  Fix: sudo pacman -S --needed wget gzip coreutils e2fsprogs binutils" >&2
    elif command -v apk >/dev/null 2>&1; then
      echo "  Fix: sudo apk add wget gzip coreutils e2fsprogs binutils" >&2
    fi
    return 1
  fi
}

DISTROS=(
  "debian-trixie"
  "debian-bookworm"
  "ubuntu-noble"
  "ubuntu-resolute"
  "rockylinux-9"
  "rockylinux-10"
  "almalinux-9"
  "almalinux-10"
)
DEFAULT_DISTRO="debian-trixie"

image_for() { echo "base-${1}${IMG_SUFFIX}.img.gz"; }

list_images() {
  echo "Available images for ${ARCH_LABEL} (from ${REPO}@latest):"
  local i=1
  for d in "${DISTROS[@]}"; do
    printf "  %d) %s\n" "$i" "$(image_for "$d")"
    i=$((i+1))
  done
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [MEMORY] [NCPUS]

Merged installer + launcher. Installs on first run, boots every run.
Works on Pterodactyl AND standard Linux. Env auto-detected (override: --env).

Options:
  -i, --image IMG   Image to install: number, short name (debian-trixie),
                    or full asset (base-debian-trixie.img.gz).
                    Env: UML_IMAGE (same values). Interactive prompt if TTY
                    and unset, otherwise default: ${DEFAULT_DISTRO}
  -d, --disk SIZE   Resize base.img to SIZE (e.g. 20G) after install.
                    Env: UML_DISK_SIZE. Interactive prompt if TTY
                    and unset, otherwise disk is left as-downloaded.
  -l, --list        List available images and exit
  -a, --arch ARCH   Override arch: x86_64 | arm64 (default: auto -> ${ARCH_LABEL}).
                    Env: UML_ARCH.
  --env ENV         Override env: auto (default), pterodactyl, standard.
                    Env: UML_ENV.
  --data-dir DIR    Where to store linux/vde_plug/base.img/config.yaml
                    (default: script dir; e.g. ~/.local/share/uml).
                    Env: UML_DATA_DIR.
  --console MODE    Guest console: fd (default, stdio, Pterodactyl-safe),
                    xterm, none. Env: UML_CONSOLE.
  --init PATH       Guest init binary.
                    --init flag > UML_INIT env > config `init:` > auto-detect
                    from the image > /lib/systemd/systemd.
                    Rescue/debug: --init /bin/sh (skips systemd entirely).
  --mode MODE       Userspace mode: seccomp (default, skas0 on Android),
                    skas0, auto.
                    Env: UML_MODE. seccomp avoids /dev/shm via memfd
                    backport; skas0 forces PTRACE fallback (needed on
                    Android kernels without close_range).
                    On install (interactive TTY, mode not given) you are
                    asked to pick; the pick is saved to config.yaml and
                    reused by later boots (incl. startuml.sh).
  --reinstall       Force re-download even if files exist
  --install-only    Install but do not boot
  -h, --help        Show this help

Positional (boot, same as startuml.sh):
  MEMORY  e.g. 2G (default: config.yaml memory or 2G; env MEMORY wins)
  NCPUS   e.g. 1 (default: config.yaml ncpus or 1; env NCPUS wins)

Examples:
  $0 --list
  $0 --image 1
  $0 --image debian-trixie --arch arm64
  UML_IMAGE=ubuntu-noble $0 4G 2
  UML_DATA_DIR=~/.local/share/uml $0 2G 1
  $0 --env standard --console xterm 4G 2
EOF
}

resolve_image() {
  local want="$1"
  if [[ "$want" =~ ^[0-9]+$ ]]; then
    local idx=$((want-1))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DISTROS[@]}" ]; then
      image_for "${DISTROS[$idx]}"
      return 0
    fi
    echo "Invalid selection: $want (1-${#DISTROS[@]})" >&2
    return 1
  fi
  if [[ "$want" == base-*.img.gz ]]; then
    echo "$want"
    return 0
  fi
  local d="$want"
  d="${d#base-}"
  d="${d%.img.gz}"
  d="${d%-arm64}"
  for known in "${DISTROS[@]}"; do
    if [ "$d" = "$known" ]; then
      image_for "$known"
      return 0
    fi
  done
  echo "Unknown image: $want" >&2
  list_images >&2
  return 1
}

# --- parse args (flags + legacy [memory] [ncpus] positionals) ---
WANT_IMAGE="${UML_IMAGE:-}"
WANT_DISK="${UML_DISK_SIZE:-}"
# Userspace mode is intentionally left empty unless explicitly given: the
# install step asks interactively (TTY) and saves the pick to config.yaml;
# boot resolves: explicit --mode/UML_MODE > config.yaml > platform default
# (seccomp, or skas0 on Android where seccomp often can't initialise:
# missing close_range -> "SECCOMP userspace requested but not functional!").
MODE_EXPLICIT=0
if [ -n "${UML_MODE:-}" ]; then MODE_EXPLICIT=1; fi
UML_CONSOLE="${UML_CONSOLE:-fd}"
REINSTALL=0
INSTALL_ONLY=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--image) WANT_IMAGE="${2:-}"; shift 2 ;;
    --image=*) WANT_IMAGE="${1#--image=}"; shift ;;
    -d|--disk) WANT_DISK="${2:-}"; shift 2 ;;
    --disk=*) WANT_DISK="${1#--disk=}"; shift ;;
    -a|--arch)
      apply_arch "${2:-}" || exit 1
      # Re-resolve image-dependent vars that embed the suffix.
      shift 2 ;;
    --arch=*) apply_arch "${1#--arch=}" || exit 1; shift ;;
    --env) UML_ENV="${2:-auto}"; ENV_KIND="$(detect_env)"; shift 2 ;;
    --env=*) UML_ENV="${1#--env=}"; ENV_KIND="$(detect_env)"; shift ;;
    --data-dir) DATA_DIR="$2"; KERNEL="$DATA_DIR/linux"; ROOTFS="$DATA_DIR/base.img"; CONFIG="$DATA_DIR/config.yaml"; mkdir -p "$DATA_DIR"; shift 2 ;;
    --data-dir=*) DATA_DIR="${1#--data-dir=}"; KERNEL="$DATA_DIR/linux"; ROOTFS="$DATA_DIR/base.img"; CONFIG="$DATA_DIR/config.yaml"; mkdir -p "$DATA_DIR"; shift ;;
    --console) UML_CONSOLE="${2:-fd}"; shift 2 ;;
    --console=*) UML_CONSOLE="${1#--console=}"; shift ;;
    --init) UML_INIT_ARG="${2:-}"; shift 2 ;;
    --init=*) UML_INIT_ARG="${1#--init=}"; shift ;;
    --mode) UML_MODE="${2:-}"; MODE_EXPLICIT=1; shift 2 ;;
    --mode=*) UML_MODE="${1#--mode=}"; MODE_EXPLICIT=1; shift ;;
    -l|--list) list_images; exit 0 ;;
    --reinstall) REINSTALL=1; shift ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) POS+=("$1"); shift ;;
  esac
done
MEMORY_ARG="${POS[0]:-}"
NCPUS_ARG="${POS[1]:-}"

# Fail fast on an invalid explicit mode (typo in --mode/UML_MODE).
if [ "$MODE_EXPLICIT" -eq 1 ] && [ -n "${UML_MODE:-}" ]; then
  case "$UML_MODE" in
    seccomp|skas0|auto) ;;
    *) echo "[ERROR] Invalid --mode/UML_MODE: $UML_MODE (use seccomp|skas0|auto)" >&2; exit 1 ;;
  esac
fi

# Fail fast on an invalid explicit init (typo in --init/UML_INIT).
if [ -n "${UML_INIT_ARG:-${UML_INIT:-}}" ]; then
  case "${UML_INIT_ARG:-$UML_INIT}" in
    /*) ;;
    *) echo "[ERROR] Invalid --init/UML_INIT: ${UML_INIT_ARG:-$UML_INIT} (use an absolute guest path)" >&2; exit 1 ;;
  esac
fi

need_install() {
  [ "$REINSTALL" -eq 1 ] && return 0
  [ ! -f "$KERNEL" ] && return 0
  [ ! -f "$DATA_DIR/vde_plug" ] && return 0
  [ ! -f "$ROOTFS" ] && return 0
  [ ! -f "$CONFIG" ] && return 0
  # Rootfs/arch drift (e.g. --arch switch after install): full reinstall so
  # the guest userspace matches the kernel. Helper-only drift is handled by
  # refresh_android_helpers() at boot without re-downloading base.img.
  local _exp _have
  _exp="$(resolve_image "${WANT_IMAGE:-$DEFAULT_DISTRO}")" || return 0
  _have="$(manifest_val image)"
  if [ -n "$_have" ] && [ "$_have" != "$_exp" ]; then return 0; fi
  return 1
}

# Ensure e2fsck/resize2fs are usable on host. Architecture-aware.
# standard env: try system package manager (with sudo if needed), then
# user-space fallback. pterodactyl: user-space fallback only (no sudo).
ensure_e2fsprogs() {
  if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
    return 0
  fi
  local prefix="$DATA_DIR/.tools/e2fsprogs"
  # Legacy prefix from older installs.
  [ -d "$BASE/.tools/e2fsprogs" ] && [ "$prefix" != "$BASE/.tools/e2fsprogs" ] && prefix="$BASE/.tools/e2fsprogs"
  : "${LIB_TRIPLET:=x86_64-linux-gnu}"
  if [ -x "$prefix/usr/sbin/resize2fs" ] || [ -x "$prefix/sbin/resize2fs" ]; then
    export PATH="$prefix/usr/sbin:$prefix/sbin:$PATH"
    export LD_LIBRARY_PATH="$prefix/usr/lib/$LIB_TRIPLET:$prefix/usr/lib:$prefix/lib/$LIB_TRIPLET:$prefix/usr/lib/aarch64-linux-gnu:$prefix/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    return 0
  fi
  # Standard host with root: prefer the distro package manager.
  if [ "$ENV_KIND" = "standard" ] && ([ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1); then
    local do_root=""; [ "$(id -u)" -ne 0 ] && do_root="sudo"
    echo "==> e2fsprogs missing, installing via system package manager..."
    if command -v apt-get >/dev/null 2>&1; then
      $do_root apt-get update && $do_root apt-get install -y e2fsprogs && return 0 || true
    elif command -v dnf >/dev/null 2>&1; then
      $do_root dnf install -y e2fsprogs && return 0 || true
    elif command -v pacman >/dev/null 2>&1; then
      $do_root pacman -S --noconfirm --needed e2fsprogs && return 0 || true
    elif command -v apk >/dev/null 2>&1; then
      $do_root apk add e2fsprogs && return 0 || true
    elif command -v zypper >/dev/null 2>&1; then
      $do_root zypper install -y e2fsprogs && return 0 || true
    fi
  fi
  command -v apt-get >/dev/null 2>&1 || return 1
  command -v dpkg-deb >/dev/null 2>&1 || return 1
  echo "==> e2fsprogs not on host, installing into $prefix ..."
  mkdir -p "$prefix/apt/lists/partial" "$prefix/apt/cache/archives/partial" "$prefix/debs"
  local apt="apt-get -o Debug::NoLocking=1 -o Dir::State::Lists=$prefix/apt/lists -o Dir::Cache=$prefix/apt/cache"
  $apt update >/dev/null 2>&1 || true
  local libs
  libs=$(apt-cache -o Debug::NoLocking=1 -o Dir::State::Lists=$prefix/apt/lists depends --important e2fsprogs 2>/dev/null | awk '/Depends:|PreDepends:/{print $2}' | grep '^lib' | sort -u | tr '\n' ' ') || true
  # shellcheck disable=SC2086
  (cd "$prefix/debs" && $apt download e2fsprogs $libs >/dev/null 2>&1) || return 1
  local deb
  for deb in "$prefix"/debs/*.deb; do
    [ -f "$deb" ] || return 1
    dpkg-deb -x "$deb" "$prefix" || return 1
  done
  [ -x "$prefix/usr/sbin/resize2fs" ] || [ -x "$prefix/sbin/resize2fs" ] || return 1
  export PATH="$prefix/usr/sbin:$prefix/sbin:$PATH"
  export LD_LIBRARY_PATH="$prefix/usr/lib/$LIB_TRIPLET:$prefix/usr/lib:$prefix/lib/$LIB_TRIPLET:$prefix/usr/lib/aarch64-linux-gnu:$prefix/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  return 0
}

# Pick an exec-capable tmpdir. Pterodactyl must stay in $DATA_DIR/.uml_tmp;
# standard hosts prefer XDG_RUNTIME_DIR / /tmp but verify exec works.
setup_tmpdir() {
  if [ -n "${TMP_DIR:-}" ]; then
    mkdir -p "$TMP_DIR" && echo "$TMP_DIR" && return 0
  fi
  if [ "$ENV_KIND" = "pterodactyl" ]; then
    mkdir -p "$DATA_DIR/.uml_tmp" && echo "$DATA_DIR/.uml_tmp" && return 0
  fi
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

# Pre-boot sanity: ELF magic, exec bit, and (best effort) that the kernel
# actually starts. Turns cryptic `No such file or directory` (missing glibc
# loader / noexec mount) into an actionable message.
preflight_kernel() { # preflight_kernel KERNEL_FILE
  local k="$1"
  if [ ! -s "$k" ]; then
    echo "[ERROR] Kernel missing/empty: $k (run with --reinstall?)" >&2
    return 1
  fi
  if ! head -c 4 "$k" 2>/dev/null | grep -q ELF; then
    echo "[ERROR] $k is not an ELF binary (download corrupted?)." >&2
    echo "        Re-download with --reinstall." >&2
    return 1
  fi
  chmod +x "$k" 2>/dev/null || true
  if [ ! -x "$k" ]; then
    echo "[ERROR] Cannot make executable: $k (noexec mount? copy to an exec-allowed dir" >&2
    echo "        or set UML_DATA_DIR to one, e.g. UML_DATA_DIR=\$HOME/uml)." >&2
    return 1
  fi
  # Dry-run: a UML kernel prints help/usage quickly; failure here predicts
  # the exec failure below (e.g. missing /lib/ld-linux on Android/Alpine).
  # NOTE: `rc=$?` must come from `||` ($? after `if ! cmd` is always 0).
  local rc=0
  "$k" --help >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
      echo "[ERROR] Cannot execute $k (exit $rc: missing loader or noexec mount)." >&2
      if is_android; then
        echo "        This is Android (bionic): the glibc UML kernel cannot run here." >&2
        echo "        You likely have stale glibc helpers - refresh them:" >&2
        echo "          ./run.sh --reinstall   (auto-picks linux-bionic + bionic helpers on Android/arm64)" >&2
        echo "        Or manual swap (all four Android assets):" >&2
        echo "          curl -fSL -o linux https://github.com/${REPO}/releases/latest/download/linux-bionic" >&2
        echo "          curl -fSL -o vde_plug https://github.com/${REPO}/releases/latest/download/vde_plug_bionic" >&2
        echo "          curl -fSL -o slirp https://github.com/${REPO}/releases/latest/download/slirp_bionic" >&2
        echo "          curl -fSL -o stub_exe_bionic https://github.com/${REPO}/releases/latest/download/stub_exe_bionic" >&2
        echo "          ln -sf stub_exe_bionic stub_exe && chmod +x linux vde_plug slirp stub_exe_bionic" >&2
        echo "        Fallback: run inside a glibc proot distro (proot-distro login debian)." >&2
      elif [ ! -f "/lib/ld-linux-aarch64.so.1" ] && [ ! -f "/lib64/ld-linux-x86-64.so.2" ] && [ ! -f "/lib/ld-linux-x86-64.so.2" ]; then
        echo "        No glibc loader found - musl/Alpine or minimal rootfs?" >&2
        echo "        Install glibc compat (e.g. apk add gcompat libc6-compat) or boot on glibc Linux." >&2
      else
      echo "        Check: file $k ; mount | grep -E 'noexec.*(${DATA_DIR}|/tmp)'" >&2
    fi
    return 1
  fi
  # Any other exit code (e.g. UML prints usage with rc!=0) is fine.
  return 0
}

# Download kernel + userspace helpers for the current arch mapping.
# Android additionally fetches slirp_bionic + stub_exe_bionic.
download_helpers() {
  download "${BASE_URL}/${KERNEL_ASSET}" "$DATA_DIR/linux" || return 1
  download "${BASE_URL}/${VDE_ASSET}" "$DATA_DIR/vde_plug" || return 1
  if [ -n "${SLIRP_ASSET:-}" ]; then
    echo "==> Downloading helper ${SLIRP_ASSET}..."
    download "${BASE_URL}/${SLIRP_ASSET}" "$DATA_DIR/slirp" || return 1
  else
    # Upstream glibc releases dropped standalone slirp (v2026.09.26-18+);
    # networking there is provided via vde_plug, so remove stale copies.
    rm -f "$DATA_DIR/slirp" "$BASE/slirp"
  fi
  if [ -n "${STUB_ASSET:-}" ]; then
    echo "==> Downloading stub ${STUB_ASSET}..."
    download "${BASE_URL}/${STUB_ASSET}" "$DATA_DIR/stub_exe_bionic" || return 1
    # The kernel looks for the stub beside itself; provide both the release
    # asset name and the canonical short name.
    ln -sf stub_exe_bionic "$DATA_DIR/stub_exe" 2>/dev/null \
      || cp -f "$DATA_DIR/stub_exe_bionic" "$DATA_DIR/stub_exe" 2>/dev/null || true
  fi
  return 0
}

# Verify downloads: GitHub error pages are tiny HTML, real assets are MBs.
verify_helpers() {
  local _f
  for _f in "$DATA_DIR/linux" "$DATA_DIR/vde_plug"; do
    if [ ! -s "$_f" ]; then
      echo "[ERROR] Download failed/empty: $_f (check network + asset ${KERNEL_ASSET}/${VDE_ASSET})" >&2
      return 1
    fi
  done
  if [ -n "${SLIRP_ASSET:-}" ] && [ ! -s "$DATA_DIR/slirp" ]; then
    echo "[ERROR] Download failed/empty: $DATA_DIR/slirp (asset ${SLIRP_ASSET})" >&2
    return 1
  fi
  if [ -n "${STUB_ASSET:-}" ] && [ ! -s "$DATA_DIR/stub_exe_bionic" ]; then
    echo "[ERROR] Download failed/empty: $DATA_DIR/stub_exe_bionic (asset ${STUB_ASSET})" >&2
    return 1
  fi
  if head -c 15 "$DATA_DIR/linux" 2>/dev/null | grep -q '<'; then
    echo "[ERROR] Kernel download looks like an HTML error page, not a binary." >&2
    echo "        Check https://github.com/${REPO}/releases for ${KERNEL_ASSET}." >&2
    return 1
  fi
  return 0
}

# Track which release assets an install came from, so helper-only drift
# (e.g. Android mapping changes) refreshes helpers without re-downloading
# the ~175MB rootfs.
manifest_path() { echo "$DATA_DIR/.uml_manifest"; }
write_manifest() { # write_manifest IMAGE_GZ
  {
    echo "kernel=${KERNEL_ASSET}"
    echo "vde=${VDE_ASSET}"
    echo "slirp=${SLIRP_ASSET:-none}"
    echo "stub=${STUB_ASSET:-none}"
    echo "image=${1:-}"
    echo "arch=${ARCH_LABEL}"
  } > "$(manifest_path)" 2>/dev/null || true
}
manifest_val() { # manifest_val KEY (empty when absent; always succeeds)
  grep -E "^${1}=" "$(manifest_path)" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Explicit install sentinel: $DATA_DIR/.installed, written LAST on a
# successful install (and refreshed when helpers change). "Is it installed?"
# is a single file test. Pre-sentinel installs are still recognised via core
# files + manifest, and get backfilled on the next run.
write_installed_marker() { # write_installed_marker IMAGE_GZ
  {
    echo "# UML helpers install sentinel (informational)"
    echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    echo "kernel=${KERNEL_ASSET}"
    echo "vde=${VDE_ASSET}"
    echo "slirp=${SLIRP_ASSET:-none}"
    echo "stub=${STUB_ASSET:-none}"
    echo "image=${1:-}"
    echo "arch=${ARCH_LABEL}"
  } > "$DATA_DIR/.installed" 2>/dev/null || true
}
ensure_installed_marker() {
  [ -f "$DATA_DIR/.installed" ] && return 0
  write_installed_marker "$(manifest_val image)"
}
installed_date() { # installed_date (empty when unknown; always succeeds)
  grep -E "^installed=" "$DATA_DIR/.installed" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Refresh helpers when the mapping drifted (or Android extras are missing),
# without touching base.img. Best effort: on download failure the existing
# files are kept and boot proceeds to preflight.
refresh_android_helpers() {
  [ -n "${SLIRP_ASSET:-}${STUB_ASSET:-}" ] || return 0
  local did=0
  if [ ! -s "$DATA_DIR/linux" ] || [ "$(manifest_val kernel)" != "$KERNEL_ASSET" ]; then
    echo "==> Refreshing kernel ${KERNEL_ASSET}..."
    download "${BASE_URL}/${KERNEL_ASSET}" "$DATA_DIR/linux" || return 1
    did=1
  fi
  if [ ! -s "$DATA_DIR/vde_plug" ] || [ "$(manifest_val vde)" != "$VDE_ASSET" ]; then
    echo "==> Refreshing helper ${VDE_ASSET}..."
    download "${BASE_URL}/${VDE_ASSET}" "$DATA_DIR/vde_plug" || return 1
    did=1
  fi
  if [ -n "${SLIRP_ASSET:-}" ] && { [ ! -s "$DATA_DIR/slirp" ] || [ "$(manifest_val slirp)" != "$SLIRP_ASSET" ]; }; then
    echo "==> Refreshing helper ${SLIRP_ASSET}..."
    download "${BASE_URL}/${SLIRP_ASSET}" "$DATA_DIR/slirp" || return 1
    did=1
  fi
  if [ -n "${STUB_ASSET:-}" ] && { [ ! -s "$DATA_DIR/stub_exe_bionic" ] || [ "$(manifest_val stub)" != "$STUB_ASSET" ]; }; then
    echo "==> Refreshing stub ${STUB_ASSET}..."
    download "${BASE_URL}/${STUB_ASSET}" "$DATA_DIR/stub_exe_bionic" || return 1
    did=1
  fi
  [ "$did" -eq 0 ] && return 0
  ln -sf stub_exe_bionic "$DATA_DIR/stub_exe" 2>/dev/null \
    || cp -f "$DATA_DIR/stub_exe_bionic" "$DATA_DIR/stub_exe" 2>/dev/null || true
  verify_helpers || return 1
  chmod +x "$DATA_DIR/linux" "$DATA_DIR/vde_plug" 2>/dev/null || true
  [ -f "$DATA_DIR/slirp" ] && chmod +x "$DATA_DIR/slirp" 2>/dev/null || true
  if [ -f "$DATA_DIR/stub_exe_bionic" ]; then
    chmod +x "$DATA_DIR/stub_exe_bionic" 2>/dev/null || true
    [ -f "$DATA_DIR/stub_exe" ] && chmod +x "$DATA_DIR/stub_exe" 2>/dev/null || true
  fi
  write_manifest "$(manifest_val image)"
  write_installed_marker "$(manifest_val image)"
  return 0
}

do_install() {
  local want="$1"
  if [ -z "$want" ]; then
    if [ -t 0 ]; then
      list_images
      echo ""
      read -rp "Select image [1-${#DISTROS[@]}] (default: ${DEFAULT_DISTRO}): " want
      want="${want:-$DEFAULT_DISTRO}"
    else
      want="$DEFAULT_DISTRO"
    fi
  fi
  local image_gz
  image_gz="$(resolve_image "$want")"

  echo "==> Architecture: ${UNAME_M} -> ${ARCH_LABEL} (env: ${ENV_KIND})"
  echo "==> Data dir: ${DATA_DIR}"
  echo "==> Image: ${image_gz}"
  echo ""
  ensure_host_deps || exit 1
  echo "==> Downloading UML kernel and networking tools..."
  download_helpers || return 1
  verify_helpers || return 1

  echo "==> Downloading rootfs image ${image_gz}..."
  download "${BASE_URL}/${image_gz}" "$DATA_DIR/rootfs.img.gz"
  if [ ! -s "$DATA_DIR/rootfs.img.gz" ]; then
    echo "[ERROR] Rootfs download failed/empty: ${image_gz}" >&2
    return 1
  fi

  if [ ! -f "$CONFIG" ] || [ "$REINSTALL" -eq 1 ]; then
    echo "==> Downloading default config.yaml..."
    download "${HELPER_URL}/config.yaml" "$CONFIG" || true
  fi

  echo "==> Setting executable permissions..."
  chmod +x "$DATA_DIR/linux" "$DATA_DIR/vde_plug"
  [ -f "$DATA_DIR/slirp" ] && chmod +x "$DATA_DIR/slirp" || true
  if [ -f "$DATA_DIR/stub_exe_bionic" ]; then
    chmod +x "$DATA_DIR/stub_exe_bionic" 2>/dev/null || true
    [ -f "$DATA_DIR/stub_exe" ] && chmod +x "$DATA_DIR/stub_exe" 2>/dev/null || true
  fi

  echo "==> Extracting rootfs image to base.img..."
  gunzip -f "$DATA_DIR/rootfs.img.gz"
  mv -f "$DATA_DIR/rootfs.img" "$ROOTFS"

  # --- optional disk resize on first install (e.g. truncate -s 20G base.img) ---
  local disk="$WANT_DISK"
  if [ -z "$disk" ] && [ -t 0 ]; then
    echo ""
    echo "Current disk size: $(du -h "$ROOTFS" | cut -f1) ($ROOTFS)"
    read -rp "Resize disk? New size (e.g. 20G, empty = keep current): " disk
  fi
  if [ -n "${disk:-}" ]; then
    if [[ ! "$disk" =~ ^[0-9]+[KkMmGg]$ ]]; then
      echo "(!) Invalid disk size '$disk' (use e.g. 20G), keeping current size." >&2
    else
      local num="${disk%[KkMmGg]}" suf="${disk: -1}" mult=1
      case "$suf" in
        K|k) mult=1024 ;;
        M|m) mult=$((1024*1024)) ;;
        G|g) mult=$((1024*1024*1024)) ;;
      esac
      local want_bytes=$((num*mult)) cur_bytes
      cur_bytes=$(stat -c%s "$ROOTFS" 2>/dev/null || stat -f%z "$ROOTFS" 2>/dev/null || echo 0)
      if [ "$want_bytes" -lt "$cur_bytes" ]; then
        echo "(!) $disk is smaller than current image, refusing to shrink." >&2
      else
        echo "==> Resizing base.img to $disk..."
        truncate -s "$disk" "$ROOTFS"
        ensure_e2fsprogs || true
        if command -v e2fsck >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1; then
          e2fsck -f -y "$ROOTFS"
          resize2fs "$ROOTFS"
        else
          # Last resort (no apt either): container grown, grow the filesystem
          # from inside the guest after boot (online grow needs no fsck):
          #   resize2fs /dev/ubda
          # (cloud-init growpart may already do this automatically on first boot.)
          echo "(!) e2fsprogs unavailable on host: container grown to $disk."
          echo "    After boot, grow the filesystem inside the guest:"
          echo "      resize2fs /dev/ubda"
        fi
      fi
    fi
  fi

  # --- userspace mode choice (asked once at install, saved to config.yaml) ---
  if [ "$MODE_EXPLICIT" -eq 0 ] && [ -t 0 ]; then
    local _def="seccomp"
    if is_android; then _def="skas0"; fi
    echo ""
    echo "Userspace mode (how the UML kernel runs):"
    echo "  1) seccomp - fast path; needs host close_range() (breaks on older Android kernels)"
    echo "  2) skas0   - ptrace fallback; slower, works everywhere incl. Android"
    echo "  3) auto    - seccomp where possible, skas0 fallback otherwise"
    local _pick=""
    read -rp "Select mode [1-3] (default: $_def): " _pick || true
    case "${_pick:-}" in
      1) UML_MODE="seccomp" ;;
      2) UML_MODE="skas0" ;;
      3) UML_MODE="auto" ;;
      "") UML_MODE="$_def" ;;
      seccomp|skas0|auto) UML_MODE="$_pick" ;;
      *) echo "(!) Unknown mode '$_pick', keeping default: $_def" >&2; UML_MODE="$_def" ;;
    esac
  fi
  if [ -n "${UML_MODE:-}" ]; then
    persist_config_mode "$UML_MODE" && echo "==> Userspace mode '$UML_MODE' saved to $CONFIG"
  fi
  if [ -n "${UML_INIT_ARG:-${UML_INIT:-}}" ]; then
    if persist_config_init "${UML_INIT_ARG:-$UML_INIT}"; then
      echo "==> Guest init '${UML_INIT_ARG:-$UML_INIT}' saved to $CONFIG"
    fi
  fi
  write_manifest "$image_gz"
  write_installed_marker "$image_gz"

  echo "==> Install complete: kernel=${KERNEL_ASSET}, image=${image_gz} -> base.img"
  if [ -n "${SLIRP_ASSET:-}${STUB_ASSET:-}" ]; then
    echo "    helpers: ${VDE_ASSET}, ${SLIRP_ASSET:-none}, ${STUB_ASSET:-none}"
  fi
  echo "    marker : $DATA_DIR/.installed"
  echo ""
}

yaml_val() {
  # Always succeeds (empty when absent): callers run under `set -e`.
  grep -E "^${1}:" "$CONFIG" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' || true
}

# Auto-detect the guest init binary so non-systemd images (e.g. Alpine with
# OpenRC, /sbin/init) boot without manual --init. Zero new dependencies:
# distro-name heuristic, then a debugfs probe if debugfs happens to be
# present (read-only, no root/mount), then a raw byte scan for the systemd
# path with plain grep (systemd images always carry those bytes, e.g. in the
# /sbin/init symlink body). Prints the path, or /sbin/init as the
# kernel-default guess when systemd traces are absent.
detect_guest_init() { # detect_guest_init IMG [IMAGE_NAME]
  local img="$1" iname="${2:-}" cand out
  case "$iname" in
    *alpine*) echo "/sbin/init"; return 0 ;;
  esac
  if command -v debugfs >/dev/null 2>&1 && [ -f "$img" ]; then
    for cand in /lib/systemd/systemd /usr/lib/systemd/systemd /sbin/init /bin/sh; do
      out="$(debugfs -R "stat $cand" "$img" 2>/dev/null)" || out=""
      case "$out" in
        *"File not found"*) ;;
        *"Inode:"*) echo "$cand"; return 0 ;;
      esac
    done
  fi
  if [ -f "$img" ]; then
    if grep -a -m1 -q -E '/lib/systemd/systemd' "$img" 2>/dev/null; then
      echo "/lib/systemd/systemd"; return 0
    fi
    if grep -a -m1 -q -E '/usr/lib/systemd/systemd' "$img" 2>/dev/null; then
      echo "/usr/lib/systemd/systemd"; return 0
    fi
    echo "/sbin/init"; return 0
  fi
  return 1
}

# Remember the userspace mode pick in config.yaml so later boots
# (incl. startuml.sh) reuse it without asking again.
persist_config_mode() {
  local m="$1"
  case "$m" in seccomp|skas0|auto) ;; *) return 0 ;; esac
  if [ ! -f "$CONFIG" ]; then
    printf '# Written by run.sh install\nmemory: 2G\nncpus: 1\nmode: %s\n' "$m" > "$CONFIG" 2>/dev/null || return 1
    return 0
  fi
  if grep -Eq '^[#[:space:]]*mode:' "$CONFIG" 2>/dev/null; then
    sed -i "s/^[#[:space:]]*mode:.*/mode: $m/" "$CONFIG" 2>/dev/null || return 1
  else
    printf 'mode: %s\n' "$m" >> "$CONFIG" 2>/dev/null || return 1
  fi
  return 0
}

# Remember an explicitly given init (--init/UML_INIT) in config.yaml.
# Auto-detected values are deliberately NOT persisted: the image file may be
# swapped later, and detection re-runs every boot anyway.
persist_config_init() {
  local p="$1"
  [ -n "$p" ] || return 0
  case "$p" in
    /*) ;;
    *) echo "[ERROR] Invalid init path: $p (use an absolute guest path)" >&2; return 1 ;;
  esac
  if [ ! -f "$CONFIG" ]; then
    printf '# Written by run.sh install\nmemory: 2G\nncpus: 1\ninit: %s\n' "$p" > "$CONFIG" 2>/dev/null || return 1
    return 0
  fi
  if grep -Eq '^[#[:space:]]*init:' "$CONFIG" 2>/dev/null; then
    sed -i "s|^[#[:space:]]*init:.*|init: $p|" "$CONFIG" 2>/dev/null || return 1
  else
    printf 'init: %s\n' "$p" >> "$CONFIG" 2>/dev/null || return 1
  fi
  return 0
}

do_boot() {
  # --- arguments: [memory] [ncpus] (both optional, config.yaml overrides; env wins) ---
  local memory="${MEMORY_ARG:-${MEMORY:-$(yaml_val memory)}}"
  memory="${memory:-2G}"
  local ncpus="${NCPUS_ARG:-${NCPUS:-$(yaml_val ncpus)}}"
  ncpus="${ncpus:-1}"
  case "$ncpus" in
    ''|*[!0-9]*) ncpus=1 ;;
  esac
  [ "$ncpus" -lt 1 ] && ncpus=1
  # Guest init: --init flag > UML_INIT env > config `init:` > auto-detect
  # from the image (systemd, Alpine /sbin/init, ...) > historic default.
  local init_bin="${UML_INIT_ARG:-${UML_INIT:-$(yaml_val init)}}"
  if [ -z "$init_bin" ]; then
    init_bin="$(detect_guest_init "$ROOTFS" "$(manifest_val image)" || true)"
  fi
  init_bin="${init_bin:-/lib/systemd/systemd}"

  for f in "$KERNEL" "$ROOTFS" "$DATA_DIR/vde_plug"; do
    if [ ! -f "$f" ]; then echo "[ERROR] Missing: $f (run with --reinstall?)"; exit 1; fi
  done
  if [ ! -x "$DATA_DIR/vde_plug" ]; then chmod +x "$DATA_DIR/vde_plug"; fi
  if [ ! -x "$KERNEL" ]; then chmod +x "$KERNEL"; fi

  # Helper drift (e.g. Android mapping gained slirp/stub after install):
  # fetch just the helpers, keep base.img. Best effort - boot proceeds
  # with existing files if the refresh fails.
  refresh_android_helpers || echo "[!] Helper refresh failed; continuing with existing files." >&2

  # Fail fast with a clear message instead of cryptic exec errors
  # (Android/bionic, noexec mounts, truncated downloads).
  # Set UML_IGNORE_PREFLIGHT=1 to attempt boot anyway.
  if [ -z "${UML_IGNORE_PREFLIGHT:-}" ]; then
    preflight_kernel "$KERNEL" || exit 1
  fi
  if is_android; then
    echo "[!] Android detected: if boot fails, run inside proot-distro Debian instead." >&2
  fi

  KERNEL_HAS_SMP=0
  if command -v strings >/dev/null 2>&1 && strings "$KERNEL" 2>/dev/null | grep -q '^CONFIG_SMP=y'; then
    KERNEL_HAS_SMP=1
  fi

  SHM_TEST=$(mktemp /dev/shm/.uml_XXXXXX 2>/dev/null) || true
  if [ -n "$SHM_TEST" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$SHM_TEST"
    chmod +x "$SHM_TEST" 2>/dev/null
    if "$SHM_TEST" 2>/dev/null; then SHM_OK=1; else SHM_OK=0; fi
    rm -f "$SHM_TEST"
  else
    SHM_OK=0
  fi

  SMP_ARGS=""
  SKAS_MODE=""

  # Userspace mode, resolved: explicit --mode/UML_MODE > config.yaml > default.
  #   seccomp: always pass seccomp=on (memfd physmem backport, no /dev/shm dep).
  #   skas0:   force PTRACE fallback when /dev/shm is slow / seccomp unavailable.
  #   auto:    legacy behavior (seccomp on SMP kernels, skas0 fallback on UP).
  local mode="${UML_MODE:-$(yaml_val mode)}"
  if [ -z "$mode" ]; then
    if is_android; then mode="skas0"; else mode="seccomp"; fi
  fi
  case "$mode" in
    seccomp)
      if [ "$KERNEL_HAS_SMP" -eq 1 ]; then
        SMP_ARGS="ncpus=$ncpus seccomp=on"
      else
        SMP_ARGS="seccomp=on"
      fi
      ;;
    skas0)
      if [ "$SHM_OK" -eq 0 ]; then
        SKAS_MODE="mode=skas0"
      fi
      if [ "$KERNEL_HAS_SMP" -eq 1 ]; then
        SMP_ARGS="ncpus=$ncpus"
      fi
      ;;
    auto)
      if [ "$KERNEL_HAS_SMP" -eq 1 ] && [ "$ncpus" -gt 1 ]; then
        SMP_ARGS="ncpus=$ncpus seccomp=on"
      elif [ "$KERNEL_HAS_SMP" -eq 1 ]; then
        SMP_ARGS="ncpus=1 seccomp=on"
      else
        if [ "$SHM_OK" -eq 0 ]; then
          SKAS_MODE="mode=skas0"
        fi
      fi
      ;;
    *)
      echo "[ERROR] Invalid mode: $mode (use seccomp|skas0|auto; check --mode, UML_MODE, $CONFIG)" >&2
      exit 1
      ;;
  esac

  # Tmpdir: Pterodactyl pins $DATA_DIR/.uml_tmp; standard prefers
  # XDG_RUNTIME_DIR//tmp with exec check. Override via TMP_DIR env.
  UML_TMPDIR="$(setup_tmpdir)"
  export TMP="$UML_TMPDIR" TMPDIR="$UML_TMPDIR" TEMP="$UML_TMPDIR"
  # Best effort: allow exec on /dev/shm when privileged (harmless if denied).
  # On standard hosts with sudo, actually try to fix it.
  if command -v sudo >/dev/null 2>&1 && [ "$ENV_KIND" = "standard" ]; then
    sudo mount -o remount,exec /dev/shm 2>/dev/null || mount -o remount,exec /dev/shm 2>/dev/null || true
  else
    mount -o remount,exec /dev/shm 2>/dev/null || true
  fi

  export PATH="$DATA_DIR:$BASE:$PATH"

  echo "========================================"
  echo "  UML Virtual Machine ($ENV_KIND / $ARCH_LABEL)"
  echo "----------------------------------------"
  if [ "$KERNEL_HAS_SMP" -eq 1 ] && [ "$ncpus" -gt 1 ]; then
    echo "  CPUs     : $ncpus (SMP, seccomp userspace)"
  elif [ "$KERNEL_HAS_SMP" -eq 1 ]; then
    echo "  CPUs     : 1 (SMP kernel, 1 vCPU)"
  else
    echo "  CPUs     : 1 (UP kernel)"
  fi
  echo "  Memory   : $memory"
  echo "  Network  : VDE VECTOR + libslirp NAT"
  if [ -n "$SKAS_MODE" ]; then echo "  Userspace: skas0 (slow /dev/shm fallback)"; else echo "  Userspace: seccomp"; fi
  echo "  Init     : $init_bin"
  echo "  Config   : $CONFIG"
  echo "  Data     : $DATA_DIR"
  echo "  Tmp      : $UML_TMPDIR"
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

  # Console selection. fd works everywhere (Pterodactyl-safe); xterm opens a
  # window on desktop hosts; none detaches (logs only).
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
    [ "$UML_CONSOLE" = "fd" ] && [ ! -t 0 ] && echo "(stdin is not a TTY; consider --console none for services)"
  fi

  # shellcheck disable=SC2086
  exec "$KERNEL" \
    mem="$memory" \
    $SKAS_MODE \
    $SMP_ARGS \
    ubd0="$ROOTFS" \
    root=/dev/ubda rw \
    init="$init_bin" \
    "vec0:transport=vde,vnl=slirp://" \
    $CON_ARGS
}

if need_install; then
  echo "==> First run: installing UML environment..."
  do_install "$WANT_IMAGE"
else
  _when="$(installed_date)"
  if [ -n "$_when" ]; then
    echo "==> Existing install found (installed $_when), skipping download."
  else
    echo "==> Existing install found, skipping download."
  fi
  # Pre-sentinel installs are recognised via files+manifest; backfill the
  # explicit marker so `test -f .installed` works going forward.
  ensure_installed_marker
fi

if [ "$INSTALL_ONLY" -eq 1 ]; then
  echo "Install-only mode: not booting."
  echo "  - (Optional) Resize: ./resizeimg.sh \"$ROOTFS\" <SIZE>"
  echo "  - Boot: ./run.sh"
  exit 0
fi

do_boot
