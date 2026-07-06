"""CourtVision metric contract — the single source of truth (spec §3).

Wire format is camelCase JSON. Pydantic models here drive:
  * FastAPI request/response validation and the OpenAPI document
  * generated TypeScript types for the web dashboard (npm run gen:types)
  * the Swift Codable mirror in ios/CourtVision/Models/Contract.swift

V1 carries shot events only. V2 will add new `type` values to the same
envelope — never change the envelope shape without bumping all three builds.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel


class ContractModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        from_attributes=True,
    )


# ---------------------------------------------------------------- enums

class SessionMode(str, enum.Enum):
    game = "game"
    practice = "practice"
    drill = "drill"
    freethrow = "freethrow"


class SessionStatus(str, enum.Enum):
    live = "live"
    ended = "ended"


class EventSource(str, enum.Enum):
    on_device = "on_device"
    manual_correction = "manual_correction"


class ShotCategory(str, enum.Enum):
    layup = "layup"
    mid_range = "mid_range"
    three = "three"
    free_throw = "free_throw"
    floater = "floater"
    dunk = "dunk"


class CourtZone(str, enum.Enum):
    paint = "paint"
    mid_left = "mid_left"
    mid_right = "mid_right"
    top_key = "top_key"
    left_corner_3 = "left_corner_3"
    right_corner_3 = "right_corner_3"
    left_wing_3 = "left_wing_3"
    right_wing_3 = "right_wing_3"
    top_arc_3 = "top_arc_3"
    ft_line = "ft_line"


THREE_POINT_ZONES = {
    CourtZone.left_corner_3,
    CourtZone.right_corner_3,
    CourtZone.left_wing_3,
    CourtZone.right_wing_3,
    CourtZone.top_arc_3,
}


# ---------------------------------------------------------------- entities

class PlayerCreate(ContractModel):
    name: str = Field(min_length=1, max_length=120)
    jersey_number: Optional[int] = Field(default=None, ge=0, le=99)
    position: Optional[str] = Field(default=None, max_length=32)


class Player(PlayerCreate):
    id: uuid.UUID


class SessionCreate(ContractModel):
    player_id: uuid.UUID
    mode: SessionMode


class Session(ContractModel):
    id: uuid.UUID
    player_id: uuid.UUID
    mode: SessionMode
    started_at: datetime
    ended_at: Optional[datetime] = None
    status: SessionStatus
    calibration_id: Optional[uuid.UUID] = None


class SessionStartResponse(ContractModel):
    """POST /api/sessions → the app opens `ws_url` and starts streaming."""

    session: Session
    ws_url: str


class SessionEnd(ContractModel):
    status: SessionStatus = SessionStatus.ended


# ---------------------------------------------------------------- calibration

class CalibrationCreate(ContractModel):
    """Homography mapping camera pixels → standardized half-court (0..1 × 0..1).

    Row-major 3×3 matrix. Computed on-device from the court-line calibration
    UX; stored server-side so a session's shots can be re-projected later.
    """

    homography: list[float] = Field(min_length=9, max_length=9)
    image_points: Optional[list[list[float]]] = None
    court_points: Optional[list[list[float]]] = None


class Calibration(CalibrationCreate):
    id: uuid.UUID
    session_id: uuid.UUID


# ---------------------------------------------------------------- events

class ShotPayload(ContractModel):
    made: bool
    category: ShotCategory
    zone: CourtZone
    court_x: float = Field(ge=0.0, le=1.0)
    court_y: float = Field(ge=0.0, le=1.0)
    release_angle_deg: Optional[float] = None
    release_time_ms: Optional[float] = None


class MetricEvent(ContractModel):
    """The atomic unit sent app → server. Ingest is idempotent on `id`."""

    id: uuid.UUID
    session_id: uuid.UUID
    ts: int = Field(ge=0, description="ms since session start (monotonic)")
    wall_clock: Optional[datetime] = Field(
        default=None, description="server-stamped on ingest; clients may omit"
    )
    player_id: Optional[uuid.UUID] = None
    confidence: float = Field(ge=0.0, le=1.0)
    source: EventSource = EventSource.on_device
    type: str = Field(pattern="^shot$")
    shot: ShotPayload


class EventBatch(ContractModel):
    """REST backfill body (offline-queue flush). Idempotent per event id."""

    events: list[MetricEvent]


class EventIngestResult(ContractModel):
    accepted: int
    duplicates: int


# ---------------------------------------------------------------- aggregates

class ZoneLine(ContractModel):
    made: int = 0
    attempted: int = 0
    pct: float = 0.0


class BoxScore(ContractModel):
    fgm: int = 0
    fga: int = 0
    three_pm: int = 0
    three_pa: int = 0
    ftm: int = 0
    fta: int = 0
    pts: int = 0
    fg_pct: float = 0.0
    three_pct: float = 0.0
    ft_pct: float = 0.0
    efg_pct: float = 0.0
    ts_pct: float = 0.0
    zones: dict[CourtZone, ZoneLine] = Field(default_factory=dict)


class ShotPoint(ContractModel):
    """Raw point for the shot chart / heatmap / 3D court."""

    id: uuid.UUID
    ts: int
    made: bool
    category: ShotCategory
    zone: CourtZone
    court_x: float
    court_y: float


class LiveSnapshot(ContractModel):
    """GET /api/sessions/:id/live — the dashboard's 10 s poll target."""

    session_id: uuid.UUID
    status: SessionStatus
    box_score: BoxScore
    shot_chart: list[ShotPoint]
    updated_at: datetime


class SessionDetail(ContractModel):
    session: Session
    player: Player
    box_score: BoxScore


class TrendPoint(ContractModel):
    """One ended session's summary, for cross-session trend lines."""

    session_id: uuid.UUID
    started_at: datetime
    fg_pct: float
    three_pct: float
    ft_pct: float
    efg_pct: float
    ts_pct: float
    pts: int


# ---------------------------------------------------------------- auth

class RegisterRequest(ContractModel):
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    password: str = Field(min_length=8, max_length=128)
    name: str = Field(min_length=1, max_length=120)


class LoginRequest(ContractModel):
    email: str
    password: str


class RefreshRequest(ContractModel):
    refresh_token: str


class TokenPair(ContractModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


# ---------------------------------------------------------------- websocket

class WsClientEvent(ContractModel):
    """app → server over /ws"""

    type: str = Field(pattern="^event$")
    event: MetricEvent


class WsSubscribe(ContractModel):
    """web → server over /ws"""

    subscribe: uuid.UUID


class WsAggregatePush(ContractModel):
    """server → web over /ws"""

    type: str = Field(pattern="^aggregate$")
    session_id: uuid.UUID
    box_score: BoxScore
    shot_chart: list[ShotPoint]
    updated_at: datetime
