-- Ajoute Hardcover aux sources de fiches (docs/CONTRAT.md, search-books).

alter table public.books drop constraint books_source_check;
alter table public.books add constraint books_source_check
  check (source in ('google', 'hardcover', 'bnf', 'openlibrary', 'manual'));

-- upsert_book : identique à la version initiale, avec la source hardcover.
create or replace function public.upsert_book(book jsonb)
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
  if v_source not in ('google', 'hardcover', 'bnf', 'openlibrary', 'manual') then
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
