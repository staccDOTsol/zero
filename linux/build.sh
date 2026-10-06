#!/usr/bin/env bash
# Build the Zero (leCore+) Linux factory image: one raw GPT disk image (ESP + ext4 root), UEFI.
#
#   sudo linux/build.sh [OUT_DIR]          -> OUT_DIR/zero-linux.img (+ BUILDINFO.txt, packages.txt)
#
# Host requirements (Ubuntu 24.04 / Debian 12+): mmdebstrap, debian-archive-keyring, gdisk,
# dosfstools, e2fsprogs, curl, git, util-linux (losetup). Runs as root; needs loop devices.
# Downloads happen here, on the build host. The image itself never downloads anything.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=config.env
. "$HERE/config.env"

OUT=$(mkdir -p "${1:-$PWD/out}" && cd "${1:-$PWD/out}" && pwd)
WORK=${WORK:-$OUT/work}
IMG=$OUT/zero-linux.img
DL=$WORK/dl
R=$WORK/root

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
for t in mmdebstrap sgdisk mkfs.vfat mkfs.ext4 losetup curl git sha256sum dpkg-deb python3; do
  command -v "$t" >/dev/null || die "missing host tool: $t"
done

LOOP=""
cleanup() {
  set +e
  if mountpoint -q "$R" 2>/dev/null; then
    for m in run dev/pts dev sys proc boot/efi; do
      mountpoint -q "$R/$m" && umount -R "$R/$m" 2>/dev/null || true
    done
    umount -R "$R" 2>/dev/null || umount -Rl "$R"
  fi
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$DL" "$R"

# ------------------------------------------------------------------------------------------------
log "Fetching pinned inputs"
fetch() { # url dest sha256
  local url=$1 dest=$2 sum=$3
  if [ ! -f "$dest" ] || ! echo "$sum  $dest" | sha256sum -c --status; then
    curl -fL --retry 5 --retry-all-errors -o "$dest.tmp" "$url"
    mv "$dest.tmp" "$dest"
  fi
  echo "$sum  $dest" | sha256sum -c - || die "sha256 mismatch: $url"
}
fetch "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/$LLAMA_ASSET" \
      "$DL/$LLAMA_ASSET" "$LLAMA_SHA256"
fetch "$NVIDIA_REPO_URL/$NVIDIA_KEYRING_DEB" "$DL/$NVIDIA_KEYRING_DEB" "$NVIDIA_KEYRING_SHA256"
fetch "$DEBIAN_KEYRING_DEB_URL" "$DL/debian-archive-keyring.deb" "$DEBIAN_KEYRING_DEB_SHA256"
rm -rf "$DL/dak" && dpkg-deb -x "$DL/debian-archive-keyring.deb" "$DL/dak"
DEBIAN_KEYRING=$DL/dak/usr/share/keyrings/debian-archive-keyring.gpg
[ -s "$DEBIAN_KEYRING" ] || die "debian-archive-keyring.gpg not found in the keyring package"

if [ ! -d "$DL/lecore/.git" ]; then
  rm -rf "$DL/lecore"
  git init -q "$DL/lecore"
  git -C "$DL/lecore" remote add origin "$LECORE_REPO"
fi
git -C "$DL/lecore" fetch -q --depth 1 origin "$LECORE_COMMIT"
git -C "$DL/lecore" checkout -q --force FETCH_HEAD
[ "$(git -C "$DL/lecore" rev-parse HEAD)" = "$LECORE_COMMIT" ] || die "leCore commit mismatch"

mkdir -p "$DL/nltk"
NLTK_SUMS=""
for p in $NLTK_PACKAGES; do
  f="$DL/nltk/${p//\//_}.zip"
  [ -s "$f" ] || curl -fL --retry 5 --retry-all-errors -o "$f" \
      "https://raw.githubusercontent.com/nltk/nltk_data/$NLTK_DATA_COMMIT/packages/$p.zip"
  NLTK_SUMS+="$(sha256sum "$f" | cut -d' ' -f1)  $p.zip"$'\n'
done

# ------------------------------------------------------------------------------------------------
log "Creating $IMAGE_SIZE GPT disk image"
rm -f "$IMG"
truncate -s "$IMAGE_SIZE" "$IMG"
sgdisk --zap-all "$IMG" >/dev/null
sgdisk -n "1:1MiB:+${ESP_SIZE_MIB}MiB" -t 1:ef00 -c 1:"EFI System Partition" \
       -n 2:0:0 -t 2:8304 -c 2:"$ROOT_PART_LABEL" "$IMG"
sgdisk -p "$IMG"
LOOP=$(losetup -f --show -P "$IMG")
udevadm settle || true
for i in $(seq 1 20); do [ -b "${LOOP}p2" ] && break; sleep 0.5; done
[ -b "${LOOP}p2" ] || die "loop partitions did not appear"
ESP_DEV=${LOOP}p1
ROOT_DEV=${LOOP}p2

mkfs.vfat -F 32 -n "$ESP_LABEL" -i "$ESP_FS_ID" "$ESP_DEV"
# metadata_csum_seed / orphan_file are left off so every GRUB and e2fsprogs on the way can read it.
mkfs.ext4 -q -F -L "$ROOT_PART_LABEL" -U "$ROOT_FS_UUID" -O ^metadata_csum_seed,^orphan_file "$ROOT_DEV"
# make the host's udev publish /dev/disk/by-uuid for the new file systems (grub-mkconfig looks there)
udevadm trigger --action=change "$ESP_DEV" "$ROOT_DEV" || true
udevadm settle || true

mount "$ROOT_DEV" "$R"

# ------------------------------------------------------------------------------------------------
log "Bootstrapping Debian $DEBIAN_SUITE (minbase)"
# mmdebstrap accepts a target that only contains lost+found (a fresh file system).
mmdebstrap --mode=root --variant=minbase --format=directory \
  --components="$DEBIAN_COMPONENTS" \
  --aptopt='Acquire::Retries "5"' \
  --keyring="$DEBIAN_KEYRING" \
  --include=ca-certificates,debian-archive-keyring \
  "$DEBIAN_SUITE" "$R" \
  "deb $DEBIAN_MIRROR $DEBIAN_SUITE $DEBIAN_COMPONENTS"
mkdir -p "$R/boot/efi"
mount "$ESP_DEV" "$R/boot/efi"

# ------------------------------------------------------------------------------------------------
log "Staging leCore, llama.cpp, NLTK data and overlay into the target"
install -d -m 0755 "$R/opt/lecore-plus" "$R/opt/lecore-plus/llama" "$R/opt/lecore-plus/lecore" \
                   "$R/usr/share/nltk_data" "$R/usr/share/lecore-plus" "$R/tmp/zero-build"

# leCore: the exact tree of the pinned commit, no .git
git -C "$DL/lecore" archive --format=tar "$LECORE_COMMIT" | tar -x -C "$R/opt/lecore-plus/lecore"

# llama.cpp: find the directory holding llama-server inside the release tarball, copy it flat
rm -rf "$WORK/llama-x" && mkdir -p "$WORK/llama-x"
tar -xzf "$DL/$LLAMA_ASSET" -C "$WORK/llama-x"
LS=$(find "$WORK/llama-x" -type f -name llama-server | head -n1)
[ -n "$LS" ] || die "llama-server not found in $LLAMA_ASSET"
cp -a "$(dirname "$LS")/." "$R/opt/lecore-plus/llama/"
find "$WORK/llama-x" -maxdepth 3 -iname 'LICENSE*' -exec cp {} "$R/opt/lecore-plus/llama/" \; || true

# NLTK corpora (pinned nltk_data commit), unpacked where nltk looks by default
for p in $NLTK_PACKAGES; do
  d="$R/usr/share/nltk_data/$(dirname "$p")"
  install -d "$d"
  cp "$DL/nltk/${p//\//_}.zip" "$d/$(basename "$p").zip"
  (cd "$d" && python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall('.')" "$(basename "$p").zip")
done

cp "$DL/$NVIDIA_KEYRING_DEB" "$R/tmp/zero-build/"
cp -a "$HERE/overlay" "$R/tmp/zero-build/overlay"
cp "$HERE/chroot-setup.sh" "$R/tmp/zero-build/"
[ -f "$HERE/lecore-requirements.lock" ] && cp "$HERE/lecore-requirements.lock" "$R/tmp/zero-build/"
cat > "$R/tmp/zero-build/build.env" <<EOF
DEBIAN_SUITE=$DEBIAN_SUITE
DEBIAN_MIRROR=$DEBIAN_MIRROR
DEBIAN_SECURITY_MIRROR=$DEBIAN_SECURITY_MIRROR
DEBIAN_COMPONENTS="$DEBIAN_COMPONENTS"
NVIDIA_KEYRING_DEB=$NVIDIA_KEYRING_DEB
NVIDIA_DRIVER_VERSION=$NVIDIA_DRIVER_VERSION
LECORE_DROP_REQUIREMENTS="$LECORE_DROP_REQUIREMENTS"
ROOT_FS_UUID=$ROOT_FS_UUID
ESP_FS_ID=$ESP_FS_ID
HOSTNAME_DEFAULT=$HOSTNAME_DEFAULT
EOF

# ------------------------------------------------------------------------------------------------
log "Configuring the target in a chroot"
cp -L /etc/resolv.conf "$R/etc/resolv.conf"
mount -t proc proc "$R/proc"
mount --rbind /sys "$R/sys";  mount --make-rslave "$R/sys"
mount --rbind /dev "$R/dev";  mount --make-rslave "$R/dev"
mount -t tmpfs tmpfs "$R/run"
chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb \
  /bin/bash /tmp/zero-build/chroot-setup.sh

# ------------------------------------------------------------------------------------------------
log "Recording build information"
{
  echo "Zero (leCore+) Linux factory image"
  echo "built:            $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "source commit:    ${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  echo "base:             Debian $DEBIAN_SUITE ($(cat "$R/etc/debian_version")) + ${DEBIAN_SUITE}-backports"
  cat "$R/usr/share/lecore-plus/versions.txt"
  echo "llama.cpp:        $LLAMA_TAG $LLAMA_ASSET sha256 $LLAMA_SHA256"
  echo "leCore:           $LECORE_REPO @ $LECORE_COMMIT"
  echo "nltk_data:        nltk/nltk_data @ $NLTK_DATA_COMMIT"
  printf '%s' "$NLTK_SUMS" | sed 's/^/                  /'
  echo "python venv (pip freeze):"
  sed 's/^/                  /' "$R/usr/share/lecore-plus/venv-freeze.txt"
  echo "image:            $IMAGE_SIZE raw GPT, ESP ${ESP_SIZE_MIB} MiB (vfat $ESP_FS_ID), root ext4 UUID $ROOT_FS_UUID"
  df -h --output=size,used,avail "$R" | sed 's/^/root fs:          /'
} | tee "$OUT/BUILDINFO.txt"
cp "$OUT/BUILDINFO.txt" "$R/usr/share/lecore-plus/BUILDINFO.txt"
cp "$R/usr/share/lecore-plus/packages.txt" "$OUT/packages.txt"

# ------------------------------------------------------------------------------------------------
log "Unmounting and checking file systems"
rm -f "$R/etc/resolv.conf"
sync
for m in run dev sys proc boot/efi; do umount -R "$R/$m" || umount -Rl "$R/$m"; done
umount "$R"
e2fsck -f -y "$ROOT_DEV" || [ $? -le 1 ] || die "e2fsck failed"
fsck.vfat -a "$ESP_DEV" || true
losetup -d "$LOOP"; LOOP=""
sgdisk -v "$IMG"
log "Done: $IMG ($(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) allocated)"
