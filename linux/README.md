# Zero Linux factory image

One x86_64 UEFI disk image for all three Zero laptops:

| Tier | Laptop | CPU / GPU | Memory |
|---|---|---|---|
| Zero Pro | HP ZBook Ultra G1a | AMD Ryzen AI Max+ 395, Radeon 8060S iGPU (gfx1151, "Strix Halo") | 64 GB unified |
| Zero Max | HP ZBook Ultra G1a | same | 128 GB unified |
| Zero Pro / Max | ASUS ROG Flow Z13 (2025) GZ302EA (**untested on hardware**) | same silicon as the ZBook (Strix Halo, Radeon 8060S); MediaTek MT7925 Wi-Fi 7 | 64 GB (Pro) / 128 GB (Max) unified |
| Zero Ultra | Lenovo ThinkPad P16 Gen 3 | Intel Core Ultra 9 275HX (Arrow Lake HX) + NVIDIA RTX PRO 5000 Blackwell laptop GPU, 24 GB | 128 GB DDR5 |

The same `zero-<tier>-linux.img.zst` goes on the HP and on the ASUS of a tier: nothing in the image is
specific to one of them. See [ASUS ROG Flow Z13](#asus-rog-flow-z13-2025) for what the Z13 needs and what
is not verified.

The image boots to a GNOME (Wayland) desktop. On the first boot GNOME's setup assistant creates the
owner's account; no user or password is baked in. At every login a Zero app window opens on the local
chat. The model's input and output never leave the laptop. The rest of the OS networks normally (see
[Zero egress](#zero-egress)).
`flash.md` explains how to write the image to a laptop and add the models.

## What is in the image

| Piece | Where | Runs as |
|---|---|---|
| llama.cpp **b11430**, `llama-b11430-bin-ubuntu-vulkan-x64.tar.gz` (sha256 pinned in `config.env`) | `/opt/lecore-plus/llama/` | `lecore-llama.service` → `llama-server --host 127.0.0.1 --port 8080 -ngl 999 -m /var/lib/lecore-plus/models/<file>` |
| leCore at commit `21abb4f4bdbe98cad0ec223bec9cab28148e73d9` (MIT), unmodified | `/opt/lecore-plus/lecore/`, venv `/opt/lecore-plus/venv/` | `lecore-chat.service` → leCore `chat_server.py` on `127.0.0.1:7860`, `LECORE_LLM_URL=http://127.0.0.1:8080/v1` |
| Zero app window | `/etc/xdg/autostart/zero.desktop`, launcher "Zero" | Chromium `--app=http://127.0.0.1:7860/` for every user at login |
| Models (GGUF) | `/var/lib/lecore-plus/models/` + `zero-models.json` | every model of the tier, written into the tier's golden image (`golden/`) by `provision/linux-add-models.sh --all <tier> --image`; the base release image has none |
| Default model | `/etc/lecore-plus/model` (one line: a file name in the models dir) | the catalog default of the tier, set by the golden build; `sudo zero-model use <id>` changes it |

### Services

- **`lecore-llama.service`** reads `/etc/lecore-plus/model` and runs `llama-server` on that file
  with `-ngl 999`. `LLAMA_EXTRA_ARGS` in `/etc/lecore-plus/llama.env` is appended (empty by
  default). The unit has `ConditionPathExists=/etc/lecore-plus/model`,
  `ConditionDirectoryNotEmpty=` on the models dir, and an `ExecCondition` that checks the named file
  exists. With no model the unit is *skipped*: it stays inactive, is not failed, and does not restart
  (proven in CI). `lecore-llama.path` starts it as soon as `/etc/lecore-plus/model` is written.
  It runs as its own system user `lecore-llama` (groups `render`, `video`), with a read-only system,
  confined to loopback (see [Zero egress](#zero-egress)). `LLAMA_ARG_OFFLINE=1` (no model
  downloads) and `LLAMA_ARG_UI=0` are set in the unit environment, which leaves the command line as
  specified. The second one turns off llama.cpp's built-in web UI, which lazy-loads a HEIC decoder
  from cdn.jsdelivr.net in the viewer's browser; Zero's UI is the leCore chat.
- **`lecore-chat.service`** runs as its own system user `lecore-chat`, confined to loopback. It runs
  leCore's `chat_server.py` through a small launcher,
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

### Runtime downloads and network features in leCore

At the pinned commit leCore has no telemetry, and the chat path downloads nothing. Its WordNet dictionary ships in
`lecore_data/`. The only runtime fetches are `nltk.download()` calls in demo and benchmark functions
(`holographic_text.ensure_corpora`, ablation and measure demos). The image pre-stages those NLTK
packages from a pinned `nltk_data` commit in `/usr/share/nltk_data`: gutenberg, udhr, brown, reuters,
movie_reviews, europarl_raw, punkt_tab. The service cannot reach the network, so a download attempt
fails at once and the corpora load from disk. Hugging Face code exists only in `assimilation/` scripts, which the chat does
not use. `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` and `PIP_NO_INDEX=1` are set for the service
anyway. The venv installs `requirements.txt` without the test-only `pytest`/`pytest-xdist`. The
resolved versions are in `BUILDINFO.txt`.

**leCore features that need the network.** Because of the confinement, these do not work on Zero:
- the chat commands `learn api: <openapi json>` / `use api: svc.endpoint {...}`
  (`holographic_apilearn`), which call the external HTTP API you describe;
- `holographic_assetfetch`, which downloads an external asset (HDRI, model, texture) from a URL once
  and caches it;
- Settings → "ollama" or any other back end that is not on `127.0.0.1`;
- the multi-machine modules `holographic_toolclient` (call another leCore node), `holographic_distbus`
  (message bus across machines) and `holographic_farm` (render-farm workers on other machines).

They fail with a connection error. Nothing is silently proxied.

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
  Firefox ESR as ordinary packages, has no snapd, and its popularity-contest is opt-in (not installed).
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
command line. The limit is computed from `MemTotal` in `/proc/meminfo` at every boot, so it applies
unchanged to any Strix Halo laptop (the ASUS ROG Flow Z13 included): 64 GB → about 54 GB, 128 GB →
about 109 GB.

### ASUS ROG Flow Z13 (2025)

The Z13 (GZ302EA) has the same Ryzen AI Max+ 395 / Radeon 8060S as the ZBook, so the GPU, firmware
(`gc_11_5_1_*`, `dcn_3_5_1`, `vcn_4_0_6`, `psp_14_0_x`), RADV and the TTM tuning above are the same
story, and the image has nothing HP-specific: the HP-only piece in the package set is the Cirrus
amplifier firmware in `firmware-misc-nonfree`, which is harmless on the Z13 (the Z13 also uses Cirrus
CS35L51 amplifiers; whether its firmware/tuning is in linux-firmware 20260810 is **not verified**).
Its Wi-Fi/Bluetooth is MediaTek MT7925 (`firmware-mediatek`, mt7925e; the 7.1 mt76 regressions are
fixed in 7.2). Its keyboard folio, touchpad, fan key and RGB go through `hid-asus` / `asus-nb-wmi`:
the upstream Z13 2025 patches landed in 6.15 (keyboard init, fan key, folio RGB) and a DMI quirk for
the GZ302EAC variant in March 2026, all in the 7.2.6 kernel here. **None of this has been run on a
Z13**: the image boots in QEMU without any of that hardware. On the first Z13, check `journalctl -b`
for `hid-asus`/`asus_wmi`, `Vulkan0` in the llama-server log, Wi-Fi, speakers, and Secure Boot
(ASUS firmware ships Microsoft's keys, so the shim chain should work as on the HP; unverified).

## Zero egress

"Zero egress" means **the model's input and output never leave the laptop**. It does not mean the
laptop is offline. The OS networks normally: NetworkManager with DHCP, Wi-Fi, NTP
(`systemd-timesyncd`), apt and GNOME Software updates, fwupd, and the browser.

The two processes that see model input and output are confined to loopback. Each runs as its own
system user under systemd, and each binds to 127.0.0.1 only:

| Process | User | Listens on | Confinement |
|---|---|---|---|
| llama-server | `lecore-llama` | 127.0.0.1:8080 | `IPAddressDeny=any`, `IPAddressAllow=localhost`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK` (no raw packet sockets) |
| leCore chat (`chat_server.py`) | `lecore-chat` | 127.0.0.1:7860 | `IPAddressDeny=any`, `IPAddressAllow=localhost`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` |

- **Layer 1, systemd:** `IPAddressDeny=`/`IPAddressAllow=` is a cgroup BPF filter on every socket in
  the service, whatever its user, including root. A child process inherits it.
- **Layer 2, nftables:** `/etc/nftables.conf` holds only table `inet zero_egress`, built from
  `/usr/lib/zero/nftables-zero.nft.in` at image build time. Its `output` chain has policy
  **accept** and drops non-loopback output for `meta skuid` of `lecore-llama` and of `lecore-chat`.
  This covers anything those users run outside the units. Other tables are left alone, so an owner's
  own firewall can coexist.
- **Fail closed:** both units have `Requires=nftables.service`. If the rules do not load, the AI
  services do not start.
- **Loopback is not a trust boundary on a laptop with a browser.** A web page can point its own host
  name at 127.0.0.1 (DNS rebinding) and talk to local ports. So:
  - **llama-server needs a per-machine API key.** `zero-llama-key.service` generates 256 random bits
    at first boot into `/etc/lecore-plus/llama-api-key` (`root:lecore-api 0640`; only the
    `lecore-llama` and `lecore-chat` users are in `lecore-api`) and again whenever `/etc/machine-id`
    changes, so a cloned disk gets its own key. llama-server reads it with `LLAMA_ARG_API_KEY_FILE`
    (not on the command line). Every request except `/health` needs `Authorization: Bearer <key>`.
    The chat launcher sends it from `LECORE_LLM_KEY_FILE`. For your own tools:
    `curl -H "Authorization: Bearer $(sudo cat /etc/lecore-plus/llama-api-key)" http://127.0.0.1:8080/v1/models`.
  - **The chat answers only `Host: 127.0.0.1:7860` / `localhost:7860`** and refuses cross-site POSTs
    (403). Its pages carry a Content-Security-Policy that keeps them on 127.0.0.1, so model output
    such as `<img src=https://…>` cannot carry text off the machine.
- **The Zero window.** Chromium shows model input and output. The enterprise policy
  `/etc/chromium/policies/managed/zero.json` turns off only the features that would send page or
  typed text to Google: Translate, the enhanced spell-check service, and the Help-me-write/Lens/
  tab-compare/history-search AI features. Everything else in Chromium (Safe Browsing, updates of
  components, etc.) is left as Debian ships it.

Verified in CI (QEMU): as `lecore-llama` and as `lecore-chat`, `curl http://1.1.1.1` (and IPv6)
fails while `curl http://127.0.0.1:7860` works. A root process moved into each service's cgroup is
blocked too, and root outside them reaches the internet. Requests to :8080 without the key, or with
a wrong one, get 401; the chat still reaches the model; a foreign `Host:` header on :7860 gets 403. See [Smoke test](#smoke-test-ci).

To check on a laptop: `sudo nft list table inet zero_egress` (the drop counters) and
`systemctl show lecore-chat -p IPAddressDeny -p IPAddressAllow`.

## Secure Boot

- **Secure Boot OFF:** works on all three laptops. This is the minimum supported setup.
- **Secure Boot ON, Zero Pro/Max (AMD):** works. The chain is Microsoft-signed `shim` → Debian-signed
  GRUB → Debian-signed kernel 7.2.6. amdgpu is an in-tree, signed module. CI boots the image with
  Secure Boot enforced (OVMF with Microsoft keys) and checks `mokutil --sb-state`. (Verified on the HP
  ZBook Ultra G1a chain in CI; the ASUS ROG Flow Z13 should behave the same but is untested.)
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

Laptops ship the **golden image** of their tier (see the top-level README and `flash.md`): this
image plus every catalog model of the tier, with the tier's default selected, so `lecore-llama` serves
the default model from the first boot. The golden build (`golden/ci/golden-linux.yml`) puts the
models in with `provision/linux-add-models.sh --all <tier> --image`, which also does service work:

- `--all <tier>`: every model with a build for that tier. The default is the catalog's
  `default_for` model unless you pass `--default <id>`.
- `--tier <tier> <id>...`: specific models. The first id is the default.
- Target: a mounted root (`--target`, optional `--grow`), an image file (`--image`, grown as
  needed), or `--download-only`.

On the laptop, `zero-model list` and `sudo zero-model use <id>` switch the served model.

Zero Ultra builds marked `"speed": "offload"` are all MoE models larger than the 24 GB GPU (63–98
GB). llama.cpp b11430's `--fit` can only reduce the context when `-ngl` is set, so `-ngl 999` alone
would try to put the whole model on the GPU and fail. For a model whose build is marked `offload` in
`zero-models.json`, the launcher therefore adds `LLAMA_OFFLOAD_ARGS` (default `--cpu-moe`, set in
`/etc/lecore-plus/llama.env`). `-ngl 999` stays: attention, shared weights and the KV cache sit on
the RTX PRO 5000, and the expert weights sit in the 128 GB system RAM. "Fast" builds and every
Pro/Max build get exactly `-ngl 999`. **Not verified on hardware.** Expect the offload models to be
limited by DDR5 bandwidth.

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
  applied, and the initramfs order checked; the per-user nftables rules are loaded and both units
  carry the confinement properties; the services listen on 127.0.0.1 only; normal networking (DHCP
  address, DNS, timesyncd and apt timers enabled); `lecore-llama` skipped cleanly with no model;
  leCore chat answering memory-only, plus teach/recall. Then `provision/linux-add-models.sh
  --target /` installs a tiny test model (SmolLM2-135M-Instruct Q4_K_M, 105 MB, CI only).
  `lecore-llama.path` starts llama-server with exactly `--host 127.0.0.1 --port 8080 -ngl 999 -m …`.
  It serves `/v1/chat/completions`, and a chat question goes from leCore to llama-server over
  `LECORE_LLM_URL`. **Per-process egress test:** root reaches 1.1.1.1. As `lecore-llama` and as
  `lecore-chat`, 1.1.1.1 (IPv4 and IPv6) is blocked and loopback works. A root process placed in
  each service's cgroup is blocked too. llama-server runs with `LLAMA_ARG_OFFLINE=1` and its web UI
  off. A screenshot of the first-boot screen is saved.
- **Boot B, Secure Boot ON (OVMF + Microsoft keys):** the image is provisioned on the host with
  `--image` (forced to grow the image file), with the test model marked as an "offload" build. It must
  boot through shim/GRUB/kernel with Secure Boot enforced (`mokutil --sb-state`: enabled; kernel
  lockdown: integrity). It must start llama-server at boot with `-ngl 999 … --cpu-moe`, and pass the
  same chat, model and per-process egress checks.

QEMU has no Strix Halo or Blackwell GPU. llama.cpp therefore runs on the CPU in CI, and nothing here
proves GPU inference. The hardware notes above are about what is installed and built, not what was
run on the laptops.
