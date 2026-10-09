# Cold/warm boot discriminator for the PL330 / SPI defer chain.
#
#   .\spi-pl330-coldwarm.ps1 -Label cold1
#   .\spi-pl330-coldwarm.ps1 -Label warm1 -Reboot
#
# What it does: captures the COM4 console (1500000 baud), then reports whether
# the two PL330 DMA controllers bound or deferred, per BOOT.
#
# Why the console and not ssh: the discriminator line is printed once, ~18s into
# the boot, and a cold boot is off the network for part of it anyway.
#
# Why per-boot: a capture can contain more than one boot, so counting occurrences
# over a whole file silently averages boots together. Boots are split on the TPL
# banner -- the rule AGENTS.md already fixes for counting panics.
#
# The prediction under test (unproven -- this is what the run is for):
#   cold boot -> SGRF/DMAC state at hardware defaults -> PERIPH_ID unreadable -> DEFER
#   warm boot -> whatever the previous boot left behind      -> maybe readable  -> PL330-OK
# If cold and warm both come back DEFER every time, the fault is deterministic and
# the "carried-over state" idea is dead. If the two arms disagree, it survives.
param(
  [Parameter(Mandatory = $true)][string]$Label,
  [switch]$Reboot,
  [int]$Seconds = 75,
  [string]$Board = 'root@192.168.3.8'
)

$ErrorActionPreference = 'Stop'
$logDir = Join-Path $PSScriptRoot '..\log'
$out = Join-Path $logDir "$Label.txt"

# --- trigger a warm reboot, if asked -----------------------------------------
# `reboot` must be detached from the pty or it dies when ssh exits and the board
# never goes down -- which looks exactly like a successful no-op (AGENTS.md).
if ($Reboot) {
  Write-Host "rebooting $Board (setsid, detached) ..."
  & ssh -o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=yes $Board `
       'setsid reboot >/dev/null 2>&1 </dev/null &' 2>&1 | Out-Null
  Start-Sleep -Seconds 5
}

# --- capture ------------------------------------------------------------------
$port = New-Object System.IO.Ports.SerialPort 'COM4', 1500000, 'None', 8, 'One'
$port.ReadTimeout = 500
try { $port.Open() }
catch { throw "Cannot open COM4 -- close MobaXterm's serial session first. ($($_.Exception.Message))" }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$sb = New-Object System.Text.StringBuilder
try {
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    try { $chunk = $port.ReadExisting(); if ($chunk) { [void]$sb.Append($chunk) } } catch {}
    Start-Sleep -Milliseconds 200
  }
}
finally { $port.Close(); $port.Dispose() }

$text = $sb.ToString()
Set-Content -LiteralPath $out -Value $text -NoNewline
Write-Host ("captured {0} bytes -> {1}" -f $text.Length, $out)

# --- classify ----------------------------------------------------------------
$lines = $text -split "`r?`n"
$starts = @()
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'U-Boot TPL') { $starts += $i } }

if ($starts.Count -eq 0) {
  Write-Host "NO TPL BANNER -- the board produced nothing. Is it powered on? Is COM4 the right port?"
  exit 1
}

Write-Host ""
Write-Host ("{0}: {1} boot(s)" -f $Label, $starts.Count)
$verdict = 'UNKNOWN'
for ($b = 0; $b -lt $starts.Count; $b++) {
  $from = $starts[$b]
  $to   = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $lines.Count }
  $boot = $lines[$from..($to - 1)]

  $ok    = @($boot | Select-String 'Loaded driver for PL330').Count
  $defer = @($boot | Select-String 'deferred probe pending').Count
  $v = if ($ok -gt 0) { 'PL330-OK' } elseif ($defer -gt 0) { 'DEFER' } else { 'UNKNOWN' }
  $verdict = $v

  Write-Host ("  boot{0}  {1,-8} pl330_ok={2} deferred={3}" -f ($b + 1), $v, $ok, $defer)
  $boot | Select-String 'Loaded driver for PL330|deferred probe pending' |
    ForEach-Object { Write-Host ("      | " + ($_.Line -replace '\s+', ' ')) }
}

Write-Host ""
Write-Host "SUMMARY $Label = $verdict"