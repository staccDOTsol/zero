# leCore+

Factory images for the leCore+ laptops (Pro / Max / Ultra). Each image runs leCore and a
local model with **zero egress**: the machine makes no outbound network connections.

Private. The Windows image contains Microsoft's installer and is only for imaging
licensed machines. Never make this repo public.

## What runs on the laptop (same on both OSes)

| Piece | Listens on | Source |
|---|---|---|
| llama.cpp `llama-server` (Vulkan build, works on AMD and NVIDIA) | `127.0.0.1:8080` (OpenAI-compatible `/v1`) | github.com/ggml-org/llama.cpp releases |
| leCore chat (`chat_server.py`), model rung → `LECORE_LLM_URL=http://127.0.0.1:8080/v1` | `127.0.0.1:7860` | github.com/AnOversizedMooseWithSocks/leCore (MIT) |
| Browser / app window opening `http://127.0.0.1:7860` at login | — | — |

Install layout:

| | Linux | Windows |
|---|---|---|
| Stack | `/opt/lecore-plus/` | `C:\Program Files\leCore+\` |
| Models (GGUF) | `/var/lib/lecore-plus/models/` | `C:\ProgramData\leCore+\models\` |
| Default model | `/etc/lecore-plus/model` (one line: file name in the models dir) | `C:\ProgramData\leCore+\model.txt` |

## Zero egress

- Linux: the OS networks normally (nftables `output` policy `accept`; DHCP, NTP, apt, the browser).
  llama-server and leCore's chat run as their own users `lecore-llama` / `lecore-chat` with systemd
  `IPAddressDeny=any` + `IPAddressAllow=localhost`, plus nftables `meta skuid <uid> oifname != "lo" drop`
  for both users; both units `Requires=nftables.service` (fail closed). Both listen on 127.0.0.1 only.
  llama-server runs `--offline` without its web UI and needs a per-machine API key (generated at first
  boot, and again when `/etc/machine-id` changes, into `/etc/lecore-plus/llama-api-key`,
  `root:lecore-api 0640`); the chat answers only `Host: 127.0.0.1:7860` / `localhost:7860`.
- Windows: the OS networks normally (Windows Firewall on, `DefaultOutboundAction Allow`). Outbound and
  inbound Block rules for every non-loopback address apply to exactly
  `C:\Program Files\leCore+\llama\llama-server.exe` and leCore's embedded
  `C:\Program Files\leCore+\python\python.exe` / `pythonw.exe`, re-applied at every boot. Both listen
  on 127.0.0.1 only. llama-server runs `--offline --no-webui --cors-origins localhost` and needs a
  per-machine API key (`--api-key-file C:\ProgramData\leCore+\secret\llama-api-key`, readable only by
  the two Zero services, SYSTEM and Administrators); the chat answers only `Host: 127.0.0.1:7860` /
  `localhost:7860`.

## Every model ships on the disk: golden images

There is no model menu at order time. Each tier ships with **every catalog model that fits it**
(`models/catalog.json`: Pro 8 models / about 174 GB, Max 15 / about 798 GB, Ultra 15 / about 719 GB),
and the laptop opens with the tier's default model (`default_for` in the catalog). The models are
written into the factory image itself, so a laptop works the moment it is turned on: nothing is
downloaded on the laptop, and the default model is already being served on 127.0.0.1 at the first
boot.

What a distributor receives is one **golden image per tier and OS**, six in all (Pro, Max, Ultra x
Linux, Windows). Each is a single raw GPT disk image (`zero-<tier>-<os>.img.zst`, zstd-compressed)
that the imaging team writes straight onto the laptop's NVMe (`zstd -dc | dd`, or any sector-copy
duplicator). Nothing has to be assembled or added by hand. On the first boot:

- **Linux**: the root partition grows to fill the NVMe, a per-machine llama-server API key is made,
  GNOME's setup assistant creates the owner's account, and the default model is already running.
- **Windows**: the image is generalized (`sysprep /generalize /oobe`), so each laptop specializes on
  its first boot (new SID, its drivers from the driver store, a per-machine API key), installs the
  Windows 11 Pro key from its own firmware, grows C: to fill the NVMe, and shows OOBE for the owner's
  local account. The model service and the chat are already running.

The images are built by `golden/build-golden.sh` (one command; see
[`golden/README.md`](golden/README.md)) on GitHub Actions runners with KVM. Every image is checked
before it is uploaded: every model file is read back from the image and its sha256 compared with the
catalog, then the image is booted for its first boot in QEMU/KVM on a drive the size of the laptop's
NVMe, and the default model must answer on 127.0.0.1:8080, the chat must answer through it on
127.0.0.1:7860, and the zero-egress confinement must hold. The images are kept in a private
object-store bucket (S3-compatible) with a manifest (sizes, sha256, base release tags, catalog
version).

`provision/` (adding models to a disk or image by hand) is what the golden builds use for Linux and
remains for service work, e.g. putting a different default on one laptop.

## Layout

```
models/catalog.json      model menu: HF repo, file, sha256, size, license, which tiers it fits
linux/                   Linux image build  → .github/workflows/linux-image.yml
windows/                 Windows image build → windows/ci/windows-image.yml (runs in kekloldyormarket/zero-golden)
provision/               put catalog models onto a Zero disk or disk image (used by the golden builds)
golden/                  golden images: base image + every model of the tier, verified, to S3
```
