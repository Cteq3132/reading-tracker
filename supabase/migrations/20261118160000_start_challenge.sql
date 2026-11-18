-- Défi démarré par l'utilisateur : gamification_started_at devient nullable
-- et n'est posé que par la RPC start_challenge().
-- Source de vérité : docs/CONTRAT.md (sections profiles et Gamification)
--
-- Plus de période d'installation : rien ne compte tant que le défi n'est pas
-- démarré. Les badges déjà obtenus (user_badges) restent tels quels.

------------------------------------------------------------------------------
-- profiles.gamification_started_at : null tant que le défi n'est pas démarré
------------------------------------------------------------------------------

-- Sans défaut, un nouveau compte démarre à null : le trigger handle_new_user
-- insère le profil sans cette colonne (schéma initial), il n'y a donc rien à
-- y changer.
alter table public.profiles
  alter column gamification_started_at drop not null,
  alter column gamification_started_at drop default;

-- Tous les comptes existants repassent à null : chacun redémarre le défi.
update public.profiles
   set gamification_started_at = null
 where gamification_started_at is not null;

-- Le client n'écrit toujours pas la colonne : elle n'a jamais été accordée à
-- authenticated (seuls username, display_name, avatar_url, is_private et
-- gamification_enabled le sont). Un PATCH qui la porte reste refusé (HTTP 403).

------------------------------------------------------------------------------
-- start_challenge() — démarre le défi, une seule fois
------------------------------------------------------------------------------

-- Pose now() si le défi n'est pas démarré, puis renvoie la valeur en place.
-- Un défi démarré ne se redémarre pas : un second appel renvoie la même date.
-- Deux appels simultanés : le second attend le verrou de ligne du premier,
-- revoit la condition « is null » sur la ligne à jour et n'écrit rien ; sa
-- lecture, nouvelle instruction, voit la date posée.
-- Sans session (auth.uid() null) ou sans profil, renvoie null.
create function public.start_challenge()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_started_at timestamptz;
begin
  update public.profiles
     set gamification_started_at = now()
   where id = v_uid
     and gamification_started_at is null
  returning gamification_started_at into v_started_at;

  if v_started_at is null then
    select p.gamification_started_at into v_started_at
      from public.profiles p
     where p.id = v_uid;
  end if;

  return v_started_at;
end;
$$;

revoke all on function public.start_challenge() from public, anon;
grant execute on function public.start_challenge() to authenticated;
