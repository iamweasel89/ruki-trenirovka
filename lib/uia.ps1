# UIA element search and reading (Windows PowerShell 5.1, ASCII only).
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$script:AE = [System.Windows.Automation.AutomationElement]
$script:CT = [System.Windows.Automation.ControlType]
$script:TS = [System.Windows.Automation.TreeScope]

function Write-RukiLog([string]$s) {
  if ($env:RUKI_LOG) {
    try { Add-Content -Path $env:RUKI_LOG -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $s) -Encoding UTF8 } catch {}
  }
}

function New-PropCond($prop, $val) { New-Object System.Windows.Automation.PropertyCondition($prop, $val) }
function New-OrCond([object[]]$c) {
  if ($c.Count -eq 1) { return $c[0] }
  New-Object System.Windows.Automation.OrCondition(, [System.Windows.Automation.Condition[]]$c)
}
function New-AndCond([object[]]$c) {
  New-Object System.Windows.Automation.AndCondition(, [System.Windows.Automation.Condition[]]$c)
}

# control types accepted for a plan step type
function Get-TipyDlya([string]$tip) {
  switch ($tip) {
    'tekst'   { @($CT::Edit, $CT::Document, $CT::Spinner, $CT::ComboBox) }
    'chislo'  { @($CT::Spinner, $CT::Edit) }
    'flazhok' { @($CT::CheckBox) }
    'knopka'  { @($CT::Button) }
    'vybor'   { @($CT::RadioButton) }
    default   { @($CT::Edit) }
  }
}

# all top-level browser windows with their document element
function Get-OknaBrauzera {
  $root = $AE::RootElement
  $c = New-PropCond $AE::ClassNameProperty 'Chrome_WidgetWin_1'
  $res = @()
  foreach ($w in $root.FindAll($TS::Children, $c)) {
    try {
      if ([string]::IsNullOrEmpty($w.Current.Name)) { continue }
      $doc = $w.FindFirst($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Document))
      $res += [pscustomobject]@{ Okno = $w; Hwnd = [IntPtr]$w.Current.NativeWindowHandle; Doc = $doc; Zagolovok = $w.Current.Name }
    } catch {}
  }
  $res
}

function Get-UrlDokumenta($doc, $okno) {
  if ($doc) {
    try {
      $vp = $doc.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
      $v = $vp.Current.Value
      if ($v -match '^[a-z]+:') { return $v }
    } catch {}
  }
  if ($okno) {
    # fallback: the address bar of the browser window
    try {
      $eds = $okno.FindAll($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Edit))
      foreach ($e in $eds) {
        try {
          $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
          if ($v -match '^(file|https?):') { return $v }
          if ($v -match '^[A-Za-z]:/') { return 'file:///' + $v }
        } catch {}
      }
    } catch {}
  }
  return $null
}

# wait for the browser window showing a page whose URL or title matches
function Wait-Stranica($stranica, [int]$TimeoutMs = 25000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    foreach ($o in (Get-OknaBrauzera)) {
      $url = Get-UrlDokumenta $o.Doc $o.Okno
      $poUrl = $url -and ([uri]::UnescapeDataString($url) -like ('*' + $stranica.url_soderzhit + '*'))
      $poZag = $stranica.zagolovok_soderzhit -and ($o.Zagolovok -like ('*' + $stranica.zagolovok_soderzhit + '*'))
      if ($o.Doc -and ($poUrl -or $poZag)) {
        $o | Add-Member -NotePropertyName Url -NotePropertyValue $url -Force
        $o | Add-Member -NotePropertyName PoUrl -NotePropertyValue ([bool]$poUrl) -Force
        return $o
      }
    }
    Start-Sleep -Milliseconds 300
  }
  return $null
}

# is the page still ours: URL check first, title as fallback
function Test-NashaStranica($ctx) {
  $url = Get-UrlDokumenta $ctx.Doc $ctx.Okno
  if ($url) {
    $u = [uri]::UnescapeDataString($url)
    return [pscustomobject]@{ Ok = ($u -like 'file:*') -and ($u -like ('*' + $ctx.Plan.stranica.url_soderzhit + '*')); Metod = 'url' }
  }
  $z = ''
  try { $z = $ctx.Okno.Current.Name } catch {}
  return [pscustomobject]@{ Ok = ($z -like ('*' + $ctx.Plan.stranica.zagolovok_soderzhit + '*')); Metod = 'zagolovok' }
}

# find an element by html id (AutomationId) or by accessible name, restricted to control types
function Find-Element($doc, [string]$id, [string]$metka, [string]$tip, [int]$TimeoutMs = 4000) {
  $tipy = Get-TipyDlya $tip
  $ctC = New-OrCond @($tipy | ForEach-Object { New-PropCond $AE::ControlTypeProperty $_ })
  $kl = @()
  if ($id) { $kl += New-PropCond $AE::AutomationIdProperty $id }
  if ($metka) { $kl += New-PropCond $AE::NameProperty $metka }
  $cond = New-AndCond @($ctC, (New-OrCond $kl))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $kr = 0
  do {
    # the document died (page reloaded or window closed): no point waiting
    if ((++$kr % 6) -eq 0 -and -not (Test-Zhivoj $doc)) { Write-RukiLog "poisk ${id}: dokument mertv"; return $null }
    try {
      $all = $doc.FindAll($TS::Descendants, $cond)
      $best = $null
      foreach ($e in $all) {
        if ($e.Current.IsOffscreen -and $all.Count -gt 1) { continue }
        if ($id -and $e.Current.AutomationId -eq $id) { return $e }
        if (-not $best) { $best = $e }
      }
      if ($best) { return $best }
    } catch {}
    Start-Sleep -Milliseconds 150
  } while ($sw.ElapsedMilliseconds -lt $TimeoutMs)
  return $null
}

# is there a password field anywhere in the document right now
function Test-EstParolVDoc($doc) {
  try { return [bool]$doc.FindFirst($TS::Descendants, (New-PropCond $AE::IsPasswordProperty $true)) } catch { return $false }
}

function Test-Parol($el) {
  if (-not $el) { return $false }
  try {
    if ($el.Current.IsPassword) { return $true }
    $n = $el.Current.Name
    if ($n -match '(?i)password|parol|\u043F\u0430\u0440\u043E\u043B') { return $true }
  } catch {}
  return $false
}

function Get-Znachenie($el) {
  if (-not $el) { return $null }
  try {
    $p = $null
    if ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) {
      return ($p.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On)
    }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) {
      return ([string]$p.Current.Value) -replace "`r`n", "`n" -replace "`r", "`n"
    }
    if ($el.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern, [ref]$p)) {
      return [string]$p.Current.Value
    }
  } catch { return $null }
  return $null
}

function Test-Zhivoj($el) {
  if (-not $el) { return $false }
  try { $null = $el.Current.ControlType; return $true } catch { return $false }
}

function Test-TotZhe($a, $b) {
  if (-not $a -or -not $b) { return $false }
  try { return [System.Windows.Automation.Automation]::Compare($a, $b) } catch { return $false }
}

function Get-Fokus {
  try { return $AE::FocusedElement } catch { return $null }
}

# a modal dialog inside the document
function Find-Dialog($doc) {
  if (-not $doc) { return $null }
  try {
    $c = New-OrCond @(
      (New-PropCond $AE::ControlTypeProperty $CT::Window),
      (New-PropCond $AE::LocalizedControlTypeProperty 'dialog'),
      (New-PropCond $AE::LocalizedControlTypeProperty 'alert dialog')
    )
    return $doc.FindFirst($TS::Descendants, $c)
  } catch { return $null }
}

# short dump of the document subtree for diagnostics
function Get-DampDereva($el, [int]$glubina = 0, [int]$maks = 9) {
  $out = @()
  if (-not $el -or $glubina -gt $maks) { return $out }
  try {
    $c = $el.Current
    $out += ('{0}{1}|{2}|id={3}|lct={4}|pw={5}' -f ('  ' * $glubina), $c.ControlType.ProgrammaticName, $c.Name, $c.AutomationId, $c.LocalizedControlType, $c.IsPassword)
    $w = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $ch = $w.GetFirstChild($el)
    $n = 0
    while ($ch -and $n -lt 60) { $out += Get-DampDereva $ch ($glubina + 1) $maks; $ch = $w.GetNextSibling($ch); $n++ }
  } catch {}
  $out
}
