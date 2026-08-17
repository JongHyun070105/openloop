from datetime import date as Date
from datetime import datetime
from datetime import time as Time
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class Intent(str, Enum):
    APPOINTMENT = "appointment"
    DEADLINE = "deadline"
    PLACE = "place"
    COUPON = "coupon"


class LoopStatus(str, Enum):
    OPEN = "open"
    NEEDS_INPUT = "needs_input"
    CLOSED = "closed"


class RetentionPolicy(str, Enum):
    IMMEDIATELY = "immediately"
    SEVEN_DAYS = "7_days"
    THIRTY_DAYS = "30_days"
    KEEP = "keep"


class Confidence(BaseModel):
    model_config = ConfigDict(extra="forbid")

    date: float = Field(ge=0, le=1)
    time: float = Field(ge=0, le=1)
    location: float = Field(ge=0, le=1)
    title: float = Field(ge=0, le=1)


class Place(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str


class Reminder(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["default", "checkpoint"] = "default"
    offset: str


class ChecklistSuggestion(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=300)
    required: bool = True


class StructuredEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Intent
    title: str
    date: Date | None = None
    start_time: Time | None = None
    expires_on: Date | None = None
    place: Place | None = None
    participants: list[str] = Field(default_factory=list)
    purpose: str | None = None
    summary: str | None = Field(default=None, max_length=600)
    reminders: list[Reminder] = Field(default_factory=list)
    checklist: list[ChecklistSuggestion] = Field(default_factory=list)
    source: Literal["screenshot", "image", "text"]
    confidence: Confidence
    missing_fields: list[str] = Field(default_factory=list)
    resolution_note: str | None = None


class AnalyzeRequest(BaseModel):
    text: str = Field(min_length=1, max_length=20_000)
    source: Literal["screenshot", "image", "text"] = "text"
    reference_at: datetime | None = None

    @field_validator("reference_at")
    @classmethod
    def reference_at_requires_timezone(cls, value: datetime | None) -> datetime | None:
        if value is not None and value.tzinfo is None:
            raise ValueError("reference_at must include a timezone")
        return value


class AnalyzeResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: LoopStatus
    event: StructuredEvent
    suggested_question: str | None = None

    @model_validator(mode="after")
    def validate_resolution_state(self) -> "AnalyzeResponse":
        if self.event.missing_fields and self.status != LoopStatus.NEEDS_INPUT:
            raise ValueError("events with missing fields must need input")
        if self.status == LoopStatus.NEEDS_INPUT and not self.event.missing_fields:
            raise ValueError("needs_input requires at least one missing field")
        return self


class ChecklistItem(BaseModel):
    id: str
    title: str = Field(min_length=1, max_length=300)
    required: bool = True
    completed: bool = False


class LoopAction(BaseModel):
    id: str
    type: Literal["calendar", "reminder", "place", "checklist", "coupon"]
    title: str
    completed: bool = False
    metadata: dict[str, Any] = Field(default_factory=dict)


class Checkpoint(BaseModel):
    id: str
    offset: str
    title: str
    due_at: datetime | None = None
    completed: bool = False


class OpenLoop(BaseModel):
    id: str
    owner_id: str = "dev-local"
    status: LoopStatus
    event: StructuredEvent
    suggested_question: str | None = None
    actions: list[LoopAction] = Field(default_factory=list)
    checklist: list[ChecklistItem] = Field(default_factory=list)
    checkpoints: list[Checkpoint] = Field(default_factory=list)
    related_loop_ids: list[str] = Field(default_factory=list)
    retention: RetentionPolicy = RetentionPolicy.KEEP
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None = None
    delete_at: datetime | None = None


class CreateLoopRequest(BaseModel):
    event: StructuredEvent
    status: LoopStatus | None = None
    suggested_question: str | None = None
    actions: list[LoopAction] = Field(default_factory=list)
    checklist: list[ChecklistItem] = Field(default_factory=list)
    checkpoints: list[Checkpoint] = Field(default_factory=list)
    related_loop_ids: list[str] = Field(default_factory=list)
    retention: RetentionPolicy = RetentionPolicy.KEEP

    @model_validator(mode="after")
    def infer_status(self) -> "CreateLoopRequest":
        if self.status is None:
            self.status = LoopStatus.NEEDS_INPUT if self.event.missing_fields else LoopStatus.OPEN
        return self


class AmbiguityUpdate(BaseModel):
    field: Literal[
        "title",
        "date",
        "start_time",
        "expires_on",
        "place",
        "participants",
        "purpose",
    ]
    value: Any


class CompletionRequest(BaseModel):
    retention: RetentionPolicy | None = None


class RetentionUpdate(BaseModel):
    retention: RetentionPolicy


class CompletionUpdate(BaseModel):
    completed: bool


class NormalizedPlace(BaseModel):
    name: str
    address: str
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    kakao_map_url: str


class WeatherForecast(BaseModel):
    available: bool
    summary: str
    temperature_c: float | None = None
    precipitation_probability: int | None = Field(default=None, ge=0, le=100)
    forecast_at: datetime | None = None
    provider: Literal["disabled", "kma"]


class PushTokenRequest(BaseModel):
    token: str = Field(min_length=20, max_length=4096)
    platform: Literal["android", "ios"]


class PushTokenResponse(BaseModel):
    registered: bool
    provider: Literal["disabled", "dynamodb"]


class CapabilitiesResponse(BaseModel):
    analysis_provider: str
    analysis_enabled: bool
    analysis_model: str | None = None
    places_provider: str
    places_enabled: bool
    weather_provider: str
    weather_enabled: bool
    push_provider: str
    push_enabled: bool
    analytics_provider: str
    analytics_enabled: bool
    sentry_enabled: bool
