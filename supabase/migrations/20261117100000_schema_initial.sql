-- reading-tracker — schéma initial
-- Source de vérité : docs/CONTRAT.md
--
-- Tables : profiles, books, user_books, follows
-- Vue    : friends_activity (security_invoker)
-- RPC    : upsert_book(jsonb)
--
-- Toutes les fonctions ont un search_path vide et qualifient leurs objets.

------------------------------------------------------------------------------
-- Fonctions utilitaires
------------------------------------------------------------------------------

-- Transforme un texte libre (username saisi, partie locale d'un email) en
-- username valide `[a-z0-9_]{3,30}` libre dans profiles. Ne lève jamais :
-- si le username demandé est pris ou invalide, il est adapté.
create function public.generate_username(wanted text)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_base text;
  v_candidate text;
  v_try int := 0;
begin
  v_base := lower(coalesce(wanted, ''));
  v_base := translate(v_base,
    'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ',
    'aaaaaaceeeeiiiinooooouuuuyyoa');
  v_base := regexp_replace(v_base, '[^a-z0-9_]+', '_', 'g');
  v_base := btrim(v_base, '_');
  if length(v_base) < 3 then
    v_base := v_base || 'lecteur';
  end if;
  v_base := left(v_base, 30);

  v_candidate := v_base;
  while exists (select 1 from public.profiles p where p.username = v_candidate) loop
    v_try := v_try + 1;
    if v_try > 20 then
      v_candidate := left(v_base, 21) || '_' || substr(md5(random()::text), 1, 8);
    else
      v_candidate := left(v_base, 25) || '_' || lpad(floor(random() * 10000)::int::text, 4, '0');
    end if;
  end loop;

  return v_candidate;
end;
$$;

revoke all on function public.generate_username(text) from public, anon, authenticated;

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

------------------------------------------------------------------------------
-- profiles
------------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique
    constraint profiles_username_format check (username ~ '^[a-z0-9_]{3,30}$'),
  display_name text,
  avatar_url text,
  is_private boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles: lecture par les connectés"
  on public.profiles for select
  to authenticated
  using (true);

create policy "profiles: mise à jour de sa ligne"
  on public.profiles for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Le profil est créé par trigger ; le client ne modifie que ces colonnes.
revoke insert, update, delete, truncate on public.profiles from anon, authenticated;
revoke select on public.profiles from anon;
grant update (username, display_name, avatar_url, is_private) on public.profiles to authenticated;

-- Création du profil à l'inscription, depuis raw_user_meta_data.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_wanted text;
begin
  v_wanted := nullif(btrim(v_meta ->> 'username'), '');
  if v_wanted is null then
    v_wanted := split_part(coalesce(new.email, ''), '@', 1);
  end if;

  insert into public.profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    public.generate_username(v_wanted),
    nullif(btrim(v_meta ->> 'display_name'), ''),
    nullif(btrim(v_meta ->> 'avatar_url'), '')
  );
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

------------------------------------------------------------------------------
-- books — cache partagé des fiches, écrit uniquement par upsert_book
------------------------------------------------------------------------------

create table public.books (
  id uuid primary key default gen_random_uuid(),
  isbn13 text unique
    constraint books_isbn13_format check (isbn13 ~ '^[0-9]{13}$'),
  isbn10 text
    constraint books_isbn10_format check (isbn10 ~ '^[0-9]{9}[0-9X]$'),
  title text not null,
  subtitle text,
  authors text[] not null default '{}',
  publisher text,
  published_date text,
  page_count int constraint books_page_count_positive check (page_count > 0),
  description text,
  language text,
  cover_url text constraint books_cover_https check (cover_url like 'https://%'),
  source text not null
    constraint books_source_check check (source in ('google', 'bnf', 'openlibrary', 'manual')),
  source_id text,
  created_at timestamptz not null default now(),
  constraint books_source_source_id_key unique (source, source_id)
);

alter table public.books enable row level security;

create policy "books: lecture par les connectés"
  on public.books for select
  to authenticated
  using (true);

revoke insert, update, delete, truncate on public.books from anon, authenticated;
revoke select on public.books from anon;

------------------------------------------------------------------------------
-- user_books — la bibliothèque de chaque compte
------------------------------------------------------------------------------

create table public.user_books (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  book_id uuid not null references public.books (id),
  status text not null
    constraint user_books_status_check check (status in ('to_read', 'reading', 'read', 'abandoned')),
  current_page int constraint user_books_current_page_positive check (current_page >= 0),
  started_at date,
  finished_at date,
  rating smallint constraint user_books_rating_range check (rating between 1 and 5),
  review text,
  is_favorite boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_books_user_id_book_id_key unique (user_id, book_id)
);

create index user_books_user_id_status_idx on public.user_books (user_id, status);
create index user_books_user_id_updated_at_idx on public.user_books (user_id, updated_at desc);
create index user_books_book_id_idx on public.user_books (book_id);

alter table public.user_books enable row level security;

-- La politique de lecture est définie après la table follows, qu'elle utilise.

create policy "user_books: ajout par le propriétaire"
  on public.user_books for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "user_books: mise à jour par le propriétaire"
  on public.user_books for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "user_books: suppression par le propriétaire"
  on public.user_books for delete
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.user_books from anon;

-- started_at / finished_at posés automatiquement au passage de statut.
create function public.user_books_set_dates()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'reading' and new.started_at is null then
    new.started_at := current_date;
  end if;
  if new.status = 'read' and new.finished_at is null then
    new.finished_at := current_date;
  end if;
  return new;
end;
$$;

create trigger user_books_set_dates
  before insert or update of status, started_at, finished_at on public.user_books
  for each row execute function public.user_books_set_dates();

create trigger user_books_set_updated_at
  before update on public.user_books
  for each row execute function public.set_updated_at();

------------------------------------------------------------------------------
-- follows
------------------------------------------------------------------------------

create table public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  following_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending'
    constraint follows_status_check check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint follows_not_self check (follower_id <> following_id)
);

-- La PK couvre les recherches par follower_id ; celui-ci sert aux demandes
-- reçues et à la liste des abonnés.
create index follows_following_id_status_idx on public.follows (following_id, status);

alter table public.follows enable row level security;

create policy "follows: lecture si concerné"
  on public.follows for select
  to authenticated
  using ((select auth.uid()) in (follower_id, following_id));

create policy "follows: suivre en son nom"
  on public.follows for insert
  to authenticated
  with check (follower_id = (select auth.uid()));

create policy "follows: accepter une demande reçue"
  on public.follows for update
  to authenticated
  using (following_id = (select auth.uid()))
  with check (following_id = (select auth.uid()));

create policy "follows: suppression si concerné"
  on public.follows for delete
  to authenticated
  using ((select auth.uid()) in (follower_id, following_id));

revoke all on public.follows from anon;
revoke update on public.follows from authenticated;
grant update (status) on public.follows to authenticated;

-- Le statut d'un nouveau follow ne dépend que de la cible : accepted si elle
-- est publique, pending si elle est privée. La valeur envoyée est ignorée.
create function public.follows_set_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select case when p.is_private then 'pending' else 'accepted' end
    into new.status
    from public.profiles p
   where p.id = new.following_id;
  new.status := coalesce(new.status, 'pending');
  return new;
end;
$$;

revoke all on function public.follows_set_status() from public, anon, authenticated;

create trigger follows_set_status
  before insert on public.follows
  for each row execute function public.follows_set_status();

-- Un profil qui repasse en public accepte les demandes en attente.
create function public.profiles_accept_pending_follows()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.follows
     set status = 'accepted'
   where following_id = new.id
     and status = 'pending';
  return new;
end;
$$;

revoke all on function public.profiles_accept_pending_follows() from public, anon, authenticated;

create trigger profiles_accept_pending_follows
  after update of is_private on public.profiles
  for each row
  when (old.is_private and not new.is_private)
  execute function public.profiles_accept_pending_follows();

-- Lecture des user_books : le propriétaire, ou tout connecté si le profil est
-- public, ou un abonné dont le follow est accepté.
create policy "user_books: lecture"
  on public.user_books for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.profiles p
      where p.id = user_books.user_id and not p.is_private
    )
    or exists (
      select 1 from public.follows f
      where f.follower_id = (select auth.uid())
        and f.following_id = user_books.user_id
        and f.status = 'accepted'
    )
  );

------------------------------------------------------------------------------
-- Vue friends_activity
------------------------------------------------------------------------------

create view public.friends_activity
with (security_invoker = true)
as
select
  ub.id as user_book_id,
  ub.user_id,
  p.username,
  p.display_name,
  p.avatar_url,
  ub.book_id,
  b.title,
  b.authors,
  b.cover_url,
  ub.status,
  ub.current_page,
  b.page_count,
  ub.rating,
  ub.updated_at
from public.user_books ub
join public.follows f
  on f.following_id = ub.user_id
 and f.follower_id = (select auth.uid())
 and f.status = 'accepted'
join public.profiles p on p.id = ub.user_id
join public.books b on b.id = ub.book_id
order by ub.updated_at desc;

revoke all on public.friends_activity from anon, authenticated;
grant select on public.friends_activity to authenticated;

------------------------------------------------------------------------------
-- RPC upsert_book(book jsonb) returns uuid
------------------------------------------------------------------------------

-- Prend un BookCandidate (format de search-books). Déduplique sur isbn13,
-- sinon sur (source, source_id). Sur une fiche existante, ne complète que les
-- champs vides. Renvoie l'id de la fiche.
create function public.upsert_book(book jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_isbn13 text;
  v_isbn10 text;
  v_title text;
  v_subtitle text;
  v_authors text[];
  v_publisher text;
  v_published_date text;
  v_page_count int;
  v_description text;
  v_language text;
  v_cover_url text;
  v_source text;
  v_source_id text;
  v_sum int;
  v_id uuid;
  v_attempt int;
begin
  if auth.uid() is null then
    raise exception 'upsert_book: authentification requise' using errcode = '42501';
  end if;
  if book is null or jsonb_typeof(book) <> 'object' then
    raise exception 'upsert_book: un objet JSON est attendu' using errcode = '22023';
  end if;

  v_title := nullif(btrim(book ->> 'title'), '');
  if v_title is null then
    raise exception 'upsert_book: title est obligatoire' using errcode = '22023';
  end if;

  v_source := coalesce(nullif(btrim(book ->> 'source'), ''), 'manual');
  if v_source not in ('google', 'bnf', 'openlibrary', 'manual') then
    raise exception 'upsert_book: source inconnue « % »', v_source using errcode = '22023';
  end if;
  v_source_id := nullif(btrim(book ->> 'source_id'), '');

  -- ISBN : on ne garde que des valeurs bien formées.
  v_isbn13 := regexp_replace(coalesce(book ->> 'isbn13', ''), '[^0-9]', '', 'g');
  if length(v_isbn13) <> 13 then
    v_isbn13 := null;
  end if;
  v_isbn10 := upper(regexp_replace(coalesce(book ->> 'isbn10', ''), '[^0-9Xx]', '', 'g'));
  if v_isbn10 !~ '^[0-9]{9}[0-9X]$' then
    v_isbn10 := null;
  end if;
  -- ISBN-13 déduit de l'ISBN-10 pour que la déduplication fonctionne.
  if v_isbn13 is null and v_isbn10 is not null then
    v_isbn13 := '978' || left(v_isbn10, 9);
    v_sum := 0;
    for i in 1..12 loop
      v_sum := v_sum + substr(v_isbn13, i, 1)::int * case when i % 2 = 0 then 3 else 1 end;
    end loop;
    v_isbn13 := v_isbn13 || ((10 - v_sum % 10) % 10)::text;
  end if;

  v_subtitle := nullif(btrim(book ->> 'subtitle'), '');
  v_publisher := nullif(btrim(book ->> 'publisher'), '');
  v_published_date := nullif(btrim(book ->> 'published_date'), '');
  v_description := nullif(btrim(book ->> 'description'), '');
  v_language := nullif(lower(btrim(book ->> 'language')), '');

  if jsonb_typeof(book -> 'authors') = 'array' then
    select coalesce(array_agg(btrim(a) order by ord), '{}')
      into v_authors
      from jsonb_array_elements_text(book -> 'authors') with ordinality as t(a, ord)
     where nullif(btrim(a), '') is not null;
  else
    v_authors := '{}';
  end if;

  if (book ->> 'page_count') ~ '^\s*[0-9]{1,6}\s*$' then
    v_page_count := nullif(btrim(book ->> 'page_count')::int, 0);
  end if;

  v_cover_url := nullif(btrim(book ->> 'cover_url'), '');
  if v_cover_url like 'http://%' then
    v_cover_url := 'https://' || substr(v_cover_url, 8);
  end if;
  if v_cover_url not like 'https://%' then
    v_cover_url := null;
  end if;

  -- Deux passes : si une insertion concurrente gagne, on relit et on complète.
  for v_attempt in 1..2 loop
    v_id := null;
    if v_isbn13 is not null then
      select b.id into v_id from public.books b where b.isbn13 = v_isbn13;
    end if;
    if v_id is null and v_source_id is not null then
      select b.id into v_id from public.books b
       where b.source = v_source and b.source_id = v_source_id;
    end if;

    if v_id is not null then
      update public.books b set
        isbn13 = coalesce(
          b.isbn13,
          case when v_isbn13 is not null
                and not exists (select 1 from public.books o where o.isbn13 = v_isbn13)
               then v_isbn13 end),
        isbn10 = coalesce(nullif(b.isbn10, ''), v_isbn10),
        subtitle = coalesce(nullif(b.subtitle, ''), v_subtitle),
        authors = case when cardinality(b.authors) = 0 then v_authors else b.authors end,
        publisher = coalesce(nullif(b.publisher, ''), v_publisher),
        published_date = coalesce(nullif(b.published_date, ''), v_published_date),
        page_count = coalesce(b.page_count, v_page_count),
        description = coalesce(nullif(b.description, ''), v_description),
        language = coalesce(nullif(b.language, ''), v_language),
        cover_url = coalesce(nullif(b.cover_url, ''), v_cover_url)
      where b.id = v_id;
      return v_id;
    end if;

    insert into public.books (
      isbn13, isbn10, title, subtitle, authors, publisher, published_date,
      page_count, description, language, cover_url, source, source_id
    ) values (
      v_isbn13, v_isbn10, v_title, v_subtitle, v_authors, v_publisher, v_published_date,
      v_page_count, v_description, v_language, v_cover_url, v_source, v_source_id
    )
    on conflict do nothing
    returning id into v_id;

    if v_id is not null then
      return v_id;
    end if;
  end loop;

  raise exception 'upsert_book: impossible d''enregistrer la fiche';
end;
$$;

revoke all on function public.upsert_book(jsonb) from public, anon;
grant execute on function public.upsert_book(jsonb) to authenticated;
