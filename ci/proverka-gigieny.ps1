# Public hygiene check: fails if any tracked file matches a pattern from gigiena-shablony.txt
$ErrorActionPreference = 'Stop'
$koren = Split-Path -Parent $PSScriptRoot
Push-Location $koren
try {
  $shabl = Get-Content -Encoding UTF8 (Join-Path $PSScriptRoot 'gigiena-shablony.txt') | Where-Object { $_ -and -not $_.StartsWith('#') }
  $faily = @(git ls-files) | Where-Object { $_ -ne 'ci/gigiena-shablony.txt' }
  $naideno = 0
  $i = 0
  foreach ($f in $faily) {
    $i++
    $n = 0
    foreach ($str in [IO.File]::ReadAllLines((Join-Path $koren $f))) {
      $n++
      foreach ($p in $shabl) {
        if ([regex]::IsMatch($str, $p, 'IgnoreCase')) { Write-Host "NAIDENO: ${f}:$n  shablon: $p"; $naideno++ }
      }
    }
  }
  Write-Host "gigiena: faylov $i, nahodok $naideno"
  if ($naideno -gt 0) { exit 1 }
} finally { Pop-Location }
