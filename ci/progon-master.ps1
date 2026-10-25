# Training job for LONG MULTI-STEP WIZARDS.
# Each run: the skill goes through a wizard by its plan under page disturbances (modal, focus,
# re-render, delays, drifting drafts, lost drafts on Back, a transient failure on Next) and
# window disturbances; it must stop BEFORE the final button with a description and a ticket.
# The harness checks nothing was sent yet, then presses the final button by a separate command
# that carries the ticket, and compares what the page received with the plan and with the
# description the skill gave.
param([int]$Seed = 1, [int]$Progonov = 6, [string]$Vyhod = 'rezultat.json', [string]$Plany = '', [string]$Pomehi = 'zaderzhka,modal,fokus,pererisovka,iskazhenie,chernovik,sboj')
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$spisok = if ($Plany) { @($Plany -split ',') } else { @(Get-ChildItem (Join-Path $koren 'plans\master') -Filter *.json | Sort-Object Name | ForEach-Object { $_.BaseName }) }
$vse = @()
$damp = $null
$jobSw = [Diagnostics.Stopwatch]::StartNew()
$vyhodPut = if ([IO.Path]::IsPathRooted($Vyhod)) { $Vyhod } else { Join-Path (Get-Location).Path $Vyhod }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$metkaItoga = [regex]::Unescape('\u0418\u0442\u043e\u0433')
function Save-Itog([string]$oshibka = '') {
  $itog = [ordered]@{ seed = $Seed; sekund = [int]$jobSw.Elapsed.TotalSeconds; progony = @($vse); damp = $damp; oshibka = $oshibka }
  try { $json = $itog | ConvertTo-Json -Depth 12 -ErrorAction Stop }
  catch { $json = (@{ seed = $Seed; progony = @(); oshibka = ('json: ' + $_.Exception.Message) } | ConvertTo-Json) }
  [IO.File]::WriteAllText($vyhodPut, $json, $utf8)
}
Save-Itog 'start'

function Stop-Lishnee {
  Get-Process chrome, notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

# one skill call in its own process with a hard time limit
function Invoke-Skill([string]$planPut, [string]$out, [string]$extra, [int]$limitMs) {
  Remove-Item $out -ErrorAction SilentlyContinue
  $sk = [Diagnostics.Stopwatch]::StartNew()
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Plan "{1}" -Vyhod "{2}" {3}' -f (Join-Path $koren 'skills\projti-master.ps1'), $planPut, $out, $extra)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
    $pr = [Diagnostics.Process]::Start($psi)
    $errTask = $pr.StandardError.ReadToEndAsync()
    $vovremya = $pr.WaitForExit($limitMs)
    if (-not $vovremya) { Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue }
    $errTxt = if ($errTask.Wait(3000)) { [string]$errTask.Result } else { '' }
    $info = "kod=$(if ($vovremya) { $pr.ExitCode } else { 'timeout' }) ms=$($sk.ElapsedMilliseconds) est_vyhod=$(Test-Path $out)"
  } catch { $info = 'zapusk: ' + $_.Exception.Message; $errTxt = '' }
  $res = $null
  if (Test-Path $out) { try { $res = Get-Content -Raw -Encoding UTF8 $out | ConvertFrom-Json } catch { $info += ' vyhod-ne-json' } }
  return @{ Rez = $res; Info = $info; Err = $errTxt }
}

function Get-Itog($o, [int]$ms) {
  if (-not $o) { return $null }
  $it = Find-Element $o.Doc 'itog' $metkaItoga 'tekst' $ms
  $txt = Get-Znachenie $it
  if (-not $txt) { return $null }
  try { return ($txt | ConvertFrom-Json) } catch { return @{ ne_json = $true } }
}

function ConvertTo-Sravnimoe($x) { if ($x -is [bool]) { return $x } if ($null -eq $x) { return $null } return ([string]$x) -replace "`r`n", "`n" }

for ($r = 0; $r -lt $Progonov; $r++) {
  $imya = $spisok[($Seed + $r) % $spisok.Count]
  $s = 70000 + $Seed * 1000 + $r
  $planPut = Join-Path $koren "plans\master\$imya.json"
  $pl = Get-Content -Raw -Encoding UTF8 $planPut | ConvertFrom-Json
  $stranicaPut = (Join-Path $koren ("polygon\" + ($pl.stranica.url_soderzhit -replace '^.*/', ''))) -replace '\\', '/'
  $url = "file:///$stranicaPut`?seed=$s&pomehi=$Pomehi"
  Stop-Lishnee
  $prof = Join-Path $tmp "cprof_$s"
  $arg = @('--new-window', "--user-data-dir=$prof", '--no-first-run', '--no-default-browser-check',
           '--force-renderer-accessibility', '--disable-features=Translate', '--start-maximized', $url)
  $null = Start-Process $chrome -ArgumentList $arg -PassThru
  $rnd = New-Object Random($s)
  $oknoPomeha = ($rnd.Next(0, 3) -eq 0)
  $job = $null
  if ($oknoPomeha) {
    $cherez = $rnd.Next(4, 40)
    $job = Start-Job -ScriptBlock { param($c) Start-Sleep -Seconds $c; Start-Process notepad } -ArgumentList $cherez
  }
  $log = Join-Path $tmp "log_$s.txt"
  $env:RUKI_LOG = $log
  Remove-Item $log -ErrorAction SilentlyContinue

  # 1. up to the final button
  $a = Invoke-Skill $planPut (Join-Path $tmp "skill_$s.json") '-Rezhim do-finala' 300000
  $sk1 = $a.Rez
  $o = Wait-Stranica $pl.stranica 5000
  if (-not $damp -and $o -and $r -eq 0) { $damp = (Get-DampDereva $o.Doc 0 8) -join "`n" }
  # nothing may be sent before the ticket
  $rano = Get-Itog $o 1500
  # 2. the final button by a separate command with the ticket
  $sk2 = $null; $b = $null
  if ($sk1 -and $sk1.gotovo_k_otpravke -and $sk1.bilet -and -not $rano) {
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue }
    $b = Invoke-Skill $planPut (Join-Path $tmp "skill2_$s.json") ('-Rezhim otpravka -Bilet ' + $sk1.bilet) 90000
    $sk2 = $b.Rez
  }
  $o = Wait-Stranica $pl.stranica 5000
  $poluch = if ($rano) { $rano } else { Get-Itog $o 6000 }

  # 3. independent check
  $prov = [ordered]@{ uspeh = $false; lozhnyj_uspeh = $false; prichina = ''; rano_otpravleno = [bool]$rano; tochnost_itoga = $null; polej_v_itoge = 0; sovpalo_v_itoge = 0; otpravok = $null; pomehi_stranicy = @() }
  $zhdat = $pl.proverka.ozhidaetsya_ostanovka
  $skazalGotovo = [bool]($sk1 -and $sk1.gotovo_k_otpravke)
  if ($zhdat) {
    $stopOk = $sk1 -and $sk1.ostanovka -and $sk1.ostanovka.prichina -eq $zhdat
    $prov.uspeh = [bool]($stopOk -and -not $poluch -and -not $skazalGotovo)
    $prov.lozhnyj_uspeh = [bool]($skazalGotovo -or $poluch)
    $prov.prichina = "ostanovka=$($sk1.ostanovka.prichina) otpravleno=$([bool]$poluch)"
  } elseif (-not $poluch) {
    $prov.prichina = if ($rano) { 'rano' } elseif (-not $skazalGotovo) { 'skill-ne-doshel' } elseif (-not $sk2) { 'net-otpravki' } else { "otpravka: $($sk2.ostanovka.prichina)" }
  } elseif ($poluch.ne_json) { $prov.prichina = 'itog-ne-json'
  } else {
    $prov.pomehi_stranicy = @($poluch.pomehi)
    $prov.otpravok = $poluch.otpravok
    $d = $poluch.dannye
    $ozh = $pl.proverka.dannye
    $rash = @()
    $klyuchi = @($ozh.PSObject.Properties.Name)
    foreach ($k in $klyuchi) { if (-not ((ConvertTo-Sravnimoe $d.$k) -ceq (ConvertTo-Sravnimoe $ozh.$k))) { $rash += $k } }
    foreach ($k in @($d.PSObject.Properties.Name)) { if ($klyuchi -notcontains $k) { $rash += "lishnee:$k" } }
    # the description the skill gave against what was actually received
    $polya = @(); if ($sk1 -and $sk1.itog) { $polya = @($sk1.itog.polya) }
    $sovp = 0
    foreach ($p in $polya) { if ((ConvertTo-Sravnimoe $d.($p.id)) -ceq (ConvertTo-Sravnimoe $p.znachenie)) { $sovp++ } }
    $vsegoPolej = [Math]::Max($polya.Count, @($d.PSObject.Properties.Name).Count)
    $prov.polej_v_itoge = $polya.Count; $prov.sovpalo_v_itoge = $sovp
    $prov.tochnost_itoga = if ($vsegoPolej) { [Math]::Round($sovp / $vsegoPolej, 3) } else { 0 }
    $prov.uspeh = ($rash.Count -eq 0 -and $poluch.otpravok -eq 1 -and $prov.tochnost_itoga -eq 1)
    $prov.lozhnyj_uspeh = ($skazalGotovo -and $sk2 -and $sk2.otpravleno -and $rash.Count -gt 0)
    $prov.prichina = if ($rash.Count) { 'rashozhdenie: ' + ($rash -join ',') } elseif ($poluch.otpravok -ne 1) { "otpravok=$($poluch.otpravok)" } elseif ($prov.tochnost_itoga -ne 1) { "itog-netochen: $sovp/$vsegoPolej" } else { 'ok' }
  }
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
  $logTail = @(); if (Test-Path $log) { $logTail += @(Get-Content $log -Encoding UTF8 | Select-Object -Last 30 | ForEach-Object { [string]$_ }) }
  $logTail += "ZAPUSK1: $($a.Info)"
  if ($b) { $logTail += "ZAPUSK2: $($b.Info)" }
  foreach ($e in @($a.Err, $(if ($b) { $b.Err } else { '' }))) { if ($e) { $logTail += @(($e -split "`n") | Select-Object -Last 12 | ForEach-Object { [string]$_ }) } }
  $vse += [ordered]@{
    progon = $r; seed = $s; plan = $imya; okno_pomeha = $oknoPomeha
    skill = $sk1; otpravka = $sk2; proverka = $prov; log = $logTail
  }
  Write-Host ("[{0}/{1}] {2} seed={3} uspeh={4} lozhnyj={5} {6} ({7} s)" -f ($r + 1), $Progonov, $imya, $s, $prov.uspeh, $prov.lozhnyj_uspeh, $prov.prichina, [int]$jobSw.Elapsed.TotalSeconds)
  Stop-Lishnee
  Save-Itog 'v-processe'
}
Save-Itog ''
$neudach = @($vse | Where-Object { -not $_.proverka.uspeh }).Count
Write-Host "neudach: $neudach iz $($vse.Count)"
exit 0
