#!/bin/bash
# install.sh - install-only. Works on Pterodactyl AND standard Linux.
# For one-step install+boot, use run.sh instead.
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

REPO="dxomg/uml-kernel-build"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

apply_arch() {
  case "$1" in
    x86_64|amd64)
      ARCH_LABEL="x86_64"; IMG_SUFFIX=""; KERNEL_ASSET="linux-uml"; VDE_ASSET="vde_plug-x86_64" ;;
    arm64|aarch64)
      ARCH_LABEL="arm64"; IMG_SUFFIX="-arm64"; KERNEL_ASSET="linux-uml-arm64"; VDE_ASSET="vde_plug-arm64"
      # Android arm64 cannot exec glibc binaries: use static bionic assets.
      if is_android; then
        KERNEL_ASSET="linux-bionic"; VDE_ASSET="vde_plug-android-arm64"
      fi
      ;;
    *) echo "Invalid --arch: $1 (use x86_64|arm64)" >&2; return 1 ;;
  esac
  UNAME_M="$1"
}
is_android() {
  [ -n "${PREFIX:-}" ] && case "$PREFIX" in *com.termux*) return 0 ;; esac
  [ -d "/system/app" ] && [ ! -d "/usr/bin" ] && return 0
  [ -f "/system/build.prop" ] && ! command -v dpkg >/dev/null 2>&1 && return 0
  [ "$(uname -o 2>/dev/null)" = "Android" ] && return 0
  return 1
}
UNAME_M="${UML_ARCH:-$(uname -m 2>/dev/null || echo x86_64)}"
case "$UNAME_M" in
  amd64) UNAME_M="x86_64" ;;
  aarch64) UNAME_M="arm64" ;;
esac
apply_arch "$UNAME_M" || exit 1

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

download() { # download URL DEST-or-blank(for cwd file)
  local url="$1" dest="${2:-}"
  if command -v wget >/dev/null 2>&1; then
    if [ -n "$dest" ]; then wget -q --show-progress -O "$dest" "$url"
    else wget -q --show-progress "$url"; fi
  elif command -v curl >/dev/null 2>&1; then
    if [ -n "$dest" ]; then curl -fSL --progress-bar -o "$dest" "$url"
    else curl -fSL -O "$url"; fi
  else
    echo "[ERROR] Need wget or curl to download $url" >&2
    return 1
  fi
}

# Distros available in the latest release (must match uml-kernel-build assets)
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

image_for() {
  echo "base-${1}${IMG_SUFFIX}.img.gz"
}

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
Usage: $0 [OPTIONS] [IMAGE|NUMBER]

Options:
  -l, --list        List available images and exit
  -a, --arch ARCH   Override arch: x86_64 | arm64 (default: auto-detected ${ARCH_LABEL}).
                    Env: UML_ARCH.
  --env ENV         Override env: auto (default), pterodactyl, standard. Env: UML_ENV.
  --data-dir DIR    Install into DIR instead of script dir. Env: UML_DATA_DIR.
  -h, --help        Show this help

IMAGE can be:
  - a number from --list (e.g. 1)
  - a distro short name (e.g. debian-trixie, ubuntu-noble)
  - a full asset name (e.g. base-debian-trixie.img.gz)

No arg (interactive terminal) -> menu prompt. No arg (non-interactive) -> default: ${DEFAULT_DISTRO}.
Examples:
  $0 --list
  $0 debian-trixie
  $0 1
  $0 base-ubuntu-noble${IMG_SUFFIX}.img.gz
  $0 --arch arm64 --data-dir ~/.local/share/uml debian-trixie
EOF
}

# --- parse args ---
ACTION="install"
WANT="${UML_IMAGE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list) ACTION="list"; shift ;;
    -a|--arch)
      apply_arch "${2:-}" || exit 1
      shift 2 ;;
    --arch=*) apply_arch "${1#--arch=}" || exit 1; shift ;;
    --env) UML_ENV="${2:-auto}"; ENV_KIND="$(detect_env)"; shift 2 ;;
    --env=*) UML_ENV="${1#--env=}"; ENV_KIND="$(detect_env)"; shift ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --data-dir=*) DATA_DIR="${1#--data-dir=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) WANT="$1"; shift ;;
  esac
done

if [ "$ACTION" = "list" ]; then
  list_images
  exit 0
fi

resolve_image() {
  local want="$1"
  # numeric selection?
  if [[ "$want" =~ ^[0-9]+$ ]]; then
    local idx=$((want-1))
    if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DISTROS[@]}" ]; then
      image_for "${DISTROS[$idx]}"
      return 0
    fi
    echo "Invalid selection: $want (1-${#DISTROS[@]})" >&2
    return 1
  fi
  # full asset name?
  if [[ "$want" == base-*.img.gz ]]; then
    echo "$want"
    return 0
  fi
  # short distro name (with or without base- prefix / .img.gz suffix)?
  local d="$want"
  d="${d#base-}"
  d="${d%.img.gz}"
  # strip trailing -arm64 if user pasted the other arch by mistake
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

if [ -z "$WANT" ]; then
  if [ -t 0 ]; then
    list_images
    echo ""
    read -rp "Select image [1-${#DISTROS[@]}] (default: ${DEFAULT_DISTRO}): " WANT
    WANT="${WANT:-$DEFAULT_DISTRO}"
  else
    WANT="$DEFAULT_DISTRO"
  fi
fi

IMAGE_GZ="$(resolve_image "$WANT")"

mkdir -p "$DATA_DIR" || { echo "[ERROR] Data dir not writable: $DATA_DIR" >&2; exit 1; }
cd "$DATA_DIR" 2>/dev/null || true  # best effort; all paths below are $DATA_DIR-prefixed anyway

echo "==> Architecture: ${UNAME_M} -> ${ARCH_LABEL} (env: ${ENV_KIND})"
echo "==> Data dir: ${DATA_DIR}"
echo "==> Image: ${IMAGE_GZ}"
echo ""
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] Need wget or curl." >&2
  [ "$ENV_KIND" = "standard" ] && echo "  Fix (Debian/Ubuntu): sudo apt-get install -y wget" >&2
  exit 1
fi
echo "==> Downloading latest UML kernel and networking tools..."
download "${BASE_URL}/${KERNEL_ASSET}" "$DATA_DIR/linux"
download "${BASE_URL}/${VDE_ASSET}" "$DATA_DIR/vde_plug"
# NOTE: upstream dropped standalone slirp binaries (v2026.09.26-18+);
# networking is provided via vde_plug, so no slirp download needed.
rm -f "$DATA_DIR/slirp" ./slirp

echo "==> Downloading rootfs image ${IMAGE_GZ}..."
download "${BASE_URL}/${IMAGE_GZ}" "$DATA_DIR/rootfs.img.gz"

echo "==> Downloading helper scripts and configuration..."
# Keep helpers next to the install script (repo dir), not DATA_DIR, so a
# custom --data-dir still leaves launchers where the user expects them.
download https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/startuml.sh "$BASE/startuml.sh" || true
download https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/resizeimg.sh "$BASE/resizeimg.sh" || true
if [ "$DATA_DIR" = "$BASE" ]; then
  download https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/config.yaml "$DATA_DIR/config.yaml" || true
elif [ ! -f "$DATA_DIR/config.yaml" ]; then
  if [ -f "$BASE/config.yaml" ]; then cp "$BASE/config.yaml" "$DATA_DIR/config.yaml"
  else download https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/config.yaml "$DATA_DIR/config.yaml" || true
  fi
fi

echo "==> Setting executable permissions..."
chmod +x "$DATA_DIR/linux" "$DATA_DIR/vde_plug" "$BASE/startuml.sh" "$BASE/resizeimg.sh" 2>/dev/null || true
[ -f "$DATA_DIR/slirp" ] && chmod +x "$DATA_DIR/slirp" || true

echo "==> Extracting rootfs image to base.img..."
gunzip -f "$DATA_DIR/rootfs.img.gz"
mv -f "$DATA_DIR/rootfs.img" "$DATA_DIR/base.img"

echo "==> Setup complete!"
echo ""
echo "Installed:"
echo "  - kernel : ${KERNEL_ASSET} -> $DATA_DIR/linux"
echo "  - image  : ${IMAGE_GZ} -> $DATA_DIR/base.img"
echo ""
echo "Next steps:"
echo "  - (Optional) Resize your image: ./resizeimg.sh \"$DATA_DIR/base.img\" <SIZE>"
echo "  - Start the UML environment:   ./startuml.sh"
echo "    (standard host with custom dir: UML_DATA_DIR=\"$DATA_DIR\" ./startuml.sh)"
