#!/usr/bin/env bash
# provision/linux-add-models.sh -- put catalog models onto a Zero Linux disk at imaging time.
#
# Runs on the IMAGING HOST (which has network). Downloads GGUF files from Hugging Face into a local
# cache, checks every file's size and sha256 against models/catalog.json, copies them into the
# target's /var/lib/lecore-plus/models/, re-checks the copies, writes the model manifest
# (zero-models.json) and the default model (/etc/lecore-plus/model). The laptop never downloads.
#
#   linux-add-models.sh --all <tier> [--default <id>] TARGET [options]
#   linux-add-models.sh --tier <tier> [--default <id>] TARGET [options] <model-id>...
#
# TARGET, exactly one of:
#   --target <dir>       root directory of a mounted Zero root file system (a mounted image
#                        partition, or a laptop NVMe attached to the imaging host)
#   --image <zero.img>   a Zero raw disk image file: grown as needed, mounted, filled, unmounted
#   --download-only      only fill and verify the cache (pre-fetch; no target)
#
# Options:
#   --catalog <file>     model menu (default: models/catalog.json next to this script's repo)
#   --cache <dir>        download cache on the imaging host (default: ./model-cache). Verified files
#                        are kept and reused; partial downloads resume.
#   --grow               with --target: first grow the partition + ext4 under <dir> to fill its disk
#   --reserve-gb <N>     keep at least N GiB free on the target after copying (default 2); with
#                        --image the image file is grown to make room
#   --no-verify-target   do not re-hash the copies on the target (faster, less safe)
#   --dry-run            print the plan and exit
#
# Default model (/etc/lecore-plus/model): --default <id> if given; with --all, the model whose
# "default_for" includes the tier; with an explicit id list, the first id. It is the first file
# of that model's build for the tier.
#
# Environment: HF_TOKEN  Hugging Face token for gated repos (sent only to huggingface.co, never logged)
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CATALOG=$HERE/../models/catalog.json
CACHE=$PWD/model-cache
ORIG_ARGS=("$@")
TIER="" ALL=0 DEFAULT_ID="" MODE="" TARGET="" IMAGE="" GROW=0 VERIFY_TARGET=1 DRY=0 RESERVE_GB=2
IDS=()

die() { echo "linux-add-models: $*" >&2; exit 1; }
say() { echo "==> $*"; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; TIER=${2:?--all needs a tier}; shift 2 ;;
    --tier) TIER=${2:?}; shift 2 ;;
    --default) DEFAULT_ID=${2:?}; shift 2 ;;
    --target) MODE=target; TARGET=${2:?}; shift 2 ;;
    --image) MODE=image; IMAGE=${2:?}; shift 2 ;;
    --download-only) MODE=download; shift ;;
    --catalog) CATALOG=${2:?}; shift 2 ;;
    --cache) CACHE=${2:?}; shift 2 ;;
    --grow) GROW=1; shift ;;
    --no-verify-target) VERIFY_TARGET=0; shift ;;
    --reserve-gb) RESERVE_GB=${2:?}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage 0 ;;
    --) shift; IDS+=("$@"); break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) IDS+=("$1"); shift ;;
  esac
done
case "$TIER" in pro|max|ultra) ;; *) die "tier must be pro, max or ultra (use --all <tier> or --tier <tier>)" ;; esac
[ -n "$MODE" ] || die "choose a target: --target <dir>, --image <file> or --download-only"
if [ "$MODE" = image ] && [ "$DRY" = 0 ] && [ -z "${ZERO_PRIVATE_MOUNTS:-}" ]; then
  # Mount the image in a private mount namespace, so no other namespace (systemd services) keeps a
  # copy of the mount and the file system can be checked and grown safely.
  [ "$(id -u)" = 0 ] || die "--image needs root (loop devices, mounting)"
  export ZERO_PRIVATE_MOUNTS=1
  exec unshare --mount --propagation private -- bash "$0" "${ORIG_ARGS[@]}"
fi
[ "$ALL" = 1 ] && [ ${#IDS[@]} -gt 0 ] && die "--all and an explicit model list are exclusive"
[ "$ALL" = 1 ] || [ ${#IDS[@]} -gt 0 ] || die "no models: pass model ids or --all <tier>"
[ -f "$CATALOG" ] || die "catalog not found: $CATALOG"
for t in python3 curl sha256sum; do command -v "$t" >/dev/null || die "missing tool: $t"; done
mkdir -p "$CACHE"; CACHE=$(cd "$CACHE" && pwd)

# ------------------------------------------------------------------------------------------------
# Plan: which files, from where, which default. Output lines: F<TAB>id<TAB>repo<TAB>path<TAB>bytes<TAB>sha256
#                                                            D<TAB>id<TAB>first-file-basename
PLAN=$(python3 - "$CATALOG" "$TIER" "$ALL" "$DEFAULT_ID" "${IDS[@]}" <<'PY'
import json, os, sys
cat, tier, all_, default_id, ids = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4], sys.argv[5:]
models = {m["id"]: m for m in json.load(open(cat))["models"]}
def build(mid):
    m = models.get(mid)
    if m is None: sys.exit("unknown model id: %s (not in %s)" % (mid, cat))
    b = (m.get("builds") or {}).get(tier)
    if not b: sys.exit("model %s has no build for tier %s" % (mid, tier))
    return b
if all_:
    ids = [mid for mid, m in models.items() if (m.get("builds") or {}).get(tier)]
    if not default_id:
        d = [mid for mid in ids if tier in (models[mid].get("default_for") or [])]
        if not d: sys.exit("no model in the catalog has default_for including %s; pass --default <id>" % tier)
        default_id = d[0]
elif not default_id:
    default_id = ids[0]
seen = {}
for mid in ids:
    b = build(mid)
    for f in b["files"]:
        base = os.path.basename(f["path"])
        if base in seen and seen[base] != f["sha256"]:
            sys.exit("two different files are both named %s; cannot place them in one models directory" % base)
        seen[base] = f["sha256"]
        print("F\t%s\t%s\t%s\t%d\t%s" % (mid, b["repo"], f["path"], int(f["bytes"]), f["sha256"].lower()))
db = build(default_id)
print("D\t%s\t%s" % (default_id, os.path.basename(db["files"][0]["path"])))
PY
) || die "planning failed"

DEF_ID=$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="D"{print $2}')
DEF_FILE=$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="D"{print $3}')
TOTAL=$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="F" && !seen[$4]++ {s+=$5} END{printf "%.0f", s}')
NFILES=$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="F"' | wc -l | tr -d ' ')
say "tier $TIER: $NFILES file(s), $(awk -v b="$TOTAL" 'BEGIN{printf "%.1f", b/1e9}') GB; default model $DEF_ID ($DEF_FILE)"
printf '%s\n' "$PLAN" | awk -F'\t' '$1=="F"{printf "    %-28s %8.2f GB  %s/%s\n", $2, $5/1e9, $3, $4}'
[ "$DRY" = 1 ] && exit 0

# ------------------------------------------------------------------------------------------------
# Download + verify into the cache
hf_curl() { # curl with the HF token in a header (from a here-doc, never on the command line)
  if [ -n "${HF_TOKEN:-}" ]; then
    curl --config - "$@" <<EOF
header = "Authorization: Bearer ${HF_TOKEN}"
EOF
  else
    curl "$@"
  fi
}
fetch() { # repo path bytes sha256 -> prints cache path
  local repo=$1 path=$2 bytes=$3 sha=$4
  local dest="$CACHE/$repo/$path" url="https://huggingface.co/$repo/resolve/main/$path"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ "$(stat -c %s "$dest")" = "$bytes" ]; then
    if [ -f "$dest.sha256" ] && [ "$(cat "$dest.sha256")" = "$sha" ] && [ "$dest.sha256" -nt "$dest" ]; then
      echo "$dest"; return 0
    fi
  else
    rm -f "$dest"
    say "downloading $repo/$path ($(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1e9}') GB)" >&2
    local try
    for try in 1 2 3 4 5; do
      if hf_curl -fL --retry 10 --retry-all-errors --retry-delay 5 --connect-timeout 30 \
           -C - -o "$dest.part" "$url" >&2; then break; fi
      echo "  download attempt $try failed; retrying" >&2; sleep 10
    done
    [ -f "$dest.part" ] && [ "$(stat -c %s "$dest.part")" = "$bytes" ] || \
      die "$repo/$path: size mismatch after download (want $bytes, got $(stat -c %s "$dest.part" 2>/dev/null || echo 0))"
    mv "$dest.part" "$dest"
  fi
  echo "  verifying sha256 of $(basename "$path")" >&2
  local got; got=$(sha256sum "$dest" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    mv "$dest" "$dest.bad"
    die "$repo/$path: sha256 mismatch (want $sha, got $got). The file changed upstream; run models/check.py."
  fi
  echo "$sha" > "$dest.sha256"
  echo "$dest"
}

declare -A SRC
while IFS=$'\t' read -r kind id repo path bytes sha; do
  [ "$kind" = F ] || continue
  SRC["$repo/$path"]=$(fetch "$repo" "$path" "$bytes" "$sha")
done <<< "$PLAN"
say "all files present in the cache and verified"
[ "$MODE" = download ] && exit 0

# ------------------------------------------------------------------------------------------------
# Target preparation
[ "$(id -u)" = 0 ] || die "--target/--image need root (file ownership, mounting)"
LOOP="" MNT=""
cleanup() {
  set +e
  [ -n "$MNT" ] && mountpoint -q "$MNT" && { sync; umount "$MNT"; }
  [ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
  [ -n "$LOOP" ] && losetup -d "$LOOP"
}
trap cleanup EXIT

need_bytes() { # bytes still to copy into ROOT
  local root=$1 n=0
  while IFS=$'\t' read -r kind id repo path bytes sha; do
    [ "$kind" = F ] || continue
    local d="$root/var/lib/lecore-plus/models/$(basename "$path")"
    [ -f "$d" ] && [ "$(stat -c %s "$d")" = "$bytes" ] && continue
    n=$((n + bytes))
  done <<< "$(printf '%s\n' "$PLAN" | awk -F'\t' '$1!="F" || !seen[$4]++')"
  echo "$n"
}
free_bytes() { df -B1 --output=avail "$1" | tail -n 1 | tr -d ' '; }
SLACK=$((RESERVE_GB * 1024 * 1024 * 1024))

root_partition_of_loop() { # print the Zero root partition device of a loop device
  local dev
  for dev in $(lsblk -nrpo NAME "$1" | tail -n +2); do
    [ "$(lsblk -no PARTLABEL "$dev")" = zero-root ] && { echo "$dev"; return; }
  done
  echo "${1}p2"
}

if [ "$MODE" = image ]; then
  for t in losetup sgdisk growpart e2fsck resize2fs; do command -v "$t" >/dev/null || die "missing tool: $t"; done
  [ -f "$IMAGE" ] || die "image not found: $IMAGE"
  MNT=$(mktemp -d)
  LOOP=$(losetup -f --show -P "$IMAGE"); udevadm settle 2>/dev/null || sleep 1
  PART=$(root_partition_of_loop "$LOOP")
  mount "$PART" "$MNT"
  NEED=$(need_bytes "$MNT"); FREE=$(free_bytes "$MNT")
  if [ "$NEED" -gt $((FREE - SLACK)) ]; then
    GROW_BY=$(( (NEED - FREE + SLACK + 1073741824 + 1073741823) / 1073741824 ))
    say "growing $IMAGE by ${GROW_BY} GiB"
    umount "$MNT"; losetup -d "$LOOP"; LOOP=""
    truncate -s "+${GROW_BY}G" "$IMAGE"
    sgdisk -e "$IMAGE" >/dev/null            # move the backup GPT to the new end
    LOOP=$(losetup -f --show -P "$IMAGE"); udevadm settle 2>/dev/null || sleep 1
    PART=$(root_partition_of_loop "$LOOP")
    growpart "$LOOP" "${PART##*p}" || [ $? = 1 ]
    e2fsck -f -y "$PART" || [ $? -le 1 ]
    resize2fs "$PART"
    mount "$PART" "$MNT"
  fi
  ROOT=$MNT
else
  ROOT=$(cd "$TARGET" && pwd)
  if [ "$GROW" = 1 ]; then
    for t in growpart resize2fs findmnt lsblk; do command -v "$t" >/dev/null || die "missing tool: $t"; done
    dev=$(readlink -f "$(findmnt -n -o SOURCE --target "$ROOT")")
    disk=$(lsblk -n -o PKNAME "$dev" | head -n 1)
    num=$(cat "/sys/class/block/$(basename "$dev")/partition")
    say "growing $dev to fill /dev/$disk"
    command -v sgdisk >/dev/null && sgdisk -e "/dev/$disk" >/dev/null 2>&1 || true
    growpart "/dev/$disk" "$num" || [ $? = 1 ]
    resize2fs "$dev"
  fi
fi

[ -d "$ROOT/opt/lecore-plus" ] && [ -d "$ROOT/etc" ] || die "$ROOT does not look like a Zero root file system"
MODELS=$ROOT/var/lib/lecore-plus/models
install -d -m 0755 "$MODELS" "$ROOT/etc/lecore-plus"
NEED=$(need_bytes "$ROOT"); FREE=$(free_bytes "$MODELS")
[ "$NEED" -le $((FREE - SLACK)) ] || die "not enough space on the target: need $((NEED/1000000000)) GB + ${RESERVE_GB} GiB reserve, free $((FREE/1000000000)) GB (use --grow or a bigger disk)"

# ------------------------------------------------------------------------------------------------
# Copy + verify
while IFS=$'\t' read -r kind id repo path bytes sha; do
  [ "$kind" = F ] || continue
  base=$(basename "$path"); dst="$MODELS/$base"; src=${SRC["$repo/$path"]}
  if [ -f "$dst" ] && [ "$(stat -c %s "$dst")" = "$bytes" ]; then
    if [ "$VERIFY_TARGET" = 0 ] || [ "$(sha256sum "$dst" | cut -d' ' -f1)" = "$sha" ]; then
      echo "  present: $base"; continue
    fi
  fi
  say "copying $base"
  cp "$src" "$dst.zero-tmp"
  sync -f "$dst.zero-tmp" 2>/dev/null || sync
  if [ "$VERIFY_TARGET" = 1 ]; then
    got=$(sha256sum "$dst.zero-tmp" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$dst.zero-tmp"; die "$base: copy on the target is corrupt (sha256 $got)"; }
  fi
  chown 0:0 "$dst.zero-tmp"; chmod 0644 "$dst.zero-tmp"
  mv -f "$dst.zero-tmp" "$dst"
done <<< "$(printf '%s\n' "$PLAN" | awk -F'\t' '$1!="F" || !seen[$4]++')"

# Manifest (merged with what is already on the target) + default model
python3 - "$CATALOG" "$TIER" "$MODELS/zero-models.json" "$DEF_FILE" <<PY
import json, os, sys, datetime
cat, tier, out, default = sys.argv[1:5]
catalog = json.load(open(cat))
models = {m["id"]: m for m in catalog["models"]}
ids = """$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="F"{print $2}' | awk '!s[$0]++')""".split()
man = {"tier": tier, "models": []}
if os.path.exists(out):
    old = json.load(open(out))
    if old.get("tier") not in (None, tier):
        sys.exit("target already holds models for tier %s, not %s" % (old.get("tier"), tier))
    man["models"] = [e for e in old.get("models", []) if e["id"] not in ids]
for mid in ids:
    m, b = models[mid], models[mid]["builds"][tier]
    man["models"].append({"id": mid, "name": m.get("name"), "maker": m.get("maker"), "license": m.get("license"),
                          "uncensored": m.get("uncensored"), "quant": b.get("quant"), "speed": b.get("speed"),
                          "repo": b["repo"],
                          "files": [{"name": os.path.basename(f["path"]), "path": f["path"],
                                     "bytes": f["bytes"], "sha256": f["sha256"]} for f in b["files"]]})
man["default"] = default
man["catalog_updated"] = catalog.get("updated")
man["provisioned"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tmp = out + ".tmp"
json.dump(man, open(tmp, "w"), indent=1)
os.chmod(tmp, 0o644); os.replace(tmp, out)
PY
[ -f "$MODELS/$DEF_FILE" ] || die "default model file $DEF_FILE is not on the target"
printf '%s\n' "$DEF_FILE" > "$ROOT/etc/lecore-plus/model.tmp"
chmod 0644 "$ROOT/etc/lecore-plus/model.tmp"
mv -f "$ROOT/etc/lecore-plus/model.tmp" "$ROOT/etc/lecore-plus/model"
sync
say "done: $(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="F"{print $2}' | sort -u | wc -l | tr -d ' ') model(s) in $MODELS; default: $DEF_ID -> /etc/lecore-plus/model = $DEF_FILE"
df -h "$MODELS" | tail -n 1
