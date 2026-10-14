#!/bin/bash
# run.sh - merged installer + launcher (Pterodactyl + standard Linux).
#   First run: picks/downloads kernel, tools, rootfs image (-> base.img).
#   Every run: boots UML.
# Works in Pterodactyl containers AND on a regular Linux host/VM.
# Architecture-aware: x86_64 and arm64 (aarch64), override via --arch / UML_ARCH.
# Based from LNQuang
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
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
apply_arch() {
  case "$1" in
    x86_64|amd64)
      ARCH_LABEL="x86_64"; IMG_SUFFIX=""; KERNEL_ASSET="linux-uml"; VDE_ASSET="vde_plug-x86_64"
      LIB_TRIPLET="x86_64-linux-gnu"
      ;;
    arm64|aarch64)
      ARCH_LABEL="arm64"; IMG_SUFFIX="-arm64"; KERNEL_ASSET="linux-uml-arm64"; VDE_ASSET="vde_plug-arm64"
      LIB_TRIPLET="aarch64-linux-gnu"
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
  --mode MODE       Userspace mode: seccomp (default), skas0, auto.
                    Env: UML_MODE. seccomp avoids /dev/shm via memfd
                    backport; skas0 forces PTRACE fallback.
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
UML_MODE="${UML_MODE:-seccomp}"
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
    --mode) UML_MODE="${2:-}"; shift 2 ;;
    --mode=*) UML_MODE="${1#--mode=}"; shift ;;
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

need_install() {
  [ "$REINSTALL" -eq 1 ] && return 0
  [ ! -f "$KERNEL" ] && return 0
  [ ! -f "$DATA_DIR/vde_plug" ] && return 0
  [ ! -f "$ROOTFS" ] && return 0
  [ ! -f "$CONFIG" ] && return 0
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
  local cand
  for cand in "${XDG_RUNTIME_DIR:-}/uml-tmp" "/tmp/uml-$USER" "$DATA_DIR/.uml_tmp"; do
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
  download "${BASE_URL}/${KERNEL_ASSET}" "$DATA_DIR/linux"
  download "${BASE_URL}/${VDE_ASSET}" "$DATA_DIR/vde_plug"
  # NOTE: upstream dropped standalone slirp binaries (v2026.09.26-18+);
  # networking is provided via vde_plug, so no slirp download needed.
  rm -f "$DATA_DIR/slirp" "$BASE/slirp"

  echo "==> Downloading rootfs image ${image_gz}..."
  download "${BASE_URL}/${image_gz}" "$DATA_DIR/rootfs.img.gz"

  if [ ! -f "$CONFIG" ] || [ "$REINSTALL" -eq 1 ]; then
    echo "==> Downloading default config.yaml..."
    download "${HELPER_URL}/config.yaml" "$CONFIG" || true
  fi

  echo "==> Setting executable permissions..."
  chmod +x "$DATA_DIR/linux" "$DATA_DIR/vde_plug"
  [ -f "$DATA_DIR/slirp" ] && chmod +x "$DATA_DIR/slirp" || true

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

  echo "==> Install complete: kernel=${KERNEL_ASSET}, image=${image_gz} -> base.img"
  echo ""
}

yaml_val() {
  grep -E "^${1}:" "$CONFIG" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'
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

  for f in "$KERNEL" "$ROOTFS" "$DATA_DIR/vde_plug"; do
    if [ ! -f "$f" ]; then echo "[ERROR] Missing: $f (run with --reinstall?)"; exit 1; fi
  done
  if [ ! -x "$DATA_DIR/vde_plug" ]; then chmod +x "$DATA_DIR/vde_plug"; fi
  if [ ! -x "$KERNEL" ]; then chmod +x "$KERNEL"; fi

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

  # Userspace mode (default: seccomp instead of skas0).
  #   seccomp: always pass seccomp=on (memfd physmem backport, no /dev/shm dep).
  #   skas0:   force PTRACE fallback when /dev/shm is slow.
  #   auto:    legacy behavior (seccomp on SMP kernels, skas0 fallback on UP).
  case "$UML_MODE" in
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
      echo "[ERROR] Invalid UML_MODE: $UML_MODE (use seccomp|skas0|auto)" >&2
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
    init=/lib/systemd/systemd \
    "vec0:transport=vde,vnl=slirp://" \
    $CON_ARGS
}

if need_install; then
  echo "==> First run: installing UML environment..."
  do_install "$WANT_IMAGE"
else
  echo "==> Existing install found, skipping download."
fi

if [ "$INSTALL_ONLY" -eq 1 ]; then
  echo "Install-only mode: not booting."
  echo "  - (Optional) Resize: ./resizeimg.sh \"$ROOTFS\" <SIZE>"
  echo "  - Boot: ./run.sh"
  exit 0
fi

do_boot
