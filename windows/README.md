# Zero — Windows factory image

Zero Pro, Zero Max and Zero Ultra ship Windows 11 Pro with the Zero stack: a local model
(llama.cpp `llama-server`, Vulkan) and the leCore chat, with **zero egress**: the model's input and
output never leave the machine. The laptop itself is a normal online PC (Windows Update, Edge, the
Store all use the network); only the two inference programs are walled off. leCore is the engine
inside; the user sees "Zero".

| Image | Hardware | Tiers |
|---|---|---|
| `zero-hp-zbook-ultra-g1a-win11pro-<build>.iso` | HP ZBook Ultra G1a, AMD Ryzen AI Max+ 395, Radeon 8060S | Zero Pro, Zero Max |
| `zero-lenovo-p16-gen3-win11pro-<build>.iso` | Lenovo ThinkPad P16 Gen 3, Core Ultra 9 275HX, RTX PRO 5000 Blackwell 24 GB | Zero Ultra |

Built by [`.github/workflows/windows-image.yml`](../.github/workflows/windows-image.yml) and published
to the **private** GitHub Release `windows-YYYYMMDD-<shortsha>`:

- `<iso>.part01`, `.part02`, … — each ISO in ≤ 1.9 GiB parts (release assets must be < 2 GiB)
- `lecore-plus-windows-stack.zip` — the stack installer + model containment on its own, for imaging partners
- `SHA256SUMS` — every part, every whole ISO, the stack zip

This repo contains Microsoft's Windows installer. It is only for imaging licensed Zero laptops.
**Never make it public.**

## What is in the ISO

- **Windows 11 Pro only**, exported from Microsoft's official Windows 11 x64 English ISO (fetched in CI
  with [Fido](https://github.com/pbatard/Fido) from Microsoft's download service and checked against the
  SHA-256 Microsoft publishes on microsoft.com/software-download/windows11, plus the Microsoft
  signature on `setup.exe`). No product key: each laptop's firmware carries an OEM Windows 11 Pro key.
- **Drivers injected offline**, so the laptop works fully from first boot with or without a network
  (Windows Update may bring newer ones later), all from the vendors' own servers, pinned by sha256 in
  [`drivers.json`](drivers.json):
  - HP: *HP ZBook Ultra G1a MWS Windows 11 Driver Pack* (SoftPaq sp168475) + **AMD Software: Adrenalin
    Edition** (Radeon 8060S, Vulkan) from drivers.amd.com.
  - Lenovo: *ThinkPad P16 Gen 3 SCCM driver pack, Windows 11 25H2* + the Lenovo WinPE pack (Intel RST /
    VMD, so Setup sees the NVMe disk) + **NVIDIA RTX Enterprise driver** (RTX PRO 5000 Blackwell, Vulkan).
  - Both the OEM pack's GPU driver and the vendor's current GPU driver are in the driver store. Both
    list the laptop's exact PCI subsystem ID, so Windows picks the newer one: AMD 32.0.31041.1004
    (Adrenalin 26.8.1) over HP's 32.0.22018.5; NVIDIA 32.0.15.9716 (597.16, `nvltwi.inf`) over
    Lenovo's 32.0.15.9658. Of NVIDIA's 20 display INFs only the 3 that list this GPU (DEV_2C38:
    `nvltwi.inf` for Lenovo, plus the HP and Dell variants) are injected; each one adds a ~1.3 GB copy
    to the driver store. The NVIDIA package ships the Vulkan loader; HP's AMD INF registers the Vulkan
    ICD. Check Vulkan on the first laptop of each model:
    `& 'C:\Program Files\leCore+\llama\llama-server.exe' --list-devices` must list `Vulkan0`.
- **Privacy toggles and the registry part of the model containment pre-applied to the image**
  (`lockdown.ps1 -OfflineImage`); the per-program firewall rules are added when the stack is installed.
- **The stack installer** under `C:\Windows\Setup\Scripts\lecore-plus\`, run by `autounattend.xml`
  in the *specialize* pass (Microsoft disables `SetupComplete.cmd` when an OEM product key is used, which
  these laptops have; `SetupComplete.cmd` is included as an idempotent fallback).
- `autounattend.xml`: en-US; EULA accepted; no Microsoft-account screens; no Wi-Fi page;
  `BypassNRO` so OOBE completes offline; the owner creates a **local account** at OOBE; privacy
  settings page skipped with everything off (`ProtectYourPC 3` + policies); "Zero" in Settings > About.
  Disk selection stays interactive (see *Unattended disk layout*).
- `install.wim` split into `install.swm` parts < 4 GB, so the USB stick can be FAT32.

The ISO has no models. Laptops ship the tier's **golden image** instead, built from this ISO with
every model of the tier inside (see *Models*).

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
   Windows 11 Pro, then the *specialize* pass installs the Zero stack and applies the model containment
   (`C:\Windows\Setup\Scripts\lecore-plus-specialize.log`, `C:\ProgramData\leCore+\logs\install-*.log`).
3. OOBE: region/keyboard, then the owner names the local account. No network, no Microsoft account.
4. At sign-in Zero opens (Edge app window on `http://127.0.0.1:7860`). With no model on the disk
   the chat runs memory-only and the model service just waits for one.
5. A laptop installed from the ISO has no models: put them back with
   `provision\windows-add-models.ps1 -All <tier>` (next section). Shipped laptops get the golden image
   instead, which already has them.

## Models

Shipped laptops get the **golden image** of their tier (`golden/`, see the top-level README): Windows
11 Pro installed from this ISO in a VM (the stack installed by this ISO's `install.ps1`), every
catalog model of the tier written into `C:\ProgramData\leCore+\models\`, the tier default in
`model.txt`, then generalized with `sysprep /generalize /oobe`. It is one raw disk image per tier
(`zero-pro-windows`, `zero-max-windows` from the HP ISO, `zero-ultra-windows` from the Lenovo ISO)
that the imaging team writes onto the NVMe. **Every model that fits a tier ships**; nothing is
downloaded on the laptop. On its first boot each laptop specializes (new SID, its drivers) and runs
the golden first-boot step (C: to the end of the disk, model file ACLs, a fresh API key, the Windows
key from the laptop's firmware; again as the `\Zero\Zero golden first boot` startup task), and OOBE
asks the owner for a local account. How to write it and how it was verified: `golden/README.md`.

Model files sit flat in `C:\ProgramData\leCore+\models\`; `model.txt` holds one file name (the first
part of a split GGUF; llama-server loads the other parts from the same folder); `models.json` is the
inventory. To change the served model: edit `model.txt`, then `Restart-Service lecore-llama`.

For service work (a laptop reinstalled from the ISO, a different default), `provision\windows-add-models.ps1`
writes the same files from Hugging Face, checking every sha256 against
[`models/catalog.json`](../models/catalog.json):

```powershell
# W: = the laptop's Windows volume attached to this machine, or C: on the laptop itself (needs internet)
.\provision\windows-add-models.ps1 -All pro   -Target W: -Cache D:\zero-model-cache   # ~174 GB
.\provision\windows-add-models.ps1 -All max   -Target W: -Cache D:\zero-model-cache   # ~798 GB
.\provision\windows-add-models.ps1 -All ultra -Target W: -Cache D:\zero-model-cache   # ~719 GB
```

- `-All <tier>` installs every model whose `builds.<tier>` is not null; `model.txt` names the model
  whose `default_for` includes the tier (override with `-Default <id>`).
- `-Models id1,id2 -Tier <tier>` installs only those (model.txt = `-Default`, else the tier default
  if present, else the first id).
- `-Cache` keeps verified downloads so the next run is a copy (each copy is re-hashed unless
  `-SkipCopyVerify`). `-DryRun` prints the plan and sizes.

## What runs on the laptop

| | Service (WinSW wrapper, `NT AUTHORITY\LocalService`) | Listens | Path |
|---|---|---|---|
| Zero model server | `lecore-llama` → `run-llama.ps1` → `llama-server --host 127.0.0.1 --port 8080 -ngl 999 -m <model> --offline --no-webui --cors-origins localhost --api-key-file …` | 127.0.0.1:8080 (`/v1`) | `C:\Program Files\leCore+\llama\` (llama.cpp b11430, Vulkan x64) |
| Zero chat | `lecore-chat` → `lecore_plus_chat.py` → leCore `chat_server.py` | 127.0.0.1:7860 | `C:\Program Files\leCore+\lecore\` (leCore `21abb4f`, MIT) on Python 3.13.16 embeddable |

- Both are automatic services with restart-on-failure. No model configured → `lecore-llama` is a clean
  no-op: nothing listens on :8080, it logs why and checks `model.txt` every 15 s, so a model added at
  imaging time starts by itself. After *changing* `model.txt`: `Restart-Service lecore-llama`. Extra
  llama-server flags (one per line) go in `C:\ProgramData\leCore+\llama-args.txt`.
- The chat runs leCore's own `chat_server.py` unmodified. At the pinned commit it does not read
  `LECORE_LLM_URL` itself, so the launcher attaches leCore's `remote_llm` rung pointed at
  `LECORE_LLM_URL=http://127.0.0.1:8080/v1`; with no model (or llama-server down) the rung returns
  nothing and the chat answers memory-only. Memory partition: `C:\ProgramData\leCore+\memory\`
  (seeded from leCore's `release_bundle`).
- Python packages were installed from a wheelhouse in the payload (`pip --no-index`, hashes required);
  NLTK corpora leCore references are pre-staged and `nltk.download()` is an offline no-op; Hugging
  Face libraries are set offline. Nothing in the stack downloads at runtime.
- Start menu: **Zero** (`msedge --app=http://127.0.0.1:7860`). At sign-in the All Users Startup entry
  waits for the chat and opens the same app window.
- Logs: `C:\ProgramData\leCore+\logs\` (`lecore-chat.out.log`, `lecore-llama.out.log`, install logs).

## Zero egress: what keeps the model's input and output on the machine

`C:\Program Files\leCore+\setup\lockdown.ps1` (registry part applied offline to the image; everything
again in the specialize pass; the firewall part re-asserted at every boot by the
`\Zero\Zero model containment check` task). Every action is logged to
`C:\ProgramData\leCore+\lockdown\lockdown-*.csv`; `-WhatIf` prints the full list.

| What | How | Why |
|---|---|---|
| Firewall, per program | Windows Firewall on, **DefaultOutboundAction Allow** on Domain/Private/Public. Outbound **and** inbound Block rules for every non-loopback address (everything except 127.0.0.0/8 and ::1) on exactly `C:\Program Files\leCore+\llama\llama-server.exe` and leCore's embedded `C:\Program Files\leCore+\python\python.exe` / `pythonw.exe` | The guarantee. Block rules beat allow rules. Any other Python, Edge, Windows Update etc. network normally. |
| Loopback only | `llama-server --host 127.0.0.1`; the chat binds `127.0.0.1:7860` | Nothing on the LAN can talk to them. |
| llama.cpp | `--offline` (never downloads), `--no-webui` (no built-in web UI; Zero's UI is the chat), `--cors-origins localhost` (no web page from elsewhere can read answers) | llama.cpp has no telemetry; these close its remote-fetch paths. |
| Per-machine API key on :8080 | `install.ps1` generates 256 random bits on each laptop (Windows Setup's specialize pass) into `C:\ProgramData\leCore+\secret\llama-api-key`, readable only by the two Zero services (service SIDs `NT SERVICE\lecore-llama` / `NT SERVICE\lecore-chat`), SYSTEM and Administrators. llama-server reads it with `--api-key-file` (the key is not on the command line); every request except `/health` needs `Authorization: Bearer <key>`; the chat's rung sends it. Without the file llama-server is not started | Loopback is not a trust boundary with a browser on the machine: a web page can point its own name at 127.0.0.1 (DNS rebinding). Your own tools: `$k = Get-Content 'C:\ProgramData\leCore+\secret\llama-api-key'` (elevated), header `Authorization: Bearer $k`. |
| leCore chat | Host allow-list (`127.0.0.1:7860`, `localhost:7860`) against DNS rebinding; cross-site POSTs refused; `Content-Security-Policy` so the chat page loads and sends nothing outside 127.0.0.1 (model text such as `<img src=https://…>` cannot leak) | The browser is online, so the chat must not answer other sites. |
| leCore Python | NLTK corpora pre-staged, `nltk.download()` is an offline no-op; Hugging Face libraries offline | leCore has no telemetry; these are its only automatic downloads. |
| Crash dumps | Windows Error Reporting excludes `llama-server.exe`, `python.exe`, `pythonw.exe` | A dump is the process memory, i.e. prompts and answers. |
| Edge (the Zero window) | Off: Microsoft Editor cloud proofing + synonyms, text prediction, Copilot page context. Everything else in Edge is untouched | These send what you type, or what the page shows, to Microsoft. Windows' local spell check still works. |
| Privacy toggles | The OOBE privacy page, all off: location, Find my device, diagnostic data Required only (`AllowTelemetry 0`; Pro's floor is "Required"), inking & typing, online speech recognition, tailored experiences, advertising ID | Original image requirement. |

The models are on the disk when the laptop ships (golden image); nothing has to be downloaded for them.

leCore features that need the network, and therefore **do not work** while contained (the chat says
it could not reach the address): the chat commands `learn api: <URL>` / `use api: service.endpoint`
(call outside HTTP APIs), and attaching a non-local model under Settings. They are left as they are.

### Letting the inference programs reach the network (owner, deliberately)

```powershell
& 'C:\Program Files\leCore+\setup\open-egress.ps1'     # removes the 6 containment rules + the boot-time check
& 'C:\Program Files\leCore+\setup\lockdown.ps1'        # contains them again
```

## For factory imaging partners (HP / Lenovo services, distributors)

`lecore-plus-windows-stack.zip` (same release) is the stack on its own, for partners who build and
capture their own Windows 11 Pro WIM:

1. Use Windows 11 Pro x64 with your own driver set for the model (see `drivers.json` for ours).
2. In **audit mode** (or your task sequence, as SYSTEM), unzip and run, elevated:
   ```powershell
   .\lecore-plus-windows-stack\install.ps1              # install + model containment
   .\lecore-plus-windows-stack\install.ps1 -SkipLockdown # if you run lockdown.ps1 later in your sequence
   ```
   Everything installs from `payload\` (verified against `manifest.json`); nothing is downloaded.
   Re-running is safe.
3. Add the models with `provision\windows-add-models.ps1 -All <tier> -Target <volume>`.
4. Apply `lockdown.ps1` last (or let `install.ps1` do it), then sysprep/capture as usual. Its
   registry part can also go into an offline image: `lockdown.ps1 -OfflineImage <mount dir>` against a
   DISM-mounted WIM (the firewall rules need the installed programs, so run it live once too).
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

The CI smoke test installs the stack on the runner without the machine-policy part of the lockdown,
starts both services, provisions a tiny test GGUF (never shipped) through `windows-add-models.ps1`,
checks `/v1/models`, that :8080 answers 401 without the per-machine key and with a wrong one, and a
chat answer that comes from the model, then applies the per-program firewall
part for real and proves: general outbound and another Python still reach the internet; leCore's
`python.exe` and the `llama-server.exe` path cannot (loopback still works); both listen on 127.0.0.1
only; the chat refuses rebinding / cross-site requests. It also runs the shipped Vulkan build of
llama.cpp on a software Vulkan device (Mesa lavapipe, CI only) as the `LOCAL SERVICE` account.
