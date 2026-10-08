#!/usr/bin/env bash
# golden/windows/build.sh -- build, verify and (optionally) upload ONE Zero Windows golden image.
#
# A golden image is a raw GPT disk image of a generalized (sysprep /generalize /oobe) Windows 11 Pro
# install made from the Zero Windows ISO of the laptop model, with every catalog model of the tier in
# C:\ProgramData\leCore+\models and the tier default in model.txt. An imaging team writes it straight
# onto the laptop's NVMe; on the first boot Windows specializes (new SID, drivers, per-machine API key),
# C: grows to the end of the disk, the owner creates the account at OOBE, and the default model is
# already being served on 127.0.0.1:8080 with the chat on 127.0.0.1:7860.
#
# Runs as root on a Linux host with KVM (the zero-golden-32 runner). Steps:
#   1. models   every file of the tier from Hugging Face (aria2c, parallel), sha256-checked   [background]
#   2. iso      the Zero ISO -> a build ISO: same files, UEFI no-prompt boot, the build answer file
#   3. install  QEMU/KVM: Windows Setup (wipes the VM's only disk), the ISO's specialize pass (Zero
#               stack), audit mode -> audit.ps1 -> sysprep /generalize /oobe /shutdown
#   4. models   into the image's NTFS (offline), model.txt + models.json, then every file re-read from
#               the image and sha256-checked against the catalog
#   5. verify   a copy-on-write overlay the size of the laptop's NVMe, booted for its first boot;
#               verify.ps1 (test only) checks the result (see that file)
#   6. upload   raw sha256 + zstd stream to the object store (golden/lib/store.sh: any S3-compatible
#               service, STORE_BUCKET / S3_ENDPOINT_URL), PREFIX/zero-<tier>-windows.img.zst + manifest
#
#   build.sh --tier pro|max|ultra --iso ZERO.iso --work DIR [--laptop TARGET] [--bucket B --prefix P]
#            [--base-tag T] [--no-upload] [--keep]
#
# --laptop names the windows/drivers.json target the ISO was built for. Without it the tier's default
# laptop is assumed (pro/max: hp-zbook-ultra-g1a, ultra: lenovo-p16-gen3) and the image is
# zero-<tier>-windows.img.zst, as before. Another target that lists the tier (asus-rog-flow-z13-gz302ea)
# gets zero-<tier>-windows-<image_name>.img.zst (+ .manifest.json, .verify.txt), so the default laptop's
# image and the other laptop's image of the same tier can sit next to each other in the bucket.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
CATALOG=$REPO/models/catalog.json
TIER="" ISO="" WORK="" PREFIX="" BASE_TAG="" UPLOAD=1 KEEP=0 LAPTOP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER=$2; shift 2 ;;
    --laptop) LAPTOP=$2; shift 2 ;;
    --iso) ISO=$(readlink -f "$2"); shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --bucket) export STORE_BUCKET=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    --base-tag) BASE_TAG=$2; shift 2 ;;
    --catalog) CATALOG=$(readlink -f "$2"); shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$TIER" in pro|max) DEFAULT_TARGET=hp-zbook-ultra-g1a ;;
                 ultra) DEFAULT_TARGET=lenovo-p16-gen3 ;;
                 *) echo "--tier pro|max|ultra" >&2; exit 2 ;; esac
TARGET=${LAPTOP:-$DEFAULT_TARGET}
# The laptop must be a windows/drivers.json target that lists the tier. VENDOR is what verify.ps1 expects
# in the display driver's provider (from the target's GPU PCI vendor id); IMAGE_NAME names the image of a
# laptop other than the tier's default.
CFG=$(python3 - "$REPO/windows/drivers.json" "$TARGET" "$TIER" 2>&1 <<'PY'
import json, re, sys
path, target, tier = sys.argv[1:4]
targets = json.load(open(path, encoding="utf-8-sig"))["targets"]
t = targets.get(target)
if t is None:
    sys.exit("laptop %s is not a target in %s (targets: %s)" % (target, path, ", ".join(targets)))
if tier not in t["tiers"]:
    sys.exit("laptop %s is not built for tier %s (its tiers: %s)" % (target, tier, ", ".join(t["tiers"])))
vendors = {re.match(r"VEN_([0-9A-Fa-f]{4})", i).group(1).upper() for i in t["gpu_device_ids"]}
regex = {"1002": "Advanced Micro Devices|AMD", "10DE": "NVIDIA"}
if len(vendors) != 1 or not regex.get(next(iter(vendors))):
    sys.exit("laptop %s: unknown GPU vendor in gpu_device_ids %s" % (target, t["gpu_device_ids"]))
name = t.get("image_name") or target
if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
    sys.exit("laptop %s: image_name %r must be lowercase letters, digits and dashes" % (target, name))
print(regex[vendors.pop()])
print(name)
PY
) || { echo "windows/drivers.json: $CFG" >&2; exit 2; }
VENDOR=$(echo "$CFG" | sed -n 1p); IMAGE_NAME=$(echo "$CFG" | sed -n 2p)
NAME=zero-$TIER-windows
[ "$TARGET" = "$DEFAULT_TARGET" ] || NAME=zero-$TIER-windows-$IMAGE_NAME
[ -f "$ISO" ] && [ -n "$WORK" ] || { echo "--iso and --work are required" >&2; exit 2; }
[ "$UPLOAD" = 0 ] || [ -n "${STORE_BUCKET:-}" ] || { echo "STORE_BUCKET / --bucket (or --no-upload)" >&2; exit 2; }
# shellcheck source=../lib/store.sh
[ "$UPLOAD" = 0 ] || . "$REPO/golden/lib/store.sh"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
LOGS=$WORK/logs; CACHE=$WORK/model-cache; MNT=$WORK/mnt
mkdir -p "$LOGS" "$CACHE" "$MNT"
DISK=$WORK/$NAME.img
VARS=$WORK/ovmf-vars.fd
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
# the laptops' drives: Pro 1 TB, Max/Ultra 2 TB (the usual exact byte counts of those NVMe sizes)
case "$TIER" in pro) NVME_BYTES=1000204886016 ;; *) NVME_BYTES=2000398934016 ;; esac
# VM sizes and the Windows headroom; the CI smoke test (small runner, tiny test model) lowers them
NVME_BYTES=${GOLDEN_NVME_BYTES:-$NVME_BYTES}
OS_GIB=${GOLDEN_OS_GIB:-64}
SETUP_SMP=${GOLDEN_SETUP_SMP:-16} SETUP_MEM=${GOLDEN_SETUP_MEM:-32}
VERIFY_SMP=${GOLDEN_VERIFY_SMP:-32} VERIFY_MEM=${GOLDEN_VERIFY_MEM:-96}
TS=${GOLDEN_TIME_SCALE:-1}   # multiplies every VM timeout
T0=$SECONDS
say() { printf '[%s +%dm] %s\n' "$(date -u +%H:%M:%S)" $(((SECONDS - T0) / 60)) "$*"; }
die() { say "FAILED: $*"; exit 1; }
LOOP=""
cleanup() {
  set +e
  mountpoint -q "$MNT" && umount "$MNT"
  [ -n "$LOOP" ] && losetup -d "$LOOP"
  [ -e /dev/nbd0p1 ] && qemu-nbd -d /dev/nbd0 >/dev/null
  pkill -f "zero-win-$NAME" 2>/dev/null
  [ -n "${DL_PID:-}" ] && kill "$DL_PID" 2>/dev/null
}
trap cleanup EXIT

for t in qemu-system-x86_64 qemu-img qemu-nbd aria2c 7z xorriso ntfs-3g mkfs.vfat sgdisk losetup zstd python3 sha256sum; do
  command -v "$t" >/dev/null || die "missing tool $t"
done
[ -w /dev/kvm ] || die "/dev/kvm is not available: the Windows install and the boot test need KVM"
SUMMARY=$(python3 "$REPO/golden/lib/catalog.py" --catalog "$CATALOG" summary "$TIER")
MODEL_BYTES=$(echo "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')
# disk = the tier's models + 64 GiB for Windows, the Zero stack and headroom, rounded up to a GiB
GIB=1073741824
DISK_BYTES=$(( (MODEL_BYTES + OS_GIB * GIB + GIB - 1) / GIB * GIB ))
[ "$DISK_BYTES" -lt "$NVME_BYTES" ] || die "image ($DISK_BYTES) would not fit the ${NVME_BYTES}-byte drive"
say "tier $TIER ($TARGET): $(echo "$SUMMARY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%d models, %d files, %.1f GB, default %s" % (len(d["models"]), d["files"], d["bytes"]/1e9, d["default"]))')"
say "image $DISK_BYTES bytes ($((DISK_BYTES / GIB)) GiB) for a $NVME_BYTES-byte NVMe; KVM ok; $(nproc) CPUs, $(free -g | awk '/Mem:/{print $2}') GiB RAM"
df -h "$WORK" | tail -n 1

# ---------------------------------------------------------------------------------------------------
# 1. models (background): aria2c, several files at once, many connections each, sha256 per file
python3 "$REPO/golden/lib/catalog.py" --catalog "$CATALOG" aria2 "$TIER" "$CACHE" > "$WORK/aria2.list"
(
  rc=1
  for attempt in 1 2 3; do
    aria2c -i "$WORK/aria2.list" -j 6 -x 16 -s 16 -k 64M --file-allocation=falloc -c \
      --auto-file-renaming=false --allow-overwrite=true --check-integrity=true \
      --max-tries=20 --retry-wait=10 --connect-timeout=30 --timeout=120 \
      --summary-interval=120 --console-log-level=warn --download-result=full \
      && { rc=0; break; }
    echo "aria2c attempt $attempt failed; resuming"
    sleep 20
  done
  echo "$rc" > "$CACHE/.aria2-exit"
) > "$LOGS/download.log" 2>&1 &
DL_PID=$!
say "model download started in the background (pid $DL_PID, log logs/download.log)"

# ---------------------------------------------------------------------------------------------------
# 2. answer files and install media
say "unpacking $(basename "$ISO")"
rm -rf "$WORK/iso"; mkdir -p "$WORK/iso"
7z x -y -bso0 -bsp0 -o"$WORK/iso" "$ISO" >/dev/null
[ -f "$WORK/iso/autounattend.xml" ] && compgen -G "$WORK/iso/sources/install.*" >/dev/null || die "ISO does not look like a Zero Windows ISO"
cp "$WORK/iso/autounattend.xml" "$WORK/iso-autounattend.xml"
cat "$WORK/iso/zero-image.json" > "$WORK/zero-image.json" 2>/dev/null || echo '{}' > "$WORK/zero-image.json"
python3 "$HERE/unattend.py" build "$WORK/iso-autounattend.xml" "$WORK/build-autounattend.xml"
python3 "$HERE/unattend.py" shipped "$WORK/iso-autounattend.xml" "$WORK/shipped-unattend.xml"
# media A: the ISO's own files as an ISO 9660 + Joliet DVD with the build answer file at its root and
# the no-prompt UEFI boot image (no "Press any key to boot from CD")
cp "$WORK/build-autounattend.xml" "$WORK/iso/autounattend.xml"
NOPROMPT=1
EFI_IMG=$(cd "$WORK/iso" && find . -ipath './efi/microsoft/boot/efisys_noprompt.bin' | head -n1)
if [ -z "$EFI_IMG" ]; then EFI_IMG=$(cd "$WORK/iso" && find . -ipath './efi/microsoft/boot/efisys.bin' | head -n1); NOPROMPT=0; fi
[ -n "$EFI_IMG" ] || die "no UEFI El Torito image (efi/microsoft/boot/efisys*.bin) in the ISO"
EFI_IMG=${EFI_IMG#./}
xorriso -as mkisofs -iso-level 3 -J -joliet-long -V ZERO_GOLDEN -o "$WORK/build.iso" \
  -e "$EFI_IMG" -no-emul-boot "$WORK/iso" 2>&1 | tail -n 2
rm -rf "$WORK/iso"
say "media A: build ISO $(du -h "$WORK/build.iso" | cut -f1) (UEFI boot image $EFI_IMG)"
# media B (fallback): the original ISO untouched, the build answer file on a small USB stick (Windows
# Setup takes an answer file on removable read/write media before the one on the DVD)
rm -f "$WORK/answer.img"; mkfs.vfat -n ZEROANSWER -C "$WORK/answer.img" 32768 >/dev/null
mkdir -p "$WORK/answer-mnt"; mount -o loop "$WORK/answer.img" "$WORK/answer-mnt"
cp "$WORK/build-autounattend.xml" "$WORK/answer-mnt/Autounattend.xml"; umount "$WORK/answer-mnt"

# ---------------------------------------------------------------------------------------------------
# QEMU
qmp() { # socket command [json-args]
  python3 - "$@" <<'PY'
import json, socket, sys
sock, cmd = sys.argv[1], sys.argv[2]
args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
f = s.makefile("rw"); f.readline()
def x(c, a=None):
    f.write(json.dumps({"execute": c, **({"arguments": a} if a else {})}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            return r
x("qmp_capabilities")
print(json.dumps(x(cmd, args)))
PY
}
# Every test VM gets its own random hardware identity (SMBIOS system UUID and serials, NIC MAC, disk
# serial). A stock QEMU VM has the same identity everywhere, and Windows OOBE matched one to somebody
# else's Windows Autopilot registration ("Let's set things up for your work or school").
rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n' | tr a-f A-F; }
new_identity() { # sets VM_UUID VM_SERIAL VM_MAC VM_DISKSERIAL
  VM_UUID=$(cat /proc/sys/kernel/random/uuid); VM_SERIAL="ZEROTEST-$(rand_hex 6)"
  VM_MAC="52:54:00:$(od -An -tx1 -N3 /dev/urandom | awk '{print $1":"$2":"$3}')"; VM_DISKSERIAL="ZT$(rand_hex 8)"
}
# vm NAME TIMEOUT_S DONE_REGEX SMP MEM_G -- extra qemu args
# (VM_START_RE / VM_START_TMO: give up early if the serial log never shows VM_START_RE)
vm() {
  local name=$1 tmo=$2 done_re=$3 smp=$4 mem=$5; shift 6
  local log=$LOGS/$name-serial.log sock=$WORK/$name.qmp
  rm -f "$log" "$sock"; mkdir -p "$LOGS/shots"
  say "VM $name: start (timeout ${tmo}s)"
  qemu-system-x86_64 -name "zero-win-$NAME-$name" -machine "${VM_MACHINE:-q35,accel=kvm}" ${VM_EXTRA:-} \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer,hv_frequencies \
    -smp "$smp" -m "${mem}G" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${VM_CODE:-$OVMF_CODE}" \
    -drive if=pflash,format=raw,unit=1,file="$VARS" \
    -rtc base=utc -vga std -display none -serial file:"$log" -qmp unix:"$sock",server=on,wait=off \
    -uuid "$VM_UUID" -smbios "type=1,manufacturer=Zero,product=Zero golden test VM,serial=$VM_SERIAL,uuid=$VM_UUID" \
    -smbios "type=2,manufacturer=Zero,serial=$VM_SERIAL" -smbios "type=3,manufacturer=Zero,serial=$VM_SERIAL" \
    -device qemu-xhci -device usb-tablet "$@" &
  local pid=$! t0=$SECONDS next=300 shot=0 t
  while kill -0 "$pid" 2>/dev/null; do
    t=$((SECONDS - t0))
    if [ -n "$done_re" ] && grep -aqE "$done_re" "$log" 2>/dev/null; then
      sleep 20; kill -0 "$pid" 2>/dev/null && { qmp "$sock" screendump "{\"filename\": \"$LOGS/shots/$name-end.png\", \"format\": \"png\"}" >/dev/null 2>&1; sleep 60; }
      kill -0 "$pid" 2>/dev/null && { qmp "$sock" quit >/dev/null 2>&1 || kill "$pid"; }
      break
    fi
    if [ -n "${VM_START_RE:-}" ] && [ "$t" -ge "${VM_START_TMO:-1800}" ] && ! grep -aqE "$VM_START_RE" "$log" 2>/dev/null; then
      say "VM $name: '$VM_START_RE' not seen after ${t}s"; tmo=$t
    fi
    if [ "$t" -ge "$tmo" ]; then
      say "VM $name: TIMEOUT after ${t}s"
      qmp "$sock" screendump "{\"filename\": \"$LOGS/shots/$name-timeout.png\", \"format\": \"png\"}" >/dev/null 2>&1 || true
      qmp "$sock" quit >/dev/null 2>&1 || kill "$pid"; wait "$pid" 2>/dev/null; return 124
    fi
    if [ "$t" -ge "$next" ]; then
      next=$((next + 300)); shot=$((shot + 1))
      qmp "$sock" screendump "{\"filename\": \"$LOGS/shots/$name-$(printf %03d $shot).png\", \"format\": \"png\"}" >/dev/null 2>&1 || true
      say "  VM $name: ${t}s, serial $(wc -l < "$log" 2>/dev/null || echo 0) lines; downloads: $(du -sh "$CACHE" 2>/dev/null | cut -f1)"
    fi
    sleep 3
  done
  wait "$pid" 2>/dev/null || true
  say "VM $name: stopped after $((SECONDS - t0))s"
  return 0
}
press_keys() { # in case the CD boot loader asks "Press any key to boot from CD"
  local sock=$1 i
  for i in $(seq 1 30); do qmp "$sock" send-key '{"keys":[{"type":"qcode","data":"ret"}]}' >/dev/null 2>&1 || true; sleep 1; done
}
ntfs_part() { # print the Windows (largest NTFS) partition of the loop device
  lsblk -lnpbo NAME,FSTYPE,SIZE "$1" | awk '$2=="ntfs"{print $3, $1}' | sort -n | tail -n 1 | awk '{print $2}'
}
attach() { LOOP=$(losetup -f --show -P "$DISK"); udevadm settle 2>/dev/null || sleep 2; WINPART=$(ntfs_part "$LOOP"); }
detach() { sync; mountpoint -q "$MNT" && umount "$MNT"; [ -n "$LOOP" ] && losetup -d "$LOOP"; LOOP=""; }

# ---------------------------------------------------------------------------------------------------
# 3. Windows Setup -> audit mode -> sysprep, in a VM whose only disk is the image
new_identity   # the build VM's identity (the image is generalized afterwards anyway)
DISKDEV=(-drive if=none,id=d0,file="$DISK",format=raw,cache=unsafe,discard=unmap,detect-zeroes=unmap -device nvme,drive=d0,serial="$VM_DISKSERIAL",bootindex=1)
setup_pe() { # A|B: Windows Setup's windowsPE pass (partitions the disk, applies Windows, reboots)
  local m=$1 media
  rm -f "$DISK"; truncate -s "$DISK_BYTES" "$DISK"; cp "$OVMF_VARS" "$VARS"
  if [ "$m" = A ]; then
    media=(-drive if=none,id=cd0,file="$WORK/build.iso",format=raw,media=cdrom,readonly=on -device ide-cd,drive=cd0,bus=ide.0,bootindex=0)
    [ "$NOPROMPT" = 1 ] || { sleep 3; press_keys "$WORK/setup-1$m.qmp"; } &
  else
    media=(-drive if=none,id=cd0,file="$ISO",format=raw,media=cdrom,readonly=on -device ide-cd,drive=cd0,bus=ide.0,bootindex=0
           -drive if=none,id=ans,file="$WORK/answer.img",format=raw -device usb-storage,drive=ans,removable=on)
    { sleep 3; press_keys "$WORK/setup-1$m.qmp"; } &
  fi
  vm "setup-1$m" $((1800 * TS)) "" "$SETUP_SMP" "$SETUP_MEM" -- "${DISKDEV[@]}" "${media[@]}" -nic none -no-reboot || return 1
  sgdisk -p "$DISK" | tail -n 5
  attach
  if [ -z "$WINPART" ] || ! ntfs-3g -o ro "$WINPART" "$MNT" 2>/dev/null; then detach; return 1; fi
  if [ ! -f "$MNT/Windows/System32/config/SYSTEM" ]; then detach; return 1; fi
  detach
}
setup_pe A || { say "media A did not install Windows; trying media B (original ISO + answer-file stick)"; setup_pe B; } \
  || die "Windows Setup (windowsPE pass) did not apply Windows (see logs/shots)"
rm -f "$WORK/build.iso" "$WORK/answer.img"
attach
ntfs-3g "$WINPART" "$MNT"
G=$MNT/Windows/Setup/Scripts/zero-golden
mkdir -p "$G"
cp "$HERE/audit.ps1" "$HERE/firstboot.ps1" "$WORK/shipped-unattend.xml" "$G/"
say "Windows applied ($(df -h "$MNT" | awk 'NR==2{print $3}') used); golden scripts in C:\\Windows\\Setup\\Scripts\\zero-golden"
detach

for n in 2 3 4 5 6; do
  vm "setup-$n" $((2700 * TS)) "" "$SETUP_SMP" "$SETUP_MEM" -- "${DISKDEV[@]}" -nic none -no-reboot || die "VM setup-$n timed out"
  grep -a 'zero-golden audit' "$LOGS/setup-$n-serial.log" 2>/dev/null | tr -d '\r' || true
  grep -aq 'ZERO_AUDIT_FAIL' "$LOGS/setup-$n-serial.log" && die "audit mode check failed (see above)"
  grep -aq 'ZERO_SYSPREP_RUN' "$LOGS/setup-$n-serial.log" && break
done
attach
ntfs-3g -o ro "$WINPART" "$MNT"
cp "$MNT/Windows/Setup/Scripts/zero-golden/audit.log" "$LOGS/" 2>/dev/null || true
cp "$MNT/Windows/System32/Sysprep/Panther/setupact.log" "$LOGS/sysprep-setupact.log" 2>/dev/null || true
cp "$MNT/Windows/Setup/Scripts/lecore-plus-specialize.log" "$LOGS/" 2>/dev/null || true
[ -f "$MNT/Windows/System32/Sysprep/Sysprep_succeeded.tag" ] || die "sysprep did not succeed (logs/sysprep-setupact.log, logs/audit.log)"
say "sysprep /generalize /oobe succeeded"
detach

# ---------------------------------------------------------------------------------------------------
# 4. models into the image
say "waiting for the model download"
while [ ! -f "$CACHE/.aria2-exit" ]; do sleep 30; done
[ "$(cat "$CACHE/.aria2-exit")" = 0 ] || { tail -n 60 "$LOGS/download.log"; die "model download failed"; }
DL_PID=""
grep -aE 'OK|ERR|Download Results|gid' "$LOGS/download.log" | tail -n 40 || true
say "all model files downloaded and sha256-checked by aria2c: $(du -sh "$CACHE" | cut -f1)"

attach
DRIVER=ntfs-3g
if modprobe ntfs3 2>/dev/null && mount -t ntfs3 -o noatime "$WINPART" "$MNT" 2>/dev/null; then DRIVER=ntfs3
else ntfs-3g -o big_writes,noatime "$WINPART" "$MNT"; fi
say "Windows volume mounted read-write with $DRIVER"
rm -f "$MNT/pagefile.sys" "$MNT/swapfile.sys" "$MNT/hiberfil.sys"
DST=$MNT/ProgramData/leCore+/models
[ -d "$MNT/ProgramData/leCore+" ] || die "the image has no C:\\ProgramData\\leCore+ (stack not installed?)"
mkdir -p "$DST"
python3 "$REPO/golden/lib/catalog.py" --catalog "$CATALOG" plan "$TIER" | while IFS=$'\t' read -r _ _ _ name bytes _ _; do
  [ -f "$CACHE/$name" ] || die "$name is not in the download cache"
  t1=$SECONDS
  cp "$CACHE/$name" "$DST/$name.zero-tmp" && mv -f "$DST/$name.zero-tmp" "$DST/$name"
  rm -f "$CACHE/$name"
  printf '  %-60s %7.2f GB  %4ds\n' "$name" "$(awk -v b="$bytes" 'BEGIN{print b/1e9}')" $((SECONDS - t1))
done
python3 "$REPO/golden/lib/catalog.py" --catalog "$CATALOG" windows-inventory "$TIER" "$MNT/ProgramData/leCore+"
python3 - "$MNT/ProgramData/leCore+/golden.json" "$TIER" "$SUMMARY" "${BASE_TAG:-}" "${GITHUB_SHA:-}" "$DISK_BYTES" <<'PY'
import json, sys
path, tier, summary, tag, sha, disk = sys.argv[1:7]
g = json.load(open(path, encoding="utf-8-sig"))
s = json.loads(summary)
g.update({"tier": tier, "catalog_updated": s["catalog_updated"], "models": s["models"], "default": s["default"],
          "model_bytes": s["bytes"], "image_bytes": int(disk), "base_release": tag, "golden_commit": sha})
open(path, "w", encoding="utf-8").write(json.dumps(g, indent=2))
PY
df -h "$MNT" | tail -n 1
detach
sync; echo 3 > /proc/sys/vm/drop_caches
attach
ntfs-3g -o ro "$WINPART" "$MNT"
say "re-reading every model file from the image (ntfs-3g, read-only, cold cache) and checking sha256"
if ! python3 "$REPO/golden/lib/catalog.py" --catalog "$CATALOG" verify "$TIER" "$MNT/ProgramData/leCore+/models" -j 8 | tee "$LOGS/models-sha256.txt"; then
  die "model files in the image do not match the catalog"
fi
cat "$MNT/ProgramData/leCore+/model.txt"
detach

# ---------------------------------------------------------------------------------------------------
# 5. first-boot verification on a throwaway overlay the size of the laptop's NVMe
VERIFY=PASS
OV=$WORK/verify.qcow2
VS=$WORK/verify-stage; rm -rf "$VS"; mkdir -p "$VS/zero-verify"
cp "$HERE/verify.ps1" "$VS/zero-verify/"
python3 - "$REPO/golden/lib/catalog.py" "$CATALOG" "$TIER" "$TARGET" "$VENDOR" "$NVME_BYTES" "$DISK_BYTES" "$VS/zero-verify/expect.json" <<'PY'
import json, subprocess, sys
tool, cat, tier, target, vendor, nvme, img, out = sys.argv[1:9]
s = json.loads(subprocess.check_output([sys.executable, tool, "--catalog", cat, "summary", tier]))
plan = subprocess.check_output([sys.executable, tool, "--catalog", cat, "plan", tier], text=True)
files = [dict(zip(("id", "repo", "path", "file", "bytes", "sha256", "speed"), l.split("\t"))) for l in plan.splitlines()]
for f in files:
    f["bytes"] = int(f["bytes"])
json.dump({"tier": tier, "target": target, "display_vendor": vendor, "disk_bytes": int(nvme), "image_bytes": int(img),
           "default": s["default"], "default_file": s["default_file"], "models": s["models"], "files": files},
          open(out, "w"), indent=1)
PY
# The test hook, in the overlay only: one line at the hook point of the image's own first-boot script,
# which the \Zero\Zero golden first boot task runs at startup (during OOBE). It starts verify.ps1 as a
# separate process (WMI Win32_Process.Create, so it is not part of the task's job object).
FB="Program Files/leCore+/golden/firstboot.ps1"
attach; ntfs-3g -o ro "$WINPART" "$MNT"
cp "$MNT/$FB" "$VS/firstboot.ps1"
detach
python3 - "$VS/firstboot.ps1" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8-sig").read()
mark = "# (golden test hook point: the build's throwaway verification overlay adds a line here)"
if mark not in t:
    sys.exit("firstboot.ps1 in the image has no test hook point")
hook = ("# ZERO GOLDEN TEST ONLY (added to a throwaway overlay by golden/windows/build.sh, not in the image)\r\n"
        "if (-not $InSpecialize -and -not (Test-Path 'C:\\zero-verify\\started')) { New-Item -ItemType File 'C:\\zero-verify\\started' | Out-Null; "
        "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "
        "'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"& C:\\zero-verify\\verify.ps1 *> C:\\zero-verify\\verify.log\"' } | Out-Null }")
open(p, "w", encoding="utf-8", newline="").write(t.replace(mark, hook))
PY
overlay() { # a fresh copy-on-write overlay of the image, the size of the laptop's NVMe, with the test hook
rm -f "$OV"
qemu-img create -q -f qcow2 -F raw -b "$DISK" "$OV" "$NVME_BYTES"
if modprobe nbd max_part=16 2>/dev/null && [ -e /dev/nbd0 ]; then
  qemu-nbd -c /dev/nbd0 "$OV"; udevadm settle 2>/dev/null || sleep 2; partprobe /dev/nbd0 2>/dev/null || true; sleep 2
  ntfs-3g "$(ntfs_part /dev/nbd0)" "$MNT"
  cp -r "$VS/zero-verify" "$MNT/"
  cp "$VS/firstboot.ps1" "$MNT/$FB"
  umount "$MNT"; qemu-nbd -d /dev/nbd0 >/dev/null
else
  say "no nbd module: writing the test hook into the overlay with guestfish"
  apt-get install -y -qq libguestfs-tools >/dev/null 2>&1 || true
  chmod 0644 /boot/vmlinuz-* 2>/dev/null || true
  P3=$(guestfish --ro -a "$OV" run : list-filesystems | awk -F: '/ntfs/{print $1}' | tail -n 1)
  guestfish --rw -a "$OV" run : mount "$P3" / : mkdir-p /zero-verify : copy-in "$VS/zero-verify/verify.ps1" "$VS/zero-verify/expect.json" /zero-verify \
    : upload "$VS/firstboot.ps1" "/$FB" : umount-all
fi
}
# A laptop fresh from imaging: a firmware with no boot entries. Secure Boot on (Microsoft keys), as the
# laptops ship; if the check does not start there (VM died, or nothing within 25 min), once more with
# Secure Boot off.
vboot() { # name secureboot(0|1)
  overlay
  new_identity   # a "new laptop"
  if [ "$2" = 1 ]; then
    cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$VARS"
    export VM_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd VM_MACHINE=q35,accel=kvm,smm=on VM_EXTRA="-global driver=cfi.pflash01,property=secure,value=on"
  else
    cp "$OVMF_VARS" "$VARS"; unset VM_CODE VM_MACHINE VM_EXTRA
  fi
  VM_START_RE=ZERO_VERIFY_STARTED VM_START_TMO=$((1500 * TS)) vm "$1" $((5400 * TS)) 'ZERO_VERIFY_DONE' "$VERIFY_SMP" "$VERIFY_MEM" -- \
    -drive if=none,id=d0,file="$OV",format=qcow2,cache=unsafe,discard=unmap -device nvme,drive=d0,serial="$VM_DISKSERIAL" \
    -nic user,model=e1000e,mac="$VM_MAC"
}
VSB=1; T1=$SECONDS
vboot verify 1 || VERIFY=FAIL
if ! grep -aq ZERO_VERIFY_STARTED "$LOGS/verify-serial.log"; then
  say "the Secure Boot VM ended after $((SECONDS - T1)) s without starting the check; retrying with Secure Boot off"
  cp "$LOGS/verify-serial.log" "$LOGS/verify-sb-serial.log" 2>/dev/null || true
  VERIFY=PASS; VSB=0
  vboot verify 0 || VERIFY=FAIL
fi
unset VM_CODE VM_MACHINE VM_EXTRA
echo "first boot: QEMU/KVM + OVMF, ${NVME_BYTES}-byte NVMe, Secure Boot $([ "$VSB" = 1 ] && echo on || echo off), $VERIFY_SMP vCPU / $VERIFY_MEM GiB, user-mode network" > "$LOGS/verify-boot.txt"
{ grep -aE '^(VERIFY OK|VERIFY FAILED)' "$LOGS/models-sha256.txt"; cat "$LOGS/verify-boot.txt"; tr -d '\r' < "$LOGS/verify-serial.log" | grep -aE '^(VERIFY|ZERO_VERIFY)'; } | tee "$LOGS/verify-report.txt" || true
grep -aq 'ZERO_VERIFY_RESULT: PASS' "$LOGS/verify-serial.log" || VERIFY=FAIL
# the guest's own logs out of the overlay (read-only): service logs, first-boot log, Setup logs, events
G=$LOGS/verify-guest; mkdir -p "$G"
if [ -e /dev/nbd0 ] && qemu-nbd -r -c /dev/nbd0 "$OV" 2>/dev/null; then
  udevadm settle 2>/dev/null || sleep 2; partprobe /dev/nbd0 2>/dev/null || true; sleep 2
  if ntfs-3g -o ro "$(ntfs_part /dev/nbd0)" "$MNT" 2>/dev/null; then
    cp -r "$MNT/ProgramData/leCore+/logs" "$G/lecore-logs" 2>/dev/null || true
    cp "$MNT/zero-verify/verify.log" "$MNT/zero-verify/report.txt" "$G/" 2>/dev/null || true
    cp "$MNT"/Windows/Setup/Scripts/*.log "$G/" 2>/dev/null || true
    cp "$MNT/Windows/Panther/setupact.log" "$G/panther-setupact.log" 2>/dev/null || true
    cp "$MNT/Windows/Panther/UnattendGC/setupact.log" "$G/unattendgc-setupact.log" 2>/dev/null || true
    cp "$MNT/Windows/System32/winevt/Logs/System.evtx" "$MNT/Windows/System32/winevt/Logs/Application.evtx" "$G/" 2>/dev/null || true
    umount "$MNT"
  fi
  qemu-nbd -d /dev/nbd0 >/dev/null
fi
say "guest logs: $(find "$G" -type f | wc -l) files in logs/verify-guest"
rm -f "$OV"
say "first-boot verification: $VERIFY"

# ---------------------------------------------------------------------------------------------------
# 6. upload
[ "$VERIFY" = PASS ] || die "first-boot verification failed (logs/verify-report.txt); the image is not uploaded"
if [ "$UPLOAD" = 1 ]; then
  P=${PREFIX%/}
  KEY=$P/$NAME.img.zst
  say "streaming to $(store_uri "$KEY") ${S3_ENDPOINT_URL:+at $S3_ENDPOINT_URL }(raw sha256 + zstd)"
  store_tune
  tee >(sha256sum | awk '{print $1}' > "$WORK/raw.sha256") < "$DISK" | zstd -T0 -3 -c \
    | tee >(sha256sum | awk '{print $1}' > "$WORK/zst.sha256") >(wc -c > "$WORK/zst.bytes") \
    | store s3 cp - "$(store_uri "$KEY")" --expected-size "$DISK_BYTES" --only-show-errors
  for _ in $(seq 1 300); do [ -s "$WORK/raw.sha256" ] && [ -s "$WORK/zst.sha256" ] && [ -s "$WORK/zst.bytes" ] && break; sleep 1; done
  python3 - "$WORK/manifest.json" <<PY
import json, sys
m = {"product": "Zero", "os": "windows", "tier": "$TIER", "laptop": "$TARGET", "image": "$NAME.img.zst",
     "format": "raw GPT disk image, zstd-compressed; write with: zstd -dc FILE | dd of=/dev/nvme0n1 bs=16M oflag=direct",
     "raw_bytes": $DISK_BYTES, "raw_sha256": open("$WORK/raw.sha256").read().strip(),
     "zst_bytes": int(open("$WORK/zst.bytes").read().strip()), "zst_sha256": open("$WORK/zst.sha256").read().strip(),
     "s3": "$(store_uri "$KEY")", "endpoint": "${S3_ENDPOINT_URL:-aws}", "base_release": "${BASE_TAG:-}", "golden_commit": "${GITHUB_SHA:-}",
     "catalog": json.loads('''$SUMMARY'''), "laptop_nvme_bytes": $NVME_BYTES,
     "verification": "$VERIFY", "verification_report": open("$LOGS/verify-report.txt").read().splitlines(),
     "model_sha256_check": open("$LOGS/models-sha256.txt").read().splitlines()[-1]}
json.dump(m, open(sys.argv[1], "w"), indent=1)
PY
  store s3 cp "$WORK/manifest.json" "$(store_uri "$P/$NAME.manifest.json")" --only-show-errors
  store s3 cp "$LOGS/verify-report.txt" "$(store_uri "$P/$NAME.verify.txt")" --only-show-errors
  store s3 ls "$(store_uri "$P/")" --human-readable
  cat "$WORK/manifest.json"
fi
[ "$KEEP" = 1 ] || rm -f "$DISK"
say "done"
