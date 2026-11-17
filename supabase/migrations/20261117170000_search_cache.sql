-- Cache des recherches de search-books (docs/CONTRAT.md).
--
-- Clé : « isbn:<isbn13> » ou « q:<requête normalisée> ». Valeur : les
-- BookCandidate renvoyés par les sources externes, sans book_id (recalculé à
-- chaque appel). La fonction considère une entrée de plus de 30 jours comme
-- périmée et la réécrit.
--
-- Table interne : aucune politique RLS, aucun droit pour anon/authenticated ;
-- seule la fonction y accède, avec la clé service.

create table public.search_cache (
  query_key text primary key,
  results jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.search_cache enable row level security;

revoke all on public.search_cache from anon, authenticated;
