#!/bin/bash
# CI ONLY. Runs inside the booted Zero image under QEMU. It is never part of the image: the CI harness
# (run-smoke.sh) attaches a separate read-only disk (label ZEROSMOKE) and injects a one-off systemd
# unit through QEMU SMBIOS credentials (which systemd honours only inside VMs).
#   smoke.sh full   pristine image: first boot, chat memory-only, firewall, provisioning, llama-server
#   smoke.sh sb     Secure Boot ON, image pre-provisioned with --image on the build host
MODE=${1:-full}
D=/run/zero-smoke
exec >/dev/ttyS0 2>&1
set -u
PASS=0; FAIL=0; WARN=0
ok()   { echo "SMOKE PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "SMOKE FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { echo "SMOKE WARN: $*"; WARN=$((WARN + 1)); }
hdr()  { echo; echo "=================== $* ==================="; }
wait_http() { # url seconds
  local i=0
  while [ "$i" -lt "$2" ]; do curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null && return 0; sleep 2; i=$((i + 2)); done
  return 1
}
chat() { curl -sS --max-time 900 -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys;print(json.dumps({"message":sys.argv[1]}))' "$1")" http://127.0.0.1:7860/api/chat; }

hdr "ZERO SMOKE TEST ($MODE)"
echo "ZERO_SMOKE_STARTED $MODE"
grep PRETTY_NAME /etc/os-release; uname -a
cat /usr/share/lecore-plus/versions.txt 2>/dev/null
echo "secure boot: $(mokutil --sb-state 2>&1 | tr '\n' ' ')"
echo "lockdown:    $(cat /sys/kernel/security/lockdown 2>/dev/null)"
echo "boot state:  $(systemctl is-system-running 2>&1) (this test is itself part of the boot transaction)"
systemctl list-jobs --no-pager | head -n 15
systemctl --no-pager --failed
systemd-analyze 2>/dev/null | head -n 1

hdr "first boot"
[ "$(systemctl show -p Result --value zero-growroot.service)" = success ] && ok "zero-growroot ran" || bad "zero-growroot did not succeed"
journalctl -b -u zero-growroot --no-pager -o cat | tail -n 8
ROOTSZ=$(df -B1 --output=size / | tail -n 1 | tr -d ' ')
DISKSZ=$(lsblk -bdno SIZE "/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)")
echo "root fs size $ROOTSZ bytes on a $DISKSZ byte disk"
[ "$ROOTSZ" -gt $((DISKSZ * 9 / 10)) ] && ok "root file system grew to fill the disk ($((ROOTSZ / 1073741824)) GiB)" \
  || bad "root file system did not grow (root $ROOTSZ, disk $DISKSZ)"
sgdisk -v "/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n1)" | tail -n 2
[ -s /etc/machine-id ] && ok "machine-id generated on first boot" || bad "machine-id empty"
grep -q '^NAME="Zero"' /etc/os-release && grep -q '^LOGO=zero' /etc/os-release && [ -f /etc/xdg/autostart/zero.desktop ] \
  && grep -q '^Name=Zero' /usr/share/applications/zero.desktop && ok "branded Zero (os-release, launcher, login autostart)" || bad "Zero branding missing"
U=$(awk -F: '$3>=1000 && $3<65000 {print $1}' /etc/passwd)
[ -z "$U" ] && ok "no user accounts baked in (first-boot setup creates the owner)" || bad "unexpected users: $U"
passwd -S root | grep -qE '^root (L|NP)' && ok "root account locked: $(passwd -S root)" || warn "root: $(passwd -S root)"
systemctl is-active -q gdm.service && ok "gdm (GNOME display manager) active" || bad "gdm not active"
sleep 5; pgrep -a -f gnome-initial-setup | head -n 3 && ok "gnome-initial-setup is running (owner account creation)" \
  || warn "gnome-initial-setup process not seen yet"

hdr "GPU memory limit (TTM)"
cat /run/modprobe.d/zero-gpu-memory.conf 2>/dev/null && ok "TTM limit config written from RAM" || bad "no /run/modprobe.d/zero-gpu-memory.conf"
modprobe ttm 2>/dev/null
WANT=$(sed -n 's/.*pages_limit=\([0-9]*\).*/\1/p' /run/modprobe.d/zero-gpu-memory.conf 2>/dev/null)
GOT=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo "?")
[ -n "$WANT" ] && [ "$GOT" = "$WANT" ] && ok "ttm pages_limit applied ($GOT pages)" || warn "ttm pages_limit: want '$WANT' got '$GOT' (ttm may be built in or loaded earlier)"
lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -E 'init-top/(00-zero|udev|ORDER)' | head
unmkinitramfs "/boot/initrd.img-$(uname -r)" /tmp/initrd 2>/dev/null && \
  { O=$(find /tmp/initrd -path '*scripts/init-top/ORDER' | head -n1); cat "$O";
    awk '/00-zero-gpu-memory/{z=NR} /init-top\/udev/{u=NR} END{exit !(z && u && z<u)}' "$O" \
      && ok "initramfs runs the TTM sizing before udev" || bad "initramfs script order wrong"; }

hdr "zero egress: firewall"
nft list ruleset
nft list chain inet zero_egress output 2>/dev/null | grep -q 'policy drop' && ok "nftables output policy drop is loaded" || bad "output policy drop missing"
systemctl is-active -q nftables.service && ok "nftables.service active" || bad "nftables.service not active"
echo "--- listening sockets"
if command -v ss >/dev/null; then
  ss -H -tulnp
  NONLO=$(ss -H -tuln | awk '{print $5}' | grep -vE '^(127\.[0-9.]+|\[::1\]|::1|\[::ffff:127\.[0-9.]+\]):' || true)
  [ -z "$NONLO" ] && ok "no TCP/UDP listener outside loopback" || bad "listeners outside loopback: $NONLO"
else
  bad "ss (iproute2) missing; cannot check listeners"
fi
NMRAF=$(systemctl show -p RestrictAddressFamilies --value NetworkManager.service)
echo "NetworkManager RestrictAddressFamilies: $NMRAF"
echo "$NMRAF" | grep -q AF_PACKET && ok "NetworkManager denied packet sockets (no DHCP; raw frames bypass nftables)" || bad "NetworkManager may use packet sockets"
echo "--- phone-home services"
BADU=""
for u in apt-daily.timer apt-daily-upgrade.timer systemd-timesyncd.service fwupd-refresh.timer avahi-daemon.service \
         cups-browsed.service geoclue.service ModemManager.service packagekit.service unattended-upgrades.service \
         motd-news.timer snapd.service; do
  st=$(systemctl is-enabled "$u" 2>&1 | head -n1); act=$(systemctl is-active "$u" 2>&1 | head -n1)
  printf '  %-30s enabled=%-10s active=%s\n' "$u" "$st" "$act"
  [ "$act" = active ] && BADU="$BADU $u"
  [ "$st" = enabled ] && BADU="$BADU $u(enabled)"
done
[ -z "$BADU" ] && ok "no phone-home service enabled or running" || bad "running: $BADU"
for p in unattended-upgrades popularity-contest snapd gnome-software packagekit flatpak avahi-daemon cups-browsed systemd-timesyncd; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' && BADP="${BADP:-} $p"
done
[ -z "${BADP:-}" ] && ok "phone-home packages not installed" || bad "installed: $BADP"
systemctl list-timers --all --no-pager | head -n 20
grep -h enabled /etc/NetworkManager/conf.d/*.conf
test -f /etc/chromium/policies/managed/zero.json && python3 -m json.tool /etc/chromium/policies/managed/zero.json >/dev/null \
  && ok "chromium enterprise policy installed" || bad "chromium policy missing"
chromium --version 2>/dev/null || true

if [ "$MODE" = full ]; then
  hdr "model server with no model installed"
  systemctl show lecore-llama.service -p ActiveState -p SubState -p Result -p NRestarts -p ConditionResult -p ExecMainStatus
  st=$(systemctl show -p ActiveState --value lecore-llama.service); cr=$(systemctl show -p ConditionResult --value lecore-llama.service)
  nr=$(systemctl show -p NRestarts --value lecore-llama.service)
  [ "$st" = inactive ] && [ "$cr" = no ] && [ "$nr" = 0 ] && ok "lecore-llama skipped cleanly (inactive, condition false, 0 restarts)" \
    || bad "lecore-llama state $st condition $cr restarts $nr"
  systemctl is-failed -q lecore-llama.service && bad "lecore-llama is failed" || true
fi

hdr "chat (leCore) on 127.0.0.1:7860"
if wait_http http://127.0.0.1:7860/ 300; then ok "lecore-chat answers HTTP on 127.0.0.1:7860"; else bad "lecore-chat not reachable"; fi
systemctl show lecore-chat.service -p ActiveState -p NRestarts
curl -s http://127.0.0.1:7860/ | grep -o '<title>[^<]*</title>' | grep -q '<title>Zero</title>' && ok "page title is Zero" || bad "page title"
curl -s http://127.0.0.1:7860/api/settings; echo
R=$(chat "what is lecore"); echo "chat> what is lecore"; echo "$R" | head -c 600; echo
echo "$R" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("text")' 2>/dev/null \
  && ok "chat answered from leCore memory$([ "$MODE" = full ] && echo ' (memory-only, no model running)')" || bad "chat did not answer"
if [ "$MODE" = full ]; then
  R=$(chat "teach: what colour is the zero test parrot = ultraviolet"); echo "$R" | head -c 300; echo
  R=$(chat "what colour is the zero test parrot"); echo "$R" | head -c 300; echo
  echo "$R" | grep -qi ultraviolet && ok "teach + recall works (writable memory partition)" || warn "taught fact not recalled"
  R=$(chat "Name a famous bridge in a city you like"); echo "$R" | head -c 400; echo
  echo "$R" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && ok "unknown question handled memory-only (no error)" || bad "unknown question errored"
fi
journalctl -b -u lecore-chat --no-pager -o cat | grep -iE 'traceback|error|read-only' | head -n 20

hdr "egress is blocked; loopback works"
IF=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
echo "--- NIC $IF as NetworkManager left it (DHCP must not have happened):"
ip -4 -br addr show dev "$IF"
nmcli -t -f GENERAL.STATE,IP4.ADDRESS device show "$IF" 2>/dev/null
if ip -4 -o addr show dev "$IF" | grep -q inet; then bad "NIC got an IPv4 address on its own (DHCP leaked)"; else ok "no IPv4 address acquired (no DHCP)"; fi
journalctl -b -u NetworkManager --no-pager -o cat | grep -iE 'dhcp|AF_PACKET|address family' | tail -n 6
nmcli device set "$IF" managed no 2>/dev/null || true
ip link set "$IF" up; ip addr flush dev "$IF"; ip addr add 10.0.2.15/24 dev "$IF"; ip route replace default via 10.0.2.2
ip -br addr
echo "--- static address set by hand; zero-egress rules loaded:"
OUT=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>&1); echo "curl http://1.1.1.1 -> $OUT"
case "$OUT" in 2*|3*|4*) bad "outbound HTTP succeeded with the firewall on" ;; *) BLOCKED=1 ;; esac
OUT2=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://10.0.2.2/ 2>&1); echo "curl http://10.0.2.2 (gateway) -> $OUT2"
getent ahosts example.com >/dev/null 2>&1 && bad "DNS resolution worked" || echo "DNS: no resolution (expected)"
curl -fsS -m 5 -o /dev/null http://127.0.0.1:7860/ && ok "loopback works with the firewall on" || bad "loopback blocked"
zero-egress status
# The host copies the wire capture of the VM's NIC now: everything up to here ran with zero egress.
echo "ZERO_SMOKE_PCAP_CHECKPOINT"
sleep 15
if [ "$MODE" = full ]; then
  echo "--- control: firewall removed for one request to prove the path exists"
  nft delete table inet zero_egress
  OUT3=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>&1); echo "curl http://1.1.1.1 (firewall off) -> $OUT3"
  nft -f /etc/nftables.conf
  OUT4=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>&1); echo "curl http://1.1.1.1 (firewall restored) -> $OUT4"
  case "$OUT3" in
    2*|3*|4*) [ "${BLOCKED:-0}" = 1 ] && case "$OUT4" in 2*|3*|4*) bad "egress open after restore" ;; *) ok "egress blocked by the firewall (control without it reached 1.1.1.1: HTTP $OUT3)" ;; esac ;;
    *) warn "control failed (no internet from the CI VM?); blocked result inconclusive: $OUT / $OUT3" ;;
  esac
  nft list chain inet zero_egress output | grep counter
  ip addr flush dev "$IF"; nmcli device set "$IF" managed yes 2>/dev/null || true

  echo "--- owner flow: sudo zero-egress open / close"
  zero-egress open
  zero-egress status
  OK5=""; for i in $(seq 1 30); do
    OUT5=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>&1)
    case "$OUT5" in 2*|3*|4*) OK5=1; break ;; esac; sleep 2
  done
  echo "after zero-egress open: curl http://1.1.1.1 -> $OUT5; $(ip -4 -br addr show dev "$IF")"
  zero-egress close
  zero-egress status
  sleep 3
  OUT6=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://1.1.1.1/ 2>&1); echo "after zero-egress close: curl http://1.1.1.1 -> $OUT6"
  NMRAF=$(systemctl show -p RestrictAddressFamilies --value NetworkManager.service)
  if [ -n "$OK5" ] && case "$OUT6" in 2*|3*|4*) false ;; *) true ;; esac && echo "$NMRAF" | grep -q AF_PACKET; then
    ok "zero-egress open (DHCP + internet work) and close (blocked again, NetworkManager packet sockets denied again)"
  else
    bad "zero-egress open/close: open=$OUT5 close=$OUT6 NM RestrictAddressFamilies='$NMRAF'"
  fi
else
  [ "${BLOCKED:-0}" = 1 ] && ok "outbound HTTP to 1.1.1.1 blocked (no control step in this boot; the wire capture is the proof)"
  ip addr flush dev "$IF"; nmcli device set "$IF" managed yes 2>/dev/null || true
fi

if [ "$MODE" = full ]; then
  hdr "provisioning a model inside the running system (provision/linux-add-models.sh --target /)"
  cp -a "$D/cache" /var/tmp/zero-cache
  bash "$D/provision/linux-add-models.sh" --tier pro --catalog "$D/smoke-catalog.json" --cache /var/tmp/zero-cache \
    --target / --reserve-gb 1 smoke-tiny && ok "linux-add-models.sh --target / succeeded" || bad "linux-add-models.sh failed"
  echo "/etc/lecore-plus/model: $(cat /etc/lecore-plus/model 2>/dev/null)"; ls -l /var/lib/lecore-plus/models
  python3 -m json.tool /var/lib/lecore-plus/models/zero-models.json | head -n 30
  zero-model list
  rm -rf /var/tmp/zero-cache
fi

hdr "llama-server on 127.0.0.1:8080"
if [ "$MODE" = full ]; then
  # lecore-llama.path starts the server when /etc/lecore-plus/model is written
  if wait_http http://127.0.0.1:8080/health 180; then ok "lecore-llama started by lecore-llama.path after provisioning"
  else warn "path unit did not start lecore-llama; starting it by hand"; systemctl start lecore-llama.service; fi
else
  systemctl is-active -q lecore-llama.service && ok "lecore-llama started at boot with the pre-provisioned model" || bad "lecore-llama not active at boot"
fi
wait_http http://127.0.0.1:8080/health 300 && ok "llama-server /health OK" || bad "llama-server not healthy"
systemctl show lecore-llama.service -p ActiveState -p NRestarts -p MainPID
ps -o args= -p "$(systemctl show -p MainPID --value lecore-llama.service)" 2>/dev/null
curl -s http://127.0.0.1:8080/v1/models | head -c 400; echo
CC=$(curl -s --max-time 300 -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":24,"temperature":0}' \
  http://127.0.0.1:8080/v1/chat/completions)
echo "$CC" | head -c 600; echo
echo "$CC" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["choices"][0]["message"]["content"].strip()' 2>/dev/null \
  && ok "llama-server served a chat completion (OpenAI /v1)" || bad "no completion from llama-server"
journalctl -b -u lecore-llama --no-pager -o cat | grep -iE 'vulkan|ggml_vk|device|backend|model|error' | head -n 25

hdr "chat -> model rung (LECORE_LLM_URL)"
T0=$(curl -s http://127.0.0.1:8080/slots | python3 -c 'import json,sys; print(sum(int(s.get("id_task",-1)) for s in json.load(sys.stdin)))' 2>/dev/null || echo x)
R=$(chat "Describe in one sentence how volcanoes on Io differ from those on Earth"); echo "$R" | head -c 600; echo
T1=$(curl -s http://127.0.0.1:8080/slots | python3 -c 'import json,sys; print(sum(int(s.get("id_task",-1)) for s in json.load(sys.stdin)))' 2>/dev/null || echo y)
echo "llama slots task ids before/after: $T0 / $T1"
PROV=$(echo "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provenance"))' 2>/dev/null)
if [ "$PROV" = model-cached ] || { [ "$T0" != x ] && [ "$T0" != "$T1" ]; }; then
  ok "chat escalated to llama-server through LECORE_LLM_URL (provenance $PROV)"
else
  bad "chat did not reach the model (provenance $PROV, slots $T0 -> $T1)"
fi

hdr "NVIDIA open module, Vulkan"
modinfo -k "$(uname -r)" nvidia 2>/dev/null | grep -E '^(filename|version|license|signer)' && ok "NVIDIA open kernel module installed for $(uname -r)" || bad "nvidia module missing"
dkms status 2>/dev/null
ls /usr/share/vulkan/icd.d/ /etc/vulkan/icd.d/ 2>/dev/null
vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|apiVersion' | head -n 12

hdr "summary"
echo "--- lecore-chat log (tail)"; journalctl -b -u lecore-chat --no-pager -o cat | tail -n 15
echo "--- lecore-llama log (tail)"; journalctl -b -u lecore-llama --no-pager -o cat | tail -n 15
echo "--- warnings/errors this boot (priority<=3)"; journalctl -b -p 3 --no-pager -o short-monotonic | tail -n 40
RES=PASS; [ "$FAIL" -gt 0 ] && RES=FAIL
echo "ZERO_SMOKE_RESULT: $RES mode=$MODE pass=$PASS fail=$FAIL warn=$WARN"
echo "ZERO_SMOKE_DONE"
sleep 120
systemctl poweroff
