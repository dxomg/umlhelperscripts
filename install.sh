#!/bin/bash
set -euo pipefail

echo "==> Downloading latest UML kernel, networking tools, and Debian image..."
wget -q --show-progress -O linux https://github.com/dxomg/uml-kernel-build/releases/latest/download/linux-uml
wget -q --show-progress https://github.com/dxomg/uml-kernel-build/releases/latest/download/slirp
wget -q --show-progress https://github.com/dxomg/uml-kernel-build/releases/latest/download/vde_plug


echo "==> Downloading helper scripts and configuration..."
wget -q --show-progress https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/startuml.sh
wget -q --show-progress https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/resizeimg.sh
wget -q --show-progress https://raw.githubusercontent.com/dxomg/umlhelperscripts/refs/heads/main/config.yaml

echo "==> Setting executable permissions..."
chmod +x linux slirp vde_plug startuml.sh resizeimg.sh

echo "==> Extracting and renaming rootfs image to base.img..."
unxz -f debian.img.xz
mv debian.img base.img

echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  - (Optional) Resize your image: ./resizeimg.sh base.img <SIZE>"
echo "  - Start the UML environment:   ./startuml.sh"
