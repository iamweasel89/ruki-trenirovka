# Generic skill: fill a form by a JSON plan.
# Checks the page, types values with read-back, reconciles the form against the plan
# before every button, presses the final button only on our page.
# Output: JSON with steps, and where it stopped and why.
param(
  [Parameter(Mandatory = $true)][string]$Plan,
  [Parameter(Mandatory = $true)][string]$Vyhod,
  [int]$TimeoutStranicyMs = 25000,
  [int]$TerpenieMs = 20000,
  [int]$TishinaMs = 1700,
  [int]$PerezapuskovMaks = 2
)
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
. (Join-Path $koren 'lib\vvod.ps1')
. (Join-Path $koren 'lib\fajl.ps1')

$sw = [Diagnostics.Stopwatch]::StartNew()
Write-RukiLog "start plan=$Plan"
$pl = $null
try { $pl = Get-Content -Raw -Encoding UTF8 -ErrorAction Stop $Plan | ConvertFrom-Json } catch { Write-RukiLog "plan ne prochitan: $($_.Exception.Message)" }
# an unreadable or empty plan is an honest stop, never an empty success
if (-not $pl -or -not $pl.stranica -or -not $pl.stranica.url_soderzhit -or @($pl.shagi).Count -eq 0) {
  ([ordered]@{ plan = $Plan; ok = $false; shagi = @(); ostanovka = [ordered]@{ shag = 0; prichina = 'plan-nekorrekten' }; pomehi = @{}; ms = [int]$sw.ElapsedMilliseconds } | ConvertTo-Json -Depth 4) | Out-File -FilePath $Vyhod -Encoding utf8
  exit 0
}
$rez = [ordered]@{ plan = $pl.imya; ok = $false; shagi = @(); ostanovka = $null; pomehi = @{}; stranica = $null; perezapuskov = 0; ms = 0 }

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

$ctx = @{ Doc = $null; Okno = $null; Hwnd = [IntPtr]::Zero; Url = $null; Plan = $pl; Pomehi = @{}; EstParol = $false
          TerpenieMs = $TerpenieMs; PoslednijVvod = [Environment]::TickCount; NuzhenKlik = $false }

# 1. page check
$o = Wait-Stranica $pl.stranica $TimeoutStranicyMs
if (-not $o) { $rez.ostanovka = [ordered]@{ shag = 0; prichina = 'net-stranicy' }; Save-Rez; exit 0 }
$ctx.Doc = $o.Doc; $ctx.Okno = $o.Okno; $ctx.Hwnd = $o.Hwnd; $ctx.Url = $o.Url
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
    'fajl' { return Invoke-ZagruzkaFajla $ctx $shag }
    default { return @{ Status = 'stop'; Prichina = 'neizvestnyj-tip' } }
  }
}

# reconcile all value steps since the last button against the plan; fix what drifted
function Sync-Forma($polya) {
  for ($prohod = 1; $prohod -le 3; $prohod++) {
    $ispr = 0
    foreach ($p in $polya) {
      $el = Find-Element $ctx.Doc $p.id $p.metka $p.tip 3000
      if (-not $el) { $el = Find-V $ctx $p $p.tip }
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

# wait for quiet since the last input (a late re-render fires within that time),
# then reconcile; repeat until a pass finds nothing to fix
function Sync-Ustojchivo($polya) {
  for ($k = 1; $k -le 4; $k++) {
    $proshlo = [Environment]::TickCount - $ctx.PoslednijVvod
    if ($proshlo -lt $TishinaMs -and $proshlo -ge 0) { Start-Sleep -Milliseconds ($TishinaMs - $proshlo) }
    $do = [int]$ctx.Pomehi['sverka-ispravila']
    $s = Sync-Forma $polya
    if ($s.Status -ne 'ok') { return $s }
    if ([int]$ctx.Pomehi['sverka-ispravila'] -eq $do) { return $s }
  }
  return @{ Status = 'stop'; Prichina = 'forma-ne-ustoyalas' }
}

function Press-Knopka($n, $shag, $polya) {
  for ($pop = 1; $pop -le 4; $pop++) {
    $s = Sync-Ustojchivo $polya
    if ($s.Status -ne 'ok') { return $s }
    $b = Find-V $ctx $shag 'knopka'
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
    if ($shag.final) { $script:finalNazhata = $true }
    try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    catch { try { if (Test-OknoVperedi $ctx.Hwnd) { $b.SetFocus(); Send-Klavisha 'Enter' } } catch {} }
    if (-not $shag.posle) { Start-Sleep -Milliseconds 500; return @{ Status = 'ok'; Popytki = $pop } }
    $p = Find-V $ctx $shag.posle $shag.posle.tip
    if ($p) { return @{ Status = 'ok'; Popytki = $pop } }
    Write-RukiLog "posle nazhatiya $($shag.id) ne poyavilos $($shag.posle.id)"
    # a final button is never pressed twice: no confirmation means an honest stop
    if ($shag.final) { return @{ Status = 'stop'; Prichina = 'net-podtverzhdeniya' } }
  }
  return @{ Status = 'stop'; Prichina = 'knopka-ne-srabotala' }
}

# the page was reloaded or replaced (new document / new URL / new window)?
# if so, take the new context and say so
function Update-Kontekst {
  $o = Wait-Stranica $pl.stranica 8000
  if (-not $o) { return 'net-stranicy' }
  $novyj = (-not (Test-Zhivoj $ctx.Doc)) -or (-not (Test-TotZhe $o.Doc $ctx.Doc)) -or ($o.Hwnd -ne $ctx.Hwnd) -or ($o.Url -and $ctx.Url -and $o.Url -ne $ctx.Url)
  if (-not $novyj) { return 'prezhnij' }
  Write-RukiLog "stranica obnovilas: url=$($o.Url -ne $ctx.Url) hwnd=$($o.Hwnd -ne $ctx.Hwnd)"
  $ctx.Doc = $o.Doc; $ctx.Okno = $o.Okno; $ctx.Hwnd = $o.Hwnd; $ctx.Url = $o.Url
  $ctx.EstParol = $false
  Update-EstParol
  return 'novyj'
}
$vosstanovimye = @('net-elementa', 'ne-sovpalo-posle-popytok', 'flazhok-ne-ustanovlen', 'net-knopki', 'knopka-ne-srabotala', 'sverka-ne-soshlas', 'forma-ne-ustoyalas')

# 2. steps; after a page reload the plan is replayed from the start (values are idempotent),
# but never after the final button was pressed
$script:finalNazhata = $false
$perezapusk = 0
do {
  $snova = $false
  $polya = @()
  $n = 0
  foreach ($shag in $pl.shagi) {
    $n++
    $t0 = $sw.ElapsedMilliseconds
    if ($shag.tip -eq 'knopka') { $r = Press-Knopka $n $shag $polya; $polya = @() }
    else {
      Update-EstParol
      $r = Invoke-Shag $shag
      # a cancelled file dialog is the planned outcome of a cancel step
      $otm = ($r.Status -eq 'otmeneno')
      if ($otm) { $r.Status = 'ok' }
      # file steps are not replayed by the reconciliation (an upload is not idempotent)
      if ($r.Status -eq 'ok' -and $shag.tip -ne 'fajl') { $polya += $shag }
    }
    $zap = [ordered]@{ n = $n; tip = $shag.tip; id = $shag.id; status = $r.Status; popytki = $r.Popytki; ms = [int]($sw.ElapsedMilliseconds - $t0); krug = $perezapusk }
    if ($shag.tip -eq 'fajl') { $zap.fajlov = $r.Fajlov; $zap.otmeneno = [bool]$otm }
    $rez.shagi += $zap
    if ($r.Status -eq 'ok') { continue }
    $podr = if ($r.Podrobno) { [string]$r.Podrobno } else { '' }
    if ($r.Prichina -in $vosstanovimye -and -not $script:finalNazhata) {
      $k = Update-Kontekst
      if ($k -eq 'novyj' -and $perezapusk -lt $PerezapuskovMaks) {
        $perezapusk++; $rez.perezapuskov = $perezapusk
        Add-Pomeha $ctx 'perezagruzka'
        Write-RukiLog "perezapusk plana $perezapusk posle shaga $n ($($r.Prichina))"
        $snova = $true; break
      }
      $podr = "kontekst=$k"
    }
    Stop-Skill $n $shag $r.Prichina $podr
  }
} while ($snova)
$rez.ok = $true
Save-Rez
