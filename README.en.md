# Clean-HyperVOrphans

[简体中文](README.md) | **English**

Clean up **VHDX / AVHDX files that stay on disk after you delete a virtual machine in Hyper-V Manager**.

> **What "orphan" means here**
> The term comes from *orphaned object*: the file is still on disk, but no currently registered virtual machine — checkpoint chain and parent chain included — references it any more.
> It means **"nothing references it", not "it has no value"**. Base disks, template disks and backup disks you keep around for later attachment will also be flagged as orphans if they sit in a Hyper-V directory. The tool's job is to list them; whether to delete is your call, based on the path.

## The problem it solves

When you delete a virtual machine in Hyper-V Manager, there is an option: **"Delete the virtual hard disk files"**.

- Don't tick it → the VM configuration is gone, but the `.vhdx` file sits exactly where it was, still eating tens of GB.
- Never notice the option → same result, and later you can't remember which VM left it behind.
- Delete a VM that had checkpoints → the whole disk chain (`.vhdx` plus every `.avhdx` level) becomes unreferenced in one go, often dozens or hundreds of GB.
- A checkpoint merge fails or gets cancelled → a differencing disk is left behind, but it is **usually still referenced by the VM**, so it will not necessarily appear in this list. Don't count on this tool to clean that case up.

Hyper-V Manager offers **no entry point to these files** — with no VM attached, there is nowhere to click through to its disk. Explorer lists them, of course, but nothing tells you which ones are safe to delete and which one is still some machine's parent. The space just disappears, and all you see in disk usage is a Hyper-V folder that is inexplicably huge.

What this tool does: scan the Hyper-V disk directories, compare every file against the exact paths actually referenced by all current VMs (checkpoints and parent chains included), and **list the files that no VM references** for you to confirm and delete.

> **⚠️ The scan scope is limited — check where your disks live first**
> Only three locations are scanned by default: the virtual hard disk path configured in `Get-VMHost`, `C:\ProgramData\Microsoft\Windows\Hyper-V`, and `C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks`.
> If your disks live anywhere else (`D:\VMs`, `E:\HyperV`, a cluster shared volume, a hand-built storage pool directory…), **you must type that path in when the tool starts** (separate multiple paths with commas). Otherwise those directories are never scanned — the list always comes back empty, and an **empty list does not mean** nothing is left on disk.

## Why not just delete them in Explorer

Two traps, and you will genuinely hit both:

**1. A disk in use looks exactly like an orphan disk.** Filename, size and last-write time give nothing away. This tool collects every in-use path through `Get-VM` → `Get-VMHardDiskDrive` (checkpoint attachments included) plus the `ParentPath` from `Get-VHD` (the parent chain), and only excludes a file after an exact match. If the Hyper-V module is missing, it demands `CONTINUE` before going ahead instead of scanning blind.

**2. `RecycleOption.SendToRecycleBin` silently deletes permanently once the file exceeds quota.** This is the main reason the tool exists — see the next section.

## The core: recycle-bin quota pre-check

The Windows recycle-bin API (`Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile` + `SendToRecycleBin`) runs on `SHFileOperation` + `FOF_ALLOWUNDO`, and behaves like this:

> **The recycle bin is used only when the file fits. Once a file is larger than that volume's recycle-bin capacity, the Shell deletes it permanently.**

The GUI would normally ask *"This file is too large to put in the Recycle Bin. Do you want to delete it permanently?"* — but passing `UIOption.OnlyErrorDialogs` suppresses that prompt too, which turns the whole thing into a **silent permanent delete**: you think it went to the recycle bin, but it is gone. VHDX files are routinely tens of GB while recycle-bin limits are usually a few GB, so this is **guaranteed to trigger, not an occasional edge case**.

So the size has to be checked first. How the tool does it:

**Where the limit comes from**

1. Prefer the current user's custom quota: `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{volume GUID}\MaxCapacity`
2. When no custom value is set, derive it with the Windows default rule:

   ```
   limit = min(volume size, 40 GB) × 10% + (portion above 40 GB) × 5%
   ```

   Verified in reverse against real machine data; error under 0.15% across 5 volumes.

**Three tiers**

| Tier | Condition | Consequence | Confirmation word |
|---|---|---|---|
| Straight to the recycle bin | Enough free space, no existing entry displaced | Restorable from the recycle bin at any time | `YES` |
| Displaces older entries | Single file fits under the limit, but space is short | Silently pushes out the oldest entries, and tells you how much in advance | `YES` |
| Permanent delete | Single file exceeds that volume's recycle-bin limit | **Not recoverable** | `NUKE` |

Typing `YES` alone leaves every third-tier file untouched. The two confirmations are independent — there is no path where one `YES` wipes everything.

**Post-delete verification**

The tool does not trust the API's return value; it only checks whether the file actually appeared in the recycle bin. It compares that volume's `$Recycle.Bin` file table before and after, looking for a new `$R*` entry of the same size as the original. If none is found it warns explicitly: *"The file is gone but it is not in the recycle bin — that is a permanent delete."*

> One issue we hit in testing: the delete API throws *"the specified file could not be found"* while the file was in fact deleted successfully — a false alarm from the Shell's cleanup phase. Success can only be judged by re-reading the directory, never by the exception.

## Workflow

```
[0/5] Environment self-check   Admin rights? Hyper-V module?
[1/5] Collect in-use disks     VM hard disks + checkpoint chain + Get-VHD parents
[2/5] Determine scan paths     VMHost default path + ProgramData + Public, extendable
[3/5] Scan and compare         *.vhdx / *.avhdx minus in-use paths → orphan list
[4/5] Show the list            # / risk / type / size GB / drive / last write / path
[5/5] Recycle-bin quota check  Classify per file → YES / NUKE → delete → verify
```

Only two risk labels exist: `[Safe]` (`.vhdx`, matched no VM reference) and `[Caution]` (`.avhdx`, an isolated differencing disk or one with a parent — may still hold unmerged differences). `[Safe]` means "nothing references it", not "confirmed useless" — do read the path before you act.

## Getting started

> **Note for English readers:** the script's console output and prompts are in Chinese (the `ALL` / `N` / `YES` / `NUKE` / `CONTINUE` keywords are all ASCII). This document translates every message and prompt it can show, so you can follow along without reading Chinese. An English UI is not implemented yet.

### Option 1: run the script directly

Requires administrator rights (to read recycle-bin usage and call the Hyper-V cmdlets).

```powershell
# In an elevated PowerShell window
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-HyperVOrphans.ps1
```

### Option 2: compile to an exe (recommended, double-click and go)

Requires the `ps2exe` module:

```powershell
Install-Module ps2exe -Scope CurrentUser
```

Then:

```powershell
.\build.ps1
```

The resulting exe embeds a `requireAdministrator` manifest, so **double-clicking triggers UAC by itself** — no right-click "Run as administrator" needed. The window is fixed at 120×40, with a 3000-line buffer, centred on screen.

> First launch takes a few hundred milliseconds longer, because a small Win32 interop snippet is compiled on the fly with `Add-Type` to centre the window. If that fails it is skipped silently; size and buffer still apply, and the main flow is unaffected.
>
> If `Install-Module` returns 405 or is blocked by the network: `ps2exe.<version>.nupkg` is just a zip. Download it, extract, and drop the contents into `%USERPROFILE%\Documents\WindowsPowerShell\Modules\ps2exe\<version>\`, then `Import-Module ps2exe`.

## Input reference

| Situation | Input |
|---|---|
| Select one | `3` |
| Select several | `1,3,5` |
| Select a range | `2-4` |
| Select all | `ALL` (`all` / `全选` / `全部` also accepted) |
| Cancel | `N` or just Enter |
| Add scan paths | `D:\VMs,E:\Disks` (comma-separated) |
| Confirm send to recycle bin | `YES` |
| Confirm permanent delete | `NUKE` |
| Force continue without the Hyper-V module | `CONTINUE` |

## Known limitations

- **Only `.vhdx` / `.avhdx` are recognised**: legacy `.vhd` (and `.avhd` from Hyper-V 2012 R2 and earlier) are outside the scan scope and must be handled by hand. An empty list does not prove the disk is clean.
- **Disk files only, no configuration leftovers**: a deleted VM still leaves `Virtual Machines\<GUID>.xml`, `Snapshots\`, `Smart Paging\` and the like behind. This tool does not touch them.
- **Paths are compared as exact strings** (case-insensitive): if a disk is referenced through an 8.3 short name (`PROGRA~1`), a symlink, `subst` or a mount point, the match can fail and the file can be misjudged as an orphan. If something in the list "looks like it is still in use", check before you act.
- **A VHDX mounted on the host cannot be deleted**: if the file is attached with `Mount-VHD`, the delete fails with "the file still exists, possibly locked by vmms".
- **Running without administrator rights**: recycle-bin usage cannot be read, so decisions fall back to file size alone (with an explicit warning), and the post-delete verification step is skipped — reading an incomplete `$Recycle.Bin` would raise false "permanent delete" alarms.
- **Hyper-V module not installed**: in-use disks cannot be identified, and you must type `CONTINUE` to proceed. Using it in this mode amounts to deleting blind — not recommended.
- **Network paths / USB drives / volumes without `$Recycle.Bin` / volumes set to delete without recycling**: all forced into the "permanent delete" tier, requiring `NUKE`.
- **Some appearance settings do not apply under Windows Terminal**: the window sizing and centring target the classic conhost. If Windows Terminal is your default, fonts and colours come from the Windows Terminal profile.
- **Volumes whose recycle bin is already full**: even when a single file fits under the limit, it takes the "displaces older entries" path and silently pushes out the oldest items. Enlarge or empty the recycle bin first if you want to keep them.

## Making large VHDX files fit in the recycle bin

The only way is to raise that volume's recycle-bin limit: right-click the Recycle Bin → Properties → select the drive → Custom size, set to at least the size of the largest single file. Then run the tool again — files that were in the "permanent delete" tier move to the "straight to the recycle bin" tier.

## Disclaimer

This tool **deletes files**. Three layers of protection are in place (in-use path exclusion, quota pre-check, post-delete verification), but:

- On first use, **start with a single file** and confirm it really shows up in the recycle bin before processing in bulk.
- Before confirming a delete, verify that each path in the list is the one you mean.
- Once a file takes the "permanent delete" path, **no software can bring it back**.

Using this tool means you understand and accept the above risks.

## License

MIT
