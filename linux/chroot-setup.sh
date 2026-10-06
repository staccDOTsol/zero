#!/bin/bash
# Runs INSIDE the target root (chroot) during linux/build.sh. Installs and configures everything.
set -Eeuo pipefail
trap 'echo "chroot-setup.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR
. /tmp/zero-build/build.env
B=/tmp/zero-build
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
          -o APT::Install-Recommends=false -o Acquire::Retries=5)
apt_install() { apt-get "${APT_OPTS[@]}" install "$@"; }
log() { printf '\n--> %s\n' "$*"; }

# Nothing may start services inside the build chroot.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d

# ------------------------------------------------------------------------------------------------
log "APT sources: $DEBIAN_SUITE, -updates, -security, -backports"
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $DEBIAN_SUITE $DEBIAN_SUITE-updates $DEBIAN_SUITE-backports
Components: $DEBIAN_COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $DEBIAN_SECURITY_MIRROR
Suites: $DEBIAN_SUITE-security
Components: $DEBIAN_COMPONENTS
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
apt-get update

# ------------------------------------------------------------------------------------------------
log "Base system"
apt_install systemd-sysv dbus dbus-user-session udev kmod sudo locales-all tzdata keyboard-configuration \
  console-setup ca-certificates curl openssl nftables iproute2 network-manager wpasupplicant iw wireless-regdb \
  systemd-timesyncd fwupd \
  rfkill bluez cloud-guest-utils fdisk gdisk e2fsprogs dosfstools zstd xz-utils pciutils usbutils \
  less nano bash-completion python3 python3-venv mokutil efibootmgr initramfs-tools dconf-cli \
  xdg-user-dirs xdg-utils polkitd pkexec accountsservice

log "Kernel, firmware and Mesa from $DEBIAN_SUITE-backports"
apt_install -t "$DEBIAN_SUITE-backports" \
  linux-image-amd64 linux-headers-amd64 \
  firmware-linux-free firmware-amd-graphics firmware-intel-graphics firmware-intel-misc \
  firmware-iwlwifi firmware-mediatek firmware-atheros firmware-realtek firmware-misc-nonfree \
  alsa-ucm-conf \
  mesa-vulkan-drivers libgl1-mesa-dri libegl-mesa0 libglx-mesa0 libgbm1 mesa-va-drivers \
  libvulkan1 vulkan-tools
apt_install firmware-sof-signed intel-microcode amd64-microcode

log "Boot loader (shim + signed GRUB)"
apt_install grub-efi-amd64 grub-efi-amd64-signed shim-signed

log "GNOME desktop (Debian gnome-core + first-boot setup)"
apt_install gnome-core gdm3 gnome-initial-setup network-manager-gnome \
  xdg-desktop-portal-gnome xdg-desktop-portal-gtk xdg-user-dirs-gtk xwayland ibus \
  switcheroo-control power-profiles-daemon bolt upower iio-sensor-proxy low-memory-monitor \
  fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-dejavu-core \
  chromium chromium-l10n nvtop

# ------------------------------------------------------------------------------------------------
KVER=$(dpkg-query -W -f='${Depends}\n' linux-image-amd64 | grep -o 'linux-image-[^ ,]*' | head -n1 | sed 's/^linux-image-//')
[ -d "/lib/modules/$KVER" ] || KVER=$(ls /lib/modules | sort -V | tail -n1)
[ -d "/usr/src/linux-headers-$KVER" ] || { echo "headers for $KVER missing"; exit 1; }
echo "target kernel: $KVER"

log "NVIDIA open kernel modules $NVIDIA_DRIVER_VERSION (NVIDIA's Debian 13 repository, DKMS)"
dpkg -i "$B/$NVIDIA_KEYRING_DEB"
apt-get update
V=$NVIDIA_DRIVER_VERSION
apt_install dkms nvidia-driver-pinning-615 "nvidia-open=$V" "nvidia-driver=$V" "nvidia-driver-cuda=$V" "nvidia-kernel-open-dkms=$V" \
  "nvidia-settings=$V" "nvidia-xconfig=$V" "nvidia-vulkan-icd=$V" "firmware-nvidia-gsp=$V"
NVKO=$(find "/lib/modules/$KVER" -name 'nvidia.ko*' | head -n1 || true)
if [ -z "$NVKO" ]; then
  echo "nvidia.ko not built for $KVER by the package hooks; running dkms autoinstall"
  dkms autoinstall -k "$KVER" || true
  NVKO=$(find "/lib/modules/$KVER" -name 'nvidia.ko*' | head -n1 || true)
fi
dkms status
[ -n "$NVKO" ] || { echo "FATAL: NVIDIA open kernel module did not build for $KVER"; \
  find /var/lib/dkms -name make.log -exec tail -n 60 {} \; ; exit 1; }
modinfo -F license "$NVKO" | grep -q 'Dual MIT/GPL' || { echo "FATAL: $NVKO is not the open module"; exit 1; }
modinfo "$NVKO" | grep -E '^(filename|version|license|vermagic|signer|sig_key):' || true
# DKMS does not sign in a chroot. If it ever made a signing key here, that private key must not ship (it
# would be the same on every laptop): remove it. zero-nvidia-secureboot makes a per-machine key.
rm -f /var/lib/dkms/mok.key /var/lib/dkms/mok.pub

# ------------------------------------------------------------------------------------------------
log "Firmware evidence for the three laptops"
fwcheck() { # module regex -> lists the firmware files the module declares that match, and whether present
  local mod=$1 re=$2 miss=0 n=0 f
  for f in $(modinfo -k "$KVER" -F firmware "$mod" 2>/dev/null | grep -E "$re" | sort -u); do
    n=$((n + 1))
    if compgen -G "/lib/firmware/${f}*" >/dev/null; then echo "  ok      $f"; else echo "  MISSING $f"; miss=$((miss + 1)); fi
  done
  echo "  $mod [$re]: $n declared, $miss missing"
  [ "$n" -gt 0 ] || return 99
  [ "$miss" = 0 ]
}
echo "AMD Strix Halo (gfx1151 = GC 11.5.1):"
fwcheck amdgpu '11_5_1' || { echo "FATAL: gfx1151 firmware missing"; exit 1; }
fwcheck amdgpu 'dcn_3_5|vcn_4_0_[56]|psp_14_0|sdma_6_1|smu_14_0' || echo "  (some optional AMD APU firmware missing)"
echo "Intel Arrow Lake graphics:"; fwcheck i915 'mtl_|arl_' || true; fwcheck xe 'mtl_|arl_|lnl_' || true
echo "Wi-Fi:"; fwcheck iwlwifi 'gl-c0-fm|bz-b0-fm|bz-b0-gf|sc-a0' || true
fwcheck mt7925e 'mt7925' || true; fwcheck ath12k 'WCN7850' || true
echo "NVIDIA GSP firmware:"; ls -la /lib/firmware/nvidia/*/ 2>/dev/null | head -n 20

# ------------------------------------------------------------------------------------------------
log "leCore Python environment"
python3 -m venv /opt/lecore-plus/venv
REQ=/tmp/zero-build/lecore-requirements.txt
cp /opt/lecore-plus/lecore/requirements.txt "$REQ"
for d in $LECORE_DROP_REQUIREMENTS; do sed -i -E "/^[[:space:]]*${d}([[:space:]]|[<>=!~;\[]|$)/d" "$REQ"; done
echo "requirements installed:"; grep -vE '^\s*(#|$)' "$REQ"
CONSTRAINT=()
[ -f /tmp/zero-build/lecore-requirements.lock ] && CONSTRAINT=(-c /tmp/zero-build/lecore-requirements.lock)
/opt/lecore-plus/venv/bin/pip install --no-cache-dir --disable-pip-version-check --upgrade "pip==26.2.1"
/opt/lecore-plus/venv/bin/pip install --no-cache-dir --disable-pip-version-check -r "$REQ" "${CONSTRAINT[@]}"
/opt/lecore-plus/venv/bin/pip freeze --all > /usr/share/lecore-plus/venv-freeze.txt
cat /usr/share/lecore-plus/venv-freeze.txt
# byte-compile leCore so the read-only install starts fast (a few research scripts may not compile)
/opt/lecore-plus/venv/bin/python -m compileall -q -j 0 /opt/lecore-plus/lecore >/dev/null 2>&1 || true
/opt/lecore-plus/venv/bin/python -m compileall -q -j 0 /opt/lecore-plus/venv >/dev/null 2>&1 || true
# chat_server.py saves uploaded memories next to itself; point that at writable state
rm -rf /opt/lecore-plus/lecore/memories
ln -s /var/lib/lecore-plus/chat/memories /opt/lecore-plus/lecore/memories
# import check (no network, no model)
cd /opt/lecore-plus/lecore && PYTHONHASHSEED=0 HOME=/tmp MPLCONFIGDIR=/tmp/mpl \
  /opt/lecore-plus/venv/bin/python -c "import lecore, chat_server; print('leCore', lecore.__version__, 'imports OK')"
cd /

log "llama.cpp check"
chmod 0755 /opt/lecore-plus/llama/llama-server
export LD_LIBRARY_PATH=/opt/lecore-plus/llama
ls -la /opt/lecore-plus/llama
if ldd /opt/lecore-plus/llama/llama-server | grep 'not found'; then
  echo "missing libraries for llama-server"; exit 1
fi
/opt/lecore-plus/llama/llama-server --version 2>&1 | tail -n 5 || true
unset LD_LIBRARY_PATH

# ------------------------------------------------------------------------------------------------
log "Overlay files"
chown -R root:root "$B/overlay"
find "$B/overlay" -type d -exec chmod 0755 {} +
cp -a "$B/overlay/." /
chmod 0755 /opt/lecore-plus/bin/* /usr/local/sbin/* /usr/lib/zero/* /etc/initramfs-tools/scripts/init-top/*
chmod 0440 /etc/sudoers.d/* 2>/dev/null || true

log "Users and directories"
# one dedicated system user per service: lecore-llama (llama-server), lecore-chat (leCore chat)
for u in lecore-llama lecore-chat; do
  getent group "$u" >/dev/null || groupadd --system "$u"
  id "$u" >/dev/null 2>&1 || useradd --system --gid "$u" --home-dir /var/lib/lecore-plus --no-create-home \
    --shell /usr/sbin/nologin --comment "Zero local AI ($u)" "$u"
done
usermod -a -G render,video lecore-llama
# lecore-api: may read the per-machine llama-server API key (/etc/lecore-plus/llama-api-key, generated at
# first boot by zero-llama-key.service; never baked into the image)
getent group lecore-api >/dev/null || groupadd --system lecore-api
usermod -a -G lecore-api lecore-llama
usermod -a -G lecore-api lecore-chat
id lecore-llama; id lecore-chat

log "Per-user egress rules (nftables): lecore-llama / lecore-chat may only use loopback"
sed -e "s/@UID_LLAMA@/$(id -u lecore-llama)/g" -e "s/@UID_CHAT@/$(id -u lecore-chat)/g" \
  /usr/lib/zero/nftables-zero.nft.in > /etc/nftables.conf
chmod 0755 /etc/nftables.conf
cat /etc/nftables.conf
nft -c -f /etc/nftables.conf && echo "nftables.conf syntax OK" || echo "WARNING: nft -c could not check the rules on this build host"
install -d -m 0755 -o root -g root /var/lib/lecore-plus /var/lib/lecore-plus/models /etc/lecore-plus /var/lib/zero
rm -f /etc/lecore-plus/model            # no model in the base image; provision/ writes it
rm -f /etc/lecore-plus/llama-api-key /etc/lecore-plus/llama-api-key.machine-id   # generated per machine at boot

log "System identity, locale, time zone, fstab"
echo "$HOSTNAME_DEFAULT" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_DEFAULT
::1		localhost ip6-localhost ip6-loopback
EOF
echo 'LANG=en_US.UTF-8' > /etc/default/locale
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime; echo Etc/UTC > /etc/timezone
ESP_UUID="${ESP_FS_ID:0:4}-${ESP_FS_ID:4:4}"
cat > /etc/fstab <<EOF
# <file system>                            <mount point> <type> <options>            <dump> <pass>
UUID=$ROOT_FS_UUID  /             ext4   errors=remount-ro    0      1
UUID=$ESP_UUID                             /boot/efi     vfat   umask=0077           0      1
EOF
# os-release: user-visible name and logo (first-boot welcome page, Settings > About). ID stays debian
# so tools keep working.
sed -i -E -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Zero (Debian GNU\/Linux 13 trixie)"/' \
          -e 's/^NAME=.*/NAME="Zero"/' -e '/^LOGO=/d' /usr/lib/os-release
echo 'LOGO=zero' >> /usr/lib/os-release
cat /usr/lib/os-release
# GDM login screen: no Debian logo
if [ -f /etc/gdm3/greeter.dconf-defaults ]; then
  printf "\n[org/gnome/login-screen]\nlogo=''\n" >> /etc/gdm3/greeter.dconf-defaults
  [ -x /usr/share/gdm/generate-config ] && /usr/share/gdm/generate-config || true
fi

log "systemd units"
systemctl enable nftables.service zero-llama-key.service lecore-llama.service lecore-llama.path lecore-chat.service \
  zero-growroot.service zero-gpu-memory.service NetworkManager.service gdm.service systemd-timesyncd.service
systemctl set-default graphical.target
# systemd-firstboot would prompt on the console (GNOME's first-boot setup does this job);
# nvidia-persistenced is not needed for Vulkan and would fail on the AMD laptops.
for u in systemd-firstboot.service nvidia-persistenced.service; do
  systemctl mask "$u"
done
for u in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service nvidia-suspend-then-hibernate.service; do
  [ -e "/usr/lib/systemd/system/$u" ] && systemctl enable "$u" || true
done

log "dconf, icons, GRUB defaults"
dconf update
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
update-desktop-database /usr/share/applications 2>/dev/null || true

# ------------------------------------------------------------------------------------------------
log "initramfs and boot loader"
update-initramfs -c -k "$KVER" 2>/dev/null || update-initramfs -u -k "$KVER"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian \
  --removable --uefi-secure-boot --no-nvram
# no shim fallback (fbx64.efi) on the removable path: boot straight shim -> GRUB, no NVRAM writes
rm -f /boot/efi/EFI/BOOT/fbx64.efi
# The signed GRUB reads grub.cfg from /EFI/debian (its built-in prefix) or next to itself.
mkdir -p /boot/efi/EFI/debian
for d in /boot/efi/EFI/BOOT /boot/efi/EFI/debian; do
  cat > "$d/grub.cfg" <<EOF
search.fs_uuid $ROOT_FS_UUID root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
EOF
done
update-grub
if ! grep -q "root=UUID=$ROOT_FS_UUID" /boot/grub/grub.cfg; then
  echo "grub.cfg does not use root=UUID; fixing the device path"
  sed -i -E "s#root=/dev/[a-z0-9]+p?2#root=UUID=$ROOT_FS_UUID#g" /boot/grub/grub.cfg
fi
grep -q "root=UUID=$ROOT_FS_UUID" /boot/grub/grub.cfg || { echo "FATAL: grub.cfg root= is wrong"; exit 1; }
grep -m3 -E '^\s*linux\s' /boot/grub/grub.cfg
find /boot/efi -type f | sort
for f in BOOTX64.EFI grubx64.efi mmx64.efi grub.cfg; do
  [ -f "/boot/efi/EFI/BOOT/$f" ] || { echo "FATAL: missing /EFI/BOOT/$f"; exit 1; }
done

# ------------------------------------------------------------------------------------------------
log "Versions"
pkgv() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "-"; }
{
  echo "kernel:           $KVER (linux-image-amd64 $(pkgv linux-image-amd64), trixie-backports)"
  echo "linux-firmware:   firmware-amd-graphics $(pkgv firmware-amd-graphics), firmware-misc-nonfree $(pkgv firmware-misc-nonfree)"
  echo "mesa (RADV/ANV):  $(pkgv mesa-vulkan-drivers)"
  echo "nvidia-open:      $(pkgv nvidia-open) (kernel module $(modinfo -F version "$NVKO"), vulkan icd $(pkgv nvidia-vulkan-icd), gsp fw $(pkgv firmware-nvidia-gsp))"
  echo "systemd:          $(pkgv systemd)"
  echo "gnome-shell:      $(pkgv gnome-shell)   gdm3 $(pkgv gdm3)   gnome-initial-setup $(pkgv gnome-initial-setup)"
  echo "chromium:         $(pkgv chromium)"
  echo "grub/shim:        grub-efi-amd64-signed $(pkgv grub-efi-amd64-signed), shim-signed $(pkgv shim-signed)"
  echo "python:           $(python3 --version 2>&1)"
} > /usr/share/lecore-plus/versions.txt
cat /usr/share/lecore-plus/versions.txt
dpkg-query -W -f='${Package}\t${Version}\n' | sort > /usr/share/lecore-plus/packages.txt

# ------------------------------------------------------------------------------------------------
log "Cleanup (first-boot state)"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/debconf/*-old /var/lib/dpkg/*-old
rm -rf /tmp/* /var/tmp/* /root/.cache /root/.bash_history /var/cache/man/*
find /var/log -type f -exec truncate -s 0 {} \;
rm -f /var/lib/systemd/random-seed /var/lib/dbus/machine-id
: > /etc/machine-id                        # empty = "first boot" for systemd
rm -f /usr/sbin/policy-rc.d
echo "chroot setup complete"
