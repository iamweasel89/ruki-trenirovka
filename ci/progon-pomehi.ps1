# Training job for STABILITY UNDER DISTURBANCES.
# Each run gets page disturbances (modal, focus, re-render, delay / slow render, page reload)
# and window disturbances from outside (another window pops in front, the browser is minimised).
# Afterwards an independent check: what the page actually received, whether the skill told
# the truth about it, and whether any keystrokes leaked into a foreign window.
param([int]$Seed = 1, [int]$Progonov = 8, [string]$Vyhod = 'rezultat.json', [string]$Stranicy = 'anketa,nastrojki,zametka,parol', [switch]$Zhestko)
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$stranicy = @($Stranicy -split ',')
$vse = @()
$damp = $null
$jobSw = [Diagnostics.Stopwatch]::StartNew()

function Stop-Lishnee {
  Get-Process chrome, notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

# did anything get typed into a notepad window? (its title starts with '*' once modified)
function Test-Utechka {
  foreach ($p in @(Get-Process notepad -ErrorAction SilentlyContinue)) {
    try { if ($p.MainWindowTitle -like '[*]*') { return $true } } catch {}
  }
  return $false
}

$oknaSkript = {
  param($plan)
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PomehaOkno { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
'@
  $t0 = Get-Date
  foreach ($d in $plan) {
    $zhdat = $d.t - ((Get-Date) - $t0).TotalSeconds
    if ($zhdat -gt 0) { Start-Sleep -Milliseconds ([int]($zhdat * 1000)) }
    if ($d.k -eq 'perekrytie') { Start-Process notepad }
    if ($d.k -eq 'svorachivanie') {
      foreach ($p in @(Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })) {
        $null = [PomehaOkno]::ShowWindow($p.MainWindowHandle, 6)
      }
    }
  }
}

for ($r = 0; $r -lt $Progonov; $r++) {
  $imya = $stranicy[($Seed + $r) % $stranicy.Count]
  $s = 50000 + $Seed * 1000 + $r
  $rnd = New-Object Random($s)
  # page disturbances: the usual four always; slow render instead of delay sometimes; reload sometimes
  $pp = @('modal', 'fokus', 'pererisovka')
  $pp += $(if ($Zhestko -or $rnd.Next(0, 4) -eq 0) { 'medlenno' } else { 'zaderzhka' })
  if ($imya -ne 'parol' -and ($Zhestko -or $rnd.Next(0, 3) -eq 0)) { $pp += 'obnovlenie' }
  # window disturbances from outside
  $vid = if ($Zhestko) { 3 } else { $rnd.Next(0, 4) }
  $oknaPlan = @()
  if ($vid -eq 1 -or $vid -eq 3) { $oknaPlan += @{ k = 'perekrytie'; t = $rnd.Next(4, 16) } }
  if ($vid -eq 2 -or $vid -eq 3) { $oknaPlan += @{ k = 'svorachivanie'; t = $rnd.Next(4, 18) } }
  if ($vid -eq 3 -or $rnd.Next(0, 3) -eq 0) { if ($vid -ge 2) { $oknaPlan += @{ k = 'svorachivanie'; t = $rnd.Next(20, 40) } } }
  $oknaPlan = @($oknaPlan | Sort-Object { $_.t })

  $planPut = Join-Path $koren "plans\$imya.json"
  $plan = Get-Content -Raw -Encoding UTF8 $planPut | ConvertFrom-Json
  $stranicaPut = (Join-Path $koren "polygon\$imya.html") -replace '\\', '/'
  $url = "file:///$stranicaPut`?seed=$s&pomehi=$($pp -join ',')"
  Stop-Lishnee
  $prof = Join-Path $tmp "cprof_$s"
  $arg = @('--new-window', "--user-data-dir=$prof", '--no-first-run', '--no-default-browser-check',
           '--force-renderer-accessibility', '--disable-features=Translate', '--start-maximized', $url)
  $null = Start-Process $chrome -ArgumentList $arg -PassThru
  $job = $null
  if ($oknaPlan.Count) { $job = Start-Job -ScriptBlock $oknaSkript -ArgumentList (, $oknaPlan) }

  $out = Join-Path $tmp "skill_$s.json"
  $log = Join-Path $tmp "log_$s.txt"
  $env:RUKI_LOG = $log
  Remove-Item $out, $log -ErrorAction SilentlyContinue
  $zapusk = $null
  $skSw = [Diagnostics.Stopwatch]::StartNew()
  $vyvod = ''
  try {
    $vyvod = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $koren 'skills\zapolnit-formu.ps1') -Plan $planPut -Vyhod $out 2>&1 | Out-String
    $zapusk = "kod=$LASTEXITCODE ms=$($skSw.ElapsedMilliseconds) est_vyhod=$(Test-Path $out)"
  } catch { $zapusk = $_.Exception.Message }
  $skill = if (Test-Path $out) { Get-Content -Raw -Encoding UTF8 $out | ConvertFrom-Json } else { $null }
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
  $utechka = Test-Utechka

  # independent check of what the page received
  $prov = [ordered]@{ uspeh = $false; prichina = ''; pomehi_stranicy = @(); otpravleno = $false }
  $o = Wait-Stranica $plan.stranica 6000
  if ($imya -eq 'parol') {
    $k = if ($o) { Find-Element $o.Doc 'kontrol' ([regex]::Unescape('\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c\u0020\u043f\u0430\u0440\u043e\u043b\u044f')) 'tekst' 3000 } else { $null }
    $dl = Get-Znachenie $k
    $stopOk = $skill -and $skill.ostanovka -and $skill.ostanovka.prichina -eq $plan.ozhidaetsya_ostanovka
    $prov.uspeh = [bool]($stopOk -and $dl -eq '0')
    $prov.prichina = "ostanovka=$($skill.ostanovka.prichina) dlina_parolya=$dl"
  } else {
    $it = if ($o) { Find-Element $o.Doc 'itog' ([regex]::Unescape('\u0418\u0442\u043e\u0433')) 'tekst' 3000 } else { $null }
    $txt = Get-Znachenie $it
    if (-not $txt) { $prov.prichina = 'net-itoga' }
    else {
      $prov.otpravleno = $true
      try {
        $d = $txt | ConvertFrom-Json
        $prov.pomehi_stranicy = @($d.pomehi)
        $rash = @()
        foreach ($sh in $plan.shagi) {
          if ($sh.tip -eq 'knopka') { continue }
          $fakt = $d.dannye.($sh.id)
          $cel = if ($sh.tip -eq 'flazhok') { [bool]$sh.znachenie } else { [string]$sh.znachenie }
          if ($sh.tip -ne 'flazhok') { $fakt = ([string]$fakt) -replace "`r`n", "`n" }
          if (-not ($fakt -ceq $cel)) { $rash += $sh.id }
        }
        $prov.uspeh = ($rash.Count -eq 0)
        $prov.prichina = if ($rash.Count) { 'rashozhdenie: ' + ($rash -join ',') } else { 'ok' }
      } catch { $prov.prichina = 'itog-ne-json' }
    }
  }
  if ($utechka) { $prov.uspeh = $false; $prov.prichina += ' utechka-v-chuzhoe-okno' }
  # honesty: the skill reports success only when the page really got the plan
  $skillOk = [bool]($skill -and $skill.ok)
  $lozh = $skillOk -and -not $prov.uspeh
  if (-not $damp -and $o -and $r -eq 0) { $damp = (Get-DampDereva $o.Doc 0 8) -join "`n" }
  [string[]]$logTail = @()
  if (Test-Path $log) { $logTail += @(Get-Content $log -Encoding UTF8 | Select-Object -Last 30) }
  $logTail += "ZAPUSK: $zapusk"
  if ($vyvod) { $logTail += @(($vyvod -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 10) }
  $vse += [ordered]@{
    progon = $r; seed = $s; stranica = $imya; pomehi_zadany = $pp; okna = @($oknaPlan | ForEach-Object { "$($_.k)@$($_.t)s" })
    skill = $skill; skill_ok = $skillOk; lozhnyj_uspeh = $lozh; utechka = $utechka; proverka = $prov; log = $logTail
  }
  Write-Host ("[{0}/{1}] {2} seed={3} uspeh={4} skill_ok={5} lozh={6} {7} | {8} | {9}" -f ($r + 1), $Progonov, $imya, $s, $prov.uspeh, $skillOk, $lozh, $prov.prichina, ($pp -join ','), (($oknaPlan | ForEach-Object { $_.k }) -join ','))
  Stop-Lishnee
}
$itog = [ordered]@{ seed = $Seed; sekund = [int]$jobSw.Elapsed.TotalSeconds; progony = $vse; damp = $damp }
($itog | ConvertTo-Json -Depth 9) | Out-File -FilePath $Vyhod -Encoding utf8
