-- Game sessions: two teams attacking opposite hoops on a full court.
-- Team attribution is rim-derived on device (which hoop the shot targeted);
-- events in practice/drill/freethrow sessions keep team null.
-- Shot court_x/court_y stay half-court normalized RELATIVE TO THE ATTACKED
-- HOOP (the app mirrors far-half shots), so zone charts need no changes.

alter table public.sessions
  add column team_a text check (char_length(team_a) between 1 and 60),
  add column team_b text check (char_length(team_b) between 1 and 60);

alter table public.events
  add column team text check (team in ('A','B'));

-- Per-team aggregates for game sessions; same metric formulas as
-- session_box_scores. security_invoker keeps RLS in force.
create view public.session_team_box_scores
  with (security_invoker = true) as
select
  e.session_id,
  e.team,
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
from public.events e
where e.team is not null
group by e.session_id, e.team;
