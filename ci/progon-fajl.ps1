# Training job for FILE UPLOAD through the system file-open dialog.
# Test files are generated here (PNG by System.Drawing, a text file, a Cyrillic name with a space,
# all in a folder with a space). Each run gets page disturbances (delayed form, the dialog asked
# for late, a deaf first press, slow file reading) and window disturbances from outside
# (another window pops in front, the browser is minimised).
# Afterwards an independent check: what the page actually received (name and size of every file,
# crop saved, form sent), whether the skill told the truth, whether a file dialog was left open,
# and whether keystrokes leaked into a foreign window.
param([int]$Seed = 1, [int]$Progonov = 6, [string]$Vyhod = 'rezultat.json',
      [string]$Plany = 'fajl-foto,fajl-vlozheniya,fajl-zamena,fajl-otmena,fajl-net,fajl-otkaz', [switch]$Zhestko, [switch]$BezPomeh)
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
. (Join-Path $koren 'lib\vvod.ps1')
. (Join-Path $koren 'lib\fajl.ps1')
Add-Type -AssemblyName System.Drawing
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$spisokPlanov = @($Plany -split ',')
$vse = @()
$damp = $null
$jobSw = [Diagnostics.Stopwatch]::StartNew()
$vyhodPut = if ([IO.Path]::IsPathRooted($Vyhod)) { $Vyhod } else { Join-Path (Get-Location).Path $Vyhod }
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Save-Itog([string]$oshibka = '') {
  $itog = [ordered]@{ seed = $Seed; sekund = [int]$jobSw.Elapsed.TotalSeconds; progony = @($vse); damp = $damp; oshibka = $oshibka }
  try { $json = $itog | ConvertTo-Json -Depth 9 -ErrorAction Stop }
  catch { $json = (@{ seed = $Seed; progony = @(); oshibka = ('json: ' + $_.Exception.Message) } | ConvertTo-Json) }
  [IO.File]::WriteAllText($vyhodPut, $json, $utf8)
}
Save-Itog 'start'

# --- test files ---
$papkaFajlov = Join-Path $tmp 'fajly test'
$null = New-Item -ItemType Directory -Force -Path $papkaFajlov
function New-Png([string]$put, [int]$w, [int]$h, [int]$ton) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::FromArgb(255, $ton, 120, 255 - $ton))
  $g.FillEllipse([System.Drawing.Brushes]::White, [int]($w / 4), [int]($h / 4), [int]($w / 2), [int]($h / 2))
  $g.Dispose()
  $bmp.Save($put, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
$imyaRu = [regex]::Unescape('\u0441\u043d\u0438\u043c\u043e\u043a 2.png')
New-Png (Join-Path $papkaFajlov 'foto.png') 320 240 40
New-Png (Join-Path $papkaFajlov $imyaRu) 200 200 200
New-Png (Join-Path $papkaFajlov 'vlozh1.png') 64 48 90
New-Png (Join-Path $papkaFajlov 'vlozh2.png') 96 64 150
New-Png (Join-Path $papkaFajlov 'skan.png') 300 400 10
[IO.File]::WriteAllText((Join-Path $papkaFajlov 'zametka.txt'), "plain text attachment`r`nline two`r`n", $utf8)
Remove-Item -LiteralPath (Join-Path $papkaFajlov 'net-takogo-fajla.png') -ErrorAction SilentlyContinue
$razmery = @{}
foreach ($f in Get-ChildItem -LiteralPath $papkaFajlov -File) { $razmery[$f.Name] = [long]$f.Length }
$env:RUKI_FAJLY = $papkaFajlov
Write-Host ("fajly: {0}" -f (($razmery.Keys | Sort-Object | ForEach-Object { "$_=$($razmery[$_])" }) -join ', '))

function Stop-Lishnee {
  Get-Process chrome, notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}
function Test-Utechka {
  foreach ($p in @(Get-Process notepad -ErrorAction SilentlyContinue)) {
    try { if ($p.MainWindowTitle -like '[*]*') { return $true } } catch {}
  }
  return $false
}
# file dialogs of any browser process, independent of the skill's own window
function Get-OstavlennyeDialogi {
  $res = @()
  foreach ($p in @(Get-Process chrome -ErrorAction SilentlyContinue)) {
    foreach ($h in @([RukiDialog]::Dialogi([uint32]$p.Id))) { if (Test-DialogFajla $h) { $res += $h } }
  }
  return $res
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

# compare one expected file name with what the page holds (name and size)
function Test-FajlStranicy($fakt, $cel) {
  if ($null -eq $cel) { return ($null -eq $fakt) }
  if ($null -eq $fakt) { return $false }
  return ([string]$fakt.imya -ceq [string]$cel) -and ([long]$fakt.razmer -eq [long]$razmery[[string]$cel])
}

for ($r = 0; $r -lt $Progonov; $r++) {
  $imya = $spisokPlanov[($Seed + $r) % $spisokPlanov.Count]
  $s = 70000 + $Seed * 1000 + $r
  $rnd = New-Object Random($s)
  $planPut = Join-Path $koren "plans\$imya.json"
  $plan = Get-Content -Raw -Encoding UTF8 $planPut | ConvertFrom-Json
  $pp = @()
  if (-not $BezPomeh) {
    $pp += $(if ($Zhestko -or $rnd.Next(0, 4) -eq 0) { 'medlenno' } else { 'zaderzhka' })
    foreach ($k in 'dialog-pozzhe', 'gluhaya', 'obrabotka') { if ($Zhestko -or $rnd.Next(0, 2) -eq 0) { $pp += $k } }
  }
  if (-not $pp.Count) { $pp = @('net') }
  $vid = if ($BezPomeh) { 0 } elseif ($Zhestko) { 3 } else { $rnd.Next(0, 4) }
  $oknaPlan = @()
  if ($vid -eq 1 -or $vid -eq 3) { $oknaPlan += @{ k = 'perekrytie'; t = $rnd.Next(3, 14) } }
  if ($vid -eq 2 -or $vid -eq 3) { $oknaPlan += @{ k = 'svorachivanie'; t = $rnd.Next(4, 16) } }
  $oknaPlan = @($oknaPlan | Sort-Object { $_.t })

  $stranicaPut = (Join-Path $koren ('polygon\' + ($plan.stranica.url_soderzhit -replace '^/polygon/', ''))) -replace '\\', '/'
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
  $errTxt = ''
  try {
    # own process with a hard time limit
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Plan "{1}" -Vyhod "{2}"' -f (Join-Path $koren 'skills\zapolnit-formu.ps1'), $planPut, $out
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $pr = [Diagnostics.Process]::Start($psi)
    $errTask = $pr.StandardError.ReadToEndAsync()
    $vovremya = $pr.WaitForExit(150000)
    if (-not $vovremya) { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
    $errTxt = if ($errTask.Wait(3000)) { [string]$errTask.Result } else { '' }
    $zapusk = "kod=$(if ($vovremya) { $pr.ExitCode } else { 'timeout' }) ms=$($skSw.ElapsedMilliseconds) est_vyhod=$(Test-Path $out)"
  } catch { $zapusk = 'zapusk: ' + $_.Exception.Message }
  $skill = $null
  if (Test-Path $out) { try { $skill = Get-Content -Raw -Encoding UTF8 $out | ConvertFrom-Json } catch {} }
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
  $utechka = Test-Utechka

  # independent check
  $prov = [ordered]@{ uspeh = $false; prichina = ''; pomehi_stranicy = @(); otpravleno = $false; dialog_ostavlen = $false; sost = $null }
  $ost = @(Get-OstavlennyeDialogi)
  if ($ost.Count) {
    $prov.dialog_ostavlen = $true
    if (-not $damp) { try { $damp = (Get-DampDereva ($AE::FromHandle($ost[0])) 0 8) -join "`n" } catch {} }
    foreach ($h in $ost) { $null = Close-DialogFajla $h }
  }
  foreach ($w in @(Get-OknaBrauzera)) { if ([RukiOkno]::IsIconic($w.Hwnd)) { $null = [RukiOkno]::ShowWindow($w.Hwnd, 9) } }
  $o = Wait-Stranica $plan.stranica 6000
  $el = if ($o) { Find-Element $o.Doc 'sostoyanie' $null 'tekst' 3000 } else { $null }
  $b64 = Get-Znachenie $el
  $sost = $null
  if ($b64) { try { $sost = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json } catch {} }
  $rash = @()
  if (-not $sost) { $prov.prichina = 'net-sostoyaniya' }
  else {
    $prov.sost = $sost
    $prov.pomehi_stranicy = @($sost.pomehi | Select-Object -Unique)
    $prov.otpravleno = [bool]$sost.otpravleno
    $cel = $plan.proverka_stranicy
    foreach ($pr2 in $cel.PSObject.Properties) {
      $k = $pr2.Name; $v = $pr2.Value
      switch ($k) {
        { $_ -in 'foto', 'skan' } { if (-not (Test-FajlStranicy $sost.$k $v)) { $rash += $k } }
        'vlozheniya' {
          $fakt = @($sost.vlozheniya)
          $ok = ($fakt.Count -eq @($v).Count)
          foreach ($n in @($v)) { if (-not ($fakt | Where-Object { Test-FajlStranicy $_ $n })) { $ok = $false } }
          if (-not $ok) { $rash += $k }
        }
        'otkloneno' { if ((@($sost.otkloneno | Sort-Object) -join '|') -cne (@($v | Sort-Object) -join '|')) { $rash += $k } }
        default { if ([string]$sost.$k -ne [string]$v) { $rash += $k } }
      }
    }
    $prov.uspeh = ($rash.Count -eq 0)
    $prov.prichina = if ($rash.Count) { 'rashozhdenie: ' + ($rash -join ',') } else { 'ok' }
  }
  $ozhStop = $plan.ozhidaetsya_ostanovka
  if ($ozhStop) {
    $stopOk = $skill -and $skill.ostanovka -and $skill.ostanovka.prichina -eq $ozhStop
    if (-not $stopOk) { $prov.uspeh = $false; $prov.prichina += " ostanovka=$($skill.ostanovka.prichina) zhdali=$ozhStop" }
  }
  if ($prov.dialog_ostavlen) { $prov.uspeh = $false; $prov.prichina += ' dialog-ostavlen' }
  if ($utechka) { $prov.uspeh = $false; $prov.prichina += ' utechka-v-chuzhoe-okno' }
  $skillOk = [bool]($skill -and $skill.ok)
  # honesty: the skill reports success only when the page really got the plan
  $lozh = $skillOk -and -not $prov.uspeh
  [string[]]$logTail = @()
  if (Test-Path $log) { $logTail += @(Get-Content $log -Encoding UTF8 | Select-Object -Last 40 | ForEach-Object { [string]$_ }) }
  $logTail += "ZAPUSK: $zapusk"
  if ($errTxt) { $logTail += @(($errTxt -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 8 | ForEach-Object { [string]$_ }) }
  $vse += [ordered]@{
    progon = $r; seed = $s; stranica = $imya; pomehi_zadany = $pp; okna = @($oknaPlan | ForEach-Object { "$($_.k)@$($_.t)s" })
    skill = $skill; skill_ok = $skillOk; lozhnyj_uspeh = $lozh; utechka = $utechka; proverka = $prov; log = $logTail
  }
  Write-Host ("[{0}/{1}] {2} seed={3} uspeh={4} skill_ok={5} lozh={6} {7} | ost={8} | {9} | {10}" -f ($r + 1), $Progonov, $imya, $s, $prov.uspeh, $skillOk, $lozh, $prov.prichina, $skill.ostanovka.prichina, ($pp -join ','), (($oknaPlan | ForEach-Object { $_.k }) -join ','))
  Save-Itog
  Stop-Lishnee
}
Save-Itog
