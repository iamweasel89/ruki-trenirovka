# Window visibility check and bringing a window to the foreground.
if (-not ('RukiOkno' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RukiOkno {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint fl, UIntPtr ex);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint fl, int x, int y, uint d, UIntPtr ex);
  [StructLayout(LayoutKind.Sequential)] public struct PT { public int x; public int y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PT p);
  public static IntPtr RootV(int x, int y) { PT p; p.x = x; p.y = y; return GetAncestor(WindowFromPoint(p), 2); }
  public static void Klik(int x, int y) { SetCursorPos(x, y); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
  public static bool Vperyod(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9);
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return true;
    uint pid;
    uint t1 = GetWindowThreadProcessId(fg, out pid);
    uint t2 = GetCurrentThreadId();
    // a lone Alt tap lifts the foreground lock for this process
    keybd_event(0x12, 0, 0, UIntPtr.Zero);
    keybd_event(0x12, 0, 2, UIntPtr.Zero);
    bool att = false;
    if (t1 != 0 && t1 != t2) att = AttachThreadInput(t2, t1, true);
    BringWindowToTop(h);
    SetForegroundWindow(h);
    if (att) AttachThreadInput(t2, t1, false);
    return GetForegroundWindow() == h;
  }
}
'@
}

# root (top-level) window of the current foreground window
function Get-PerednijRoot {
  $fg = [RukiOkno]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return $fg }
  return [RukiOkno]::GetAncestor($fg, 2)
}

# is our window in front and not minimised right now (cheap, for a check per character)
function Test-OknoVperedi([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return $true }
  if ([RukiOkno]::IsIconic($hwnd)) { return $false }
  return (Get-PerednijRoot) -eq $hwnd
}

# returns @{ Ok; Bylo } where Bylo says whether something had to be fixed
function Confirm-OknoVidimo([IntPtr]$hwnd, [int]$popytok = 4) {
  if (-not [RukiOkno]::IsWindow($hwnd)) { return [pscustomobject]@{ Ok = $false; Bylo = 'net-okna' } }
  $bylo = $null
  for ($i = 0; $i -lt $popytok; $i++) {
    $vid = [RukiOkno]::IsWindowVisible($hwnd) -and -not [RukiOkno]::IsIconic($hwnd)
    $vper = (Get-PerednijRoot) -eq $hwnd
    if ($vid -and $vper) { return [pscustomobject]@{ Ok = $true; Bylo = $bylo } }
    if (-not $bylo) { $bylo = if (-not $vid) { 'svernuto' } else { 'ne-vperedi' } }
    Write-RukiLog "okno: $bylo, vozvrashchayu"
    $null = [RukiOkno]::Vperyod($hwnd)
    Start-Sleep -Milliseconds (120 + 80 * $i)
  }
  return [pscustomobject]@{ Ok = $false; Bylo = $bylo }
}

# real mouse click into the middle of an element, only when the point belongs to our window
# (used when UIA says the focus is right but keystrokes do not land, e.g. after a restore)
function Invoke-KlikVElement([IntPtr]$hwnd, $el) {
  try {
    $r = $el.Current.BoundingRectangle
    if ($r.IsEmpty -or $r.Width -lt 2 -or $r.Height -lt 2) { return $false }
    $x = [int]($r.Left + [Math]::Min($r.Width / 2, 40)); $y = [int]($r.Top + [Math]::Min($r.Height / 2, 12))
    if ([RukiOkno]::RootV($x, $y) -ne $hwnd) { Write-RukiLog "klik: tochka ne v nashem okne"; return $false }
    [RukiOkno]::Klik($x, $y)
    Start-Sleep -Milliseconds 120
    return $true
  } catch { return $false }
}
