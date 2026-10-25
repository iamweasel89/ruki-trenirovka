#!/usr/bin/env python3
"""Aggregate disturbance-training results into itog.json + itog.md.
usage: svod-pomehi.py <dir with rezultat-*.json> <out dir> [jobs.json from the API]
Measures:
  vosstanovleno   - runs with at least one disturbance where the page got exactly the plan
                    (or, on the password page, the expected stop with nothing typed)
  chestno         - runs where the skill's own verdict agrees with the page (success or honest stop)
  lozhnyj_uspeh   - skill said ok but the page does not match the plan (must be 0)
  utechka         - keystrokes reached a foreign window (must be 0)
"""
import glob, json, os, sys, collections, datetime

src, dst = sys.argv[1], sys.argv[2]
jobs_api = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(dst, exist_ok=True)


def load(p):
    with open(p, encoding='utf-8-sig') as f:
        return json.load(f)


def spisok(x):
    if x is None:
        return []
    if isinstance(x, (list, tuple)):
        return list(x)
    return [x]


raboty = []
for p in sorted(glob.glob(os.path.join(src, '**', 'rezultat-*.json'), recursive=True)):
    try:
        raboty.append(load(p))
    except Exception as e:
        raboty.append({'seed': os.path.basename(p), 'oshibka': str(e), 'progony': []})

vsego = uspeh = s_pomehami = vosst = chestno = lozh = utech = 0
prichiny = collections.Counter()
pomehi_str = collections.Counter()
pomehi_skill = collections.Counter()
okna = collections.Counter()
po_pomehe = collections.defaultdict(lambda: [0, 0])  # disturbance -> [runs, recovered]
po_stranicam = collections.defaultdict(lambda: [0, 0])
neudachi, po_rabotam = [], []
for rb in raboty:
    progony = spisok(rb.get('progony'))
    u = 0
    for pr in progony:
        vsego += 1
        sk = pr.get('skill') or {}
        prov = pr.get('proverka') or {}
        ok = bool(prov.get('uspeh'))
        st = pr.get('stranica')
        po_stranicam[st][0] += 1
        vstr = set()
        for k in spisok(prov.get('pomehi_stranicy')):
            pomehi_str[k] += 1; vstr.add(k)
        for k, v in (sk.get('pomehi') or {}).items():
            pomehi_skill[k] += v
        for w in spisok(pr.get('okna')):
            k = str(w).split('@')[0]
            okna[k] += 1; vstr.add(k)
        if (sk.get('pomehi') or {}):
            vstr.add('_skill_zametil')
        if ok:
            uspeh += 1; u += 1; po_stranicam[st][1] += 1
        if vstr:
            s_pomehami += 1
            if ok:
                vosst += 1
        for k in vstr:
            po_pomehe[k][0] += 1
            if ok:
                po_pomehe[k][1] += 1
        skill_ok = bool(pr.get('skill_ok'))
        is_lozh = bool(pr.get('lozhnyj_uspeh'))
        if pr.get('utechka'):
            utech += 1
        if is_lozh:
            lozh += 1
        if ok or (not skill_ok and not prov.get('otpravleno') and sk.get('ostanovka')):
            chestno += 1
        if not ok:
            ost = sk.get('ostanovka') or {}
            pr_txt = (ost.get('prichina') if ost else None) or prov.get('prichina') or 'net-rezultata'
            if is_lozh:
                pr_txt = 'LOZHNYJ-USPEH ' + str(prov.get('prichina'))
            prichiny[f"{st}: {pr_txt}"] += 1
            neudachi.append({'seed': pr.get('seed'), 'stranica': st, 'pomehi_zadany': pr.get('pomehi_zadany'),
                             'okna': pr.get('okna'), 'ostanovka': ost, 'proverka': prov.get('prichina'),
                             'pomehi_stranicy': prov.get('pomehi_stranicy'), 'skill_pomehi': sk.get('pomehi'),
                             'log': spisok(pr.get('log'))[-25:]})
    po_rabotam.append({'seed': rb.get('seed'), 'progonov': len(progony), 'uspeh': u, 'sekund': rb.get('sekund')})

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


def proc(a, b):
    return round(100.0 * a / b, 1) if b else 0.0


itog = {
    'run': os.environ.get('GITHUB_RUN_ID'), 'sha': os.environ.get('GITHUB_SHA'),
    'progonov': vsego, 'uspeshno': uspeh, 'dolya_uspeha_proc': proc(uspeh, vsego),
    'progonov_s_pomehami': s_pomehami, 'vosstanovleno': vosst, 'dolya_vosstanovlenij_proc': proc(vosst, s_pomehami),
    'chestno': chestno, 'dolya_chestnosti_proc': proc(chestno, vsego),
    'lozhnyh_uspehov': lozh, 'utechek_v_chuzhoe_okno': utech,
    'po_pomehe': {k: {'progonov': v[0], 'vosstanovleno': v[1]} for k, v in sorted(po_pomehe.items())},
    'po_stranicam': {k: {'progonov': v[0], 'uspeh': v[1]} for k, v in po_stranicam.items()},
    'prichiny_neudach': dict(prichiny), 'pomehi_stranicy': dict(pomehi_str), 'pomehi_zamecheny_skillom': dict(pomehi_skill),
    'okna': dict(okna), 'minut_runnera': minuty, 'po_rabotam': po_rabotam, 'neudachi': neudachi[:40],
    'damp_dereva': next((rb.get('damp') for rb in raboty if rb.get('damp')), None),
}
with open(os.path.join(dst, 'itog.json'), 'w', encoding='utf-8') as f:
    json.dump(itog, f, ensure_ascii=False, indent=1)

L = ["# Itog: ustojchivost k pomeham", "", f"run {itog['run']}, commit {str(itog['sha'])[:10]}", "",
     f"- vosstanovlenij: **{itog['dolya_vosstanovlenij_proc']} %** ({vosst}/{s_pomehami} progonov s pomehami)",
     f"- chestnost (verdikt skilla = stranica): {itog['dolya_chestnosti_proc']} % ({chestno}/{vsego})",
     f"- lozhnyh uspehov: **{lozh}**, utechek v chuzhoe okno: **{utech}**",
     f"- uspeh vsego: {uspeh}/{vsego}", f"- minut runnera: {minuty}", "", "## Po pomehe (progonov / vosstanovleno)", ""]
L += [f"- {k}: {v['vosstanovleno']}/{v['progonov']}" for k, v in itog['po_pomehe'].items()]
L += ["", "## Po stranicam", ""] + [f"- {k}: {v['uspeh']}/{v['progonov']}" for k, v in sorted(itog['po_stranicam'].items())]
L += ["", "## Prichiny neudach", ""] + ([f"- {k}: {v}" for k, v in prichiny.most_common()] or ["- net"])
L += ["", "## Pomehi, zamechennye skillom", ""] + [f"- {k}: {v}" for k, v in sorted(pomehi_skill.items())]
L += ["", "## Po rabotam", ""] + [f"- seed {r['seed']}: {r['uspeh']}/{r['progonov']}, {r['sekund']} s" for r in po_rabotam]
with open(os.path.join(dst, 'itog.md'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(L) + '\n')
print('\n'.join(L))
