-- Teams own players (rosters). Sessions belong to a team; game events are
-- attributed to individual players by jersey number (detected on-device),
-- enabling per-player box scores like a real NBA live app.

create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now()
);

alter table public.teams enable row level security;
create policy "own teams" on public.teams
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table public.players  add column team_id uuid references public.teams (id) on delete set null;
alter table public.sessions add column team_id uuid references public.teams (id) on delete set null;

-- Per-player aggregates within a session (game mode: shooter identified by
-- jersey number on-device → events.player_id). Same formulas as
-- session_box_scores; security_invoker keeps RLS in force.
create view public.session_player_box_scores
  with (security_invoker = true) as
select
  e.session_id,
  e.player_id,
  count(e.id) filter (where e.category <> 'free_throw')             ::int as fga,
  count(e.id) filter (where e.category <> 'free_throw' and e.made)  ::int as fgm,
  count(e.id) filter (where e.category = 'three')                   ::int as three_pa,
  count(e.id) filter (where e.category = 'three' and e.made)        ::int as three_pm,
  count(e.id) filter (where e.category = 'free_throw')              ::int as fta,
  count(e.id) filter (where e.category = 'free_throw' and e.made)   ::int as ftm,
  (  2 * (count(e.id) filter (where e.category not in ('free_throw','three') and e.made))
   + 3 * (count(e.id) filter (where e.category = 'three' and e.made))
   +     (count(e.id) filter (where e.category = 'free_throw' and e.made)) )::int as pts,
  coalesce( (count(e.id) filter (where e.category <> 'free_throw' and e.made))::real
          / nullif(count(e.id) filter (where e.category <> 'free_throw'), 0), 0)   as fg_pct,
  max(e.wall_clock) as updated_at
from public.events e
where e.player_id is not null
group by e.session_id, e.player_id;

-- One-time cleanup: sessions left 'live' forever (app killed without End
-- Session). Anything live and older than 3 hours is over.
update public.sessions
set status = 'ended',
    ended_at = coalesce(ended_at, started_at + interval '1 hour')
where status = 'live'
  and started_at < now() - interval '3 hours';
