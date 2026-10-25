#!/usr/bin/env bash
# Checks before a push of the wizard trainer, without a desktop: the common checks, ASCII-only .ps1,
# wizard plans as PowerShell sees them, svod-master on a fixture.
# usage: ci/lokalnaya-proverka-master.sh [path to pwsh]
set -e
cd "$(dirname "$0")/.."
PW=${1:-pwsh}
./ci/lokalnaya-proverka.sh "$PW"
echo "[m1] ascii in ps1"
if grep -lP '[^\x00-\x7F]' $(git ls-files '*.ps1'; ls skills/*.ps1 lib/*.ps1 ci/*.ps1) 2>/dev/null; then echo "NON-ASCII"; exit 1; fi; echo ok
echo "[m2] wizard plans"
"$PW" -NoProfile -c 'foreach($f in Get-ChildItem plans/master/*.json){ $p = Get-Content -Raw -Encoding UTF8 $f | ConvertFrom-Json; if($p.vid -ne "master" -or -not $p.stranica.url_soderzhit -or -not $p.svodka.zagolovok -or -not $p.final.metka -or -not $p.knopki.dalee -or -not $p.knopki.nazad){ "BAD $($f.Name)"; exit 1 }; foreach($s in $p.shagi){ if(-not $s.zagolovok){ "BAD step in $($f.Name)"; exit 1 }; foreach($q in $s.polya){ if($q.tip -notin "tekst","chislo","flazhok","vybor"){ "BAD tip $($q.tip) in $($f.Name)"; exit 1 }; if($q.tip -eq "vybor" -and (-not $q.gruppa -or -not $q.v_svodke)){ "BAD vybor in $($f.Name)"; exit 1 } } } ; if(-not (Test-Path ("polygon/" + ($p.stranica.url_soderzhit -replace "^.*/","")))){ "NO PAGE for $($f.Name)"; exit 1 } }; "ok"'
echo "[m3] svod-master on fixture"
T=$(mktemp -d); mkdir -p "$T/rez"
python3 - "$T/rez/rezultat-1.json" <<'PY'
import json,sys
pr=[{"progon":0,"seed":1,"plan":"a","skill":{"gotovo_k_otpravke":True,"shagi":[{"status":"ok"},{"status":"ok"}],"ispravleniya":[{"pole":"x"}],"vozvratov":2,"pomehi":{"okno":1}},"proverka":{"uspeh":True,"lozhnyj_uspeh":False,"tochnost_itoga":1.0,"pomehi_stranicy":["sboj"]},"log":["l"]},
    {"progon":1,"seed":2,"plan":"b","skill":{"shagi":[{"status":"ok"},{"status":"stop"}],"ostanovka":{"prichina":"net-knopki"}},"proverka":{"uspeh":False,"prichina":"skill-ne-doshel"},"log":"one"}]
json.dump({"seed":1,"sekund":5,"progony":pr},open(sys.argv[1],"w",encoding="utf-8-sig"))
PY
python3 ci/svod-master.py "$T/rez" "$T/out" /nonexistent > /dev/null
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d['uspeshno']==1 and d['progonov']==2 and d['max_seriya_stranic']==3 and d['vozvratov_nazad']==2, d;print('ok', d['dolya_uspeha_proc'], d['max_seriya_stranic'])" "$T/out/itog.json"
rm -rf "$T"
