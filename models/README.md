# leCore+ model menu

`catalog.json` is the menu behind the order page checkboxes. Every file's path, byte size and
sha256 came from the Hugging Face API (`/api/models/<repo>?blobs=true`) on 2026-10-05. The
imaging station downloads these files and checks them against the sha256 values. Nothing was
downloaded to build the menu. `python3 models/check.py` checks the catalog against HF again
(sizes, sha256, multi-part sets, budgets, one default per tier). It exits 1 on any drift, so it
can run in CI.

Sizes are decimal GB (10^9 bytes). Runtime: llama.cpp b11430, Vulkan. For every chosen file I read
the GGUF header over an HTTP range request. Each `general.architecture` (qwen35, qwen4exp,
glm5-next, deepseek4, laguna, gemma4, mistral4, gpt-oss, deepseek2, nemotron_h_moe) is in
`src/llama-arch.cpp` at tag b11430. No file has been load-tested on the hardware yet: there was
no disk space for that. Run one load test per model on the imaging station before shipping.

| Model | Maker | License | Pro (≤44 GB) | Max (≤100 GB) | Ultra (fast ≤20 GB / offload ≤100 GB) |
|---|---|---|---|---|---|
| Qwen3.8 27B **(default: pro, max, ultra)** | Qwen (Alibaba) | apache-2.0 | 17.6 GB UD-Q4_K_XL | 29.0 GB Q8_0 | 17.6 GB UD-Q4_K_XL |
| Qwen3.8 Flash-Next | Qwen (Alibaba) | qwen-community-1.0 (see below) | — | 93.7 GB UD-IQ4_XS | 93.7 GB UD-IQ4_XS (offload) |
| GLM-5.3-Flash | Z.ai (zai-org) | mit | — | 97.6 GB UD-IQ1_M | 97.6 GB UD-IQ1_M (offload) |
| DeepSeek V4 Flash (0731) | DeepSeek | mit | — | 96.8 GB UD-Q2_K_XL | 96.8 GB UD-Q2_K_XL (offload) |
| Laguna S 2.1 (coding) | poolside | openmdw-1.1 | — | 67.7 GB Q4_K_M | 67.7 GB Q4_K_M (offload) |
| Qwen3.8 27B Abliterated (uncensored) | huihui-ai | apache-2.0 | 17.4 GB UD-Q4_K_XL | 29.0 GB Q8_0 | 17.4 GB UD-Q4_K_XL |
| GLM-5.3-Flash Abliterated (uncensored) | huihui-ai | mit | — | 93.1 GB UD-IQ1_S | 93.1 GB UD-IQ1_S (offload) |
| Gemma 4 31B | Google DeepMind | apache-2.0 | 17.7 GB Q4_0 (QAT) | 32.6 GB Q8_0 | 17.7 GB Q4_0 (QAT) |
| Mistral Small 4 (2603) | Mistral AI | apache-2.0 | — | 74.2 GB UD-Q4_K_XL | 74.2 GB UD-Q4_K_XL (offload) |
| gpt-oss 120B | OpenAI | apache-2.0 | — | 63.4 GB MXFP4 | 63.4 GB MXFP4 (offload) |
| GLM-4.7-Flash | Z.ai (zai-org) | mit | 31.8 GB Q8_0 | 31.8 GB Q8_0 | 17.5 GB UD-Q4_K_XL |
| Nemotron 3.5 Lightning 30B-A3B | NVIDIA | openmdw-1.1 | 33.6 GB Q8_0 | 33.6 GB Q8_0 | 18.9 GB Q4_0 |
| Gemma 4 26B-A4B | Google DeepMind | apache-2.0 | 26.9 GB Q8_0 | 26.9 GB Q8_0 | 14.4 GB Q4_0 (QAT) |
| Gemma 4 26B-A4B Abliterated (uncensored) | huihui-ai | apache-2.0 | 16.8 GB Q4_K | 16.8 GB Q4_K | 16.8 GB Q4_K |
| gpt-oss 20B | OpenAI | apache-2.0 | 12.1 GB MXFP4 | 12.1 GB MXFP4 | 12.1 GB MXFP4 |

The "Q4_0 (QAT)" files are Google's own quantization-aware-trained GGUFs (`google/gemma-4-*-qat-q4_0-gguf`).
Every pro/max build and every ultra build of 20 GB or less runs fully on the GPU (`"fast"`).

Picks:
- Default: **Qwen3.8 27B** (Aug 2026, Apache-2.0) on all three tiers. It is the strongest
  permissively licensed model that fits each tier comfortably. Its card reports SWE-bench Pro 61.7
  and Terminal-Bench 2.1 73.0. Laguna S 2.1's card reports 59.4 and 70.2. Qwen's card lists Meta's
  Muse Glimmer 30B at 51.2 and 51.7.
- Coding: Qwen3.8 27B on every tier. On max/ultra also Laguna S 2.1, Qwen3.8 Flash-Next and
  DeepSeek V4 Flash.
- Small and fast on every tier: gpt-oss 20B, Gemma 4 26B-A4B, Nemotron 3.5 Lightning.
- GLM: GLM-5.3-Flash is the current generation. Its 320B total only fits max/ultra, and only
  with a 1-bit-class dynamic quant (UD-IQ1_M, about 2.4 bits per weight on average).
  GLM-4.7-Flash is the GLM that fits pro.

## Not included, and why

- **Reflection AI "Beam": the weights are not public.** reflection.ai/blog/introducing-beam
  (dated 2026-10-05) announces a 501B-total / 23B-active MoE. The post says "We will release the
  weights … later this month" and offers early-access signup only. The verified Hugging Face org
  `reflection` lists 0 public models, and no Beam repo exists on HF. Nothing else is listed under
  Reflection's name. When the weights come out, note that 501B fits ≤100 GB only at about 1.6
  bits per weight on average. Check it again then.
- **Too large for the 100 GB budget:** GLM-5.3 and GLM-5.2 (753B), Kimi K3 (2.8T), Qwen3.8-2.4T-A95B,
  DeepSeek V4.1 Flash (763B), DeepSeek V4 Pro (1.6T), MiMo-V2.6-Flash (311B; the smallest ggml-org GGUF is 126 GB),
  MiniMax-M3 (427B), Nemotron 3 Ultra (550B).
- **Mistral Medium 3.5 (128B, dense):** it would fit max, but a dense 128B model on a ~256 GB/s
  memory bus runs at only a few tokens per second. Its license is also a modified MIT with
  large-company exceptions. Mistral Small 4 is the Mistral pick instead.
- **Qwen3.8 Flash-Next abliterated (huihui-ai):** the only standard quant is UD-Q4_K_XL, at
  111 GB, which is over budget. The smaller "Swift" files in that repo are third-party merges
  that huihui marks "just a test/validation".
- **DeepSeek V4 Flash abliterated (huihui-ai):** it fits only at Q2 (87–98 GB). huihui says the Q2
  ablation is weaker than Q4, and Q4 is 156+ GB.
- **Vision/audio projectors (`mmproj-*.gguf`), MTP/draft heads:** left out. Several of these
  models are multimodal (Qwen3.8, GLM-5.3-Flash, Gemma 4, Mistral Small 4). The catalog schema
  has no field for a projector, and the launcher loads a single model file. As shipped, these
  models are text-only.

## Caveats to review before selling

- **Qwen3.8 Flash-Next uses the Qwen Community License 1.0, not Apache-2.0.** A licensee that
  runs a "Model as a Service" or "AI Work Assistant" business needs a separate commercial
  license from Qwen. Products above 100M MAU or US$20M monthly revenue must display the model
  name. Get a legal read on preloading it for sale before offering it. It is not a default.
- **Heavily quantized:** GLM-5.3-Flash (UD-IQ1_M), GLM-5.3-Flash Abliterated (UD-IQ1_S) and
  DeepSeek V4 Flash (UD-Q2_K_XL) average about 2.3–2.7 bits per weight, with 1–2-bit expert
  tensors. That is the only way they fit 100 GB. Expect some quality loss compared with their
  published benchmarks.
- **Abliterated models** have had refusals partly removed with huihui-ai's "crude,
  proof-of-concept" method. They are marked `"uncensored": true`.
- **gpt-oss** is from August 2025. OpenAI has published no newer open-weight LLM on HF.
- **Upstream files can change.** unsloth rewrote the first GLM-5.3-Flash shard on 2026-10-05,
  after llama.cpp merged GLM-5.3-Flash support. When a file changes upstream, the sha256 check
  at imaging fails. Run `check.py` and update the size and sha256 of each entry it reports.
