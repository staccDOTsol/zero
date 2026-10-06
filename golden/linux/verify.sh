#!/usr/bin/env bash
# golden/linux/verify.sh -- verify a finished Zero Linux golden image before it is uploaded.
#   sudo golden/linux/verify.sh IMAGE TIER OUT_DIR [CATALOG]
#
# 1. Every model file of the tier is read back from the image (read-only loop mount, cold page cache)
#    and its size and sha256 are checked against models/catalog.json.
# 2. The image's FIRST boot, in QEMU/KVM with OVMF, on a copy-on-write overlay the size of the laptop's
#    NVMe (1 TB Pro, 2 TB Max/Ultra), the way an imaging team writes it: Secure Boot on for Pro/Max (as
#    those laptops ship), off for Ultra (NVIDIA modules). golden/linux/guest.sh (test only, on its own
#    read-only disk, started through a VM-only SMBIOS credential) checks: root grows to the drive, no
#    user baked in, every model present, the default model's sha256, the per-machine API key, the default
#    model served on 127.0.0.1:8080 and answering, the chat on 127.0.0.1:7860 answering through it, and
#    the zero-egress confinement (both services loopback-only, the OS online).
# The image file is never written. Exit 0 only if everything passed.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
IMG=$(readlink -f "${1:?image}"); TIER=${2:?tier}; OUT=$(mkdir -p "${3:?out dir}" && cd "$3" && pwd)
CATALOG=$(readlink -f "${4:-$REPO/models/catalog.json}")
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -w /dev/kvm ] || { echo "/dev/kvm is required" >&2; exit 1; }
case "$TIER" in pro) NVME=1000204886016; SB=1 ;; max) NVME=2000398934016; SB=1 ;; ultra) NVME=2000398934016; SB=0 ;;
  *) echo "tier pro|max|ultra" >&2; exit 2 ;; esac
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
MNT=$OUT/mnt LOOP=""
cleanup() { set +e; mountpoint -q "$MNT" && umount "$MNT"; [ -n "$LOOP" ] && losetup -d "$LOOP"; }
trap cleanup EXIT
RC=0

# ---- 1. sha256 of every model file in the image ------------------------------------------------------
mkdir -p "$MNT"
sync; echo 3 > /proc/sys/vm/drop_caches
LOOP=$(losetup -f --show -r -P "$IMG"); udevadm settle 2>/dev/null || sleep 2
ROOT=$(lsblk -lnpo NAME,PARTLABEL "$LOOP" | awk '$2=="zero-root"{print $1}')
[ -n "$ROOT" ] || ROOT=$(lsblk -lnpbo NAME,FSTYPE,SIZE "$LOOP" | awk '$2=="ext4"{print $3, $1}' | sort -n | tail -n1 | cut -d' ' -f2)
mount -o ro,noload "$ROOT" "$MNT"
say "model files in the image: re-reading and checking sha256 against the catalog"
python3 "$REPO/golden/lib/catalog.py" --catalog "$CATALOG" verify "$TIER" "$MNT/var/lib/lecore-plus/models" -j 8 | tee "$OUT/models-sha256.txt" || RC=1
umount "$MNT"; losetup -d "$LOOP"; LOOP=""

# ---- 2. first boot ---------------------------------------------------------------------------------------
SD=$OUT/golden-disk; rm -rf "$SD"; mkdir -p "$SD"
cp "$HERE/guest.sh" "$SD/"
golden_disk() { # SECUREBOOT(0|1): the test disk with guest.sh and what it must find
python3 - "$REPO/golden/lib/catalog.py" "$CATALOG" "$TIER" "$NVME" "$1" "$SD/expect.json" <<'PY'
import json, subprocess, sys
tool, cat, tier, nvme, sb, out = sys.argv[1:7]
s = json.loads(subprocess.check_output([sys.executable, tool, "--catalog", cat, "summary", tier]))
plan = subprocess.check_output([sys.executable, tool, "--catalog", cat, "plan", tier], text=True)
files = [dict(zip(("id", "repo", "path", "file", "bytes", "sha256", "speed"), l.split("\t"))) for l in plan.splitlines()]
for f in files:
    f["bytes"] = int(f["bytes"])
json.dump({"tier": tier, "disk_bytes": int(nvme), "secure_boot": sb == "1", "default": s["default"],
           "default_file": s["default_file"], "models": s["models"], "files": files}, open(out, "w"), indent=1)
PY
rm -f "$OUT/golden-disk.img"; mkfs.ext4 -q -L ZEROGOLD -d "$SD" "$OUT/golden-disk.img" 64M
}
UNIT=$(base64 -w0 <<'EOF'
[Unit]
Description=Zero golden image first-boot check - injected by the build through a VM credential, not part of the image
After=graphical.target lecore-chat.service lecore-llama.service nftables.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mkdir -p /run/zero-golden && mount -o ro LABEL=ZEROGOLD /run/zero-golden && exec /bin/bash /run/zero-golden/guest.sh'
TimeoutStartSec=infinity
StandardOutput=journal+console
EOF
)
DROPIN=$(printf '[Unit]\nWants=zero-golden-check.service\n' | base64 -w0)
OV=$OUT/first-boot.qcow2
LOG=$OUT/first-boot-serial.log; SOCK=$OUT/qmp.sock
HOSTMEM=$(free -g | awk '/Mem:/{print $2}')
boot() { # SMP MEM_G SECUREBOOT(0|1) -> 0 done, 1 failed, 2 the VM died before the check started
  local smp=$1 mem=$2 sb=$3 code machine extra=() rc=1 t0 pid
  rm -f "$OV" "$LOG" "$SOCK"
  golden_disk "$sb"
  # its own hardware identity, as a new laptop has (a stock QEMU VM looks the same everywhere)
  local uuid serial mac
  uuid=$(cat /proc/sys/kernel/random/uuid); serial=$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')
  mac="52:54:00:$(od -An -tx1 -N3 /dev/urandom | awk '{print $1":"$2":"$3}')"
  qemu-img create -q -f qcow2 -F raw -b "$IMG" "$OV" "$NVME"
  if [ "$sb" = 1 ]; then
    code=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd; cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$OUT/vars.fd"
    machine=q35,accel=kvm,smm=on; extra=(-global driver=cfi.pflash01,property=secure,value=on -global mch.extended-tseg-mbytes=64)
  else
    code=/usr/share/OVMF/OVMF_CODE_4M.fd; cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OUT/vars.fd"
    machine=q35,accel=kvm
  fi
  BOOTCFG="first boot: QEMU/KVM + OVMF, ${NVME}-byte NVMe, Secure Boot $([ "$sb" = 1 ] && echo on || echo off), $smp vCPU / $mem GiB, user-mode network"
  say "$BOOTCFG"
  qemu-system-x86_64 -name zero-golden-linux -machine "$machine" -cpu host -smp "$smp" -m "${mem}G" "${extra[@]}" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$code" -drive if=pflash,format=raw,unit=1,file="$OUT/vars.fd" \
    -drive file="$OV",if=none,id=d0,format=qcow2,cache=unsafe -device nvme,drive=d0,serial="ZT$serial" \
    -drive file="$OUT/golden-disk.img",if=virtio,format=raw,readonly=on \
    -uuid "$uuid" -smbios "type=1,manufacturer=Zero,product=Zero golden test VM,serial=ZEROTEST-$serial,uuid=$uuid" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac="$mac" -device virtio-rng-pci -device virtio-vga -display none \
    -serial file:"$LOG" -qmp unix:"$SOCK",server=on,wait=off \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.zero-golden-check.service=$UNIT" \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.graphical.target=$DROPIN" \
    2> "$OUT/qemu-stderr.log" &
  pid=$!; t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if grep -aq ZERO_GOLDEN_DONE "$LOG" 2>/dev/null; then sleep 40; kill -0 "$pid" 2>/dev/null && kill "$pid"; rc=0; break; fi
    if [ $((SECONDS - t0)) -ge 900 ] && ! grep -aq ZERO_GOLDEN_STARTED "$LOG" 2>/dev/null; then say "the check never started (15 min)"; kill "$pid"; break; fi
    if [ $((SECONDS - t0)) -ge 7200 ]; then say "TIMEOUT"; kill "$pid"; break; fi
    sleep 5
  done
  wait "$pid" 2>/dev/null || true
  cat "$OUT/qemu-stderr.log" 2>/dev/null
  if [ "$rc" != 0 ] && ! grep -aq ZERO_GOLDEN_STARTED "$LOG" 2>/dev/null && [ $((SECONDS - t0)) -lt 300 ]; then
    say "the VM stopped after $((SECONDS - t0)) s, before the check started; serial tail:"
    tail -c 2000 "$LOG" | tr -d '\r' | sed 's/\x1b\[[0-9;=]*[A-Za-z]//g' | tail -n 15
    rc=2
  fi
  return "$rc"
}
# As the laptop ships first. No -no-reboot: OVMF with SMM (Secure Boot) resets once on the first boot
# of a large-memory VM, and with -no-reboot QEMU would exit there. If the VM still dies before the
# check starts: a smaller VM with Secure Boot, then Secure Boot off. The report says which one ran.
SMP=$(nproc); [ "$SMP" -gt 32 ] && SMP=32
MEM=$(( HOSTMEM * 6 / 10 )); [ "$MEM" -gt 96 ] && MEM=96
BRC=2
boot "$SMP" "$MEM" "$SB" && BRC=0 || BRC=$?
if [ "$BRC" = 2 ] && [ "$SB" = 1 ]; then boot 16 64 1 && BRC=0 || BRC=$?; fi
if [ "$BRC" = 2 ]; then say "retrying with Secure Boot off"; boot "$SMP" "$MEM" 0 && BRC=0 || BRC=$?; fi
rm -f "$OV" "$OUT/vars.fd" "$SOCK"
sed -n '/ZERO GOLDEN IMAGE FIRST BOOT/,$p' "$LOG" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' > "$OUT/first-boot.txt"
cat "$OUT/first-boot.txt"
{ grep -aE '^(VERIFY OK|VERIFY FAILED)' "$OUT/models-sha256.txt"; echo "${BOOTCFG:-first boot: not run}"; grep -aE 'GOLDEN (PASS|FAIL|WARN)|ZERO_GOLDEN_RESULT' "$OUT/first-boot.txt"; } > "$OUT/verify-report.txt" || true
grep -q 'ZERO_GOLDEN_RESULT: PASS' "$OUT/first-boot.txt" || RC=1
say "verification: $([ "$RC" = 0 ] && echo PASS || echo FAIL)"
exit "$RC"
