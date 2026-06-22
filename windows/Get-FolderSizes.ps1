<#
.SYNOPSIS
    Show the biggest sub-folders of one or more paths, by total size.

.DESCRIPTION
    Native PowerShell disk-usage scanner for Windows (PowerShell 5.1+). For each
    -Path it lists the immediate child folders sorted by total recursive size, as
    a clean table. Runs natively on Windows -- no WSL/bash bridge -- and reads
    NTFS directly, which is far faster than 'du' over the WSL /mnt/c (9p) mount.

    Launched with NO arguments -- including a double-click or right-click ->
    "Run with PowerShell" -- it shows an INTERACTIVE MENU of common scans and
    pauses before exiting (so the window does not flash shut). Pass any flag to
    skip the menu and scan directly (scriptable mode).

    This is the saved, parameterized version of the ad-hoc C:\Temp\scan*.ps1
    snippets used to find space hogs on this machine.

.PARAMETER Path
    One or more folders to scan. Default: your user profile ($env:USERPROFILE).
    Quote paths with spaces, e.g. 'C:\Users\charlie\My Games'.

.PARAMETER Top
    Number of largest children to show per path. Default: 15.

.PARAMETER IncludeFiles
    Also include loose top-level files (not just folders), with a Type column.

.EXAMPLE
    .\Get-FolderSizes.ps1
    No arguments -> interactive menu. This is also what right-click
    "Run with PowerShell" gives you.

.EXAMPLE
    .\Get-FolderSizes.ps1 -Path 'C:\Users\charlie\AppData\Local' -Top 20

.EXAMPLE
    .\Get-FolderSizes.ps1 'C:\','D:\' -Top 25
    Scan two drives.

.EXAMPLE
    .\Get-FolderSizes.ps1 "$env:LOCALAPPDATA\Temp" -IncludeFiles
    Include loose files too.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [string[]] $Path = @($env:USERPROFILE),

    [ValidateRange(1, [int]::MaxValue)]
    [int] $Top = 15,

    [switch] $IncludeFiles
)

# Sum every file under $Dir recursively. -Force includes hidden/system items;
# -ErrorAction SilentlyContinue skips locked/denied ones (they count as 0).
function Get-FolderBytes {
    param([string] $Dir)
    (Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
}

# Scan one or more paths and print a size-sorted table for each. Everything goes
# to the success stream (Write-Output + Format-Table) so it renders in order and
# can still be redirected in scriptable mode.
function Invoke-Scan {
    param(
        [string[]] $Path,
        [int]      $Top = 15,
        [switch]   $IncludeFiles
    )
    foreach ($base in $Path) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        if (-not (Test-Path -LiteralPath $base)) {
            Write-Warning "skipped (not found): $base"
            continue
        }
        $full = (Resolve-Path -LiteralPath $base).Path
        Write-Output ""
        Write-Output "===== $full ====="

        $rows = Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue |
            Where-Object { $IncludeFiles -or $_.PSIsContainer } |
            ForEach-Object {
                if ($_.PSIsContainer) {
                    $bytes = Get-FolderBytes $_.FullName
                    $type  = 'dir'
                } else {
                    $bytes = $_.Length
                    $type  = 'file'
                }
                [PSCustomObject]@{
                    GB   = [math]::Round((($bytes) / 1GB), 2)
                    Type = $type
                    Name = $_.Name
                }
            } |
            Sort-Object GB -Descending |
            Select-Object -First $Top

        if (-not $rows) {
            Write-Output "(nothing readable here)"
            continue
        }
        if ($IncludeFiles) {
            $rows | Format-Table GB, Type, Name -AutoSize
        } else {
            $rows | Format-Table GB, Name -AutoSize
        }
    }
}

# Ask "how many rows?" with a sane default.
function Read-TopN {
    $n = Read-Host "  How many to show [default 15]"
    if ($n -match '^\s*\d+\s*$' -and [int]$n -gt 0) { return [int]$n }
    return 15
}

# Interactive menu shown when the script is launched with no arguments
# (double-click / right-click -> "Run with PowerShell").
function Show-Menu {
    $me = $env:USERPROFILE
    while ($true) {
        Write-Host ""
        Write-Host "  ===== Folder Sizes =====" -ForegroundColor Cyan
        Write-Host "  What would you like to scan?"
        Write-Host ""
        Write-Host "   1.  My user profile      ($me)"
        Write-Host "   2.  Whole C:\ drive"
        Write-Host "   3.  AppData\Local        ($env:LOCALAPPDATA)"
        Write-Host "   4.  Temp folder          (incl. loose files)"
        Write-Host "   5.  A folder I'll type in..."
        Write-Host "   Q.  Quit"
        Write-Host ""
        $choice = (Read-Host "  Choice").Trim().ToUpper()

        # Flow control lives HERE in the while loop -- NOT inside the switch.
        # In PowerShell `continue`/`break` inside a switch target the switch,
        # not the enclosing loop, so the switch below only SELECTS a path.
        if ($choice -eq 'Q') { return }
        if ($choice -eq '')  { continue }

        $scanPath  = $null
        $inclFiles = $false
        switch ($choice) {
            '1' { $scanPath = @($me) }
            '2' { $scanPath = @('C:\') }
            '3' { $scanPath = @($env:LOCALAPPDATA) }
            '4' { $scanPath = @($env:TEMP); $inclFiles = $true }
            '5' {
                $p = (Read-Host "  Full path to scan").Trim().Trim('"')
                if (-not [string]::IsNullOrWhiteSpace($p)) { $scanPath = @($p) }
                else { Write-Host "  (nothing entered)" -ForegroundColor Yellow }
            }
            default { Write-Host "  '$choice' isn't one of the options." -ForegroundColor Yellow }
        }

        # Invalid choice or empty path -> back to the menu.
        if (-not $scanPath) { continue }

        $topN = Read-TopN
        Write-Host "  Scanning... (large folders can take a while)" -ForegroundColor DarkGray
        Invoke-Scan -Path $scanPath -Top $topN -IncludeFiles:$inclFiles | Out-Host

        Write-Host ""
        if ((Read-Host "  Press Enter for the menu, or Q to quit").Trim().ToUpper() -eq 'Q') {
            return
        }
    }
}

# ---- Entry point -----------------------------------------------------------
# No args + an interactive console -> menu (covers right-click "Run with
# PowerShell"). Any flag, or a non-interactive host -> direct scriptable mode.
if ($PSBoundParameters.Count -eq 0 -and [Environment]::UserInteractive) {
    Show-Menu
} else {
    Invoke-Scan -Path $Path -Top $Top -IncludeFiles:$IncludeFiles
}
