"""Qualité et vitesse de la recherche texte de search-books, sur le vrai projet.

    ENV_LOCAL=/chemin/.env.local python3 supabase/tests/search_quality.py [--json sortie.json]

Lance un jeu de recherches réelles et affiche, pour chacune, le temps de
réponse et le top 5. Avant chaque recherche, l'entrée correspondante de
search_cache est supprimée (via `supabase db query --remote`, CLI connectée au
compte qui possède le projet) : le temps mesuré est celui d'une recherche qui
interroge vraiment les sources. --keep-cache saute cette suppression.

Se connecte avec le compte de test A (TEST_USER_A_* dans .env.local, créé par
verify_backend.py). Chaque recherche qui interroge les sources coûte 10 unités
de la limite par utilisateur (300 par minute) : le jeu entier en prend 90.

Les critères attendus sont contrôlés à la fin (OK / ÉCHEC) ; le script sort
avec le code 1 si l'un d'eux échoue.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ENV_LOCAL = os.environ.get("ENV_LOCAL") or str(REPO / ".env.local")

QUERIES = [
    "dune",
    "la peste",
    "fred vargas",
    "l'étranger",
    "harry potter",
    "le mage du kremlin",
    "yoga carrère",
    "une sorcière",
    "amélie nothomb",
]

# Guides, analyses et résumés : ils ne doivent pas figurer dans le top 5.
GUIDE = re.compile(
    r"fiche de lecture|analyse|etude|commentaire|profil d.une oeuvre|resume|\bbac\b|"
    r"dossier pedagogique|lecture analytique|study guide|summary|analysis|cliffsnotes|sparknotes",
)
# Disques et partitions (la BnF renvoyait les albums de Herman Dune pour « dune »).
NOT_A_BOOK = re.compile(r"herman dune|enregistrement sonore|partition|\bcd\b|vinyl")

TIME_LIMIT_S = 3.5


def env_value(name):
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in open(ENV_LOCAL):
            if line.startswith(name + "="):
                return line.rstrip("\n").split("=", 1)[1]
    except FileNotFoundError:
        pass
    sys.exit(f"{name} manquant : le définir dans l'environnement ou dans {ENV_LOCAL}")


URL = env_value("SUPABASE_URL").rstrip("/")
KEY = env_value("SUPABASE_PUBLISHABLE_KEY")
REF = URL.split("//", 1)[1].split(".", 1)[0]


def fold(s):
    """Minuscules sans accents, comme normalizeQuery dans search-books."""
    s = unicodedata.normalize("NFKD", s.lower().replace("œ", "oe").replace("æ", "ae"))
    s = "".join(c for c in s if not unicodedata.category(c).startswith("M"))
    return re.sub(r"[\W_]+", " ", s).strip()


def call(path, token, body, timeout=40):
    req = urllib.request.Request(
        URL + path, data=json.dumps(body).encode(), method="POST",
        headers={"apikey": KEY, "Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def purge_cache(queries):
    keys = ", ".join("'q:" + fold(q).replace("'", "''") + "'" for q in queries)
    run = subprocess.run(
        ["supabase", "db", "query", f"--remote={REF}", "-o", "json", "--yes",
         f"delete from public.search_cache where query_key in ({keys})"],
        capture_output=True, text=True, cwd=REPO, timeout=60)
    if run.returncode != 0:
        sys.exit(f"suppression du cache impossible : {(run.stderr or run.stdout)[-300:]}")


def describe(r):
    authors = ", ".join(r.get("authors") or []) or "?"
    flags = [r.get("source") or "?", r.get("language") or "--"]
    if r.get("isbn13"):
        flags.append("isbn")
    if r.get("cover_url"):
        flags.append("couv")
    return f"{r['title']} — {authors} [{' '.join(flags)}]"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", help="écrit les résultats dans ce fichier")
    parser.add_argument("--keep-cache", action="store_true", help="ne vide pas search_cache")
    args = parser.parse_args()

    status, res = call("/auth/v1/token?grant_type=password", None, {
        "email": env_value("TEST_USER_A_EMAIL"), "password": env_value("TEST_USER_A_PASSWORD")})
    if status != 200:
        sys.exit(f"connexion du compte de test A impossible (HTTP {status})")
    token = res["access_token"]

    if not args.keep_cache:
        purge_cache(QUERIES)

    runs = {}
    for q in QUERIES:
        t = time.time()
        status, res = call("/functions/v1/search-books", token, {"query": q})
        elapsed = time.time() - t
        results = res.get("results", []) if isinstance(res, dict) else []
        runs[q] = {"status": status, "seconds": round(elapsed, 2), "results": results}
        print(f"\n« {q} » — HTTP {status}, {elapsed:.2f} s, {len(results)} résultats")
        if status != 200:
            print("   ", json.dumps(res, ensure_ascii=False)[:300])
        for i, r in enumerate(results[:5], 1):
            print(f"  {i}. {describe(r)}")

    failures = []

    def check(label, ok, detail=""):
        print(("OK    " if ok else "ÉCHEC ") + label + (f" — {detail}" if detail else ""))
        if not ok:
            failures.append(label)

    def top(q, n=5):
        return runs[q]["results"][:n]

    def text(r):
        return fold(" ".join([r["title"], r.get("subtitle") or "", *(r.get("authors") or [])]))

    print("\nCritères")
    first = top("dune", 1)
    # « Dune », ou « Dune, tome 1 », pas une suite (« Les Hérétiques de Dune »).
    check("« dune » : Dune de Frank Herbert en premier",
          bool(first) and re.fullmatch(r"dune( (tome|livre|volume|t))?( 1)?", fold(first[0]["title"]))
          and any("herbert" in fold(a) for a in first[0]["authors"]),
          describe(first[0]) if first else "aucun résultat")

    etranger = runs["l'étranger"]["results"]
    camus = next((i for i, r in enumerate(etranger)
                  if fold(r["title"]).startswith("l etranger") and not GUIDE.search(text(r))
                  and any("camus" in fold(a) for a in r["authors"])), None)
    guide = next((i for i, r in enumerate(etranger) if GUIDE.search(text(r))), None)
    check("« l'étranger » : L'Étranger de Camus devant les fiches de lecture",
          camus is not None and (guide is None or camus < guide), f"Camus rang {camus}, 1er guide rang {guide}")

    bad = [(q, describe(r)) for q in QUERIES for r in top(q)
           if GUIDE.search(text(r)) or NOT_A_BOOK.search(text(r))]
    check("aucun disque ni guide dans les top 5", not bad, "; ".join(f"{q} : {d}" for q, d in bad))

    slow = [(q, runs[q]["seconds"]) for q in QUERIES if runs[q]["seconds"] >= TIME_LIMIT_S]
    check(f"chaque recherche répond en moins de {TIME_LIMIT_S} s", not slow,
          ", ".join(f"{q} {s:.2f} s" for q, s in slow))
    check("toutes les recherches répondent HTTP 200",
          all(runs[q]["status"] == 200 for q in QUERIES))

    if args.json:
        Path(args.json).write_text(json.dumps(runs, ensure_ascii=False, indent=1))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
