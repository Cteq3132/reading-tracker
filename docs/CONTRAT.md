# reading-tracker — contrat entre backend et app

Ce document est la source de vérité partagée par le backend Supabase (`supabase/`) et l'app iOS (`ios/`).
Toute évolution du schéma ou de l'API se fait ici d'abord.

## Projet Supabase

- Ref : `<project-ref>`, région West EU (Paris)
- URL : `https://<project-ref>.supabase.co`
- Clé publishable (client) : `sb_publishable_xxx`
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
| source | text not null | `google` \| `bnf` \| `openlibrary` \| `manual` |
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
  "isbn13": "9782070360024", "isbn10": "2070360024",
  "title": "L'Étranger", "subtitle": null,
  "authors": ["Albert Camus"], "publisher": "Gallimard",
  "published_date": "1972", "page_count": 191,
  "description": null, "language": "fr",
  "cover_url": "https://covers.openlibrary.org/b/isbn/9782070360024-L.jpg",
  "source": "bnf", "source_id": "ark:/12148/cb35224436w"
}
```

Sources, appelées en parallèle et fusionnées par ISBN-13 :
1. **Google Books** : seulement si le secret `GOOGLE_BOOKS_API_KEY` est défini, car sans clé le quota est de 0. Données les plus riches.
2. **BnF SRU** (`catalogue.bnf.fr/api/SRU`, `recordSchema=dublincore`, sans auth) : ISBN via `bib.isbn adj "<isbn>"` (essayer ISBN-13 puis ISBN-10), texte via `bib.anywhere all "<q>"`. On ne garde que `dc:type` « texte imprimé ». Il faut nettoyer : le titre (couper à « / »), les auteurs (« Camus, Albert (1913-1960). Auteur du texte » → « Albert Camus »), l'éditeur (retirer « (Paris) »), le nombre de pages tiré de `dc:format`, et l'ISBN tiré de `dc:identifier` « ISBN … ».
3. **Open Library** : `search.json` pour le texte, `/isbn/<isbn>.json` pour l'ISBN. Sert aussi de couverture de secours : `https://covers.openlibrary.org/b/isbn/<isbn13>-L.jpg?default=false`.

Ordre de priorité des champs : Google > BnF > Open Library. Toute `cover_url` est en https.
Hardcover : hors v1 (son API demande un jeton lié à un compte et n'est pas prévue pour une app distribuée).

## App iOS

- SwiftUI, iOS 26 minimum, design Liquid Glass natif. La structure simple d'AudioBooth (github.com/AudioBooth/AudioBooth) sert de référence.
- Bundle id `app.readingtracker.ios`, nom affiché « reading-tracker » (provisoire).
- Dépendance : `supabase-swift` (SPM).
- Onglets : **Bibliothèque** (En cours / PAL / Lus / Abandonnés), **Ajouter** (recherche et scan ISBN), **Amis** (activité, recherche de comptes, demandes), **Profil**.
