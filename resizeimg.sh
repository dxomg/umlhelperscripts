#!/bin/bash

# Check for required tools (losetup removed)
for tool in qemu-img e2fsck resize2fs; do
  if ! command -v "$tool" &> /dev/null; then
    echo "[-] Required tool '$tool' is missing. Please install it first."
    exit 1
  fi
done

echo "=== QEMU Direct Rootfs Image Resizer ==="
read -p "Enter path to your .img file: " IMG_PATH

if [ ! -f "$IMG_PATH" ]; then
  echo "[-] Error: File '$IMG_PATH' not found."
  exit 1
fi

if [ ! -w "$IMG_PATH" ]; then
  echo "[-] Error: You do not have write permissions for '$IMG_PATH'."
  echo "    Try running with sudo, or change the file ownership."
  exit 1
fi

# Show current info
echo -e "\nCurrent image details:"
qemu-img info "$IMG_PATH"

echo -e "\nHow would you like to specify the new size?"
echo "1) Absolute size (e.g., 5G, 2048M)"
echo "2) Increment / Add space (e.g., +2G, +500M)"
read -p "Select option [1-2]: " SIZE_OPT

read -p "Enter the size value (e.g., 5G or +2G): " TARGET_SIZE

if [ "$SIZE_OPT" -eq 2 ]; then
  SIZE_ARG="+$TARGET_SIZE"
else
  SIZE_ARG="$TARGET_SIZE"
fi

# Backup prompt
read -p "[?] Do you want to create a backup copy before resizing? (y/n): " BACKUP
if [[ "$BACKUP" =~ ^[Yy]$ ]]; then
  BACKUP_PATH="${IMG_PATH}.bak"
  echo "[+] Creating backup at $BACKUP_PATH..."
  cp "$IMG_PATH" "$BACKUP_PATH"
  echo "[+] Backup complete."
fi

# Step 1: Resize the raw image container
echo "[+] Resizing image container with qemu-img..."
qemu-img resize -f raw "$IMG_PATH" "$SIZE_ARG"
if [ $? -ne 0 ]; then
  echo "[-] qemu-img resize failed."
  exit 1
fi

echo "[+] Image container successfully expanded."

# Step 2: Expand the filesystem directly on the file
read -p "[?] Do you want to automatically expand the ext4 filesystem now? (y/n): " EXPAND_FS
if [[ ! "$EXPAND_FS" =~ ^[Yy]$ ]]; then
  echo "[*] Skipping filesystem expansion. Done!"
  exit 0
fi

# Check and expand the filesystem directly on the image file
echo "[+] Checking filesystem integrity..."
e2fsck -f -y "$IMG_PATH"

echo "[+] Expanding filesystem to fill the new image size..."
resize2fs "$IMG_PATH"

echo "[+] Success! The rootfs image has been resized and the filesystem expanded."
qemu-img info "$IMG_PATH"
