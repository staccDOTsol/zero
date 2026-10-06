# Writing the Zero Linux image to a laptop

The image is one raw GPT disk (`zero-<tag>.img`): a 512 MiB EFI system partition and an ext4 root
partition, 16 GiB in total. On its first boot the root partition grows to fill the laptop's NVMe.
It holds no models and no user account. The owner creates the account on first boot.

Never boot a unit at the factory unless it is going to be re-flashed. The first boot creates the
owner account, the machine id, and the grown root partition. You cannot undo that.

## 1. Get the release and check it

Each release `linux-YYYYMMDD-<sha>` in `staccDOTsol/lecore-plus` has these assets:

| Asset | What it is |
|---|---|
| `zero-<tag>.img.zst.part00`, `part01`, … | the zstd-compressed image, split into parts of at most 1.9 GiB |
| `SHA256SUMS` | sha256 of every part, of the joined `.img.zst`, and of the raw `.img` |
| `BUILDINFO.txt`, `packages.txt` | pinned versions and the full package list |
| `smoke-report.txt`, `smoke-first-boot-screen.png` | the CI boot test of this exact image |

```sh
gh release download linux-YYYYMMDD-<sha> -R staccDOTsol/lecore-plus -D zero && cd zero
sha256sum -c --ignore-missing SHA256SUMS          # checks the parts
```

GitHub limits a release asset to 2 GiB, so the image comes in parts. The parts also fit a FAT32 stick,
which has a 4 GiB file limit.

## 2. Reassemble

To get an image file (needs 16 GiB free):

```sh
cat zero-<tag>.img.zst.part* | zstd -d --long=27 -o zero-<tag>.img
sha256sum -c --ignore-missing SHA256SUMS          # now also checks zero-<tag>.img
```

You can also stream it straight to a disk without writing a file (step 3). `--long=27` is optional with
current zstd, since 128 MiB is the default decode window. It does no harm.

## 3. Write it to a laptop's NVMe from a USB live stick

1. Make a live USB from any current Linux (Debian 13 or Ubuntu 24.04 "Try" mode both work and both
   boot with Secure Boot on). Copy the parts and `SHA256SUMS` onto the stick or onto a second stick.
2. Boot the laptop from USB. On the HP ZBook Ultra G1a press **F9** at power-on. On the Lenovo
   ThinkPad P16 Gen 3 press **F12**.
3. Find the internal disk. It is the NVMe, not the USB stick:
   ```sh
   lsblk -d -o NAME,SIZE,MODEL,TRAN
   ```
   Below, the disk is `/dev/nvme0n1`. If the P16 has two NVMe drives, pick the one you boot from.
4. Discard the old contents (fast; it also TRIMs the SSD), then write and check:
   ```sh
   sudo blkdiscard -f /dev/nvme0n1
   cat zero-<tag>.img.zst.part* | zstd -dc --long=27 | \
     sudo dd of=/dev/nvme0n1 bs=16M iflag=fullblock oflag=direct conv=fsync status=progress
   # read back exactly the image's size and compare with the .img line of SHA256SUMS
   sudo head -c "$(stat -c %s zero-<tag>.img 2>/dev/null || echo 17179869184)" /dev/nvme0n1 | sha256sum
   sudo sgdisk -e /dev/nvme0n1     # move the backup GPT header to the real end of the disk
   ```
5. Optional, before the first boot: add models (section 5). Then power off and remove the stick.

Firmware settings: UEFI boot (the default on both models). Turn network boot (PXE/IPv4/IPv6 stack)
off; see section 6. Secure Boot can stay **on** for Zero
Pro/Max. On Zero Ultra it must be **off**, or the NVIDIA driver must be enrolled once. See
"Secure Boot" in `linux/README.md`. The image boots through the removable-media path
`\EFI\BOOT\BOOTX64.EFI` and writes no firmware boot entries.

## 4. Clonezilla

Clonezilla restores its own image format, not raw `.img` files. There are two ways to use it:

- **Clonezilla as the live stick.** Boot Clonezilla Live, choose *Enter command line prompt*, and run
  the `dd` pipeline from step 3. Clonezilla Live includes `zstd`, `dd`, `blkdiscard` and `sgdisk`.
- **Clonezilla as the duplicator.** This is best for many machines and for images with models. Write
  Zero (and the models, section 5) to one *golden* disk without booting it. Then boot Clonezilla →
  `device-image` → `savedisk` to save it. Partclone copies only the used blocks of the ext4 and vfat
  partitions, so a golden Max disk saves about 800 GB of models, not the whole NVMe. Restore with
  `restoredisk` per laptop, or use Clonezilla SE (DRBL) to multicast to a whole bench. Restoring to a
  larger NVMe is fine: Zero grows its root partition on the first boot.

## 5. Models (imaging station)

Models are not in the image. `provision/linux-add-models.sh` downloads them on the **imaging
station**, checks every file's size and sha256 against `models/catalog.json`, and copies them into
`/var/lib/lecore-plus/models/`. It then writes `zero-models.json` (the manifest) and
`/etc/lecore-plus/model` (the default). The laptop never downloads anything.

Every model that fits a tier is preloaded on that tier. Catalog totals on 2026-10-05:

| Tier | Models | Download / disk | Minimum NVMe |
|---|---|---|---|
| Zero Pro | 8 | ≈ 174 GB | 512 GB (1 TB recommended) |
| Zero Max | 15 | ≈ 798 GB | 1 TB (2 TB recommended) |
| Zero Ultra | 15 | ≈ 719 GB | 1 TB (2 TB recommended) |

Station requirements: Linux with `bash`, `python3`, `curl`, `sha256sum`, and for disks and images also
`losetup`, `sgdisk` (gdisk), `growpart` (cloud-guest-utils) and `resize2fs`/`e2fsck`.
It also needs about 1 TB for the download cache. Some repos are gated (for example Google's Gemma QAT
GGUFs). Accept their license on huggingface.co once and export `HF_TOKEN`. The token goes only to
huggingface.co and never into the image.

### Per tier, once per release: the golden image

```sh
# 1. fetch and verify everything for the tier (resumable; cached files are reused)
provision/linux-add-models.sh --all max --download-only --cache /srv/zero-models

# 2. make the tier's golden image: the image file grows to fit, gets every Max model, and
#    /etc/lecore-plus/model = the catalog's default for max (override with --default <id>)
cat zero-<tag>.img.zst.part* | zstd -dc --long=27 > zero-max-<tag>.img
sudo provision/linux-add-models.sh --all max --image zero-max-<tag>.img --cache /srv/zero-models

# 3. write the golden image to each Max laptop (as in step 3, or with Clonezilla / a duplicator)
sudo dd if=zero-max-<tag>.img of=/dev/nvme0n1 bs=16M oflag=direct conv=fsync status=progress
sudo sgdisk -e /dev/nvme0n1
```

The golden image file is sparse. It takes about 820 GB on disk for Max. Run the same steps with
`--all pro` and `--all ultra` for the other tiers. Do the load test the model README asks for (one
per model) on a sample unit of each tier, then re-flash that unit. Use `sudo zero-model use <id>`
to switch models, and `journalctl -u lecore-llama` to see whether a model loaded.

### Directly onto a laptop disk (no golden file)

Write the base image (step 3). Then mount the root partition from the live stick or the imaging
station and fill it. `--grow` first grows the partition and file system to fill the NVMe:

```sh
sudo mount /dev/nvme0n1p2 /mnt/zero
sudo provision/linux-add-models.sh --all ultra --target /mnt/zero --grow --cache /srv/zero-models
sudo umount /mnt/zero
```

### Per-order selections

If an order lists specific models instead of the whole tier, pass ids. The first id becomes the
default unless you pass `--default`:

```sh
sudo provision/linux-add-models.sh --tier pro --target /mnt/zero --grow qwen3.8-27b gpt-oss-20b
```

Other options: `--dry-run` prints the plan, `--reserve-gb N` sets how much free space stays for the
owner (default 2 GiB), and `--no-verify-target` skips re-hashing the copies.

## 6. How a factory imaging service would take this

The usual inputs are one image per SKU plus a written procedure. For Zero that means:

1. **Golden image per tier.** For each tier, the base release image plus `--all <tier>` models,
   made on the imaging station as in section 5. Hand over the `.img` file, or a Clonezilla
   `savedisk` image of a golden disk, with its sha256.
2. **Duplication.** NVMe duplicators (or Clonezilla SE multicast) write the golden image to the
   laptops' drives. If the duplicator copies sector by sector, the copy is exact. If it copies used
   blocks only, that is fine too, because the file systems are ext4 and vfat.
3. **BIOS settings.** UEFI boot. Secure Boot on for Pro/Max. For Ultra, Secure Boot off, or on with
   the NVIDIA MOK enrollment done by the owner (see the README). **Network boot off:** disable
   PXE / HTTP boot / "UEFI IPv4 and IPv6 network stack" and Wake-on-LAN. Zero's OS sends nothing,
   but firmware with a network stack sends IPv6 neighbor-discovery frames at power-on. CI sees
   exactly that from the virtual machine's UEFI. On the ZBook this is under
   Advanced → Boot Options / Network. On the ThinkPad it is under Config → Network.
4. **No boot before shipping.** The first boot is the owner's: gnome-initial-setup creates the
   account and the root file system grows to fill the disk.
5. **Per release.** Build a new golden image when the image or `models/catalog.json` changes.
   Re-run `--download-only` first. It re-verifies the cache and fetches only what changed.
