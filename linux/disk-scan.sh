#!/usr/bin/env bash
#
# disk-scan.sh -- report the biggest folders on a Windows drive, from inside WSL2.
#
# ============================================================================
# WHY THIS EXISTS / THE NEVER-DU-OVER-/mnt/c RULE  (read this first)
# ============================================================================
# This is a WSL2 box. The Windows C: drive is exposed to Linux through the 9p
# filesystem at /mnt/c. Running `du`/`find` over /mnt/c to size folders is
# *catastrophically* slow -- every stat() round-trips through the 9p protocol,
# and a full 462G scan has literally never finished on this machine. So we DO
# NOT traverse the mount from Linux. Instead we drive NATIVE powershell.exe,
# which reads the NTFS volume directly and only streams a tiny summary back.
#
# ============================================================================
# TRANSPORT STRATEGY: quoted-heredoc -> temp .ps1 -> powershell.exe -File
# ============================================================================
# We write the PowerShell program to a real .ps1 file on the Windows side
# (C:\Temp) and execute it with:
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File <WinPath> -Base ... -Top ...
#
# The PowerShell body is emitted via a heredoc with a QUOTED delimiter
# (<<'PSEOF'). Quoting the delimiter tells bash to perform ZERO expansion on the
# heredoc body: no $var, no `command`, no backslash munging. The PS source
# therefore passes through VERBATIM. This matters because PowerShell is full of
# things bash would otherwise wreck -- $_ automatic vars, $Base, member access,
# [math]::Round, backtick escapes, etc.
#
# WHY -File AND NOT INLINE -Command / -EncodedCommand / stdin:
# Past sessions on THIS machine repeatedly MANGLED paths when the PowerShell was
# built as an inline `-Command "..."` string with bash interpolation (eaten
# dollar-signs / backslashes / quotes). The hard-won rule: never interpolate
# bash variables into PowerShell source. Runtime values (the target path, the
# top-N count) are passed as REAL ARGUMENTS to the .ps1 via its param() block
# (-Base / -Top), NOT baked into the text. -File is the most robust transport:
#   * Unlike -EncodedCommand, -File accepts trailing -Base/-Top parameters
#     directly (no WSLENV/env-var detour, which is config-dependent and fails
#     silently if interop env forwarding is disabled).
#   * Unlike `-Command -` over stdin, -File is not parsed line-by-line, so a
#     line ending in a trailing pipe `|` cannot silently truncate the program.
#   * The user's path -- even one with spaces, e.g. 'C:\Users\charlie\My Games'
#     -- arrives as one argv token bound to [string]$Base, intact.
#
# ENCODING NOTE: the .ps1 is written with a leading UTF-8 BOM (EF BB BF). Windows
# PowerShell 5.1 decodes a BOM-less script using the legacy ANSI code page
# (Windows-1252), which would silently corrupt any non-ASCII byte embedded in
# the SOURCE. The BOM makes 5.1 (and pwsh) detect UTF-8. Keep the heredoc body
# ASCII or UTF-8; either is safe with the BOM present. (Runtime folder NAMES read
# from the filesystem are NOT affected by this -- PowerShell gets those as native
# UTF-16 from the OS and re-emits them via [Console]::OutputEncoding=UTF8.)
#
# Requires: bash, native powershell.exe, and standard WSL utils (wslpath).
# No iconv/base64/jq/etc. Single self-contained file, no other external deps.

set -euo pipefail

PROG="$(basename "$0")"

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
TARGET='C:\'   # default scan root: the whole C: drive
TOP=30         # default number of rows to display

# ----------------------------------------------------------------------------
# Help / usage
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: ${PROG} [-p|--path <WindowsPath>] [-n|--top <N>] [-h|--help]

Report the largest immediate child folders of a Windows path, by total
recursive size, on a WSL2 machine -- using native powershell.exe (NOT a slow
du/find over the /mnt/c 9p mount, which never finishes).

Options:
  -p, --path <WindowsPath>  Windows path to scan. Default: C:\\
                            Use Windows syntax, e.g. 'C:\\Users\\charlie\\My Games'.
                            Quote paths that contain spaces.
  -n, --top  <N>            Show the top N folders. Default: ${TOP}.
  -h, --help                Show this help and exit.

  (--path=<v> and --top=<v> forms are also accepted.)

Examples:
  ${PROG}
  ${PROG} -p 'C:\\Users\\charlie' -n 20
  ${PROG} --path 'C:\\Users\\charlie\\AppData\\Local' --top 15
  ${PROG} -p 'C:\\Users\\charlie\\My Games'           # spaces are fine

Notes:
  * Sizes are total recursive file bytes (sum of Length), shown in GB with
    2 decimals, invariant culture (always '.' decimal separator regardless of
    the Windows machine locale) and NO thousands separators (parse-friendly).
    This is logical size, not on-disk allocation: NTFS compression / sparse
    files (e.g. the WSL .vhdx, pagefile) may report differently than Explorer's
    "size on disk".
  * Drive total/free is read from Win32_LogicalDisk (the physical volume size),
    falling back to Get-PSDrive (used+free) if CIM is unavailable. For a normal
    local volume both agree; on subst/UNC/quota-limited drives the reported
    capacity may reflect the backing volume rather than the literal path.
  * Hidden/system items are included (-Force). Locked/unreadable items are
    skipped silently and counted as 0 rather than aborting the scan.
  * Reparse points (junctions/symlinks) are skipped: a top-level folder that is
    itself a junction does not appear as a row, and the recursive sizer never
    descends through a nested junction/symlink. This is enforced by an explicit
    walk that tests the ReparsePoint attribute on every entry (engine-
    independent), so there is no infinite recursion or cross-volume wandering.
    Consequence: reparse-point FILES (e.g. OneDrive online-only placeholders)
    are also excluded, so a cloud-backed folder may under-report its logical
    size -- which roughly matches the ~0 bytes such placeholders occupy on disk.
  * A whole-C:\\ scan of a large used drive can take several minutes (this is
    still vastly faster than du-over-9p). Scope with -p to go faster.

Environment:
  POWERSHELL   Override the powershell.exe to use (absolute path). If unset, the
               script uses one on PATH, else the System32 WindowsPowerShell 5.1
               fallback. You may point this at pwsh.exe (PowerShell 7); the
               script is validated against Windows PowerShell 5.1 and treats
               pwsh as best-effort.
EOF
}

die() { echo "${PROG}: error: $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TARGET="$2"; shift 2 ;;
    --path=*)
      TARGET="${1#*=}"; shift ;;
    -n|--top)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TOP="$2"; shift 2 ;;
    --top=*)
      TOP="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      # End-of-options. This tool accepts NO positional operands, so anything
      # after '--' is user error -- report it rather than silently dropping it.
      shift
      [[ $# -eq 0 ]] || die "unexpected argument(s): $* (try --help)"
      break ;;
    -*)
      die "unknown option: $1 (try --help)" ;;
    *)
      die "unexpected argument: $1 (try --help)" ;;
  esac
done

# Validate TOP is a positive integer.
[[ "$TOP" =~ ^[1-9][0-9]*$ ]] || die "--top must be a positive integer, got: $TOP"

# A bare drive root sometimes arrives as "C:" -- normalise to "C:\".
[[ "$TARGET" =~ ^[A-Za-z]:$ ]] && TARGET="${TARGET}\\"

# Reject an empty path outright.
[[ -n "$TARGET" ]] || die "--path must not be empty"

# ----------------------------------------------------------------------------
# Sanity checks: WSL + powershell.exe + wslpath
# ----------------------------------------------------------------------------
[[ -d /mnt/c ]] || die "/mnt/c not found -- this script must run inside WSL2 with the C: drive mounted."
command -v wslpath >/dev/null 2>&1 || die "wslpath not found -- this script must run inside WSL."

# Resolve powershell.exe robustly:
#   1) honor $POWERSHELL override if set (must be an executable; can be pwsh.exe),
#   2) else whatever is on PATH (powershell.exe, then pwsh.exe),
#   3) else the well-known absolute fallback under System32 (it is frequently
#      NOT on PATH in non-interactive shells).
resolve_powershell() {
  if [[ -n "${POWERSHELL:-}" ]]; then
    if [[ -x "$POWERSHELL" ]]; then printf '%s\n' "$POWERSHELL"; return 0; fi
    die "POWERSHELL is set to '$POWERSHELL' but that is not an executable file."
  fi
  local p
  if p="$(command -v powershell.exe 2>/dev/null)"; then printf '%s\n' "$p"; return 0; fi
  if p="$(command -v pwsh.exe 2>/dev/null)"; then printf '%s\n' "$p"; return 0; fi
  local fallback='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  if [[ -x "$fallback" ]]; then printf '%s\n' "$fallback"; return 0; fi
  die "powershell.exe not found (not in \$POWERSHELL, not on PATH, not at $fallback). Set POWERSHELL=/path/to/powershell.exe."
}
PS_EXE="$(resolve_powershell)"

# ----------------------------------------------------------------------------
# Prepare a Windows-accessible temp .ps1
# ----------------------------------------------------------------------------
# powershell.exe -File needs to open the script by a Windows path, so the .ps1
# must live somewhere visible on the Windows side. C:\Temp is reliable; we
# create it (via the Linux view of the mount) if missing. mktemp gives a unique
# name so concurrent runs don't collide. We use the explicit GNU `--suffix`
# form rather than embedding 'XXXXXX' mid-template: mid-template Xs are a GNU
# coreutils extension and would break under BusyBox mktemp.
WIN_TEMP_LINUX='/mnt/c/Temp'
mkdir -p "$WIN_TEMP_LINUX" 2>/dev/null \
  || die "could not create $WIN_TEMP_LINUX (C:\\Temp). Is /mnt/c writable?"

PS1_LINUX="$(mktemp --suffix=.ps1 "${WIN_TEMP_LINUX}/disk-scan.XXXXXX")" \
  || die "could not create a temp .ps1 in $WIN_TEMP_LINUX."

# Always clean up the temp file, even on error / Ctrl-C.
cleanup() { rm -f "$PS1_LINUX" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# The PowerShell program.
#
# QUOTED heredoc (<<'PSEOF'): bash does NOT touch a single character below.
# Parameters arrive via the param() block (-Base / -Top), bound from real argv
# tokens passed to powershell.exe -File. Nothing about the user's path or N is
# interpolated into this text.
#
# We first write a UTF-8 BOM (EF BB BF) so Windows PowerShell 5.1 decodes the
# source as UTF-8 rather than the legacy ANSI code page (see ENCODING NOTE at
# the top). Then APPEND (>>) the heredoc body after the BOM.
# ----------------------------------------------------------------------------
printf '\xEF\xBB\xBF' > "$PS1_LINUX"
cat >> "$PS1_LINUX" <<'PSEOF'
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Base,
  [Parameter(Mandatory = $true)] [int]    $Top
)

# Be quiet and resilient: never throw on a locked/denied file, and never let the
# "preparing modules for first use" progress stream pollute our output.
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'

# Force invariant culture so numbers always print with '.' as the decimal
# separator regardless of the Windows regional settings on this machine.
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

# Force UTF-8 console output so non-ASCII folder names (e.g. accented or
# CJK directory names) survive the trip back to the bash side instead of
# rendering as '?' / replacement characters.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 }            catch { }

# --- Validate target --------------------------------------------------------
if (-not (Test-Path -LiteralPath $Base)) {
    [Console]::Error.WriteLine("disk-scan: path not found on Windows side: $Base")
    exit 2
}

# Canonicalise to the provider's idea of the full path (handles e.g. 'C:' vs
# 'C:\', trailing slashes). Fall back to the raw input if resolution fails.
$item = Get-Item -LiteralPath $Base -Force -ErrorAction SilentlyContinue
if ($item -and -not [string]::IsNullOrWhiteSpace($item.FullName)) {
    $full = $item.FullName
} else {
    $full = $Base
}

# --- Drive total / used / free ----------------------------------------------
# Derive the drive root (e.g. 'C:') from the target and report capacity.
# Prefer Win32_LogicalDisk for an accurate PHYSICAL volume Size/FreeSpace;
# fall back to Get-PSDrive (used+free, gated to real FileSystem volumes) if CIM
# is unavailable. UNC paths (\\server\share) have no qualifier -> we omit the
# drive line entirely.
$qual = Split-Path -Qualifier $full -ErrorAction SilentlyContinue
if ($qual) {
    $printed = $false

    # 1) Authoritative: Win32_LogicalDisk gives the true volume capacity.
    $ld = Get-CimInstance -ClassName Win32_LogicalDisk `
              -Filter ("DeviceID='{0}'" -f $qual) -ErrorAction SilentlyContinue
    if ($ld -and ($null -ne $ld.Size) -and ([double]$ld.Size -gt 0)) {
        $totalGB = [math]::Round([double]$ld.Size      / 1GB, 2)
        $freeGB  = [math]::Round([double]$ld.FreeSpace / 1GB, 2)
        $usedGB  = [math]::Round(([double]$ld.Size - [double]$ld.FreeSpace) / 1GB, 2)
        Write-Output ("Drive {0}  total {1} GB  used {2} GB  free {3} GB" -f `
                      $qual, $totalGB, $usedGB, $freeGB)
        $printed = $true
    }

    # 2) Fallback: Get-PSDrive used+free, only for a real FileSystem volume.
    if (-not $printed) {
        $drive = Get-PSDrive -Name ($qual.TrimEnd(':')) -ErrorAction SilentlyContinue
        if ($drive -and ($drive.Provider.Name -eq 'FileSystem') -and
            ($null -ne $drive.Free) -and ($null -ne $drive.Used) -and
            (($drive.Free + $drive.Used) -gt 0)) {
            $freeGB  = [math]::Round($drive.Free / 1GB, 2)
            $usedGB  = [math]::Round($drive.Used / 1GB, 2)
            $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 2)
            Write-Output ("Drive {0}  total {1} GB  used {2} GB  free {3} GB" -f `
                          $qual, $totalGB, $usedGB, $freeGB)
            $printed = $true
        }
    }

    if (-not $printed) {
        Write-Output ("Drive {0}  capacity info unavailable" -f $qual)
    }
}
Write-Output ("Scanning: {0}   (top {1} folders by total size)" -f $full, $Top)
Write-Output ''

# --- Enumerate immediate child directories ----------------------------------
# -Force includes hidden/system dirs. -EA SilentlyContinue swallows access
# errors. We EXCLUDE reparse points (NTFS junctions / symlinks) at the top level
# so a recursive sum can never loop back into itself or wander off into another
# volume.
$childDirs = Get-ChildItem -LiteralPath $full -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }

if (-not $childDirs) {
    Write-Output '(no readable child directories found)'
    exit 0
}

# --- Size each child folder recursively -------------------------------------
# We do an EXPLICIT iterative (stack-based) walk instead of relying on
# `Get-ChildItem -Recurse ... -Attributes !ReparsePoint`. Rationale: the
# -Attributes filter only excludes reparse-point ITEMS from the output set; its
# traversal-halting behavior is engine-dependent (it differs between Windows
# PowerShell 5.1 and pwsh 7). By testing the ReparsePoint attribute on every
# entry ourselves and refusing to Push reparse-point directories, we GUARANTEE
# junctions/symlinks are never followed -- no infinite recursion, no cross-
# volume wandering -- on any engine. -Force includes hidden/system entries;
# -EA SilentlyContinue swallows access-denied / locked errors (those subtrees
# simply contribute 0). Reparse-point FILES (e.g. cloud placeholders) are also
# skipped, matching the ~0 bytes they occupy on disk.
function Get-FolderBytes {
    param([string] $Path)
    $sum   = [long]0
    $stack = [System.Collections.Stack]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $entries = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        foreach ($e in $entries) {
            # Never descend into (or count) a reparse point.
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.PSIsContainer) {
                $stack.Push($e.FullName)
            } else {
                $sum += [long]$e.Length
            }
        }
    }
    return $sum
}

$rows = foreach ($dir in $childDirs) {
    [PSCustomObject]@{
        Bytes  = Get-FolderBytes -Path $dir.FullName
        Folder = $dir.Name
    }
}

# --- Sort by true byte count desc, take top N, print a clean fixed table ----
# Sort on the exact byte count (not rounded GB) so ordering is always correct.
$rows = $rows | Sort-Object -Property Bytes -Descending | Select-Object -First $Top

Write-Output ('{0,12}   {1}' -f 'Size (GB)', 'Folder')
Write-Output ('-' * 66)
foreach ($r in $rows) {
    # F2 (not N2): fixed-point, no thousands separators, '.' decimal under
    # InvariantCulture -- keeps the column numeric-parseable for awk/sort/cut.
    Write-Output ('{0,12:F2}   {1}' -f ($r.Bytes / 1GB), $r.Folder)
}

exit 0
PSEOF

# ----------------------------------------------------------------------------
# Translate the .ps1 path to a Windows path and run it.
# ----------------------------------------------------------------------------
# powershell.exe -File needs a Windows path. wslpath -w handles the /mnt path
# (and spaces) fine; the resulting string is quoted on the command line below.
PS1_WIN="$(wslpath -w "$PS1_LINUX")" \
  || die "wslpath could not translate $PS1_LINUX to a Windows path."

# Note: "$TARGET" is passed as a normal argv value to powershell.exe, then bound
# to [string]$Base. Quoting "$TARGET" preserves embedded spaces (e.g.
# 'C:\Users\charlie\My Games'). No bash text ever enters the PS source. We
# temporarily disable errexit so we can capture and propagate PowerShell's own
# exit code instead of letting set -e abort before the cleanup trap reports it.
set +e
"$PS_EXE" \
  -NoProfile \
  -NonInteractive \
  -ExecutionPolicy Bypass \
  -File "$PS1_WIN" \
  -Base "$TARGET" \
  -Top "$TOP"
status=$?
set -e

exit "$status"