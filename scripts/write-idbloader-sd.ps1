<#
.SYNOPSIS
    Write a Rockchip idbloader to a removable card at LBA 0x40.

.DESCRIPTION
    Recovers a Radxa ROCK 4B+ whose SPI flash holds a U-Boot that cannot
    initialise DRAM. The RK3399 BootROM looks for the bootloader on SPI
    first, then eMMC, then SD, so a card carrying a good idbloader gives
    the board a way in once the SPI TPL gives up.

    This writes exactly one file to one offset:

        offset  0x8000 (32768 bytes = LBA 0x40)   192512 bytes

    Sector 0 is not touched, so an existing partition table and MBR on the
    card are left intact. Nothing is erased and nothing is formatted.

    Why LBA 0x40 and not 0: that is where the RK3399 boot ROM looks, and it
    is where Armbian puts it. Evidence recorded in docs/flashing.md section 7 --
    the first 8 bytes of this idbloader match the first 8 bytes of the
    Armbian image at that offset byte for byte.

.PARAMETER DiskNumber
    The disk to write to, as shown by Get-Disk. Nothing is guessed: with
    no -DiskNumber this only lists disks and exits.

.PARAMETER ImagePath
    Path to idbloader.img. Defaults to the copy beside this script.

.PARAMETER Offset
    Byte offset to write at. Default 32768 (LBA 0x40).

.EXAMPLE
    # list the disks first, then pick one by size/model
    .\write-idbloader-sd.ps1
    .\write-idbloader-sd.ps1 -DiskNumber 2

.NOTES
    Must run elevated. Writes to a raw device, so it refuses any disk that
    Windows considers a system or boot disk, and asks for confirmation
    before touching anything.
#>

[CmdletBinding()]
param(
    [int]    $DiskNumber = -1,
    [string] $ImagePath,
    [long]    $Offset = 32768,
    [switch] $Preview
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    # WindowsIdentity has no IsInRole; the role check lives on
    # WindowsPrincipal. Building it this way works on both Windows
    # PowerShell 5.1 and PowerShell 7, unlike calling it directly.
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Must run elevated. Reopen PowerShell as Administrator and run this again."
    }
}

function Show-Disks {
    Write-Host ''
    Write-Host '  Num  Size        Bus     Removable  System  Name' -ForegroundColor DarkGray
    Write-Host '  ---  ----------  ------  ---------  ------  ----' -ForegroundColor DarkGray
    foreach ($d in Get-Disk) {
        $sys = if ($d.IsSystem) { 'yes' } else { '-' }
        $sysFg = if ($d.IsSystem -or $d.IsBoot) { 'Red' } else { 'DarkGray' }
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        Write-Host ('  {0,3}  {1,8} GB  {2,-6}  {3,-9}  ' -f `
            $d.Number, $sizeGB, $d.BusType, $d.IsRemovable) `
            -ForegroundColor DarkGray -NoNewline
        Write-Host $sys -ForegroundColor $sysFg -NoNewline
        Write-Host ('  {0}' -f $d.FriendlyName) -ForegroundColor Gray
    }
    Write-Host ''
}

# --- no target named: just show what is there and stop -------------------

if ($DiskNumber -lt 0) {
    Write-Host 'Disks currently attached:' -ForegroundColor Cyan
    Show-Disks
    Write-Host 'Re-run with -DiskNumber <n> for the removable card you want.' -ForegroundColor Cyan
    Write-Host 'Pick by size and model. The system disk is flagged above in red.' -ForegroundColor DarkGray
    exit 0
}

# Elevation is only needed for the write itself, so -Preview can run without
# it. That matters: without a way to run this path read-only, the part of the
# script that touches a real disk cannot be exercised until it is too late.
if (-not $Preview) {
    Assert-Admin
}

# --- locate the image ---------------------------------------------------

if (-not $ImagePath) {
    $ImagePath = Join-Path $PSScriptRoot 'idbloader.img'
}
if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Image not found: $ImagePath`nPass -ImagePath <path-to-idbloader.img>."
}

$image = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ImagePath))
$len = $image.Length

# --- identify the target and refuse the dangerous ones -------------------

$disk = Get-Disk -Number $DiskNumber
if ($null -eq $disk) { throw "Disk $DiskNumber is not present." }

$target = "\\.\PhysicalDrive$DiskNumber"

Write-Host ''
Write-Host "  image   : $ImagePath ($len bytes, sha256 $((Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash.Substring(0,16)))"
Write-Host "  target  : $target"
Write-Host ("  size    : {0} GB" -f [math]::Round($disk.Size / 1GB, 1))
Write-Host "  name    : $($disk.FriendlyName)"
$lba = [long][math]::Floor($Offset / 512)
Write-Host ("  offset  : {0} (0x{1:X})" -f $Offset, $Offset)
Write-Host ("  sector  : {0} / 512 = {1}   (LBA 0x{2:X})" -f $Offset, $lba, $lba)
Write-Host ("  ends at : byte {0}   (sector {1})" -f ($Offset + $len), ($lba + [long]($len / 512)))
Write-Host ''

# A system or boot disk means the disk number was picked wrong.
if ($disk.IsSystem -or $disk.IsBoot) {
    Write-Host '  REFUSING: Windows reports this as a system or boot disk.' -ForegroundColor Red
    Write-Host '  If you believe that is wrong, double-check the disk number.' -ForegroundColor DarkGray
    exit 1
}

if ($Offset % 512 -ne 0) {
    Write-Host "  REFUSING: the offset is not a whole number of 512-byte sectors." -ForegroundColor Red
    Write-Host "            A raw device write has no notion of a partial sector." -ForegroundColor DarkGray
    exit 1
}

if ($Offset + $len -gt $disk.Size) {
    Write-Host '  REFUSING: the image does not fit at that offset on this device.' -ForegroundColor Red
    exit 1
}

# Removable is a hint, not a guarantee. Some USB card readers report
# IsRemovable as false, so this is a warning rather than a gate -- but the
# confirmation prompt below is not optional.
if (-not $disk.IsRemovable) {
    Write-Host '  NOTE: Windows does not think this disk is removable.' -ForegroundColor Yellow
    Write-Host '        That is expected for some USB card readers.' -ForegroundColor DarkGray
    Write-Host ''
}

if ($Preview) {
    Write-Host '  PREVIEW: every check above ran, nothing was written.' -ForegroundColor Cyan
    Write-Host '           Re-run without -Preview to actually write.' -ForegroundColor DarkGray
    exit 0
}

$answer = Read-Host ("  Write $len bytes to $target at offset $Offset ? Type YES to continue")
if ($answer -cne 'YES') {
    Write-Host '  Aborted. Nothing was written.' -ForegroundColor Yellow
    exit 0
}

# --- write --------------------------------------------------------------

$stream = [System.IO.File]::Open($target, 'Open', 'Write')
try {
    [void]$stream.Seek($Offset, 'Begin')
    $stream.Write($image, 0, $len)
    $stream.Flush($true)
} finally {
    $stream.Dispose()
}
Write-Host "  Wrote $len bytes." -ForegroundColor Green

# --- read back and verify ----------------------------------------------

$stream = [System.IO.File]::Open($target, 'Open', 'Read')
try {
    [void]$stream.Seek($Offset, 'Begin')
    $buf = New-Object byte[] $len
    $read = 0
    while ($read -lt $len) {
        $n = $stream.Read($buf, $read, $len - $read)
        if ($n -le 0) { break }
        $read += $n
    }
} finally {
    $stream.Dispose()
}

if ($read -ne $len) {
    Write-Host "  VERIFY FAILED: read back only $read of $len bytes." -ForegroundColor Red
    exit 1
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$got = ($sha.ComputeHash($buf) | ForEach-Object { $_.ToString('x2') }) -join ''
$want = ($sha.ComputeHash($image) | ForEach-Object { $_.ToString('x2') }) -join ''

if ($got -eq $want) {
    Write-Host "  VERIFIED: read-back sha256 matches ($($got.Substring(0,16)) ...)" -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next: insert the card in the board and power on with the serial console attached.' -ForegroundColor Cyan
    Write-Host '  Success looks like an SPL and U-Boot banner after the TPL line.' -ForegroundColor Cyan
    exit 0
}

Write-Host "  VERIFY FAILED" -ForegroundColor Red
Write-Host "    expected $want" -ForegroundColor Red
Write-Host "    got      $got" -ForegroundColor Red
exit 1
