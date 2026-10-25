# Generic skill: go through a multi-step wizard by a JSON plan (plans\master\*.json).
# Knows the step by its heading, fills it, handles validation messages by the plan
# (a foreseen message -> the plan's corrected value; a transient one -> press again;
# anything else -> an honest stop), goes back to correct when the summary disagrees
# with the plan, checks the summary against the WHOLE plan and stops BEFORE the final
# button with a ready description of what will be sent and a ticket (hash of it).
#   -Rezhim do-finala   (default) fill everything, stop before the final button
#   -Rezhim otpravka -Bilet <hash>   re-read the summary; press the final button once,
#                       only if what is shown is exactly what the ticket was issued for
# Output: JSON with steps, corrections, the description (itog) and where it stopped and why.
param(
  [Parameter(Mandatory = $true)][string]$Plan,
  [Parameter(Mandatory = $true)][string]$Vyhod,
  [ValidateSet('do-finala', 'otpravka')][string]$Rezhim = 'do-finala',
  [string]$Bilet = '',
  [int]$TimeoutStranicyMs = 25000,
  [int]$TerpenieMs = 15000,
  [int]$TishinaMs = 1700,
  [int]$LimitMs = 270000
)
$ErrorActionPreference = 'Continue'
$koren = Split-Path -Parent $PSScriptRoot
. (Join-Path $koren 'lib\uia.ps1')
. (Join-Path $koren 'lib\okno.ps1')
. (Join-Path $koren 'lib\vvod.ps1')
. (Join-Path $koren 'lib\master.ps1')

$sw = [Diagnostics.Stopwatch]::StartNew()
$Uni = { param($s) [regex]::Unescape($s) }
Write-RukiLog "start master plan=$Plan rezhim=$Rezhim"
$pl = $null
try { $pl = Get-Content -Raw -Encoding UTF8 -ErrorAction Stop $Plan | ConvertFrom-Json } catch { Write-RukiLog "plan ne prochitan: $($_.Exception.Message)" }
$planOk = $pl -and $pl.stranica -and $pl.stranica.url_soderzhit -and @($pl.shagi).Count -gt 0 -and $pl.svodka -and $pl.svodka.zagolovok -and $pl.final -and $pl.final.metka -and $pl.knopki.dalee -and $pl.knopki.nazad
if ($planOk) { foreach ($s0 in @($pl.shagi)) { if (-not $s0.zagolovok -or @($s0.polya).Count -eq 0) { $planOk = $false } } }
if (-not $planOk) {
  ([ordered]@{ plan = $Plan; rezhim = $Rezhim; ok = $false; gotovo_k_otpravke = $false; otpravleno = $false; shagi = @(); ostanovka = [ordered]@{ shag = ''; prichina = 'plan-nekorrekten' }; pomehi = @{}; ms = [int]$sw.ElapsedMilliseconds } | ConvertTo-Json -Depth 4) | Out-File -FilePath $Vyhod -Encoding utf8
  exit 0
}
$rez = [ordered]@{ plan = $pl.imya; rezhim = $Rezhim; ok = $false; gotovo_k_otpravke = $false; otpravleno = $false
  shagi = @(); ostanovka = $null; ispravleniya = @(); vozvratov = 0; svodka_krugov = 0; itog = $null; bilet = $null; pomehi = @{}; ms = 0 }
$ctx = @{ Doc = $null; Okno = $null; Hwnd = [IntPtr]::Zero; Url = $null; Plan = $pl; Pomehi = @{}; EstParol = $false
          TerpenieMs = $TerpenieMs; PoslednijVvod = [Environment]::TickCount; NuzhenKlik = $false; Cel = @{} }

function Save-Rez {
  $rez.ms = [int]$sw.ElapsedMilliseconds
  $rez.pomehi = $ctx.Pomehi
  ($rez | ConvertTo-Json -Depth 8) | Out-File -FilePath $Vyhod -Encoding utf8
}
function Stop-Skill([string]$zag, [string]$prichina, [string]$podrobno = '') {
  $rez.ostanovka = [ordered]@{ shag = $zag; prichina = $prichina; podrobno = $podrobno }
  Write-RukiLog "STOP shag=$zag $prichina $podrobno"
  Save-Rez
  exit 0
}

$o = Wait-Stranica $pl.stranica $TimeoutStranicyMs
if (-not $o) { Stop-Skill '' 'net-stranicy' }
$ctx.Doc = $o.Doc; $ctx.Okno = $o.Okno; $ctx.Hwnd = $o.Hwnd; $ctx.Url = $o.Url
$v = Confirm-OknoVidimo $ctx.Hwnd
if (-not $v.Ok) { Stop-Skill '' 'okno-ne-vidno' $v.Bylo }

# ---- values: the plan value, or the corrected one after a foreseen message
function Get-Cel($pole) { if ($ctx.Cel.ContainsKey([string]$pole.id)) { return $ctx.Cel[[string]$pole.id] } return $pole.znachenie }
function Get-Klyuch($pole) { if ($pole.tip -eq 'vybor') { return [string]$pole.gruppa } return [string]$pole.id }
function Get-MetkaSvodki($pole) { if ($pole.v_svodke) { return [string]$pole.v_svodke } return [string]$pole.metka }
function Get-Pokaz($pole, $cel) {
  switch ($pole.tip) {
    'flazhok' { if ([bool]$cel) { return [string]$pl.svodka.da } return [string]$pl.svodka.net }
    'vybor' { return [string]$pole.metka }
    default {
      $t = ([string]$cel -replace '\s+', ' ').Trim()
      if (-not $t) { if ($pl.svodka.pusto) { return [string]$pl.svodka.pusto } return '' }
      return $t
    }
  }
}

function Invoke-Pole($pole) {
  $p2 = $pole.PSObject.Copy()
  $p2.znachenie = Get-Cel $pole
  switch ($pole.tip) {
    { $_ -in 'tekst', 'chislo' } { return Set-Tekst $ctx $p2 }
    'flazhok' { return Set-Flazhok $ctx $p2 }
    'vybor' { return Set-Vybor $ctx $p2 }
    default { return @{ Status = 'stop'; Prichina = 'neizvestnyj-tip' } }
  }
}

function Test-PoleVNorme($pole) {
  $el = Find-Element $ctx.Doc $pole.id $pole.metka $pole.tip 2500
  if (-not $el) { $el = Find-V $ctx $pole $pole.tip }
  if (-not $el) { return $false }
  $cel = Get-Cel $pole
  switch ($pole.tip) {
    'vybor' { return (Test-Vybrano $el) }
    'flazhok' { return ((Get-ZnachenieUstojchivo $el) -ceq [bool]$cel) }
    default { return ((Get-ZnachenieUstojchivo $el) -ceq (([string]$cel) -replace "`r`n", "`n")) }
  }
}

# reconcile the fields of the current step with the plan after a quiet pause; fix what drifted
function Sync-Shag($polya) {
  for ($k = 1; $k -le 4; $k++) {
    $proshlo = [Environment]::TickCount - $ctx.PoslednijVvod
    if ($proshlo -lt $TishinaMs -and $proshlo -ge 0) { Start-Sleep -Milliseconds ($TishinaMs - $proshlo) }
    $ispr = 0
    foreach ($p in @($polya)) {
      if (Test-PoleVNorme $p) { continue }
      Write-RukiLog "sverka: $($p.id) razoshlos"
      Add-Pomeha $ctx 'sverka-ispravila'
      $ispr++
      $r = Invoke-Pole $p
      if ($r.Status -ne 'ok') { return $r }
    }
    if ($ispr -eq 0) { return @{ Status = 'ok' } }
  }
  return @{ Status = 'stop'; Prichina = 'forma-ne-ustoyalas' }
}

function Press-Knopka($spec, $polya, [switch]$Final) {
  for ($pop = 1; $pop -le 4; $pop++) {
    if (@($polya).Count) { $s = Sync-Shag $polya; if ($s.Status -ne 'ok') { return $s } }
    $b = Find-V $ctx $spec 'knopka'
    if (-not $b) { return @{ Status = 'stop'; Prichina = 'net-knopki' } }
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not $b.Current.IsEnabled -and $t.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 150 }
    if (-not $b.Current.IsEnabled) { Write-RukiLog "knopka $($spec.metka) neaktivna"; continue }
    if (Find-Dialog $ctx.Doc) { $null = Close-Dialog $ctx; continue }
    $ok = Confirm-OknoVidimo $ctx.Hwnd
    if ($ok.Bylo) { Add-Pomeha $ctx 'okno' }
    if (-not $ok.Ok) { continue }
    if ($Final) {
      $ns = Test-NashaStranica $ctx
      if (-not $ns.Ok) { return @{ Status = 'stop'; Prichina = 'ne-nasha-stranica' } }
    }
    try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    catch { if ($Final) { return @{ Status = 'stop'; Prichina = 'final-ne-nazhat' } }; try { if (Test-OknoVperedi $ctx.Hwnd) { $b.SetFocus(); Send-Klavisha 'Enter' } } catch {} }
    return @{ Status = 'ok'; Popytki = $pop }
  }
  return @{ Status = 'stop'; Prichina = 'knopka-ne-srabotala' }
}

# wait until a step heading shows (the transition may leave the page without one for a while)
function Wait-Shag([int]$ms = 15000) {
  $t = [Diagnostics.Stopwatch]::StartNew()
  do {
    $c = Get-TekushchijShag $ctx
    if ($c.Vid -in 'shag', 'svodka') { return $c }
    if ($c.Vid -eq 'neizvesten' -and $t.ElapsedMilliseconds -gt 2500) { return $c }
    if (Find-Dialog $ctx.Doc) { $null = Close-Dialog $ctx }
    Start-Sleep -Milliseconds 200
  } while ($t.ElapsedMilliseconds -lt $ms)
  return $c
}

# after Next / Back: the heading changed, or messages appeared, or nothing happened
function Wait-Ishod([string]$bylo, [int]$ms = 15000) {
  $t = [Diagnostics.Stopwatch]::StartNew()
  do {
    $c = Get-TekushchijShag $ctx
    if ($c.Vid -ne 'net' -and $c.Tekst -ne $bylo) {
      if ($c.Vid -eq 'neizvesten' -and $t.ElapsedMilliseconds -lt 2500) { Start-Sleep -Milliseconds 200; continue }
      return @{ Vid = 'smena'; Cur = $c }
    }
    if ($c.Vid -ne 'net' -and $t.ElapsedMilliseconds -ge 500) {
      $osh = @(Get-OshibkiObzora $c.Obzor)
      if ($osh.Count) { return @{ Vid = 'oshibki'; Osh = $osh; Cur = $c } }
    }
    Start-Sleep -Milliseconds 200
  } while ($t.ElapsedMilliseconds -lt $ms)
  return @{ Vid = 'nichego' }
}

function Test-Soderzhit([string]$tekst, [string]$chast) { return $chast -and ($tekst.IndexOf($chast, [StringComparison]::OrdinalIgnoreCase) -ge 0) }

# the summary against the whole plan: every field of every (unconditional) step, by its label
function Test-Svodka($obzor, [switch]$DopuskAlt) {
  $stroki = Get-StrokiObzora $obzor
  $para = @{}
  foreach ($s in $stroki) { $i = $s.IndexOf(': '); if ($i -gt 0) { $k = $s.Substring(0, $i).Trim(); if (-not $para.ContainsKey($k)) { $para[$k] = $s.Substring($i + 2).Trim() } } elseif ($s.EndsWith(':')) { $k = $s.TrimEnd(':').Trim(); if (-not $para.ContainsKey($k)) { $para[$k] = '' } } }
  $rash = @(); $polya = @(); $izv = @()
  foreach ($sh in @($pl.shagi)) {
    foreach ($p in @($sh.polya)) {
      $m = Get-MetkaSvodki $p
      $izv += $m
      $cel = Get-Cel $p
      $zhd = Get-Pokaz $p $cel
      if (-not $para.ContainsKey($m)) {
        if ($sh.uslovnyj) { continue }
        $rash += [ordered]@{ id = [string]$p.id; metka = $m; zhdali = $zhd; vidim = $null; shag = [string]$sh.zagolovok }
        continue
      }
      $vid = $para[$m]
      $ok = ($vid -ceq $zhd)
      $znach = $cel
      if (-not $ok -and $DopuskAlt) {
        foreach ($alt in @($p.pri_oshibke)) { if ($alt -and (Get-Pokaz $p $alt.znachenie) -ceq $vid) { $ok = $true; $znach = $alt.znachenie } }
      }
      if (-not $ok) { $rash += [ordered]@{ id = [string]$p.id; metka = $m; zhdali = $zhd; vidim = $vid; shag = [string]$sh.zagolovok }; continue }
      if ($p.tip -eq 'flazhok') { $znach = [bool]$znach } elseif ($p.tip -ne 'vybor') { $znach = [string]$znach } else { $znach = [string]$p.znachenie }
      $polya += [ordered]@{ id = (Get-Klyuch $p); metka = $m; pokaz = $vid; znachenie = $znach }
    }
  }
  $prochee = @()
  foreach ($k in $para.Keys) { if ($izv -notcontains $k) { $prochee += ($k + ': ' + $para[$k]) } }
  $prochee = @($prochee | Sort-Object)
  return @{ Rash = $rash; Polya = $polya; Prochee = $prochee }
}

function New-Itog($sv) {
  $dash = & $Uni '\u2014'; $lq = & $Uni '\u00ab'; $rq = & $Uni '\u00bb'; $ar = & $Uni '\u2192'
  $chasti = @($sv.Polya | ForEach-Object { "$($_.metka) $dash $($_.pokaz)" })
  $txt = (& $Uni '\u0418\u0442\u043e\u0433') + ": $($pl.imya). " + (& $Uni '\u0411\u0443\u0434\u0435\u0442 \u043e\u0442\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e') + ': ' + ($chasti -join '; ') + '.'
  if (@($sv.Prochee).Count) { $txt += ' ' + (& $Uni '\u0422\u0430\u043a\u0436\u0435 \u043d\u0430 \u0441\u0442\u0440\u0430\u043d\u0438\u0446\u0435') + ': ' + (@($sv.Prochee) -join '; ') + '.' }
  if (@($rez.ispravleniya).Count) {
    $ip = @($rez.ispravleniya | ForEach-Object { "$($_.metka): $lq$($_.bylo)$rq $ar $lq$($_.stalo)$rq ($($_.soobshchenie))" })
    $txt += ' ' + (& $Uni '\u0418\u0441\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e \u043f\u043e \u0441\u043e\u043e\u0431\u0449\u0435\u043d\u0438\u044f\u043c \u0441\u0430\u0439\u0442\u0430') + ': ' + ($ip -join '; ') + '.'
  }
  $txt += ' ' + (& $Uni '\u041a\u043d\u043e\u043f\u043a\u0430 \u043e\u0442\u043f\u0440\u0430\u0432\u043a\u0438') + ": $lq$($pl.final.metka)$rq."
  # the ticket binds exactly what the summary shows and the button that will be pressed
  $osnova = (@($sv.Polya | ForEach-Object { "$($_.id)|$($_.metka)|$($_.pokaz)" }) + @($sv.Prochee) + @("final|$($pl.final.metka)", "plan|$($pl.imya)")) -join "`n"
  return @{ Itog = [ordered]@{ tekst = $txt; polya = @($sv.Polya); prochee = @($sv.Prochee); knopka = [string]$pl.final.metka; ispravleniya = @($rez.ispravleniya) }; Bilet = (Get-Hash $osnova) }
}

# ---- the run
$posetil = New-Object System.Collections.Generic.List[string]
$vizity = @{}
$nShaga = 0
while ($true) {
  if ($sw.ElapsedMilliseconds -gt $LimitMs) { Stop-Skill '' 'vremya-vyshlo' }
  $cur = Wait-Shag
  if ($cur.Vid -eq 'net') { Stop-Skill '' 'net-shaga' ("zagolovki: " + (@($cur.Zagolovki) -join ' / ')) }
  if ($cur.Vid -eq 'neizvesten') { Stop-Skill $cur.Tekst 'shag-ne-predusmotren' $cur.Tekst }

  if ($cur.Vid -eq 'svodka') {
    Write-RukiLog "svodka: $($cur.Tekst)"
    if ($Rezhim -eq 'otpravka') {
      $sv = Test-Svodka $cur.Obzor -DopuskAlt
      if (@($sv.Rash).Count) { Stop-Skill $cur.Tekst 'svodka-ne-soshlas' (@($sv.Rash | ForEach-Object { "$($_.metka): zhdali '$($_.zhdali)' vidim '$($_.vidim)'" }) -join '; ') }
      $it = New-Itog $sv
      $rez.itog = $it.Itog; $rez.bilet = $it.Bilet
      if (-not $Bilet) { Stop-Skill $cur.Tekst 'net-bileta' }
      if ($it.Bilet -ne $Bilet) { Stop-Skill $cur.Tekst 'bilet-ne-sovpal' 'svodka izmenilas posle vydachi bileta' }
      $r = Press-Knopka $pl.final @() -Final
      if ($r.Status -ne 'ok') { Stop-Skill $cur.Tekst $r.Prichina }
      Write-RukiLog "final nazhata: $($pl.final.metka)"
      $posle = $pl.final.posle
      $el = if ($posle) { Find-Element $ctx.Doc $posle.id $posle.metka $posle.tip 20000 } else { $null }
      # a final button is never pressed twice: no confirmation means an honest stop
      if ($posle -and -not $el) { Stop-Skill $cur.Tekst 'net-podtverzhdeniya' }
      $rez.otpravleno = $true; $rez.ok = $true
      Save-Rez
      exit 0
    }
    $sv = Test-Svodka $cur.Obzor
    if (@($sv.Rash).Count -eq 0) {
      $it = New-Itog $sv
      $rez.itog = $it.Itog; $rez.bilet = $it.Bilet
      $rez.ok = $true; $rez.gotovo_k_otpravke = $true
      Write-RukiLog "gotovo k otpravke, bilet $($it.Bilet.Substring(0, 12))"
      Save-Rez
      exit 0
    }
    $rez.svodka_krugov++
    $opis = (@($sv.Rash | ForEach-Object { "$($_.metka): zhdali '$($_.zhdali)' vidim '$($_.vidim)'" }) -join '; ')
    Write-RukiLog "svodka razoshlas: $opis"
    if ($rez.svodka_krugov -gt 3) { Stop-Skill $cur.Tekst 'svodka-ne-soshlas' $opis }
    Add-Pomeha $ctx 'svodka-rashozhdenie'
    $cel = [string]$sv.Rash[0].shag
    if (-not $posetil.Contains($cel)) { Stop-Skill $cur.Tekst 'shag-plana-ne-pokazan' "$cel; $opis" }
    # back to the step that holds the first wrong value
    $doshli = $false
    for ($i = 0; $i -lt 12 -and -not $doshli; $i++) {
      $r = Press-Knopka $pl.knopki.nazad @()
      if ($r.Status -ne 'ok') { Stop-Skill $cur.Tekst $r.Prichina 'nazad' }
      $ish = Wait-Ishod $cur.Tekst
      if ($ish.Vid -ne 'smena') { Stop-Skill $cur.Tekst 'nazad-ne-srabotal' $ish.Vid }
      $cur = $ish.Cur
      $rez.vozvratov++
      if ($cur.Vid -eq 'shag' -and [string]$cur.Shag.zagolovok -eq $cel) { $doshli = $true }
    }
    if (-not $doshli) { Stop-Skill $cur.Tekst 'nazad-ne-doshli' $cel }
    Write-RukiLog "vernulis na shag: $cel"
    continue
  }

  # ---- an ordinary step
  if ($Rezhim -eq 'otpravka') { Stop-Skill $cur.Tekst 'net-svodki' 'v rezhime otpravki zhdali stranicu svodki' }
  $sh = $cur.Shag
  $zag = [string]$sh.zagolovok
  $vizity[$zag] = 1 + [int]$vizity[$zag]
  if ($vizity[$zag] -gt 6) { Stop-Skill $zag 'zaciklivanie' }
  if (-not $posetil.Contains($zag)) { $posetil.Add($zag) }
  $nShaga++
  $t0 = $sw.ElapsedMilliseconds
  Write-RukiLog "shag $($cur.Nomer)/$($cur.Iz): $zag"
  foreach ($p in @($sh.polya)) {
    $r = Invoke-Pole $p
    if ($r.Status -ne 'ok') {
      $rez.shagi += [ordered]@{ n = $nShaga; zagolovok = $zag; nomer = "$($cur.Nomer)/$($cur.Iz)"; status = 'stop'; ms = [int]($sw.ElapsedMilliseconds - $t0) }
      Stop-Skill $zag $r.Prichina "pole $($p.id)"
    }
  }
  $dalee = if ($sh.dalee) { $sh.dalee } else { $pl.knopki.dalee }
  $povtorov = 0; $pustyh = 0; $ispr = 0; $prinyat = $false
  for ($pop = 1; $pop -le 7 -and -not $prinyat; $pop++) {
    $r = Press-Knopka $dalee @($sh.polya)
    if ($r.Status -ne 'ok') { Stop-Skill $zag $r.Prichina 'dalee' }
    $ish = Wait-Ishod $cur.Tekst
    if ($ish.Vid -eq 'smena') { $prinyat = $true; break }
    if ($ish.Vid -eq 'nichego') { $pustyh++; Write-RukiLog "dalee bez otveta ($pustyh)"; if ($pustyh -ge 2) { Stop-Skill $zag 'dalee-bez-otveta' }; continue }
    $nepon = @()
    foreach ($msg in @($ish.Osh)) {
      Write-RukiLog "soobshchenie: $msg"
      $ponyal = $false
      foreach ($pv in @($pl.povtoryat_pri)) { if (Test-Soderzhit $msg $pv) { $ponyal = $true } }
      if ($ponyal) { $povtorov++; Add-Pomeha $ctx 'povtor-po-soobshcheniyu'; if ($povtorov -gt 3) { $nepon += $msg }; continue }
      foreach ($p in @($sh.polya)) {
        if ($ponyal) { break }
        foreach ($pr in @($p.pri_oshibke)) {
          if (-not $pr -or -not (Test-Soderzhit $msg $pr.soderzhit)) { continue }
          $bylo = Get-Cel $p
          if (([string]$bylo) -ceq ([string]$pr.znachenie)) { continue }
          $ctx.Cel[[string]$p.id] = $pr.znachenie
          $rez.ispravleniya += [ordered]@{ pole = [string]$p.id; metka = (Get-MetkaSvodki $p); bylo = [string]$bylo; stalo = [string]$pr.znachenie; soobshchenie = $msg }
          Write-RukiLog "ispravlenie po planu: $($p.id)"
          $ispr++
          $r2 = Invoke-Pole $p
          if ($r2.Status -ne 'ok') { Stop-Skill $zag $r2.Prichina "pole $($p.id)" }
          $ponyal = $true; break
        }
      }
      if ($ponyal) { continue }
      # the message names a field of this step whose value has drifted: the reconcile before the next press fixes it
      foreach ($p in @($sh.polya)) {
        if ((Test-Soderzhit $msg ([string]$p.metka)) -and -not (Test-PoleVNorme $p)) { $ponyal = $true; Add-Pomeha $ctx 'soobshchenie-o-sbitom-pole' }
      }
      if (-not $ponyal) { $nepon += $msg }
    }
    if ($nepon.Count) {
      $rez.shagi += [ordered]@{ n = $nShaga; zagolovok = $zag; nomer = "$($cur.Nomer)/$($cur.Iz)"; status = 'stop'; ms = [int]($sw.ElapsedMilliseconds - $t0) }
      Stop-Skill $zag 'oshibka-ne-predusmotrena' ($nepon -join ' | ')
    }
  }
  if (-not $prinyat) { Stop-Skill $zag 'shag-ne-prinyat' }
  $rez.shagi += [ordered]@{ n = $nShaga; zagolovok = $zag; nomer = "$($cur.Nomer)/$($cur.Iz)"; status = 'ok'; ispravlenij = $ispr; povtorov = $povtorov; ms = [int]($sw.ElapsedMilliseconds - $t0) }
  Save-Rez
}
