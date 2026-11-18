-- Gamification : réglage du jeu dans profiles, badges obtenus dans user_badges.
-- Source de vérité : docs/CONTRAT.md (sections profiles, user_badges, Gamification)
--
-- Jetons, mois au vert et badges se calculent dans l'app. Le serveur garde
-- seulement le réglage, la date de début du décompte et les badges obtenus.

------------------------------------------------------------------------------
-- profiles : gamification_enabled et gamification_started_at
------------------------------------------------------------------------------

-- now() est stable : les comptes existants reçoivent tous l'heure de la
-- migration. Pour un nouveau compte, le trigger handle_new_user insère le
-- profil sans cette colonne : le défaut lui donne l'heure de l'inscription.
alter table public.profiles
  add column gamification_enabled boolean not null default true,
  add column gamification_started_at timestamptz not null default now();

-- Le client ne modifie le profil que par les colonnes accordées (schéma
-- initial). gamification_enabled les rejoint ; gamification_started_at n'est
-- pas accordée : la modifier est refusé (HTTP 403), comme start_size et set_at
-- dans pal_goals. Un privilège par colonne plutôt qu'un trigger : c'est le
-- mécanisme déjà en place sur profiles, le refus est explicite au lieu d'une
-- valeur ignorée en silence, et aucune fonction n'est à maintenir.
grant update (gamification_enabled) on public.profiles to authenticated;

------------------------------------------------------------------------------
-- user_badges — badges obtenus
------------------------------------------------------------------------------

create table public.user_badges (
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  badge_id text not null
    constraint user_badges_badge_id_format check (badge_id ~ '^[a-z0-9_]{2,40}$'),
  earned_at timestamptz not null default now(),
  user_book_id uuid references public.user_books (id) on delete set null,
  primary key (user_id, badge_id)
);

-- Sert au « on delete set null » quand une ligne de user_books est supprimée.
create index user_badges_user_book_id_idx on public.user_badges (user_book_id);

alter table public.user_badges enable row level security;

-- Le propriétaire lit ses badges. Les autres comptes les lisent si le jeu est
-- affiché et si le profil est public ou suivi avec un follow accepté.
create policy "user_badges: lecture"
  on public.user_badges for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (
      select 1 from public.profiles p
      where p.id = user_badges.user_id
        and p.gamification_enabled
        and (
          not p.is_private
          or exists (
            select 1 from public.follows f
            where f.follower_id = (select auth.uid())
              and f.following_id = p.id
              and f.status = 'accepted'
          )
        )
    )
  );

-- Le propriétaire ajoute ses badges, rattachés au besoin à l'un de ses livres.
create policy "user_badges: ajout par le propriétaire"
  on public.user_badges for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and (
      user_book_id is null
      or exists (
        select 1 from public.user_books ub
        where ub.id = user_badges.user_book_id
          and ub.user_id = (select auth.uid())
      )
    )
  );

-- Pas de mise à jour ni de suppression : aucun privilège, donc HTTP 403.
-- L'insertion sans conflit à gérer (on conflict do nothing) ne demande que
-- le privilège insert.
revoke all on public.user_badges from anon, authenticated;
grant select on public.user_badges to authenticated;
grant insert (user_id, badge_id, earned_at, user_book_id) on public.user_badges to authenticated;
