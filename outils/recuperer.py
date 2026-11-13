#!/usr/bin/env python3
"""Récupère les données brutes de Celcat SANS le Mac : se connecte avec un identifiant
et un mot de passe, puis écrit la réponse de GetCalendarData dans un fichier.
usage : recuperer.py <EDTKit.swift> <fichier de sortie> [profs.json]
        identifiants dans les variables d'environnement EDT_USER et EDT_PASSWORD

Tourne dans GitHub Actions, sur un dépôt PUBLIC : les journaux sont lisibles par tous.
Ce script n'affiche donc JAMAIS d'identifiant, de cookie, ni de contenu de page —
seulement l'étape atteinte. Ne pas y ajouter de trace « pour déboguer ».

La configuration (groupe, période) est lue dans EDTKit.swift pour ne pas exister en double.
"""
import datetime, html, http.cookiejar, json, os, re, sys, time, urllib.parse, urllib.request

# Enseignants. Celcat ne les met presque jamais dans la liste des cours, seulement dans la
# fiche détaillée de chaque cours : une requête par cours. On garde donc ce qu'on a déjà
# trouvé dans profs.json ({identifiant du cours: nom}) et on ne va chercher, à chaque passage,
# que les cours À VENIR encore inconnus, dans la limite de MAX_FICHES.
# Fichier à part, et non un champ de data.json : le Mac ne sait pas lire ces fiches, il
# republierait sans cesse un emploi du temps « modifié » où les noms auraient disparu.
MAX_FICHES = 90
REVOIR_VIDES_JOURS = 14     # un cours proche sans enseignant connu est redemandé


def nettoyer(v):
    """Contenu d'un champ de fiche -> texte simple (il peut contenir du HTML)."""
    if isinstance(v, (list, tuple)):
        v = ", ".join(str(x) for x in v if x)
    t = html.unescape(re.sub(r"<[^>]+>", " ", str(v or "")))
    return re.sub(r"\s+", " ", t).strip(" ,;")


def enseignant(fiche):
    """Nom(s) du champ « Enseignant ». Les lignes sans libellé qui le suivent sont sa suite
    (Celcat écrit ainsi les champs à plusieurs valeurs)."""
    noms, dedans = [], False
    for e in (fiche.get("elements") or []) if isinstance(fiche, dict) else []:
        lab = e.get("label")
        if lab and re.search(r"enseignant", str(lab), re.I):
            dedans = True
        elif lab:
            dedans = False
        if dedans:
            n = nettoyer(e.get("content"))
            if n and len(n) <= 80 and n not in noms:
                noms.append(n)
    return "; ".join(noms)      # « ; » et non « , » : Celcat écrit déjà « Nom, Prénom »


def maj_profs(appel_souple, seances, chemin):
    try:
        connus = json.load(open(chemin, encoding="utf-8"))
        assert isinstance(connus, dict)
    except Exception:
        connus = {}
    maintenant = datetime.datetime.now()
    proche = (maintenant + datetime.timedelta(days=REVOIR_VIDES_JOURS)).isoformat()
    ids = {str(e.get("id")) for e in seances if e.get("id")}
    a_voir = []
    for e in sorted(seances, key=lambda x: str(x.get("start"))):
        i, debut = str(e.get("id") or ""), str(e.get("start") or "")
        if not i or debut < maintenant.isoformat()[:10]:
            continue                                  # cours passé : inutile
        if i not in connus or (connus[i] == "" and debut <= proche):
            a_voir.append(i)
    trouves = 0
    for i in a_voir[:MAX_FICHES]:
        brut = appel_souple("/Home/GetSideBarEvent", {"eventId": i})
        if brut is None:
            break                                     # Celcat ne répond plus : on garde l'acquis
        try:
            nom = enseignant(json.loads(brut))
        except ValueError:
            continue
        connus[i] = nom
        trouves += bool(nom)
        time.sleep(0.05)
    connus = {i: n for i, n in connus.items() if i in ids}      # cours disparus
    with open(chemin, "w", encoding="utf-8") as f:
        json.dump(connus, f, ensure_ascii=False, indent=0, sort_keys=True)
        f.write("\n")
    # Journal public : des nombres seulement.
    print(f"[recuperer] enseignants : {min(len(a_voir), MAX_FICHES)} fiches lues, {trouves} noms, "
          f"{sum(1 for n in connus.values() if n)} connus au total, {max(0, len(a_voir) - MAX_FICHES)} restent à lire")


def stop(msg):
    print(f"[recuperer] ÉCHEC : {msg}")
    sys.exit(1)


def conf(source):
    txt = open(source, encoding="utf-8").read()
    c = dict(re.findall(r'static let (\w+)\s*=\s*"([^"]*)"', txt))
    manquants = [k for k in ("host", "federationId", "resType", "rangeStart", "rangeEnd") if k not in c]
    if manquants:
        stop("configuration introuvable dans EDTKit.swift : " + ", ".join(manquants))
    return c


def main():
    if len(sys.argv) not in (3, 4):
        stop("usage : recuperer.py <EDTKit.swift> <sortie> [profs.json]")
    c = conf(sys.argv[1])
    user, mdp = os.environ.get("EDT_USER", ""), os.environ.get("EDT_PASSWORD", "")
    if not user or not mdp:
        stop("secrets EDT_USER / EDT_PASSWORD absents")

    nav = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    # Celcat traduit certains libellés (« 10 autres... » / « 10 more... ») selon la langue du
    # navigateur. Le Mac est en français : sans cet en-tête, GitHub recevrait de l'anglais et
    # chacun republierait par-dessus l'autre un emploi du temps « modifié ».
    nav.addheaders = [("User-Agent", "Mozilla/5.0 (Macintosh) edt-maj"),
                      ("Accept-Language", "fr-FR,fr;q=0.9")]

    def appel(etape, chemin, champs=None, ajax=False):
        req = urllib.request.Request(c["host"] + chemin)
        if champs is not None:
            req.data = urllib.parse.urlencode(champs).encode()
            req.add_header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
        if ajax:
            req.add_header("X-Requested-With", "XMLHttpRequest")
        try:
            rep = nav.open(req, timeout=30)
            return rep.geturl(), rep.read().decode("utf-8", "replace")
        except Exception as e:                       # le type seulement : jamais le détail
            stop(f"{etape} — {type(e).__name__}")

    _, page = appel("page de connexion", "/LdapLogin")
    jeton = re.search(r'name="__RequestVerificationToken"[^>]*value="([^"]+)"', page)
    if not jeton:
        stop("jeton de formulaire introuvable (la page de connexion a changé ?)")

    url, _ = appel("connexion", "/LdapLogin/Logon", {
        "Name": user, "Password": mdp, "RememberMe": "false",
        "__RequestVerificationToken": jeton.group(1)})
    if "login" in urllib.parse.urlparse(url).path.lower():
        stop("connexion refusée (identifiants ?)")
    print("[recuperer] connecté")

    _, brut = appel("emploi du temps", "/Home/GetCalendarData", [
        ("start", c["rangeStart"]), ("end", c["rangeEnd"]), ("resType", c["resType"]),
        ("calView", "month"), ("federationIds[]", c["federationId"]), ("colourScheme", "3")],
        ajax=True)
    try:
        seances = json.loads(brut)
    except ValueError:
        stop("réponse qui n'est pas du JSON (session refusée ?)")
    # Une année entière sans aucune séance n'existe pas : c'est une panne, pas une nouvelle.
    if not isinstance(seances, list) or not seances:
        stop("aucune séance reçue")

    with open(sys.argv[2], "w", encoding="utf-8") as f:
        f.write(brut)
    print(f"[recuperer] {len(seances)} événements bruts")

    if len(sys.argv) == 4:
        def appel_souple(chemin, champs):             # ne doit jamais faire échouer la mise à jour
            req = urllib.request.Request(c["host"] + chemin, data=urllib.parse.urlencode(champs).encode())
            req.add_header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
            req.add_header("X-Requested-With", "XMLHttpRequest")
            try:
                return nav.open(req, timeout=20).read().decode("utf-8", "replace")
            except Exception:
                return None
        try:
            maj_profs(appel_souple, seances, sys.argv[3])
        except Exception as e:
            print(f"[recuperer] enseignants ignorés — {type(e).__name__}")


if __name__ == "__main__":
    main()
