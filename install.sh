#!/bin/bash
set -euo pipefail

REPO="dxomg/uml-kernel-build"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

# Detect host arch -> release asset suffix
UNAME_M="$(uname -m 2>/dev/null || echo x86_64)"
case "$UNAME_M" in
  x86_64|amd64)
    ARCH_LABEL="x86_64"
    IMG_SUFFIX=""        # e.g. base-debian-trixie.img.gz
    KERNEL_ASSET="linux-uml"
    SLIRP_ASSET="slirp-x86_64"
    VDE_ASSET="vde_plug-x86_64"
    ;;
  aarch64|arm64)
    ARCH_LABEL="arm64"
    IMG_SUFFIX="-arm64"  # e.g. base-debian-trixie-arm64.img.gz
    KERNEL_ASSET="linux-uml-arm64"
    SLIRP_ASSET="slirp-arm64"
    VDE_ASSET="vde_plug-arm64"
    ;;
  *)
    echo "Unsupported architecture: $UNAME_M (expected x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

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
  -a, --arch ARCH   Override arch: x86_64 | arm64 (default: auto-detected ${ARCH_LABEL})
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
EOF
}

# --- parse args ---
ACTION="install"
WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list) ACTION="list"; shift ;;
    -a|--arch)
      case "${2:-}" in
        x86_64|amd64) IMG_SUFFIX=""; KERNEL_ASSET="linux-uml"; SLIRP_ASSET="slirp-x86_64"; VDE_ASSET="vde_plug-x86_64"; ARCH_LABEL="x86_64" ;;
        arm64|aarch64) IMG_SUFFIX="-arm64"; KERNEL_ASSET="linux-uml-arm64"; SLIRP_ASSET="slirp-arm64"; VDE_ASSET="vde_plug-arm64"; ARCH_LABEL="arm64" ;;
        *) echo "Invalid --arch: $2 (use x86_64|arm64)" >&2; exit 1 ;;
      esac
      shift 2 ;;
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

echo "==> Architecture: ${UNAME_M} -> ${ARCH_LABEL}"
echo "==> Image: ${IMAGE_GZ}"
echo ""
echo "==> Downloading latest UML kernel and networking tools..."
wget -q --show-progress -O linux "${BASE_URL}/${KERNEL_ASSET}"
wget -q --show-progress -O vde_plug "${BASE_URL}/${VDE_ASSET}"
# slirp was dropped from newer releases (e.g. v2026.09.26-18) - best effort only
if ! wget -q --show-progress -O slirp "${BASE_URL}/${SLIRP_ASSET}"; then
  echo "(!) ${SLIRP_ASSET} not found in latest release, skipping (newer releases omit slirp)."
  rm -f slirp
fi

echo "==> Downloading rootfs image ${IMAGE_GZ}..."
wget -q --show-progress -O rootfs.img.gz "${BASE_URL}/${IMAGE_GZ}"

echo "==> Downloading helper scripts and configuration..."
wget -q --show-progress https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/startuml.sh
wget -q --show-progress https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/resizeimg.sh
wget -q --show-progress https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/config.yaml

echo "==> Setting executable permissions..."
chmod +x linux vde_plug startuml.sh resizeimg.sh
[ -f slirp ] && chmod +x slirp || true

echo "==> Extracting rootfs image to base.img..."
gunzip -f rootfs.img.gz
mv -f rootfs.img base.img

echo "==> Setup complete!"
echo ""
echo "Installed:"
echo "  - kernel : ${KERNEL_ASSET} -> linux"
echo "  - image  : ${IMAGE_GZ} -> base.img"
echo ""
echo "Next steps:"
echo "  - (Optional) Resize your image: ./resizeimg.sh base.img <SIZE>"
echo "  - Start the UML environment:   ./startuml.sh"
