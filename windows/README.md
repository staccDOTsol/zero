# Zero — Windows factory image

Zero Pro, Zero Max and Zero Ultra ship Windows 11 Pro with the Zero stack: a local model
(llama.cpp `llama-server`, Vulkan) and the leCore chat, with **zero egress**: the laptop makes no
outbound network connections. leCore is the engine inside; the user sees "Zero".

| Image | Hardware | Tiers |
|---|---|---|
| `zero-hp-zbook-ultra-g1a-win11pro-<build>.iso` | HP ZBook Ultra G1a, AMD Ryzen AI Max+ 395, Radeon 8060S | Zero Pro, Zero Max |
| `zero-lenovo-p16-gen3-win11pro-<build>.iso` | Lenovo ThinkPad P16 Gen 3, Core Ultra 9 275HX, RTX PRO 5000 Blackwell 24 GB | Zero Ultra |

Built by [`.github/workflows/windows-image.yml`](../.github/workflows/windows-image.yml) and published
to the **private** GitHub Release `windows-YYYYMMDD-<shortsha>`:

- `<iso>.part01`, `.part02`, … — each ISO in ≤ 1.9 GiB parts (release assets must be < 2 GiB)
- `lecore-plus-windows-stack.zip` — the stack installer + lockdown on its own, for imaging partners
- `SHA256SUMS` — every part, every whole ISO, the stack zip

This repo contains Microsoft's Windows installer. It is only for imaging licensed Zero laptops.
**Never make it public.**

## What is in the ISO

- **Windows 11 Pro only**, exported from Microsoft's official Windows 11 x64 English ISO (fetched in CI
  with [Fido](https://github.com/pbatard/Fido) from Microsoft's download service and checked against the
  SHA-256 Microsoft publishes on microsoft.com/software-download/windows11, plus the Microsoft
  signature on `setup.exe`). No product key: each laptop's firmware carries an OEM Windows 11 Pro key.
- **Drivers injected offline** (Windows Update never runs on a zero-egress laptop), all from the
  vendors' own servers, pinned by sha256 in [`drivers.json`](drivers.json):
  - HP: *HP ZBook Ultra G1a MWS Windows 11 Driver Pack* (SoftPaq sp168475) + **AMD Software: Adrenalin
    Edition** (Radeon 8060S, Vulkan) from drivers.amd.com.
  - Lenovo: *ThinkPad P16 Gen 3 SCCM driver pack, Windows 11 25H2* + the Lenovo WinPE pack (Intel RST /
    VMD, so Setup sees the NVMe disk) + **NVIDIA RTX Enterprise driver** (RTX PRO 5000 Blackwell, Vulkan).
  - Both the OEM pack's GPU driver and the vendor's current GPU driver are in the driver store; Windows
    picks the best match. The build log lists every display INF that matches the GPU's PCI ID.
- **The zero-egress lockdown pre-applied to the image** (`lockdown.ps1 -OfflineImage`), so egress is
  blocked from the very first boot, before OOBE.
- **The stack installer** under `C:\Windows\Setup\Scripts\lecore-plus\`, run by `autounattend.xml`
  in the *specialize* pass (Microsoft disables `SetupComplete.cmd` when an OEM product key is used, which
  these laptops have; `SetupComplete.cmd` is included as an idempotent fallback).
- `autounattend.xml`: en-US; EULA accepted; no Microsoft-account screens; no Wi-Fi page;
  `BypassNRO` so OOBE completes offline; the owner creates a **local account** at OOBE; privacy
  settings page skipped with everything off (`ProtectYourPC 3` + policies); "Zero" in Settings > About.
  Disk selection stays interactive (see *Unattended disk layout*).
- `install.wim` split into `install.swm` parts < 4 GB, so the USB stick can be FAT32.

Models are **not** in the ISO (see *Models*).

## Make the USB stick

Download every part of one ISO plus `SHA256SUMS` from the release into one folder, then on Windows,
elevated:

```powershell
Get-Disk                                    # find the USB stick (BusType USB)
.\windows\make-usb.ps1 -Parts D:\release -DiskNumber 3
```

`make-usb.ps1` checks each part against `SHA256SUMS`, reassembles the ISO, **erases** the stick,
makes one FAT32 partition (GPT, ≤ 31 GB) and copies the files. UEFI boot, Secure Boot can stay on.

Or reassemble by hand and use Rufus:

```
copy /b zero-...iso.part01 + zero-...iso.part02 + zero-...iso.part03 + zero-...iso.part04 + zero-...iso.part05 zero-...iso
certutil -hashfile zero-...iso SHA256          (compare with SHA256SUMS)
```
(`cat zero-...iso.part* > zero-...iso` on Linux/macOS.) In Rufus pick the ISO, partition scheme GPT,
target UEFI, file system FAT32 (the image is already split), and **untick** every "Windows User
Experience" customization: the ISO's own `autounattend.xml` already does that job.

## Install a laptop

1. Boot the laptop from the stick (F9 on HP, F12 on Lenovo). Keep it **off the network**.
2. Choose the internal NVMe disk; delete its partitions if it has an old install. Setup installs
   Windows 11 Pro, then the *specialize* pass installs the Zero stack and applies the lockdown
   (`C:\Windows\Setup\Scripts\lecore-plus-specialize.log`, `C:\ProgramData\leCore+\logs\install-*.log`).
3. OOBE: region/keyboard, then the owner names the local account. No network, no Microsoft account.
4. At sign-in Zero opens (Edge app window on `http://127.0.0.1:7860`). With no model on the disk
   the chat runs memory-only and the model service stops cleanly.
5. Add the models (next section) before the laptop leaves the station.

## Models

Models are 10–100 GB each and are not baked into the image. The imaging station downloads them from
Hugging Face, checks every sha256 against [`models/catalog.json`](../models/catalog.json) and copies
them onto the laptop. **Every model that fits a tier is preloaded.**

```powershell
# On the imaging station (has internet). W: = the laptop's Windows volume attached to the station,
# or C: when running on the laptop itself while it is still on the imaging network.
.\provision\windows-add-models.ps1 -All pro   -Target W: -Cache D:\zero-model-cache   # ~174 GB
.\provision\windows-add-models.ps1 -All max   -Target W: -Cache D:\zero-model-cache   # ~798 GB
.\provision\windows-add-models.ps1 -All ultra -Target W: -Cache D:\zero-model-cache   # ~719 GB
```

- `-All <tier>` installs every model whose `builds.<tier>` is not null; `model.txt` names the model
  whose `default_for` includes the tier (override with `-Default <id>`).
- `-Models id1,id2 -Tier <tier>` installs only those (model.txt = `-Default`, else the tier default
  if present, else the first id).
- Files land flat in `C:\ProgramData\leCore+\models\`; `model.txt` holds one file name (the first part
  of a split GGUF; llama-server loads the other parts from the same folder). An inventory is written to
  `C:\ProgramData\leCore+\models.json`.
- `-Cache` keeps verified downloads on the station so the next laptop is a copy (each copy is
  re-hashed unless `-SkipCopyVerify`). `-DryRun` prints the plan and sizes.

**Golden-image flow (recommended):** install one laptop per image from the USB stick, run
`windows-add-models.ps1 -All <tier>` once onto it, then capture that disk with your imaging tool
and clone it to the other laptops of the same tier (a Pro golden image and a Max golden image from the
HP ISO, an Ultra golden image from the Lenovo ISO). Run one load test per model on the golden image
before shipping (`Start-Service lecore-llama` after editing `model.txt`, then
`Invoke-RestMethod http://127.0.0.1:8080/v1/models`).

## What runs on the laptop

| | Service (WinSW wrapper, `NT AUTHORITY\LocalService`) | Listens | Path |
|---|---|---|---|
| Zero model server | `lecore-llama` → `run-llama.ps1` → `llama-server --host 127.0.0.1 --port 8080 -ngl 999 -m <model>` | 127.0.0.1:8080 (`/v1`) | `C:\Program Files\leCore+\llama\` (llama.cpp b11430, Vulkan x64) |
| Zero chat | `lecore-chat` → `lecore_plus_chat.py` → leCore `chat_server.py` | 127.0.0.1:7860 | `C:\Program Files\leCore+\lecore\` (leCore `21abb4f`, MIT) on Python 3.13.16 embeddable |

- Both are automatic services with restart-on-failure. No model configured → `lecore-llama` logs why
  and stops (exit 0); `Start-Service lecore-llama` after adding one. Extra llama-server flags (one per
  line) go in `C:\ProgramData\leCore+\llama-args.txt`.
- The chat runs leCore's own `chat_server.py` unmodified. At the pinned commit it does not read
  `LECORE_LLM_URL` itself, so the launcher attaches leCore's `remote_llm` rung pointed at
  `LECORE_LLM_URL=http://127.0.0.1:8080/v1`; with no model (or llama-server down) the rung returns
  nothing and the chat answers memory-only. Memory partition: `C:\ProgramData\leCore+\memory\`
  (seeded from leCore's `release_bundle`).
- Python packages were installed from a wheelhouse in the payload (`pip --no-index`, hashes required);
  NLTK corpora leCore references are pre-staged and `nltk.download()` is an offline no-op; Hugging
  Face libraries are set offline. Nothing on the laptop downloads.
- Start menu: **Zero** (`msedge --app=http://127.0.0.1:7860`). At sign-in the All Users Startup entry
  waits for the chat and opens the same app window.
- Logs: `C:\ProgramData\leCore+\logs\` (`lecore-chat.out.log`, `lecore-llama.out.log`, install logs).

## What the lockdown turns off, and why

`C:\Program Files\leCore+\setup\lockdown.ps1` (applied offline to the image, again in the specialize
pass, and a firewall-only check at every boot via the `\Zero\Zero zero-egress check` task). Every
action is logged to `C:\ProgramData\leCore+\lockdown\lockdown-*.csv`. Run it with `-WhatIf` to see the
full list.

| Area | What | Why |
|---|---|---|
| Firewall | On for Domain/Private/Public; `DefaultOutboundAction Block` (local store **and** policy); every enabled outbound Allow rule disabled (names recorded); one Block rule for all non-loopback addresses | The guarantee. Loopback (127.0.0.0/8, ::1) is not filtered, so Edge → chat → model works. DHCP/DNS are blocked too: the laptop never puts a packet on the wire. |
| Windows Update | `wuauserv`, `UsoSvc`, `WaaSMedicSvc` disabled; `NoAutoUpdate`, `DoNotConnectToWindowsUpdateInternetLocations`, no driver search on WU; WU scheduled tasks disabled | All drivers are in the image; updates would need egress. |
| Delivery Optimization | `DoSvc` disabled, `DODownloadMode 99` | Peer/cloud downloads. |
| Telemetry | `DiagTrack`, `dmwappushservice` disabled; `AllowTelemetry 0`; CEIP, app inventory, error reporting, feedback off | Windows 11 **Pro** treats `AllowTelemetry 0` as 1 ("Required"); with DiagTrack disabled and the firewall closed nothing is sent. |
| Connectivity probe | NCSI `NoActiveProbe`, `EnableActiveProbing 0` | No msftconnecttest.com probes (the network icon will say "No internet"). |
| Time | `W32Time`, `tzautoupdate` disabled; NTP client policy off | NTP is egress. The clock runs from the RTC; set the time zone by hand. |
| Store | `AutoDownload 2`, `InstallService` disabled | No app updates. |
| Edge | `edgeupdate`/`edgeupdatem` + update tasks disabled; policies: no sign-in, no sync, no SmartScreen, no diagnostic data, no component updates, no search suggestions, no sidebar/Copilot, no first-run | The app window is local-only. |
| Defender | Cloud protection (MAPS) off, sample submission never, block-at-first-sight off | Local antimalware keeps running. **Signature updates need manual offline packages** (below). With Tamper Protection on, Windows ignores these two settings; the firewall still blocks the traffic. |
| Search | No Bing/web results or suggestions in Start, no Cortana, no cloud search | |
| OneDrive | Sync client disabled by policy; setup not run for new users | |
| Copilot / Recall | Copilot app removed, Copilot policy off; Recall feature removed + `DisableAIDataAnalysis`, `AllowRecallEnablement 0`; Click to Do off | The HP has a Copilot+-class NPU. |
| Consumer features | Suggested/silently installed apps, tips, Spotlight, Widgets news, Start recommendations off; cloud-only apps removed (Bing News/Weather/Search, Office hub, new Outlook, Teams, Clipchamp, To Do, Feedback Hub, Get Help, Quick Assist, Family, Phone Link, Solitaire, Dev Home) | `DisableWindowsConsumerFeatures` is honoured only on Enterprise/Education, so Pro also gets the per-user settings in the default profile. |
| Other egress | Location, Find my device, advertising ID, activity history, inking/typing + online speech, settings sync, root-certificate auto-update, online font providers, map downloads, push notifications from the cloud, SmartScreen | |

### Activation

The firmware key is picked up automatically (no key in `autounattend.xml`). Windows **activation**
itself contacts Microsoft once; under zero egress it cannot. Either activate at the imaging station
before the laptop leaves (open egress briefly, see below, then run `lockdown.ps1` again), or the owner
uses phone activation (`slui 4`). Windows keeps working unactivated, with the "Activate Windows" notice.

### Defender signatures offline

On a connected PC download the x64 definition package `mpam-fe.exe` from
<https://www.microsoft.com/en-us/wdsi/defenderupdates>, copy it over on a USB stick, run it elevated.

## Opening egress deliberately (owner)

Elevated PowerShell on the laptop:

```powershell
& 'C:\Program Files\leCore+\setup\open-egress.ps1'                  # firewall only
& 'C:\Program Files\leCore+\setup\open-egress.ps1' -WindowsUpdate   # also turn Windows Update back on
& 'C:\Program Files\leCore+\setup\open-egress.ps1' -TimeSync        # also NTP
```

It removes the block rule and the firewall policy, sets the default outbound action to Allow,
re-enables the outbound rules the lockdown disabled, and disables the boot-time check. To close
egress again: `& 'C:\Program Files\leCore+\setup\lockdown.ps1'`.

## For factory imaging partners (HP / Lenovo services, distributors)

`lecore-plus-windows-stack.zip` (same release) is the stack on its own, for partners who build and
capture their own Windows 11 Pro WIM:

1. Use Windows 11 Pro x64 with your own driver set for the model (see `drivers.json` for ours).
2. In **audit mode** (or your task sequence, as SYSTEM), unzip and run, elevated:
   ```powershell
   .\lecore-plus-windows-stack\install.ps1              # install + lockdown
   .\lecore-plus-windows-stack\install.ps1 -SkipLockdown # if you lock down later in your sequence
   ```
   Everything installs from `payload\` (verified against `manifest.json`); nothing is downloaded.
   Re-running is safe.
3. Add the models with `provision\windows-add-models.ps1 -All <tier> -Target <volume>`.
4. Apply `lockdown.ps1` last (or let `install.ps1` do it), then sysprep/capture as usual. To pre-lock
   an offline image instead: `lockdown.ps1 -OfflineImage <mount dir>` against a DISM-mounted WIM.
5. If your flow uses `SetupComplete.cmd`, ours is in the zip: it runs `install.ps1` from
   `%WINDIR%\Setup\Scripts\lecore-plus\`. Remember Windows skips `SetupComplete.cmd` when an OEM product
   key is present; use an unattend `RunSynchronous` command in the specialize pass instead, as
   `windows/image/autounattend.xml` does.

## Unattended disk layout

The ISO never erases a disk by itself. To make a fully unattended factory stick, add a
`DiskConfiguration` + `ImageInstall/OSImage/InstallTo` block to the `windowsPE` pass of
`windows/image/autounattend.xml` and rebuild. That stick then wipes disk 0 of any PC it boots.

## Building

`workflow_dispatch` the **windows-image** workflow (`mode: full`). Inputs: `targets`, `iso_url` /
`iso_sha256` (use your own copy of Microsoft's ISO if Microsoft refuses the runners), `publish`.
`mode: probe` downloads and extracts every driver package and prints sha256s (to pin a new driver);
pushes to `windows/**` run the stack build and the smoke test. Each image job: ADK Deployment Tools
(oscdimg) → ISO → drivers → DISM servicing → oscdimg → split + upload, about 1–2 h per target.

The CI smoke test installs the stack on the runner **without** the lockdown, starts both services,
provisions a tiny test GGUF (never shipped) through `windows-add-models.ps1`, checks
`/v1/models`, a chat answer that comes from the model, that the chat process attempted no non-loopback
connection, and that `lockdown.ps1 -WhatIf` runs clean and changes nothing.
