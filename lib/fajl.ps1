# File upload through the system file-open dialog (Windows common item dialog).
# Windows PowerShell 5.1, ASCII only. Needs lib\uia.ps1, lib\okno.ps1, lib\vvod.ps1 loaded first.
#
# Plan step (tip = "fajl"):
#   id / metka   the opener on the page: an upload button, a drop zone, a native file input
#   fajly        full paths; %VARS% are expanded; several files must share one folder
#   otmena       true: open the dialog and cancel it (nothing must reach the page)
#   obrezka      { id, metka } of the Save button of a cropping modal shown after upload;
#                without it a modal with a Save / Apply / Crop / OK button is handled generically
#   proverka     { soderzhit: [...] } texts that must show on the page; default: the file names
#   otkaz        { id, metka } of the element where the page shows a rejection
#   zhdat_ms     how long to wait for the page to react (default 15000)
# The dialog is driven without keyboard focus: ValuePattern on the file name field and a posted
# BM_CLICK on Open / Cancel, so a window popping in front or a minimised browser does not matter.

if (-not ('RukiDialog' -as [type])) {
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RukiDialog {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
  public static string Klass(IntPtr h) { StringBuilder s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Tekst(IntPtr h) { StringBuilder s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static IntPtr Vladelec(IntPtr h) { return GetWindow(h, 4); }
  // top-level dialog windows (#32770) of a process
  public static IntPtr[] Dialogi(uint pid) {
    List<IntPtr> res = new List<IntPtr>();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      if (Klass(h) == "#32770" && Pid(h) == pid) res.Add(h);
      return true;
    }, IntPtr.Zero);
    return res.ToArray();
  }
  public static bool Klik(IntPtr knopka) { return PostMessage(knopka, 0x00F5, IntPtr.Zero, IntPtr.Zero); }
  public static bool Komanda(IntPtr dlg, int id) { return PostMessage(dlg, 0x0111, (IntPtr)id, IntPtr.Zero); }
  public static bool Zakryt(IntPtr h) { return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
}
'@
}

# cache for reading names of many page elements at once
$script:KeshTeksta = New-Object System.Windows.Automation.CacheRequest
foreach ($p in @($AE::NameProperty, $AE::ControlTypeProperty)) { $KeshTeksta.Add($p) }
$KeshTeksta.TreeScope = $TS::Element

# a file dialog is a #32770 that hosts the file name box (id 1148) or the shell view;
# a message box is a #32770 owned by another #32770
function Test-DialogFajla([IntPtr]$h) {
  $v = [RukiDialog]::Vladelec($h)
  if ($v -ne [IntPtr]::Zero -and [RukiDialog]::Klass($v) -eq '#32770') { return $false }
  if ([RukiDialog]::GetDlgItem($h, 1148) -ne [IntPtr]::Zero) { return $true }
  try {
    $el = $AE::FromHandle($h)
    $c = New-OrCond @((New-PropCond $AE::AutomationIdProperty '1148'), (New-PropCond $AE::ClassNameProperty 'DUIViewWndClassName'))
    return [bool]$el.FindFirst($TS::Descendants, $c)
  } catch { return $false }
}

# open file dialogs of the browser that owns window $hwnd
function Get-DialogiFajla([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return @() }
  $pid0 = [RukiDialog]::Pid($hwnd)
  return @([RukiDialog]::Dialogi($pid0) | Where-Object { Test-DialogFajla $_ })
}

# message boxes owned by a dialog (e.g. "file not found")
function Get-SoobshcheniyaDialoga([IntPtr]$dlg) {
  return @([RukiDialog]::Dialogi([RukiDialog]::Pid($dlg)) | Where-Object { [RukiDialog]::Vladelec($_) -eq $dlg })
}

function Wait-DialogFajla([IntPtr]$hwnd, [int]$TimeoutMs = 5000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    $d = @(Get-DialogiFajla $hwnd)
    if ($d.Count) { return $d[0] }
    Start-Sleep -Milliseconds 100
  } while ($sw.ElapsedMilliseconds -lt $TimeoutMs)
  return [IntPtr]::Zero
}

function Wait-DialogZakryt([IntPtr]$dlg, [int]$TimeoutMs = 4000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ([RukiDialog]::IsWindow($dlg) -and $sw.ElapsedMilliseconds -lt $TimeoutMs) { Start-Sleep -Milliseconds 80 }
  return -not [RukiDialog]::IsWindow($dlg)
}

# the "File name" edit box of the dialog: by control id (locale independent), then by name
function Get-PoleImeni([IntPtr]$dlg, [int]$TimeoutMs = 4000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $imena = @('File name:', [regex]::Unescape('\u0418\u043c\u044f \u0444\u0430\u0439\u043b\u0430:'))
  do {
    try {
      $koren = $AE::FromHandle($dlg)
      $ed = $koren.FindFirst($TS::Descendants, (New-AndCond @((New-PropCond $AE::ControlTypeProperty $CT::Edit), (New-PropCond $AE::AutomationIdProperty '1148'))))
      if (-not $ed) {
        $cb = $koren.FindFirst($TS::Descendants, (New-AndCond @((New-PropCond $AE::ControlTypeProperty $CT::ComboBox), (New-PropCond $AE::AutomationIdProperty '1148'))))
        if ($cb) { $ed = $cb.FindFirst($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Edit)) }
      }
      if (-not $ed) {
        foreach ($n in $imena) {
          $ed = $koren.FindFirst($TS::Descendants, (New-AndCond @((New-PropCond $AE::ControlTypeProperty $CT::Edit), (New-PropCond $AE::NameProperty $n))))
          if ($ed) { break }
        }
      }
      if ($ed) { return $ed }
    } catch {}
    Start-Sleep -Milliseconds 150
  } while ($sw.ElapsedMilliseconds -lt $TimeoutMs)
  return $null
}

# put text into the file name box: ValuePattern first, typing as a fallback (dialog must be in front)
function Set-PoleImeni($ctx, [IntPtr]$dlg, $pole, [string]$s) {
  for ($i = 1; $i -le 3; $i++) {
    try { $pole.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($s) } catch { Write-RukiLog "dialog: SetValue $($_.Exception.Message)" }
    if ((Wait-Znachenie $pole $s 800) -ceq $s) { return $true }
    Start-Sleep -Milliseconds 150
  }
  Add-Pomeha $ctx 'dialog-vvod-klavishami'
  Write-RukiLog 'dialog: SetValue ne proshel, pechatayu'
  $null = [RukiOkno]::Vperyod($dlg)
  try { $pole.SetFocus() } catch {}
  Start-Sleep -Milliseconds 150
  if ((Get-PerednijRoot) -ne $dlg) { return $false }
  Send-Klavisha 'CtrlA'; Send-Klavisha 'Delete'
  $null = Send-Tekst $s 8 $dlg
  return ((Wait-Znachenie $pole $s 1000) -ceq $s)
}

# press a dialog button by control id (1 = Open, 2 = Cancel) without focus
function Invoke-KnopkaDialoga([IntPtr]$dlg, [int]$id) {
  $b = [RukiDialog]::GetDlgItem($dlg, $id)
  if ($b -ne [IntPtr]::Zero) { return [RukiDialog]::Klik($b) }
  try {
    $el = $AE::FromHandle($dlg).FindFirst($TS::Descendants, (New-AndCond @((New-PropCond $AE::AutomationIdProperty ([string]$id)), (New-OrCond @((New-PropCond $AE::ControlTypeProperty $CT::Button), (New-PropCond $AE::ControlTypeProperty $CT::SplitButton))))))
    if ($el -and $el.Current.NativeWindowHandle) { return [RukiDialog]::Klik([IntPtr]$el.Current.NativeWindowHandle) }
  } catch {}
  return [RukiDialog]::Komanda($dlg, $id)
}

# close message boxes of the dialog, return their text
function Close-Soobshcheniya([IntPtr]$dlg) {
  $txt = @()
  foreach ($m in @(Get-SoobshcheniyaDialoga $dlg)) {
    try {
      $el = $AE::FromHandle($m)
      foreach ($t in @($el.FindAll($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Text)))) { $txt += $t.Current.Name }
    } catch {}
    if (-not $txt) { $txt += [RukiDialog]::Tekst($m) }
    # OK / Close of a message box, then WM_CLOSE
    $null = Invoke-KnopkaDialoga $m 2
    if (-not (Wait-DialogZakryt $m 800)) { $null = Invoke-KnopkaDialoga $m 1 }
    if (-not (Wait-DialogZakryt $m 800)) { $null = [RukiDialog]::Zakryt($m); $null = Wait-DialogZakryt $m 800 }
  }
  return (($txt | Where-Object { $_ }) -join ' / ')
}

# cancel a file dialog for sure: Cancel button, WM_CLOSE, Esc
function Close-DialogFajla([IntPtr]$dlg) {
  if (-not [RukiDialog]::IsWindow($dlg)) { return $true }
  $null = Close-Soobshcheniya $dlg
  $null = Invoke-KnopkaDialoga $dlg 2
  if (Wait-DialogZakryt $dlg 2000) { return $true }
  $null = [RukiDialog]::Zakryt($dlg)
  if (Wait-DialogZakryt $dlg 1500) { return $true }
  if ([RukiOkno]::Vperyod($dlg)) { Send-Klavisha 'Esc' }
  return (Wait-DialogZakryt $dlg 1500)
}

# visible text of an element: its name, else the names of the texts inside
function Get-TekstElementa($el) {
  if (-not $el) { return '' }
  try {
    if ($el.Current.IsOffscreen) { return '' }
    $n = [string]$el.Current.Name
    if ($n.Trim()) { return $n }
    return ((@($el.FindAll($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Text))) | ForEach-Object { $_.Current.Name }) -join ' ')
  } catch { return '' }
}

# all names of text-like elements in the document (one cached request)
function Get-TekstyDokumenta($doc) {
  $c = New-OrCond @(@($CT::Text, $CT::ListItem, $CT::Button, $CT::Image, $CT::Hyperlink, $CT::Group) | ForEach-Object { New-PropCond $AE::ControlTypeProperty $_ })
  $KeshTeksta.Push()
  try { return @($doc.FindAll($TS::Descendants, $c) | ForEach-Object { $_.Cached.Name } | Where-Object { $_ }) } catch { return @() } finally { $KeshTeksta.Pop() }
}

function Test-TekstyNaStranice($doc, [string[]]$frag) {
  $vse = (Get-TekstyDokumenta $doc) -join "`n"
  foreach ($f in $frag) { if (-not $vse.Contains($f)) { return $false } }
  return $true
}

# Save / Apply / Crop / OK / Done in a modal of the page (generic cropping dialog)
function Find-KnopkaObrezki($ctx, $spec) {
  if ($spec) {
    $id = Get-PoleSpec $spec 'id'; $m = Get-PoleSpec $spec 'metka'
    $b = Find-Element $ctx.Doc $id $m 'knopka' 150
    if ($b -and $b.Current.IsEnabled -and -not $b.Current.IsOffscreen) { return $b }
    return $null
  }
  $d = Find-Dialog $ctx.Doc
  if (-not $d) { return $null }
  $imena = @('\u0421\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c', '\u041f\u0440\u0438\u043c\u0435\u043d\u0438\u0442\u044c', '\u041e\u0431\u0440\u0435\u0437\u0430\u0442\u044c', '\u0413\u043e\u0442\u043e\u0432\u043e', 'Save', 'Apply', 'Crop', 'Done', 'OK') | ForEach-Object { ([regex]::Unescape($_)).ToLowerInvariant() }
  try {
    foreach ($b in @($d.FindAll($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Button)))) {
      if ($imena -contains ([string]$b.Current.Name).Trim().ToLowerInvariant() -and $b.Current.IsEnabled) { return $b }
    }
  } catch {}
  return $null
}

function Get-PoleSpec($spec, [string]$k) {
  if ($null -eq $spec) { return $null }
  if ($spec -is [hashtable]) { return $spec[$k] }
  $p = $spec.PSObject.Properties[$k]
  if ($p) { return $p.Value }
  return $null
}

# the browser was minimised while its dialog is open: restore it (the dialog hides with it)
function Restore-Brauzer($ctx) {
  if ([RukiOkno]::IsIconic($ctx.Hwnd)) { Add-Pomeha $ctx 'okno'; Write-RukiLog 'dialog: brauzer svernut, vosstanavlivayu'; $null = [RukiOkno]::ShowWindow($ctx.Hwnd, 9); Start-Sleep -Milliseconds 300 }
}

# open the dialog from the page; returns the dialog hwnd or Zero
function Open-DialogFajla($ctx, $shag) {
  for ($pop = 1; $pop -le 3; $pop++) {
    $el = Find-V $ctx $shag 'fajl'
    if (-not $el) { return [pscustomobject]@{ Dlg = [IntPtr]::Zero; Prichina = 'net-elementa' } }
    $null = Confirm-OknoVidimo $ctx.Hwnd
    $p = $null
    $sposob = 'invoke'
    if ($pop -lt 3 -and $el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) {
      try { $p.Invoke() } catch { $sposob = 'klik' }
    } else { $sposob = 'klik' }
    if ($sposob -eq 'klik') {
      try { $null = Show-VidimoDlyaKlika $el } catch {}
      if (-not (Invoke-KlikVElement $ctx.Hwnd $el)) { Write-RukiLog 'dialog: klik ne udalsya' }
    }
    Write-RukiLog "dialog: otkryvayu ($sposob, popytka $pop)"
    $dlg = Wait-DialogFajla $ctx.Hwnd 5000
    if ($dlg -ne [IntPtr]::Zero) { return [pscustomobject]@{ Dlg = $dlg; Prichina = $null } }
    Add-Pomeha $ctx 'dialog-ne-otkrylsya'
    Write-RukiLog 'dialog: ne poyavilsya'
  }
  return [pscustomobject]@{ Dlg = [IntPtr]::Zero; Prichina = 'dialog-ne-otkrylsya' }
}

function Show-VidimoDlyaKlika($el) {
  $p = $null
  if ($el.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$p)) { $p.ScrollIntoView(); Start-Sleep -Milliseconds 150 }
}

# the whole movement. returns @{ Status = ok|otmeneno|stop; Prichina; Podrobno; Popytki; Fajlov }
function Invoke-ZagruzkaFajla($ctx, $shag) {
  $otmena = [bool](Get-PoleSpec $shag 'otmena')
  $fajly = @(@(Get-PoleSpec $shag 'fajly') | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
  if (-not $otmena) {
    if ($fajly.Count -eq 0) { return @{ Status = 'stop'; Prichina = 'net-fajlov-v-plane' } }
    foreach ($f in $fajly) {
      # a missing file is an honest stop before any dialog is opened
      if (-not [IO.Path]::IsPathRooted($f) -or -not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Write-RukiLog "fajl ne najden: $([IO.Path]::GetFileName($f))"
        return @{ Status = 'stop'; Prichina = 'net-fajla'; Podrobno = [IO.Path]::GetFileName($f) }
      }
    }
    $papki = @($fajly | ForEach-Object { [IO.Path]::GetDirectoryName($_) } | Select-Object -Unique)
    if ($papki.Count -gt 1) { return @{ Status = 'stop'; Prichina = 'raznye-papki' } }
  }
  # a dialog left over from before blocks the page: cancel it first
  foreach ($d in @(Get-DialogiFajla $ctx.Hwnd)) { Add-Pomeha $ctx 'staryj-dialog'; $null = Close-DialogFajla $d }

  $zhdat = Get-PoleSpec $shag 'zhdat_ms'; if (-not $zhdat) { $zhdat = 15000 }
  $imena = @($fajly | ForEach-Object { [IO.Path]::GetFileName($_) })
  $prov = Get-PoleSpec $shag 'proverka'
  $frag = @(Get-PoleSpec $prov 'soderzhit'); if (-not ($frag | Where-Object { $_ })) { $frag = $imena }
  $obrSpec = Get-PoleSpec $shag 'obrezka'
  $otkazSpec = Get-PoleSpec $shag 'otkaz'

  for ($pop = 1; $pop -le 2; $pop++) {
    $o = Open-DialogFajla $ctx $shag
    if ($o.Dlg -eq [IntPtr]::Zero) { return @{ Status = 'stop'; Prichina = $o.Prichina; Popytki = $pop } }
    $dlg = $o.Dlg
    Restore-Brauzer $ctx
    Write-RukiLog "dialog: otkryt, zagolovok '$([RukiDialog]::Tekst($dlg))'"
    if ($otmena) {
      if (Close-DialogFajla $dlg) { return @{ Status = 'otmeneno'; Popytki = $pop; Fajlov = 0 } }
      return @{ Status = 'stop'; Prichina = 'dialog-ne-zakrylsya'; Popytki = $pop }
    }
    $pole = Get-PoleImeni $dlg
    if (-not $pole) {
      try { foreach ($l in @(Get-DampDereva ($AE::FromHandle($dlg)) 0 7 | Select-Object -First 80)) { Write-RukiLog "damp: $l" } } catch {}
      $null = Close-DialogFajla $dlg; return @{ Status = 'stop'; Prichina = 'net-polya-imeni'; Popytki = $pop }
    }
    if ($fajly.Count -gt 1) {
      # several files: go to their folder first, then name them all in quotes
      $papka = [IO.Path]::GetDirectoryName($fajly[0])
      if (-not (Set-PoleImeni $ctx $dlg $pole $papka)) { $null = Close-DialogFajla $dlg; return @{ Status = 'stop'; Prichina = 'put-ne-vstavlen'; Popytki = $pop } }
      $null = Invoke-KnopkaDialoga $dlg 1
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while ($sw.ElapsedMilliseconds -lt 3000 -and (Get-Znachenie $pole) -ceq $papka) { Start-Sleep -Milliseconds 100 }
      Start-Sleep -Milliseconds 300
      if (-not [RukiDialog]::IsWindow($dlg)) { return @{ Status = 'stop'; Prichina = 'dialog-zakrylsya-na-papke'; Popytki = $pop } }
      $pole = Get-PoleImeni $dlg
      $znach = ($imena | ForEach-Object { '"' + $_ + '"' }) -join ' '
    } else { $znach = $fajly[0] }
    if (-not $pole -or -not (Set-PoleImeni $ctx $dlg $pole $znach)) { $null = Close-DialogFajla $dlg; return @{ Status = 'stop'; Prichina = 'put-ne-vstavlen'; Popytki = $pop } }
    $null = Invoke-KnopkaDialoga $dlg 1
    if (-not (Wait-DialogZakryt $dlg 4000)) {
      $soob = Close-Soobshcheniya $dlg
      Write-RukiLog "dialog: ne zakrylsya posle Otkryt; soobshchenie '$soob'"
      $null = Close-DialogFajla $dlg
      if ($soob) { return @{ Status = 'stop'; Prichina = 'dialog-otklonil'; Podrobno = $soob; Popytki = $pop } }
      Add-Pomeha $ctx 'dialog-ne-prinyal'
      continue
    }
    Write-RukiLog "dialog: zakryt, zhdu stranicu ($($frag.Count) primet)"
    # the page reacts: cropping modal, rejection, or the file names show up
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $obrezano = $false
    do {
      Restore-Brauzer $ctx
      if ($otkazSpec) {
        $ot = Find-Element $ctx.Doc (Get-PoleSpec $otkazSpec 'id') (Get-PoleSpec $otkazSpec 'metka') 'fajl' 100
        $ott = Get-TekstElementa $ot
        if ($ott.Trim()) { return @{ Status = 'stop'; Prichina = 'stranica-otklonila'; Podrobno = $ott; Popytki = $pop } }
      }
      $b = Find-KnopkaObrezki $ctx $obrSpec
      if ($b) {
        Write-RukiLog "obrezka: nazhimayu '$($b.Current.Name)'"
        Add-Pomeha $ctx 'obrezka'
        try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { $null = Invoke-KlikVElement $ctx.Hwnd $b }
        $obrezano = $true
        Start-Sleep -Milliseconds 300
        continue
      }
      if (Test-TekstyNaStranice $ctx.Doc $frag) {
        # a cropping modal named in the plan must have been passed
        if ($obrSpec -and -not $obrezano) { Write-RukiLog 'obrezka ozhidalas, no ne vstretilas' }
        return @{ Status = 'ok'; Popytki = $pop; Fajlov = $fajly.Count }
      }
      Start-Sleep -Milliseconds 200
    } while ($sw.ElapsedMilliseconds -lt $zhdat)
    return @{ Status = 'stop'; Prichina = 'stranica-ne-poluchila'; Popytki = $pop }
  }
  return @{ Status = 'stop'; Prichina = 'dialog-ne-prinyal'; Popytki = 2 }
}
