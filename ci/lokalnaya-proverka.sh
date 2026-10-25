#!/usr/bin/env bash
# Checks before a push, without a desktop: hygiene, parse of all .ps1, plans as PowerShell sees them, svod on a fixture.
# usage: ci/lokalnaya-proverka.sh [path to pwsh]
set -e
cd "$(dirname "$0")/.."
PW=${1:-pwsh}
echo "[1/4] gigiena"; ./ci/proverka-gigieny.sh | tail -1
echo "[2/4] parse ps1"
"$PW" -NoProfile -c '$bad=0; foreach($f in Get-ChildItem -Recurse -Filter *.ps1){ $t=$null;$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e); foreach($x in $e){ "$($f.Name):$($x.Extent.StartLineNumber) $($x.Message)"; $bad++ } }; if($bad){exit 1}; "ok"'
echo "[2b] ps1 ascii only (PS 5.1 reads BOM-less files as ANSI)"
if grep -lP '[^\x00-\x7F]' $(git ls-files '*.ps1'; git ls-files --others --exclude-standard '*.ps1'); then echo "non-ASCII in ps1"; exit 1; fi; echo ok
echo "[3/4] plans"
"$PW" -NoProfile -c 'foreach($f in Get-ChildItem plans/*.json){ $p = Get-Content -Raw -Encoding UTF8 $f | ConvertFrom-Json; if(-not $p.imya -or -not $p.stranica.url_soderzhit -or -not $p.shagi){ "BAD $($f.Name)"; exit 1 }; foreach($s in $p.shagi){ if($s.tip -notin "tekst","chislo","flazhok","knopka","fajl"){ "BAD tip $($s.tip) in $($f.Name)"; exit 1 } } }; "ok"'
echo "[4/4] svod on fixture"
T=$(mktemp -d); mkdir -p "$T/rez"
python3 - "$T/rez/rezultat-1.json" <<'PY'
import json,sys
pr=[{"progon":0,"seed":1000,"stranica":"parol","skill":{"ok":False,"shagi":[{"n":1,"status":"ok"}],"ostanovka":{"shag":2,"prichina":"pole-parolya"}},"proverka":{"uspeh":True,"prichina":"ok"},"log":"one line"},
    {"progon":1,"seed":1001,"stranica":"anketa","skill":{"ok":False,"shagi":[{"n":1,"status":"ok"},{"n":2,"status":"stop"}],"ostanovka":{"shag":2,"prichina":"net-elementa"}},"proverka":{"uspeh":False,"prichina":"net-itoga"},"log":["a","b"]}]
json.dump({"seed":1,"sekund":5,"progony":pr},open(sys.argv[1],"w",encoding="utf-8-sig"))
PY
python3 ci/svod.py "$T/rez" "$T/out" /nonexistent > /dev/null
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d['uspeshno']==1 and d['progonov']==2, d;print('ok', d['dolya_uspeha_proc'], d['max_seriya_shagov'])" "$T/out/itog.json"
grep -q "Pervaya oshibka" "$T/out/itog.md" && echo "md ok"
rm -rf "$T"
