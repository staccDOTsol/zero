#!/usr/bin/env bash
# CI smoke test for the Zero Linux image. Boots the image headless in QEMU with OVMF (UEFI) twice:
#   A) the pristine image (copy-on-write overlay, 40 GiB virtual NVMe, Secure Boot OFF): first boot,
#      chat memory-only, llama skipped without a model, firewall, in-system provisioning, llama-server
#   B) a COPY of the image provisioned on the host with provision/linux-add-models.sh --image (which
#      also has to grow the image), Secure Boot ON (OVMF with Microsoft keys): shim -> GRUB -> kernel,
#      model server up at boot.
# The released image file is never written to. The tiny test model never enters it.
#   sudo linux/smoke/run-smoke.sh IMAGE OUT_DIR
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
IMG=$(readlink -f "${1:?image}")
OUT=$(mkdir -p "${2:?out dir}" && cd "$2" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

# Tiny chat model for the test only (SmolLM2-135M-Instruct Q4_K_M, 105 MB). Never shipped.
TEST_REPO=bartowski/SmolLM2-135M-Instruct-GGUF
TEST_FILE=SmolLM2-135M-Instruct-Q4_K_M.gguf
TEST_BYTES=105454432
TEST_SHA=2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d

if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=kvm; CPU=host; TMO=${SMOKE_TIMEOUT:-1800}
else ACCEL=tcg; CPU=max; TMO=${SMOKE_TIMEOUT:-4800}; fi
echo "QEMU acceleration: $ACCEL (timeout ${TMO}s per boot)"
qemu-system-x86_64 --version | head -n1

# ---- smoke data disk (read-only in the VM) -------------------------------------------------------
SD=$OUT/smoke-disk
rm -rf "$SD"; mkdir -p "$SD/provision"
cp "$HERE/smoke.sh" "$SD/"
cp "$REPO/provision/linux-add-models.sh" "$SD/provision/"
cat > "$SD/smoke-catalog.json" <<EOF
{"updated": "ci", "models": [
  {"id": "smoke-tiny", "name": "SmolLM2 135M Instruct (CI smoke test only)", "license": "apache-2.0",
   "default_for": ["pro", "max", "ultra"],
   "builds": {"pro":   {"repo": "$TEST_REPO", "quant": "Q4_K_M", "speed": "fast",
                        "files": [{"path": "$TEST_FILE", "bytes": $TEST_BYTES, "sha256": "$TEST_SHA"}]},
              "max": null, "ultra": null}}]}
EOF
# boot B: same file, but marked as an "offload" build to exercise the launcher's LLAMA_OFFLOAD_ARGS path
sed 's/"speed": "fast"/"speed": "offload"/' "$SD/smoke-catalog.json" > "$SD/smoke-catalog-offload.json"
echo "--- host: provision/linux-add-models.sh --download-only (downloads + sha256 check)"
bash "$REPO/provision/linux-add-models.sh" --tier pro --catalog "$SD/smoke-catalog.json" \
  --cache "$SD/cache" --download-only smoke-tiny
rm -f "$OUT/smoke-disk.img"
mkfs.ext4 -q -L ZEROSMOKE -d "$SD" "$OUT/smoke-disk.img" 400M

# ---- systemd units injected through SMBIOS credentials (systemd >= 256 debug generator) ----------
unit_b64() { # mode
  base64 -w0 <<EOF
[Unit]
Description=Zero CI smoke test ($1) - injected by CI through a VM credential, not part of the image
After=graphical.target lecore-chat.service nftables.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mkdir -p /run/zero-smoke && mount -o ro LABEL=ZEROSMOKE /run/zero-smoke && exec /bin/bash /run/zero-smoke/smoke.sh $1'
TimeoutStartSec=infinity
StandardOutput=journal+console
EOF
}
DROPIN_B64=$(printf '[Unit]\nWants=zero-smoke.service\n' | base64 -w0)

qmp() { # socket command [json-args]
  python3 - "$@" <<'PY'
import json, socket, sys
sock, cmd = sys.argv[1], sys.argv[2]
args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
f = s.makefile("rw")
f.readline()
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

GUEST_MAC=52:54:00:5a:e7:00

wire_check() { # pcap label kernel-start-epoch -> 0 if the OS sent no frame (frames before the kernel are firmware)
  python3 - "$1" "$2" "$GUEST_MAC" "${3:-0}" <<'PY'
import struct, sys
path, label, mac = sys.argv[1], sys.argv[2], bytes.fromhex(sys.argv[3].replace(":", ""))
kstart = float(sys.argv[4]) - 1.0          # 1 s allowance: the guest clock comes from the RTC (1 s resolution)
data = open(path, "rb").read()
if len(data) < 24:
    print("wire capture %s: empty file" % label); sys.exit(2)
endian = "<" if data[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
off, total, sent, fw, rows = 24, 0, 0, 0, []
while off + 16 <= len(data):
    ts, us, incl, _ = struct.unpack(endian + "IIII", data[off:off + 16]); off += 16
    f = data[off:off + incl]; off += incl; total += 1
    if len(f) >= 14 and f[6:12] == mac:
        before = ts + us / 1e6 < kstart
        if before: fw += 1
        else: sent += 1
        et = struct.unpack(">H", f[12:14])[0]; d = "ethertype 0x%04x" % et
        if et == 0x0800 and len(f) >= 34:
            pr = f[23]; d = "IPv4 %s -> %s proto %d" % (".".join(map(str, f[26:30])), ".".join(map(str, f[30:34])), pr)
            if pr in (6, 17) and len(f) >= 38: d += " dport %d" % struct.unpack(">H", f[36:38])[0]
        elif et == 0x86dd and len(f) >= 54:
            d = "IPv6 next-header %d to %s" % (f[20], f[38:54].hex())
        elif et == 0x0806:
            d = "ARP"
        rows.append(("before the kernel started (UEFI firmware): " if before else "by the OS: ") + d)
print("wire capture %s: %d frames on the link; sent by the VM: %d by the OS, %d by the UEFI firmware before the kernel started"
      % (label, total, sent, fw))
for r in rows[:25]: print("  sent", r)
sys.exit(0 if sent == 0 else 1)
PY
}

boot() { # name overlay mode secure(0|1)
  local name=$1 disk=$2 mode=$3 sb=$4 code vars machine extra=()
  if [ "$sb" = 1 ]; then
    code=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd; cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$OUT/$name-vars.fd"
    machine="q35,accel=$ACCEL,smm=on"; extra=(-global driver=cfi.pflash01,property=secure,value=on)
  else
    code=/usr/share/OVMF/OVMF_CODE_4M.fd; cp /usr/share/OVMF/OVMF_VARS_4M.fd "$OUT/$name-vars.fd"
    machine="q35,accel=$ACCEL"
  fi
  local log=$OUT/$name-serial.log sock=$OUT/$name-qmp.sock pcap=$OUT/$name-net.pcap
  rm -f "$log" "$sock" "$pcap" "$OUT/$name-net-zero-egress.pcap"
  echo "=== boot $name: mode=$mode secureboot=$sb"
  qemu-system-x86_64 -name "zero-$name" -machine "$machine" -cpu "$CPU" -smp 2 -m 4096 "${extra[@]}" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$code" \
    -drive if=pflash,format=raw,unit=1,file="$OUT/$name-vars.fd" \
    -drive file="$disk",if=none,id=disk0,format=qcow2 -device nvme,drive=disk0,serial=ZERO0001 \
    -drive file="$OUT/smoke-disk.img",if=virtio,format=raw,readonly=on \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=$GUEST_MAC \
    -object filter-dump,id=dump0,netdev=n0,file="$pcap" \
    -device virtio-rng-pci -device virtio-vga -display none \
    -serial file:"$log" -qmp unix:"$sock",server=on,wait=off \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.zero-smoke.service=$(unit_b64 "$mode")" \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.graphical.target=$DROPIN_B64" \
    -no-reboot &
  local pid=$! t0=$SECONDS shot=0 next=300 ckpt=0 t
  while kill -0 "$pid" 2>/dev/null; do
    t=$((SECONDS - t0))
    if [ "$ckpt" = 0 ] && grep -q ZERO_SMOKE_PCAP_CHECKPOINT "$log" 2>/dev/null; then
      cp --sparse=never "$pcap" "$OUT/$name-net-zero-egress.pcap"; ckpt=1
      echo "  wire capture checkpoint at ${t}s (everything before the firewall control step)"
    fi
    if grep -q ZERO_SMOKE_DONE "$log" 2>/dev/null; then
      sleep 5; qmp "$sock" screendump "{\"filename\": \"$OUT/$name-screen.png\", \"format\": \"png\"}" || true
      qmp "$sock" quit || true; break
    fi
    if [ "$t" -ge 900 ] && ! grep -q ZERO_SMOKE_STARTED "$log" 2>/dev/null; then
      echo "boot $name: the smoke unit never started (15 min)"; t=$TMO
    fi
    if [ "$t" -ge "$TMO" ]; then
      echo "boot $name: TIMEOUT after ${t}s"
      qmp "$sock" screendump "{\"filename\": \"$OUT/$name-timeout.png\", \"format\": \"png\"}" || true
      qmp "$sock" quit || kill "$pid"; break
    fi
    if [ "$t" -ge "$next" ]; then
      next=$((next + 300)); shot=$((shot + 1))
      qmp "$sock" screendump "{\"filename\": \"$OUT/$name-progress-$shot.png\", \"format\": \"png\"}" >/dev/null 2>&1 || true
      echo "  ... ${t}s, serial log $(wc -l < "$log") lines"
    fi
    sleep 2
  done
  wait "$pid" 2>/dev/null || true
  echo "--- serial log ($name), smoke section:"
  sed -n '/ZERO SMOKE TEST/,$p' "$log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'
  local wire=0
  echo "--- wire-level egress check ($name): every frame the VM's NIC sent from power-on to the checkpoint"
  if [ -f "$OUT/$name-net-zero-egress.pcap" ]; then
    local ks; ks=$(grep -a -o 'ZERO_SMOKE_KERNEL_START [0-9.]*' "$log" | tail -n1 | cut -d' ' -f2)
    wire_check "$OUT/$name-net-zero-egress.pcap" "$name power-on..checkpoint" "${ks:-0}" || wire=1
  else
    echo "no checkpoint capture"; wire=1
  fi
  [ "$wire" = 0 ] && echo "WIRE PASS: boot $name: the OS sent 0 frames on its network link (kernel start to checkpoint)" \
                  || echo "WIRE FAIL: boot $name: the OS sent frames on its network link"
  wire_check "$pcap" "$name whole boot incl. deliberate control traffic" >/dev/null 2>&1; true
  grep -a "ZERO_SMOKE_RESULT" "$log" | tail -n1 | grep -q "RESULT: PASS" && [ "$wire" = 0 ]
}

RC=0
# ---- A: pristine image, Secure Boot off ---------------------------------------------------------
qemu-img create -q -f qcow2 -F raw -b "$IMG" "$OUT/a.qcow2" 40G
boot a "$OUT/a.qcow2" full 0 | tee "$OUT/a-console.txt" || RC=1
grep -E "^(WIRE (PASS|FAIL)|wire capture)" "$OUT/a-console.txt" > "$OUT/a-wire.txt" || true
rm -f "$OUT/a.qcow2"

# ---- B: image copy provisioned on the host (--image, forced to grow), Secure Boot on ------------
echo "--- host: provision/linux-add-models.sh --image (on a throwaway copy)"
cp --sparse=always "$IMG" "$OUT/b.img"
bash "$REPO/provision/linux-add-models.sh" --tier pro --catalog "$SD/smoke-catalog-offload.json" --cache "$SD/cache" \
  --image "$OUT/b.img" --reserve-gb 12 smoke-tiny || RC=1
ls -ls "$OUT/b.img"; sgdisk -p "$OUT/b.img" | tail -n 3
qemu-img create -q -f qcow2 -F raw -b "$OUT/b.img" "$OUT/b.qcow2" 30G
boot b "$OUT/b.qcow2" sb 1 | tee "$OUT/b-console.txt" || RC=1
grep -E "^(WIRE (PASS|FAIL)|wire capture)" "$OUT/b-console.txt" > "$OUT/b-wire.txt" || true
rm -f "$OUT/b.qcow2" "$OUT/b.img"

{
  echo "Zero Linux image smoke test ($(date -u +%Y-%m-%dT%H:%M:%SZ), QEMU $ACCEL, OVMF)"
  for n in a b; do
    echo; echo "## boot $n"; grep -a -E 'SMOKE (PASS|FAIL|WARN)|ZERO_SMOKE_RESULT' "$OUT/$n-serial.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' || echo "(no results)"
    [ -f "$OUT/$n-wire.txt" ] && cat "$OUT/$n-wire.txt"
  done
} > "$OUT/smoke-report.txt"
cat "$OUT/smoke-report.txt"
rm -f "$OUT"/*.sock "$OUT"/*-vars.fd
exit $RC
