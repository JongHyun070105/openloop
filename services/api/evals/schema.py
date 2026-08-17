from __future__ import annotations

import json
import re
from collections import Counter
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


EXPECTED_CATEGORY_COUNTS = {
    "clear_appointment": 20,
    "time_change": 20,
    "place_change": 15,
    "relative_date": 15,
    "missing_fields": 15,
    "poster_deadline": 15,
}
CANONICAL_MISSING_FIELDS = {
    "title",
    "date",
    "start_time",
    "place",
    "participants",
    "purpose",
}
_DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_TIME_PATTERN = re.compile(r"^\d{2}:\d{2}$")
_PII_PATTERNS = (
    re.compile(r"[\w.+-]+@[\w.-]+\.\w+"),
    re.compile(r"(?<!\d)01[016789][ -]?\d{3,4}[ -]?\d{4}(?!\d)"),
    re.compile(r"(?<!\d)\d{6}[ -]?[1-4]\d{6}(?!\d)"),
)


@dataclass(frozen=True)
class FinalAgreement:
    date: str | None
    time: str | None
    place: str | None


@dataclass(frozen=True)
class ExpectedFacts:
    intent: str
    date: str | None
    time: str | None
    place: str | None
    missing_fields: tuple[str, ...]
    final_agreement: FinalAgreement


@dataclass(frozen=True)
class EvalCase:
    id: str
    category: str
    timezone: str
    reference_at: str
    input: str
    expected: ExpectedFacts

    @property
    def evaluation_input(self) -> str:
        return (
            f"평가 기준 현재 시각: {self.reference_at} ({self.timezone})\n"
            f"사용자 입력: {self.input}"
        )


def _optional_string(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string or null")
    return value


def _parse_case(raw: dict[str, Any]) -> EvalCase:
    expected = raw["expected"]
    agreement = expected["final_agreement"]
    return EvalCase(
        id=str(raw["id"]),
        category=str(raw["category"]),
        timezone=str(raw["timezone"]),
        reference_at=str(raw["reference_at"]),
        input=str(raw["input"]),
        expected=ExpectedFacts(
            intent=str(expected["intent"]),
            date=_optional_string(expected.get("date"), "expected.date"),
            time=_optional_string(expected.get("time"), "expected.time"),
            place=_optional_string(expected.get("place"), "expected.place"),
            missing_fields=tuple(str(item) for item in expected["missing_fields"]),
            final_agreement=FinalAgreement(
                date=_optional_string(agreement.get("date"), "final_agreement.date"),
                time=_optional_string(agreement.get("time"), "final_agreement.time"),
                place=_optional_string(agreement.get("place"), "final_agreement.place"),
            ),
        ),
    )


def load_cases(path: Path | None = None) -> list[EvalCase]:
    dataset_path = path or Path(__file__).with_name("cases.json")
    raw = json.loads(dataset_path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError("evaluation dataset must be a JSON array")
    cases = [_parse_case(item) for item in raw]
    validate_cases(cases)
    return cases


def validate_cases(cases: list[EvalCase]) -> None:
    if len(cases) != 100:
        raise ValueError(f"dataset must contain exactly 100 cases, got {len(cases)}")
    counts = Counter(case.category for case in cases)
    if counts != Counter(EXPECTED_CATEGORY_COUNTS):
        raise ValueError(f"category distribution mismatch: {dict(counts)}")
    ids = [case.id for case in cases]
    if len(ids) != len(set(ids)):
        raise ValueError("case ids must be unique")

    kst = ZoneInfo("Asia/Seoul")
    for case in cases:
        if case.timezone != "Asia/Seoul":
            raise ValueError(f"{case.id}: timezone must be Asia/Seoul")
        reference = datetime.fromisoformat(case.reference_at)
        if reference.tzinfo is None or reference.utcoffset() != kst.utcoffset(reference):
            raise ValueError(f"{case.id}: reference_at must include the Asia/Seoul offset")
        if not case.input.strip():
            raise ValueError(f"{case.id}: input must not be empty")
        if any(pattern.search(case.input) for pattern in _PII_PATTERNS):
            raise ValueError(f"{case.id}: input contains a forbidden PII-shaped value")
        if case.expected.intent not in {"appointment", "deadline"}:
            raise ValueError(f"{case.id}: invalid intent")
        if not set(case.expected.missing_fields) <= CANONICAL_MISSING_FIELDS:
            raise ValueError(f"{case.id}: invalid missing field")
        if len(case.expected.missing_fields) != len(set(case.expected.missing_fields)):
            raise ValueError(f"{case.id}: duplicate missing field")
        for value, label, pattern in (
            (case.expected.date, "date", _DATE_PATTERN),
            (case.expected.time, "time", _TIME_PATTERN),
        ):
            if value is not None and not pattern.fullmatch(value):
                raise ValueError(f"{case.id}: invalid expected {label}")
        agreement = case.expected.final_agreement
        if (agreement.date, agreement.time, agreement.place) != (
            case.expected.date,
            case.expected.time,
            case.expected.place,
        ):
            raise ValueError(f"{case.id}: final agreement must match expected event facts")
