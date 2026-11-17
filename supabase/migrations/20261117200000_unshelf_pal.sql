-- Unshelf : PAL possédée, envies, libération, historique des statuts, objectif PAL.
-- Source de vérité : docs/CONTRAT.md
--
-- user_books        : statuts wishlist et released, colonne status_changed_at
-- user_book_events  : historique écrit uniquement par trigger
-- profiles          : objectif PAL (cible, échéance, taille de départ, date)
--
-- Reprise de l'existant : un événement null → status daté du created_at de
-- chaque user_books, et status_changed_at = created_at.

------------------------------------------------------------------------------
-- user_books : nouveaux statuts et status_changed_at
------------------------------------------------------------------------------

alter table public.user_books
  drop constraint user_books_status_check,
  add constraint user_books_status_check
    check (status in ('wishlist', 'to_read', 'reading', 'read', 'abandoned', 'released'));

alter table public.user_books add column status_changed_at timestamptz;

-- La reprise ne doit pas faire avancer updated_at (ordre de friends_activity).
alter table public.user_books disable trigger user_books_set_updated_at;
update public.user_books set status_changed_at = created_at;
alter table public.user_books enable trigger user_books_set_updated_at;

alter table public.user_books
  alter column status_changed_at set not null,
  alter column status_changed_at set default now();

-- Posée à l'insertion et à chaque changement de statut ; toute autre valeur
-- envoyée par le client est ignorée. Ne touche pas aux dates de lecture
-- (trigger user_books_set_dates) ni à updated_at (user_books_set_updated_at).
create function public.user_books_set_status_changed_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    new.status_changed_at := now();
  else
    new.status_changed_at := old.status_changed_at;
  end if;
  return new;
end;
$$;

create trigger user_books_set_status_changed_at
  before insert or update on public.user_books
  for each row execute function public.user_books_set_status_changed_at();

------------------------------------------------------------------------------
-- user_book_events — historique des statuts
------------------------------------------------------------------------------

create table public.user_book_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  user_book_id uuid references public.user_books (id) on delete set null,
  book_id uuid not null references public.books (id),
  from_status text,
  to_status text,
  occurred_at timestamptz not null default now()
);

create index user_book_events_user_id_occurred_at_idx on public.user_book_events (user_id, occurred_at);
-- Sert au « on delete set null » quand une ligne de user_books est supprimée.
create index user_book_events_user_book_id_idx on public.user_book_events (user_book_id);

alter table public.user_book_events enable row level security;

-- Mêmes règles de lecture que user_books.
create policy "user_book_events: lecture"
  on public.user_book_events for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.profiles p
      where p.id = user_book_events.user_id and not p.is_private
    )
    or exists (
      select 1 from public.follows f
      where f.follower_id = (select auth.uid())
        and f.following_id = user_book_events.user_id
        and f.status = 'accepted'
    )
  );

-- Écrite uniquement par trigger.
revoke all on public.user_book_events from anon, authenticated;
grant select on public.user_book_events to authenticated;

-- Reprise de l'existant, avant la création du trigger.
insert into public.user_book_events (user_id, user_book_id, book_id, from_status, to_status, occurred_at)
select ub.user_id, ub.id, ub.book_id, null, ub.status, ub.created_at
  from public.user_books ub;

-- Un événement à l'insertion, à chaque changement de statut et à la
-- suppression. Après la suppression, la ligne n'existe plus : user_book_id est
-- null, comme pour les événements antérieurs (on delete set null).
create function public.user_books_log_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.user_book_events (user_id, user_book_id, book_id, from_status, to_status)
    values (new.user_id, new.id, new.book_id, null, new.status);
  elsif tg_op = 'UPDATE' then
    if new.status is distinct from old.status then
      insert into public.user_book_events (user_id, user_book_id, book_id, from_status, to_status)
      values (new.user_id, new.id, new.book_id, old.status, new.status);
    end if;
  elsif tg_op = 'DELETE' then
    -- Suppression du compte : le profil est déjà parti, l'historique aussi.
    if exists (select 1 from public.profiles p where p.id = old.user_id) then
      insert into public.user_book_events (user_id, user_book_id, book_id, from_status, to_status)
      values (old.user_id, null, old.book_id, old.status, null);
    end if;
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.user_books_log_event() from public, anon, authenticated;

create trigger user_books_log_event
  after insert or delete or update of status on public.user_books
  for each row execute function public.user_books_log_event();

------------------------------------------------------------------------------
-- profiles : objectif PAL
------------------------------------------------------------------------------

alter table public.profiles
  add column pal_goal_target int constraint profiles_pal_goal_target_positive check (pal_goal_target >= 0),
  add column pal_goal_deadline date,
  add column pal_goal_start_size int,
  add column pal_goal_set_at timestamptz;

-- Le client écrit la cible et l'échéance ; la taille de départ et la date sont
-- posées par trigger.
grant update (pal_goal_target, pal_goal_deadline) on public.profiles to authenticated;

-- Quand la cible change : taille actuelle de la PAL (to_read) et now(). Sans
-- objectif (cible null), les deux sont remises à null. Sinon, elles gardent
-- leur valeur, quoi qu'on envoie.
create function public.profiles_set_pal_goal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.pal_goal_target is distinct from old.pal_goal_target then
    if new.pal_goal_target is null then
      new.pal_goal_start_size := null;
      new.pal_goal_set_at := null;
    else
      select count(*)::int into new.pal_goal_start_size
        from public.user_books ub
       where ub.user_id = new.id and ub.status = 'to_read';
      new.pal_goal_set_at := now();
    end if;
  else
    new.pal_goal_start_size := old.pal_goal_start_size;
    new.pal_goal_set_at := old.pal_goal_set_at;
  end if;
  return new;
end;
$$;

revoke all on function public.profiles_set_pal_goal() from public, anon, authenticated;

create trigger profiles_set_pal_goal
  before update on public.profiles
  for each row execute function public.profiles_set_pal_goal();
