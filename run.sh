#!/bin/bash
# run.sh - merged installer + launcher (Pterodactyl-friendly).
#   First run: picks/downloads kernel, tools, rootfs image (-> base.img).
#   Every run: boots UML.
# Based from LNQuang
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$BASE/linux"
ROOTFS="$BASE/base.img"
CONFIG="$BASE/config.yaml"

REPO="dxomg/uml-kernel-build"
BASE_URL="https://github.com/${REPO}/releases/latest/download"
HELPER_URL="https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main"

# Detect host arch -> release asset suffix
UNAME_M="$(uname -m 2>/dev/null || echo x86_64)"
case "$UNAME_M" in
  x86_64|amd64)
    ARCH_LABEL="x86_64"
    IMG_SUFFIX=""
    KERNEL_ASSET="linux-uml"
    SLIRP_ASSET="slirp-x86_64"
    VDE_ASSET="vde_plug-x86_64"
    ;;
  aarch64|arm64)
    ARCH_LABEL="arm64"
    IMG_SUFFIX="-arm64"
    KERNEL_ASSET="linux-uml-arm64"
    SLIRP_ASSET="slirp-arm64"
    VDE_ASSET="vde_plug-arm64"
    ;;
  *)
    echo "Unsupported architecture: $UNAME_M (expected x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

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

Options:
  -i, --image IMG   Image to install: number, short name (debian-trixie),
                    or full asset (base-debian-trixie.img.gz).
                    Env: UML_IMAGE (same values). Interactive prompt if TTY
                    and unset, otherwise default: ${DEFAULT_DISTRO}
  -l, --list        List available images and exit
  --reinstall       Force re-download even if files exist
  --install-only    Install but do not boot
  -h, --help        Show this help

Positional (boot, same as startuml.sh):
  MEMORY  e.g. 2G (default: config.yaml memory or 2G; env MEMORY wins)
  NCPUS   e.g. 1 (default: config.yaml ncpus or 1; env NCPUS wins)

Examples:
  $0 --list
  $0 --image 1
  $0 --image debian-trixie
  UML_IMAGE=ubuntu-noble $0 4G 2
  $0 2G 1
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
REINSTALL=0
INSTALL_ONLY=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--image) WANT_IMAGE="${2:-}"; shift 2 ;;
    --image=*) WANT_IMAGE="${1#--image=}"; shift ;;
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
  [ ! -f "$BASE/vde_plug" ] && return 0
  [ ! -f "$ROOTFS" ] && return 0
  [ ! -f "$CONFIG" ] && return 0
  return 1
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

  echo "==> Architecture: ${UNAME_M} -> ${ARCH_LABEL}"
  echo "==> Image: ${image_gz}"
  echo ""
  echo "==> Downloading UML kernel and networking tools..."
  wget -q --show-progress -O "$BASE/linux" "${BASE_URL}/${KERNEL_ASSET}"
  wget -q --show-progress -O "$BASE/vde_plug" "${BASE_URL}/${VDE_ASSET}"
  # slirp was dropped from newer releases (e.g. v2026.09.26-18) - best effort only
  if ! wget -q --show-progress -O "$BASE/slirp" "${BASE_URL}/${SLIRP_ASSET}"; then
    echo "(!) ${SLIRP_ASSET} not found in latest release, skipping (newer releases omit slirp)."
    rm -f "$BASE/slirp"
  fi

  echo "==> Downloading rootfs image ${image_gz}..."
  wget -q --show-progress -O "$BASE/rootfs.img.gz" "${BASE_URL}/${image_gz}"

  if [ ! -f "$CONFIG" ] || [ "$REINSTALL" -eq 1 ]; then
    echo "==> Downloading default config.yaml..."
    wget -q --show-progress -O "$CONFIG" "${HELPER_URL}/config.yaml" || true
  fi

  echo "==> Setting executable permissions..."
  chmod +x "$BASE/linux" "$BASE/vde_plug"
  [ -f "$BASE/slirp" ] && chmod +x "$BASE/slirp" || true

  echo "==> Extracting rootfs image to base.img..."
  gunzip -f "$BASE/rootfs.img.gz"
  mv -f "$BASE/rootfs.img" "$ROOTFS"

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

  for f in "$KERNEL" "$ROOTFS" "$BASE/vde_plug"; do
    if [ ! -f "$f" ]; then echo "[ERROR] Missing: $f (run with --reinstall?)"; exit 1; fi
  done
  if [ ! -x "$BASE/vde_plug" ]; then chmod +x "$BASE/vde_plug"; fi
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

  if [ "$KERNEL_HAS_SMP" -eq 1 ] && [ "$ncpus" -gt 1 ]; then
    SMP_ARGS="ncpus=$ncpus seccomp=on"
  elif [ "$KERNEL_HAS_SMP" -eq 1 ]; then
    SMP_ARGS="ncpus=1 seccomp=on"
  else
    if [ "$SHM_OK" -eq 0 ]; then
      SKAS_MODE="mode=skas0"
    fi
  fi

  if [ "$SHM_OK" -eq 0 ]; then
    mkdir -p "$BASE/.uml_tmp"
    export TMP="$BASE/.uml_tmp" TMPDIR="$BASE/.uml_tmp" TEMP="$BASE/.uml_tmp"
  fi

  export PATH="$BASE:$PATH"

  echo "========================================"
  echo "  UML Virtual Machine"
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
  if [ -n "$SKAS_MODE" ]; then echo "  Userspace: skas0 (slow /dev/shm fallback)"; fi
  echo "  Config   : $CONFIG"
  echo "----------------------------------------"
  echo "  Login: root / root"
  echo "========================================"
  echo ""

  cleanup() { if [ -n "$SKAS_MODE" ]; then rm -rf "$BASE/.uml_tmp" 2>/dev/null; fi; }
  trap cleanup EXIT

  exec "$KERNEL" \
    mem="$memory" \
    $SKAS_MODE \
    $SMP_ARGS \
    ubd0="$ROOTFS" \
    root=/dev/ubda rw \
    init=/lib/systemd/systemd \
    "vec0:transport=vde,vnl=slirp://" \
    con0=fd:0,fd:1 \
    con=null
}

if need_install; then
  echo "==> First run: installing UML environment..."
  do_install "$WANT_IMAGE"
else
  echo "==> Existing install found, skipping download."
fi

if [ "$INSTALL_ONLY" -eq 1 ]; then
  echo "Install-only mode: not booting."
  echo "  - (Optional) Resize: ./resizeimg.sh base.img <SIZE>"
  echo "  - Boot: ./run.sh"
  exit 0
fi

do_boot
