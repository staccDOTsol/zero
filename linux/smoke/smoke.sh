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
KEYF=/etc/lecore-plus/llama-api-key
AUTH() { echo "Authorization: Bearer $(cat "$KEYF" 2>/dev/null)"; }   # the per-machine llama-server key (root may read it)

hdr "ZERO SMOKE TEST ($MODE)"
echo "ZERO_SMOKE_STARTED $MODE"
grep PRETTY_NAME /etc/os-release; uname -a
cat /usr/share/lecore-plus/versions.txt 2>/dev/null
echo "secure boot: $(mokutil --sb-state 2>&1 | tr '\n' ' ')"
echo "lockdown:    $(cat /sys/kernel/security/lockdown 2>/dev/null)"
if [ "$MODE" = sb ]; then
  mokutil --sb-state 2>&1 | grep -q 'SecureBoot enabled' && grep -q '\[integrity\]' /sys/kernel/security/lockdown \
    && ok "booted with Secure Boot enforced (shim -> GRUB -> kernel), kernel lockdown=integrity" || bad "Secure Boot not enforced"
fi
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

hdr "zero egress: per-service confinement (rules)"
nft list ruleset
UL=$(id -u lecore-llama); UC=$(id -u lecore-chat); echo "lecore-llama uid $UL, lecore-chat uid $UC"
nft list chain inet zero_egress output > /tmp/zero-chain 2>&1
grep -q 'policy accept' /tmp/zero-chain && grep -q "meta skuid $UL oifname != \"lo\" counter .*drop" /tmp/zero-chain \
  && grep -q "meta skuid $UC oifname != \"lo\" counter .*drop" /tmp/zero-chain \
  && ok "nftables: output policy accept; non-loopback output dropped for lecore-llama and lecore-chat" || bad "per-user nftables rules missing"
systemctl is-active -q nftables.service && ok "nftables.service active" || bad "nftables.service not active"
for u in lecore-llama lecore-chat; do
  P=$(systemctl show "$u.service" -p User -p IPAddressDeny -p IPAddressAllow -p RestrictAddressFamilies -p Requires | tr '\n' ' ')
  echo "$u.service: $P"
  DENY=$(systemctl show -p IPAddressDeny --value "$u.service" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
  ALLOW=$(systemctl show -p IPAddressAllow --value "$u.service" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
  echo "$P" | grep -q "User=$u" && [ "$DENY" = "0.0.0.0/0 ::/0 " ] && [ "$ALLOW" = "127.0.0.0/8 ::1/128 " ] \
    && systemctl show -p Requires --value "$u.service" | grep -qw nftables.service \
    && ok "$u.service: dedicated user, IPAddressDeny=any, IPAddressAllow=localhost, requires the nftables rules" \
    || bad "$u.service confinement properties: $P"
done
echo "--- listening sockets"
ss -H -tulnp
NONLO=$(ss -H -tlnp | grep -E 'llama-server|python' | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):' || true)
[ -z "$NONLO" ] && ok "llama-server / leCore listen on 127.0.0.1 only" || bad "Zero services listen outside loopback: $NONLO"

hdr "normal OS networking"
IF=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
for i in $(seq 1 60); do ip -4 -o addr show dev "$IF" | grep -q inet && break; sleep 1; done
ip -br addr; ip route | head -n 3
ip -4 -o addr show dev "$IF" | grep -q inet && ok "NetworkManager configured $IF by DHCP" || bad "no DHCP address on $IF"
getent hosts deb.debian.org >/dev/null && ok "DNS works for the system" || bad "DNS resolution failed"
for u in systemd-timesyncd.service apt-daily.timer apt-daily-upgrade.timer NetworkManager.service; do
  printf '  %-28s enabled=%-8s active=%s\n' "$u" "$(systemctl is-enabled "$u" 2>&1)" "$(systemctl is-active "$u" 2>&1)"
done
systemctl is-enabled -q systemd-timesyncd.service && systemctl is-enabled -q apt-daily.timer \
  && ok "time sync and apt update timers enabled (normal Debian behaviour)" || bad "timesyncd/apt timers not enabled"
timedatectl show -p NTP -p NTPSynchronized | tr '\n' ' '; echo
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
H1=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: zero.attacker.example:7860' http://127.0.0.1:7860/api/settings)
H2=$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://attacker.example' -H 'Content-Type: text/plain' -d '{"message":"hi"}' http://127.0.0.1:7860/api/chat)
H3=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost:7860' http://127.0.0.1:7860/api/settings)
echo "chat: foreign Host -> $H1, foreign Origin POST -> $H2, Host localhost:7860 -> $H3"
[ "$H1" = 403 ] && [ "$H2" = 403 ] && [ "$H3" = 200 ] && ok "chat refuses DNS-rebinding Host headers and cross-site POSTs (403); localhost works" \
  || bad "chat Host/Origin checks: foreign Host $H1, foreign Origin $H2, localhost $H3"
curl -s -D - -o /dev/null http://127.0.0.1:7860/ | grep -i '^content-security-policy:' | head -c 200; echo

hdr "per-machine llama-server API key"
systemctl show zero-llama-key.service -p Result -p ActiveState | tr '\n' ' '; echo
journalctl -b -u zero-llama-key --no-pager -o cat | tail -n 3
KS=$(stat -c '%U:%G %a %s' "$KEYF" 2>/dev/null); echo "$KEYF: $KS"
[ "$KS" = "root:lecore-api 640 64" ] && grep -qx "$(cat /etc/machine-id)" /etc/lecore-plus/llama-api-key.machine-id \
  && ok "API key generated at first boot for this machine-id (root:lecore-api 0640, 256 bits)" || bad "API key file: '$KS'"
getent group lecore-api
for u in lecore-llama lecore-chat; do
  setpriv --reuid="$u" --regid="$u" --init-groups -- test -r "$KEYF" && ok "$u can read the key" || bad "$u cannot read the key"
done
setpriv --reuid=nobody --regid=nogroup --clear-groups -- test -r "$KEYF" && bad "nobody can read the key" || ok "other users cannot read the key"

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
ARGS=$(ps -ww -o args= -p "$(systemctl show -p MainPID --value lecore-llama.service)" 2>/dev/null); echo "$ARGS"
case "$MODE" in
  full) echo "$ARGS" | grep -qE -- '--host 127\.0\.0\.1 --port 8080 -ngl 999 -m /var/lib/lecore-plus/models/[^ ]+$' \
          && ok "llama-server command line is exactly --host 127.0.0.1 --port 8080 -ngl 999 -m <model>" || bad "llama-server args: $ARGS" ;;
  sb)   echo "$ARGS" | grep -qE -- '-ngl 999 -m /var/lib/lecore-plus/models/[^ ]+ --cpu-moe' \
          && ok "offload build: launcher added --cpu-moe (and kept -ngl 999)" || bad "offload args missing: $ARGS" ;;
esac
U1=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v1/models)
U2=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":4}' http://127.0.0.1:8080/v1/chat/completions)
U3=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong-key' http://127.0.0.1:8080/v1/models)
U4=$(curl -s -o /dev/null -w '%{http_code}' -H "$(AUTH)" http://127.0.0.1:8080/v1/models)
echo "llama-server: no key /v1/models -> $U1, no key /v1/chat/completions -> $U2, wrong key -> $U3, right key -> $U4"
[ "$U1" = 401 ] && [ "$U2" = 401 ] && [ "$U3" = 401 ] && [ "$U4" = 200 ] \
  && ok "llama-server requires the per-machine API key (no key / wrong key -> 401, key -> 200)" \
  || bad "llama-server API key: no key $U1/$U2, wrong $U3, right $U4"
case "$ARGS" in *"$(cat "$KEYF" 2>/dev/null)"*) bad "the API key is visible on llama-server's command line" ;; *) ok "API key not on llama-server's command line (read from a file)" ;; esac
curl -s -H "$(AUTH)" http://127.0.0.1:8080/v1/models | head -c 400; echo
CC=$(curl -s --max-time 300 -H 'Content-Type: application/json' -H "$(AUTH)" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":24,"temperature":0}' \
  http://127.0.0.1:8080/v1/chat/completions)
echo "$CC" | head -c 600; echo
echo "$CC" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["choices"][0]["message"]["content"].strip()' 2>/dev/null \
  && ok "llama-server served a chat completion (OpenAI /v1)" || bad "no completion from llama-server"
journalctl -b -u lecore-llama --no-pager -o cat | grep -iE 'vulkan|ggml_vk|device|backend|model|error' | head -n 25

hdr "chat -> model rung (LECORE_LLM_URL)"
T0=$(curl -s -H "$(AUTH)" http://127.0.0.1:8080/slots | python3 -c 'import json,sys; print(sum(int(s.get("id_task",-1)) for s in json.load(sys.stdin)))' 2>/dev/null || echo x)
R=$(chat "Describe in one sentence how volcanoes on Io differ from those on Earth"); echo "$R" | head -c 600; echo
T1=$(curl -s -H "$(AUTH)" http://127.0.0.1:8080/slots | python3 -c 'import json,sys; print(sum(int(s.get("id_task",-1)) for s in json.load(sys.stdin)))' 2>/dev/null || echo y)
echo "llama slots task ids before/after: $T0 / $T1"
PROV=$(echo "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provenance"))' 2>/dev/null)
if [ "$PROV" = model-cached ] || { [ "$T0" != x ] && [ "$T0" != "$T1" ]; }; then
  ok "chat escalated to llama-server through LECORE_LLM_URL with the API key (provenance $PROV)"
else
  bad "chat did not reach the model (provenance $PROV, slots $T0 -> $T1)"
fi

hdr "zero egress: per-process test"
code() { "$@" -sS -m 8 -o /dev/null -w '%{http_code}' 2>&1 | tail -n 1; }
reached() { case "$1" in 2*|3*|4*) return 0 ;; *) return 1 ;; esac; }
R0=$(code curl http://1.1.1.1/); echo "root:          curl http://1.1.1.1 -> $R0"
reached "$R0" && ok "root reaches the internet (normal networking)" || bad "root cannot reach the internet ($R0)"
for u in lecore-llama lecore-chat; do
  as_u() { setpriv --reuid="$u" --regid="$u" --clear-groups -- "$@"; }
  RU=$(code as_u curl http://1.1.1.1/); echo "user $u: curl http://1.1.1.1 -> $RU"
  RU6=$(code as_u curl "http://[2606:4700:4700::1111]/"); echo "user $u: curl http://[2606:4700:4700::1111] -> $RU6"
  RL=$(code as_u curl http://127.0.0.1:7860/); echo "user $u: curl http://127.0.0.1:7860 -> $RL"
  if ! reached "$RU" && ! reached "$RU6" && reached "$RL"; then
    ok "user $u: internet blocked (nftables skuid rule), loopback works"
  else bad "user $u: internet=$RU/$RU6 loopback=$RL"; fi
  # the service's own cgroup: a root process moved into it is still blocked (IPAddressDeny=any)
  CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$u.service")
  if [ -d "$CG" ]; then
    sh -c 'sleep 2; exec curl -sS -m 8 -o /dev/null -w "%{http_code}" http://1.1.1.1/ 2>&1' > /tmp/cg-out 2>&1 &
    P=$!; echo "$P" > "$CG/cgroup.procs"; wait "$P"; RC_=$(tail -n 1 /tmp/cg-out)
    sh -c 'sleep 2; exec curl -sS -m 8 -o /dev/null -w "%{http_code}" http://127.0.0.1:7860/ 2>&1' > /tmp/cg-out 2>&1 &
    P=$!; echo "$P" > "$CG/cgroup.procs"; wait "$P"; RCL=$(tail -n 1 /tmp/cg-out)
    echo "root inside $u.service cgroup: internet -> $RC_, loopback -> $RCL"
    ! reached "$RC_" && reached "$RCL" && ok "$u.service cgroup: internet blocked even for root (IPAddressDeny), loopback works" \
      || bad "$u.service cgroup: internet=$RC_ loopback=$RCL"
  else
    bad "$u.service is not running (no cgroup $CG)"
  fi
done
nft list chain inet zero_egress output | grep counter
R1=$(code curl http://1.1.1.1/); reached "$R1" && ok "root still reaches the internet afterwards ($R1)" || bad "root lost the internet ($R1)"
echo "--- llama.cpp: offline mode and no web UI (no remote assets)"
LP=$(systemctl show -p MainPID --value lecore-llama.service)
tr '\0' '\n' < "/proc/$LP/environ" | grep -E '^LLAMA_ARG_(OFFLINE|UI)=' | sort | tr '\n' ' '; echo
UI=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/); echo "GET http://127.0.0.1:8080/ -> $UI"
tr '\0' '\n' < "/proc/$LP/environ" | grep -qx 'LLAMA_ARG_OFFLINE=1' && tr '\0' '\n' < "/proc/$LP/environ" | grep -qx 'LLAMA_ARG_UI=0' \
  && [ "$UI" != 200 ] && ok "llama-server runs offline with its web UI disabled" || bad "llama-server offline/UI settings (UI=$UI)"

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
