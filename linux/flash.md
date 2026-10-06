# Writing the Zero Linux golden image to a laptop

A laptop gets one file: the **golden image** of its tier, `zero-<tier>-linux.img.zst`. It is a raw GPT
disk (a 512 MiB EFI system partition and an ext4 root partition) that already holds the Zero stack and
**every catalog model of the tier**, with the tier's default model selected. Write it onto the
laptop's NVMe and the laptop works the moment it is turned on: nothing is downloaded on the laptop,
nothing is added by hand.

| Golden image | Laptop | Models | Image size (raw, about) | Minimum NVMe |
|---|---|---|---|---|
| `zero-pro-linux.img.zst` | HP ZBook Ultra G1a, 64 GB | 8 (≈ 174 GB), default Qwen3.8 27B UD-Q4_K_XL | ≈ 193 GB | 256 GB (ships on 1 TB) |
| `zero-max-linux.img.zst` | HP ZBook Ultra G1a, 128 GB | 15 (≈ 798 GB), default Qwen3.8 27B Q8_0 | ≈ 817 GB | 1 TB (ships on 2 TB) |
| `zero-ultra-linux.img.zst` | Lenovo ThinkPad P16 Gen 3, 128 GB | 15 (≈ 719 GB), default Qwen3.8 27B UD-Q4_K_XL | ≈ 738 GB | 1 TB (ships on 2 TB) |

The exact byte sizes and sha256 values are in each image's manifest (`zero-<tier>-linux.manifest.json`).
The image is only as large as its contents; on the first boot the root partition grows to fill the
NVMe, so the owner gets the rest of the drive. The image holds no user account: GNOME's setup
assistant creates the owner's account on the first boot.

**Never boot a unit at the factory unless it is going to be re-flashed.** The first boot creates the
owner account, the machine id, the per-machine llama-server API key and the grown root partition. You
cannot undo that.

## 1. Get the image and check it

The golden images are in the private S3 bucket of the Zero team, under `linux/<base release>/`, next
to their manifests and verification reports (see `golden/README.md`). The Zero team sends a download
link (an S3 presigned URL) per file.

```sh
curl -fLo zero-max-linux.img.zst '<presigned URL of the image>'
curl -fLo zero-max-linux.manifest.json '<presigned URL of the manifest>'
python3 -c 'import json; m=json.load(open("zero-max-linux.manifest.json")); print(m["zst_sha256"], " zero-max-linux.img.zst")' | sha256sum -c -
python3 -m json.tool zero-max-linux.manifest.json | grep -E '"(raw_bytes|raw_sha256|verification)"'
```

`verification` must be `PASS`. The manifest also lists every model, the base release and the catalog
version the image was built from.

## 2. Write it to a laptop's NVMe from a USB live stick

1. Make a live USB from any current Linux (Debian 13 or Ubuntu 24.04 "Try" mode both work and both
   boot with Secure Boot on). Put the `.img.zst` and its manifest on a second stick or a network share
   (a Max image is about 800 GB: use an external SSD or an NFS/SMB share).
2. Boot the laptop from USB. On the HP ZBook Ultra G1a press **F9** at power-on. On the Lenovo
   ThinkPad P16 Gen 3 press **F12**.
3. Find the internal disk. It is the NVMe, not the USB stick:
   ```sh
   lsblk -d -o NAME,SIZE,MODEL,TRAN
   ```
   Below, the disk is `/dev/nvme0n1`. If the P16 has two NVMe drives, pick the one you boot from.
4. Discard the old contents (fast; it also TRIMs the SSD), write, and check:
   ```sh
   sudo blkdiscard -f /dev/nvme0n1
   zstd -dc zero-max-linux.img.zst | \
     sudo dd of=/dev/nvme0n1 bs=16M iflag=fullblock oflag=direct conv=fsync status=progress
   # read back exactly raw_bytes and compare with raw_sha256 from the manifest
   RAW=$(python3 -c 'import json; print(json.load(open("zero-max-linux.manifest.json"))["raw_bytes"])')
   sudo head -c "$RAW" /dev/nvme0n1 | sha256sum
   sudo sgdisk -e /dev/nvme0n1     # move the backup GPT header to the real end of the disk
   ```
   `sgdisk -e` is optional (the first boot fixes the GPT when it grows the root partition), but it
   keeps tools that look at the disk before the first boot happy.
5. Power off and remove the stick.

Firmware settings: UEFI boot (the default on both models). Secure Boot can stay **on** for Zero
Pro/Max. On Zero Ultra it must be **off**, or the NVIDIA driver must be enrolled once. See
"Secure Boot" in `linux/README.md`. The image boots through the removable-media path
`\EFI\BOOT\BOOTX64.EFI` and writes no firmware boot entries.

## 3. Clonezilla and disk duplicators

- **Clonezilla Live as the boot stick.** Choose *Enter command line prompt* and run the pipeline of
  step 2. Clonezilla Live includes `zstd`, `dd`, `blkdiscard` and `sgdisk`.
- **Clonezilla as the duplicator.** Write the golden image to one disk as in step 2 *without booting
  it*, then Clonezilla → `device-image` → `savedisk`. Partclone copies only the used blocks of the
  ext4 and vfat partitions. Restore with `restoredisk` per laptop, or multicast a bench with
  Clonezilla SE (DRBL). Restoring to a larger NVMe is fine: the root partition grows on the first boot.
- **Hardware NVMe duplicators** take a raw image: decompress it once
  (`zstd -d zero-max-linux.img.zst`, needs `raw_bytes` of free space), check it against `raw_sha256`,
  and copy that `.img` sector by sector. A duplicator that copies only used blocks is fine too
  (ext4 + vfat).

## 4. What was checked before the image was released

The golden build (`golden/`, see `golden/README.md`) refuses to publish an image as verified unless:

- every model file of the tier is read back from the finished image and its size and sha256 match
  `models/catalog.json`;
- the image, booted for its first boot in QEMU/KVM with OVMF on a drive the size of the laptop's NVMe
  (Secure Boot on for Pro/Max, off for Ultra), grows its root to the drive, has no user baked in,
  makes its own API key, starts `lecore-llama` on the tier's default model by itself, the default
  model answers on `127.0.0.1:8080` (with the key; without it, 401), the chat on `127.0.0.1:7860`
  answers through the model, and both services stay confined to loopback while the OS reaches the
  internet.

The VM has no GPU, so in that test the model runs on the CPU. That the Vulkan GPU path works on the
real laptops is checked on the first laptop of each model (`journalctl -u lecore-llama` names the
Vulkan device).

## 5. Base images, and changing models on one laptop

The GitHub release `linux-YYYYMMDD-<sha>` (and its public mirror) holds the **base** image: the same
system with no models, 16 GiB. It is the input of the golden build, not something to ship: a laptop
flashed with only the base image has no model. Its parts are `zero-<tag>.img.zst.part00…` plus
`SHA256SUMS` (`cat` the parts, then `zstd -d`).

On a shipped laptop the owner switches the served model with `zero-model list` and
`sudo zero-model use <id>`. Service work that must put a model back (or a different default) onto a
disk uses `provision/linux-add-models.sh` (`--target <mounted root>` or `--image <file>`; `--help`).

## 6. How a factory imaging service takes this

1. **One golden image per tier**: `zero-pro-linux`, `zero-max-linux`, `zero-ultra-linux`, each with
   its manifest (sha256, size, model list). Pro and Max go on the HP ZBook Ultra G1a (64 GB / 128 GB
   RAM), Ultra on the Lenovo ThinkPad P16 Gen 3.
2. **Duplication**: `zstd -dc | dd` from a live stick, Clonezilla, or a duplicator (section 3).
3. **BIOS settings**: UEFI boot. Secure Boot on for Pro/Max. For Ultra, Secure Boot off, or on with
   the NVIDIA MOK enrollment done by the owner (see the README).
4. **No boot before shipping**: the first boot is the owner's.
5. **Per release**: the Zero team rebuilds the golden images when the base image or
   `models/catalog.json` changes (`golden/build-golden.sh`) and sends new manifests.
