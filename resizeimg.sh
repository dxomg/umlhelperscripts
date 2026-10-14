#!/bin/bash
# resizeimg.sh - resize a UML/QEMU raw rootfs image + ext4 filesystem.
# Works on Pterodactyl AND standard Linux, non-interactive friendly.
#
# Usage:
#   ./resizeimg.sh [IMG] [SIZE] [OPTIONS]
#   ./resizeimg.sh base.img 20G
#   ./resizeimg.sh base.img +5G --no-backup --yes
#
# SIZE: absolute (20G, 2048M) or increment (+5G, +500M).
# Options:
#   -y, --yes           Assume yes to expand-fs (non-interactive)
#   --backup / --no-backup     Create ${IMG}.bak before resize (default: prompt / no in non-interactive)
#   --expand / --no-expand     Expand ext4 afterwards (default: yes with -y, else prompt)
#   -h, --help          Show help
#
# Env: IMG_PATH, TARGET_SIZE (same as positional args).
# No args -> legacy interactive prompts (Pterodactyl-safe).
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [IMG_PATH] [SIZE] [OPTIONS]

Resize raw image container (qemu-img if present, else truncate) and
expand the ext4 filesystem (e2fsck + resize2fs).

Examples:
  $0 base.img 20G
  $0 base.img +5G --no-backup -y
  $0 --help
EOF
}

IMG_PATH="${IMG_PATH:-}"
TARGET_SIZE="${TARGET_SIZE:-}"
ASSUME_YES=0
BACKUP=""   # yes|no|empty=prompt
EXPAND=""   # yes|no|empty=prompt
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    --backup) BACKUP="yes"; shift ;;
    --no-backup) BACKUP="no"; shift ;;
    --expand) EXPAND="yes"; shift ;;
    --no-expand) EXPAND="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$IMG_PATH" ]; then IMG_PATH="$1";
      elif [ -z "$TARGET_SIZE" ]; then TARGET_SIZE="$1";
      else echo "Unexpected arg: $1" >&2; usage >&2; exit 1; fi
      shift ;;
  esac
done

echo "=== Rootfs Image Resizer (raw + ext4) ==="

if [ -z "$IMG_PATH" ]; then
  if [ -t 0 ]; then
    read -rp "Enter path to your .img file: " IMG_PATH
  else
    echo "[-] Missing IMG_PATH. Usage: $0 <img> <size>" >&2
    exit 1
  fi
fi
if [ ! -f "$IMG_PATH" ]; then
  echo "[-] Error: File '$IMG_PATH' not found." >&2
  exit 1
fi
if [ ! -w "$IMG_PATH" ]; then
  echo "[-] Error: You do not have write permissions for '$IMG_PATH'." >&2
  echo "    Try running with sudo, or change the file ownership." >&2
  exit 1
fi

# Show current info (qemu-img when available, else ls/du).
echo ""
echo "Current image details:"
if command -v qemu-img >/dev/null 2>&1; then
  qemu-img info "$IMG_PATH" || du -h "$IMG_PATH"
else
  echo "(qemu-img not installed, using truncate fallback)"
  du -h "$IMG_PATH"
  ls -l "$IMG_PATH"
fi

if [ -z "$TARGET_SIZE" ]; then
  if [ ! -t 0 ]; then
    echo "[-] Missing SIZE. Usage: $0 <img> <size> (e.g. 20G or +5G)" >&2
    exit 1
  fi
  echo ""
  echo "How would you like to specify the new size?"
  echo "1) Absolute size (e.g., 5G, 2048M)"
  echo "2) Increment / Add space (e.g., +2G, +500M)"
  read -rp "Select option [1-2]: " SIZE_OPT
  read -rp "Enter the size value (e.g., 5G or +2G): " TARGET_SIZE
  if [ "$SIZE_OPT" = "2" ]; then
    case "$TARGET_SIZE" in +*) ;; *) TARGET_SIZE="+$TARGET_SIZE" ;; esac
  fi
fi
SIZE_ARG="$TARGET_SIZE"

# Refuse to shrink: compare wanted bytes vs current bytes for absolute sizes.
if [[ "$SIZE_ARG" != +* ]]; then
  if [[ "$SIZE_ARG" =~ ^([0-9]+)([KkMmGg])$ ]]; then
    num="${BASH_REMATCH[1]}" suf="${BASH_REMATCH[2]}" mult=1
    case "$suf" in K|k) mult=1024 ;; M|m) mult=$((1024*1024)) ;; G|g) mult=$((1024*1024*1024)) ;; esac
    want_bytes=$((num*mult))
    cur_bytes=$(stat -c%s "$IMG_PATH" 2>/dev/null || stat -f%z "$IMG_PATH" 2>/dev/null || echo 0)
    if [ "$want_bytes" -lt "$cur_bytes" ]; then
      echo "[-] $SIZE_ARG is smaller than current image, refusing to shrink." >&2
      exit 1
    fi
  fi
fi

# Backup prompt (default no in non-interactive / -y).
if [ -z "$BACKUP" ]; then
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    BACKUP="no"
  else
    read -rp "[?] Do you want to create a backup copy before resizing? (y/n): " BACKUP_IN
    case "$BACKUP_IN" in [Yy]*) BACKUP="yes" ;; *) BACKUP="no" ;; esac
  fi
fi
if [ "$BACKUP" = "yes" ]; then
  BACKUP_PATH="${IMG_PATH}.bak"
  echo "[+] Creating backup at $BACKUP_PATH..."
  cp "$IMG_PATH" "$BACKUP_PATH"
  echo "[+] Backup complete."
fi

# Step 1: Resize the raw image container.
if command -v qemu-img >/dev/null 2>&1; then
  echo "[+] Resizing image container with qemu-img..."
  qemu-img resize -f raw "$IMG_PATH" "$SIZE_ARG" || { echo "[-] qemu-img resize failed." >&2; exit 1; }
else
  # truncate fallback: supports absolute (20G) and +increment (+5G).
  echo "[+] qemu-img missing, resizing with truncate -s $SIZE_ARG ..."
  if ! truncate -s "$SIZE_ARG" "$IMG_PATH"; then
    echo "[-] truncate failed. Install qemu-img:" >&2
    echo "    Debian/Ubuntu: sudo apt-get install -y qemu-utils" >&2
    echo "    Fedora:        sudo dnf install -y qemu-img" >&2
    echo "    Arch:          sudo pacman -S --needed qemu-img" >&2
    exit 1
  fi
fi

echo "[+] Image container successfully expanded."

# Step 2: Expand the filesystem.
if [ -z "$EXPAND" ]; then
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    EXPAND="yes"
  else
    read -rp "[?] Do you want to automatically expand the ext4 filesystem now? (y/n): " EXPAND_IN
    case "$EXPAND_IN" in [Yy]*) EXPAND="yes" ;; *) EXPAND="no" ;; esac
  fi
fi
if [ "$EXPAND" != "yes" ]; then
  echo "[*] Skipping filesystem expansion. Done!"
  echo "    Grow later from inside the guest with: resize2fs /dev/ubda"
  exit 0
fi

if ! command -v e2fsck >/dev/null 2>&1 || ! command -v resize2fs >/dev/null 2>&1; then
  echo "[!] e2fsprogs missing on host: container grown, filesystem NOT expanded." >&2
  echo "    Install e2fsprogs, then re-run: e2fsck -f -y \"$IMG_PATH\" && resize2fs \"$IMG_PATH\"" >&2
  echo "    Debian/Ubuntu: sudo apt-get install -y e2fsprogs" >&2
  echo "    Fedora:        sudo dnf install -y e2fsprogs" >&2
  echo "    Arch:          sudo pacman -S --needed e2fsprogs" >&2
  echo "    Or grow from inside the guest after boot: resize2fs /dev/ubda" >&2
  exit 1
fi

echo "[+] Checking filesystem integrity..."
e2fsck -f -y "$IMG_PATH"

echo "[+] Expanding filesystem to fill the new image size..."
resize2fs "$IMG_PATH"

echo "[+] Success! The rootfs image has been resized and the filesystem expanded."
if command -v qemu-img >/dev/null 2>&1; then
  qemu-img info "$IMG_PATH"
else
  du -h "$IMG_PATH"
fi
