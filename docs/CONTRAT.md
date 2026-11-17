# reading-tracker — contrat entre backend et app

Ce document est la source de vérité partagée par le backend Supabase (`supabase/`) et l'app iOS (`ios/`).
Toute évolution du schéma ou de l'API se fait ici d'abord.

## Projet Supabase

- Région West EU (Paris). L'URL du projet et la clé publishable ne sont pas versionnées :
  - app iOS : `ios/Config/Secrets.xcconfig`, à créer depuis `ios/Config/Secrets.example.xcconfig` ;
  - scripts : `SUPABASE_URL` et `SUPABASE_PUBLISHABLE_KEY`, dans l'environnement ou dans `.env.local` ;
  - CI : secrets du dépôt GitHub.
- Mot de passe DB : dans `.env.local` (non versionné). Les clés secrètes ne vont jamais dans le dépôt ni dans l'app.

## Authentification (v1)

- Email + mot de passe, **confirmation d'email désactivée** en v1 (pas de deep link à gérer).
- Sign in with Apple : plus tard.
- À l'inscription, l'app passe `data: { username, display_name }` dans les métadonnées ; un trigger crée la ligne `profiles`.

## Schéma (schéma `public`, RLS activée partout)

### `profiles`
| colonne | type | note |
|---|---|---|
| id | uuid PK | = `auth.users.id`, cascade |
| username | text unique not null | 3–30 car. `[a-z0-9_]`, généré depuis l'email si absent |
| display_name | text | |
| avatar_url | text | |
| is_private | bool default false | privé ⇒ les follows passent par une demande |
| created_at | timestamptz | |

RLS : lecture pour tout utilisateur connecté ; mise à jour de sa propre ligne seulement.

### `books` — cache partagé des fiches
| colonne | type | note |
|---|---|---|
| id | uuid PK | |
| isbn13 | text unique | nullable |
| isbn10 | text | |
| title | text not null | |
| subtitle | text | |
| authors | text[] not null default '{}' | |
| publisher | text | |
| published_date | text | format libre (« 2020 », « 2020-03-05 ») |
| page_count | int | |
| description | text | |
| language | text | ISO 639-1 si possible |
| cover_url | text | https |
| source | text not null | `google` \| `hardcover` \| `bnf` \| `openlibrary` \| `manual` |
| source_id | text | unique avec `source` |
| created_at | timestamptz | |

RLS : lecture pour les utilisateurs connectés, **pas d'écriture directe**. On écrit uniquement par la RPC `upsert_book`.

### `user_books` — la bibliothèque de chaque compte
| colonne | type | note |
|---|---|---|
| id | uuid PK | |
| user_id | uuid not null default `auth.uid()` | FK profiles, cascade |
| book_id | uuid not null | FK books |
| status | text not null | `to_read` (PAL) \| `reading` \| `read` \| `abandoned` |
| current_page | int | |
| started_at | date | posé auto au passage en `reading` s'il est vide |
| finished_at | date | posé auto au passage en `read` s'il est vide |
| rating | smallint | 1–5, nullable |
| review | text | |
| is_favorite | bool default false | |
| created_at, updated_at | timestamptz | `updated_at` maintenu par trigger |

Contrainte : unique `(user_id, book_id)`.
RLS : le propriétaire fait tout. En lecture seule, la ligne est aussi visible si le profil du propriétaire est public, ou si l'utilisateur courant le suit avec un follow `accepted`.

### `follows`
| colonne | type | note |
|---|---|---|
| follower_id | uuid | FK profiles |
| following_id | uuid | FK profiles |
| status | text | `pending` \| `accepted` — posé par trigger : `accepted` si la cible est publique, sinon `pending` |
| created_at | timestamptz | |

PK `(follower_id, following_id)`, check `follower_id <> following_id`.
RLS : lecture si je suis l'un des deux ; insertion si `follower_id = auth.uid()` ; mise à jour (accepter) si `following_id = auth.uid()` ; suppression si je suis l'un des deux.

### Vue `friends_activity` (`security_invoker = true`)
Les `user_books` des comptes que je suis (follow `accepted`), joints à `books` et `profiles`, triés par `updated_at desc`.
Colonnes : `user_book_id, user_id, username, display_name, avatar_url, book_id, title, authors, cover_url, status, current_page, page_count, rating, updated_at`.

### RPC
- `upsert_book(book jsonb) returns uuid` (security definer) : prend un candidat au format renvoyé par `search-books`. Elle déduplique sur `isbn13`, sinon sur `(source, source_id)`, complète les champs vides d'une fiche existante sans écraser ceux qui sont remplis, et renvoie l'id.

## Edge Function `search-books`

`POST /functions/v1/search-books` avec un JWT utilisateur (verify_jwt activé).

Corps : `{ "query": "camus etranger" }` ou `{ "isbn": "9782070360024" }`

Réponse : `{ "results": [BookCandidate] }`, 20 résultats au maximum, sans doublons sur l'ISBN-13.

```json
{
  "book_id": "8b65ae35-f7de-44f8-ac36-4984ed882e96",
  "isbn13": "9782070360024", "isbn10": "2070360024",
  "title": "L'Étranger", "subtitle": null,
  "authors": ["Albert Camus"], "publisher": "Gallimard",
  "published_date": "1972", "page_count": 191,
  "description": null, "language": "fr",
  "cover_url": "https://covers.openlibrary.org/b/isbn/9782070360024-L.jpg",
  "source": "bnf", "source_id": "ark:/12148/cb35224436w"
}
```

`book_id` (uuid ou `null`) : id de la fiche si le livre est déjà dans `books`. L'app peut alors créer le `user_books` directement ; sinon, elle appelle `upsert_book` avec le candidat. `source` peut aussi valoir `manual` pour une fiche déjà en base.

Cache, pour limiter les appels aux sources externes (et le quota Hardcover partagé) :
- **ISBN** : la table `books` fait foi. Une fiche complète (titre, auteurs, couverture) est renvoyée sans appeler les sources. Sinon les sources sont interrogées, au plus une fois tous les 30 jours par ISBN, et le résultat est enregistré dans `books` par `upsert_book` : chaque scan peuple le catalogue, et la réponse porte son `book_id`.
- **Texte** : les résultats sont gardés 30 jours dans la table interne `search_cache`, clé = requête en minuscules sans accents ni ponctuation. Une réponse incomplète (une source en panne) n'est pas mise en cache. Les candidats ne sont pas enregistrés dans `books`.
- `search_cache` n'est accessible ni à `anon` ni à `authenticated` : seule la fonction la lit et l'écrit, avec la clé service.

Sources, appelées en parallèle et fusionnées par ISBN-13 :
1. **Google Books** : seulement si le secret `GOOGLE_BOOKS_API_KEY` est défini, car sans clé le quota est de 0. Données les plus riches.
2. **Hardcover** (GraphQL, `https://api.hardcover.app/v1/graphql`, header `authorization: Bearer <jeton>`) : seulement si le secret `HARDCOVER_API_TOKEN` est défini. ISBN via `editions(where: isbn_13 / isbn_10)`, texte via `search(query_type: "Book")`. Un résultat texte est une œuvre : il ne porte pas d'ISBN, et son `source_id` vaut `book:<id>` (`edition:<id>` pour une recherche par ISBN). Le jeton est personnel, avec un quota partagé par tous les utilisateurs de l'app (offre gratuite : 60 requêtes/min, 5 000/jour), une expiration choisie à sa création et une réinitialisation possible sans préavis tant que l'API est en bêta. Scope suffisant : `read:catalog:search`.
3. **BnF SRU** (`catalogue.bnf.fr/api/SRU`, `recordSchema=dublincore`, sans auth) : ISBN via `bib.isbn adj "<isbn>"` (essayer ISBN-13 puis ISBN-10), texte via `bib.anywhere all "<q>"`. On ne garde que `dc:type` « texte imprimé ». Il faut nettoyer : le titre (couper à « / »), les auteurs (« Camus, Albert (1913-1960). Auteur du texte » → « Albert Camus »), l'éditeur (retirer « (Paris) »), le nombre de pages tiré de `dc:format`, et l'ISBN tiré de `dc:identifier` « ISBN … ».
4. **Open Library** : `search.json` pour le texte, `/isbn/<isbn>.json` pour l'ISBN. Sert aussi de couverture de secours : `https://covers.openlibrary.org/b/isbn/<isbn13>-L.jpg?default=false`.

Ordre de priorité des champs : Google > Hardcover > BnF > Open Library. Toute `cover_url` est en https.

### Limites de débit

L'URL et la clé publishable sont publiques (dépôt open source, app distribuée) : n'importe qui peut créer un compte et appeler `search-books`. La fonction limite donc chaque compte et protège le quota Hardcover. Les compteurs sont dans Postgres : fenêtres fixes d'une minute et d'un jour UTC (remise à zéro à minuit UTC), tables `rate_limit_settings` et `rate_limit_counters`, fonctions `search_books_rate_limit` et `hardcover_take`. Rien de tout cela n'est accessible à `anon` ni à `authenticated`.

**Par utilisateur**, en unités :
| appel | coût |
|---|---|
| tout appel authentifié, y compris servi par le cache ou invalide | 1 |
| appel qui interroge les sources externes (ISBN absent de `books` et du cache, texte absent du cache) | 10 au total |

| fenêtre | plafond | soit, en recherches qui interrogent les sources | soit, servies par le cache |
|---|---|---|---|
| minute | 300 | 30 (un scan toutes les 2 s) | 300 |
| jour UTC | 6 000 | 600 (une bibliothèque entière scannée d'un coup) | 6 000 |

Au-delà, la fonction n'appelle aucune source et répond :

```
HTTP 429
Retry-After: 42
{ "error": "Trop de recherches en peu de temps. Réessaie dans 42 s.", "retry_after": 42 }
```

`Retry-After` et `retry_after` donnent le même nombre de secondes avant l'ouverture de la fenêtre pleine : 60 au plus pour la minute, jusqu'à minuit UTC pour le jour (message « Limite de recherches du jour atteinte. Réessaie dans 5 h 12 min. »). `error` est en français et peut être affiché tel quel. L'app ne relance pas automatiquement ; elle peut désactiver la recherche pendant `retry_after` secondes.

**Global, pour Hardcover** : au plus 50 appels sortants par minute et 4 000 par jour UTC, sous le quota du jeton (60/min, 5 000/jour), toute l'app confondue. Au-delà, la recherche continue sans Hardcover, sans erreur : les autres sources répondent, et ce résultat n'est pas mis en cache, pour que la même recherche profite de Hardcover le lendemain.

Les seuils et les coûts sont dans la ligne unique de `rate_limit_settings`, modifiable sans redéploiement. Si la base est injoignable, la fonction laisse passer l'utilisateur mais se passe de Hardcover.

Supabase Auth applique ses propres limites par IP (`[auth.rate_limit]` dans `supabase/config.toml`, poussées avec `supabase config push`) : 10 inscriptions ou connexions par 5 minutes, 30 rafraîchissements de session par 5 minutes. Au-delà, Auth répond HTTP 429 (`over_request_rate_limit`).

## App iOS

- SwiftUI, iOS 26 minimum, design Liquid Glass natif. La structure simple d'AudioBooth (github.com/AudioBooth/AudioBooth) sert de référence.
- Bundle id `fr.dachet.readingtracker`, nom affiché « reading-tracker » (provisoire).
- Dépendance : `supabase-swift` (SPM).
- Onglets : **Accueil** (date et salut, lectures en cours avec mise à jour rapide de la page, stats du mois calculées côté client, 3 dernières activités des amis), **Bibliothèque** (En cours / PAL / Lus / Abandonnés), **Amis** (activité, recherche de comptes, demandes), **Profil**. **Ajouter** (recherche et scan ISBN) est l'onglet de recherche iOS 26 (`Tab(role: .search)`), affiché à part dans la tab bar ; l'Accueil y mène aussi.
