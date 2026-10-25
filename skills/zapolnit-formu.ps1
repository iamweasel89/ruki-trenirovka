# Generic skill: fill a form by a JSON plan.
# Checks the page, types values with read-back, reconciles the form against the plan
# before every button, presses the final button only on our page.
# Output: JSON with steps, and where it stopped and why.
param(
  [Parameter(Mandatory = $true)][string]$Plan,
  [Parameter(Mandatory = $true)][string]$Vyhod,
  [int]$TimeoutStranicyMs = 25000
)
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
. (Join-Path $koren 'lib\vvod.ps1')

$sw = [Diagnostics.Stopwatch]::StartNew()
Write-RukiLog "start plan=$Plan"
$pl = Get-Content -Raw -Encoding UTF8 $Plan | ConvertFrom-Json
$rez = [ordered]@{ plan = $pl.imya; ok = $false; shagi = @(); ostanovka = $null; pomehi = @{}; stranica = $null; ms = 0 }

function Save-Rez {
  $rez.ms = [int]$sw.ElapsedMilliseconds
  $rez.pomehi = $ctx.Pomehi
  ($rez | ConvertTo-Json -Depth 6) | Out-File -FilePath $Vyhod -Encoding utf8
}
function Stop-Skill($n, $shag, [string]$prichina, [string]$podrobno = '') {
  $rez.ostanovka = [ordered]@{ shag = $n; id = $shag.id; prichina = $prichina; podrobno = $podrobno }
  Write-RukiLog "STOP shag=$n id=$($shag.id) $prichina $podrobno"
  Save-Rez
  exit 0
}

$ctx = @{ Doc = $null; Okno = $null; Hwnd = [IntPtr]::Zero; Plan = $pl; Pomehi = @{}; EstParol = $false }

# 1. page check
$o = Wait-Stranica $pl.stranica $TimeoutStranicyMs
if (-not $o) { $rez.ostanovka = [ordered]@{ shag = 0; prichina = 'net-stranicy' }; Save-Rez; exit 0 }
$ctx.Doc = $o.Doc; $ctx.Okno = $o.Okno; $ctx.Hwnd = $o.Hwnd
$rez.stranica = [ordered]@{ po_url = $o.PoUrl }
$v = Confirm-OknoVidimo $ctx.Hwnd
if (-not $v.Ok) { $rez.ostanovka = [ordered]@{ shag = 0; prichina = 'okno-ne-vidno'; podrobno = $v.Bylo }; Save-Rez; exit 0 }

# careful mode if the page has a password field anywhere
function Update-EstParol {
  try {
    $pw = $ctx.Doc.FindFirst($TS::Descendants, (New-PropCond $AE::IsPasswordProperty $true))
    if ($pw) { $ctx.EstParol = $true }
  } catch {}
}
Update-EstParol

function Invoke-Shag($shag) {
  switch ($shag.tip) {
    { $_ -in 'tekst', 'chislo' } { return Set-Tekst $ctx $shag }
    'flazhok' { return Set-Flazhok $ctx $shag }
    default { return @{ Status = 'stop'; Prichina = 'neizvestnyj-tip' } }
  }
}

# reconcile all value steps since the last button against the plan; fix what drifted
function Sync-Forma($polya) {
  for ($prohod = 1; $prohod -le 3; $prohod++) {
    $ispr = 0
    foreach ($p in $polya) {
      $el = Find-Element $ctx.Doc $p.id $p.metka $p.tip 3000
      $val = Get-ZnachenieUstojchivo $el
      $cel = if ($p.tip -eq 'flazhok') { [bool]$p.znachenie } else { ([string]$p.znachenie) -replace "`r`n", "`n" }
      if ($el -and ($val -ceq $cel)) { continue }
      Write-RukiLog "sverka: $($p.id) razoshlos"
      Add-Pomeha $ctx 'sverka-ispravila'
      $ispr++
      $r = Invoke-Shag $p
      if ($r.Status -ne 'ok') { return $r }
    }
    if ($ispr -eq 0) { return @{ Status = 'ok' } }
  }
  return @{ Status = 'stop'; Prichina = 'sverka-ne-soshlas' }
}

function Press-Knopka($n, $shag, $polya) {
  for ($pop = 1; $pop -le 4; $pop++) {
    $s = Sync-Forma $polya
    if ($s.Status -ne 'ok') { return $s }
    $b = Find-Element $ctx.Doc $shag.id $shag.metka 'knopka' 6000
    if (-not $b) { return @{ Status = 'stop'; Prichina = 'net-knopki' } }
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not $b.Current.IsEnabled -and $t.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 150 }
    if (-not $b.Current.IsEnabled) { Write-RukiLog "knopka $($shag.id) neaktivna"; continue }
    if ($shag.final) {
      $ns = Test-NashaStranica $ctx
      $rez.stranica.final_metod = $ns.Metod
      if (-not $ns.Ok) { return @{ Status = 'stop'; Prichina = 'ne-nasha-stranica' } }
    }
    if (Find-Dialog $ctx.Doc) { $null = Close-Dialog $ctx; continue }
    $ok = Confirm-OknoVidimo $ctx.Hwnd
    if ($ok.Bylo) { Add-Pomeha $ctx 'okno' }
    try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    catch { try { $b.SetFocus(); Send-Klavisha 'Enter' } catch {} }
    if (-not $shag.posle) { Start-Sleep -Milliseconds 500; return @{ Status = 'ok'; Popytki = $pop } }
    $p = Find-Element $ctx.Doc $shag.posle.id $shag.posle.metka $shag.posle.tip 6000
    if ($p) { return @{ Status = 'ok'; Popytki = $pop } }
    Write-RukiLog "posle nazhatiya $($shag.id) ne poyavilos $($shag.posle.id)"
  }
  return @{ Status = 'stop'; Prichina = 'knopka-ne-srabotala' }
}

# 2. steps
$polya = @()
$n = 0
foreach ($shag in $pl.shagi) {
  $n++
  $t0 = $sw.ElapsedMilliseconds
  if ($shag.tip -eq 'knopka') { $r = Press-Knopka $n $shag $polya; $polya = @() }
  else {
    Update-EstParol
    $r = Invoke-Shag $shag
    if ($r.Status -eq 'ok') { $polya += $shag }
  }
  $rez.shagi += [ordered]@{ n = $n; tip = $shag.tip; id = $shag.id; status = $r.Status; popytki = $r.Popytki; ms = [int]($sw.ElapsedMilliseconds - $t0) }
  if ($r.Status -ne 'ok') { Stop-Skill $n $shag $r.Prichina }
}
$rez.ok = $true
Save-Rez
