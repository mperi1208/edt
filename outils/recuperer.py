#!/usr/bin/env python3
"""Récupère les données brutes de Celcat SANS le Mac : se connecte avec un identifiant
et un mot de passe, puis écrit la réponse de GetCalendarData dans un fichier.
usage : recuperer.py <EDTKit.swift> <fichier de sortie>
        identifiants dans les variables d'environnement EDT_USER et EDT_PASSWORD

Tourne dans GitHub Actions, sur un dépôt PUBLIC : les journaux sont lisibles par tous.
Ce script n'affiche donc JAMAIS d'identifiant, de cookie, ni de contenu de page —
seulement l'étape atteinte. Ne pas y ajouter de trace « pour déboguer ».

La configuration (groupe, période) est lue dans EDTKit.swift pour ne pas exister en double.
"""
import http.cookiejar, json, os, re, sys, urllib.parse, urllib.request


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
    if len(sys.argv) != 3:
        stop("usage : recuperer.py <EDTKit.swift> <sortie>")
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


if __name__ == "__main__":
    main()
