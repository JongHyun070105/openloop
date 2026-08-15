from datetime import date as Date
from datetime import time as Time
from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field


class Intent(str, Enum):
    APPOINTMENT = "appointment"
    DEADLINE = "deadline"


class LoopStatus(str, Enum):
    OPEN = "open"
    NEEDS_INPUT = "needs_input"
    CLOSED = "closed"


class Confidence(BaseModel):
    date: float = Field(ge=0, le=1)
    time: float = Field(ge=0, le=1)
    location: float = Field(ge=0, le=1)
    title: float = Field(ge=0, le=1)


class Place(BaseModel):
    name: str


class Reminder(BaseModel):
    type: Literal["default", "checkpoint"] = "default"
    offset: str


class StructuredEvent(BaseModel):
    type: Intent
    title: str
    date: Date | None = None
    start_time: Time | None = None
    place: Place | None = None
    participants: list[str] = Field(default_factory=list)
    purpose: str | None = None
    reminders: list[Reminder] = Field(default_factory=list)
    source: Literal["screenshot", "image", "text"]
    confidence: Confidence
    missing_fields: list[str] = Field(default_factory=list)
    resolution_note: str | None = None


class AnalyzeRequest(BaseModel):
    text: str = Field(min_length=1, max_length=20_000)
    source: Literal["screenshot", "image", "text"] = "text"


class AnalyzeResponse(BaseModel):
    status: LoopStatus
    event: StructuredEvent
    suggested_question: str | None = None
