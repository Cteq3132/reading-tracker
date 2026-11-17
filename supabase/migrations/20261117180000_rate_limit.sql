-- Limite de débit de search-books (docs/CONTRAT.md, « Limites de débit »).
--
-- Deux usages d'un même compteur à fenêtres fixes (minute et jour UTC) :
--   - par utilisateur : chaque appel coûte cost_cached unités, et un appel qui
--     interroge les sources externes coûte cost_external au total ; au-delà de
--     user_per_minute ou user_per_day, la fonction répond 429 ;
--   - global, pour Hardcover : chaque appel sortant prend 1 unité ; au-delà de
--     hardcover_per_minute ou hardcover_per_day, la fonction se passe de
--     Hardcover (quota du jeton partagé : 60/min, 5 000/jour).
--
-- Tables et fonctions internes : aucune politique RLS, aucun droit pour anon ni
-- authenticated ; seule la fonction y accède, avec la clé service.

-- Seuils, modifiables sans redéploiement (une seule ligne).
create table public.rate_limit_settings (
  id boolean primary key default true check (id),
  user_per_minute int not null check (user_per_minute > 0),
  user_per_day int not null check (user_per_day > 0),
  cost_cached int not null check (cost_cached >= 0),
  cost_external int not null,
  hardcover_per_minute int not null check (hardcover_per_minute >= 0),
  hardcover_per_day int not null check (hardcover_per_day >= 0),
  check (cost_external >= cost_cached)
);

-- Unités : une recherche servie par le cache coûte 1, une recherche qui
-- interroge les sources coûte 10. Soit, par utilisateur, 30 recherches
-- externes par minute (un scan toutes les 2 s) et 600 par jour (une
-- bibliothèque entière scannée d'un coup), ou dix fois plus servies par le
-- cache. Hardcover : 50/min et 4 000/jour, sous le quota de 60 et 5 000.
insert into public.rate_limit_settings
  (user_per_minute, user_per_day, cost_cached, cost_external, hardcover_per_minute, hardcover_per_day)
values (300, 6000, 1, 10, 50, 4000);

create table public.rate_limit_counters (
  bucket text not null,                -- « user:<uuid> » ou « hardcover »
  period text not null check (period in ('minute', 'day')),
  window_start timestamptz not null,
  hits int not null default 0,
  primary key (bucket, period, window_start)
);

create index rate_limit_counters_window_start_idx on public.rate_limit_counters (window_start);

alter table public.rate_limit_settings enable row level security;
alter table public.rate_limit_counters enable row level security;
revoke all on public.rate_limit_settings from public, anon, authenticated;
revoke all on public.rate_limit_counters from public, anon, authenticated;

-- Prend p_cost unités dans les fenêtres minute et jour de p_bucket, seulement
-- si les deux restent sous leur plafond. Renvoie 0 si c'est pris, sinon le
-- nombre de secondes avant l'ouverture de la fenêtre pleine (Retry-After).
-- Les deux lignes sont verrouillées dans un ordre fixe : deux appels
-- concurrents sur le même bucket passent l'un après l'autre.
create or replace function public.rate_limit_take(
  p_bucket text,
  p_cost int,
  p_per_minute int,
  p_per_day int
)
returns int
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_minute timestamptz := date_trunc('minute', v_now);
  v_day timestamptz := date_trunc('day', v_now, 'UTC');
  v_minute_hits int;
  v_day_hits int;
begin
  if p_cost <= 0 then
    return 0;
  end if;

  insert into public.rate_limit_counters (bucket, period, window_start)
  values (p_bucket, 'minute', v_minute), (p_bucket, 'day', v_day)
  on conflict do nothing;

  select hits into v_minute_hits from public.rate_limit_counters
   where bucket = p_bucket and period = 'minute' and window_start = v_minute
     for update;
  select hits into v_day_hits from public.rate_limit_counters
   where bucket = p_bucket and period = 'day' and window_start = v_day
     for update;

  if v_minute_hits + p_cost > p_per_minute then
    return greatest(1, ceil(extract(epoch from v_minute + interval '1 minute' - v_now))::int);
  end if;
  if v_day_hits + p_cost > p_per_day then
    return greatest(1, ceil(extract(epoch from v_day + interval '1 day' - v_now))::int);
  end if;

  update public.rate_limit_counters set hits = hits + p_cost
   where bucket = p_bucket
     and ((period = 'minute' and window_start = v_minute) or (period = 'day' and window_start = v_day));

  -- Ménage occasionnel des fenêtres closes depuis plus de deux jours.
  if random() < 0.01 then
    delete from public.rate_limit_counters where window_start < v_now - interval '2 days';
  end if;

  return 0;
end;
$$;

-- Limite par utilisateur de search-books.
--   p_step = 'request'  : à chaque appel (coût cost_cached) ;
--   p_step = 'external' : avant d'interroger les sources (complément jusqu'à
--                         cost_external).
-- Renvoie 0 si l'appel peut continuer, sinon le délai Retry-After en secondes.
create or replace function public.search_books_rate_limit(p_user uuid, p_step text)
returns int
language plpgsql
set search_path = ''
as $$
declare
  s public.rate_limit_settings;
  v_cost int;
begin
  if p_user is null then
    raise exception 'search_books_rate_limit: utilisateur requis' using errcode = '22023';
  end if;
  select * into strict s from public.rate_limit_settings;
  v_cost := case p_step
    when 'request' then s.cost_cached
    when 'external' then s.cost_external - s.cost_cached
  end;
  if v_cost is null then
    raise exception 'search_books_rate_limit: étape inconnue « % »', p_step using errcode = '22023';
  end if;
  return public.rate_limit_take('user:' || p_user, v_cost, s.user_per_minute, s.user_per_day);
end;
$$;

-- Plafond global des appels sortants vers Hardcover : true si l'appel peut
-- partir (et il est alors compté), false si le plafond est atteint.
create or replace function public.hardcover_take()
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  s public.rate_limit_settings;
begin
  select * into strict s from public.rate_limit_settings;
  return public.rate_limit_take('hardcover', 1, s.hardcover_per_minute, s.hardcover_per_day) = 0;
end;
$$;

revoke all on function public.rate_limit_take(text, int, int, int) from public, anon, authenticated;
revoke all on function public.search_books_rate_limit(uuid, text) from public, anon, authenticated;
revoke all on function public.hardcover_take() from public, anon, authenticated;
grant execute on function public.rate_limit_take(text, int, int, int) to service_role;
grant execute on function public.search_books_rate_limit(uuid, text) to service_role;
grant execute on function public.hardcover_take() to service_role;
grant select, insert, update, delete on public.rate_limit_counters to service_role;
grant select, update on public.rate_limit_settings to service_role;
