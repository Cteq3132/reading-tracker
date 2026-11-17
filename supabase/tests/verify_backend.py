"""Vérification réelle du backend reading-tracker contre le projet Supabase.

    python3 supabase/tests/verify_backend.py

Au premier lancement, crée deux comptes de test (A et B) et note leurs
identifiants dans .env.local (non versionné, jamais affichés). Ensuite, se
reconnecte avec ces comptes et remet leurs données à zéro avant de rejouer les
contrôles de docs/CONTRAT.md : profil, upsert_book, user_books, RLS selon le
follow, friends_activity et search-books.

ENV_LOCAL permet de désigner un autre fichier que .env.local à la racine.
"""
import json
import os
import secrets
import sys
import urllib.error
import urllib.request
from pathlib import Path

URL = "https://<project-ref>.supabase.co"
KEY = "sb_publishable_xxx"  # clé publique, cf. docs/CONTRAT.md
ENV_LOCAL = os.environ.get("ENV_LOCAL") or str(Path(__file__).resolve().parents[2] / ".env.local")

failures = []


def call(method, path, token=None, body=None, headers=None):
    h = {"apikey": KEY, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = f"Bearer {token}"
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def check(label, ok, detail=""):
    print(("OK   " if ok else "ÉCHEC") + f" {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(label)


def show(obj):
    return json.dumps(obj, ensure_ascii=False)


# 1. Inscription des deux comptes (ou reconnexion s'ils existent déjà) ---------
def load_existing():
    env = {}
    try:
        for line in open(ENV_LOCAL):
            if line.startswith("TEST_USER_") and "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                env[k] = v
    except FileNotFoundError:
        pass
    return env


existing = load_existing()
accounts = {}
if all(f"TEST_USER_{w}_EMAIL" in existing for w in "AB"):
    for who in ("a", "b"):
        W = who.upper()
        status, res = call("POST", "/auth/v1/token?grant_type=password", body={
            "email": existing[f"TEST_USER_{W}_EMAIL"], "password": existing[f"TEST_USER_{W}_PASSWORD"]})
        check(f"connexion du compte de test {W} existant (HTTP {status})", status == 200)
        if status != 200:
            sys.exit(1)
        accounts[who] = {"email": res["user"]["email"], "id": res["user"]["id"], "token": res["access_token"]}
    suffix = accounts["a"]["email"].split(".")[3].split("@")[0]
    A, B = accounts["a"], accounts["b"]
    # Remise à zéro de leurs données, par eux-mêmes (RLS).
    call("DELETE", f"/rest/v1/follows?follower_id=eq.{A['id']}", A["token"])
    for acc in (A, B):
        call("DELETE", f"/rest/v1/user_books?user_id=eq.{acc['id']}", acc["token"])
        call("PATCH", f"/rest/v1/profiles?id=eq.{acc['id']}", acc["token"], {"is_private": False})
    print("Comptes A et B réutilisés, données remises à zéro.")

suffix = locals().get("suffix") or secrets.token_hex(3)
for who in ("a", "b"):
    if who in accounts:
        continue
    email = f"rt.test.{who}.{suffix}@example.com"
    password = secrets.token_urlsafe(18)
    status, res = call("POST", "/auth/v1/signup", body={
        "email": email,
        "password": password,
        "data": {"username": f"Test_{who.upper()}_{suffix}", "display_name": f"Testeur {who.upper()}"},
    })
    ok = status == 200 and isinstance(res, dict) and res.get("access_token")
    check(f"inscription {who.upper()} sans confirmation d'email (HTTP {status})", bool(ok),
          "" if ok else show(res)[:300])
    if not ok:
        sys.exit(1)
    accounts[who] = {"email": email, "password": password, "id": res["user"]["id"], "token": res["access_token"]}
    # Noté tout de suite, pour ne jamais perdre un compte créé.
    with open(ENV_LOCAL, "a") as f:
        if who == "a":
            f.write("\n# Comptes de test backend (créés par la session backend-supabase)\n")
        f.write(f"TEST_USER_{who.upper()}_EMAIL={email}\n")
        f.write(f"TEST_USER_{who.upper()}_PASSWORD={password}\n")
        f.write(f"TEST_USER_{who.upper()}_ID={accounts[who]['id']}\n")
if not existing:
    print(f"Identifiants ajoutés à {ENV_LOCAL} (TEST_USER_A_*, TEST_USER_B_*)")

A, B = accounts["a"], accounts["b"]

# 2. Profils créés par trigger ------------------------------------------------
status, res = call("GET", f"/rest/v1/profiles?id=in.({A['id']},{B['id']})&select=id,username,display_name,is_private", A["token"])
print("profiles:", show(res))
check("profils créés depuis raw_user_meta_data", status == 200 and len(res) == 2
      and all(p["username"] == f"test_{'a' if p['id'] == A['id'] else 'b'}_{suffix}" for p in res)
      and all(p["display_name"].startswith("Testeur") for p in res))

# B passe en privé
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{B['id']}", B["token"], {"is_private": True},
                   {"Prefer": "return=representation"})
check("B passe son profil en privé", status == 200 and res and res[0]["is_private"] is True, show(res))

status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{B['id']}", A["token"], {"display_name": "piraté"},
                   {"Prefer": "return=representation"})
check("A ne peut pas modifier le profil de B", status == 200 and res == [], f"HTTP {status} {show(res)}")

# 3. search-books -------------------------------------------------------------
status, res = call("POST", "/functions/v1/search-books", body={"isbn": "9782818051382"})
check("search-books refuse la seule clé publishable (apikey)", status == 401, f"HTTP {status}")
status, res = call("POST", "/functions/v1/search-books", KEY, {"isbn": "9782818051382"})
check("search-books refuse la clé publishable en Bearer", status == 401, f"HTTP {status}")

search = {}
for body in ({"isbn": "9782818051382"}, {"query": "camus etranger"}):
    status, res = call("POST", "/functions/v1/search-books", A["token"], body)
    results = res.get("results", []) if isinstance(res, dict) else []
    search[json.dumps(body)] = results
    print(f"search-books {show(body)} → HTTP {status}, {len(results)} résultats")
    for r in results[:5]:
        print("   ", show(r))
    isbns = [r["isbn13"] for r in results if r["isbn13"]]
    check(f"search-books {show(body)} : résultats, ≤ 20, sans doublon d'ISBN-13, couvertures https",
          status == 200 and 0 < len(results) <= 20 and len(isbns) == len(set(isbns))
          and all(r["cover_url"] is None or r["cover_url"].startswith("https://") for r in results))

yoga = search[json.dumps({"isbn": "9782818051382"})]
check("ISBN 9782818051382 → Yoga d'Emmanuel Carrère, chez POL, avec pages et couverture",
      bool(yoga) and yoga[0]["title"] == "Yoga" and yoga[0]["authors"] == ["Emmanuel Carrère"]
      and yoga[0]["publisher"] == "POL" and yoga[0]["page_count"] and yoga[0]["cover_url"].startswith("https://"))
camus = search[json.dumps({"query": "camus etranger"})]
check("« camus etranger » → L'Étranger d'Albert Camus parmi les premiers résultats",
      any("tranger" in r["title"] and "Albert Camus" in r["authors"] for r in camus[:3]))

# Sources optionnelles (secrets GOOGLE_BOOKS_API_KEY et HARDCOVER_API_TOKEN).
check("Google Books répond (résultats source google)",
      any(r["source"] == "google" for rs in search.values() for r in rs))
extra = {}
for body in ({"isbn": "9782070360024"}, {"query": "project hail mary"}):
    status, res = call("POST", "/functions/v1/search-books", A["token"], body)
    extra[json.dumps(body)] = res.get("results", []) if isinstance(res, dict) else []
    print(f"search-books {show(body)} → HTTP {status}, sources :",
          sorted({r["source"] for r in extra[json.dumps(body)]}))
etranger = extra[json.dumps({"isbn": "9782070360024"})]
check("recherche ISBN : uniquement le livre demandé",
      bool(etranger) and all(r["isbn13"] == "9782070360024" for r in etranger)
      and all(r["isbn13"] == "9782818051382" for r in yoga), show(etranger)[:300])
hc_isbn = [r for r in etranger if r["source"] == "hardcover"]
check("Hardcover répond par ISBN (édition hardcover, couverture https)",
      bool(hc_isbn) and hc_isbn[0]["source_id"].startswith("edition:")
      and hc_isbn[0]["cover_url"].startswith("https://"), show(hc_isbn)[:300])
hc_text = [r for r in extra[json.dumps({"query": "project hail mary"})] if r["source"] == "hardcover"]
check("Hardcover répond en texte (« project hail mary »)",
      bool(hc_text) and hc_text[0]["source_id"].startswith("book:") and "Andy Weir" in hc_text[0]["authors"],
      show(hc_text[:1])[:300])

# 4. upsert_book --------------------------------------------------------------
candidate = yoga[0]
status, book_id = call("POST", "/rest/v1/rpc/upsert_book", A["token"], {"book": candidate})
check("upsert_book par A renvoie un uuid", status == 200 and isinstance(book_id, str), show(book_id))
status, book_id_b = call("POST", "/rest/v1/rpc/upsert_book", B["token"], {"book": {**candidate, "description": "Récit."}})
check("upsert_book par B déduplique sur l'ISBN-13 (même id)", book_id_b == book_id, show(book_id_b))
status, res = call("GET", f"/rest/v1/books?id=eq.{book_id}&select=title,authors,page_count,description,cover_url,source", A["token"])
print("books:", show(res))
check("upsert_book complète un champ vide sans écraser", res and res[0]["description"] == "Récit." and res[0]["title"] == "Yoga")
status, res = call("POST", "/rest/v1/rpc/upsert_book", A["token"], {"book": {**candidate, "isbn13": None, "isbn10": "281805138X", "title": "Autre titre"}})
check("upsert_book retrouve la fiche par l'ISBN-10 converti, sans écraser le titre", res == book_id, show(res))
if hc_text:
    status, hc_id = call("POST", "/rest/v1/rpc/upsert_book", A["token"], {"book": hc_text[0]})
    status2, hc_id2 = call("POST", "/rest/v1/rpc/upsert_book", B["token"], {"book": hc_text[0]})
    check("upsert_book accepte une fiche hardcover et la déduplique sur (source, source_id)",
          status == 200 and isinstance(hc_id, str) and hc_id == hc_id2, show([hc_id, hc_id2]))
status, res = call("POST", "/rest/v1/books", A["token"], {"title": "x", "source": "manual"})
check("écriture directe dans books refusée", status in (401, 403), f"HTTP {status}")
status, res = call("POST", "/rest/v1/rpc/upsert_book", None, {"book": candidate})
check("upsert_book refusée sans session", status in (401, 403), f"HTTP {status}")

# 5. user_books ---------------------------------------------------------------
status, res = call("POST", "/rest/v1/user_books", B["token"], {"book_id": book_id, "status": "reading", "current_page": 42},
                   {"Prefer": "return=representation"})
print("user_books B:", show(res))
ub_b = res[0] if status == 201 else None
check("B ajoute le livre en cours, started_at posé automatiquement",
      ub_b is not None and ub_b["user_id"] == B["id"] and ub_b["started_at"] is not None and ub_b["finished_at"] is None)

status, res = call("POST", "/rest/v1/user_books", A["token"], {"book_id": book_id, "status": "to_read"},
                   {"Prefer": "return=representation"})
check("A ajoute le livre à sa PAL", status == 201 and res[0]["user_id"] == A["id"], show(res))

status, res = call("POST", "/rest/v1/user_books", A["token"], {"book_id": book_id, "status": "to_read", "user_id": B["id"]})
check("A ne peut pas écrire dans la bibliothèque de B", status in (401, 403), f"HTTP {status}")

# 6. Visibilité selon le follow -----------------------------------------------
status, res = call("GET", f"/rest/v1/user_books?user_id=eq.{B['id']}&select=id", A["token"])
check("A ne voit pas les livres de B (privé, pas de follow)", status == 200 and res == [], show(res))

status, res = call("POST", "/rest/v1/follows", A["token"], {"follower_id": A["id"], "following_id": B["id"], "status": "accepted"},
                   {"Prefer": "return=representation"})
print("follow A→B:", show(res))
check("le follow vers un profil privé est posé en pending malgré status=accepted envoyé",
      status == 201 and res[0]["status"] == "pending")

status, res = call("PATCH", f"/rest/v1/follows?follower_id=eq.{A['id']}&following_id=eq.{B['id']}", A["token"],
                   {"status": "accepted"}, {"Prefer": "return=representation"})
check("A ne peut pas accepter sa propre demande", status == 200 and res == [], show(res))

status, res = call("GET", f"/rest/v1/user_books?user_id=eq.{B['id']}&select=id", A["token"])
check("A ne voit toujours pas les livres de B (follow pending)", status == 200 and res == [], show(res))
status, res = call("GET", "/rest/v1/friends_activity?select=*", A["token"])
check("friends_activity vide tant que le follow est pending", status == 200 and res == [], show(res))

status, res = call("PATCH", f"/rest/v1/follows?follower_id=eq.{A['id']}&following_id=eq.{B['id']}", B["token"],
                   {"status": "accepted"}, {"Prefer": "return=representation"})
check("B accepte la demande", status == 200 and res and res[0]["status"] == "accepted", show(res))

status, res = call("GET", f"/rest/v1/user_books?user_id=eq.{B['id']}&select=id,status,current_page", A["token"])
check("A voit les livres de B une fois le follow accepté", status == 200 and len(res) == 1, show(res))

# B termine le livre : finished_at et updated_at
status, res = call("PATCH", f"/rest/v1/user_books?id=eq.{ub_b['id']}", B["token"], {"status": "read", "rating": 5},
                   {"Prefer": "return=representation"})
check("passage en read : finished_at posé, updated_at avancé",
      status == 200 and res[0]["finished_at"] is not None and res[0]["updated_at"] > ub_b["updated_at"]
      and res[0]["started_at"] == ub_b["started_at"], show(res))

status, res = call("GET", "/rest/v1/friends_activity?select=*", A["token"])
print("friends_activity A:", show(res))
expected_cols = {"user_book_id", "user_id", "username", "display_name", "avatar_url", "book_id", "title", "authors",
                 "cover_url", "status", "current_page", "page_count", "rating", "updated_at"}
check("friends_activity renvoie l'activité de B avec les colonnes du contrat",
      status == 200 and len(res) == 1 and set(res[0]) == expected_cols and res[0]["user_id"] == B["id"]
      and res[0]["title"] == "Yoga" and res[0]["status"] == "read")
status, res = call("GET", "/rest/v1/friends_activity?select=user_book_id", B["token"])
check("friends_activity de B vide (B ne suit personne)", status == 200 and res == [], show(res))
status, res = call("GET", "/rest/v1/friends_activity?select=user_book_id")
check("friends_activity refusée sans session", status in (401, 403) or res == [], f"HTTP {status} {show(res)}")

print()
print("RÉSULTAT :", "tout est passé" if not failures else f"{len(failures)} échec(s) : {failures}")
sys.exit(1 if failures else 0)
