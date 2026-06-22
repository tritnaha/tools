# tools

Personal cross-platform utility scripts for a WSL2 + Windows machine.

Organized by where each script **runs**:

| Dir          | Runs on                          | Language          |
|--------------|----------------------------------|-------------------|
| [`linux/`](linux/)     | WSL2 / Ubuntu (bash)             | Bash              |
| [`windows/`](windows/) | Windows, natively (PowerShell 5.1+) | PowerShell        |

> The `windows/` scripts live here on the Linux side as the canonical source, but
> are meant to be run **natively on Windows**. From a Windows PowerShell prompt you
> can run them straight from the WSL share, e.g.
> `& '\\wsl.localhost\Ubuntu\home\charlie\tools\windows\Get-FolderSizes.ps1'`,
> or copy them to a Windows folder (e.g. `C:\Users\charlie\tools`) first.

---

## `windows/Get-FolderSizes.ps1`

**What it does** — Lists the biggest sub-folders of one or more paths, by total
recursive size, as a clean table. The everyday "what's eating my disk?" tool for
the Windows side.

**How it works (short)** — Native PowerShell. For each `-Path`, it enumerates the
immediate child folders, sums every file underneath each one
(`Get-ChildItem -Recurse -File`), rounds to GB, sorts descending and prints a
table. Reads NTFS directly, so it's far faster than running `du` over the WSL
`/mnt/c` (9p) mount. Hidden/system items are included; locked/denied items are
skipped (counted as 0).

**Flags**

| Flag            | Type       | Default            | Meaning                                                        |
|-----------------|------------|--------------------|----------------------------------------------------------------|
| `-Path`         | `string[]` | `$env:USERPROFILE` | One or more folders to scan (positional; accepts a list).      |
| `-Top`          | `int`      | `15`               | How many of the biggest children to show per path.             |
| `-IncludeFiles` | switch     | off                | Also list loose top-level files (adds a `Type` column).        |

**Examples**

```powershell
.\Get-FolderSizes.ps1                                           # profile, top 15
.\Get-FolderSizes.ps1 -Path 'C:\Users\charlie\AppData\Local' -Top 20
.\Get-FolderSizes.ps1 'C:\','D:\' -Top 25                       # multiple drives
.\Get-FolderSizes.ps1 "$env:LOCALAPPDATA\Temp" -IncludeFiles    # include loose files
Get-Help .\Get-FolderSizes.ps1 -Full                            # built-in help
```

> Note: the GB column prints with the machine's regional decimal separator
> (e.g. `1,65` on a comma-locale machine).

---

## `linux/disk-cleanup.sh`

**What it does** — Project-aware disk reporter **and** safe reclaimer for the WSL
ext4 side (`/`, your home). It reports usage and a categorized list of reclaimable
junk, and — only when asked — reclaims it. **Dry-run by default: it changes
nothing without an explicit `--delete`/`--purge`.**

**How it works (short)** — First it walks your scan roots and builds a map of
every project and its regenerable dependency dirs (so they're protected). Then it
classifies the rest into tiers and applies a *triple gate* to every deletion
target: the path must (a) resolve under a scan root (no symlink/mount escape),
(b) match a known-safe allowlist pattern, **and** (c) not match the protected
denylist or contain a `.git`/source/secret. Tier-0 (regenerating package caches)
is the only thing eligible for action; `--delete` **moves** it to a reversible
quarantine, `--purge` deletes irreversibly. Project deps (`node_modules`,
`.venv`, toolchains…) are **never** auto-removed — only reported with a restore
command.

**Flags**

| Flag                      | Default                    | Meaning                                                              |
|---------------------------|----------------------------|---------------------------------------------------------------------|
| `-p`, `--root <dir>`      | `$HOME`                    | Scan root (repeatable).                                             |
| `-n`, `--top <N>`         | `15`                       | Show top N subdirs in the `du` summary (`0` disables).             |
| `--tmp-age <days>`        | `7`                        | Only treat loose `/tmp` files older than this as waste.            |
| `--include-tmp`           | off                        | Also consider stale, you-owned loose **files** in `/tmp`.          |
| `--delete`                | off                        | Reclaim Tier-0 by **moving** it to quarantine (reversible). Prompts unless `--yes`. |
| `--purge`                 | off                        | Reclaim Tier-0 by **irreversible** `rm -rf`. Implies `--delete`.   |
| `--quarantine <dir>`      | `$HOME/.cache/disk-cleanup/quarantine` | Quarantine root for `--delete`.                        |
| `--yes`                   | off                        | Skip the interactive y/N confirmation.                            |
| `--include-redownloadable`| off                        | Also act on large re-downloadable caches (e.g. ms-playwright).    |
| `--json`                  | off                        | Machine-readable report (report-only; cannot combine with delete).|
| `-h`, `--help`            | —                          | Full help.                                                         |

**Examples**

```bash
disk-cleanup.sh                       # dry-run report — always start here
disk-cleanup.sh --delete              # move Tier-0 junk to quarantine (prompts)
disk-cleanup.sh --delete --yes        # ...no prompt
disk-cleanup.sh -p ~/projects -n 25   # scope to one tree
disk-cleanup.sh --purge               # irreversible — review the dry-run first!
```

> Safe by design: never touches `assets-golden`, `.git`, `.ssh`, `.config`,
> `.claude/projects`, or any active project's dependencies.

---

## `linux/disk-scan.sh`

**What it does** — Scans a **Windows** drive's biggest folders from *inside* WSL.
This is the secondary option — prefer [`windows/Get-FolderSizes.ps1`](windows/Get-FolderSizes.ps1)
when you're on Windows. Use this only when you want the answer without leaving
your WSL shell.

**How it works (short)** — It's a thin bridge: it writes a small PowerShell program
to a temp `.ps1` on the Windows side and runs it via
`powershell.exe -File`. The PowerShell does the actual NTFS scan (never `du` over
`/mnt/c`). A quoted heredoc keeps bash from mangling the PowerShell source, and the
target path / top-N are passed as real `-Base`/`-Top` arguments. The temp file is
cleaned up on exit.

**Flags**

| Flag                       | Default | Meaning                                              |
|----------------------------|---------|------------------------------------------------------|
| `-p`, `--path <WinPath>`   | `C:\`   | Windows path to scan (quote paths with spaces).      |
| `-n`, `--top <N>`          | `30`    | Show the top N folders.                              |
| `-h`, `--help`             | —       | Help.                                                |

**Examples**

```bash
disk-scan.sh                              # whole C:, top 30
disk-scan.sh -p 'C:\Users\charlie' -n 20  # scoped
```
