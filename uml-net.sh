#!/bin/sh
# uml-net.sh - guest-side network init. Runs INSIDE the UML guest.
# Same behaviour on Pterodactyl and standard hosts; arch-independent.
#
# Env overrides (all optional, defaults = classic slirp/VDE layout):
#   UML_IPV4=1|0        enable IPv4 (default 1)
#   UML_IPV6=1|0        enable IPv6 (default 1)
#   UML_IP4_ADDR        default 10.0.2.15/24
#   UML_IP4_GW          default 10.0.2.2
#   UML_DNS4            default 10.0.2.3
#   UML_IP6_ADDR        default fec0::15/64
#   UML_IP6_GW          default fec0::2
#   UML_DNS6            default fec0::3
#   UML_NET_WAIT=1|0    wait for ping before exiting (default 1, Pterodactyl-safe)
#   UML_NET_TIMEOUT     iface wait seconds (default 30)
set -e

DNS4="${UML_DNS4:-${DNS4:-10.0.2.3}}"
DNS6="${UML_DNS6:-${DNS6:-fec0::3}}"
TIMEOUT="${UML_NET_TIMEOUT:-30}"
DO_V4="${UML_IPV4:-1}"
DO_V6="${UML_IPV6:-1}"
IP4_ADDR="${UML_IP4_ADDR:-10.0.2.15/24}"
IP4_GW="${UML_IP4_GW:-10.0.2.2}"
IP6_ADDR="${UML_IP6_ADDR:-fec0::15/64}"
IP6_GW="${UML_IP6_GW:-fec0::2}"
NET_WAIT="${UML_NET_WAIT:-1}"

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
        if [ "$DO_V4" = "1" ]; then
            # eth0 SLIRP path uses .1/24 historically; honour override if set.
            if [ -n "${UML_IP4_ADDR:-}" ]; then
                ip addr add "$IP4_ADDR" dev vmbr0 2>/dev/null || true
            else
                ip addr add 10.0.2.1/24 dev vmbr0 2>/dev/null || true
            fi
            ip route replace default dev vmbr0
            echo "[uml-net] eth0 (SLIRP/SLIP) bridged to vmbr0"
        fi
        ;;

    vec0)
        ip link set vec0 master vmbr0 2>/dev/null || true
        if [ "$DO_V4" = "1" ]; then
            ip addr add "$IP4_ADDR" dev vmbr0 2>/dev/null || true
            ip route replace default via "$IP4_GW" dev vmbr0
        fi
        if [ "$DO_V6" = "1" ]; then
            ip -6 addr add "$IP6_ADDR" dev vmbr0 2>/dev/null || true
            ip -6 route replace default via "$IP6_GW" dev vmbr0
        fi

        echo "[uml-net] vec0 (VECTOR/VDE) bridged to vmbr0: v4=$DO_V4 v6=$DO_V6"
        ;;
esac

# resolv.conf honours enabled families (keep at least one nameserver).
: > /etc/resolv.conf
if [ "$DO_V4" = "1" ]; then echo "nameserver $DNS4" >> /etc/resolv.conf; fi
if [ "$DO_V6" = "1" ]; then echo "nameserver $DNS6" >> /etc/resolv.conf; fi

echo "[uml-net] DNS: $(tr '\n' ' ' < /etc/resolv.conf)"

if [ "$NET_WAIT" != "1" ]; then
  echo "[uml-net] Network initialization complete (wait skipped)."
  exit 0
fi

# ------------------------------------------------------------
# Wait indefinitely for Internet connectivity
# ------------------------------------------------------------

echo "[uml-net] Waiting for Internet connection..."

while true; do
    # Test raw IPv4 connectivity first.
    if [ "$DO_V4" = "1" ] && ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "[uml-net] Internet connection established (IPv4)"
        break
    fi

    # Also try IPv6 if available.
    if [ "$DO_V6" = "1" ] && ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
        echo "[uml-net] Internet connection established (IPv6)"
        break
    fi

    echo "[uml-net] No Internet connection yet, retrying..."
    sleep 2
done

echo "[uml-net] Network initialization complete."
