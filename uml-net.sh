#!/bin/sh
set -e

DNS4="10.0.2.3"
DNS6="fec0::3"
TIMEOUT=30

find_iface() {
    for _i in $(seq 1 "$TIMEOUT"); do
        for dev in vec0 eth0; do
            if ip link show "$dev" >/dev/null 2>&1; then
                echo "$dev"
                return 0
            fi
        done
        sleep 1
    done
    return 1
}

IFACE=$(find_iface) || {
    echo "[uml-net] ERROR: no vec0 or eth0 after ${TIMEOUT}s" >&2
    exit 1
}

echo "[uml-net] Found interface: $IFACE"

ip link set "$IFACE" up

ip link add name vmbr0 type bridge 2>/dev/null || true
ip link set vmbr0 up

case "$IFACE" in
    eth0)
        ip link set eth0 master vmbr0 2>/dev/null || true
        ip addr add 10.0.2.1/24 dev vmbr0 2>/dev/null || true
        ip route replace default dev vmbr0

        echo "[uml-net] eth0 (SLIRP/SLIP) bridged to vmbr0: 10.0.2.1/24"
        ;;

    vec0)
        ip link set vec0 master vmbr0 2>/dev/null || true
        ip addr add 10.0.2.15/24 dev vmbr0 2>/dev/null || true
        ip route replace default via 10.0.2.2 dev vmbr0

        ip -6 addr add fec0::15/64 dev vmbr0 2>/dev/null || true
        ip -6 route replace default via fec0::2 dev vmbr0

        echo "[uml-net] vec0 (VECTOR/VDE) bridged to vmbr0: 10.0.2.15/24 + fec0::15/64"
        ;;
esac

echo "nameserver $DNS4" > /etc/resolv.conf
echo "nameserver $DNS6" >> /etc/resolv.conf

echo "[uml-net] DNS: $DNS4, $DNS6"

# ------------------------------------------------------------
# Wait indefinitely for Internet connectivity
# ------------------------------------------------------------

echo "[uml-net] Waiting for Internet connection..."

while true; do
    # Test raw IPv4 connectivity first.
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "[uml-net] Internet connection established (IPv4)"
        break
    fi

    # Also try IPv6 if available.
    if ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
        echo "[uml-net] Internet connection established (IPv6)"
        break
    fi

    echo "[uml-net] No Internet connection yet, retrying..."
    sleep 2
done

echo "[uml-net] Network initialization complete."
