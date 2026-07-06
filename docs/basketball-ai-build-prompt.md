# Build Prompt — "CourtVision" Basketball Analytics Platform

> Hand this document to an AI coding agent (or a dev team). It specifies how to
> turn the `basketball-anal-archieve` POC into a real, live product in the class
> of **HomeCourt, Ball AI, SwingVision, Basketball Shot Bot, Ballogy, Shot Count**.
>
> **Two versions in one spec:**
> - **V1 (ship first): shooting metrics only** — make/miss + shot category +
>   court location/heatmap, sent live to a web dashboard.
> - **V2 (next): everything else** — passing/assist, rebound, steal, block,
>   turnover, and multi-player attribution.
>
> Build V1 end-to-end first. Do not start V2 until V1 meets its Definition of Done.

---

## 0. Core architecture (read first)

All computer vision runs **on the device**. The server never does CV — it only
receives, stores, aggregates, and serves **metrics**. This is how HomeCourt / Ball
AI / SwingVision / Ballogy / Shot Count work, and it means **no GPU server, no
heavy hosting** — a thin API is enough.

```
┌──────────────────────────────┐   metrics only (JSON)    ┌───────────────┐
│  Mobile App (on-device CV)   │  WebSocket (live)         │  Thin Server  │
│  • NPU detection 30–60 FPS   │ ───────────────────────▶ │  (FastAPI)    │
│    ball + rim (YOLO-nano/     │  REST (sync/backfill)     │  validate →   │
│    MobileNet → CoreML/TFLite) │ ◀───────────────────────▶│  store → agg  │
│  • Pose (Apple Vision)        │                           └──────┬────────┘
│  • Homography court mapping   │                                  │
│  • Computes shooting metrics  │                    ┌─────────────┴─────────┐
│  • Offline queue              │                    │ Postgres  +  Redis     │
└──────────────────────────────┘                    │ (metrics) (live agg)   │
                                                     └───────────┬───────────┘
                                       WebSocket push / 10s poll │
                                                     ┌───────────▼───────────┐
                                                     │  Web Dashboard         │
                                                     │  live, refresh ≤10s    │
                                                     └────────────────────────┘
```

**The mechanism (both versions):**
1. App detects a play **on-device** and computes the metric.
2. App **sends the metric** to the server (WebSocket live; REST for sync; offline
   queue so nothing is lost on bad signal).
3. Server validates → stores in DB → updates a live per-session aggregate.
4. Web dashboard shows it **live, auto-refreshing at least every 10 seconds**
   (WebSocket push preferred, 10s poll as the guaranteed fallback).

---

## 1. On-device detection & tracking (the CV core, shared by V1 and V2)

Match what the competitor apps do:

- **Real-time detection:** run on the phone NPU — **Apple Neural Engine** (iOS)
  / **Android NNAPI** (Android) — at **30–60 FPS**.
- **Models:** lightweight mobile detectors — **YOLO-nano family** or **MobileNet**
  — trained/fine-tuned for **basketball + rim**, converted to **CoreML** (iOS)
  and **TensorFlow Lite** (Android). Reference: `ultralytics/yolo-ios-app`.
- **Pose:** Apple **Vision** `VNDetectHumanBodyPoseRequest` (iOS) for the shooter's
  release mechanics; MediaPipe/ML Kit Pose on Android.
- **Homography (court-space mapping):** detect court lines on the 2D camera frame
  — **free-throw line, 3-point line, the key/paint** — and compute a homography
  that maps screen pixels onto a **standard basketball half-court coordinate
  system**. Every shot's floor position is transformed through it, so heatmaps and
  zones reflect **exactly where on the court** the shot was taken. One-time
  calibration per setup (tap/confirm the key lines; SwingVision-style UX), stored
  per session. High-precision mapping is required for credible location metrics.

The POC already has real Vision pose + ball-trajectory detection and a heuristic
classifier — reuse the pose/trajectory plumbing, but **add rim detection and
homography**, which the POC lacks. Keep the heuristic classifier only as a
fallback; the mobile detector above is the real path.

---

## 2. Recommended stack (thin — no GPU, no complex hosting)

- **iOS:** Swift 5.9+, SwiftUI, iOS 17+. CoreML (Neural Engine) for ball+rim,
  Vision for pose, `URLSession` WebSocket + REST, SwiftData for the offline queue.
  *(Android is a later port; keep the metric schema platform-neutral.)*
- **Server (thin relay):** **Python 3.12 + FastAPI** (async REST + WebSocket in
  one process). No CV on the server. Pydantic models are the schema authority →
  **OpenAPI** → generated TS types for web + Swift `Codable` for iOS.
- **Database:** **PostgreSQL 16** via **SQLAlchemy 2.0 async** + **Alembic**.
  (SQLite is acceptable for the very first local milestone; move to Postgres before
  multi-session.)
- **Live layer:** **Redis** — per-session live aggregate + pub/sub to WebSocket
  subscribers; also caches the 10s snapshot. *(Optional at first: an in-process
  dict works for a single-instance MVP; add Redis when you scale past one worker.)*
- **Web:** React 18 + TypeScript + Vite. **TanStack Query** with
  `refetchInterval: 10000` + a WebSocket subscription. **Chart.js** + **three.js**
  (reuse the POC's look; replace its fake data).
- **Dev/run:** `docker compose up` (api + postgres + redis). No cloud GPU needed.

---

## 3. Metric contract (Pydantic = single source of truth)

The `type` field and its payload grow from V1 → V2. Everything else is shared.

```py
# Entities (V1 needs Player + Session; Team roster is a V2 concern)
Player   { id, name, jerseyNumber?, position? }
Session  { id, playerId, mode: 'game'|'practice'|'drill'|'freethrow',
           startedAt, endedAt?, status: 'live'|'ended', calibrationId }

# The atomic unit sent app -> server
MetricEvent {
  id: uuid                          # client-generated; ingest is idempotent on it
  sessionId: uuid
  ts: int                           # ms since session start (monotonic)
  wallClock: str                    # ISO, server-stamped on ingest
  playerId: uuid | null
  confidence: float                 # 0..1 from the on-device model
  source: 'on_device' | 'manual_correction'

  # ---------- V1: shot only ----------
  type: 'shot'
  shot: {
    made: bool
    category: 'layup'|'mid_range'|'three'|'free_throw'|'floater'|'dunk'
    zone: 'paint'|'mid_left'|'mid_right'|'top_key'|'left_corner_3'
        |'right_corner_3'|'left_wing_3'|'right_wing_3'|'top_arc_3'|'ft_line'
    courtX: float                   # 0..1 on the standardized half-court (homography)
    courtY: float
    releaseAngleDeg?: float
    releaseTimeMs?: float
  }

  # ---------- V2: added later (same envelope, new type values) ----------
  # type: 'pass'|'rebound'|'steal'|'block'|'turnover'|'dribble'
  # pass?:   { fromPlayerId?, toPlayerId?, kind:'chest'|'bounce'|'lob'|'outlet'|'skip', ledToAssist: bool }
  # rebound?:{ kind: 'offensive'|'defensive' }
  # (steal/block/turnover/dribble carry playerId + confidence)
}
```

**Server-derived aggregates (cached, served to the dashboard):**
- **V1:** per session/player — FGM/FGA, 3PM/3PA, FTM/FTA, PTS, **FG% / 3P% / FT% /
  eFG% / TS%**; per-zone made/attempted + % ; raw `(courtX, courtY, made)` points
  for the heatmap and 3D court; rolling trend series across sessions.
- **V2 adds:** REB (O/D), AST, STL, BLK, TOV, +/-, assist rate, and multi-player
  box scores.

---

## 4. Live pipeline & the 10-second contract (both versions)

1. **App → server:** open a WebSocket per active session; send each `MetricEvent`
   the instant it's computed on-device. Under poor network, buffer to the SwiftData
   **offline queue** and flush on reconnect — idempotent by `event.id`.
2. **Server ingest:** validate with Pydantic → insert into Postgres → update the
   Redis live aggregate → `PUBLISH session:{id}`.
3. **Server → web (both paths required):**
   - **Push:** dashboard subscribes via WebSocket; server pushes the updated
     aggregate on change (sub-second).
   - **Poll fallback:** `GET /api/sessions/:id/live` returns the Redis snapshot;
     the dashboard polls it **every 10 s** so it stays live even if the socket drops.
4. **Freshness UI:** "live • updated Ns ago"; show reconnecting if no update >20 s.

**Acceptance (V1):** with the app recording, a made 3-pointer appears on the web
shot chart + shooting splits **within 10 seconds** (typically <1 s via WebSocket),
and survives a page refresh, with no manual action.

---

## 5. API surface

```
Auth        POST /api/auth/login   /register   /refresh          (JWT)
Players     GET/POST /api/players
Sessions    POST /api/sessions                 # start -> {id, wsUrl}
            PATCH /api/sessions/:id             # end
            GET  /api/sessions?playerId=&mode=  # list + filters
            GET  /api/sessions/:id              # detail + box score
            GET  /api/sessions/:id/live         # Redis snapshot (10s poll target)
            GET  /api/sessions/:id/shots        # raw shot points (chart/3D/heatmap)
Events      POST /api/sessions/:id/events       # REST batch sync (idempotent)
Calibration POST /api/sessions/:id/calibration  # store homography for the session

WebSocket  /ws
  app→server:  { type:'event', ...MetricEvent }
  web→server:  { subscribe: sessionId }
  server→web:  { type:'aggregate', sessionId, boxScore, shotChart, updatedAt }
```

---

# VERSION 1 — Shooting metrics only (ship this first)

**Scope:** a single shooter records a session; the app detects each shot on-device
and sends the metric; the dashboard shows shooting analytics live.

### V1 metrics (exactly these — nothing else)
- **Make / miss** — from on-device **ball + rim detection**: ball enters the rim
  region from above with a downward vector and exits below = **made**; rim/backboard
  contact then diverge, or trajectory misses the region = **miss**.
- **Shot category** — `layup | mid_range | three | free_throw | floater | dunk`,
  derived from location + release mechanics + context (FT from the line).
- **Court location** — shooter's foot midpoint (ankle keypoints) at release →
  **homography** → `(courtX, courtY)` → **zone**. Powers the **heatmap**.
- **Shooting splits** — FG%, 3P%, FT%, eFG%, TS%, per-zone %.
- **Release quality (nice-to-have if cheap)** — release angle, release time.

### V1 build order
1. **Contract & thin server:** Pydantic schema + OpenAPI codegen, FastAPI with the
   §5 endpoints (shot-only), Postgres + Alembic, JWT, `docker compose up`, CI.
   *Verify:* create player + session via API; app authenticates.
2. **On-device shot detection:** add rim detection (YOLO-nano/MobileNet → CoreML)
   to the existing ball trajectory + pose; implement make/miss + category.
   *Verify:* on 20 labeled clips, make/miss accuracy ≥ agreed threshold.
3. **Homography + location:** court-line calibration UX → homography → per-shot
   `(courtX, courtY)` + zone. *Verify:* known spots map to the correct zone.
4. **Live pipeline:** WebSocket send + offline queue → ingest → Redis aggregate →
   dashboard WebSocket + 10 s poll. *Verify:* the §4 acceptance test.
5. **Dashboard (reuse POC look, kill fake data):** live shot chart + heatmap + 3D
   court + shooting splits + trends, all server-fed. Delete `data.js` arrays and the
   `Math.random()` shot generator.

### V1 Definition of Done
1. Shooter records; a remote viewer sees each **made/missed shot at the correct
   court location** on the web **within 10 s**.
2. All dashboard shooting data is **100% server-derived** — no hardcoded/random data.
3. Killing wifi mid-session loses **no shots** (offline queue replays, no dupes).
4. App, server, and web share **one schema**; a schema change breaks all three
   builds until reconciled.
5. eFG% / TS% / per-zone % match hand-computed values on a test fixture.
6. Runs from `docker compose up`; health checks green.

---

# VERSION 2 — Passing, rebound, steal & team tracking (next release)

**Only after V1 is done.** Same architecture and envelope; adds event types and
multi-player attribution — the genuinely hard part on a single camera.

### V2 adds
- **New on-device events:** `pass`, `rebound` (offensive/defensive), `steal`,
  `block`, `turnover`, `dribble`.
- **Multi-player tracking + re-ID:** detect all players (YOLO person class),
  maintain stable tracks (ByteTrack/DeepSORT-style association) **on-device**, and
  map each track to a roster player via **jersey-number OCR** + team-color/appearance
  cues, with a **manual assignment tap** at tip-off as the reliable fallback.
- **Attribution rules:**
  - **pass** = ball possession transfers between two tracked players.
  - **assist** = a pass whose receiver scores within ~4 s (tunable).
  - **rebound** = possession gained near the rim after a miss (O vs D by team).
  - **steal** = possession change caused by a defender's action.
  - **block** = defender contacts a shot attempt, altering its trajectory.
- **Team entities:** add `Team` + roster; multi-player box scores; 5-man lineup
  net rating; assist rate, AST/TO.
- **Manual-correction UX:** live + post-session review screen to reassign player or
  fix make/miss — emits `source:'manual_correction'` events that override aggregates.

### V2 risk notes
- Multi-player re-ID on one phone is the top risk — prototype it on real 5-on-5
  footage before committing metric breadth on top of it.
- Keep everything gated by `confidence`; when re-ID is uncertain, prompt the manual
  tap rather than guessing the wrong player.

### V2 Definition of Done
1. In a 5-on-5 clip, pass/assist/rebound/steal/block are attributed to the correct
   players with surfaced confidence, live to the dashboard within 10 s.
2. Team + per-player box scores are fully server-derived and match a hand-scored
   fixture.
3. Manual corrections propagate to aggregates and persist.

---

## Guardrails (both versions)
- All CV is **on-device**; the server does **no** CV and needs **no GPU**.
- Delete the POC's hardcoded `data.js` / `Math.random()` shots.
- Don't start V2 until V1's Definition of Done is met.
- Don't emit low-confidence events as fact — gate them behind `confidence` +
  manual review.
