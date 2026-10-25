# Wizard movements (Windows PowerShell 5.1, ASCII only).
# Needs lib\uia.ps1, lib\okno.ps1, lib\vvod.ps1 loaded first.
# One cached pass over the document gives headings, alert messages and text lines,
# so a step check costs one cross-process call instead of hundreds.

$script:ReZagolovok = '(?i)heading|\u0437\u0430\u0433\u043e\u043b\u043e\u0432'
$script:ReAlert = '(?i)alert|\u043e\u043f\u043e\u0432\u0435\u0449'

function Get-Obzor($doc) {
  $res = @()
  if (-not $doc) { return $res }
  $cr = New-Object System.Windows.Automation.CacheRequest
  $cr.Add($AE::NameProperty); $cr.Add($AE::LocalizedControlTypeProperty); $cr.Add($AE::AutomationIdProperty)
  $cr.Add($AE::ControlTypeProperty); $cr.Add($AE::IsOffscreenProperty)
  $cr.TreeScope = [System.Windows.Automation.TreeScope]::Element
  $h = $null
  try {
    $h = $cr.Activate()
    $all = $doc.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
      try {
        $c = $e.Cached
        $res += [pscustomobject]@{ Name = [string]$c.Name; Lct = [string]$c.LocalizedControlType; Id = [string]$c.AutomationId; Ct = $c.ControlType.ProgrammaticName; El = $e }
      } catch {}
    }
  } catch {} finally { if ($h) { $h.Dispose() } }
  return $res
}

function Get-TekstUzla($u) {
  if ($u.Name.Trim()) { return $u.Name.Trim() }
  try {
    $parts = @()
    foreach ($x in $u.El.FindAll($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Text))) { $n = [string]$x.Current.Name; if ($n.Trim()) { $parts += $n.Trim() } }
    return ($parts -join ' ')
  } catch { return '' }
}

function Get-ZagolovkiObzora($obzor) { @($obzor | Where-Object { $_.Lct -match $ReZagolovok -and $_.Name.Trim() } | ForEach-Object { $_.Name.Trim() }) }

function Get-OshibkiObzora($obzor) {
  $res = @()
  foreach ($u in $obzor) {
    if ($u.Lct -match $ReAlert -or $u.Id -match '^(?i)(oshibka|error)') {
      $t = Get-TekstUzla $u
      if ($t -and $res -notcontains $t) { $res += $t }
    }
  }
  return $res
}

# text lines of the visible page (static texts and list items), without duplicates
function Get-StrokiObzora($obzor) {
  $res = New-Object System.Collections.Generic.List[string]
  foreach ($u in $obzor) {
    if ($u.Ct -notin 'ControlType.Text', 'ControlType.ListItem') { continue }
    $t = (($u.Name -replace '\s+', ' ').Trim()) -replace '^[\u2022\u25e6\u25aa*-]\s*', ''
    if ($t -and -not $res.Contains($t)) { $res.Add($t) }
  }
  return , $res
}

# which wizard step is on screen: matches headings against the plan steps and the summary
# returns @{ Vid = shag|svodka|net|neizvesten; Shag; Tekst; Nomer; Iz; Zagolovki; Obzor }
function Get-TekushchijShag($ctx, $obzor = $null) {
  if (-not $obzor) { $obzor = Get-Obzor $ctx.Doc }
  $zag = Get-ZagolovkiObzora $obzor
  $best = $null; $dl = -1
  foreach ($z in $zag) {
    foreach ($sh in @($ctx.Plan.shagi)) {
      if ($z.Contains([string]$sh.zagolovok) -and ([string]$sh.zagolovok).Length -gt $dl) { $best = @{ Vid = 'shag'; Shag = $sh; Tekst = $z }; $dl = ([string]$sh.zagolovok).Length }
    }
    if ($z.Contains([string]$ctx.Plan.svodka.zagolovok) -and ([string]$ctx.Plan.svodka.zagolovok).Length -gt $dl) { $best = @{ Vid = 'svodka'; Shag = $null; Tekst = $z }; $dl = ([string]$ctx.Plan.svodka.zagolovok).Length }
  }
  if (-not $best) {
    # a heading with a step counter that the plan does not know
    $neizv = @($zag | Where-Object { $_ -match '\d+\D{1,6}\d+' })
    if ($neizv.Count) { $best = @{ Vid = 'neizvesten'; Shag = $null; Tekst = $neizv[0] } } else { $best = @{ Vid = 'net'; Shag = $null; Tekst = '' } }
  }
  $best.Nomer = 0; $best.Iz = 0
  if ($best.Tekst -match '(\d+)\D{1,6}(\d+)') { $best.Nomer = [int]$Matches[1]; $best.Iz = [int]$Matches[2] }
  $best.Zagolovki = $zag
  $best.Obzor = $obzor
  return $best
}

function Test-Vybrano($el) {
  if (-not $el) { return $false }
  try {
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { return [bool]$p.Current.IsSelected }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { return ($p.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) }
  } catch {}
  return $false
}

# choose a radio option. returns @{ Status; Prichina; Popytki }
function Set-Vybor($ctx, $pole) {
  for ($pop = 1; $pop -le 5; $pop++) {
    $el = Find-V $ctx $pole 'vybor'
    if (-not $el) { return @{ Status = 'stop'; Prichina = 'net-elementa'; Popytki = $pop } }
    $ok = Confirm-OknoVidimo $ctx.Hwnd
    if ($ok.Bylo) { Add-Pomeha $ctx 'okno' }
    if (Find-Dialog $ctx.Doc) { $null = Close-Dialog $ctx; continue }
    if (Test-Vybrano $el) { return @{ Status = 'ok'; Popytki = $pop } }
    if (-not $el.Current.IsEnabled) { return @{ Status = 'stop'; Prichina = 'vybor-nedostupen'; Popytki = $pop } }
    Set-MetkaVvoda $ctx
    try { $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() }
    catch { try { if (Test-OknoVperedi $ctx.Hwnd) { $el.SetFocus(); Send-Klavisha 'Space' } } catch {} }
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Vybrano $el) -and $t.ElapsedMilliseconds -lt 1000) { Start-Sleep -Milliseconds 80 }
    if (Test-Vybrano $el) { return @{ Status = 'ok'; Popytki = $pop } }
    if ($pop -ge 2 -and (Test-OknoVperedi $ctx.Hwnd)) { try { $el.SetFocus(); Send-Klavisha 'Space' } catch {} }
  }
  return @{ Status = 'stop'; Prichina = 'vybor-ne-ustanovlen'; Popytki = 5 }
}

function Get-Hash([string]$s) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}
