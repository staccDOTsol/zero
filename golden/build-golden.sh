#!/usr/bin/env bash
# golden/build-golden.sh -- build all Zero golden images (Linux + Windows x Pro/Max/Ultra) in one command.
#
#   golden/build-golden.sh [--linux-tag T] [--windows-tag T] [--tiers '["pro","max","ultra"]']
#                          [--os linux|windows|both] [--laptop TARGET] [--no-upload] [--wait]
#
#   --laptop: a windows/drivers.json target for the Windows images instead of each tier's default laptop
#             (hp-zbook-ultra-g1a for pro/max, lenovo-p16-gen3 for ultra), e.g.
#             --os windows --tiers '["pro","max"]' --laptop asus-rog-flow-z13-gz302ea
#             -> zero-{pro,max}-windows-asus-rog-flow-z13.img.zst. The Linux image is the same for every
#             laptop of a tier, so the option does not apply to it.
#
# Runs from a checkout of staccDOTsol/lecore-plus (the source of truth) with `gh` logged in to an
# account that can run workflows in staccDOTsol/lecore-plus and kekloldyormarket/zero-golden.
#   1. picks the newest base releases (or the tags given): linux-* of staccDOTsol/lecore-plus,
#      windows-* of kekloldyormarket/zero-golden (the Windows ISOs are built there: private, org-billed)
#   2. stages them into the private object store (workflow golden-stage in each repo)
#   3. copies golden/, provision/ and models/ of this checkout's HEAD into kekloldyormarket/zero-golden
#      (golden/ci/golden-*.yml -> .github/workflows/) and pushes
#   4. dispatches golden-linux and golden-windows there: one job per tier x OS on the zero-golden-32
#      runners (96 cores, 2 TB, KVM), in parallel. Each job downloads every model of its tier, builds
#      the image, re-reads every model's sha256 from it, boots it for its first boot in QEMU/KVM
#      (default model served and answering, chat answering through it, zero-egress confinement), and
#      streams it with a manifest to the object store, {linux,windows}/<base tag>/ in the bucket.
#      The store is any S3-compatible service, set by repo variables S3_ENDPOINT_URL (empty = AWS S3),
#      STORE_BUCKET, STORE_REGION and secrets STORE_ACCESS_KEY_ID / STORE_SECRET_ACCESS_KEY on both
#      repos (golden/lib/store.sh). golden-store-check tests it.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
SOURCE_REPO=staccDOTsol/lecore-plus
BUILD_REPO=kekloldyormarket/zero-golden
LINUX_TAG="" WINDOWS_TAG="" TIERS='["pro","max","ultra"]' OS=both UPLOAD=true WAIT=0 LAPTOP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --linux-tag) LINUX_TAG=$2; shift 2 ;;
    --windows-tag) WINDOWS_TAG=$2; shift 2 ;;
    --tiers) TIERS=$2; shift 2 ;;
    --os) OS=$2; shift 2 ;;
    --laptop) LAPTOP=$2; shift 2 ;;
    --no-upload) UPLOAD=false; shift ;;
    --wait) WAIT=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
newest() { # repo prefix
  gh release list -R "$1" --limit 100 --json tagName,createdAt,isDraft \
    -q "[.[] | select(.isDraft | not) | select(.tagName | startswith(\"$2\"))] | sort_by(.createdAt) | last | .tagName"
}
latest_run() { # repo workflow
  sleep 8; gh run list -R "$1" -w "$2" --limit 1 --json databaseId,url -q '.[0].url'
}
[ -z "$(git -C "$SRC" status --porcelain -- golden provision models)" ] || { echo "commit golden/, provision/, models/ first" >&2; exit 1; }
SHA=$(git -C "$SRC" rev-parse HEAD)

WIN_STAGE=none LIN_STAGE=none
if [ "$OS" != windows ]; then
  [ -n "$LINUX_TAG" ] || LINUX_TAG=$(newest "$SOURCE_REPO" linux-)
  echo "Linux base:   $SOURCE_REPO $LINUX_TAG"; LIN_STAGE=$LINUX_TAG
fi
if [ "$OS" != linux ]; then
  [ -n "$WINDOWS_TAG" ] || WINDOWS_TAG=$(newest "$BUILD_REPO" windows-)
  echo "Windows base: $BUILD_REPO $WINDOWS_TAG"; WIN_STAGE=$WINDOWS_TAG
fi

echo "syncing $BUILD_REPO from $SOURCE_REPO@${SHA:0:7}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
gh repo clone "$BUILD_REPO" "$TMP/b" -- -q
rm -rf "$TMP/b/golden" "$TMP/b/provision" "$TMP/b/models" "$TMP/b/windows"
mkdir -p "$TMP/b/.github/workflows"
cp -R "$SRC/golden" "$SRC/provision" "$SRC/models" "$SRC/windows" "$TMP/b/"
cp "$SRC/golden/ci/golden-linux.yml" "$SRC/golden/ci/golden-windows.yml" "$SRC/golden/ci/golden-store-check.yml" \
   "$SRC/golden/ci/golden-windows-smoke.yml" "$SRC/windows/ci/windows-image.yml" "$SRC/.github/workflows/golden-stage.yml" \
   "$TMP/b/.github/workflows/"
git -C "$TMP/b" add -A
git -C "$TMP/b" diff --cached --quiet || git -C "$TMP/b" commit -q -m "sync golden build from $SOURCE_REPO@${SHA:0:7}"
git -C "$TMP/b" push -q origin HEAD

# the bases into the object store (sha256-checked; parts already there are skipped): the linux-*
# release from this repo, the windows-* release from the build repo (where it is built)
stage() { # repo windows_tag linux_tag
  gh workflow run golden-stage.yml -R "$1" -f windows_tag="$2" -f linux_tag="$3"
  local run; run=$(latest_run "$1" golden-stage.yml); echo "staging in $1: $run"
  gh run watch -R "$1" "${run##*/}" --exit-status >/dev/null
}
[ "$LIN_STAGE" = none ] || stage "$SOURCE_REPO" none "$LIN_STAGE"
[ "$WIN_STAGE" = none ] || stage "$BUILD_REPO" "$WIN_STAGE" none

if [ "$OS" != windows ]; then
  gh workflow run golden-linux.yml -R "$BUILD_REPO" -f base_repo=store -f base_tag="$LINUX_TAG" -f tiers="$TIERS" -f upload="$UPLOAD"
  echo "golden-linux:   $(latest_run "$BUILD_REPO" golden-linux.yml)"
fi
if [ "$OS" != linux ]; then
  gh workflow run golden-windows.yml -R "$BUILD_REPO" -f windows_tag="$WINDOWS_TAG" -f tiers="$TIERS" -f upload="$UPLOAD" ${LAPTOP:+-f laptop="$LAPTOP"}
  echo "golden-windows: $(latest_run "$BUILD_REPO" golden-windows.yml)"
fi
if [ "$WAIT" = 1 ]; then
  for w in golden-linux.yml golden-windows.yml; do
    id=$(gh run list -R "$BUILD_REPO" -w "$w" --limit 1 --json databaseId -q '.[0].databaseId')
    [ -n "$id" ] && gh run watch -R "$BUILD_REPO" "$id" || true
  done
fi
echo "images + manifests: {linux/$LINUX_TAG,windows/$WINDOWS_TAG}/ in $(gh variable get STORE_BUCKET -R "$BUILD_REPO" 2>/dev/null || echo the store bucket)"
