# Zero golden images

A golden image is everything one laptop needs, in one file: the Zero OS image of its laptop model
**plus every catalog model of its tier** (`models/catalog.json`), with the tier's default model
selected. An imaging team writes it straight onto the laptop's NVMe. When the owner turns the laptop
on, the default model is already being served on 127.0.0.1 and the chat answers through it. Nothing
is downloaded on the laptop and nothing is added by hand.

| Image | Laptop | Models | Raw size (about) |
|---|---|---|---|
| `zero-pro-linux.img.zst` | HP ZBook Ultra G1a, 64 GB / 1 TB | 8, ≈ 174 GB | ≈ 193 GB |
| `zero-max-linux.img.zst` | HP ZBook Ultra G1a, 128 GB / 2 TB | 15, ≈ 798 GB | ≈ 817 GB |
| `zero-ultra-linux.img.zst` | Lenovo ThinkPad P16 Gen 3, 128 GB / 2 TB | 15, ≈ 719 GB | ≈ 738 GB |
| `zero-pro-windows.img.zst` | HP ZBook Ultra G1a, 64 GB / 1 TB | 8, ≈ 174 GB | ≈ 243 GB |
| `zero-max-windows.img.zst` | HP ZBook Ultra G1a, 128 GB / 2 TB | 15, ≈ 798 GB | ≈ 867 GB |
| `zero-ultra-windows.img.zst` | Lenovo ThinkPad P16 Gen 3, 128 GB / 2 TB | 15, ≈ 719 GB | ≈ 788 GB |

Default model on every tier: Qwen3.8 27B (Pro/Ultra UD-Q4_K_XL, Max Q8_0). Exact sizes and sha256
values are in each image's manifest. Each image is smaller than its laptop's drive; on the first boot
the root partition (Linux) or C: (Windows) grows to the end of the drive.

## Format, and why

Every image, Linux and Windows, is one **raw GPT disk image**, zstd-compressed. It is written with
`zstd -dc zero-<tier>-<os>.img.zst | dd of=/dev/nvme0n1 bs=16M oflag=direct`, by any sector-copy
duplicator (after `zstd -d`), or with Clonezilla (see `linux/flash.md`). One format for both OSes, one
procedure, nothing Zero-specific for the imaging team to do.

**Windows** is a *generalized full-disk image*: Windows 11 Pro installed from the Zero ISO of the
laptop model (`windows-*` release: Microsoft's Windows 11 Pro, the laptop's drivers injected, the Zero
stack staged). Setup runs the ISO's own specialize pass; then, in audit mode, the Zero stack and the
model containment are installed (again) by the ISO's `install.ps1` in full Windows and checked, and
`sysprep /generalize /oobe /shutdown` generalizes the install. The models are then written into
`C:\ProgramData\leCore+\models`. On each laptop's first boot Windows specializes (new SID, Plug and
Play on the laptop's hardware with the drivers in the driver store) and runs `windows/firstboot.ps1`:
C: grows to the end of the NVMe, the model files' ACLs are reset, a per-machine llama-server API key
is made, and the Windows 11 Pro key from the laptop's firmware (OA3/MSDM) is installed (activation
then happens online). The `\Zero\Zero golden first boot` startup task runs the same script again
and removes itself. OOBE asks the owner for a local account; the model service and the chat are
already running behind it. Why this and not a WIM:

- it is what could be built and *verified end to end* here: the exact bytes that are uploaded are
  booted for their first boot in QEMU/KVM and checked (below). A WIM would need a second, separate
  apply step (`DISM /Apply-Image` + `bcdboot`) between the artifact and anything that can be tested;
- the stack is installed *before* sysprep, so the image works even if an imaging service replaces the
  answer file: the first-boot task does not depend on it;
- one file per laptop, one procedure for both OSes, and the models stay inside C: (no separate data
  partition, nothing to assemble).

If an imaging line accepts only WIMs: write the image to one disk without booting it, boot WinPE,
`dism /Capture-Image /ImageFile:E:\zero-max.wim /CaptureDir:W:\ /Name:"Zero Max"` (W: = the image's
Windows partition), and per laptop `dism /Apply-Image /ImageFile:E:\zero-max.wim /Index:1 /ApplyDir:W:\`
+ `bcdboot W:\Windows /s S: /f UEFI` onto an ESP (S:, 260 MB FAT32) + MSR + NTFS layout. The captured
volume is the generalized one, so the result is the same image. **This WIM route has not been tested.**

## How an image is built (`golden/build-golden.sh`)

```sh
golden/build-golden.sh                    # newest base releases, all tiers, both OSes
golden/build-golden.sh --os windows --tiers '["max"]' --windows-tag windows-YYYYMMDD-<sha>
```

It runs from a checkout of `staccDOTsol/lecore-plus` (the source of truth) with `gh` logged in:

1. `golden-stage` (workflow in lecore-plus) copies the newest `linux-*` image parts and `windows-*`
   ISO parts into `s3://zero-golden-images-143795940981/base/{linux,windows}/<tag>/`, each part
   sha256-checked. It assumes an IAM role through GitHub OIDC (main branch only, `base/` prefix only).
2. It copies `golden/`, `provision/` and `models/` into the private build repo
   `kekloldyormarket/zero-golden` (the larger runners belong to that org) and pushes.
3. It dispatches `golden-linux` and `golden-windows` there: one job per tier x OS on `zero-golden-32`
   (96 cores, 384 GB, 2 TB SSD, KVM), all six in parallel.

Each Linux job (`ci/golden-linux.yml`): every model of the tier from Hugging Face (aria2c, parallel,
sha256 per file) → the base image → `provision/linux-add-models.sh --all <tier> --image` (grows the
image, copies the models in, re-hashes every copy, writes `zero-models.json` and the default) →
`linux/verify.sh` → upload.

Each Windows job (`ci/golden-windows.yml` → `windows/build.sh`): models download in the background →
the laptop's Zero ISO is rebuilt as a build ISO (same files, no-prompt UEFI boot, the build answer
file from `windows/unattend.py`) → QEMU/KVM: Windows Setup onto the VM's only disk (the image file,
sized models + 64 GiB), the ISO's specialize pass, audit mode, `windows/audit.ps1` (`install.ps1`,
stack checks, first-boot task, per-machine state removed), sysprep → the models into the NTFS volume, `model.txt`,
`models.json` → every model re-read from the image (ntfs-3g, read-only, cold cache) and sha256-checked
→ first-boot verification → upload.

## Verification (before upload)

1. **Every model file** of the tier is read back from the finished image and its size and sha256 are
   compared with the catalog (`lib/catalog.py verify`).
2. **First boot**: the image is booted in QEMU/KVM with OVMF through a copy-on-write overlay the size
   of the laptop's NVMe (1 TB Pro, 2 TB Max/Ultra), with a fresh firmware variable store, as on a
   laptop just written by an imaging team. A test-only script, on its own disk (Linux:
   `linux/guest.sh`, started through a VM-only systemd credential; Windows: `windows/verify.ps1`,
   started by one line added to the overlay's copy of the first-boot script, so it runs from the
   image's own startup task during OOBE), checks:
   - generalized first boot: Linux root grows to the drive, machine-id and API key made, no user;
     Windows `IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE`, a new machine SID, no enabled account, the OOBE
     answer file, C: grown to the drive, the first-boot task done, the laptop's drivers in the driver
     store, Windows 11 Pro;
   - `model.txt` / `/etc/lecore-plus/model` = the catalog default, the inventory lists every model,
     every file present with its catalog size, the default model's sha256 computed again by the booted
     OS (and Windows: model ACLs inherited);
   - the default model started by itself, served on 127.0.0.1:8080, needs the per-machine key (none or
     wrong → 401), and answers a chat completion; the chat on 127.0.0.1:7860 answers through it;
   - zero egress: both services listen on 127.0.0.1 only; Linux: `lecore-llama`/`lecore-chat` users
     and service cgroups cannot reach 1.1.1.1 while root can; Windows: the six containment rules,
     leCore's `python.exe` and the `llama-server.exe` path cannot reach pypi.org while the OS can; the
     chat refuses a DNS-rebinding Host.
   An image whose verification fails is not uploaded; the job fails and its logs (serial console of
   the test boot, screenshots, reports) are kept as the run's artifact.

**Not verified by the build** (no hardware): the GPU path (the VM has no GPU, so the model runs on the
CPU; check `Vulkan0` in the llama-server log on the first laptop of each model), Windows activation
with the laptop's firmware key (the VM has no OA3 key), Secure Boot for the Windows image (the VM
boots without it), and loading the non-default models (size + sha256 only).

## S3 layout

```
s3://zero-golden-images-143795940981/
  base/linux/<tag>/...           base/windows/<tag>/...        staged base releases
  linux/<linux tag>/zero-<tier>-linux.img.zst  .manifest.json  .verify.txt
  windows/<windows tag>/zero-<tier>-windows.img.zst  .manifest.json  .verify.txt
```

The bucket is private (public access blocked, bucket-owner-enforced, SSE-S3), tagged
`project=zero-images`; incomplete multipart uploads are aborted after 2 days. The manifest holds the
raw size and sha256 (to check the written NVMe), the compressed size and sha256 (to check the
download), the base release, the golden commit, the catalog version, the model list and the
verification report. Downloads are by presigned URL, made on request. Each full download of an
image leaves AWS and is billed as data transfer out (about $0.09/GB; a Max image ≈ $70).
