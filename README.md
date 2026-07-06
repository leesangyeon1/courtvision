# CourtVision

Basketball shooting analytics in the class of HomeCourt / Ball AI / SwingVision /
Rapsodo MLM: the phone does all the computer vision on-device, the server is a
thin metric relay, and a web dashboard shows shooting analytics live.

**V1 scope (this repo): shooting metrics only** — make/miss, shot category,
court location (homography → heatmap), and shooting splits (FG% / 3P% / FT% /
eFG% / TS%), live on the dashboard within 10 seconds.

```
iOS app (on-device CV) ──WebSocket/REST──▶ FastAPI ──▶ Postgres + Redis
                                              │
                                    WebSocket push / 10s poll
                                              ▼
                                       React dashboard
```

## Layout

| Path | What |
|---|---|
| `server/` | FastAPI thin relay: validate → store → aggregate → push. **No CV here.** |
| `server/app/schemas.py` | **The contract.** Pydantic single source of truth (camelCase wire). |
| `web/` | React 18 + Vite + TanStack Query dashboard (WS push + guaranteed 10 s poll). |
| `ios/` | SwiftUI capture app: Vision trajectory + pose, rim detection, homography. |
| `tools/` | `simulate_session.py` — replays a scripted session; acceptance harness. |

## Run

```sh
docker compose up            # api :8000 + postgres + redis
cd web && npm i && npm run dev   # dashboard on :5173
```

Local dev without Docker: `cd server && pip install -e '.[dev]' && uvicorn app.main:app`
(uses SQLite + in-process live hub; Postgres/Redis engage via env vars).

## The 10-second contract

Every shot the app detects must appear on the dashboard within 10 s:
WebSocket push is the fast path (<1 s), a 10 s poll of
`GET /api/sessions/:id/live` is the guaranteed fallback. No hardcoded data
anywhere — if the server is down, the dashboard shows *reconnecting*, not fakes.
