#!/usr/bin/env python3
"""Sonde TEMPORAIRE : Celcat expose-t-il l'enseignant dans la fiche détaillée d'un cours ?
Journaux publics : n'affiche QUE des noms de champs et des longueurs, jamais un contenu."""
import http.cookiejar, json, os, re, sys, urllib.parse, urllib.request, datetime
H = "https://edt.uvsq.fr"
nav = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
nav.addheaders = [("User-Agent", "Mozilla/5.0 (Macintosh) edt-maj"), ("Accept-Language", "fr-FR,fr;q=0.9")]
def appel(chemin, champs=None):
    req = urllib.request.Request(H + chemin)
    if champs is not None:
        req.data = urllib.parse.urlencode(champs).encode()
        req.add_header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
        req.add_header("X-Requested-With", "XMLHttpRequest")
    try:
        r = nav.open(req, timeout=30); return r.status, r.read().decode("utf-8", "replace")
    except Exception as e:
        return getattr(e, "code", 0), ""
_, page = appel("/LdapLogin")
jeton = re.search(r'name="__RequestVerificationToken"[^>]*value="([^"]+)"', page).group(1)
appel("/LdapLogin/Logon", {"Name": os.environ["EDT_USER"], "Password": os.environ["EDT_PASSWORD"],
                           "RememberMe": "false", "__RequestVerificationToken": jeton})
auj = datetime.date.today()
_, brut = appel("/Home/GetCalendarData", [("start", str(auj)), ("end", str(auj + datetime.timedelta(days=21))),
    ("resType", "103"), ("calView", "month"), ("federationIds[]", "MYAMS1_26"), ("colourScheme", "3")])
ev = json.loads(brut)
print("événements :", len(ev), "| champs bruts :", sorted(ev[0].keys()))
vus, choisis = set(), []
for e in ev:
    m = (e.get("modules") or [None])[0]
    if m and m not in vus: vus.add(m); choisis.append(e)
MOTS = re.compile(r"enseign|staff|personnel|prof|teacher|intervenant", re.I)
for e in choisis[:10]:
    code, txt = appel("/Home/GetSideBarEvent", {"eventId": e["id"]})
    try: d = json.loads(txt)
    except ValueError: print("module", (e.get("modules") or ["?"])[0], "-> HTTP", code, "non JSON, longueur", len(txt)); continue
    els = d.get("elements") if isinstance(d, dict) else None
    if els is None: print("clés :", sorted(d.keys()) if isinstance(d, dict) else type(d).__name__); continue
    resume = []
    for x in els:
        lab = str(x.get("label")); c = x.get("content")
        resume.append(f"{lab}[{'rempli' if c else 'vide'}{', PROF?' if MOTS.search(lab) else ''}; clés={sorted(k for k in x.keys())}]")
    print("module", (e.get("modules") or ["?"])[0], "->", " | ".join(resume))
