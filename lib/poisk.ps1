# Finding elements, visibility and speed (Windows PowerShell 5.1, ASCII only).
# Needs lib\uia.ps1 and lib\okno.ps1 loaded first.
#
# Spec of an element (hashtable or JSON object):
#   id              AutomationId (html id)               - strongest key
#   imya            accessible name, exact (normalised fallback: trim, spaces, case, yo)
#   imya_soderzhit  part of the name (only when asked explicitly)
#   rol             UIA ControlType name: Button, Hyperlink, Edit, CheckBox, ...
#   oblast          name of an enclosing region / group / frame document: narrows the scope
#   indeks          1-based number among several matches (tree order)
#   prokrutka       true: the element may be loaded only when scrolled to (lazy lists)
#   zhdat_ms        how long to wait for appearance (default 3000)
# Result of Find-Uzel: @{ Status = ok|net|neodnoznachno; El; Kandidatov; Strategiya; Ms }

if (-not ('RukiMysh' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RukiMysh {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONINFO { public int cb; public RECT mon; public RECT work; public uint fl; }
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, int d, UIntPtr ex);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONINFO i);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  public static void Klik(int x, int y) {
    SetCursorPos(x, y);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
    mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
  }
  public static void Koleso(int x, int y, int delta) {
    SetCursorPos(x, y);
    mouse_event(0x0800, 0, 0, delta, UIntPtr.Zero);
  }
  public static IntPtr RootPodTochkoj(int x, int y) {
    POINT p; p.X = x; p.Y = y;
    IntPtr h = WindowFromPoint(p);
    if (h == IntPtr.Zero) return h;
    return GetAncestor(h, 2);
  }
  // share of the window rectangle that lies inside the work area of its monitor
  public static double DolyaNaEkrane(IntPtr h) {
    RECT r; if (!GetWindowRect(h, out r)) return 0;
    MONINFO mi = new MONINFO(); mi.cb = Marshal.SizeOf(typeof(MONINFO));
    IntPtr m = MonitorFromWindow(h, 2);
    if (!GetMonitorInfo(m, ref mi)) return 0;
    double w = r.R - r.L, hh = r.B - r.T;
    if (w <= 0 || hh <= 0) return 0;
    double iw = Math.Min(r.R, mi.work.R) - Math.Max(r.L, mi.work.L);
    double ih = Math.Min(r.B, mi.work.B) - Math.Max(r.T, mi.work.T);
    if (iw <= 0 || ih <= 0) return 0;
    return (iw * ih) / (w * hh);
  }
}
'@
}

# one cache request for everything the search reads from candidates
$script:KeshPoiska = New-Object System.Windows.Automation.CacheRequest
foreach ($p in @($AE::NameProperty, $AE::AutomationIdProperty, $AE::ControlTypeProperty, $AE::IsOffscreenProperty,
                 $AE::BoundingRectangleProperty, $AE::IsEnabledProperty, $AE::NativeWindowHandleProperty, $AE::ClassNameProperty)) { $KeshPoiska.Add($p) }
$KeshPoiska.TreeScope = $TS::Element

function Get-Pole($spec, [string]$k) {
  if ($null -eq $spec) { return $null }
  if ($spec -is [hashtable]) { return $spec[$k] }
  $p = $spec.PSObject.Properties[$k]
  if ($p) { return $p.Value }
  return $null
}

function Get-NormImya([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s -replace '[\s\u00A0]+', ' '
  $s = $s.Trim().ToLowerInvariant()
  return $s.Replace([string][char]0x0451, [string][char]0x0435)
}

# FindAll under the cache request; returns an array of cached elements
function Find-VseKesh($koren, $cond, $scope = $null) {
  if (-not $scope) { $scope = $TS::Descendants }
  $KeshPoiska.Push()
  try { return @($koren.FindAll($scope, $cond)) } catch { return @() } finally { $KeshPoiska.Pop() }
}

function Get-KeshRect($e) {
  try { return $e.Cached.BoundingRectangle } catch { return [System.Windows.Rect]::Empty }
}

# scopes: the root itself, or every region/group/frame document named "oblast"
function Get-Oblasti($koren, [string]$oblast) {
  if (-not $oblast) { return @($koren) }
  $tipy = @($CT::Group, $CT::Document, $CT::Pane, $CT::Custom, $CT::List, $CT::Tab, $CT::Window)
  $c = New-AndCond @((New-PropCond $AE::NameProperty $oblast), (New-OrCond @($tipy | ForEach-Object { New-PropCond $AE::ControlTypeProperty $_ })))
  return Find-VseKesh $koren $c
}

# one pass of all strategies; returns @{ Spisok; Strategiya }
function Find-Kandidaty($koren, $spec) {
  $id = Get-Pole $spec 'id'; $imya = Get-Pole $spec 'imya'; $sod = Get-Pole $spec 'imya_soderzhit'
  $rol = Get-Pole $spec 'rol'; $oblast = Get-Pole $spec 'oblast'
  $rolC = if ($rol) { New-PropCond $AE::ControlTypeProperty ($CT::$rol) } else { $null }
  $oblasti = @(Get-Oblasti $koren $oblast)
  if ($oblasti.Count -eq 0) { return @{ Spisok = @(); Strategiya = 'net-oblasti' } }
  $plan = @()
  if ($id) { $plan += , @('id', (New-PropCond $AE::AutomationIdProperty $id)) }
  if ($imya) {
    $c = New-PropCond $AE::NameProperty $imya
    if ($rolC) { $c = New-AndCond @($c, $rolC) }
    $plan += , @('imya', $c)
  }
  foreach ($st in $plan) {
    $res = @()
    foreach ($ob in $oblasti) { $res += @(Find-VseKesh $ob $st[1]) }
    if ($st[0] -eq 'id' -and $rol) { $res = @($res | Where-Object { $_.Cached.ControlType -eq $CT::$rol }) }
    if ($res.Count) { return @{ Spisok = $res; Strategiya = $st[0] } }
  }
  # fallback: normalised name or explicit part of the name, among elements of the role
  if ($imya -or $sod) {
    $c = if ($rolC) { $rolC } else { New-OrCond @(@($CT::Button, $CT::Hyperlink, $CT::Edit, $CT::CheckBox, $CT::RadioButton, $CT::ComboBox, $CT::MenuItem, $CT::TabItem, $CT::ListItem) | ForEach-Object { New-PropCond $AE::ControlTypeProperty $_ }) }
    $nImya = Get-NormImya $imya; $nSod = Get-NormImya $sod
    $res = @()
    foreach ($ob in $oblasti) {
      foreach ($e in @(Find-VseKesh $ob $c)) {
        $n = Get-NormImya $e.Cached.Name
        if (($imya -and $n -eq $nImya) -or ($sod -and $n.Contains($nSod))) { $res += $e }
      }
    }
    if ($res.Count) { return @{ Spisok = $res; Strategiya = $(if ($sod) { 'soderzhit' } else { 'norm-imya' }) } }
  }
  return @{ Spisok = @(); Strategiya = 'net' }
}

function Select-Kandidat($spisok, $spec) {
  $ind = Get-Pole $spec 'indeks'
  # elements with an empty rectangle are not rendered (visibility hidden, zero size)
  $vid = @($spisok | Where-Object { -not (Get-KeshRect $_).IsEmpty -and (Get-KeshRect $_).Width -gt 0 })
  if ($vid.Count) { $spisok = $vid }
  if ($ind) {
    if ($spisok.Count -ge [int]$ind) { return @{ Status = 'ok'; El = $spisok[[int]$ind - 1] } }
    return @{ Status = 'net' }
  }
  if ($spisok.Count -eq 1 -or (Get-Pole $spec 'id')) { return @{ Status = 'ok'; El = $spisok[0] } }
  return @{ Status = 'neodnoznachno' }
}

# scroll the document and every scrollable frame document inside it to the end.
# Lazy lists add content at the end, so the next call moves again. Returns $true if anything moved.
function Move-StranicaVniz($doc, $hwnd) {
  $dvig = $false
  $docs = @($doc) + @(Find-VseKesh $doc (New-PropCond $AE::ControlTypeProperty $CT::Document))
  foreach ($d in $docs) {
    $p = $null
    try {
      if ($d.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$p) -and $p.Current.VerticallyScrollable) {
        if ($p.Current.VerticalScrollPercent -lt 99.5) { $p.SetScrollPercent(-1, 100); $dvig = $true }
      }
    } catch {}
  }
  if ($dvig) { return $true }
  # fallback when no scroll pattern answered: mouse wheel over the middle of the document
  try {
    $p = $null
    if (-not $doc.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$p)) {
      $r = $doc.Current.BoundingRectangle
      [RukiMysh]::Koleso([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2), -720)
      return $true
    }
  } catch {}
  return $false
}

function Find-Uzel($koren, $spec, [IntPtr]$hwnd = [IntPtr]::Zero) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $tmo = Get-Pole $spec 'zhdat_ms'; if (-not $tmo) { $tmo = 3000 }
  $prok = [bool](Get-Pole $spec 'prokrutka')
  if ($prok -and $tmo -lt 8000) { $tmo = 8000 }
  $pauza = 20; $last = $null; $bezDvizheniya = 0; $prohod = 0; $avto = $false
  while ($true) {
    $prohod++
    $k = Find-Kandidaty $koren $spec
    if ($k.Spisok.Count) {
      $v = Select-Kandidat $k.Spisok $spec
      if ($v.Status -eq 'ok' -or $v.Status -eq 'neodnoznachno') {
        return @{ Status = $v.Status; El = $v.El; Kandidatov = $k.Spisok.Count; Strategiya = $k.Strategiya; Ms = $sw.ElapsedMilliseconds; Prohodov = $prohod }
      }
    }
    $last = $k
    if ($sw.ElapsedMilliseconds -ge $tmo) { break }
    if ($prok) {
      # lazy list: scroll on; stop when the page no longer moves and nothing new appeared
      if (Move-StranicaVniz $koren $hwnd) { $bezDvizheniya = 0 } else { $bezDvizheniya++ }
      if ($bezDvizheniya -ge 3) { break }
      Start-Sleep -Milliseconds 50; $script:Spano += 50
      continue
    }
    # nothing yet after a while: content may be built only when scrolled to (frames, lazy parts)
    if ($sw.ElapsedMilliseconds -ge 350 -and -not $avto) { $avto = $true; Write-RukiLog 'poisk: avto-prokrutka' }
    if ($avto) { $null = Move-StranicaVniz $koren $hwnd }
    Start-Sleep -Milliseconds $pauza; $script:Spano += $pauza
    if ($pauza -lt 160) { $pauza = [Math]::Min(160, $pauza * 2) }
  }
  return @{ Status = 'net'; El = $null; Kandidatov = $last.Spisok.Count; Strategiya = $last.Strategiya; Ms = $sw.ElapsedMilliseconds; Prohodov = $prohod }
}

# wait until the element is enabled (live reads)
function Wait-Dostupen($el, [int]$TimeoutMs = 3000) {
  $sw = [Diagnostics.Stopwatch]::StartNew(); $pz = 20
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    try { if ($el.Current.IsEnabled) { return $true } } catch { return $false }
    Start-Sleep -Milliseconds $pz; $script:Spano += $pz; if ($pz -lt 120) { $pz *= 2 }
  }
  return $false
}

# window really visible: not minimised, >= 60 % inside the work area, in front.
# Fixes what it can. Returns @{ Ok; Bylo (list of fixes) }
function Confirm-OknoGotovo([IntPtr]$hwnd, [double]$minDolya = 0.6) {
  $bylo = @()
  if (-not [RukiOkno]::IsWindow($hwnd)) { return @{ Ok = $false; Bylo = @('net-okna') } }
  for ($i = 0; $i -lt 4; $i++) {
    $min = [RukiOkno]::IsIconic($hwnd) -or -not [RukiOkno]::IsWindowVisible($hwnd)
    $dolya = [RukiMysh]::DolyaNaEkrane($hwnd)
    $vper = (Get-PerednijRoot) -eq $hwnd
    if (-not $min -and $dolya -ge $minDolya -and $vper) { return @{ Ok = $true; Bylo = $bylo } }
    if ($min) { $bylo += 'svernuto'; $null = [RukiOkno]::ShowWindow($hwnd, 9) }
    elseif ($dolya -lt $minDolya) { $bylo += ('za-ekranom-' + [int]($dolya * 100)); $null = [RukiOkno]::ShowWindow($hwnd, 3) }
    if (-not $vper -or $min) { if (-not $vper) { $bylo += 'ne-vperedi' }; $null = [RukiOkno]::Vperyod($hwnd) }
    # poll for the new state instead of a fixed pause
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.ElapsedMilliseconds -lt 600) {
      if (-not [RukiOkno]::IsIconic($hwnd) -and [RukiMysh]::DolyaNaEkrane($hwnd) -ge $minDolya -and (Get-PerednijRoot) -eq $hwnd) { break }
      Start-Sleep -Milliseconds 25
    }
  }
  return @{ Ok = $false; Bylo = $bylo }
}

function Test-VnutriRect($r, $v, [int]$pole = 2) {
  return (-not $r.IsEmpty) -and $r.Width -gt 0 -and $r.Height -gt 0 -and
    $r.Left -ge ($v.Left - $pole) -and $r.Top -ge ($v.Top - $pole) -and $r.Right -le ($v.Right + $pole) -and $r.Bottom -le ($v.Bottom + $pole)
}

function Test-Pokazan($el, $doc) {
  try {
    $c = $el.Current
    if ($c.IsOffscreen) { return $false }
    return Test-VnutriRect $c.BoundingRectangle $doc.Current.BoundingRectangle
  } catch { return $false }
}

# bring the element into the visible area of the document. Returns the method used or $null.
function Show-Uzel($el, $doc, [IntPtr]$hwnd) {
  if (Test-Pokazan $el $doc) { return 'uzhe' }
  $metody = @('scrollitem', 'fokus', 'koleso')
  foreach ($m in $metody) {
    try {
      switch ($m) {
        'scrollitem' { $el.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView() }
        'fokus' { $el.SetFocus() }
        'koleso' {
          $v = $doc.Current.BoundingRectangle
          for ($j = 0; $j -lt 30 -and -not (Test-Pokazan $el $doc); $j++) {
            $r = $el.Current.BoundingRectangle
            $d = if ($r.Top -gt $v.Bottom -or $r.IsEmpty) { -240 } else { 240 }
            [RukiMysh]::Koleso([int]($v.X + $v.Width / 2), [int]($v.Y + $v.Height / 2), $d)
            Start-Sleep -Milliseconds 40
          }
        }
      }
    } catch { continue }
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ($t.ElapsedMilliseconds -lt 500) {
      if (Test-Pokazan $el $doc) { return $m }
      Start-Sleep -Milliseconds 20
    }
  }
  return $null
}

# after the window was restored / moved the page relayouts: wait until the rectangle stops changing
function Wait-RectUstojchiv($el, [int]$TimeoutMs = 1200, $ot = $null, [int]$rovnoNado = 2, [int]$shag = 30) {
  $sw = [Diagnostics.Stopwatch]::StartNew(); $pr = $null; $rovno = 0
  # first the rectangle must leave its old value (the relayout has started), if one is given
  while ($ot -ne $null -and $sw.ElapsedMilliseconds -lt 600) {
    try { if ($el.Current.BoundingRectangle -ne $ot) { break } } catch { return $false }
    Start-Sleep -Milliseconds 25
  }
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    try { $r = $el.Current.BoundingRectangle } catch { return $false }
    if ($pr -ne $null -and $r -eq $pr) { $rovno++; if ($rovno -ge $rovnoNado) { return $true } } else { $rovno = 0 }
    $pr = $r
    Start-Sleep -Milliseconds $shag
  }
  return $false
}

# only a change of the window geometry (restore, maximise) makes the page relayout;
# bringing the window to the front does not
function Test-GeomFiks($bylo) {
  foreach ($b in @($bylo)) { if ($b -eq 'svernuto' -or ([string]$b).StartsWith('za-ekranom')) { return $true } }
  return $false
}

# the element is what lies under its own centre (not covered, not clipped by a frame)
function Test-PodTochkoj($el, [int]$x, [int]$y, [IntPtr]$hwnd) {
  if ([RukiMysh]::RootPodTochkoj($x, $y) -ne $hwnd) { return 'drugoe-okno' }
  try {
    $u = $AE::FromPoint((New-Object System.Windows.Point($x, $y)))
    $w = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    for ($i = 0; $i -lt 4 -and $u; $i++) {
      if ([System.Windows.Automation.Automation]::Compare($u, $el)) { return 'ok' }
      $u = $w.GetParent($u)
    }
    return 'zakryto'
  } catch { return 'oshibka' }
}

# browser window by title / URL, switching to a background tab when needed.
# spec: zagolovok_soderzhit, url_soderzhit. Returns @{ Okno; Hwnd; Doc; Vkladka } or $null
function Select-OknoBrauzera($spec, [int]$TimeoutMs = 0) {
  if (-not $TimeoutMs) { $TimeoutMs = Get-Pole $spec 'zhdat_ms'; if (-not $TimeoutMs) { $TimeoutMs = 4000 } }
  $zag = Get-Pole $spec 'zagolovok_soderzhit'; $url = Get-Pole $spec 'url_soderzhit'
  $sw = [Diagnostics.Stopwatch]::StartNew(); $vkladka = $false
  $docC = New-PropCond $AE::ControlTypeProperty $CT::Document
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    $okna = Find-VseKesh $AE::RootElement (New-PropCond $AE::ClassNameProperty 'Chrome_WidgetWin_1') $TS::Children
    $okna = @($okna | Where-Object { $_.Cached.Name })
    $podh = @($okna | Where-Object { -not $zag -or $_.Cached.Name -like ('*' + $zag + '*') })
    foreach ($w in $podh) {
      $doc = $null
      try { $doc = $w.FindFirst($TS::Descendants, $docC) } catch {}
      if (-not $doc) { continue }
      if ($url) {
        $u = Get-UrlDokumenta $doc $null
        if (-not ($u -and [uri]::UnescapeDataString($u) -like ('*' + $url + '*'))) { continue }
      }
      return @{ Okno = $w; Hwnd = [IntPtr]$w.Cached.NativeWindowHandle; Doc = $doc; Vkladka = $vkladka }
    }
    # not an active tab anywhere: look for a tab with that title and select it
    if ($zag -and -not $vkladka) {
      $tc = New-PropCond $AE::ControlTypeProperty $CT::TabItem
      foreach ($w in $okna) {
        foreach ($t in (Find-VseKesh $w $tc)) {
          if ($t.Cached.Name -like ('*' + $zag + '*')) {
            Write-RukiLog "vkladka: $($t.Cached.Name)"
            $h = [IntPtr]$w.Current.NativeWindowHandle
            $null = Confirm-OknoGotovo $h
            $sel = $null
            try { if ($t.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) { $sel.Select() } else { $t.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } } catch {
              $r = $t.Current.BoundingRectangle; [RukiMysh]::Klik([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
            }
            $vkladka = $true
            break
          }
        }
        if ($vkladka) { break }
      }
      if ($vkladka) { continue }
    }
    Start-Sleep -Milliseconds 40
  }
  return $null
}

# The whole movement: window -> find -> visible -> scroll into view -> check under point -> click.
# zadacha: @{ okno = @{...}; element = @{...}; dejstvie = klik|invoke }
# Returns @{ Status; Ms; Etapy; Strategiya; Kandidatov; Okno; Prokrutka }
function Invoke-Dvizhenie($zadacha) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $script:Spano = 0
  $et = [ordered]@{}
  $rez = [ordered]@{ Status = 'ok'; Ms = 0; Ozhidanie = 0; Effekt = $null; Diag = $null; Povtor = $null; Etapy = $et; Strategiya = $null; Kandidatov = 0; Okno = @(); Prokrutka = $null }
  # Ozhidanie: time spent waiting for the page (appearance, enabling), not work of the hands
  function Konec($s) { $rez.Status = $s; $rez.Ms = [int]$sw.ElapsedMilliseconds; $rez.Ozhidanie = [int]$script:Spano; return $rez }
  $t = $sw.ElapsedMilliseconds
  $o = Select-OknoBrauzera (Get-Pole $zadacha 'okno')
  $et.okno = [int]($sw.ElapsedMilliseconds - $t)
  if (-not $o) { return Konec 'net-okna' }
  $t = $sw.ElapsedMilliseconds
  $r0 = $null; try { $r0 = $o.Doc.Current.BoundingRectangle } catch {}
  $g = Confirm-OknoGotovo $o.Hwnd
  $rez.Okno = $g.Bylo
  $et.vidimost = [int]($sw.ElapsedMilliseconds - $t)
  if (-not $g.Ok) { return Konec 'okno-ne-vidno' }
  $spec = Get-Pole $zadacha 'element'
  $fiks = $null
  if (Test-GeomFiks $g.Bylo) { $fiks = $sw.ElapsedMilliseconds; $null = Wait-RectUstojchiv $o.Doc 1500 $r0 }
  for ($pop = 1; $pop -le 3; $pop++) {
    $t = $sw.ElapsedMilliseconds
    $f = Find-Uzel $o.Doc $spec $o.Hwnd
    $et.poisk = [int]($sw.ElapsedMilliseconds - $t)
    $rez.Strategiya = $f.Strategiya; $rez.Kandidatov = $f.Kandidatov
    if ($f.Status -ne 'ok') { return Konec $f.Status }
    $el = $f.El
    $t = $sw.ElapsedMilliseconds
    if (-not (Wait-Dostupen $el 3000)) { if (Test-Zhivoj $el) { return Konec 'nedostupen' } else { continue } }
    $et.dostupen = [int]($sw.ElapsedMilliseconds - $t)
    if ((Get-Pole $zadacha 'dejstvie') -eq 'invoke') {
      try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return Konec 'ok' } catch { continue }
    }
    $t = $sw.ElapsedMilliseconds
    $m = Show-Uzel $el $o.Doc $o.Hwnd
    $et.prokrutka = [int]($sw.ElapsedMilliseconds - $t)
    $rez.Prokrutka = $m
    if (-not $m) { if (-not (Test-Zhivoj $el)) { continue }; return Konec 'ne-prokrutilos' }
    $t = $sw.ElapsedMilliseconds
    $g = Confirm-OknoGotovo $o.Hwnd
    if ($g.Bylo) { $rez.Okno += $g.Bylo }
    if (-not $g.Ok) { return Konec 'okno-ne-vidno' }
    if (Test-GeomFiks $g.Bylo) { $fiks = $sw.ElapsedMilliseconds; $null = Wait-RectUstojchiv $o.Doc 1500; $null = Show-Uzel $el $o.Doc $o.Hwnd }
    # after a window fix the page relayouts with a delay: give it time and demand a longer stable run
    if ($fiks -ne $null) {
      $ost = 300 - ($sw.ElapsedMilliseconds - $fiks); if ($ost -gt 0) { Start-Sleep -Milliseconds $ost }
      $null = Wait-RectUstojchiv $el 1200 $null 3 50
    } else { $null = Wait-RectUstojchiv $el 300 $null 1 }
    try { $r = $el.Current.BoundingRectangle } catch { continue }
    $x = [int]($r.X + $r.Width / 2); $y = [int]($r.Y + $r.Height / 2)
    $pt = Test-PodTochkoj $el $x $y $o.Hwnd
    $et.proverka = [int]($sw.ElapsedMilliseconds - $t)
    if ($pt -eq 'drugoe-okno') { $null = Confirm-OknoGotovo $o.Hwnd; $pt = Test-PodTochkoj $el $x $y $o.Hwnd }
    if ($pt -ne 'ok') {
      Write-RukiLog "pod tochkoj: $pt"
      if (-not (Test-Zhivoj $el)) { continue }
      if ($pop -lt 3) { continue }
      return Konec ('pod-tochkoj-' + $pt)
    }
    # snapshot for the effect check
    $do = Get-SnimokEffekta $el $o
    [RukiMysh]::Klik($x, $y)
    $t = $sw.ElapsedMilliseconds
    $ef = Wait-Effekt $el $o $do 700
    $et.effekt = [int]($sw.ElapsedMilliseconds - $t)
    $rez.Effekt = $ef.Vid
    $r2 = $null; try { $r2 = $el.Current.BoundingRectangle } catch {}
    $rez.Diag = ('tochka={0},{1} rect_do={2} rect_posle={3} fiks={4}' -f $x, $y, $r, $r2, ($g.Bylo -join '+'))
    if ($ef.Est) { return Konec 'ok' }
    Write-RukiLog "klik bez effekta: $($rez.Diag)"
    # no effect and the element moved since the point was taken: the layout was stale, a retry is safe
    if ($pop -lt 3 -and $r2 -ne $null -and $r2 -ne $r) { $rez.Povtor = 'rect-sdvinulsya'; continue }
    return Konec 'nazhatie-ne-doshlo'
  }
  return Konec 'ustarel'
}

# what the effect check compares: focus, window title, the element's own state
function Get-SnimokEffekta($el, $o) {
  $f = Get-Fokus
  $sn = @{ Fokus = $f; Zag = $null; Imya = $null; Vkl = $null; Zhiv = $true }
  try { $sn.Zag = $o.Okno.Current.Name } catch {}
  try { $c = $el.Current; $sn.Imya = $c.Name; $sn.Vkl = $c.IsEnabled } catch { $sn.Zhiv = $false }
  return $sn
}

# the page reacted to the click: focus moved onto the element or elsewhere, the title changed,
# the element changed its name / enabled state or left the tree. Returns @{ Est; Vid }
function Wait-Effekt($el, $o, $do, [int]$TimeoutMs = 700) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    $f = Get-Fokus
    if ($f -and (Test-TotZhe $f $el)) { return @{ Est = $true; Vid = 'fokus-na-celi' } }
    try { if ($o.Okno.Current.Name -ne $do.Zag) { return @{ Est = $true; Vid = 'zagolovok' } } } catch {}
    if (-not (Test-Zhivoj $el)) { return @{ Est = $true; Vid = 'element-ushel' } }
    try { $c = $el.Current; if ($c.Name -ne $do.Imya -or $c.IsEnabled -ne $do.Vkl) { return @{ Est = $true; Vid = 'sostoyanie' } } } catch {}
    if ($f -and $do.Fokus -and -not (Test-TotZhe $f $do.Fokus)) { return @{ Est = $true; Vid = 'fokus-drugoj' } }
    if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return @{ Est = $false; Vid = 'net' } }
    Start-Sleep -Milliseconds 30
  }
}
