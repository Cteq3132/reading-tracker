"""Vérification réelle du backend reading-tracker contre le projet Supabase.

    python3 supabase/tests/verify_backend.py

Au premier lancement, crée deux comptes de test (A et B) et note leurs
identifiants dans .env.local (non versionné, jamais affichés).
SUPABASE_URL et SUPABASE_PUBLISHABLE_KEY viennent de l'environnement ou de
.env.local. Ensuite, se
reconnecte avec ces comptes et remet leurs données à zéro avant de rejouer les
contrôles de docs/CONTRAT.md : profil, upsert_book, user_books, RLS selon le
follow, friends_activity, search-books et ses limites de débit.

Les limites de débit se vérifient avec les seuils réels : le script pré-remplit
les compteurs dans la base avec `supabase db query --remote` (CLI connectée au
compte qui possède le projet), puis les remet en état.

Unshelf : entrées et sorties de PAL dans user_book_events, status_changed_at,
droits de lecture des événements, objectif PAL et reprise de l'existant.

ENV_LOCAL permet de désigner un autre fichier que .env.local à la racine.
"""
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

ENV_LOCAL = os.environ.get("ENV_LOCAL") or str(Path(__file__).resolve().parents[2] / ".env.local")


def env_value(name):
    """Variable d'environnement, sinon ligne NAME=... de .env.local."""
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
KEY = env_value("SUPABASE_PUBLISHABLE_KEY")  # clé publishable, faite pour le client

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
    for acc in (A, B):
        call("DELETE", f"/rest/v1/follows?follower_id=eq.{acc['id']}", acc["token"])
    for acc in (A, B):
        call("DELETE", f"/rest/v1/user_books?user_id=eq.{acc['id']}", acc["token"])
        call("PATCH", f"/rest/v1/profiles?id=eq.{acc['id']}", acc["token"],
             {"is_private": False, "pal_goal_target": None, "pal_goal_deadline": None})
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
status, book_id_b = call("POST", "/rest/v1/rpc/upsert_book", B["token"], {"book": candidate})
check("upsert_book par B déduplique sur l'ISBN-13 (même id)", book_id_b == book_id, show(book_id_b))

# books est le catalogue partagé (et le cache de search-books) : les écritures
# de test portent sur une fiche dédiée, jamais sur un vrai livre.
test_book = {"title": "Fiche de test reading-tracker", "source": "manual", "source_id": "verify-backend",
             "authors": ["Testeur"]}
status, test_id = call("POST", "/rest/v1/rpc/upsert_book", A["token"], {"book": test_book})
status, test_id_b = call("POST", "/rest/v1/rpc/upsert_book", B["token"],
                         {"book": {**test_book, "title": "Autre titre", "description": "Description de test."}})
status, res = call("GET", f"/rest/v1/books?id=eq.{test_id}&select=title,description,source,source_id", A["token"])
print("fiche de test:", show(res))
check("upsert_book déduplique sur (source, source_id) et complète un champ vide sans écraser le titre",
      test_id == test_id_b and res and res[0]["title"] == "Fiche de test reading-tracker"
      and res[0]["description"] == "Description de test.")
status, res = call("POST", "/rest/v1/rpc/upsert_book", A["token"], {"book": {**candidate, "isbn13": None, "isbn10": "281805138X", "title": "Autre titre"}})
check("upsert_book retrouve la fiche par l'ISBN-10 converti, sans écraser le titre", res == book_id, show(res))
if hc_text:
    status, hc_id = call("POST", "/rest/v1/rpc/upsert_book", A["token"], {"book": hc_text[0]})
    status2, hc_id2 = call("POST", "/rest/v1/rpc/upsert_book", B["token"], {"book": hc_text[0]})
    check("upsert_book accepte une fiche hardcover et la déduplique sur (source, source_id)",
          status == 200 and isinstance(hc_id, str) and hc_id == hc_id2, show([hc_id, hc_id2]))
# Cache de search-books et book_id
status, res = call("POST", "/functions/v1/search-books", A["token"], {"isbn": "9782818051382"})
hit = res.get("results", []) if isinstance(res, dict) else []
check("ISBN déjà en base : fiche de books renvoyée avec son book_id",
      len(hit) == 1 and hit[0].get("book_id") == book_id and hit[0]["title"] == "Yoga", show(hit)[:300])
status, res = call("POST", "/functions/v1/search-books", B["token"], {"query": "yoga carrere"})
annotated = [r for r in res.get("results", []) if r["isbn13"] == "9782818051382"] if isinstance(res, dict) else []
check("recherche texte : book_id posé sur un livre déjà en base",
      all("book_id" in r for r in res.get("results", [])) and (not annotated or annotated[0]["book_id"] == book_id),
      show(annotated)[:200])
runs = []
for q in ("Fred Vargas Pars vite", "fred vargas, pars vite !"):
    t = time.time()
    status, res = call("POST", "/functions/v1/search-books", A["token"], {"query": q})
    runs.append((time.time() - t, [(r["source"], r["source_id"]) for r in res.get("results", [])]))
print(f"recherche texte : {runs[0][0]:.2f} s puis {runs[1][0]:.2f} s (même clé de cache)")
check("recherche texte : la variante de ponctuation et de casse renvoie les mêmes résultats (cache)",
      runs[0][1] and runs[0][1] == runs[1][1])
status, res = call("GET", "/rest/v1/search_cache?select=query_key&limit=1", A["token"])
check("search_cache illisible pour un utilisateur", status in (401, 403), f"HTTP {status} {show(res)[:120]}")

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

# 7. Unshelf : PAL, historique des statuts, objectif ---------------------------
# Les événements s'accumulent d'un lancement à l'autre (les suppressions de la
# remise à zéro en créent aussi) : on ne regarde que ceux créés après ce point.
def ts(value):
    return datetime.fromisoformat(value)


def events_of(token, user_id, after_id, book=None):
    q = f"/rest/v1/user_book_events?user_id=eq.{user_id}&id=gt.{after_id}&order=id&select=*"
    if book:
        q += f"&book_id=eq.{book}"
    return call("GET", q, token)


def transitions(events):
    return [f"{e['from_status'] or '∅'}→{e['to_status'] or '∅'}" for e in events]


status, res = call("GET", f"/rest/v1/user_book_events?user_id=eq.{A['id']}&order=id.desc&limit=1&select=id", A["token"])
last_event = res[0]["id"] if status == 200 and res else 0
status, res = call("GET", f"/rest/v1/user_books?user_id=eq.{A['id']}&book_id=eq.{book_id}&select=*", A["token"])
ub_a = res[0]
status, res = call("GET", f"/rest/v1/user_book_events?user_book_id=eq.{ub_a['id']}&select=*", A["token"])
print("événements du Yoga de A :", show(res))
check("insertion en to_read : événement ∅→to_read, status_changed_at = created_at",
      status == 200 and transitions(res) == ["∅→to_read"] and res[0]["book_id"] == book_id
      and ts(res[0]["occurred_at"]) == ts(ub_a["status_changed_at"]) == ts(ub_a["created_at"]), show(ub_a))

status, res = call("POST", "/rest/v1/user_books", A["token"],
                   {"book_id": test_id, "status": "to_read", "status_changed_at": "2000-01-01T00:00:00Z"},
                   {"Prefer": "return=representation"})
ub_t = res[0] if status == 201 else None
check("status_changed_at envoyé par le client ignoré à l'insertion",
      ub_t is not None and ts(ub_t["status_changed_at"]).year > 2000, show(res))

time.sleep(1.1)
status, res = call("PATCH", f"/rest/v1/user_books?id=eq.{ub_t['id']}", A["token"],
                   {"rating": 4, "status_changed_at": "2000-01-01T00:00:00Z"}, {"Prefer": "return=representation"})
status_e, ev = events_of(A["token"], A["id"], last_event, test_id)
check("mise à jour sans changement de statut : status_changed_at inchangé (valeur envoyée ignorée), aucun événement",
      status == 200 and res[0]["status_changed_at"] == ub_t["status_changed_at"]
      and ts(res[0]["updated_at"]) > ts(ub_t["updated_at"]) and transitions(ev) == ["∅→to_read"],
      f"{show(res)} {transitions(ev)}")

status, res = call("PATCH", f"/rest/v1/user_books?id=eq.{ub_a['id']}", A["token"], {"status": "reading"},
                   {"Prefer": "return=representation"})
moved = res[0] if status == 200 and res else {}
status_e, ev = call("GET", f"/rest/v1/user_book_events?user_book_id=eq.{ub_a['id']}&order=id&select=*", A["token"])
check("passage to_read → reading : sortie de PAL, status_changed_at avancé, started_at posé par l'autre trigger",
      moved.get("status") == "reading" and ts(moved["status_changed_at"]) > ts(ub_a["status_changed_at"])
      and moved["started_at"] is not None and transitions(ev) == ["∅→to_read", "to_read→reading"]
      and ts(ev[-1]["occurred_at"]) == ts(moved["status_changed_at"]), f"{show(moved)} {transitions(ev)}")

time.sleep(1.1)
status, res = call("PATCH", f"/rest/v1/user_books?id=eq.{ub_t['id']}", A["token"], {"status": "released"},
                   {"Prefer": "return=representation"})
released = res[0] if status == 200 and res else {}
check("passage to_read → released (Libérer) accepté, status_changed_at avancé",
      released.get("status") == "released" and ts(released["status_changed_at"]) > ts(ub_t["status_changed_at"])
      and released["started_at"] is None and released["finished_at"] is None, show(res))
status, res = call("POST", "/rest/v1/user_books", B["token"], {"book_id": test_id, "status": "wishlist"},
                   {"Prefer": "return=representation"})
check("statut wishlist accepté (Envies)", status == 201 and res[0]["status"] == "wishlist", show(res))
status, res = call("POST", "/rest/v1/user_books", B["token"], {"book_id": book_id, "status": "possédé"})
check("statut inconnu refusé", status == 400, f"HTTP {status}")

status, _ = call("DELETE", f"/rest/v1/user_books?id=eq.{ub_t['id']}", A["token"])
status, res = call("POST", "/rest/v1/user_books", A["token"], {"book_id": test_id, "status": "to_read"},
                   {"Prefer": "return=representation"})
again = res[0]["id"] if status == 201 else None
status, _ = call("DELETE", f"/rest/v1/user_books?id=eq.{again}", A["token"])
status_e, ev = events_of(A["token"], A["id"], last_event, test_id)
print("événements de la fiche de test (A) :", transitions(ev), [e["user_book_id"] for e in ev])
check("suppressions : released→∅ puis, ligne to_read supprimée, to_read→∅ ; user_book_id passé à null",
      transitions(ev) == ["∅→to_read", "to_read→released", "released→∅", "∅→to_read", "to_read→∅"]
      and all(e["user_book_id"] is None for e in ev), show(ev)[:400])
status_e, ev = events_of(A["token"], A["id"], last_event)
entries = sum(e["to_status"] == "to_read" for e in ev)
exits = sum(e["from_status"] == "to_read" for e in ev)
print(f"bilan de A depuis le début de la section : {entries} entrées, {exits} sorties de PAL")
check("bilan calculable depuis les événements : 2 entrées en PAL, 3 sorties (reading, released, suppression)",
      entries == 2 and exits == 3, transitions(ev))

# Droits sur user_book_events. Ici : A public, B privé, A suit B (accepté).
status, res = call("GET", f"/rest/v1/user_book_events?user_id=eq.{A['id']}&select=id", B["token"])
check("B voit les événements de A (profil public)", status == 200 and len(res) > 0, f"HTTP {status} {len(res or [])}")
status, res = call("GET", f"/rest/v1/user_book_events?user_id=eq.{B['id']}&select=id", A["token"])
check("A voit les événements de B (privé, follow accepté)", status == 200 and len(res) > 0, f"HTTP {status}")
call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {"is_private": True})
try:
    status, res = call("GET", f"/rest/v1/user_book_events?user_id=eq.{A['id']}&select=id", B["token"])
    check("A passe en privé : B ne voit plus ses événements (pas de follow)", status == 200 and res == [], show(res))
    status, res = call("POST", "/rest/v1/follows", B["token"], {"follower_id": B["id"], "following_id": A["id"]},
                       {"Prefer": "return=representation"})
    status, res = call("GET", f"/rest/v1/user_book_events?user_id=eq.{A['id']}&select=id", B["token"])
    check("follow B→A pending : toujours rien", status == 200 and res == [], show(res))
    call("PATCH", f"/rest/v1/follows?follower_id=eq.{B['id']}&following_id=eq.{A['id']}", A["token"],
         {"status": "accepted"})
    status, res = call("GET", f"/rest/v1/user_book_events?user_id=eq.{A['id']}&select=id", B["token"])
    check("follow B→A accepté : B voit les événements de A", status == 200 and len(res) > 0, f"HTTP {status}")
finally:
    call("DELETE", f"/rest/v1/follows?follower_id=eq.{B['id']}&following_id=eq.{A['id']}", B["token"])
    call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {"is_private": False})
status, res = call("GET", "/rest/v1/user_book_events?select=id&limit=1")
check("user_book_events refusée sans session", status in (401, 403) or res == [], f"HTTP {status} {show(res)}")

status, res = call("POST", "/rest/v1/user_book_events", A["token"],
                   {"user_id": A["id"], "book_id": book_id, "from_status": None, "to_status": "to_read"})
check("insertion directe dans user_book_events refusée", status in (401, 403), f"HTTP {status} {show(res)[:120]}")
status, mine = call("GET", f"/rest/v1/user_book_events?user_id=eq.{A['id']}&order=id.desc&limit=1&select=id", A["token"])
status, res = call("PATCH", f"/rest/v1/user_book_events?id=eq.{mine[0]['id']}", A["token"], {"to_status": "read"},
                   {"Prefer": "return=representation"})
check("modification directe d'un événement refusée, même le sien", status in (401, 403), f"HTTP {status} {show(res)[:120]}")
status, res = call("DELETE", f"/rest/v1/user_book_events?id=eq.{mine[0]['id']}", A["token"],
                   headers={"Prefer": "return=representation"})
check("suppression directe d'un événement refusée, même le sien", status in (401, 403), f"HTTP {status} {show(res)[:120]}")

# Objectif PAL. A a une PAL de 1 livre ici (le Yoga est passé en reading) : on
# en ajoute un pour que la taille de départ ne soit pas un hasard.
status, res = call("POST", "/rest/v1/user_books", A["token"], {"book_id": test_id, "status": "to_read"},
                   {"Prefer": "return=representation"})
status, pal = call("GET", f"/rest/v1/user_books?user_id=eq.{A['id']}&status=eq.to_read&select=id", A["token"])
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"],
                   {"pal_goal_target": 0, "pal_goal_deadline": "2027-06-30"}, {"Prefer": "return=representation"})
goal = res[0] if status == 200 and res else {}
print(f"objectif de A (PAL de {len(pal)}) :",
      show({k: v for k, v in goal.items() if k.startswith("pal_goal")}))
check("objectif PAL : start_size = taille de la PAL, set_at posé, échéance gardée",
      goal.get("pal_goal_target") == 0 and goal.get("pal_goal_start_size") == len(pal) >= 1
      and goal.get("pal_goal_set_at") is not None and goal.get("pal_goal_deadline") == "2027-06-30", show(goal))
for col, value in (("pal_goal_start_size", 99), ("pal_goal_set_at", "2000-01-01T00:00:00Z")):
    status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {col: value})
    check(f"{col} non modifiable par le client", status in (401, 403), f"HTTP {status} {show(res)[:120]}")
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {"pal_goal_deadline": None},
                   {"Prefer": "return=representation"})
check("changer l'échéance seule ne touche ni start_size ni set_at",
      status == 200 and res[0]["pal_goal_start_size"] == goal["pal_goal_start_size"]
      and res[0]["pal_goal_set_at"] == goal["pal_goal_set_at"], show(res))
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {"pal_goal_target": -1})
check("objectif PAL négatif refusé", status == 400, f"HTTP {status}")
call("DELETE", f"/rest/v1/user_books?user_id=eq.{A['id']}&book_id=eq.{test_id}", A["token"])
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {"pal_goal_target": 1},
                   {"Prefer": "return=representation"})
check("nouvelle cible : start_size recalculé sur la PAL du moment",
      status == 200 and res[0]["pal_goal_start_size"] == len(pal) - 1
      and ts(res[0]["pal_goal_set_at"]) > ts(goal["pal_goal_set_at"]), show(res))
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{B['id']}", A["token"], {"pal_goal_target": 3},
                   {"Prefer": "return=representation"})
check("A ne peut pas fixer l'objectif de B", status == 200 and res == [], show(res))
status, res = call("PATCH", f"/rest/v1/profiles?id=eq.{A['id']}", A["token"], {"pal_goal_target": None},
                   {"Prefer": "return=representation"})
check("objectif retiré : start_size et set_at remis à null",
      status == 200 and res[0]["pal_goal_start_size"] is None and res[0]["pal_goal_set_at"] is None, show(res))

# 8. Limites de débit de search-books -----------------------------------------
# Les seuils réels restent en place : on pré-remplit les compteurs du compte A
# (et le compteur global Hardcover) dans la base, puis on remet tout en état.
# Nécessite la CLI supabase connectée au compte qui possède le projet.
REF = URL.split("//", 1)[1].split(".", 1)[0]
REPO = Path(__file__).resolve().parents[2]


def sql(query, write=False):
    """Requête sur la base du projet via la CLI supabase (rôle postgres)."""
    args = ["supabase", "db", "query", f"--remote={REF}", "-o", "json"]
    args += ["--yes"] if write else ["--read-only"]
    run = subprocess.run(args + [query], capture_output=True, text=True, cwd=REPO, timeout=60)
    out = run.stdout
    if run.returncode != 0 or "{" not in out:
        raise RuntimeError(f"supabase db query a échoué : {(run.stderr or out)[-300:]}")
    return json.loads(out[out.index("{"):]).get("rows") or []


def call_raw(token, body):
    """Comme call(), mais renvoie aussi les en-têtes de la réponse."""
    req = urllib.request.Request(URL + "/functions/v1/search-books", data=json.dumps(body).encode(),
                                 method="POST", headers={"apikey": KEY, "Content-Type": "application/json",
                                                         "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, dict(r.headers), json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, dict(e.headers), json.loads(raw)
        except ValueError:
            return e.code, dict(e.headers), raw


def wait_for_fresh_minute():
    """Les contrôles « minute » doivent tenir dans une même fenêtre d'une minute."""
    s = time.gmtime().tm_sec
    if s > 40:
        time.sleep(61 - s)


def set_user_counter(user_id, period, hits):
    window = "date_trunc('minute', now())" if period == "minute" else "date_trunc('day', now(), 'UTC')"
    sql(f"insert into public.rate_limit_counters (bucket, period, window_start, hits) "
        f"values ('user:{user_id}', '{period}', {window}, {int(hits)}) "
        f"on conflict (bucket, period, window_start) do update set hits = excluded.hits", write=True)


for path in ("/rest/v1/rate_limit_settings?select=*", "/rest/v1/rate_limit_counters?select=*"):
    status, res = call("GET", path, A["token"])
    check(f"{path.split('?')[0]} illisible pour un utilisateur", status in (401, 403), f"HTTP {status} {show(res)[:120]}")
for fn, body in (("search_books_rate_limit", {"p_user": A["id"], "p_step": "request"}), ("hardcover_take", {})):
    status, res = call("POST", f"/rest/v1/rpc/{fn}", A["token"], body)
    check(f"RPC {fn} refusée à un utilisateur", status in (401, 403, 404), f"HTTP {status} {show(res)[:120]}")


def section_rate_limits():
    rights = sql("""
      select r.role,
             has_table_privilege(r.role, 'public.rate_limit_counters', 'select,insert,update,delete') as counters,
             has_table_privilege(r.role, 'public.rate_limit_settings', 'select,update') as settings,
             has_function_privilege(r.role, 'public.rate_limit_take(text,int,int,int)', 'execute') as take,
             has_function_privilege(r.role, 'public.search_books_rate_limit(uuid,text)', 'execute') as limit_fn,
             has_function_privilege(r.role, 'public.hardcover_take()', 'execute') as hardcover
        from unnest(array['anon', 'authenticated', 'service_role']) as r(role)""")
    print("droits:", show(rights))
    by_role = {r.pop("role"): r for r in rights}
    check("tables et fonctions de limite : aucun droit pour anon ni authenticated, tous pour service_role",
          len(by_role) == 3 and not any(any(by_role[r].values()) for r in ("anon", "authenticated"))
          and all(by_role["service_role"].values()), show(by_role))

    settings = sql("select * from public.rate_limit_settings")[0]
    print("rate_limit_settings:", show(settings))
    per_min, per_day = settings["user_per_minute"], settings["user_per_day"]
    cost_cached, cost_external = settings["cost_cached"], settings["cost_external"]
    cached_isbn = {"isbn": "9782818051382"}  # Yoga, déjà dans books : servi sans source externe

    try:
        # Le cache compte peu : un appel servi par books passe là où une recherche
        # externe est refusée (avant tout appel aux sources).
        wait_for_fresh_minute()
        set_user_counter(A["id"], "minute", per_min - cost_external + 1)
        status, _, res = call_raw(A["token"], cached_isbn)
        check("limite minute presque atteinte : une recherche servie par le cache passe", status == 200,
              f"HTTP {status} {show(res)[:150]}")
        status, headers, res = call_raw(A["token"], {"query": f"zzqx introuvable {secrets.token_hex(4)}"})
        retry = headers.get("Retry-After")
        print(f"recherche externe au-delà de la limite → HTTP {status}, Retry-After {retry}, {show(res)}")
        check("limite minute : une recherche qui irait aux sources → 429, Retry-After ≤ 60, message en français",
              status == 429 and retry is not None and 1 <= int(retry) <= 60 and isinstance(res, dict)
              and res.get("retry_after") == int(retry) and "Réessaie" in res.get("error", ""),
              f"HTTP {status} {retry} {show(res)[:200]}")

        # Atomicité : 12 appels simultanés pour 5 places → exactement 5 passent.
        wait_for_fresh_minute()
        set_user_counter(A["id"], "minute", per_min - 5 * cost_cached)
        with ThreadPoolExecutor(max_workers=12) as pool:
            statuses = sorted(s for s, _, _ in pool.map(lambda _: call_raw(A["token"], cached_isbn), range(12)))
        print("12 appels simultanés pour 5 places :", statuses)
        check("compteur atomique : 12 appels simultanés pour 5 places → 5 × 200 et 7 × 429",
              statuses.count(200) == 5 and statuses.count(429) == 7, str(statuses))

        # Limite du jour : Retry-After jusqu'à minuit UTC.
        sql(f"delete from public.rate_limit_counters where bucket = 'user:{A['id']}' and period = 'minute'", write=True)
        set_user_counter(A["id"], "day", per_day)
        status, headers, res = call_raw(A["token"], cached_isbn)
        retry = headers.get("Retry-After")
        now = time.gmtime()
        to_midnight = 86400 - (now.tm_hour * 3600 + now.tm_min * 60 + now.tm_sec)
        print(f"limite du jour → HTTP {status}, Retry-After {retry} (minuit UTC dans {to_midnight} s), {show(res)}")
        check("limite du jour → 429, Retry-After jusqu'à minuit UTC, message « du jour »",
              status == 429 and retry is not None and abs(int(retry) - to_midnight) <= 5
              and "du jour" in res.get("error", ""), f"HTTP {status} {retry} {show(res)[:200]}")
    finally:
        sql(f"delete from public.rate_limit_counters where bucket = 'user:{A['id']}'", write=True)
    status, _, res = call_raw(A["token"], cached_isbn)
    check("compteurs de A remis à zéro : la recherche repasse", status == 200, f"HTTP {status}")

    # Plafond Hardcover : la recherche continue sans Hardcover ; le résultat
    # n'est gardé qu'un jour en cache. La fenêtre du jour est figée une fois,
    # pour que la remise en état vise la même ligne même après minuit UTC.
    # Pendant ces quelques secondes, Hardcover est coupé pour toute l'app.
    hc_query, hc_key = {"query": "project hail mary"}, "q:project hail mary"
    day = sql("select date_trunc('day', now(), 'UTC') as d")[0]["d"]
    hc_row = f"bucket = 'hardcover' and period = 'day' and window_start = '{day}'::timestamptz"
    hc_count = f"select coalesce(sum(hits), 0)::int as n from public.rate_limit_counters where {hc_row}"
    cache_age = ("select extract(epoch from now() - created_at)::int as age from public.search_cache "
                 f"where query_key = '{hc_key}'")
    cap = settings["hardcover_per_day"]

    def search_until_cached():
        """Une source lente (Open Library frôle parfois son délai de 6 s) rend le
        résultat incomplet, donc non mis en cache : jusqu'à 3 essais."""
        for attempt in range(3):
            status, _, res = call_raw(B["token"], hc_query)
            results = res.get("results", []) if isinstance(res, dict) else []
            age = [r["age"] for r in sql(cache_age)]
            if age or status != 200:
                break
            print(f"   essai {attempt + 1} : résultat non mis en cache (source lente), on recommence")
        return status, res, results, age

    sql(f"delete from public.search_cache where query_key = '{hc_key}'", write=True)
    sql("insert into public.rate_limit_counters (bucket, period, window_start, hits) "
        f"values ('hardcover', 'day', '{day}'::timestamptz, {cap}) "
        f"on conflict (bucket, period, window_start) do update set hits = rate_limit_counters.hits + {cap}", write=True)
    try:
        before = sql(hc_count)[0]["n"]
        status, res, results, age = search_until_cached()
        after = sql(hc_count)[0]["n"]
        print(f"plafond Hardcover atteint → HTTP {status}, {len(results)} résultats, sources",
              sorted({r["source"] for r in results}), f"compteur {before} → {after}, âge en cache : {age}")
        check("plafond Hardcover atteint : recherche 200 avec résultats, sans Hardcover ni appel sortant compté",
              status == 200 and results and all(r["source"] != "hardcover" for r in results) and after == before,
              f"HTTP {status} {show(res)[:200]}")
        # readCache garde 30 jours : antidaté de 29 jours, l'entrée périme dans un jour.
        check("plafond Hardcover atteint : résultat gardé un jour seulement en cache",
              len(age) == 1 and 29 * 86400 - 60 <= age[0] <= 29 * 86400 + 60, str(age))
    finally:
        sql(f"update public.rate_limit_counters set hits = greatest(hits - {cap}, 0) where {hc_row}", write=True)
        sql(f"delete from public.search_cache where query_key = '{hc_key}'", write=True)
    status, res, results, age = search_until_cached()
    check("plafond Hardcover rendu : Hardcover revient et le résultat est gardé 30 jours en cache",
          status == 200 and any(r["source"] == "hardcover" for r in results) and len(age) == 1 and age[0] < 600,
          f"HTTP {status} sources {sorted({r['source'] for r in results})} âge {age}")
    print("compteur Hardcover du jour :", sql(hc_count)[0]["n"], "/", cap)


def section_unshelf_sql():
    rights = sql("""
      select r.role,
             has_table_privilege(r.role, 'public.user_book_events', 'insert,update,delete,truncate') as write,
             has_table_privilege(r.role, 'public.user_book_events', 'select') as read,
             has_column_privilege(r.role, 'public.profiles', 'pal_goal_start_size', 'insert,update') as start_size,
             has_column_privilege(r.role, 'public.profiles', 'pal_goal_set_at', 'insert,update') as set_at,
             has_column_privilege(r.role, 'public.profiles', 'pal_goal_target', 'update') as target
        from unnest(array['anon', 'authenticated']) as r(role)""")
    print("droits Unshelf:", show(rights))
    by_role = {r.pop("role"): r for r in rights}
    check("user_book_events : aucune écriture pour anon ni authenticated, lecture pour authenticated seul ; "
          "pal_goal_start_size et pal_goal_set_at non modifiables, pal_goal_target modifiable",
          not any(by_role["anon"].values())
          and by_role["authenticated"] == {"write": False, "read": True, "start_size": False, "set_at": False,
                                           "target": True}, show(by_role))

    # Reprise de l'existant : chaque ligne, reprise ou créée depuis, a un
    # événement d'origine ∅→statut daté de son created_at (la migration l'a posé
    # pour les lignes existantes, le trigger pour les nouvelles), et son dernier
    # événement donne son statut actuel et son status_changed_at.
    rows = sql(f"""
      with last as (
        select distinct on (e.user_book_id) e.user_book_id, e.to_status, e.occurred_at
          from public.user_book_events e where e.user_book_id is not null
         order by e.user_book_id, e.id desc)
      select ub.user_id not in ('{A['id']}', '{B['id']}') as other_account,
             exists (select 1 from public.user_book_events o
                      where o.user_book_id = ub.id and o.from_status is null
                        and o.occurred_at = ub.created_at) as origin_ok,
             l.to_status = ub.status and l.occurred_at = ub.status_changed_at as last_ok,
             (select count(*) from public.user_book_events o where o.user_book_id = ub.id) > 1
               or ub.status_changed_at = ub.created_at as single_ok
        from public.user_books ub left join last l on l.user_book_id = ub.id""")
    bad = [r for r in rows if not (r["origin_ok"] and r["last_ok"] and r["single_ok"])]
    others = sum(r["other_account"] for r in rows)
    print(f"reprise : {len(rows)} lignes de user_books, dont {others} hors comptes de test ; incohérentes : {len(bad)}")
    check("reprise de l'existant : chaque user_books a son événement ∅→statut daté de created_at, "
          "et son dernier événement donne status et status_changed_at",
          rows and others >= 1 and not bad, show(bad)[:300])


try:
    section_unshelf_sql()
except (RuntimeError, subprocess.TimeoutExpired, FileNotFoundError) as error:
    check("contrôles SQL Unshelf (CLI supabase requise)", False, str(error)[:300])

try:
    section_rate_limits()
except (RuntimeError, subprocess.TimeoutExpired, FileNotFoundError) as error:
    check("contrôles des limites de débit (CLI supabase requise)", False, str(error)[:300])

print()
print("RÉSULTAT :", "tout est passé" if not failures else f"{len(failures)} échec(s) : {failures}")
sys.exit(1 if failures else 0)
