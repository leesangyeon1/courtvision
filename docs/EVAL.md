# EVAL — measured numbers, per engine / model version

Every gate in `docs/superpowers/specs/2026-08-17-tracking-engine-design.md`
lands here. No number, no merge.

## Engine tick cost (P0)

Device / build → run a 10-minute practice session at each rate; read the
`NN ms` in the record status line every ~30 s and note the median; note the
thermal state at 10 min (Settings → Battery shows throttling; the status
tick rate halves under serious/critical).

| date | device | commit | tickHz | slowEvery | ms/tick (median) | thermal @10 min | notes |
|---|---|---|---|---|---|---|---|
| YYYY-MM-DD | iPhone … | … | 5 | 5 | | | |
| YYYY-MM-DD | iPhone … | … | 8 | 8 | | | |
| YYYY-MM-DD | iPhone … | … | 10 | 10 | | | |

Chosen default: `Engine.Config.tickHz = 8` (provisional — the pre-engine ball
loop ran at 8 Hz; replace with the highest rate whose ms/tick stays under
1000/tickHz with headroom and no serious thermal state at 10 min).

## Shot events (P1)

Filled by `tools/eval_events.py --append docs/EVAL.md`.

| date | commit | clip | attempts GT | P | R | make/miss acc | loc median ft | loc p90 ft |
|---|---|---|---|---|---|---|---|---|
| 2026-08-17 | 102d842 | freethrow | 1 | 1.00 | 1.00 | 0.00 | — | — |
