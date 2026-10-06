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

- Linux: nftables `output` policy `drop`, loopback allowed. No apt timers, no NTP, no telemetry.
- Windows: Windows Firewall `DefaultOutboundAction Block` on every profile, loopback allowed;
  Windows Update, telemetry and Store services disabled.

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
