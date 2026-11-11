#!/usr/bin/env python3
"""Décide s'il faut publier. Affiche la raison, ou une ligne vide s'il ne faut rien faire.
usage : decide-publication.py <cache local> <data.json déjà publié>

Deux raisons seulement :
  - l'emploi du temps a réellement changé ;
  - le battement de vie : la dernière VÉRIFICATION publiée date de plus de 18 h.
    (La page iPhone passe en rouge à 30 h. Il n'y a plus de passage toutes les 30 min :
    cette règle ne joue que lorsqu'une vérification est demandée, sur le Mac ou le téléphone.)

Piège évité : ne jamais se baser sur `fetchedAt` pour le battement. Il désigne le dernier
CHANGEMENT et reste volontairement figé tant que rien ne bouge : s'y fier faisait publier
à chaque passage (314 commits dont 40 en un jour)."""
import json, sys, datetime

SEUIL = datetime.timedelta(hours=18)

def instant(txt):
    try:
        return datetime.datetime.fromisoformat((txt or "").replace("Z", "+00:00"))
    except ValueError:
        return None

def decide(local, publie, maintenant=None):
    maintenant = maintenant or datetime.datetime.now(datetime.timezone.utc)
    if publie is None:
        return "première publication"
    if local["sessions"] != publie["sessions"]:
        return "emploi du temps modifié"
    ref = instant(publie.get("checkedAt")) or instant(publie.get("fetchedAt"))
    if ref is None or maintenant - ref > SEUIL:
        return "battement de vie (vérification publiée trop ancienne)"
    return ""

if __name__ == "__main__":
    try:
        local = json.load(open(sys.argv[1]))
    except Exception:
        print("cache illisible"); sys.exit(0)
    try:
        publie = json.load(open(sys.argv[2]))
    except Exception:
        publie = None
    print(decide(local, publie))
