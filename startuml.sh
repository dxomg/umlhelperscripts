#Based from LNQuang
#!/bin/sh
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$BASE/linux"
ROOTFS="$BASE/base.img"
CONFIG="$BASE/config.yaml"

yaml_val() {
    grep -E "^${1}:" "$CONFIG" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'
}

# --- arguments: [memory] [ncpus]  (both optional, config.yaml overrides) ---
# Env overrides: MEMORY, NCPUS, UML_MODE (seccomp|skas0|auto, default seccomp)
MEMORY="${1:-${MEMORY:-$(yaml_val memory)}}"
MEMORY="${MEMORY:-2G}"
NCPUS="${2:-${NCPUS:-$(yaml_val ncpus)}}"
NCPUS="${NCPUS:-1}"
UML_MODE="${UML_MODE:-seccomp}"
# coerce to a positive integer (ignore garbage from config/argv)
case "$NCPUS" in
    ''|*[!0-9]*) NCPUS=1 ;;
esac
[ "$NCPUS" -lt 1 ] && NCPUS=1

for f in "$KERNEL" "$ROOTFS" "$BASE/vde_plug"; do
    if [ ! -f "$f" ]; then echo "[ERROR] Missing: $f"; exit 1; fi
done
if [ ! -x "$BASE/vde_plug" ]; then chmod +x "$BASE/vde_plug"; fi
if [ ! -x "$KERNEL" ]; then chmod +x "$KERNEL"; fi

# --- detect whether the kernel was built with SMP ---
KERNEL_HAS_SMP=0
if command -v strings >/dev/null 2>&1 && strings "$KERNEL" 2>/dev/null | grep -q '^CONFIG_SMP=y'; then
    KERNEL_HAS_SMP=1
fi

# --- /dev/shm usable? (used to decide the skas0 PTRACE fallback) ---
SHM_TEST=$(mktemp /dev/shm/.uml_XXXXXX 2>/dev/null) || true
if [ -n "$SHM_TEST" ]; then
    printf '#!/bin/sh\nexit 0\n' > "$SHM_TEST"
    chmod +x "$SHM_TEST" 2>/dev/null
    if "$SHM_TEST" 2>/dev/null; then SHM_OK=1; else SHM_OK=0; fi
    rm -f "$SHM_TEST"
else
    SHM_OK=0
fi

# --- build the kernel cmdline ---
#
# SMP rules (upstream UML since v6.19):
#   * ncpus=N       how many vCPUs to bring online (<= NR_CPUS, default 1).
#   * seccomp=on    Default userspace mode (memfd physmem backport, avoids
#   *               the /dev/shm dependency). REQUIRED for ncpus>1.
#   * mode=skas0    forces PTRACE userspace (TT-less). INCOMPATIBLE with
#   *               SMP, only used on explicit UML_MODE=skas0 when /dev/shm
#   *               is slow. Set UML_MODE=auto for legacy auto behavior.
SMP_ARGS=""
SKAS_MODE=""

case "$UML_MODE" in
    seccomp)
        if [ "$KERNEL_HAS_SMP" -eq 1 ]; then
            SMP_ARGS="ncpus=$NCPUS seccomp=on"
        else
            SMP_ARGS="seccomp=on"
        fi
        ;;
    skas0)
        if [ "$SHM_OK" -eq 0 ]; then
            SKAS_MODE="mode=skas0"
        fi
        if [ "$KERNEL_HAS_SMP" -eq 1 ]; then
            SMP_ARGS="ncpus=$NCPUS"
        fi
        ;;
    auto)
        if [ "$KERNEL_HAS_SMP" -eq 1 ] && [ "$NCPUS" -gt 1 ]; then
            SMP_ARGS="ncpus=$NCPUS seccomp=on"
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

UML_TMPDIR="${TMP_DIR:-$BASE/.uml_tmp}"
mkdir -p "$UML_TMPDIR"
export TMP="$UML_TMPDIR" TMPDIR="$UML_TMPDIR" TEMP="$UML_TMPDIR"
# Best effort: allow exec on /dev/shm when privileged (harmless if denied).
mount -o remount,exec /dev/shm 2>/dev/null || true

export PATH="$BASE:$PATH"

echo "========================================"
echo "  UML Virtual Machine"
echo "----------------------------------------"
if [ "$KERNEL_HAS_SMP" -eq 1 ] && [ "$NCPUS" -gt 1 ]; then
    echo "  CPUs     : $NCPUS (SMP, seccomp userspace)"
elif [ "$KERNEL_HAS_SMP" -eq 1 ]; then
    echo "  CPUs     : 1 (SMP kernel, 1 vCPU)"
else
    echo "  CPUs     : 1 (UP kernel)"
fi
echo "  Memory   : $MEMORY"
echo "  Network  : VDE VECTOR + libslirp NAT"
if [ -n "$SKAS_MODE" ]; then echo "  Userspace: skas0 (slow /dev/shm fallback)"; else echo "  Userspace: seccomp"; fi
echo "  Config   : $CONFIG"
echo "----------------------------------------"
echo "  Login: root / root"
echo "========================================"
echo ""

cleanup() { if [ "$UML_TMPDIR" = "$BASE/.uml_tmp" ]; then rm -rf "$BASE/.uml_tmp" 2>/dev/null; fi; }
trap cleanup EXIT

exec "$KERNEL" \
    mem="$MEMORY" \
    $SKAS_MODE \
    $SMP_ARGS \
    ubd0="$ROOTFS" \
    root=/dev/ubda rw \
    init=/lib/systemd/systemd \
    "vec0:transport=vde,vnl=slirp://" \
    con0=fd:0,fd:1 \
    con=null
