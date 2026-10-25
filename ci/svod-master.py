#!/usr/bin/env python3
"""Aggregate wizard training results into itog.json + itog.md.
usage: svod-master.py <dir with rezultat-*.json> <out dir> [jobs.json from the API]"""
import glob, json, os, sys, collections, datetime

src, dst = sys.argv[1], sys.argv[2]
jobs_api = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(dst, exist_ok=True)

def load(p):
    with open(p, encoding='utf-8-sig') as f:
        return json.load(f)

def spisok(x):
    if x is None: return []
    return x if isinstance(x, list) else [x]

faily = sorted(glob.glob(os.path.join(src, '**', 'rezultat-*.json'), recursive=True))
etap = 'matrica' if any('dym' not in os.path.basename(p) for p in faily) else 'dym'
raboty = []
for p in faily:
    try:
        rb = load(p); rb['_fail'] = os.path.basename(p); raboty.append(rb)
    except Exception as e:
        raboty.append({'seed': os.path.basename(p), 'oshibka': str(e), 'progony': [], '_fail': os.path.basename(p)})

vsego = uspeh = lozh = rano = 0
tochn = []
prichiny = collections.Counter()
pomehi = collections.Counter()
po_planam = collections.defaultdict(lambda: [0, 0])
serii, po_rabotam, neudachi = [], [], []
ispravlenij = vozvratov = stranic_ok = audit_ispr = audit_polej = 0
for rb in raboty:
    seriya = best = u = 0
    for pr in spisok(rb.get('progony')):
        vsego += 1
        sk = pr.get('skill') or {}
        prov = pr.get('proverka') or {}
        ok = bool(prov.get('uspeh'))
        pl = pr.get('plan')
        po_planam[pl][0] += 1
        if ok:
            uspeh += 1; u += 1; po_planam[pl][1] += 1
        if prov.get('lozhnyj_uspeh'): lozh += 1
        if prov.get('rano_otpravleno'): rano += 1
        if prov.get('tochnost_itoga') is not None: tochn.append(prov['tochnost_itoga'])
        for k, v in (sk.get('pomehi') or {}).items(): pomehi['skill:' + k] += v
        for k in spisok(prov.get('pomehi_stranicy')): pomehi['stranica:' + k] += 1
        if pr.get('okno_pomeha'): pomehi['okno-zapusk'] += 1
        ispravlenij += len(spisok(sk.get('ispravleniya')))
        vozvratov += int(sk.get('vozvratov') or 0)
        pp = sk.get('proverka_polej') or {}
        audit_ispr += int(pp.get('ispravleno') or 0); audit_polej += int(pp.get('polej') or 0)
        for sh in spisok(sk.get('shagi')):
            if sh.get('status') == 'ok':
                stranic_ok += 1; seriya += 1; best = max(best, seriya)
        if not ok:
            seriya = 0
            ost = sk.get('ostanovka') or {}
            k = f"{pl}: {ost.get('prichina') or '-'} / {prov.get('prichina')}"
            prichiny[k] += 1
            neudachi.append({'seed': pr.get('seed'), 'plan': pl, 'kluch': k, 'ostanovka': ost, 'proverka': prov.get('prichina'),
                             'otpravka': (pr.get('otpravka') or {}).get('ostanovka'), 'log': spisok(pr.get('log'))[-24:]})
    serii.append(best)
    po_rabotam.append({'fail': rb.get('_fail'), 'seed': rb.get('seed'), 'progonov': len(spisok(rb.get('progony'))), 'uspeh': u, 'max_seriya_stranic': best, 'sekund': rb.get('sekund'), 'oshibka': rb.get('oshibka')})

minuty = None
if jobs_api and os.path.exists(jobs_api):
    try:
        tot = 0.0
        for j in load(jobs_api).get('jobs', []):
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
    'progonov': vsego, 'uspeshno': uspeh, 'dolya_uspeha_proc': dolya, 'lozhnyh_uspehov': lozh, 'rano_otpravleno': rano,
    'tochnost_itoga_srednyaya': round(sum(tochn) / len(tochn), 3) if tochn else None, 'izmereno_tochnost': len(tochn),
    'stranic_projdeno': stranic_ok, 'max_seriya_stranic': max(serii or [0]),
    'srednyaya_max_seriya': round(sum(serii) / len(serii), 1) if serii else 0,
    'ispravlenij_po_soobshcheniyam': ispravlenij, 'vozvratov_nazad': vozvratov, 'proverka_polej': {'provereno': audit_polej, 'ispravleno': audit_ispr},
    'po_planam': {k: {'progonov': v[0], 'uspeh': v[1]} for k, v in po_planam.items()},
    'prichiny_neudach': dict(prichiny), 'pomehi_vstrecheno': dict(pomehi),
    'minut_runnera': minuty, 'po_rabotam': po_rabotam, 'neudachi': neudachi[:30],
    'damp_dereva': next((rb.get('damp') for rb in raboty if rb.get('damp')), None),
}
with open(os.path.join(dst, 'itog.json'), 'w', encoding='utf-8') as f:
    json.dump(itog, f, ensure_ascii=False, indent=1)

L = ["# Itog trenirovki: mastera", "", f"run {itog['run']}, commit {str(itog['sha'])[:10]}, etap: {etap}", "",
     f"- progonov: {vsego}, uspeshno: {uspeh}, dolya: **{dolya} %**",
     f"- lozhnyh uspehov: **{lozh}**, otpravleno do bileta: {rano}",
     f"- tochnost itoga (opisanie vs poluchennoe): {itog['tochnost_itoga_srednyaya']} po {len(tochn)} progonam",
     f"- stranic mastera bez ostanovki podryad: max {itog['max_seriya_stranic']}, srednee po rabotam {itog['srednyaya_max_seriya']}, vsego projdeno {stranic_ok}",
     f"- ispravlenij po soobshcheniyam sajta: {ispravlenij}, vozvratov nazad: {vozvratov}",
     f"- proverka polej pered biletom: provereno {audit_polej}, ispravleno {audit_ispr}",
     f"- minut runnera: {minuty}", "", "## Po planam", ""]
L += [f"- {k}: {v['uspeh']}/{v['progonov']}" for k, v in sorted(itog['po_planam'].items())]
L += ["", "## Prichiny neudach", ""] + ([f"- {k}: {v}" for k, v in prichiny.most_common()] or ["- net"])
pervye = {}
for n in neudachi: pervye.setdefault(n['kluch'], n)
L += ["", "## Pervaya oshibka kazhdogo vida", ""]
for k, n in pervye.items():
    L.append(f"### {k} (seed {n['seed']})")
    L.append(f"- ostanovka: {json.dumps(n.get('ostanovka'), ensure_ascii=False)}; otpravka: {json.dumps(n.get('otpravka'), ensure_ascii=False)}")
    L.append("```"); L += [str(x) for x in n.get('log') or []]; L.append("```")
L += ["", "## Pomehi vstrecheno", ""] + [f"- {k}: {v}" for k, v in pomehi.most_common()]
L += ["", "## Po rabotam", ""] + [f"- {r['fail']}: {r['uspeh']}/{r['progonov']}, seriya {r['max_seriya_stranic']}, {r['sekund']} s" + (f", oshibka garnesa: {r['oshibka']}" if r.get('oshibka') else '') for r in po_rabotam]
with open(os.path.join(dst, 'itog.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(L) + '\n')
print('\n'.join(L[:16]))
