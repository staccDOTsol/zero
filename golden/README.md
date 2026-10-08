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
| `zero-pro-windows-asus-rog-flow-z13.img.zst` | ASUS ROG Flow Z13 (2025) GZ302EA, 64 GB / 1 TB (**untested on hardware**) | 8, ≈ 174 GB | ≈ 243 GB |
| `zero-max-windows-asus-rog-flow-z13.img.zst` | ASUS ROG Flow Z13 (2025) GZ302EA, 128 GB / 2 TB (**untested on hardware**) | 15, ≈ 798 GB | ≈ 867 GB |

The Pro and Max **Linux** images are the same file for the HP ZBook Ultra G1a and the ASUS ROG Flow Z13
(2025) (same Strix Halo silicon; `linux/README.md`). The **Windows** image is per laptop, because it is
installed from that laptop's Zero ISO (its own drivers): the HP ZBook Ultra G1a is each tier's default
laptop and keeps the plain name; another laptop's image carries the laptop's `image_name` from
`windows/drivers.json` (`--laptop` of `build-golden.sh` / `golden/windows/build.sh`, the `laptop` input
of `golden-windows`), so both images of a tier sit side by side in the bucket. The Z13 images are built
and verified exactly like the HP ones (QEMU first boot, below) but have not yet been written to a Z13.

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
in full Windows: there it also moves the Windows Recovery Environment onto C: (Setup's Recovery
partition sits right after C: and would block the extension: `reagentc /disable`, the partition is
deleted, C: extended, `reagentc /enable`), makes sure both Zero services run, and removes itself. OOBE asks the owner for a local account; the model service and the chat are
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
golden/build-golden.sh --os windows --tiers '["pro","max"]' --laptop asus-rog-flow-z13-gz302ea   # the Z13 images
```

It runs from a checkout of `staccDOTsol/lecore-plus` (the source of truth) with `gh` logged in:

1. It copies `golden/`, `provision/`, `models/` and `windows/` (with their workflows) into the private,
   org-billed build repo `kekloldyormarket/zero-golden` and pushes. The larger runners belong to that
   org, and the Windows base ISOs are built there too (`windows/ci/windows-image.yml`): they contain
   Microsoft's installer and stay private.
2. `golden-stage` copies the newest `linux-*` image parts (a release of lecore-plus) and `windows-*`
   ISO parts (a release of zero-golden) into the object store, `base/{linux,windows}/<tag>/`, each part
   sha256-checked.
3. It dispatches `golden-linux` and `golden-windows` there: one job per tier x OS on `zero-golden-32`
   (a larger runner with KVM and a 2 TB SSD), up to the runner's parallel limit.

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
     Windows: Setup's passes done (`ImageState` `IMAGE_STATE_COMPLETE`) with OOBE still waiting for the
     owner (kernel32 `OOBEComplete()` = 0, or `OOBEInProgress` = 1, or `msoobe.exe` on the screen), a new
     machine SID, no enabled account, the OOBE answer file, C: grown to the drive, the first-boot task
     done, the laptop's drivers in the driver store, Windows 11 Pro;
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

**Not verified by the build** (no hardware): the GPU path (the VM has no GPU and, on Windows, no Vulkan
loader, so llama.cpp skips its Vulkan backend and runs the model on the CPU backend; the report lists the
backends it loaded; check `Vulkan0` in the llama-server log on the first laptop of each model), Windows activation
with the laptop's firmware key (the VM has no OA3 key), Secure Boot for the Windows image (the VM
boots without it), and loading the non-default models (size + sha256 only).

## Object store

The images go to a private bucket on any S3-compatible service; `lib/store.sh` wraps aws-cli
(`--endpoint-url` when an endpoint is set). Configuration, on both `staccDOTsol/lecore-plus` (staging)
and `kekloldyormarket/zero-golden` (builds):

| | Kind | Example |
|---|---|---|
| `S3_ENDPOINT_URL` | repo variable | `https://fly.storage.tigris.dev` (Tigris); empty = AWS S3 |
| `STORE_BUCKET` | repo variable | `zeroknows-golden` |
| `STORE_REGION` | repo variable | `auto` (Tigris, R2); the region for AWS S3 / B2 |
| `STORE_ACCESS_KEY_ID`, `STORE_SECRET_ACCESS_KEY` | repo secrets | the store's keys (AWS keys / OIDC role if absent) |

`golden-store-check` (in zero-golden, small runner) tests a configuration: a streamed multipart upload
with the golden jobs' settings, a download back with sha256 compare, and the part arithmetic (128 MiB
parts; aws-cli raises the part size when `--expected-size` / 10,000 is larger, so even 2 TB stays
under 10,000 parts).

```
<bucket>/
  base/linux/<tag>/...           base/windows/<tag>/...        staged base releases
  linux/<linux tag>/zero-<tier>-linux.img.zst  .manifest.json  .verify.txt
  windows/<windows tag>/zero-<tier>-windows.img.zst  .manifest.json  .verify.txt
  windows/<windows tag>/zero-<tier>-windows-asus-rog-flow-z13.img.zst  .manifest.json  .verify.txt
```

The manifest holds the raw size and sha256 (to check the written NVMe), the compressed size and
sha256 (to check the download), the store endpoint and key, the image file name, the laptop
(`windows/drivers.json` target), the base release, the golden commit, the catalog version, the model
list and the verification report. Downloads are by presigned URL, made on
request.
