<#
.SYNOPSIS
    Show-DiskUsage.ps1 -- an ncdu-style INTERACTIVE disk-usage explorer for Windows
    PowerShell 5.1+. Walks the directory tree, shows sizes with bars, and CLASSIFIES every
    folder/file by name & path heuristics so you understand what each one is.

.DESCRIPTION
    Think "ncdu, but PowerShell and more improved." Launches a full-screen, arrow-key TUI
    rooted at -Path (default: the system drive root, e.g. C:\). The current directory is
    shown as a header with its total size and percent-of-parent; below it is a size-sorted
    list of its children (folders and, optionally, files). Each row renders:

        SIZE (right-aligned B/KB/MB/GB/TB) | relative size BAR | PERCENT of current dir
        | NAME | a short CLASSIFICATION TAG

    The classification engine is DATA-DRIVEN (see Get-ClassRules): an ordered table of rules,
    each a scriptblock matcher mapping a name/path pattern (and file-vs-dir) to a category, a
    short tag, a console color, a one-line hint and a reclaim hint. Categories include:
    system - careful, app data, cache/junk - clearable, re-downloadable, user data - keep,
    downloads - often clearable, project, and a neutral default. The FIRST matching rule (by
    ascending Priority) wins, so specific/known rules are checked before broad ones. Add a row
    to extend it; nothing else changes.

    Sizing is the TOTAL recursive bytes beneath each entry, computed with an explicit ITERATIVE
    walk (via DirectoryInfo.EnumerateFileSystemInfos) that NEVER follows NTFS reparse points
    (junctions / symlinks) -- this prevents junction loops and cross-volume wandering (the
    legacy AppData "Application Data"/"History" compat junctions, or a junction back to the
    root). Immediate-child sizes are computed once per directory and CACHED by full path, so
    navigation and redraw never rescan (an arrow-key TUI must not rescan on every keypress).
    A "Scanning <path>..." indicator is shown while a slow level is being measured.

    Deletion is supported from inside the tool ('d'), defaulting to the RECYCLE BIN (reversible)
    via Microsoft.VisualBasic.FileIO.FileSystem. Shift+D permanently deletes (stricter "type DELETE"
    confirm). Permanent-vs-reversible is decided by the SHIFT MODIFIER, never by character case, so
    Caps Lock cannot silently invert the safe default. If Microsoft.VisualBasic cannot load, the tool
    REFUSES to delete (rather than silently hard-deleting). Hard guardrails refuse to delete drive
    roots, Windows/Program Files/Program Files (x86)/ProgramData, the Users folder itself, ANY user
    profile root (C:\Users\<name>, not just yours), $Recycle.Bin, System Volume Information, the
    page/hibernation/swap files, the Windows system root, and any reparse point. Guardrail matching
    canonicalizes to the real long path first, so 8.3 short-name aliases (C:\PROGRA~1) cannot bypass
    it. Subfolders of an allowed parent (e.g. C:\Users\bob\Downloads) remain deletable.

    Sizing is hardened for correctness and responsiveness: deep paths over 260 chars are measured via
    the \\?\ extended-length form (not silently counted as 0); each subdirectory's recursive total is
    MEMOIZED so drilling in reuses the size the parent scan already computed; toggling file visibility
    ('g') never re-walks (files are always measured and only hidden at render time, so the directory
    total stays invariant); and a long scan can be aborted with Esc/q so a 100k-entry level never
    freezes the UI.

    If interactive console key input is unavailable (input redirected, not a real console, or
    [Environment]::UserInteractive is false), the script does NOT crash; it prints a classified,
    size-sorted annotated tree of -Path and exits 0. The -Dump switch forces that same tree
    explicitly (handy for piping AND automated testing). The dump and the TUI SHARE all sizing
    and classification code (no duplicate logic).

.PARAMETER Path
    Starting directory. Defaults to the system drive root (e.g. C:\). A file resolves to its parent.

.PARAMETER Dump
    Print a classified, size-sorted tree once (to -MaxDepth) and exit. No navigation.

.PARAMETER MaxDepth
    Depth for -Dump (and for the non-interactive fallback). Default 2.

.PARAMETER ShowFiles
    Start with files visible alongside folders in the TUI (toggle later with 'g').

.EXAMPLE
    .\Show-DiskUsage.ps1
    Launch the ncdu-style TUI at the system drive root. Arrow keys navigate; press 'h' for help.

.EXAMPLE
    .\Show-DiskUsage.ps1 -Path 'C:\Users\charlie'
    Explore a specific folder interactively.

.EXAMPLE
    .\Show-DiskUsage.ps1 -Path 'C:\Users\charlie\AppData\Local' -Dump -MaxDepth 3
    Non-interactive: print a classified, size-sorted tree 3 levels deep (pipe-friendly, testable).

.NOTES
    ncdu-style. KEYS: Up/Down move, Right/Enter drill in, Left/Backspace go up,
    Home/End first/last, PageUp/PageDown scroll, d delete (Recycle Bin), Shift+D permanent,
    r rescan, g toggle files, h or ? help, q or Esc quit.
    Windows PowerShell 5.1 compatible (no PS7-only syntax). Single self-contained .ps1.
    No external modules beyond the in-box Microsoft.VisualBasic assembly.
    Forces InvariantCulture and UTF-8 console output.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Dump,
    [int]$MaxDepth = 2,
    [switch]$ShowFiles
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------------------------------
# 0. Global setup -- culture, encoding, module-level state
# ----------------------------------------------------------------------------------------------------

# Force InvariantCulture so size formatting never emits comma decimals on non-US locales (pitfall #5).
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture   = $script:Inv
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $script:Inv
} catch { }

# UTF-8 console output so the bar/box glyphs render correctly.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Per-path cache of computed level scans (folder sizes computed ONCE on entry, reused on redraw/nav).
# Keyed by normalized path; value holds the FULL child set (dirs + files) so toggling file visibility
# never re-walks. Value: @{ Entries=<PSCustomObject[] dirs+files>; Total=<double invariant total> }.
$script:LevelCache = @{}

# Memoized recursive directory byte totals, keyed by normalized path. A directory's subtree is walked
# exactly once per session: when it is sized as a sibling, the result is stored here, so drilling INTO
# it (which sizes its children) reuses each child's already-known total instead of re-walking. Cleared
# downward + upward on delete and on explicit rescan so stale sizes never survive a mutation.
$script:SizeMemo = @{}

# Classification rule table cache (lazily built by Get-ClassRules). $null so StrictMode reads are safe.
$script:ClassRules = $null

# Reparse-point flag, for fast attribute testing.
$script:ReparseFlag = [System.IO.FileAttributes]::ReparsePoint

# Bar glyphs (UTF-8 block + light shade). Functionality is unaffected if a legacy font mojibakes them.
$script:BarFull  = [char]0x2588   # full block
$script:BarEmpty = [char]0x2591   # light shade

# Off-screen buffer of last-painted lines, for flicker-free differential redraw.
$script:LastFrame = @()

# Whether Microsoft.VisualBasic has been loaded (lazy, only for delete).
$script:VbLoaded = $false

# Throttle timestamp for the "Scanning ..." progress heartbeat (set under StrictMode-safe init).
$script:LastProgressTick = [DateTime]::MinValue


# ====================================================================================================
# 1. PURE LOGIC (no console IO) -- unit-testable by dot-sourcing
# ====================================================================================================

function Get-NormalizedPath {
    <#
        Canonical key for caching/guardrail comparison: full path, no trailing slash except a bare
        drive root, lower-cased. Does NOT resolve reparse points (we must never follow junctions).
    #>
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return '' }
    $n = $P.Trim()
    # Strip any \\?\ extended-length (or \\?\UNC\) prefix FIRST so a path that came back from a
    # DirectoryInfo built on the \\?\ form normalizes to the SAME key as the plain form. Otherwise the
    # size memo / level cache would key the same directory two different ways and never hit.
    if ($n.StartsWith('\\?\UNC\')) { $n = '\\' + $n.Substring(8) }
    elseif ($n.StartsWith('\\?\')) { $n = $n.Substring(4) }
    try { $n = [System.IO.Path]::GetFullPath($n) } catch { }
    # Preserve a bare drive root like 'C:\'; strip a trailing backslash otherwise.
    if ($n -match '^[A-Za-z]:\\?$') { return ($n.Substring(0,2) + '\').ToLowerInvariant() }
    if ($n.Length -gt 3 -and $n.EndsWith('\')) { $n = $n.TrimEnd('\') }
    return $n.ToLowerInvariant()
}

function Get-LongPath {
    <#
        Return the \\?\ extended-length form of a LOCAL absolute path so .NET's MAX_PATH (260-char)
        limit on Windows PowerShell 5.1 does NOT truncate the size walk of deep node_modules/.venv/
        build trees (which otherwise throw PathTooLongException and get silently counted as 0 bytes).
        UNC shares get the \\?\UNC\ form. Already-prefixed or non-rooted inputs are returned unchanged.
        Pure string math; no IO.
    #>
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return $P }
    if ($P.StartsWith('\\?\') -or $P.StartsWith('\\.\')) { return $P }   # already extended/device form
    if ($P -match '^[A-Za-z]:\\') { return ('\\?\' + $P) }               # local drive-rooted path
    if ($P.StartsWith('\\')) { return ('\\?\UNC\' + $P.Substring(2)) }   # UNC share
    return $P
}

function Test-IsDriveRoot {
    <# True for a bare drive root such as 'C:\' or 'C:'. #>
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return $false }
    return (($P.Trim().TrimEnd('\')) -match '^[A-Za-z]:$')
}

function Get-ParentPath {
    <# Parent directory path, or $null if already at a drive root. Pure (path math only). #>
    param([Parameter(Mandatory)][string]$FullPath)
    $trimmed = $FullPath.TrimEnd('\','/')
    if ($trimmed -match '^[A-Za-z]:$') { return $null }   # "C:" -> already root
    $parent = $null
    try { $parent = Split-Path -Parent $trimmed } catch { $parent = $null }
    if ([string]::IsNullOrEmpty($parent)) { return $null }
    if ($parent -match '^[A-Za-z]:$') { $parent = $parent + '\' }   # normalize bare-drive parent
    if ($parent -eq $FullPath -or $parent -eq $trimmed) { return $null }
    return $parent
}

function Test-IsReparsePoint {
    <# True if the item (a FileSystemInfo) is an NTFS reparse point (junction/symlink). Never throws. #>
    param([Parameter(Mandatory)]$Item)
    try {
        return (($Item.Attributes -band $script:ReparseFlag) -eq $script:ReparseFlag)
    } catch {
        return $false
    }
}

function Format-Size {
    <#
        Human-readable byte size, right-aligned to a fixed width. InvariantCulture.
        e.g. "  1.2 GB", "342.0 MB", "     0 B".
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Bytes,
        [int]$Width = 9
    )
    if ($null -eq $Bytes) { $Bytes = 0 }
    [double]$val = [double]$Bytes
    if ($val -lt 0) { $val = 0 }
    $units = @('B','KB','MB','GB','TB','PB')
    $i = 0
    while ($val -ge 1024.0 -and $i -lt ($units.Count - 1)) { $val = $val / 1024.0; $i++ }
    if ($i -eq 0) {
        $txt = ([long]$val).ToString($script:Inv) + ' ' + $units[$i]
    } elseif ($val -ge 100) {
        $txt = $val.ToString('0', $script:Inv) + ' ' + $units[$i]
    } elseif ($val -ge 10) {
        $txt = $val.ToString('0.0', $script:Inv) + ' ' + $units[$i]
    } else {
        $txt = $val.ToString('0.00', $script:Inv) + ' ' + $units[$i]
    }
    return $txt.PadLeft($Width)
}

function Format-Bar {
    <# Proportional bar scaled to the largest sibling. $Width = inner cells. Returns "[####....]". #>
    param(
        [Parameter(Mandatory)][double]$Value,
        [Parameter(Mandatory)][double]$Max,
        [int]$Width = 12
    )
    if ($Width -lt 1) { return '' }
    if ($Max -le 0) { return '[' + (([string]$script:BarEmpty) * $Width) + ']' }
    $frac = $Value / $Max
    if ($frac -lt 0) { $frac = 0 }
    if ($frac -gt 1) { $frac = 1 }
    $filled = [int][math]::Round($frac * $Width)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0)      { $filled = 0 }
    return '[' + (([string]$script:BarFull) * $filled) + (([string]$script:BarEmpty) * ($Width - $filled)) + ']'
}

function Format-Percent {
    <# Percent string like ' 42.3%' padded to width 6. #>
    param([double]$Fraction)
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }
    return (($Fraction * 100.0).ToString('0.0', $script:Inv).PadLeft(5) + '%')
}

function Get-ClassField {
    <#
        StrictMode-2.0-safe read of a Class object field with a default. Under Set-StrictMode 2.0,
        touching a NON-EXISTENT property throws; this guards member access so a future under-populated
        Class object can never make the render loop throw out of Invoke-Tui.
    #>
    param($Class, [string]$Field, $Default = '')
    if ($null -eq $Class) { return $Default }
    try {
        $prop = $Class.PSObject.Properties[$Field]
        if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    } catch { }
    return $Default
}


# ----------------------------------------------------------------------------------------------------
# 1b. CLASSIFICATION ENGINE -- data-driven, priority-ordered rule table
# ----------------------------------------------------------------------------------------------------
#
#  Each rule is a PSCustomObject with:
#    Category : broad bucket (System, Cache, Redownloadable, Project, Downloads, UserData, AppData, Other)
#    Tag      : short label shown in the row, e.g. "cache - clearable"
#    Color    : ConsoleColor name used to paint the row
#    Hint     : one-line description of what this is
#    Reclaim  : one-line guidance on whether/how it is safe to reclaim
#    Scope    : 'Dir', 'File', or 'Any' -- which entry kinds the rule can match
#    Priority : lower number = checked first (more specific rules win)
#    Test     : scriptblock ($name, $full, $isDir, $isProject) -> [bool], the matcher
#               $name = leaf name (lower), $full = full path (lower), $isDir = bool, $isProject = bool
#
#  The engine evaluates rules in Priority order and returns the FIRST match. Put exact full-path and
#  highly-specific rules at low priority numbers, broad name globs higher. Extend by adding a row.
# ----------------------------------------------------------------------------------------------------

function Get-ClassRules {
    <# Returns the ordered classification rule table. Pure data; built once and cached. #>
    if ($null -ne $script:ClassRules) { return $script:ClassRules }

    $rules = New-Object System.Collections.Generic.List[object]

    function _rule {
        param($Category,$Tag,$Color,$Hint,$Reclaim,$Scope,$Priority,$Test)
        [PSCustomObject]@{
            Category = $Category; Tag = $Tag; Color = $Color; Hint = $Hint
            Reclaim = $Reclaim; Scope = $Scope; Priority = $Priority; Test = $Test
        }
    }

    # ============ SYSTEM (careful) -- exact, highest priority ====================================
    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Windows OS files. Removing/altering can break the system.' `
        'Do NOT delete. Use Disk Cleanup / Storage Sense instead.' `
        'Dir' 10 `
        { param($n,$f,$d) ($f -match '^[a-z]:\\windows($|\\)') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Installed 32-bit applications.' `
        'Uninstall via Apps & Features rather than deleting folders.' `
        'Dir' 11 `
        { param($n,$f,$d) ($f -match '^[a-z]:\\program files \(x86\)($|\\)') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Installed 64-bit applications.' `
        'Uninstall via Apps & Features rather than deleting folders.' `
        'Dir' 12 `
        { param($n,$f,$d) ($f -match '^[a-z]:\\program files($|\\)') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Per-machine application data and installer state.' `
        'Some app caches live here, but deleting blindly can break apps. Be careful.' `
        'Dir' 12 `
        { param($n,$f,$d) ($f -match '^[a-z]:\\programdata($|\\)') } ) )

    $rules.Add( (_rule 'System' 'recycle bin' 'DarkRed' `
        'Recycle Bin storage for the drive.' `
        'Empty via the Recycle Bin UI; do not delete the folder.' `
        'Any' 12 `
        { param($n,$f,$d) ($n -eq '$recycle.bin') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'NTFS restore-point / shadow-copy metadata.' `
        'Managed by Windows. Use System Protection settings.' `
        'Any' 12 `
        { param($n,$f,$d) ($n -eq 'system volume information') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Virtual-memory paging file.' `
        'Managed by Windows. Adjust via System > Advanced > Virtual Memory.' `
        'File' 12 `
        { param($n,$f,$d) ($n -eq 'pagefile.sys') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Hibernation image (saved RAM).' `
        'Reclaim by disabling hibernation: powercfg /hibernate off.' `
        'File' 12 `
        { param($n,$f,$d) ($n -eq 'hiberfil.sys') } ) )

    $rules.Add( (_rule 'System' 'system - careful' 'DarkRed' `
        'Modern-app swap file.' `
        'Managed by Windows; reclaimed automatically.' `
        'File' 12 `
        { param($n,$f,$d) ($n -eq 'swapfile.sys') } ) )

    $rules.Add( (_rule 'System' 'boot - careful' 'DarkRed' `
        'Boot / recovery / perf data.' `
        'Do NOT delete -- the machine may not boot.' `
        'Any' 13 `
        { param($n,$f,$d) ($n -eq 'boot' -or $n -eq 'recovery' -or $n -eq 'msocache' -or $n -eq 'perflogs') } ) )

    $rules.Add( (_rule 'UserData' 'users root - careful' 'Green' `
        'The Users folder. Holds every profile.' `
        'Never delete; drill into a specific profile instead.' `
        'Dir' 14 `
        { param($n,$f,$d) ($f -match '^[a-z]:\\users$') } ) )

    # ============ CACHE / JUNK (clearable) -- specific known offenders first =======================
    $rules.Add( (_rule 'Cache' 'WSL crash dumps - clearable' 'Yellow' `
        'WSL2 crash dumps. Known to accumulate to tens of GB on this machine.' `
        'Safe to empty; it recurs.' `
        'Dir' 18 `
        { param($n,$f,$d) ($f -like '*\appdata\local\temp\wsl-crashes*' -or $n -eq 'wsl-crashes') } ) )

    $rules.Add( (_rule 'Cache' 'temp - clearable' 'Yellow' `
        'Temporary files. Apps recreate what they need.' `
        'Safe to clear; close apps first to avoid in-use files.' `
        'Any' 19 `
        { param($n,$f,$d) ($n -eq 'temp' -or $n -eq 'tmp' -or $f -like '*\appdata\local\temp*' -or $f -match '^[a-z]:\\windows\\temp($|\\)') } ) )

    $rules.Add( (_rule 'Cache' 'pip cache - re-downloadable' 'Yellow' `
        'pip download / wheel cache.' `
        'Safe to delete; pip re-downloads. (pip cache purge)' `
        'Dir' 20 `
        { param($n,$f,$d) ($f -like '*\pip\cache*' -or $f -like '*\pip\http*' -or $f -like '*\pip\wheels*' -or $n -eq 'pip-cache') } ) )

    $rules.Add( (_rule 'Cache' 'npm cache - re-downloadable' 'Yellow' `
        'npm / npx package cache.' `
        'Safe to delete; npm re-fetches. (npm cache clean --force)' `
        'Dir' 20 `
        { param($n,$f,$d) ($n -eq '_cacache' -or $n -eq '_npx' -or $f -like '*\npm-cache*' -or $f -like '*\.npm\*') } ) )

    $rules.Add( (_rule 'Cache' 'browser cache - clearable' 'Yellow' `
        'Browser engine cache.' `
        'Safe to clear; the browser rebuilds it.' `
        'Dir' 21 `
        { param($n,$f,$d) ($n -eq 'code cache' -or $n -eq 'gpucache' -or $n -eq 'cache_data' -or $n -eq 'service worker') } ) )

    $rules.Add( (_rule 'Cache' 'Store sandbox - clear in-app' 'DarkYellow' `
        'Microsoft Store app sandboxes (e.g. Spotify / Claude offline data).' `
        'Clear from inside each app; do not delete the folders blindly.' `
        'Dir' 21 `
        { param($n,$f,$d) ($n -eq 'packages' -and $f -like '*\appdata\local\packages') } ) )

    $rules.Add( (_rule 'Cache' 'WSL vhdx - compact, do not delete' 'DarkYellow' `
        'The WSL2 virtual disk (.vhdx). Grows, never auto-shrinks.' `
        'Do NOT delete -- it IS your Linux filesystem. Compact after freeing Linux space.' `
        'Any' 22 `
        { param($n,$f,$d) ($f -like '*\appdata\local\wsl*' -or $n -like '*.vhdx') } ) )

    $rules.Add( (_rule 'Cache' 'cache - clearable' 'Yellow' `
        'A cache directory. Contents are regenerated as needed.' `
        'Generally safe to delete; the owning app rebuilds it.' `
        'Dir' 25 `
        { param($n,$f,$d) ($n -like '*cache*' -or $n -eq '.cache' -or $n -eq '__pycache__' -or $n -eq '.gradle' -or $n -eq '.nuget') } ) )

    $rules.Add( (_rule 'Cache' 'logs - clearable' 'Yellow' `
        'Log / crash-dump files.' `
        'Usually safe to delete old logs.' `
        'Dir' 26 `
        { param($n,$f,$d) ($n -eq 'logs' -or $n -eq 'log' -or $n -eq 'crashpad' -or $n -eq 'crashdumps') } ) )

    # ============ RE-DOWNLOADABLE (regenerable build/dep artifacts, game content) ==================
    $rules.Add( (_rule 'Redownloadable' 're-downloadable' 'Cyan' `
        'Node.js dependencies. Regenerated from package.json.' `
        'Safe to delete; restore with: npm install.' `
        'Dir' 30 `
        { param($n,$f,$d) ($n -eq 'node_modules') } ) )

    $rules.Add( (_rule 'Redownloadable' 're-downloadable' 'Cyan' `
        'Python virtual environment.' `
        'Safe to delete; recreate with python -m venv + pip install.' `
        'Dir' 30 `
        { param($n,$f,$d) ($n -eq '.venv' -or $n -eq 'venv' -or $n -eq 'env' -or $n -eq 'virtualenv' -or $n -eq '.tox') } ) )

    $rules.Add( (_rule 'Redownloadable' 'build output - regenerable' 'Cyan' `
        'Compiled build output.' `
        'Safe to delete; rebuild from source.' `
        'Dir' 31 `
        { param($n,$f,$d) ($n -eq 'target' -or $n -eq 'build' -or $n -eq 'dist' -or $n -eq 'out' -or $n -eq 'bin' -or $n -eq 'obj' -or $n -eq '.next' -or $n -eq '.nuxt' -or $n -eq '.svelte-kit' -or $n -eq '.turbo' -or $n -eq '.parcel-cache') } ) )

    $rules.Add( (_rule 'Redownloadable' 'Playwright browsers - re-downloadable' 'Cyan' `
        'Playwright-managed browser binaries.' `
        'Safe to delete; restore with: npx playwright install.' `
        'Dir' 31 `
        { param($n,$f,$d) ($n -eq 'ms-playwright' -or $f -like '*\ms-playwright*') } ) )

    $rules.Add( (_rule 'Redownloadable' 'Steam games - re-downloadable' 'Cyan' `
        'Steam-installed game content.' `
        'Re-downloadable via Steam. Uninstall games you do not play.' `
        'Dir' 31 `
        { param($n,$f,$d) ($n -eq 'steamapps' -or $f -like '*\steam\steamapps*' -or $f -like '*\steamapps*') } ) )

    $rules.Add( (_rule 'Redownloadable' 'Arma Workshop addons - re-downloadable' 'Cyan' `
        'Arma Reforger Workshop content. Large and re-downloadable.' `
        'Safe to delete unused addons; re-download via the in-game Workshop.' `
        'Dir' 31 `
        { param($n,$f,$d) ($f -like '*\my games\armareforger\addons*' -or ($n -eq 'addons' -and $f -like '*armareforger*')) } ) )

    $rules.Add( (_rule 'Redownloadable' 'package cache - re-downloadable' 'Cyan' `
        'Downloaded package / toolchain cache.' `
        'Safe to delete; re-downloaded on demand.' `
        'Dir' 32 `
        { param($n,$f,$d) ($n -eq '.m2' -or $n -eq '.cargo' -or $n -eq '.rustup' -or $n -eq '.conda' -or $n -eq 'pkgs' -or $n -eq 'fnm') } ) )

    # ============ PROJECT / REPO ==================================================================
    $rules.Add( (_rule 'Project' 'git internals' 'DarkCyan' `
        'Git repository internal data (history, objects).' `
        'Do NOT delete -- this is your version history. (gc/repack to shrink.)' `
        'Dir' 33 `
        { param($n,$f,$d) ($n -eq '.git') } ) )

    # NOTE: the project matcher is STRING-ONLY here. The actual filesystem marker probe runs once in
    # Get-LevelEntries (Test-LooksLikeProject) and is passed into Get-EntryClass as $isProject (the 4th
    # matcher arg). This keeps Get-EntryClass pure/dot-source-testable and off the hot scan path.
    $rules.Add( (_rule 'Project' 'project' 'Blue' `
        'Looks like a source project (contains repo/build markers).' `
        'Keep -- your work. Reclaim space inside via node_modules/build/.venv.' `
        'Dir' 60 `
        { param($n,$f,$d,$proj) ([bool]$proj) } ) )

    # ============ DOWNLOADS =======================================================================
    $rules.Add( (_rule 'Downloads' 'downloads - often clearable' 'Magenta' `
        'A Downloads folder. Often full of one-off installers.' `
        'Review and delete installers/archives you no longer need.' `
        'Dir' 40 `
        { param($n,$f,$d) ($n -eq 'downloads' -or $f -like '*\downloads') } ) )

    # ============ USER DATA (keep) ================================================================
    $rules.Add( (_rule 'UserData' 'user data - keep' 'Green' `
        'OneDrive synced data.' `
        'Keep. To free local space, use Files On-Demand instead of deleting.' `
        'Dir' 41 `
        { param($n,$f,$d) ($n -like 'onedrive*' -or $f -like '*\onedrive*') } ) )

    $rules.Add( (_rule 'UserData' 'user data - keep' 'Green' `
        'Your personal documents / media.' `
        'Keep -- irreplaceable user files. Back up before any cleanup.' `
        'Dir' 42 `
        { param($n,$f,$d) ($n -eq 'documents' -or $n -eq 'my documents' -or $n -eq 'desktop' -or $n -eq 'pictures' -or $n -eq 'videos' -or $n -eq 'music' -or $n -eq 'favorites' -or $n -eq 'contacts' -or $n -eq 'saved games') } ) )

    # ============ APP DATA (after caches/re-downloadable/user-data have had their say) ============
    $rules.Add( (_rule 'AppData' 'app data (local) - mixed' 'DarkBlue' `
        'Per-machine application data for your user. Mix of caches and real settings.' `
        'Drill in: caches here are clearable, but app state/settings are not.' `
        'Dir' 50 `
        { param($n,$f,$d) ($n -eq 'local' -and $f -like '*\appdata\local') } ) )

    $rules.Add( (_rule 'AppData' 'app data (locallow) - mixed' 'DarkBlue' `
        'Low-integrity application data.' `
        'Mostly app caches/state. Drill in before deleting.' `
        'Dir' 50 `
        { param($n,$f,$d) ($n -eq 'locallow' -and $f -like '*\appdata\locallow') } ) )

    $rules.Add( (_rule 'AppData' 'app data (roaming) - settings' 'DarkBlue' `
        'Roaming application settings that follow your profile.' `
        'Usually real settings -- keep unless you know an app is gone.' `
        'Dir' 50 `
        { param($n,$f,$d) ($n -eq 'roaming' -and $f -like '*\appdata\roaming') } ) )

    $rules.Add( (_rule 'AppData' 'app data - mixed' 'DarkBlue' `
        'Application data.' `
        'Mix of settings and caches; inspect before deleting.' `
        'Dir' 51 `
        { param($n,$f,$d) ($n -eq 'appdata' -or $f -like '*\appdata\*') } ) )

    $rules.Add( (_rule 'UserData' 'user profile - careful' 'Green' `
        'A user profile root.' `
        'Contains personal data and settings. Delete subfolders selectively, not the whole profile.' `
        'Dir' 52 `
        { param($n,$f,$d) ($f -match '^[a-z]:\\users\\[^\\]+$') } ) )

    # ============ FALLBACKS =======================================================================
    $rules.Add( (_rule 'Other' 'file' 'Gray' `
        'A file.' `
        'Inspect before deleting.' `
        'File' 900 `
        { param($n,$f,$d) (-not $d) } ) )

    $rules.Add( (_rule 'Other' 'folder' 'Gray' `
        'A folder of uncategorized content.' `
        'Inspect contents before deleting.' `
        'Dir' 901 `
        { param($n,$f,$d) $true } ) )

    # Sort by priority once and cache.
    $script:ClassRules = @($rules | Sort-Object Priority)
    return $script:ClassRules
}

function Get-EntryClass {
    <#
        Classify one entry by name + full path + dir flag. PURE -- no IO (the only rule that would need
        the filesystem, "project", consumes a precomputed -IsProject hint instead of probing). Returns
        the matching rule object (Category/Tag/Color/Hint/Reclaim). First matching rule (ascending
        Priority) wins; the catch-all fallbacks guarantee a result. Each matcher receives
        ($name, $fullLower, $isDir, $isProject).
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][bool]  $IsDir,
        [bool]$IsProject = $false
    )
    $n = $Name.ToLowerInvariant()
    $f = $FullPath.ToLowerInvariant()
    foreach ($rule in (Get-ClassRules)) {
        if ($rule.Scope -eq 'Dir'  -and -not $IsDir) { continue }
        if ($rule.Scope -eq 'File' -and      $IsDir) { continue }
        $ok = $false
        try { $ok = [bool](& $rule.Test $n $f $IsDir $IsProject) } catch { $ok = $false }
        if ($ok) { return $rule }
    }
    # Unreachable given the catch-alls, but be safe.
    return [PSCustomObject]@{
        Category='Other'; Tag='unknown'; Color='Gray'
        Hint='Uncategorized.'; Reclaim='Inspect before deleting.'; Scope='Any'; Priority=999; Test=$null
    }
}


# ----------------------------------------------------------------------------------------------------
# 1c. SIZING -- iterative, reparse-safe recursive byte total (fast: EnumerateFileSystemInfos)
# ----------------------------------------------------------------------------------------------------

function Measure-DirBytes {
    <#
        Total recursive bytes under a directory (or the size of a single file), using an EXPLICIT
        iterative stack walk via DirectoryInfo.EnumerateFileSystemInfos (far cheaper than Get-Item
        per child). This is the core anti-junction-loop logic: every directory is tested for
        ReparsePoint before its children are pushed, and a visited-set guards against any residual
        loop. Reparse points (file OR dir) are NEVER measured or descended.

        Correctness/perf hardening:
          * LONG PATHS: every DirectoryInfo/FileInfo is built from the \\?\ extended-length form
            (Get-LongPath) so deep trees beyond 260 chars are measured, not silently counted as 0.
          * MEMOIZATION: while descending, each SUBDIRECTORY's own recursive total is recorded in
            $script:SizeMemo (keyed by normalized path). Drilling into a child later reuses that total
            instead of re-walking the subtree the parent scan already walked. The top is memoized too.
          * CANCELLABLE: an optional -CancelCheck scriptblock returning $true aborts the walk and
            returns the partial total, so a 100k-entry tree cannot freeze the UI with no way out.

        Returns [double] bytes. Null/denied sums are treated as 0; never throws on locked items.
        Optional -Progress scriptblock is invoked with a directory name occasionally as a heartbeat.
    #>
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [bool]$IsDir = $true,
        [scriptblock]$Progress,
        [scriptblock]$CancelCheck,
        [bool]$Memoize = $true
    )

    $reparseAttr = $script:ReparseFlag
    $dirAttr     = [System.IO.FileAttributes]::Directory

    if (-not $IsDir) {
        try {
            $fi = New-Object System.IO.FileInfo((Get-LongPath $FullPath))
            if (($fi.Attributes -band $reparseAttr) -eq $reparseAttr) { return 0 }
            return [double]$fi.Length
        } catch { return 0 }
    }

    # Reuse a previously computed subtree total when one is memoized (drill-in is then a cache hit).
    $topKey = Get-NormalizedPath $FullPath
    if ($Memoize -and $script:SizeMemo.ContainsKey($topKey)) { return [double]$script:SizeMemo[$topKey] }

    # Don't even start if the top itself is a reparse point.
    $topInfo = $null
    try {
        $topInfo = New-Object System.IO.DirectoryInfo((Get-LongPath $FullPath))
        if (($topInfo.Attributes -band $reparseAttr) -eq $reparseAttr) { return 0 }
    } catch { return 0 }

    # Per-directory running totals so each subdirectory's own subtree total can be memoized as the
    # walk unwinds. We process post-order by deferring a directory's "finalize" until its children pop.
    $subtotal = @{}                       # normalized dir key -> [double] bytes accumulated so far
    $parentOf = @{}                       # normalized dir key -> parent normalized key (for roll-up)

    $stack = New-Object System.Collections.Stack
    $stack.Push($topInfo)
    $subtotal[$topKey] = [double]0
    $parentOf[$topKey] = $null

    $visited = New-Object 'System.Collections.Generic.HashSet[string]'
    $finished = New-Object 'System.Collections.Generic.List[string]'   # keys in pop order, for roll-up
    $checkCounter = 0
    $aborted = $false

    while ($stack.Count -gt 0) {
        $dirInfo = $stack.Pop()
        $dispName = ''
        try { $dispName = $dirInfo.Name } catch { }
        $key = $null
        try { $key = (Get-NormalizedPath $dirInfo.FullName) } catch { $key = $null }
        if ($null -eq $key) { continue }
        if (-not $visited.Add($key)) { continue }
        if (-not $subtotal.ContainsKey($key)) { $subtotal[$key] = [double]0 }
        $finished.Add($key)

        if ($Progress) { try { & $Progress $dispName } catch { } }

        # Periodic cancellation check (cheap; only every 64 directories).
        $checkCounter++
        if ($CancelCheck -and ($checkCounter -band 63) -eq 0) {
            $stop = $false
            try { $stop = [bool](& $CancelCheck) } catch { $stop = $false }
            if ($stop) { $aborted = $true; break }
        }

        $children = $null
        try { $children = $dirInfo.EnumerateFileSystemInfos() } catch { $children = $null }
        if ($null -eq $children) { continue }

        $enum = $null
        try { $enum = $children.GetEnumerator() } catch { $enum = $null }
        if ($null -eq $enum) { continue }

        while ($true) {
            # MoveNext()/Current can throw on a denied/locked entry mid-iteration; swallow and stop.
            $hasNext = $false
            try { $hasNext = $enum.MoveNext() } catch { break }
            if (-not $hasNext) { break }

            $info = $enum.Current
            $attrs = $null
            try { $attrs = $info.Attributes } catch { continue }

            if (($attrs -band $reparseAttr) -eq $reparseAttr) { continue }   # never follow a junction/symlink

            if (($attrs -band $dirAttr) -eq $dirAttr) {
                $ckey = $null
                try { $ckey = (Get-NormalizedPath $info.FullName) } catch { $ckey = $null }
                if ($null -ne $ckey) {
                    if (-not $subtotal.ContainsKey($ckey)) { $subtotal[$ckey] = [double]0 }
                    $parentOf[$ckey] = $key
                    $stack.Push($info)                    # a real subdirectory
                }
            } else {
                try { $subtotal[$key] += [double]$info.Length } catch { }
            }
        }
    }

    # Roll child subtree totals up into their parents (process deepest-finished-first by reversing the
    # discovery order is not strictly post-order, so iterate to a fixed point cheaply via parent links).
    # Each finished dir already holds its own files; add it into its parent's running total.
    for ($i = $finished.Count - 1; $i -ge 0; $i--) {
        $k = $finished[$i]
        $par = $parentOf[$k]
        if ($null -ne $par -and $subtotal.ContainsKey($par)) {
            $subtotal[$par] += [double]$subtotal[$k]
        }
    }

    $total = [double]$subtotal[$topKey]

    # Memoize fully-walked subtrees only (a partial/aborted walk must not poison the memo with a low
    # number). When complete, every visited dir's roll-up is final, so memoize them all for drill-in.
    if ($Memoize -and -not $aborted) {
        foreach ($k in $finished) {
            if ($subtotal.ContainsKey($k)) { $script:SizeMemo[$k] = [double]$subtotal[$k] }
        }
    }

    return $total
}


# ----------------------------------------------------------------------------------------------------
# 1d. LEVEL ENUMERATION + CACHE -- immediate children with sizes + classification
# ----------------------------------------------------------------------------------------------------

function Test-LooksLikeProject {
    <#
        Filesystem probe (IO) for repo/build markers in a directory. Kept OUT of Get-EntryClass so the
        classifier stays string-only / dot-source-testable; the result is passed in as a precomputed
        IsProject hint. Stops at the first marker found. Never throws.
    #>
    param([Parameter(Mandatory)][string]$DirPath)
    foreach ($m in @('.git','package.json','cargo.toml','pyproject.toml','go.mod','requirements.txt','pom.xml')) {
        try { if (Test-Path -LiteralPath (Join-Path $DirPath $m)) { return $true } } catch { }
    }
    return $false
}

function Get-LevelEntries {
    <#
        Build the model for ONE directory level: ALL its immediate children (dirs + files) with
        recursive sizes and classification, sorted by size descending. Files are ALWAYS measured and
        returned (an IsDir flag lets the consumer hide files at render time WITHOUT changing the
        directory's true total), so toggling file visibility never re-walks subtrees and the header
        total stays invariant. Reparse-point children are listed (so the user sees them) but reported
        as 0 bytes and tagged "junction/symlink - not followed".

        Returns an array of PSCustomObject: Name, FullName, IsDir, IsReparse, Bytes, Class.
        Optional -Progress is forwarded to the size walk as a heartbeat; -CancelCheck aborts a slow
        walk. If the walk is cancelled, [ref]$Cancelled is set $true so the caller can avoid CACHING a
        partial/incomplete listing. Reads the filesystem; caching is the caller's job.
    #>
    param(
        [Parameter(Mandatory)][string]$DirPath,
        [scriptblock]$Progress,
        [scriptblock]$CancelCheck,
        [ref]$Cancelled
    )

    if ($null -ne $Cancelled) { $Cancelled.Value = $false }

    $entries = New-Object System.Collections.Generic.List[object]
    $children = $null
    try {
        $children = @(Get-ChildItem -LiteralPath $DirPath -Force -ErrorAction SilentlyContinue)
    } catch {
        $children = @()
    }

    foreach ($ci in $children) {
        # Allow cancellation between children of a huge level (e.g. 100k entries) so the UI is abortable.
        if ($CancelCheck) {
            $stop = $false
            try { $stop = [bool](& $CancelCheck) } catch { $stop = $false }
            if ($stop) { if ($null -ne $Cancelled) { $Cancelled.Value = $true }; break }
        }

        $isDir = $false
        try { $isDir = [bool]$ci.PSIsContainer } catch { }

        $isReparse = Test-IsReparsePoint $ci

        if ($isReparse) {
            $bytes = 0
            $cls = [PSCustomObject]@{
                Category='Reparse'; Tag='junction/symlink - not followed'; Color='DarkCyan'
                Hint='Reparse point (junction or symlink). Skipped to avoid loops; size shown as 0.'
                Reclaim='Manage the link target directly, not through here.'; Scope='Any'; Priority=0; Test=$null
            }
        } elseif ($isDir) {
            $bytes = Measure-DirBytes -FullPath $ci.FullName -IsDir $true -Progress $Progress -CancelCheck $CancelCheck
            # Classify with the cheap string rules FIRST. Only if the directory falls through to the
            # generic 'folder' fallback do we pay for the filesystem project-marker probe (up to 7
            # Test-Path stats) and reclassify -- so the probe runs on a small minority of dirs, not on
            # every child during the scan.
            $cls = Get-EntryClass -Name $ci.Name -FullPath $ci.FullName -IsDir $true -IsProject $false
            if ($cls.Category -eq 'Other' -and (Test-LooksLikeProject -DirPath $ci.FullName)) {
                $cls = Get-EntryClass -Name $ci.Name -FullPath $ci.FullName -IsDir $true -IsProject $true
            }
        } else {
            try { $bytes = [double]$ci.Length } catch { $bytes = 0 }
            $cls = Get-EntryClass -Name $ci.Name -FullPath $ci.FullName -IsDir $false
        }

        $entries.Add( [PSCustomObject]@{
            Name      = $ci.Name
            FullName  = $ci.FullName
            IsDir     = $isDir
            IsReparse = $isReparse
            Bytes     = [double]$bytes
            Class     = $cls
        } )
    }

    return @($entries | Sort-Object -Property @{Expression='Bytes';Descending=$true}, @{Expression='Name';Descending=$false})
}

function Get-CachedLevel {
    <#
        Return @{ Entries; Total } for a path. Entries is ALWAYS the full child set (dirs + files);
        Total is the invariant directory total (dirs + loose files) regardless of how files are later
        displayed. This is what makes the TUI fast: a directory's children are measured ONCE on entry,
        then reused on redraw, on navigation back, AND across file-visibility toggles (which only change
        what is rendered, never what is measured). $StatusCallback (optional) is invoked with the path
        just before a (potentially slow) scan; -Progress animates a per-directory heartbeat during the
        scan; -CancelCheck lets a slow scan be aborted.

        NOTE: the returned Entries always include files. Consumers that hide files (TUI 'g' off, or a
        folders-only dump) filter at render time via Select-VisibleEntries; the cached Total never moves.
    #>
    param(
        [Parameter(Mandatory)][string]$DirPath,
        [scriptblock]$StatusCallback,
        [scriptblock]$Progress,
        [scriptblock]$CancelCheck,
        [switch]$Force
    )
    $key = Get-NormalizedPath $DirPath
    if (-not $Force -and $script:LevelCache.ContainsKey($key)) {
        return $script:LevelCache[$key]
    }
    if ($StatusCallback) { try { & $StatusCallback $DirPath } catch { } }
    $cancelled = $false
    $cref = [ref]$cancelled
    # @(...) is REQUIRED: a function returning an empty array emits zero pipeline objects, which a bare
    # assignment captures as $null (PowerShell empty-array-unrolling gotcha). Without the wrap, an EMPTY
    # directory would cache Entries=$null and crash Select-VisibleEntries downstream.
    $entries = @(Get-LevelEntries -DirPath $DirPath -Progress $Progress -CancelCheck $CancelCheck -Cancelled $cref)
    $total = [double]0
    foreach ($e in $entries) { $total += [double]$e.Bytes }
    $rec = @{ Entries = $entries; Total = [double]$total }
    # Do NOT cache a cancelled/partial scan -- it would freeze an incomplete listing/total into the
    # cache. Returning it uncached lets this draw proceed; the next entry into the dir rescans cleanly.
    if (-not $cref.Value) { $script:LevelCache[$key] = $rec }
    return $rec
}

function Select-VisibleEntries {
    <#
        Filter a level's full entry set for display: when -IncludeFiles is $false, drop file rows
        (folders and reparse points stay). PURE; does not touch the cached Total, so hiding files never
        changes the directory's reported size or the percentages (which are computed against the
        invariant Total).
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Entries,
        [bool]$IncludeFiles = $true
    )
    if ($null -eq $Entries) { return @() }
    if ($IncludeFiles) { return @($Entries) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entries) { if ($e.IsDir) { $out.Add($e) } }
    return @($out.ToArray())
}

function Invalidate-CacheUp {
    <#
        Drop cached level scans AND memoized subtree sizes for a path and all its ancestors (totals
        change after a delete). Tolerates $null/'' (passing the parent of a drive-root child yields
        $null) so callers never need to guard -- this also closes the "delete a top-level item at C:\
        crashes by binding $null to a Mandatory [string]" defect.
    #>
    param([AllowNull()][AllowEmptyString()][string]$FromPath)
    if ([string]::IsNullOrEmpty($FromPath)) { return }
    $p = $FromPath
    while ($p) {
        $k = Get-NormalizedPath $p
        if ($script:LevelCache.ContainsKey($k)) { [void]$script:LevelCache.Remove($k) }
        if ($script:SizeMemo.ContainsKey($k))   { [void]$script:SizeMemo.Remove($k) }
        $p = Get-ParentPath $p
    }
}

function Invalidate-CacheDown {
    <#
        Drop cached level scans AND memoized subtree sizes for a path and everything beneath it. Called
        after a delete so a previously-drilled-into (now-removed) subtree cannot serve stale pre-delete
        listings/sizes if a directory is later recreated at the same path within the session.
    #>
    param([AllowNull()][AllowEmptyString()][string]$FromPath)
    if ([string]::IsNullOrEmpty($FromPath)) { return }
    $key = Get-NormalizedPath $FromPath
    $prefix = $key + '\'
    foreach ($k in @($script:LevelCache.Keys)) {
        if ($k -eq $key -or $k.StartsWith($prefix)) { [void]$script:LevelCache.Remove($k) }
    }
    foreach ($k in @($script:SizeMemo.Keys)) {
        if ($k -eq $key -or $k.StartsWith($prefix)) { [void]$script:SizeMemo.Remove($k) }
    }
}


# ----------------------------------------------------------------------------------------------------
# 1e. GUARDRAILS -- protected paths that must never be deleted
# ----------------------------------------------------------------------------------------------------

function Get-ProtectedReason {
    <#
        Return a non-empty reason string if $FullPath must NOT be deleted, else $null. Canonicalizes the
        path to its real long name (one Get-Item) before string matching so 8.3 short-name / trailing-dot
        aliases cannot bypass the rules; otherwise pure path-string logic. Covers drive roots, Windows
        (and its subitems), Program Files / (x86), ProgramData (by regex AND by environment path), the
        Users folder ITSELF, ANY user profile root C:\Users\<name> (not just the current user --
        subfolders like C:\Users\bob\Downloads remain deletable), the Windows system root, $Recycle.Bin,
        System Volume Information, and pagefile/hiberfil/swapfile. Reparse-point refusal is enforced
        separately against the live item by the caller. Called only on the delete path, never the hot
        scan path, so the one canonicalizing stat is cheap.
    #>
    param([Parameter(Mandatory)][string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) { return 'empty path' }

    # CANONICALIZE to the real long name before string matching. GetFullPath (used by Get-NormalizedPath)
    # resolves '..' but does NOT expand 8.3 short names (C:\PROGRA~1) or trim trailing dots/spaces, which
    # would let an aliased path slip past the literal long-name regexes. If the item exists, resolve its
    # authoritative .FullName from the filesystem so PROGRA~1 -> "Program Files", etc. all collapse to the
    # canonical target. Fall back to the string-normalized form when the item cannot be resolved.
    $canon = $FullPath
    try {
        if (Test-Path -LiteralPath $FullPath) {
            $li = Get-Item -LiteralPath $FullPath -Force -ErrorAction Stop
            if ($li -and $li.FullName) { $canon = $li.FullName }
        }
    } catch { }

    $f = Get-NormalizedPath $canon

    if (Test-IsDriveRoot $canon)                         { return 'a drive root' }
    if ($f -match '^[a-z]:\\windows($|\\)')              { return 'inside C:\Windows' }
    if ($f -match '^[a-z]:\\program files \(x86\)($|\\)'){ return 'C:\Program Files (x86)' }
    if ($f -match '^[a-z]:\\program files($|\\)')        { return 'C:\Program Files' }
    if ($f -match '^[a-z]:\\programdata($|\\)')          { return 'C:\ProgramData (per-machine app data)' }
    if ($f -match '^[a-z]:\\users$')                     { return 'the Users folder itself' }
    # Any direct child of Users (C:\Users\<name>) is a full profile root -- protect it for ALL users,
    # not just the current one. Deleting another live profile root is high-impact; subfolders stay open.
    if ($f -match '^[a-z]:\\users\\[^\\]+$')             { return 'a user profile root' }

    $leaf = Split-Path -Leaf $f
    if ($leaf -eq '$recycle.bin')                        { return 'the Recycle Bin store' }
    if ($leaf -eq 'system volume information')           { return 'System Volume Information' }
    if ($leaf -eq 'pagefile.sys' -or $leaf -eq 'hiberfil.sys' -or $leaf -eq 'swapfile.sys') {
        return 'a protected system file (page/hibernation/swap)'
    }

    # Current user profile root (exact match only; its subfolders are deletable). Covered by the Users
    # child rule above too, but kept for an explicit, clearer message.
    if ($env:USERPROFILE) {
        $up = Get-NormalizedPath $env:USERPROFILE
        if ($f -eq $up) { return 'your user profile root ($env:USERPROFILE)' }
    }
    # Program Files variants resolved from the environment (defends against non-standard install drives
    # and short-name aliasing that survived canonicalization).
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($pf) {
            $pfn = Get-NormalizedPath $pf
            if ($f -eq $pfn -or $f.StartsWith($pfn + '\')) { return 'a protected system location' }
        }
    }
    # Windows system root variants.
    if ($env:SystemRoot) {
        $sr = Get-NormalizedPath $env:SystemRoot
        if ($f -eq $sr -or $f.StartsWith($sr + '\')) { return 'the Windows system root' }
    }

    return $null
}


# ====================================================================================================
# 2. CONSOLE IO  (kept separate from the pure logic above)
# ====================================================================================================

function Test-Interactive {
    <#
        True only if we can safely use ReadKey on a real console. Conservative: any doubt -> false ->
        caller falls back to the non-interactive dump.
    #>
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected)  { return $false }
        if ([Console]::IsOutputRedirected) { return $false }
        # Touching these throws when there is no real console.
        $null = [Console]::WindowWidth
        $null = [Console]::CursorVisible
        return $true
    } catch {
        return $false
    }
}

function Get-ConsoleSize {
    <# Returns @{ W; H } with sane fallbacks. W leaves the last column unused to avoid auto-wrap. #>
    param([int]$DefaultW = 100, [int]$DefaultH = 30)
    $w = $DefaultW; $h = $DefaultH
    try { $w = [Console]::WindowWidth }  catch { }
    try { $h = [Console]::WindowHeight } catch { }
    if ($w -lt 60) { $w = 60 }
    if ($h -lt 12) { $h = 12 }
    return @{ W = ($w - 1); H = $h }
}

function Ensure-VisualBasic {
    if ($script:VbLoaded) { return $true }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $script:VbLoaded = $true; return $true }
    catch { return $false }
}


# ----------------------------------------------------------------------------------------------------
# 2b. FRAME RENDERING -> returns an array of { Text; Color } line objects (PURE; no console writes)
# ----------------------------------------------------------------------------------------------------

function Render-Frame {
    <#
        Build the full TUI frame as an array of [PSCustomObject]@{ Text; Color }. PURE: takes state,
        returns lines; no console writes (the caller paints them). This lets the renderer be
        unit-tested (Render-Frame ... | % Text). Color is a ConsoleColor name 'Fg', or 'Fg:Bg' for the
        selected/highlighted rows. Class fields are read via Get-ClassField (StrictMode-safe).
    #>
    param(
        [Parameter(Mandatory)][string]$CurrentPath,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Entries,
        [Parameter(Mandatory)][int]$Selected,
        [Parameter(Mandatory)][int]$Top,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [double]$CurrentTotal = -1,
        [double]$ParentTotal = -1,
        [bool]$ShowFiles = $true,
        [string]$Status = ''
    )

    if ($Width  -lt 40) { $Width  = 40 }
    if ($Height -lt 12) { $Height = 12 }
    $lines = New-Object System.Collections.ArrayList

    $mkLine = {
        param($t, $c)
        if ($null -eq $t) { $t = '' }
        if ($t.Length -gt $Width) { $t = $t.Substring(0, $Width) }
        [PSCustomObject]@{ Text = $t; Color = $c }
    }

    $count = @($Entries).Count

    # Compute totals / max if not supplied.
    if ($CurrentTotal -lt 0) {
        $CurrentTotal = 0
        foreach ($e in $Entries) { $CurrentTotal += $e.Bytes }
    }
    $maxBytes = [double]0
    foreach ($e in $Entries) { if ($e.Bytes -gt $maxBytes) { $maxBytes = $e.Bytes } }

    # --- Header (title bar) ---
    $title = ' Show-DiskUsage -- ncdu-style explorer '
    [void]$lines.Add((& $mkLine ($title.PadRight($Width)) 'Black:DarkCyan'))

    # --- Header (path + total + pct of parent) ---
    $totalStr = (Format-Size -Bytes $CurrentTotal -Width 1).Trim()
    $pctStr = ''
    if ($ParentTotal -gt 0) {
        $pctStr = '  (' + (Format-Percent -Fraction ($CurrentTotal / $ParentTotal)).Trim() + ' of parent)'
    }
    $meta = ('  ' + $totalStr + $pctStr + ' ')
    $room = $Width - $meta.Length
    if ($room -lt 1) { $room = 1 }
    $hdr = (' ' + $CurrentPath)
    if ($hdr.Length -gt $room) { $hdr = $hdr.Substring(0, [math]::Max(0,$room-1)) + ([char]0x2026) }
    $hdrLine = $hdr.PadRight($room) + $meta
    [void]$lines.Add((& $mkLine $hdrLine 'White'))

    # --- Separator ---
    [void]$lines.Add((& $mkLine (([string]([char]0x2500)) * $Width) 'DarkGray'))

    # --- Body geometry: reserve 3 header + 3 footer (hint, reclaim, help) = 6 chrome lines. ---
    $reserved = 6
    $rows = $Height - $reserved
    if ($rows -lt 1) { $rows = 1 }

    # Bar width scales to terminal: ~22% of width, clamped.
    $sizeW = 9
    $barInner = [int][math]::Floor($Width * 0.22)
    if ($barInner -lt 6)  { $barInner = 6 }
    if ($barInner -gt 28) { $barInner = 28 }

    if ($count -eq 0) {
        [void]$lines.Add((& $mkLine '   <empty>' 'DarkGray'))
        for ($i = 1; $i -lt $rows; $i++) { [void]$lines.Add((& $mkLine '' 'Gray')) }
    } else {
        $end = [math]::Min($Top + $rows, $count)
        for ($i = $Top; $i -lt $end; $i++) {
            $e = $Entries[$i]
            $sizeTxt = Format-Size -Bytes $e.Bytes -Width $sizeW
            $barTxt  = Format-Bar  -Value $e.Bytes -Max $maxBytes -Width $barInner
            $pctFrac = if ($CurrentTotal -gt 0) { $e.Bytes / $CurrentTotal } else { 0 }
            $pctTxt  = Format-Percent -Fraction $pctFrac

            if ($e.IsReparse) { $marker = '@' }      # @ = reparse (not descended)
            elseif ($e.IsDir) { $marker = '/' }
            else { $marker = ' ' }

            $left = ($sizeTxt + ' ' + $barTxt + ' ' + $pctTxt + ' ' + $marker)
            $remaining = $Width - $left.Length - 1
            if ($remaining -lt 4) { $remaining = 4 }

            $nameField = $e.Name
            $tagText   = [string](Get-ClassField $e.Class 'Tag' '')
            $tagField  = ''
            if ($tagText) { $tagField = ' [' + $tagText + ']' }
            $combined  = $nameField + $tagField
            if ($combined.Length -gt $remaining) {
                # Prefer keeping the tag visible; trim the name.
                $nameRoom = $remaining - $tagField.Length
                if ($nameRoom -lt 3) {
                    $combined = $combined.Substring(0, $remaining)
                } else {
                    $nm = $nameField
                    if ($nm.Length -gt $nameRoom) { $nm = $nm.Substring(0, [math]::Max(0,$nameRoom-1)) + ([char]0x2026) }
                    $combined = $nm.PadRight($nameRoom) + $tagField
                }
            }
            $rowText = ($left + ' ' + $combined)
            if ($rowText.Length -gt $Width) { $rowText = $rowText.Substring(0, $Width) }
            $rowText = $rowText.PadRight($Width)

            $rowColor = [string](Get-ClassField $e.Class 'Color' 'Gray')
            if (-not $rowColor) { $rowColor = 'Gray' }
            if ($i -eq $Selected) {
                [void]$lines.Add((& $mkLine $rowText ('Black:' + $rowColor)))
            } else {
                [void]$lines.Add((& $mkLine $rowText $rowColor))
            }
        }
        $printed = $end - $Top
        for ($i = $printed; $i -lt $rows; $i++) { [void]$lines.Add((& $mkLine '' 'Gray')) }
    }

    # --- Footer line 1: hint + scroll position (or status if a status is set) ---
    if ($count -gt 0) { $sel = ($Selected + 1) } else { $sel = 0 }
    $scrollInfo = "$sel/$count"
    if ($Status) {
        [void]$lines.Add((& $mkLine ((' ' + $Status).PadRight($Width)) 'Black:Yellow'))
    } else {
        $hint = ''
        if ($count -gt 0 -and $Selected -lt $count) { $hint = [string](Get-ClassField $Entries[$Selected].Class 'Hint' '') }
        $st = (' ' + $hint)
        $room2 = $Width - $scrollInfo.Length - 2
        if ($room2 -lt 0) { $room2 = 0 }
        if ($st.Length -gt $room2) { $st = $st.Substring(0, $room2) }
        [void]$lines.Add((& $mkLine ($st.PadRight($room2) + ' ' + $scrollInfo + ' ') 'DarkGray'))
    }

    # --- Footer line 2: reclaim hint of the selected entry ---
    $reclaim = ''
    if ($count -gt 0 -and $Selected -lt $count) { $reclaim = ' reclaim: ' + [string](Get-ClassField $Entries[$Selected].Class 'Reclaim' '') }
    [void]$lines.Add((& $mkLine ($reclaim.PadRight($Width)) 'DarkGray'))

    # --- Footer line 3: key legend ---
    $foot = ' Up/Dn move  Enter/Right in  Left up  d del  g files  r rescan  h help  q quit'
    [void]$lines.Add((& $mkLine ($foot.PadRight($Width)) 'Black:Gray'))

    return ,@($lines.ToArray())
}

function Get-HelpLines {
    <# Help overlay content as { Text; Color } line objects. Pure. #>
    $h = @(
        '  Show-DiskUsage -- ncdu-style disk explorer',
        '  ----------------------------------------------------------------',
        '  NAVIGATION',
        '    Up / Down ........ move selection',
        '    PageUp / PageDn .. scroll a page',
        '    Home / End ....... first / last entry',
        '    Right / Enter .... drill into folder',
        '    Left / Backspace . go up to parent (clamps at drive root)',
        '',
        '  ACTIONS',
        '    d ................ delete selected -> RECYCLE BIN (reversible)',
        '    Shift+D .......... PERMANENT delete (type DELETE to confirm)',
        '    r ................ rescan current directory',
        '    g ................ toggle showing files',
        '    h or ? ........... this help            q or Esc ... quit',
        '  (Recycle vs permanent is decided by the SHIFT key, never Caps Lock.)',
        '',
        '  TAGS color-code each entry: [system - careful] [app data]',
        '  [cache - clearable] [re-downloadable] [user data - keep]',
        '  [downloads - often clearable] [project].  @ marks reparse',
        '  points (junctions/symlinks) -- they are shown but never followed.',
        '',
        '  GUARDRAILS: drive roots, Windows, Program Files (x86), ProgramData,',
        '  the Users folder, ANY profile root (C:\Users\<name>), Recycle Bin,',
        '  System Volume Information and page/hiberfil/swapfile are PROTECTED.',
        '  During a slow scan, press Esc or q to STOP measuring this level.',
        '',
        '  Press any key to return.'
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($l in $h) { [void]$out.Add([PSCustomObject]@{ Text = $l; Color = 'Gray' }) }
    return ,@($out.ToArray())
}


# ----------------------------------------------------------------------------------------------------
# 2c. PAINTING -- flicker-free differential redraw of { Text; Color } line objects
# ----------------------------------------------------------------------------------------------------

function Paint-Frame {
    <#
        Flicker-free paint: writes only lines that changed since the last frame, moving the cursor with
        SetCursorPosition. Each line object is { Text; Color } where Color is 'Fg' or 'Fg:Bg'. Hides the
        cursor while painting. Guards every SetCursorPosition so a mid-session window resize cannot throw.
    #>
    param([Parameter(Mandatory)]$Lines, [switch]$ForceFull)

    $arr = @($Lines)
    try { [Console]::CursorVisible = $false } catch { }

    $width = 100
    try { $width = [Console]::WindowWidth } catch { $width = 100 }
    $padTo = $width - 1
    if ($padTo -lt 1) { $padTo = 1 }

    for ($i = 0; $i -lt $arr.Count; $i++) {
        $new = $arr[$i]
        $old = $null
        if (-not $ForceFull -and $i -lt $script:LastFrame.Count) { $old = $script:LastFrame[$i] }

        if ($null -ne $old -and $old.Text -eq $new.Text -and $old.Color -eq $new.Color) { continue }

        try { [Console]::SetCursorPosition(0, $i) } catch { break }

        $fg = $null; $bg = $null
        if ($new.Color -like '*:*') {
            $parts = $new.Color.Split(':'); $fg = $parts[0]; $bg = $parts[1]
        } else {
            $fg = $new.Color
        }

        $text = $new.Text
        if ($text.Length -lt $padTo) { $text = $text.PadRight($padTo) }
        elseif ($text.Length -gt $padTo) { $text = $text.Substring(0, $padTo) }

        $params = @{ Object = $text; NoNewline = $true }
        if ($fg) { try { $params['ForegroundColor'] = [System.ConsoleColor]$fg } catch { } }
        if ($bg) { try { $params['BackgroundColor'] = [System.ConsoleColor]$bg } catch { } }
        Write-Host @params
        try { [Console]::ResetColor() } catch { }
    }

    # If the new frame is shorter than the last, blank the trailing lines -- but only up to the LIVE
    # window height. After a height SHRINK the old frame's tail rows are now off-screen; positioning to
    # them throws and a naive 'break' would leave them as garbage. Clamping the upper bound to the live
    # window height means we only clear rows that are actually still on screen (the off-screen ones are
    # handled by the resize-detection full Clear in the TUI loop).
    if (-not $ForceFull -and $arr.Count -lt $script:LastFrame.Count) {
        $liveH = $script:LastFrame.Count
        try { $liveH = [Console]::WindowHeight } catch { }
        $hi = [math]::Min($script:LastFrame.Count, $liveH)
        for ($i = $arr.Count; $i -lt $hi; $i++) {
            try { [Console]::SetCursorPosition(0, $i); Write-Host -Object (' ' * $padTo) -NoNewline } catch { continue }
        }
    }

    $script:LastFrame = $arr
}

function Reset-PaintBuffer {
    $script:LastFrame = @()
    try { [Console]::Clear() } catch { }
}

function Show-StatusOverlay {
    <#
        Quick single-line status painted on the LIVE bottom row, then force a full repaint next frame.
        The bottom row is re-derived from the live WindowHeight (not a passed-in, possibly-stale value)
        so a resize between the last frame and this overlay cannot strand the bar on the wrong row.
        $Height is accepted for call-site compatibility but only used as a fallback.
    #>
    param([string]$Text, [int]$Height = 0)
    $h = $Height; try { $h = [Console]::WindowHeight } catch { }
    if ($h -lt 1) { $h = if ($Height -gt 0) { $Height } else { 1 } }
    $row = $h - 1
    if ($row -lt 0) { $row = 0 }
    try {
        [Console]::SetCursorPosition(0, $row)
        $w = 80; try { $w = [Console]::WindowWidth } catch { $w = 80 }
        $padTo = $w - 1; if ($padTo -lt 1) { $padTo = 1 }
        $t = (' ' + $Text)
        if ($t.Length -gt $padTo) { $t = $t.Substring(0,$padTo) } else { $t = $t.PadRight($padTo) }
        Write-Host -Object $t -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        try { [Console]::ResetColor() } catch { }
    } catch { }
    # Force a full repaint next frame (do NOT Clear here -- that would erase the overlay before it is
    # read). The caller forces a Reset-PaintBuffer (Clear) AFTER any key acknowledging the overlay.
    $script:LastFrame = @()
}


# ----------------------------------------------------------------------------------------------------
# 2d. DELETE -- Recycle Bin default; permanent optional. Guardrails + reparse re-check + revalidate.
# ----------------------------------------------------------------------------------------------------

function Remove-EntrySafely {
    <#
        Delete $FullPath. Default = Recycle Bin (reversible) via Microsoft.VisualBasic.FileIO.FileSystem.
        -Permanent for an irreversible delete. Honors guardrails, refuses reparse points, and re-validates
        existence immediately before deleting. Returns @{ Ok=$bool; Message=string }.

        SAFER-BY-DEFAULT when Microsoft.VisualBasic cannot load: rather than silently hard-deleting, the
        function REFUSES unless -ForceHard is explicitly set. The TUI never sets -ForceHard, so a missing
        VisualBasic assembly can never turn an interactive delete (even a Shift+D permanent one) into an
        unconfirmed Remove-Item -Recurse -Force.
    #>
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [bool]$IsDir,
        [switch]$Permanent,
        [switch]$ForceHard
    )

    # 1. Guardrails.
    $reason = Get-ProtectedReason -FullPath $FullPath
    if ($reason) { return @{ Ok=$false; Message="Refused: $FullPath is $reason." } }

    # 2. Must still exist, must not be a reparse point (re-check against the live item).
    if (-not (Test-Path -LiteralPath $FullPath)) {
        return @{ Ok=$false; Message="Gone already (nothing to delete): $FullPath" }
    }
    $live = $null
    try { $live = Get-Item -LiteralPath $FullPath -Force -ErrorAction Stop } catch {
        return @{ Ok=$false; Message=("Cannot access: " + $_.Exception.Message) }
    }
    if (Test-IsReparsePoint $live) {
        return @{ Ok=$false; Message="Refused: $FullPath is a reparse point (junction/symlink); its target must not be deleted." }
    }
    $IsDir = [bool]$live.PSIsContainer

    # 3. Need Microsoft.VisualBasic for the Recycle Bin.
    if (-not (Ensure-VisualBasic)) {
        if ($Permanent -and $ForceHard) {
            try {
                Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction Stop
                return @{ Ok=$true; Message="Permanently deleted (VB unavailable, -ForceHard): $FullPath" }
            } catch {
                return @{ Ok=$false; Message=("Delete failed: " + $_.Exception.Message) }
            }
        }
        # Refuse rather than silently bypass the Recycle Bin with an irreversible hard delete.
        return @{ Ok=$false; Message="Recycle Bin unavailable (Microsoft.VisualBasic failed to load); refusing to hard-delete." }
    }

    if ($Permanent) {
        $recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::DeletePermanently
    } else {
        $recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    }
    $cancel = [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
    $uiopt  = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs

    try {
        if ($IsDir) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($FullPath, $uiopt, $recycle, $cancel)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($FullPath, $uiopt, $recycle, $cancel)
        }
        if ($Permanent) { return @{ Ok=$true; Message="Permanently deleted -> $FullPath" } }
        return @{ Ok=$true; Message="Sent to Recycle Bin -> $FullPath" }
    } catch {
        return @{ Ok=$false; Message=("Delete failed: " + $_.Exception.Message) }
    }
}


# ====================================================================================================
# 3. NON-INTERACTIVE DUMP  (shares Get-CachedLevel / Get-EntryClass / Format-Size with the TUI)
# ====================================================================================================

function Invoke-DumpLevel {
    <# Recursive helper for Invoke-Dump. Emits classified, indented, size-sorted lines via Write-Host. #>
    param([string]$DirPath, [int]$Depth, [int]$MaxDepth, [bool]$IncludeFiles)

    $level = Get-CachedLevel -DirPath $DirPath
    # Total is the INVARIANT directory total (dirs + files); percentages stay correct even when files
    # are hidden. We only filter which ROWS are printed.
    $total = $level.Total
    $entries = @(Select-VisibleEntries -Entries $level.Entries -IncludeFiles $IncludeFiles)

    foreach ($e in $entries) {
        $indent = ('  ' * ($Depth + 1))
        $sizeStr = (Format-Size -Bytes $e.Bytes -Width 10)
        if ($total -gt 0) { $frac = $e.Bytes / $total } else { $frac = 0 }
        $pct = (Format-Percent -Fraction $frac)
        if ($e.IsReparse) { $marker = '@' } elseif ($e.IsDir) { $marker = '/' } else { $marker = ' ' }
        $line = ("{0} {1} {2}{3}{4}  [{5}]" -f $sizeStr, $pct, $indent, $marker, $e.Name, $e.Class.Tag)
        $col = 'Gray'
        try { $null = [System.ConsoleColor]$e.Class.Color; $col = $e.Class.Color } catch { $col = 'Gray' }
        Write-Host $line -ForegroundColor $col

        if ($e.IsDir -and (-not $e.IsReparse) -and (($Depth + 1) -lt $MaxDepth)) {
            Invoke-DumpLevel -DirPath $e.FullName -Depth ($Depth + 1) -MaxDepth $MaxDepth -IncludeFiles $IncludeFiles
        }
    }
}

function Invoke-Dump {
    <#
        Print a classified, size-sorted tree of -RootPath to -MaxDepth. Uses the SAME Get-CachedLevel /
        Get-EntryClass / Format-Size code as the TUI. Stdout via Write-Host (colored).
    #>
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [int]$MaxDepth = 2,
        [bool]$IncludeFiles = $true
    )
    if ($MaxDepth -lt 1) { $MaxDepth = 1 }

    $root = Get-CachedLevel -DirPath $RootPath
    Write-Host ''
    Write-Host ("Show-DiskUsage -- classified tree dump (depth $MaxDepth)") -ForegroundColor White
    Write-Host ("Path: $RootPath   Total: " + (Format-Size -Bytes $root.Total -Width 1).Trim())
    Write-Host ("Generated: " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:Inv)) -ForegroundColor DarkGray
    Write-Host ("Legend: / dir   @ reparse(not followed)   [tag] = classification") -ForegroundColor DarkGray
    Write-Host ('-' * 70) -ForegroundColor DarkGray
    Invoke-DumpLevel -DirPath $RootPath -Depth 0 -MaxDepth $MaxDepth -IncludeFiles $IncludeFiles
    Write-Host ''
}


# ====================================================================================================
# 4. INTERACTIVE TUI LOOP
# ====================================================================================================

function Read-ConfirmLine {
    <#
        Paint a confirmation prompt as an overlay on the LIVE bottom row and read a single keypress;
        return the lowercase char typed. Used by the Recycle-Bin (y/N) confirm. The row is re-derived
        from the current WindowHeight so a resize before/while prompting cannot misplace the bar.
    #>
    param([string]$Prompt, [int]$Height = 0)
    $h = $Height; try { $h = [Console]::WindowHeight } catch { }
    if ($h -lt 1) { $h = if ($Height -gt 0) { $Height } else { 1 } }
    $row = $h - 1
    if ($row -lt 0) { $row = 0 }
    try {
        [Console]::SetCursorPosition(0, $row)
        $w = 80; try { $w = [Console]::WindowWidth } catch { $w = 80 }
        $padTo = $w - 1; if ($padTo -lt 1) { $padTo = 1 }
        $t = (' ' + $Prompt)
        if ($t.Length -gt $padTo) { $t = $t.Substring(0,$padTo) } else { $t = $t.PadRight($padTo) }
        Write-Host -Object $t -ForegroundColor Black -BackgroundColor Red -NoNewline
        try { [Console]::ResetColor() } catch { }
    } catch { }
    $key = [Console]::ReadKey($true)
    $script:LastFrame = @()
    return ([string]$key.KeyChar).ToLowerInvariant()
}

function Read-ConfirmWord {
    <#
        Paint a strict prompt that requires typing an exact word (used for permanent delete). Reads a
        full line. Returns the typed string. Restores the paint buffer afterwards. The row is re-derived
        from the current WindowHeight so a resize cannot misplace the prompt.
    #>
    param([string]$Prompt, [int]$Height = 0)
    $h = $Height; try { $h = [Console]::WindowHeight } catch { }
    if ($h -lt 1) { $h = if ($Height -gt 0) { $Height } else { 1 } }
    $row = $h - 1
    if ($row -lt 0) { $row = 0 }
    $typed = ''
    try {
        [Console]::SetCursorPosition(0, $row)
        $w = 80; try { $w = [Console]::WindowWidth } catch { $w = 80 }
        $padTo = $w - 1; if ($padTo -lt 1) { $padTo = 1 }
        $t = (' ' + $Prompt)
        if ($t.Length -gt $padTo) { $t = $t.Substring(0,$padTo) } else { $t = $t.PadRight($padTo) }
        Write-Host -Object $t -ForegroundColor White -BackgroundColor Red -NoNewline
        try { [Console]::ResetColor() } catch { }
        try { [Console]::CursorVisible = $true } catch { }
        $typed = [Console]::ReadLine()
        if ($null -eq $typed) { $typed = '' }
    } catch { $typed = '' }
    finally { try { [Console]::CursorVisible = $false } catch { } }
    $script:LastFrame = @()
    return $typed
}

function Invoke-Tui {
    param([Parameter(Mandatory)][string]$StartPath, [bool]$ShowFilesInit = $false)

    $current   = $StartPath
    $showFiles = $ShowFilesInit
    $selected  = 0
    $top        = 0
    $status     = ''
    $running    = $true

    # Per-path selection memory so navigating restores where you were.
    $selMemory = @{}

    # Resize tracking: when the console W/H changes we must Clear() and full-repaint, else a height
    # shrink leaves stale rows from the taller frame painted as garbage below the new frame.
    $prevH = -1
    $prevW = -1

    # Save console state for finally{} restoration (pitfall #4).
    $prevCursor = $true
    try { $prevCursor = [Console]::CursorVisible } catch { }
    $prevFg = [Console]::ForegroundColor
    $prevBg = [Console]::BackgroundColor

    # Status heartbeat: repaint the bottom row with the directory currently being measured. The
    # per-directory progress callback is THROTTLED (>= ~120 ms apart) so it animates during a long scan
    # without a console write per directory (which would dominate the walk on huge trees).
    $statusCb = {
        param($p)
        Show-StatusOverlay -Text ("Scanning " + $p + " ...")
    }
    $script:LastProgressTick = [DateTime]::MinValue
    $progressCb = {
        param($name)
        if (-not $name) { return }
        $now = [DateTime]::UtcNow
        if (($now - $script:LastProgressTick).TotalMilliseconds -lt 120) { return }
        $script:LastProgressTick = $now
        Show-StatusOverlay -Text ("Scanning ... " + $name + "   (Esc/q to stop)")
    }
    # Cancel check: pressing Esc or 'q' during a slow scan aborts it (returns the partial sizing) so a
    # 100k-entry / very deep level can never freeze the UI with no way out.
    $cancelCb = {
        $hit = $false
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq [System.ConsoleKey]::Escape -or $k.KeyChar -eq 'q' -or $k.KeyChar -eq 'Q') { $hit = $true }
            }
        } catch { }
        $hit
    }

    # Load (or reuse cached) level for a path with status/progress/cancel wired up. Local closure so all
    # navigation paths share one code path.
    $loadLevel = {
        param([string]$p, [switch]$Force)
        Get-CachedLevel -DirPath $p -StatusCallback $statusCb -Progress $progressCb -CancelCheck $cancelCb -Force:$Force
    }

    try {
        try { [Console]::CursorVisible = $false } catch { }
        Reset-PaintBuffer

        $level = & $loadLevel $current
        $needRedraw = $true

        while ($running) {
            # The cache always holds the FULL child set; filter for display only (Total stays invariant).
            $entries = @(Select-VisibleEntries -Entries $level.Entries -IncludeFiles $showFiles)
            $count = @($entries).Count

            $cs = Get-ConsoleSize
            $rows = $cs.H - 6
            if ($rows -lt 1) { $rows = 1 }

            # Detect a resize since last iteration: force a clean full repaint so no stale rows survive.
            if ($cs.H -ne $prevH -or $cs.W -ne $prevW) {
                if ($prevH -ne -1) { Reset-PaintBuffer }   # skip the very first iteration (already cleared)
                $prevH = $cs.H
                $prevW = $cs.W
                $needRedraw = $true
            }

            # Clamp selection.
            if ($count -eq 0) { $selected = 0 }
            else {
                if ($selected -ge $count) { $selected = $count - 1 }
                if ($selected -lt 0)      { $selected = 0 }
            }

            # Keep selection within the visible window (scroll).
            if ($selected -lt $top) { $top = $selected }
            if ($selected -ge ($top + $rows)) { $top = $selected - $rows + 1 }
            if ($top -lt 0) { $top = 0 }
            $maxTop = [math]::Max(0, $count - $rows)
            if ($top -gt $maxTop) { $top = $maxTop }

            # Percent of parent (only if the parent level is already cached).
            $parentTotal = -1
            $parent = Get-ParentPath $current
            if ($parent) {
                $pkey = Get-NormalizedPath $parent
                if ($script:LevelCache.ContainsKey($pkey) -and $script:LevelCache[$pkey].Total -gt 0) {
                    $parentTotal = $script:LevelCache[$pkey].Total
                }
            }

            if ($needRedraw) {
                # Render to the PAINTABLE width ($cs.W = WindowWidth-1), matching Paint-Frame's pad, so
                # full-width chrome bars fill the whole paintable area (no one-cell color gap at the edge).
                $frame = Render-Frame -CurrentPath $current -Entries $entries -Selected $selected `
                    -Top $top -Width $cs.W -Height $cs.H -CurrentTotal $level.Total `
                    -ParentTotal $parentTotal -ShowFiles $showFiles -Status $status
                Paint-Frame -Lines $frame
                $needRedraw = $false
                $status = ''   # status is one-shot
            }

            # --- Read a key (the console buffer, never redirected stdin -- pitfall #3) ---
            $key = $null
            try { $key = [Console]::ReadKey($true) } catch { $running = $false; break }
            $kk = $key.Key
            $ch = $key.KeyChar

            # Decode to an action label first; keep loop flow-control OUTSIDE the switch (pitfall #1).
            $action = 'none'
            if     ($kk -eq [System.ConsoleKey]::UpArrow)    { $action = 'up' }
            elseif ($kk -eq [System.ConsoleKey]::DownArrow)  { $action = 'down' }
            elseif ($kk -eq [System.ConsoleKey]::RightArrow) { $action = 'enter' }
            elseif ($kk -eq [System.ConsoleKey]::Enter)      { $action = 'enter' }
            elseif ($kk -eq [System.ConsoleKey]::LeftArrow)  { $action = 'back' }
            elseif ($kk -eq [System.ConsoleKey]::Backspace)  { $action = 'back' }
            elseif ($kk -eq [System.ConsoleKey]::Home)       { $action = 'home' }
            elseif ($kk -eq [System.ConsoleKey]::End)        { $action = 'end' }
            elseif ($kk -eq [System.ConsoleKey]::PageUp)     { $action = 'pageup' }
            elseif ($kk -eq [System.ConsoleKey]::PageDown)   { $action = 'pagedown' }
            elseif ($kk -eq [System.ConsoleKey]::Escape)     { $action = 'quit' }
            elseif ($ch -eq 'q' -or $ch -eq 'Q')             { $action = 'quit' }
            elseif ($ch -eq 'd' -or $ch -eq 'D') {
                # CRITICAL safety: distinguish permanent (Shift+D) from reversible (d) by the SHIFT
                # MODIFIER BIT, never by KeyChar case. `-eq` is case-insensitive, so a case test would
                # route plain 'd' to the permanent branch; and Caps Lock flips KeyChar case independently
                # of Shift, which would silently invert the safe Recycle-Bin default. The modifier bit is
                # the only reliable signal: Shift held => permanent; otherwise => Recycle Bin.
                if (($key.Modifiers -band [System.ConsoleModifiers]::Shift) -ne 0) { $action = 'delperm' }
                else { $action = 'delete' }
            }
            elseif ($ch -eq 'r' -or $ch -eq 'R')             { $action = 'rescan' }
            elseif ($ch -eq 'g' -or $ch -eq 'G')             { $action = 'togglefiles' }
            elseif ($ch -eq 'h' -or $ch -eq 'H' -or $ch -eq '?') { $action = 'help' }

            switch ($action) {
                'up'       { if ($selected -gt 0) { $selected-- }; $needRedraw = $true }
                'down'     { if ($selected -lt ($count - 1)) { $selected++ }; $needRedraw = $true }
                'home'     { $selected = 0; $top = 0; $needRedraw = $true }
                'end'      { $selected = [math]::Max(0, $count - 1); $needRedraw = $true }

                'pageup' {
                    # True page scroll: move the viewport and the cursor together (ncdu feel), then let
                    # the clamp at the top of the loop reconcile $top.
                    $top = [math]::Max(0, $top - $rows)
                    $selected = [math]::Max(0, $selected - $rows)
                    $needRedraw = $true
                }
                'pagedown' {
                    $maxTopNow = [math]::Max(0, $count - $rows)
                    $top = [math]::Min($maxTopNow, $top + $rows)
                    $selected = [math]::Min([math]::Max(0, $count - 1), $selected + $rows)
                    $needRedraw = $true
                }

                'togglefiles' {
                    # File visibility is a DISPLAY concern only: re-filter the already-cached full entry
                    # set. No rescan, no Measure-DirBytes, and the directory Total is unchanged.
                    $showFiles = -not $showFiles
                    $selected = 0; $top = 0
                    $status = "Files: $(if ($showFiles) {'shown'} else {'hidden'})"
                    $needRedraw = $true
                }

                'rescan' {
                    Invalidate-CacheUp -FromPath $current
                    Invalidate-CacheDown -FromPath $current
                    $level = & $loadLevel $current -Force
                    $selected = 0; $top = 0
                    $status = 'Rescanned.'
                    $needRedraw = $true
                }

                'help' {
                    Reset-PaintBuffer
                    Paint-Frame -Lines (Get-HelpLines) -ForceFull
                    try { [void][Console]::ReadKey($true) } catch { }
                    Reset-PaintBuffer
                    $needRedraw = $true
                }

                'enter' {
                    if ($count -gt 0 -and $selected -lt $count) {
                        $sel = $entries[$selected]
                        if ($sel.IsReparse) {
                            $status = 'Reparse point -- not entered (junction/symlink).'
                        } elseif ($sel.IsDir) {
                            $selMemory[(Get-NormalizedPath $current)] = $selected
                            $current = $sel.FullName
                            $level = & $loadLevel $current
                            $rk = Get-NormalizedPath $current
                            $selected = $(if ($selMemory.ContainsKey($rk)) { [int]$selMemory[$rk] } else { 0 })
                            $top = 0
                        } else {
                            $status = 'That is a file, not a folder.'
                        }
                    }
                    $needRedraw = $true
                }

                'back' {
                    $parentPath = Get-ParentPath $current
                    if ($null -eq $parentPath) {
                        $status = 'Already at the drive root -- cannot go up.'
                    } else {
                        $childKey = Get-NormalizedPath $current
                        $selMemory[$childKey] = $selected
                        $current = $parentPath
                        $level = & $loadLevel $current
                        $rk = Get-NormalizedPath $current
                        if ($selMemory.ContainsKey($rk)) {
                            $selected = [int]$selMemory[$rk]
                        } else {
                            # Re-select the child we came from.
                            $selected = 0
                            for ($x = 0; $x -lt $level.Entries.Count; $x++) {
                                if ((Get-NormalizedPath $level.Entries[$x].FullName) -eq $childKey) { $selected = $x; break }
                            }
                        }
                        $top = 0
                    }
                    $needRedraw = $true
                }

                default { }   # 'delete','delperm','quit','none' handled below (need IO / clean flow)
            }

            if ($action -eq 'quit') { $running = $false; continue }

            if (($action -eq 'delete' -or $action -eq 'delperm') -and $count -gt 0 -and $selected -lt $count) {
                $sel = $entries[$selected]
                $permanent = ($action -eq 'delperm')

                $reason = Get-ProtectedReason -FullPath $sel.FullName
                if ($reason) {
                    Show-StatusOverlay -Text ("PROTECTED: cannot delete " + $sel.Name + " (" + $reason + "). Any key.")
                    try { [void][Console]::ReadKey($true) } catch { }
                    Reset-PaintBuffer
                    $needRedraw = $true
                } elseif ($sel.IsReparse) {
                    Show-StatusOverlay -Text ("REFUSED: " + $sel.Name + " is a reparse point. Any key.")
                    try { [void][Console]::ReadKey($true) } catch { }
                    Reset-PaintBuffer
                    $needRedraw = $true
                } else {
                    $szStr = (Format-Size -Bytes $sel.Bytes -Width 1).Trim()
                    $proceed = $false
                    if ($permanent) {
                        # Stricter: require typing the exact word DELETE (case-sensitive -ceq).
                        $typed = Read-ConfirmWord -Prompt ("PERMANENTLY DELETE '" + $sel.Name + "' [" + $sel.Class.Tag + "] " + $szStr + "? Type DELETE to confirm: ")
                        if ($typed -ceq 'DELETE') { $proceed = $true }
                    } else {
                        $ans = Read-ConfirmLine -Prompt ("Recycle '" + $sel.Name + "' [" + $sel.Class.Tag + "] " + $szStr + "?  " + $sel.FullName + "  [y/N]")
                        if ($ans -eq 'y') { $proceed = $true }
                    }

                    if ($proceed) {
                        Show-StatusOverlay -Text ("Deleting " + $sel.Name + " ...")
                        $res = Remove-EntrySafely -FullPath $sel.FullName -IsDir $sel.IsDir -Permanent:$permanent
                        if ($res.Ok) {
                            # Update the in-memory model: drop the entry from the FULL cached child set
                            # (NOT the filtered display set -- otherwise hidden files would be lost),
                            # recompute the invariant total, invalidate ancestor + descendant caches,
                            # re-pin the current level, then fix the selection index against the new
                            # VISIBLE count.
                            $selKey = Get-NormalizedPath $sel.FullName
                            $remaining = New-Object System.Collections.Generic.List[object]
                            foreach ($e in $level.Entries) {
                                if ((Get-NormalizedPath $e.FullName) -ne $selKey) { $remaining.Add($e) }
                            }
                            $newEntries = @($remaining.ToArray())
                            $newTotal = [double]0
                            foreach ($e in $newEntries) { $newTotal += [double]$e.Bytes }
                            $level = @{ Entries = $newEntries; Total = $newTotal }

                            # Ancestors' totals changed; the deleted subtree's caches/memo must not linger.
                            $par = Get-ParentPath $current
                            if ($par) { Invalidate-CacheUp -FromPath $par }
                            Invalidate-CacheDown -FromPath $sel.FullName
                            if ($script:SizeMemo.ContainsKey($selKey)) { [void]$script:SizeMemo.Remove($selKey) }
                            $script:LevelCache[(Get-NormalizedPath $current)] = $level

                            $visCount = @(Select-VisibleEntries -Entries $newEntries -IncludeFiles $showFiles).Count
                            if ($selected -ge $visCount) { $selected = [math]::Max(0, $visCount - 1) }
                            $status = $res.Message
                        } else {
                            Show-StatusOverlay -Text ($res.Message + "  (any key)")
                            try { [void][Console]::ReadKey($true) } catch { }
                            Reset-PaintBuffer
                        }
                    } else {
                        $status = 'Delete cancelled.'
                    }
                    $needRedraw = $true
                }
            }
        }
    }
    finally {
        # RESTORE everything (pitfall #4): colors, cursor, clear TUI state.
        try { [Console]::ResetColor() } catch { }
        try { [Console]::ForegroundColor = $prevFg } catch { }
        try { [Console]::BackgroundColor = $prevBg } catch { }
        try { [Console]::CursorVisible = $prevCursor } catch { }
        try {
            $hh = 30; try { $hh = [Console]::WindowHeight } catch { }
            [Console]::SetCursorPosition(0, [math]::Max(0, $hh - 1))
        } catch { }
        Write-Host ''
        $script:LastFrame = @()
    }
}


# ====================================================================================================
# 5. ENTRY POINT
# ====================================================================================================

function Resolve-StartPath {
    param([string]$Requested)
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        $drv = $env:SystemDrive
        if ([string]::IsNullOrWhiteSpace($drv)) { $drv = 'C:' }
        return ($drv.TrimEnd('\') + '\')
    }
    $resolved = $Requested
    try {
        $rp = Resolve-Path -LiteralPath $Requested -ErrorAction Stop
        $resolved = $rp.ProviderPath
    } catch {
        # leave as-is; validated by the caller
    }
    try {
        if (Test-Path -LiteralPath $resolved) {
            $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                return (Split-Path -Parent $item.FullName)   # a file was given: start in its parent
            }
            $resolved = $item.FullName
        }
    } catch { }
    if ($resolved -match '^[A-Za-z]:$') { $resolved = $resolved + '\' }
    return $resolved
}

function Invoke-Main {
    $start = Resolve-StartPath -Requested $Path

    if (-not (Test-Path -LiteralPath $start)) {
        # With $ErrorActionPreference='Stop', Write-Error would terminate before exit; write to stderr.
        [Console]::Error.WriteLine("Show-DiskUsage: path not found: $start")
        exit 2
    }

    if ($MaxDepth -lt 1) { $MaxDepth = 1 }

    # Explicit dump mode.
    if ($Dump) {
        Invoke-Dump -RootPath $start -MaxDepth $MaxDepth -IncludeFiles ([bool]$ShowFiles)
        exit 0
    }

    # Interactive if we can; otherwise the non-interactive fallback dump.
    if (Test-Interactive) {
        try {
            Invoke-Tui -StartPath $start -ShowFilesInit:$ShowFiles.IsPresent
            exit 0
        } catch {
            # Never crash the user out without restoring the console; fall back to a dump.
            try { [Console]::ResetColor() } catch { }
            try { [Console]::CursorVisible = $true } catch { }
            Write-Warning ("Interactive mode failed (" + $_.Exception.Message + "); falling back to dump.")
            Invoke-Dump -RootPath $start -MaxDepth $MaxDepth -IncludeFiles ([bool]$ShowFiles)
            exit 0
        }
    } else {
        Write-Host "Non-interactive console detected -- printing classified tree dump instead." -ForegroundColor DarkYellow
        Invoke-Dump -RootPath $start -MaxDepth $MaxDepth -IncludeFiles ([bool]$ShowFiles)
        exit 0
    }
}

# Only auto-run when executed as a script (so dot-sourcing for tests does not launch the TUI).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}