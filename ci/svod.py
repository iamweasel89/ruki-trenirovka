#!/usr/bin/env python3
"""Aggregate job results into itog.json + itog.md.
usage: svod.py <dir with rezultat-*.json> <out dir> [jobs.json from the API]"""
import glob, json, os, sys, collections, datetime

src, dst = sys.argv[1], sys.argv[2]
jobs_api = sys.argv[3] if len(sys.argv) > 3 else None
smoke_dir = sys.argv[4] if len(sys.argv) > 4 else None
os.makedirs(dst, exist_ok=True)

def load(p):
    with open(p, encoding='utf-8-sig') as f:
        return json.load(f)

etap = 'matrica'
faily = sorted(glob.glob(os.path.join(src, '**', 'rezultat-*.json'), recursive=True))
if not faily and smoke_dir:
    etap = 'smoke'
    faily = sorted(glob.glob(os.path.join(smoke_dir, '**', 'smoke-*.json'), recursive=True))
raboty = []
for p in faily:
    try:
        raboty.append(load(p))
    except Exception as e:
        raboty.append({'seed': os.path.basename(p), 'oshibka': str(e), 'progony': []})

vsego = uspeh = shagov = 0
prichiny = collections.Counter()
pomehi = collections.Counter()
po_stranicam = collections.defaultdict(lambda: [0, 0])
serii_max = []
po_rabotam = []
neudachi = []
for rb in raboty:
    progony = rb.get('progony') or []
    if isinstance(progony, dict):
        progony = [progony]
    seriya = best = 0
    u = 0
    for pr in progony:
        vsego += 1
        sk = pr.get('skill') or {}
        prov = pr.get('proverka') or {}
        ok = bool(prov.get('uspeh'))
        st = pr.get('stranica')
        po_stranicam[st][0] += 1
        if ok:
            uspeh += 1; u += 1; po_stranicam[st][1] += 1
        for k, v in (sk.get('pomehi') or {}).items():
            pomehi[k] += v
        if pr.get('okno_pomeha'):
            pomehi['okno-zapusk'] += 1
        shagi = sk.get('shagi') or []
        if isinstance(shagi, dict):
            shagi = [shagi]
        for sh in shagi:
            if sh.get('status') == 'ok':
                shagov += 1; seriya += 1; best = max(best, seriya)
        expected_stop = st == 'parol'
        if not ok:
            seriya = 0
            ost = sk.get('ostanovka') or {}
            pr_txt = (ost.get('prichina') if ost else None) or prov.get('prichina') or 'net-rezultata'
            prichiny[f"{st}: {pr_txt}"] += 1
            neudachi.append({'seed': pr.get('seed'), 'stranica': st, 'ostanovka': ost, 'proverka': prov.get('prichina'), 'log': ([pr['log']] if isinstance(pr.get('log'), str) else (pr.get('log') or []))[-14:]})
        elif not expected_stop and sk.get('ostanovka'):
            seriya = 0
    serii_max.append(best)
    po_rabotam.append({'seed': rb.get('seed'), 'progonov': len(progony), 'uspeh': u, 'max_seriya_shagov': best, 'sekund': rb.get('sekund')})

minuty = None
if jobs_api and os.path.exists(jobs_api):
    try:
        js = load(jobs_api).get('jobs', [])
        tot = 0.0
        for j in js:
            if j.get('started_at') and j.get('completed_at'):
                a = datetime.datetime.fromisoformat(j['started_at'].replace('Z', '+00:00'))
                b = datetime.datetime.fromisoformat(j['completed_at'].replace('Z', '+00:00'))
                tot += max(0, (b - a).total_seconds())
        minuty = round(tot / 60, 1)
    except Exception:
        pass

dolya = round(100.0 * uspeh / vsego, 1) if vsego else 0.0
itog = {
    'etap': etap, 'run': os.environ.get('GITHUB_RUN_ID'), 'sha': os.environ.get('GITHUB_SHA'),
    'progonov': vsego, 'uspeshno': uspeh, 'dolya_uspeha_proc': dolya,
    'shagov_ok': shagov, 'max_seriya_shagov': max(serii_max or [0]),
    'srednyaya_max_seriya': round(sum(serii_max) / len(serii_max), 1) if serii_max else 0,
    'po_stranicam': {k: {'progonov': v[0], 'uspeh': v[1]} for k, v in po_stranicam.items()},
    'prichiny_neudach': dict(prichiny), 'pomehi_vstrecheno': dict(pomehi),
    'minut_runnera_matrica': minuty, 'po_rabotam': po_rabotam, 'neudachi': neudachi[:30],
    'primer_progona': (raboty[0].get('progony') or [None])[0] if raboty else None,
    'damp_dereva': next((rb.get('damp') for rb in raboty if rb.get('damp')), None),
}
with open(os.path.join(dst, 'itog.json'), 'w', encoding='utf-8') as f:
    json.dump(itog, f, ensure_ascii=False, indent=1)

L = [f"# Itog trenirovki ruk", "",
     f"run {itog['run']}, commit {str(itog['sha'])[:10]}, etap: {etap}", "",
     f"- progonov: {vsego}, uspeshno: {uspeh}, dolya: **{dolya} %**",
     f"- shagov bez ostanovki podryad: max {itog['max_seriya_shagov']}, srednee po rabotam {itog['srednyaya_max_seriya']}",
     f"- shagov ok vsego: {shagov}",
     f"- minut runnera (matrica): {minuty}", "", "## Po stranicam", ""]
for k, v in sorted(itog['po_stranicam'].items()):
    L.append(f"- {k}: {v['uspeh']}/{v['progonov']}")
L += ["", "## Prichiny neudach", ""] + [f"- {k}: {v}" for k, v in prichiny.most_common()] or ["- net"]
pervye = {}
for n in neudachi:
    k = f"{n['stranica']}: {(n.get('ostanovka') or {}).get('prichina') or n.get('proverka')}"
    pervye.setdefault(k, n)
L += ["", "## Pervaya oshibka kazhdogo vida", ""]
for k, n in pervye.items():
    L.append(f"### {k} (seed {n['seed']})")
    L.append(f"- proverka: {n.get('proverka')}; ostanovka: {json.dumps(n.get('ostanovka'), ensure_ascii=False)}")
    L.append("```")
    L += [str(x) for x in (n.get('log') or [])]
    L.append("```")
L += ["", "## Pomehi vstrecheno", ""] + [f"- {k}: {v}" for k, v in pomehi.most_common()]
L += ["", "## Po rabotam", ""] + [f"- seed {r['seed']}: {r['uspeh']}/{r['progonov']}, seriya {r['max_seriya_shagov']}, {r['sekund']} s" for r in po_rabotam]
with open(os.path.join(dst, 'itog.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(L) + '\n')
print('\n'.join(L))
