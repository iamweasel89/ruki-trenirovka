# One training job: several runs of the skill on the practice pages with a disturbance seed.
param([int]$Seed = 1, [int]$Progonov = 8, [string]$Vyhod = 'rezultat.json', [switch]$Strogo)
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$stranicy = @('anketa', 'nastrojki', 'zametka', 'parol')
$vse = @()
$damp = $null
$jobSw = [Diagnostics.Stopwatch]::StartNew()
$vyhodPut = if ([IO.Path]::IsPathRooted($Vyhod)) { $Vyhod } else { Join-Path (Get-Location).Path $Vyhod }
$utf8 = New-Object System.Text.UTF8Encoding($false)
# written after every run, so a crash later still leaves the runs done so far
function Save-Itog([string]$oshibka = '') {
  $itog = [ordered]@{ seed = $Seed; sekund = [int]$jobSw.Elapsed.TotalSeconds; progony = @($vse); damp = $damp; oshibka = $oshibka }
  try { $json = $itog | ConvertTo-Json -Depth 9 -ErrorAction Stop }
  catch {
    $json = (@{ seed = $Seed; progony = @(); oshibka = ('json: ' + $_.Exception.Message) } | ConvertTo-Json)
  }
  [IO.File]::WriteAllText($vyhodPut, $json, $utf8)
}
Save-Itog 'start'

function Stop-Lishnee {
  Get-Process chrome, notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

for ($r = 0; $r -lt $Progonov; $r++) {
  $imya = $stranicy[($Seed + $r) % $stranicy.Count]
  $s = $Seed * 1000 + $r
  $planPut = Join-Path $koren "plans\$imya.json"
  $plan = Get-Content -Raw -Encoding UTF8 $planPut | ConvertFrom-Json
  $stranicaPut = (Join-Path $koren "polygon\$imya.html") -replace '\\', '/'
  $url = "file:///$stranicaPut`?seed=$s"
  Stop-Lishnee
  $prof = Join-Path $tmp "cprof_$s"
  $arg = @('--new-window', "--user-data-dir=$prof", '--no-first-run', '--no-default-browser-check',
           '--force-renderer-accessibility', '--disable-features=Translate', '--start-maximized', $url)
  $null = Start-Process $chrome -ArgumentList $arg -PassThru
  # window disturbance: another window pops in front during the run
  $rnd = New-Object Random($s)
  $oknoPomeha = ($rnd.Next(0, 3) -eq 0)
  $job = $null
  if ($oknoPomeha) {
    $cherez = $rnd.Next(3, 14)
    $job = Start-Job -ScriptBlock { param($c) Start-Sleep -Seconds $c; Start-Process notepad } -ArgumentList $cherez
  }
  $out = Join-Path $tmp "skill_$s.json"
  $log = Join-Path $tmp "log_$s.txt"
  $env:RUKI_LOG = $log
  Remove-Item $out, $log -ErrorAction SilentlyContinue
  $errF = Join-Path $tmp "err_$s.txt"; $soF = Join-Path $tmp "so_$s.txt"
  $zapuskOshibka = $null
  $skSw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $vyvod = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $koren 'skills\zapolnit-formu.ps1') -Plan $planPut -Vyhod $out 2>&1 | Out-String
    $vyvod | Out-File -FilePath $soF -Encoding utf8
    $zapuskOshibka = "kod=$LASTEXITCODE ms=$($skSw.ElapsedMilliseconds) est_vyhod=$(Test-Path $out)"
  } catch { $zapuskOshibka = $_.Exception.Message }
  $skill = if (Test-Path $out) { Get-Content -Raw -Encoding UTF8 $out | ConvertFrom-Json } else { $null }

  # independent check of what the page received
  $prov = [ordered]@{ uspeh = $false; prichina = '' ; pomehi_stranicy = @() }
  $o = Wait-Stranica $plan.stranica 5000
  if ($imya -eq 'parol') {
    $k = if ($o) { Find-Element $o.Doc 'kontrol' ([regex]::Unescape('\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c\u0020\u043f\u0430\u0440\u043e\u043b\u044f')) 'tekst' 3000 } else { $null }
    $dl = Get-Znachenie $k
    $stopOk = $skill -and $skill.ostanovka -and $skill.ostanovka.prichina -eq $plan.ozhidaetsya_ostanovka
    $prov.uspeh = [bool]($stopOk -and $dl -eq '0')
    $prov.prichina = "ostanovka=$($skill.ostanovka.prichina) dlina_parolya=$dl"
  } else {
    $it = if ($o) { Find-Element $o.Doc 'itog' ([regex]::Unescape('\u0418\u0442\u043e\u0433')) 'tekst' 4000 } else { $null }
    $txt = Get-Znachenie $it
    if (-not $txt) { $prov.prichina = 'net-itoga' }
    else {
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
  if (-not $damp -and $o -and $r -eq 0) { $damp = (Get-DampDereva $o.Doc 0 8) -join "`n" }
  if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
  $logTail = @(); if (Test-Path $log) { $logTail += @(Get-Content $log -Encoding UTF8 | Select-Object -Last 25) }
  if ($zapuskOshibka) { $logTail += "ZAPUSK: $zapuskOshibka" }
  foreach ($ff in @($errF, $soF)) { if (Test-Path $ff) { $logTail += @(Get-Content $ff -Encoding UTF8 | Select-Object -Last 15) } }
  $vse += [ordered]@{
    progon = $r; seed = $s; stranica = $imya; okno_pomeha = $oknoPomeha
    skill = $skill; proverka = $prov; log = $logTail
  }
  Write-Host ("[{0}/{1}] {2} seed={3} uspeh={4} {5}" -f ($r + 1), $Progonov, $imya, $s, $prov.uspeh, $prov.prichina)
  Stop-Lishnee
  Save-Itog 'v-processe'
}
Save-Itog ''
$neudach = @($vse | Where-Object { -not $_.proverka.uspeh }).Count
$bezSkilla = @($vse | Where-Object { -not $_.skill }).Count
Write-Host "neudach: $neudach iz $($vse.Count); skill bez rezultata: $bezSkilla"
# a skill failure on the polygon is not a job failure; only a broken harness is
if ($Strogo -and ($bezSkilla -gt 0 -or -not (Test-Path $vyhodPut))) { exit 1 }
exit 0
