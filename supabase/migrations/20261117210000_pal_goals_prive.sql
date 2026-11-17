-- Objectif PAL privé : table pal_goals, visible du seul propriétaire.
-- Source de vérité : docs/CONTRAT.md
--
-- profiles est lisible par tout utilisateur connecté : l'objectif et la taille
-- de PAL de départ d'un compte privé y étaient visibles de tous. Ils passent
-- dans pal_goals, où seul le propriétaire lit et écrit. Pas de ligne = pas
-- d'objectif.

create table public.pal_goals (
  user_id uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  target int not null constraint pal_goals_target_positive check (target >= 0),
  deadline date,
  start_size int not null,
  set_at timestamptz not null
);

alter table public.pal_goals enable row level security;

create policy "pal_goals: lecture par le propriétaire"
  on public.pal_goals for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy "pal_goals: ajout par le propriétaire"
  on public.pal_goals for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "pal_goals: mise à jour par le propriétaire"
  on public.pal_goals for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "pal_goals: suppression par le propriétaire"
  on public.pal_goals for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- start_size et set_at sont posées par trigger. user_id est modifiable pour
-- que l'upsert de PostgREST (on conflict do update) fonctionne ; la politique
-- de mise à jour l'empêche de changer de propriétaire.
revoke all on public.pal_goals from anon, authenticated;
grant select, delete on public.pal_goals to authenticated;
grant insert (user_id, target, deadline) on public.pal_goals to authenticated;
grant update (user_id, target, deadline) on public.pal_goals to authenticated;

-- Reprise des objectifs posés dans profiles, avant la création du trigger
-- pour garder leur taille de départ et leur date (recalculées si absentes).
insert into public.pal_goals (user_id, target, deadline, start_size, set_at)
select p.id, p.pal_goal_target, p.pal_goal_deadline,
       coalesce(p.pal_goal_start_size,
                (select count(*)::int from public.user_books ub
                  where ub.user_id = p.id and ub.status = 'to_read')),
       coalesce(p.pal_goal_set_at, now())
  from public.profiles p
 where p.pal_goal_target is not null;

-- À l'insertion et quand la cible change : taille actuelle de la PAL (to_read)
-- et now(). Sinon, start_size et set_at gardent leur valeur.
create function public.pal_goals_set_start()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.target is distinct from old.target then
    select count(*)::int into new.start_size
      from public.user_books ub
     where ub.user_id = new.user_id and ub.status = 'to_read';
    new.set_at := now();
  else
    new.start_size := old.start_size;
    new.set_at := old.set_at;
  end if;
  return new;
end;
$$;

create trigger pal_goals_set_start
  before insert or update on public.pal_goals
  for each row execute function public.pal_goals_set_start();

------------------------------------------------------------------------------
-- profiles : l'objectif n'y est plus
------------------------------------------------------------------------------

drop trigger profiles_set_pal_goal on public.profiles;
drop function public.profiles_set_pal_goal();

alter table public.profiles
  drop column pal_goal_target,
  drop column pal_goal_deadline,
  drop column pal_goal_start_size,
  drop column pal_goal_set_at;
