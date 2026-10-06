#!/bin/bash
# Zero golden image, TEST ONLY: runs inside a throwaway copy-on-write overlay of a finished Linux
# golden image booted in QEMU (golden/linux/verify.sh). It is never part of the image: it comes on a
# separate read-only disk (label ZEROGOLD) and is started by a unit injected through QEMU SMBIOS
# credentials, which systemd honours only inside VMs. This is the image's FIRST boot.
D=/run/zero-golden
exec >/dev/ttyS0 2>&1
set -u
EXP=$D/expect.json
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$EXP" "$1"; }
TIER=$(j 'd["tier"]'); DEFAULT_FILE=$(j 'd["default_file"]'); DEFAULT=$(j 'd["default"]'); DISK_BYTES=$(j 'd["disk_bytes"]')
SB_EXPECTED=$(j 'd["secure_boot"]')
PASS=0; FAIL=0; WARN=0
ok()   { echo "GOLDEN PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "GOLDEN FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { echo "GOLDEN WARN: $*"; WARN=$((WARN + 1)); }
hdr()  { echo; echo "=================== $* ==================="; }
wait_http() { local i=0; while [ "$i" -lt "$2" ]; do curl -fsS -o /dev/null --max-time 5 "$1" 2>/dev/null && return 0; sleep 3; i=$((i + 3)); done; return 1; }
chat() { curl -sS --max-time 1800 -H 'Content-Type: application/json' -d "$(python3 -c 'import json,sys;print(json.dumps({"message":sys.argv[1]}))' "$1")" http://127.0.0.1:7860/api/chat; }
KEYF=/etc/lecore-plus/llama-api-key
AUTH() { echo "Authorization: Bearer $(cat "$KEYF" 2>/dev/null)"; }
MODELS=/var/lib/lecore-plus/models

hdr "ZERO GOLDEN IMAGE FIRST BOOT ($TIER)"
echo "ZERO_GOLDEN_STARTED"
grep PRETTY_NAME /etc/os-release; uname -r
cat /usr/share/lecore-plus/versions.txt 2>/dev/null | head -n 8

hdr "first boot"
SB=$(mokutil --sb-state 2>&1 | tr '\n' ' ')
echo "secure boot: $SB"
if [ "$SB_EXPECTED" = True ]; then
  echo "$SB" | grep -q 'SecureBoot enabled' && ok "booted with Secure Boot on (shim -> GRUB -> kernel), as on Zero $TIER" || bad "Secure Boot not enforced: $SB"
fi
[ "$(systemctl show -p Result --value zero-growroot.service)" = success ] && ok "zero-growroot ran" || bad "zero-growroot did not succeed"
ROOTDEV=$(findmnt -no SOURCE /); DISK=/dev/$(lsblk -no PKNAME "$ROOTDEV" | head -n1)
DISKSZ=$(lsblk -bdno SIZE "$DISK"); ROOTSZ=$(df -B1 --output=size / | tail -n 1 | tr -d ' ')
[ "$DISKSZ" = "$DISK_BYTES" ] && ok "disk is the laptop-sized test drive ($DISKSZ bytes)" || bad "disk is $DISKSZ bytes, expected $DISK_BYTES"
[ "$ROOTSZ" -gt $((DISKSZ * 9 / 10)) ] && ok "root file system grew to fill the NVMe ($((ROOTSZ / 1000000000)) GB of $((DISKSZ / 1000000000)) GB)" \
  || bad "root did not grow (root $ROOTSZ, disk $DISKSZ)"
[ -s /etc/machine-id ] && ok "machine-id generated on first boot" || bad "machine-id empty"
U=$(awk -F: '$3>=1000 && $3<65000 {print $1}' /etc/passwd)
[ -z "$U" ] && ok "no user accounts baked in (first-boot setup creates the owner)" || bad "unexpected users: $U"
systemctl is-active -q gdm.service && ok "gdm active" || bad "gdm not active"
sleep 5; pgrep -f gnome-initial-setup >/dev/null && ok "gnome-initial-setup running (owner account creation)" || warn "gnome-initial-setup not seen yet"

hdr "models on the disk"
echo "/etc/lecore-plus/model: $(cat /etc/lecore-plus/model 2>/dev/null)"
[ "$(cat /etc/lecore-plus/model 2>/dev/null)" = "$DEFAULT_FILE" ] && ok "default model is the catalog default for $TIER ($DEFAULT -> $DEFAULT_FILE)" || bad "default model file is '$(cat /etc/lecore-plus/model 2>/dev/null)', expected $DEFAULT_FILE"
python3 - "$EXP" "$MODELS" <<'PY' && ok "every model file of the tier present with its catalog size; zero-models.json lists every model" || bad "models on the disk do not match the catalog"
import json, os, sys
e = json.load(open(sys.argv[1])); d = sys.argv[2]
bad = [f["file"] for f in e["files"] if not os.path.isfile(os.path.join(d, f["file"])) or os.path.getsize(os.path.join(d, f["file"])) != f["bytes"]]
man = json.load(open(os.path.join(d, "zero-models.json")))
ids = sorted(m["id"] for m in man["models"])
print("files: %d expected, %d bad %s; zero-models.json tier %s, %d models, default %s" % (len(e["files"]), len(bad), bad, man.get("tier"), len(ids), man.get("default")))
sys.exit(1 if bad or ids != sorted(e["models"]) or man.get("tier") != e["tier"] else 0)
PY
zero-model list 2>&1 | head -n 20
T=$SECONDS
for f in $(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print(" ".join(x["file"]+":"+x["sha256"] for x in e["files"] if x["id"]==e["default"]))' "$EXP"); do
  n=${f%%:*}; want=${f##*:}
  got=$(sha256sum "$MODELS/$n" | cut -d' ' -f1)
  [ "$got" = "$want" ] && ok "default model sha256 (read inside the booted laptop image): $n" || bad "default model $n sha256 $got != $want"
done
echo "hashed the default model in $((SECONDS - T)) s"

hdr "per-machine API key"
if systemctl cat zero-llama-key.service >/dev/null 2>&1; then
  KS=$(stat -c '%U:%G %a %s' "$KEYF" 2>/dev/null); echo "$KEYF: $KS"
  [ "$KS" = "root:lecore-api 640 64" ] && grep -qx "$(cat /etc/machine-id)" /etc/lecore-plus/llama-api-key.machine-id \
    && ok "API key generated on this first boot for this machine-id" || bad "API key file: '$KS'"
else
  bad "this base image has no per-machine API key (zero-llama-key.service): rebuild on a base with commit ccc4060"
fi

hdr "the default model starts by itself"
wait_http http://127.0.0.1:8080/health 1800 && ok "llama-server /health OK" || bad "llama-server not healthy"
systemctl is-active -q lecore-llama.service && ok "lecore-llama active (started at boot with the preloaded default model)" || bad "lecore-llama not active"
ARGS=$(ps -ww -o args= -p "$(systemctl show -p MainPID --value lecore-llama.service)" 2>/dev/null); echo "$ARGS"
echo "$ARGS" | grep -qE -- "--host 127\.0\.0\.1 --port 8080 -ngl 999 -m $MODELS/$DEFAULT_FILE( |$)" && ok "llama-server serves $DEFAULT_FILE on 127.0.0.1:8080" || bad "llama-server args: $ARGS"
U1=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v1/models)
U4=$(curl -s -o /dev/null -w '%{http_code}' -H "$(AUTH)" http://127.0.0.1:8080/v1/models)
[ "$U1" = 401 ] && [ "$U4" = 200 ] && ok "llama-server needs the per-machine key (no key -> 401, key -> 200)" || bad "llama-server key: no key $U1, key $U4"
T=$SECONDS
CC=$(curl -s --max-time 1800 -H 'Content-Type: application/json' -H "$(AUTH)" \
  -d '{"messages":[{"role":"user","content":"Reply with one short sentence: what is the capital of France?"}],"max_tokens":48,"temperature":0}' \
  http://127.0.0.1:8080/v1/chat/completions)
echo "$CC" | head -c 700; echo
echo "$CC" | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; assert (m.get("content") or "").strip() or (m.get("reasoning_content") or "").strip()' 2>/dev/null \
  && ok "the default model answers on 127.0.0.1:8080 ($((SECONDS - T)) s, CPU only in this VM)" || bad "no completion from the default model"

hdr "chat on 127.0.0.1:7860, through the model"
wait_http http://127.0.0.1:7860/ 600 && ok "chat answers HTTP on 127.0.0.1:7860" || bad "chat not reachable"
curl -s http://127.0.0.1:7860/ | grep -q '<title>Zero</title>' && ok "page title is Zero" || bad "page title"
slots() { curl -s -H "$(AUTH)" http://127.0.0.1:8080/slots | python3 -c 'import json,sys; print(sum(int(s.get("id_task",-1)) for s in json.load(sys.stdin)))' 2>/dev/null || echo x; }
VIA=0
for q in "Describe in one sentence how volcanoes on Io differ from those on Earth" "Write one short sentence about a lighthouse keeper named Brindle."; do
  T0=$(slots); T=$SECONDS
  R=$(chat "$q"); T1=$(slots)
  PROV=$(echo "$R" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provenance"))' 2>/dev/null)
  echo "chat> $q  ($((SECONDS - T)) s, slots $T0 -> $T1, provenance $PROV)"; echo "$R" | head -c 600; echo
  if echo "$R" | python3 -c 'import json,sys; assert json.load(sys.stdin).get("text")' 2>/dev/null && \
     { [ "$PROV" = model-cached ] || { [ "$T0" != x ] && [ "$T0" != "$T1" ]; }; }; then VIA=1; break; fi
done
[ "$VIA" = 1 ] && ok "the chat answers on 127.0.0.1:7860 through the default model (with the API key)" || bad "chat did not reach the model"
H1=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: zero.attacker.example:7860' http://127.0.0.1:7860/api/settings)
[ "$H1" = 403 ] && ok "chat refuses a DNS-rebinding Host (403)" || bad "foreign Host -> $H1"

hdr "zero egress"
UL=$(id -u lecore-llama); UC=$(id -u lecore-chat)
nft list chain inet zero_egress output > /tmp/zc 2>&1
grep -q "meta skuid $UL oifname != \"lo\" counter .*drop" /tmp/zc && grep -q "meta skuid $UC oifname != \"lo\" counter .*drop" /tmp/zc \
  && ok "nftables: non-loopback output dropped for lecore-llama and lecore-chat" || bad "per-user nftables rules missing"
for u in lecore-llama lecore-chat; do
  DENY=$(systemctl show -p IPAddressDeny --value "$u.service" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
  ALLOW=$(systemctl show -p IPAddressAllow --value "$u.service" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
  [ "$DENY" = "0.0.0.0/0 ::/0 " ] && [ "$ALLOW" = "127.0.0.0/8 ::1/128 " ] && ok "$u.service: IPAddressDeny=any, IPAddressAllow=localhost" || bad "$u.service deny='$DENY' allow='$ALLOW'"
done
NONLO=$(ss -H -tlnp | grep -E 'llama-server|python' | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):' || true)
[ -z "$NONLO" ] && ok "llama-server / leCore listen on 127.0.0.1 only" || bad "listening outside loopback: $NONLO"
code() { "$@" -sS -m 8 -o /dev/null -w '%{http_code}' 2>&1 | tail -n 1; }
reached() { case "$1" in 2*|3*|4*) return 0 ;; *) return 1 ;; esac; }
R0=$(code curl http://1.1.1.1/); reached "$R0" && ok "the OS reaches the internet (root -> 1.1.1.1: $R0)" || bad "root cannot reach the internet ($R0)"
for u in lecore-llama lecore-chat; do
  RU=$(code setpriv --reuid="$u" --regid="$u" --clear-groups -- curl http://1.1.1.1/)
  RL=$(code setpriv --reuid="$u" --regid="$u" --clear-groups -- curl http://127.0.0.1:7860/)
  ! reached "$RU" && reached "$RL" && ok "user $u: internet blocked, loopback works ($RU / $RL)" || bad "user $u: internet=$RU loopback=$RL"
  CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$u.service")
  sh -c 'sleep 2; exec curl -sS -m 8 -o /dev/null -w "%{http_code}" http://1.1.1.1/ 2>&1' > /tmp/cg 2>&1 &
  P=$!; echo "$P" > "$CG/cgroup.procs" 2>/dev/null; wait "$P"; RC_=$(tail -n 1 /tmp/cg)
  ! reached "$RC_" && ok "$u.service cgroup: internet blocked even for root ($RC_)" || bad "$u.service cgroup: internet=$RC_"
done

hdr "summary"
journalctl -b -u lecore-llama --no-pager -o cat | tail -n 12
RES=PASS; [ "$FAIL" -gt 0 ] && RES=FAIL
echo "ZERO_GOLDEN_RESULT: $RES tier=$TIER pass=$PASS fail=$FAIL warn=$WARN"
echo "ZERO_GOLDEN_DONE"
sleep 30
systemctl poweroff
