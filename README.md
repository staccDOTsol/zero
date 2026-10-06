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

## Models are not baked into the image

Model files are 10–70 GB each; GitHub release assets cap at 2 GiB a file and runners have
limited disk space. The images ship without models. The imaging station runs
`provision/` with the model ids the customer checked on the order page. It downloads them
from Hugging Face on the **imaging station**, checks each sha256 and copies them onto the
laptop. The laptop itself never downloads anything.

`models/catalog.json` is the menu; the order page's checkboxes come from it.

## Layout

```
models/catalog.json      model menu: HF repo, file, sha256, size, license, which tiers it fits
linux/                   Linux image build  → .github/workflows/linux-image.yml
windows/                 Windows image build → .github/workflows/windows-image.yml
provision/               add checked models to a laptop or a disk image at imaging time
```
