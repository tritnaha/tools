<#
.SYNOPSIS
    Show the biggest sub-folders of one or more paths, by total size.

.DESCRIPTION
    Native PowerShell disk-usage scanner for Windows (PowerShell 5.1+). For each
    -Path it lists the immediate child folders sorted by total recursive size, as
    a clean table. Runs natively on Windows -- no WSL/bash bridge -- and reads
    NTFS directly, which is far faster than 'du' over the WSL /mnt/c (9p) mount.

    This is the saved, parameterized version of the ad-hoc C:\Temp\scan*.ps1
    snippets used to find space hogs on this machine (wsl-crashes, Arma addons,
    Store-app sandboxes, etc.).

.PARAMETER Path
    One or more folders to scan. Default: your user profile ($env:USERPROFILE).
    Quote paths with spaces, e.g. 'C:\Users\charlie\My Games'.

.PARAMETER Top
    Number of largest children to show per path. Default: 15.

.PARAMETER IncludeFiles
    Also include loose top-level files (not just folders), with a Type column.
    Handy for noisy dirs like AppData\Local\Temp.

.EXAMPLE
    .\Get-FolderSizes.ps1
    Scan your profile, show the 15 biggest folders.

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

foreach ($base in $Path) {
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

    if ($IncludeFiles) {
        $rows | Format-Table GB, Type, Name -AutoSize
    } else {
        $rows | Format-Table GB, Name -AutoSize
    }
}
