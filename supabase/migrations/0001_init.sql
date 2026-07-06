-- CourtVision V1 schema — the single source of truth for the metric contract.
-- Apply with `supabase db push` or paste into the Supabase SQL editor.
-- Mirrored by web/src/types/contract.ts and ios/CourtVision/Models/Contract.swift.

-- ---------------------------------------------------------------- tables

create table public.players (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 120),
  jersey_number int  check (jersey_number between 0 and 99),
  position      text check (char_length(position) <= 32),
  created_at    timestamptz not null default now()
);

create table public.sessions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  player_id   uuid not null references public.players (id) on delete cascade,
  mode        text not null check (mode in ('game','practice','drill','freethrow')),
  status      text not null default 'live' check (status in ('live','ended')),
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  -- {"homography": [9 floats, row-major 3x3], "imagePoints": [[x,y]...], "courtPoints": [[x,y]...]}
  calibration jsonb
);

-- One row per detected shot. `id` is client-generated so offline-queue
-- replays are idempotent: insert with on-conflict-do-nothing.
create table public.events (
  id                uuid primary key,
  session_id        uuid not null references public.sessions (id) on delete cascade,
  user_id           uuid not null default auth.uid() references auth.users (id) on delete cascade,
  ts                integer not null check (ts >= 0),  -- ms since session start
  wall_clock        timestamptz not null default now(),
  player_id         uuid references public.players (id),
  confidence        real not null check (confidence >= 0 and confidence <= 1),
  source            text not null default 'on_device'
                    check (source in ('on_device','manual_correction')),
  type              text not null default 'shot' check (type = 'shot'),
  made              boolean not null,
  category          text not null check (category in
                    ('layup','mid_range','three','free_throw','floater','dunk')),
  zone              text not null check (zone in
                    ('paint','mid_left','mid_right','top_key',
                     'left_corner_3','right_corner_3','left_wing_3','right_wing_3',
                     'top_arc_3','ft_line')),
  court_x           real not null check (court_x >= 0 and court_x <= 1),
  court_y           real not null check (court_y >= 0 and court_y <= 1),
  release_angle_deg real,
  release_time_ms   real
);

create index events_session_ts_idx on public.events (session_id, ts);
create index sessions_player_idx   on public.sessions (player_id, started_at desc);

-- ---------------------------------------------------------------- RLS

alter table public.players  enable row level security;
alter table public.sessions enable row level security;
alter table public.events   enable row level security;

create policy "own players" on public.players
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Write policies verify ownership of referenced rows too: FK checks bypass
-- RLS, so without these an authenticated user could attach sessions/events
-- to another user's player/session (and probe for UUID existence).
create policy "select own sessions" on public.sessions
  for select using (user_id = auth.uid());
create policy "insert own sessions" on public.sessions
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.players p
                where p.id = player_id and p.user_id = auth.uid()));
create policy "update own sessions" on public.sessions
  for update using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.players p
                where p.id = player_id and p.user_id = auth.uid()));
create policy "delete own sessions" on public.sessions
  for delete using (user_id = auth.uid());

create policy "select own events" on public.events
  for select using (user_id = auth.uid());
create policy "insert own events" on public.events
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.sessions s
                where s.id = session_id and s.user_id = auth.uid())
    and (player_id is null
         or exists (select 1 from public.players p
                    where p.id = player_id and p.user_id = auth.uid())));
create policy "update own events" on public.events
  for update using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.sessions s
                where s.id = session_id and s.user_id = auth.uid())
    and (player_id is null
         or exists (select 1 from public.players p
                    where p.id = player_id and p.user_id = auth.uid())));
create policy "delete own events" on public.events
  for delete using (user_id = auth.uid());

-- ---------------------------------------------------------------- views
-- Server-derived aggregates (V1 DoD: dashboard math must come from here,
-- not client-side reimplementation). security_invoker keeps RLS in force.

create view public.session_box_scores
  with (security_invoker = true) as
select
  s.id  as session_id,
  s.player_id,
  s.status,
  s.started_at,
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
  coalesce( (count(e.id) filter (where e.category = 'three' and e.made))::real
          / nullif(count(e.id) filter (where e.category = 'three'), 0), 0)         as three_pct,
  coalesce( (count(e.id) filter (where e.category = 'free_throw' and e.made))::real
          / nullif(count(e.id) filter (where e.category = 'free_throw'), 0), 0)    as ft_pct,
  coalesce( ( (count(e.id) filter (where e.category <> 'free_throw' and e.made))
            + 0.5 * (count(e.id) filter (where e.category = 'three' and e.made)) )::real
          / nullif(count(e.id) filter (where e.category <> 'free_throw'), 0), 0)   as efg_pct,
  coalesce( (  2 * (count(e.id) filter (where e.category not in ('free_throw','three') and e.made))
             + 3 * (count(e.id) filter (where e.category = 'three' and e.made))
             +     (count(e.id) filter (where e.category = 'free_throw' and e.made)) )::real
          / nullif( 2 * (  count(e.id) filter (where e.category <> 'free_throw')
                         + 0.44 * (count(e.id) filter (where e.category = 'free_throw')) ), 0), 0)
                                                                                    as ts_pct,
  max(e.wall_clock) as updated_at
from public.sessions s
left join public.events e on e.session_id = s.id
group by s.id;

create view public.session_zone_splits
  with (security_invoker = true) as
select
  e.session_id,
  e.zone,
  count(*) filter (where e.made) ::int as made,
  count(*)                       ::int as attempted,
  (count(*) filter (where e.made))::real / count(*) as pct
from public.events e
group by e.session_id, e.zone;

create view public.player_trends
  with (security_invoker = true) as
select b.player_id, b.session_id, b.started_at,
       b.fg_pct, b.three_pct, b.ft_pct, b.efg_pct, b.ts_pct, b.pts
from public.session_box_scores b
order by b.started_at;

-- ---------------------------------------------------------------- realtime
-- Dashboard subscribes to event inserts (filtered by session_id) for the
-- sub-second path; the 10 s poll of session_box_scores is the fallback.

alter publication supabase_realtime add table public.events;
alter publication supabase_realtime add table public.sessions;
