# Zero Linux factory image

One x86_64 UEFI disk image for all three Zero laptops:

| Tier | Laptop | CPU / GPU | Memory |
|---|---|---|---|
| Zero Pro | HP ZBook Ultra G1a | AMD Ryzen AI Max+ 395, Radeon 8060S iGPU (gfx1151, "Strix Halo") | 64 GB unified |
| Zero Max | HP ZBook Ultra G1a | same | 128 GB unified |
| Zero Ultra | Lenovo ThinkPad P16 Gen 3 | Intel Core Ultra 9 275HX (Arrow Lake HX) + NVIDIA RTX PRO 5000 Blackwell laptop GPU, 24 GB | 128 GB DDR5 |

The image boots to a GNOME (Wayland) desktop. On the first boot GNOME's setup assistant creates the
owner's account; no user or password is baked in. At every login a Zero app window opens on the local
chat. Nothing on the machine can reach the network (see [Zero egress](#zero-egress)).
`flash.md` explains how to write the image to a laptop and add the models.

## What is in the image

| Piece | Where | Runs as |
|---|---|---|
| llama.cpp **b11430**, `llama-b11430-bin-ubuntu-vulkan-x64.tar.gz` (sha256 pinned in `config.env`) | `/opt/lecore-plus/llama/` | `lecore-llama.service` → `llama-server --host 127.0.0.1 --port 8080 -ngl 999 -m /var/lib/lecore-plus/models/<file>` |
| leCore at commit `21abb4f4bdbe98cad0ec223bec9cab28148e73d9` (MIT), unmodified | `/opt/lecore-plus/lecore/`, venv `/opt/lecore-plus/venv/` | `lecore-chat.service` → leCore `chat_server.py` on `127.0.0.1:7860`, `LECORE_LLM_URL=http://127.0.0.1:8080/v1` |
| Zero app window | `/etc/xdg/autostart/zero.desktop`, launcher "Zero" | Chromium `--app=http://127.0.0.1:7860/` for every user at login |
| Models (GGUF) | `/var/lib/lecore-plus/models/` + `zero-models.json` | added at imaging time by `provision/linux-add-models.sh`, never in the image |
| Default model | `/etc/lecore-plus/model` (one line: a file name in the models dir) | written by provisioning; `sudo zero-model use <id>` changes it |

### Services

- **`lecore-llama.service`** reads `/etc/lecore-plus/model` and runs `llama-server` on that file
  with `-ngl 999`. `LLAMA_EXTRA_ARGS` in `/etc/lecore-plus/llama.env` is appended (empty by
  default). The unit has `ConditionPathExists=/etc/lecore-plus/model`,
  `ConditionDirectoryNotEmpty=` on the models dir, and an `ExecCondition` that checks the named file
  exists. With no model the unit is *skipped*: it stays inactive, is not failed, and does not restart
  (proven in CI). `lecore-llama.path` starts it as soon as `/etc/lecore-plus/model` is written.
  It runs as the unprivileged `lecore` user (groups `render`, `video`), with a read-only system.
  `IPAddressDeny=any` / `IPAddressAllow=localhost` keep it on loopback even if an owner opens the
  firewall.
- **`lecore-chat.service`** runs leCore's `chat_server.py` through a small launcher,
  `/opt/lecore-plus/bin/lecore-chat-server`. At the pinned commit, `chat_server.py` starts with no
  model rung ("none") and does not read `LECORE_LLM_URL`. leCore's documented route to a model in
  another process is `$LECORE_LLM_URL` through its own OpenAI-compatible rung
  (`holographic_remotellm.remote_llm`; see leCore's `AGENTS.md` and `agent_boot`). The launcher
  builds that rung from `LECORE_LLM_URL=http://127.0.0.1:8080/v1` and attaches it the way
  `lecore.autoboot()` / `attach_runtime()` do (`zoo_attach` + `_zoo_llm`). If llama-server is not
  running, the rung returns an empty reply. That is the same reply as chat_server's own "none" rung,
  so leCore answers from memory or escalates honestly (**memory-only mode**, proven in CI). The
  launcher also does three small things. It gives leCore a writable memory partition
  (`LECORE_PARTITION=/var/lib/lecore-plus/chat/memory`, seeded once from leCore's shipped
  `release_bundle`). It respects the chat's Settings dialog. It sets the browser window title to
  "Zero". leCore's code is not modified.
- **`zero-growroot.service`** runs once on the first boot. It grows the root partition and ext4 to
  fill the NVMe (`growpart` + `resize2fs`, online).
- **`zero-gpu-memory.service`** and the initramfs script `00-zero-gpu-memory`: see
  [GPU memory](#gpu-memory-strix-halo).

### Runtime downloads in leCore: none

At the pinned commit, leCore downloads nothing in the chat path. Its WordNet dictionary ships in
`lecore_data/`. The only runtime fetches are `nltk.download()` calls in demo and benchmark functions
(`holographic_text.ensure_corpora`, ablation and measure demos). The image pre-stages those NLTK
packages from a pinned `nltk_data` commit in `/usr/share/nltk_data`: gutenberg, udhr, brown, reuters,
movie_reviews, europarl_raw, punkt_tab. With no network, the download attempt fails at once and the
corpora load from disk. Hugging Face code exists only in `assimilation/` scripts, which the chat does
not use. `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` and `PIP_NO_INDEX=1` are set for the service
anyway. The venv installs `requirements.txt` without the test-only `pytest`/`pytest-xdist`. The
resolved versions are in `BUILDINFO.txt`.

## Base: Debian 13 "trixie" + trixie-backports kernel 7.2

| Component | Version in the image | Source |
|---|---|---|
| Distribution | Debian 13.7 (trixie) | deb.debian.org |
| Kernel | **7.2.6** (`7.2.6+deb13-amd64`, package 7.2.6-1~bpo13+1, Debian-signed) | trixie-backports |
| linux-firmware | **20260810** (`firmware-amd-graphics`, `-intel-graphics`, `-iwlwifi`, `-mediatek`, `-atheros`, `-realtek`, `-misc-nonfree`) | trixie-backports |
| Mesa (RADV, ANV) | **26.1.6** (26.1.6-1~bpo13+1) | trixie-backports |
| NVIDIA | **615.71.09** open kernel modules (`nvidia-open` 615.71.09-2, DKMS 3.4) + Vulkan ICD + GSP firmware | NVIDIA's repo `developer.download.nvidia.com/compute/cuda/repos/debian13` |
| systemd / GNOME | 257.13 / GNOME Shell 48.7, gdm3 48.0, gnome-initial-setup 48.1 | trixie |
| Browser | Chromium 154.0.8037.92 (a real `.deb`) | trixie |
| Python (leCore venv) | 3.13.5; Flask 3.1.3, numpy 2.5.3, matplotlib 3.11.2, pillow 12.3.0, nltk 3.10.3 (`lecore-requirements.lock`) | trixie + PyPI at build time |
| Boot | shim-signed 16.1, grub-efi-amd64-signed 2.12 | trixie |

The exact versions of every package in a given build are in that release's `BUILDINFO.txt` and
`packages.txt`.

Why this base:

- **Real `.deb` browser, no snaps.** Ubuntu ships Firefox and Chromium only as snaps. snapd
  refreshes itself and its snaps from the Snap Store in the background. Debian ships Chromium and
  Firefox ESR as ordinary packages, and Debian has no snapd and no telemetry (popularity-contest is
  opt-in, and it is pinned out here).
- **Kernel 7.2 from Debian itself.** trixie-backports carries the current kernel, firmware and
  Mesa, built and signed by Debian, so the Secure Boot chain stays Debian's (shim → GRUB → kernel).
  - *Strix Halo (gfx1151):* amdgpu has supported GC 11.5.1 since the 6.x series. 7.2 has the
    mature APU support (MES scheduling, VCN, SMU/power). `firmware-amd-graphics` 20260810 has the
    `gc_11_5_1_*` files (MES, ME, PFP, RLC), `dcn_3_5_1`, `vcn_4_0_6` and `psp_14_0_x`. RADV in
    Mesa 26.1 supports gfx1151.
  - *Arrow Lake HX:* i915 (and xe) with Arrow Lake GuC/HuC/DMC firmware from
    `firmware-intel-graphics`. ANV for Vulkan on the iGPU. Intel Wi-Fi 7 (BE200/BE201) through
    iwlwifi.
  - *RTX PRO 5000 Blackwell (laptop):* Blackwell GPUs need NVIDIA's **open** kernel modules (the
    proprietary module does not support them). They come from NVIDIA's official Debian 13
    repository and are built with DKMS against 7.2.6 during the image build. The build fails if
    `nvidia.ko` is missing or is not the `Dual MIT/GPL` open module. The Vulkan ICD
    (`nvidia-vulkan-icd`) and GSP firmware (`firmware-nvidia-gsp`) come from the same repo.
  - *Wi-Fi/Bluetooth/audio:* firmware for Intel (iwlwifi), MediaTek (MT7925), Qualcomm (ath11k/12k)
    and Realtek, so whichever radio a SKU ships is covered. Audio uses SOF firmware plus
    `alsa-ucm-conf` 1.2.16 from backports. HP's Cirrus amplifier firmware is in
    `firmware-misc-nonfree`.
- **Vulkan everywhere.** llama.cpp uses Vulkan: RADV on the Pro/Max, the NVIDIA ICD on the Ultra.
  llama.cpp's default device choice is "all discrete GPUs, else the integrated one". So the Ultra
  runs on the RTX PRO 5000, not the Arrow Lake iGPU, and the Pro/Max run on the Radeon 8060S.
  `GGML_VK_VISIBLE_DEVICES` in `llama.env` overrides this.

### GPU memory (Strix Halo)

The Pro/Max iGPU uses system memory. The kernel lets GPU drivers map at most 50% of RAM (the TTM
limit) by default. That would cap a 128 GB Max at about 64 GB of model. Zero raises the limit to 85%
of RAM: about 54 GB on the Pro and 109 GB on the Max. The limit is written to
`/run/modprobe.d/zero-gpu-memory.conf` (`options ttm pages_limit=… page_pool_size=…`) at every boot,
before any GPU driver loads. In the initramfs, `00-zero-gpu-memory` runs ahead of udev (CI checks
the order). In the booted system, `zero-gpu-memory.service` runs before udev starts. To opt out,
create `/etc/lecore-plus/no-gpu-memory-tuning` and add `zero.no_gpu_memory_tuning` to the kernel
command line.

## Zero egress

Enforced:

- **nftables** (`/etc/nftables.conf`, table `inet zero_egress`): `output` policy **drop**, with only
  `oifname "lo"` accepted. The `input` and `forward` policies are drop too, with loopback accepted
  on input. It loads before `network-pre.target`. **Fail closed:** NetworkManager has
  `Requires=nftables.service`, so if the rules do not load, no network comes up.
- **No raw frames:** DHCP clients send their first packets through raw packet sockets (`AF_PACKET`),
  and those bypass nftables. The first CI boot showed this: the VM got a DHCP lease through the
  firewall. NetworkManager therefore runs with `RestrictAddressFamilies=~AF_PACKET`. It cannot send
  DHCP or any other raw frame, so the laptop never gets an address. CI records every frame the VM's
  network card sends (QEMU `filter-dump`) and requires **zero** frames from power-on through all
  tests, until the deliberate control step.
- **Per-service:** `lecore-llama` and `lecore-chat` run with systemd `IPAddressDeny=any`
  (loopback only), even if the firewall is opened.

Disabled, removed or masked:

| What | How |
|---|---|
| apt timers, unattended-upgrades | `apt-daily*.timer/service` masked; `APT::Periodic` all 0; unattended-upgrades not installed and pinned out |
| NTP | `systemd-timesyncd` not installed and masked; chrony/ntpsec pinned out; GNOME automatic time zone off and locked |
| fwupd | not installed; `fwupd-refresh.timer` masked; LVFS remote disabled if it is ever added |
| NetworkManager connectivity check | `[connectivity] enabled=false` |
| GNOME Software / PackageKit / Flatpak | not installed (pinned out), service masked |
| GNOME Online Accounts | no providers allowed (`whitelisted-providers=['']`, locked); setup page skipped |
| Location / weather / maps | geoclue masked and its sources disabled; location off and locked; GNOME Weather and Maps not installed |
| Problem reporting / usage stats | off and locked |
| Shell extension downloads | `allow-extension-installation=false`, locked |
| avahi / mDNS, cups-browsed | not installed and masked; no TCP listener outside loopback (checked in CI) |
| motd-news, popularity-contest, snapd, ModemManager, gnome-remote-desktop | not installed and/or masked |
| Chromium | enterprise policy `/etc/chromium/policies/managed/zero.json`: no Safe Browsing pings, metrics, variations, component updates, sync, sign-in, search suggestions, translate, DNS-over-HTTPS, network prediction, media router or AI features; plus `--disable-background-networking --disable-component-update --no-pings` |

The radios still exist. The Wi-Fi driver and `wpa_supplicant` can scan and associate (802.11
management and EAPOL frames, below IP), and Bluetooth works. No IP packet can leave, and there is no
DHCP, so an association leads nowhere. To keep the radios silent too, switch them off (airplane mode,
or `rfkill block all`).

### Opening egress (owner, root)

The owner created at first boot is an administrator (`sudo` group). Opening the network is a
deliberate, root-only act:

```sh
zero-egress status                  # BLOCKED / OPEN (anyone can run this)
sudo zero-egress open               # allow outbound traffic until the next reboot
sudo zero-egress open --permanent   # allow it from now on (rewrites /etc/nftables.conf)
sudo zero-egress close              # back to zero egress (restores the shipped rules)
```

`open` removes the nftables table. It also lifts NetworkManager's packet-socket restriction, through
a drop-in in `/run` (or in `/etc` with `--permanent`), and restarts NetworkManager so DHCP can run.
`close` undoes both. The same by hand: `sudo nft delete table inet zero_egress`, then remove the
`RestrictAddressFamilies=~AF_PACKET` line from
`/etc/systemd/system/NetworkManager.service.d/zero-egress.conf` and run
`sudo systemctl daemon-reload && sudo systemctl restart NetworkManager`. Opening the firewall does not
re-enable time sync, update timers or anything else listed above. The Zero AI services stay
loopback-only either way.

## Secure Boot

- **Secure Boot OFF:** works on all three laptops. This is the minimum supported setup.
- **Secure Boot ON, Zero Pro/Max (AMD):** works. The chain is Microsoft-signed `shim` → Debian-signed
  GRUB → Debian-signed kernel 7.2.6. amdgpu is an in-tree, signed module. CI boots the image with
  Secure Boot enforced (OVMF with Microsoft keys) and checks `mokutil --sb-state`.
- **Secure Boot ON, Zero Ultra (NVIDIA): blocker.** The NVIDIA open modules are built by DKMS on
  the build host and are **unsigned**. DKMS does not sign in a chroot, and no shared signing key is
  shipped (that key would be the same on every laptop). With Secure Boot on, the kernel refuses to load `nvidia.ko`. The
  desktop still runs on the Intel iGPU, but llama.cpp has no NVIDIA GPU. Fix, once per laptop, as
  the owner:
  `sudo zero-nvidia-secureboot`. It creates a per-machine MOK, rebuilds and signs the modules, and
  queues the key. Reboot, then choose *Enroll MOK* on the blue screen and type the one-time
  password. This step has not been tested on a P16 Gen 3. The only other route is a key the vendor
  enrolls in firmware at the factory, which needs a signing service.

## Models

Models are not in the image (see the top-level README). The imaging station runs
`provision/linux-add-models.sh` (see `flash.md`):

- `--all <tier>`: every model with a build for that tier. The default is the catalog's
  `default_for` model unless you pass `--default <id>`.
- `--tier <tier> <id>...`: specific models. The first id is the default.
- Target: a mounted root (`--target`, optional `--grow`), an image file (`--image`, grown as
  needed), or `--download-only`.

On the laptop, `zero-model list` and `sudo zero-model use <id>` switch the served model.

Zero Ultra builds marked `"speed": "offload"` (larger than the 24 GB GPU) need llama.cpp to keep part
of the model in system RAM. The unit always passes `-ngl 999` as specified. llama.cpp b11430's
default `--fit on` can only change arguments that were not set. If such a model does not load, add
`LLAMA_EXTRA_ARGS="--n-cpu-moe <N>"` in `/etc/lecore-plus/llama.env`. **Not verified on hardware.**

## Building

CI (`.github/workflows/linux-image.yml`, on `workflow_dispatch` or a push to `linux/**` or
`provision/**`) runs on `ubuntu-24.04`:

1. Frees runner disk space.
2. Runs `sudo linux/build.sh`. It uses `mmdebstrap` to bootstrap trixie straight into the image's
   ext4 partition on a loop device. It then runs `chroot-setup.sh`: packages, NVIDIA DKMS, venv,
   overlay, units, GRUB/shim, and first-boot cleanup (empty `machine-id`, no apt lists, no logs).
3. Runs `linux/smoke/run-smoke.sh` (below).
4. Compresses with `zstd -12 --long=27`, splits into 1900 MiB parts and writes `SHA256SUMS`.
5. Publishes the release `linux-YYYYMMDD-<shortsha>`.

Local build on a Debian/Ubuntu host with about 25 GB free:
`sudo apt install mmdebstrap debian-archive-keyring gdisk dosfstools e2fsprogs` and then
`sudo linux/build.sh out/`.

Pinned inputs are in `config.env`: the llama.cpp sha256, the leCore commit, the NVIDIA version and
keyring sha256, and the nltk_data commit.

## Smoke test (CI)

`linux/smoke/run-smoke.sh` boots the built image headless in QEMU with OVMF, using KVM when the
runner has `/dev/kvm`. The image disk is a virtual NVMe. The test script arrives on a separate
read-only disk and is started by a unit injected through QEMU SMBIOS credentials, which systemd
accepts only in VMs. The shipped image is never written: boot A uses a copy-on-write overlay, and
boot B uses a throwaway copy.

- **Boot A, pristine image, Secure Boot off, 40 GiB disk:** first boot (root grows to the disk,
  machine-id, no users, gdm + gnome-initial-setup running, Zero branding); TTM limit written and
  applied, and the initramfs order checked; nftables loaded; NetworkManager denied packet sockets;
  no IPv4 address acquired; no TCP/UDP listener outside loopback; phone-home units absent or masked;
  `lecore-llama` skipped cleanly with no model; leCore chat answering memory-only, plus
  teach/recall. Egress is then tested with a static address set by hand: `curl http://1.1.1.1`
  fails, DNS fails, loopback works. The wire capture up to this point must contain **zero frames
  from the VM**. As a control, the firewall is lifted for one request to show the VM *can* reach
  1.1.1.1 without it. Then `zero-egress open` must give DHCP and internet, and `zero-egress close`
  must block them again. Then `provision/linux-add-models.sh --target /` installs a tiny test model
  (SmolLM2-135M-Instruct Q4_K_M, 105 MB, CI only). `lecore-llama.path` starts llama-server, which
  serves `/v1/chat/completions`, and a chat question goes from leCore to llama-server over
  `LECORE_LLM_URL`. A screenshot of the first-boot screen is saved.
- **Boot B, Secure Boot ON (OVMF + Microsoft keys):** the image is provisioned on the host with
  `--image` (forced to grow the image file). It must boot through shim/GRUB/kernel with Secure Boot
  enforced (`mokutil --sb-state`: enabled; kernel lockdown: integrity) and start llama-server at
  boot with the pre-provisioned model. It runs the same checks with no control step, so its whole
  wire capture must contain zero frames from the VM.

QEMU has no Strix Halo or Blackwell GPU. llama.cpp therefore runs on the CPU in CI, and nothing here
proves GPU inference. The hardware notes above are about what is installed and built, not what was
run on the laptops.
