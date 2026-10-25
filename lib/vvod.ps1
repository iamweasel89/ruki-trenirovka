# Keyboard input: SendInput KEYEVENTF_UNICODE with a focus check before each chunk
# and read-back after it. Keys Enter / Tab / Esc. Stop on a password field.
if (-not ('RukiKlav' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RukiKlav {
  [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk; public ushort sc; public uint fl; public uint t; public IntPtr ex; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct IN { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KI ki; }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, IN[] i, int s);
  static int Sz() { return Marshal.SizeOf(typeof(IN)); }
  static IN K(ushort vk, ushort sc, uint fl) { IN x = new IN(); x.type = 1; x.ki = new KI(); x.ki.vk = vk; x.ki.sc = sc; x.ki.fl = fl; return x; }
  public static uint Simvol(char ch) {
    return SendInput(2, new IN[] { K(0, ch, 4), K(0, ch, 6) }, Sz());
  }
  public static uint Klavisha(ushort vk, bool ext) {
    uint e = ext ? 1u : 0u;
    return SendInput(2, new IN[] { K(vk, 0, e), K(vk, 0, e | 2) }, Sz());
  }
  public static uint SModom(ushort mod, ushort vk, bool ext) {
    uint e = ext ? 1u : 0u;
    return SendInput(4, new IN[] { K(mod, 0, 0), K(vk, 0, e), K(vk, 0, e | 2), K(mod, 0, 2) }, Sz());
  }
}
'@
}

$script:VK = @{ Enter = 0x0D; Tab = 0x09; Esc = 0x1B; End = 0x23; Home = 0x24; Delete = 0x2E; Backspace = 0x08; A = 0x41; Ctrl = 0x11; Space = 0x20 }
$script:VKext = @{ End = $true; Home = $true; Delete = $true }

function Send-Klavisha([string]$imya) {
  switch ($imya) {
    'CtrlA'   { $null = [RukiKlav]::SModom($VK.Ctrl, $VK.A, $false); return }
    'CtrlEnd' { $null = [RukiKlav]::SModom($VK.Ctrl, $VK.End, $true); return }
    default   { $null = [RukiKlav]::Klavisha([uint16]$VK[$imya], [bool]$VKext[$imya]) }
  }
}

# types $s; with $hwnd it checks before every character that our window is still in front
# and stops at once otherwise (never type into a foreign window). returns chars typed.
function Send-Tekst([string]$s, [int]$pauza = 12, [IntPtr]$hwnd = [IntPtr]::Zero) {
  $n = 0
  foreach ($ch in $s.ToCharArray()) {
    if ($hwnd -ne [IntPtr]::Zero -and -not (Test-OknoVperedi $hwnd)) { Write-RukiLog "vvod prervan: okno ne vperedi posle $n"; return $n }
    if ($ch -eq "`n") { Send-Klavisha 'Enter' }
    elseif ($ch -eq "`r") { }
    else { $null = [RukiKlav]::Simvol($ch) }
    $n++
    Start-Sleep -Milliseconds $pauza
  }
  return $n
}

function Set-MetkaVvoda($ctx) { $ctx.PoslednijVvod = [Environment]::TickCount }

# context: @{ Doc; Okno; Hwnd; Plan; Pomehi = @{}; EstParol = bool }
function Add-Pomeha($ctx, [string]$k) {
  if (-not $ctx.Pomehi.ContainsKey($k)) { $ctx.Pomehi[$k] = 0 }
  $ctx.Pomehi[$k]++
}

# close a modal dialog: Esc first, then a button inside it
function Close-Dialog($ctx) {
  $d = Find-Dialog $ctx.Doc
  if (-not $d) { return $false }
  Add-Pomeha $ctx 'dialog'
  Write-RukiLog "dialog: $($d.Current.Name)"
  Send-Klavisha 'Esc'
  Start-Sleep -Milliseconds 250
  if (-not (Find-Dialog $ctx.Doc)) { return $true }
  try {
    $b = $d.FindFirst($TS::Descendants, (New-PropCond $AE::ControlTypeProperty $CT::Button))
    if ($b) { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
  } catch {}
  Start-Sleep -Milliseconds 250
  return -not (Find-Dialog $ctx.Doc)
}

# environment ready for typing into $el: window in front, no dialog, focus on $el
# returns 'ok', 'parol' or 'net'
function Confirm-Gotovnost($ctx, $el) {
  for ($i = 0; $i -lt 5; $i++) {
    $ok = Confirm-OknoVidimo $ctx.Hwnd
    if ($ok.Bylo) { Add-Pomeha $ctx 'okno'; $ctx.NuzhenKlik = $true }
    if (-not $ok.Ok) { continue }
    if (Find-Dialog $ctx.Doc) { $null = Close-Dialog $ctx; continue }
    if ($ctx.NuzhenKlik) {
      # after the window came back UIA may report our focus while keys go elsewhere
      $ctx.NuzhenKlik = $false
      try { $el.SetFocus() } catch {}
      # the click puts the caret where it lands: move it back to the end
      if (Invoke-KlikVElement $ctx.Hwnd $el) { Add-Pomeha $ctx 'klik-fokus'; Send-Klavisha 'CtrlEnd' }
      Start-Sleep -Milliseconds 100
    }
    $f = Get-Fokus
    if (Test-TotZhe $f $el) { return 'ok' }
    if (Test-Parol $f) { Write-RukiLog 'fokus v pole parolya' }
    Add-Pomeha $ctx 'fokus'
    try { $el.SetFocus() } catch {}
    Start-Sleep -Milliseconds (80 + 60 * $i)
    $f = Get-Fokus
    if (Test-TotZhe $f $el) { return 'ok' }
    if ($i -ge 2) { Send-Klavisha 'Esc'; Start-Sleep -Milliseconds 150 }
  }
  return 'net'
}

# read back until it equals $ozhid or times out; returns last value
function Wait-Znachenie($el, $ozhid, [int]$TimeoutMs = 1200) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $v = Get-Znachenie $el
  while ($v -cne $ozhid -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
    Start-Sleep -Milliseconds 60
    $v = Get-Znachenie $el
  }
  return $v
}

# stable read: two equal reads in a row
function Get-ZnachenieUstojchivo($el) {
  $a = Get-Znachenie $el
  for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Milliseconds 80
    $b = Get-Znachenie $el
    if ($a -ceq $b) { return $b }
    $a = $b
  }
  return $a
}

# find an element while keeping our window visible: search in slices, restore between them
function Find-V($ctx, $shag, [string]$tip) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    $ok = Confirm-OknoVidimo $ctx.Hwnd
    if ($ok.Bylo) { Add-Pomeha $ctx 'okno'; $ctx.NuzhenKlik = $true }
    $el = Find-Element $ctx.Doc $shag.id $shag.metka $tip 2500
    if ($el) { return $el }
    if (-not (Test-Zhivoj $ctx.Doc)) { return $null }
  } while ($sw.ElapsedMilliseconds -lt $ctx.TerpenieMs)
  return $null
}

# keystrokes went into a password field by accident: take back exactly the lost ones
function Undo-VParole($ctx, $el, [string]$nabrano) {
  $f = Get-Fokus
  if (-not (Test-Parol $f)) { return }
  $v = [string](Get-Znachenie $el)
  $poteryano = $nabrano.Length - $v.Length
  if (-not $nabrano.StartsWith($v) -or $poteryano -le 0) { return }
  Add-Pomeha $ctx 'otkat-v-parole'
  Write-RukiLog "otkat: $poteryano simv. ushli v pole parolya, stirayu"
  for ($i = 0; $i -lt [Math]::Min($poteryano, 16); $i++) { if (Test-OknoVperedi $ctx.Hwnd) { Send-Klavisha 'Backspace'; Start-Sleep -Milliseconds 15 } }
}

# type a value into a text-like field. returns @{ Status = ok|stop; Prichina; Popytki }
function Set-Tekst($ctx, $shag, [int]$kusok = 8) {
  $cel = ([string]$shag.znachenie) -replace "`r`n", "`n"
  for ($pop = 1; $pop -le 6; $pop++) {
    $el = Find-V $ctx $shag $shag.tip
    if (-not $el) { return @{ Status = 'stop'; Prichina = 'net-elementa'; Popytki = $pop } }
    if (-not $ctx.EstParol -and (Test-EstParolVDoc $ctx.Doc)) { $ctx.EstParol = $true }
    if (Test-Parol $el) { return @{ Status = 'stop'; Prichina = 'pole-parolya'; Popytki = $pop } }
    $g = Confirm-Gotovnost $ctx $el
    if ($g -ne 'ok') { continue }
    $tek = Get-ZnachenieUstojchivo $el
    if ($tek -ceq $cel) { return @{ Status = 'ok'; Popytki = $pop } }
    if (-not (Test-OknoVperedi $ctx.Hwnd)) { continue }
    Set-MetkaVvoda $ctx
    if ($tek -and $cel.StartsWith([string]$tek)) {
      $ost = $cel.Substring(([string]$tek).Length)
      Send-Klavisha 'CtrlEnd'
    } else {
      Send-Klavisha 'CtrlA'; Send-Klavisha 'Delete'
      if ((Wait-Znachenie $el '' 800) -cne '') { continue }
      $ost = $cel
    }
    $nabrano = $cel.Substring(0, $cel.Length - $ost.Length)
    $sboj = $false
    # careful mode on pages with a password field: focus check before every character
    $k = if ($ctx.EstParol) { 1 } else { $kusok }
    while ($ost.Length -gt 0) {
      if (-not (Test-Zhivoj $el)) { $sboj = $true; break }
      $f = Get-Fokus
      if (-not (Test-TotZhe $f $el)) {
        if (Test-Parol $f) { Add-Pomeha $ctx 'fokus-v-parol' }
        $g = Confirm-Gotovnost $ctx $el
        if ($g -ne 'ok') { $sboj = $true; break }
      }
      if (-not $ctx.EstParol -and (Find-Dialog $ctx.Doc)) { $null = Close-Dialog $ctx; $sboj = $true; break }
      $n = [Math]::Min($k, $ost.Length)
      $ch = $ost.Substring(0, $n)
      $do = [string](Get-Znachenie $el)
      $nn = Send-Tekst $ch 12 $ctx.Hwnd
      Set-MetkaVvoda $ctx
      if ($nn -lt $n) { Add-Pomeha $ctx 'vvod-prervan'; Undo-VParole $ctx $el ($nabrano + $ch.Substring(0, $nn)); $sboj = $true; break }
      $nabrano += $ch; $ost = $ost.Substring($n)
      if ($ctx.EstParol) {
        $f = Get-Fokus
        if (-not (Test-TotZhe $f $el)) { Start-Sleep -Milliseconds 60; Undo-VParole $ctx $el $nabrano; $sboj = $true; break }
      }
      if ($k -gt 1 -or $ost.Length -eq 0 -or ($nabrano.Length % 8) -eq 0) {
        $v = Wait-Znachenie $el $nabrano 900
        if ($v -cne $nabrano) {
          Write-RukiLog "sverka kuska: zhdali $($nabrano.Length), vidim $(([string]$v).Length)"
          Undo-VParole $ctx $el $nabrano
          # nothing of the chunk landed although UIA showed our focus: click into the field next time
          if ([string]$v -ceq $do) { $ctx.NuzhenKlik = $true; Add-Pomeha $ctx 'vvod-ne-doshel' }
          $sboj = $true; break
        }
      }
    }
    if ($sboj) { continue }
    $v = Wait-Znachenie $el $cel 1200
    if ($v -ceq $cel) { return @{ Status = 'ok'; Popytki = $pop } }
  }
  return @{ Status = 'stop'; Prichina = 'ne-sovpalo-posle-popytok'; Popytki = 6 }
}

function Set-Flazhok($ctx, $shag) {
  $cel = [bool]$shag.znachenie
  for ($pop = 1; $pop -le 5; $pop++) {
    $el = Find-V $ctx $shag 'flazhok'
    if (-not $el) { return @{ Status = 'stop'; Prichina = 'net-elementa'; Popytki = $pop } }
    $ok = Confirm-OknoVidimo $ctx.Hwnd
    if ($ok.Bylo) { Add-Pomeha $ctx 'okno' }
    if (Find-Dialog $ctx.Doc) { $null = Close-Dialog $ctx; continue }
    $v = Get-ZnachenieUstojchivo $el
    if ($v -ceq $cel) { return @{ Status = 'ok'; Popytki = $pop } }
    if (-not $el.Current.IsEnabled) { return @{ Status = 'stop'; Prichina = 'flazhok-nedostupen'; Popytki = $pop } }
    Set-MetkaVvoda $ctx
    try { $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() } catch { continue }
    if ((Wait-Znachenie $el $cel 1000) -ceq $cel) { return @{ Status = 'ok'; Popytki = $pop } }
  }
  return @{ Status = 'stop'; Prichina = 'flazhok-ne-ustanovlen'; Popytki = 5 }
}
