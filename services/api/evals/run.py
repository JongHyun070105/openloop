from __future__ import annotations

import argparse
import logging
import math
import mimetypes
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable, Protocol

import httpx
from dotenv import load_dotenv

from app.analyzer import AnalysisAdapter, analysis_adapter_from_env
from app.models import AnalyzeRequest, AnalyzeResponse
from app.secrets import load_provider_secrets_from_env
from evals.schema import EvalCase, load_cases


ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"}


class HarnessConfigurationError(ValueError):
    """A safe-to-display validation failure produced by this harness."""


class Evaluator(Protocol):
    provider: str

    def evaluate_text(self, case: EvalCase) -> AnalyzeResponse: ...

    def evaluate_image(self, case: EvalCase, image_path: Path) -> AnalyzeResponse: ...


class AdapterEvaluator:
    def __init__(self, adapter: AnalysisAdapter) -> None:
        self.adapter = adapter
        self.provider = adapter.provider

    def evaluate_text(self, case: EvalCase) -> AnalyzeResponse:
        return self.adapter.analyze(
            AnalyzeRequest(
                # `reference_at` is a first-class request field. Do not prefix it
                # into user text: an ISO date in the content channel can be
                # mistaken for an event date and would not match Flutter's real
                # request shape.
                text=case.input,
                source="text",
                reference_at=datetime.fromisoformat(case.reference_at),
            )
        )

    def evaluate_image(self, case: EvalCase, image_path: Path) -> AnalyzeResponse:
        content_type = mimetypes.guess_type(image_path.name)[0] or "application/octet-stream"
        return self.adapter.analyze_image(
            filename="critical-capture" + image_path.suffix.lower(),
            content_type=content_type,
            content=image_path.read_bytes(),
            companion_text=case.input,
            source="image",
            reference_at=datetime.fromisoformat(case.reference_at),
        )


class ApiEvaluator:
    provider = "api"

    def __init__(self, base_url: str, timeout_seconds: float) -> None:
        self.client = httpx.Client(base_url=base_url.rstrip("/"), timeout=timeout_seconds)

    def evaluate_text(self, case: EvalCase) -> AnalyzeResponse:
        response = self.client.post(
            "/v1/analyze",
            json={
                "text": case.input,
                "source": "text",
                "reference_at": case.reference_at,
            },
        )
        response.raise_for_status()
        return AnalyzeResponse.model_validate(response.json())

    def evaluate_image(self, case: EvalCase, image_path: Path) -> AnalyzeResponse:
        content_type = mimetypes.guess_type(image_path.name)[0] or "application/octet-stream"
        with image_path.open("rb") as image:
            response = self.client.post(
                "/v1/analyze/image",
                files={"file": ("critical-capture" + image_path.suffix.lower(), image, content_type)},
                data={
                    "companion_text": case.input,
                    "source": "image",
                    "reference_at": case.reference_at,
                },
            )
        response.raise_for_status()
        return AnalyzeResponse.model_validate(response.json())


@dataclass
class Scoreboard:
    total: int = 0
    correct: dict[str, int] = field(
        default_factory=lambda: {
            "field": 0,
            "date": 0,
            "time": 0,
            "location": 0,
            "final_agreement": 0,
        }
    )
    failures: dict[str, list[str]] = field(default_factory=dict)
    provider_errors: list[str] = field(default_factory=list)

    def add(self, case: EvalCase, result: AnalyzeResponse) -> None:
        expected = case.expected
        actual_place = result.event.place.name if result.event.place else None
        actual_date = result.event.date.isoformat() if result.event.date else None
        actual_time = result.event.start_time.strftime("%H:%M") if result.event.start_time else None
        comparisons = {
            "field": (
                result.event.type.value == expected.intent
                and set(result.event.missing_fields) == set(expected.missing_fields)
            ),
            "date": actual_date == expected.date,
            "time": actual_time == expected.time,
            "location": actual_place == expected.place,
            "final_agreement": (
                actual_date,
                actual_time,
                actual_place,
            )
            == (
                expected.final_agreement.date,
                expected.final_agreement.time,
                expected.final_agreement.place,
            ),
        }
        self.total += 1
        failed = []
        for metric, passed in comparisons.items():
            if passed:
                self.correct[metric] += 1
            else:
                failed.append(metric)
        if failed:
            self.failures[case.id] = failed

    def add_provider_error(self, case: EvalCase) -> None:
        self.total += 1
        self.provider_errors.append(case.id)

    def accuracy(self, metric: str) -> float:
        return (self.correct[metric] / self.total * 100) if self.total else 0.0

    def passes(self, minimum_accuracy: float, critical_case: str | None = None) -> bool:
        metrics_pass = all(
            self.accuracy(metric) >= minimum_accuracy for metric in self.correct
        )
        if critical_case is None:
            return metrics_pass
        critical_pass = (
            critical_case not in self.failures and critical_case not in self.provider_errors
        )
        return metrics_pass and critical_pass

    def print_report(self, provider: str) -> None:
        print(f"provider={provider} cases={self.total}")
        labels = {
            "field": "Field Accuracy",
            "date": "Date Accuracy",
            "time": "Time Accuracy",
            "location": "Location Accuracy",
            "final_agreement": "Final Agreement Accuracy",
        }
        for metric, label in labels.items():
            accuracy = self.accuracy(metric)
            print(f"{label}: {accuracy:.1f}% ({self.correct[metric]}/{self.total})")
        if self.failures:
            print("failed_case_ids:")
            for case_id, metrics in self.failures.items():
                print(f"- {case_id}: {','.join(metrics)}")
        if self.provider_errors:
            print("provider_error_case_ids:")
            for case_id in self.provider_errors:
                print(f"- {case_id}")


def select_cases(
    cases: list[EvalCase], case_ids: list[str] | None, limit: int | None
) -> list[EvalCase]:
    if case_ids:
        requested = set(case_ids)
        selected = [case for case in cases if case.id in requested]
    else:
        selected = list(cases)
    return selected[:limit] if limit else selected


def evaluate_cases(
    evaluator: Evaluator,
    cases: list[EvalCase],
    critical_image: Path | None = None,
    critical_case: str | None = None,
    *,
    delay_seconds: float = 0.0,
    max_attempts: int = 1,
    sleep: Callable[[float], None] = time.sleep,
) -> Scoreboard:
    """Evaluate every selected case without turning a transient provider error into a bad score.

    The production Gemini quota is deliberately modest for this low-cost model.  Pacing
    keeps a 100-case acceptance run below the per-minute request limit, while bounded
    retries absorb an occasional timeout or 429 without hiding a persistent failure.
    """

    scoreboard = Scoreboard()
    for index, case in enumerate(cases):
        for attempt in range(max_attempts):
            try:
                if critical_image and case.id == critical_case:
                    result = evaluator.evaluate_image(case, critical_image)
                else:
                    result = evaluator.evaluate_text(case)
                scoreboard.add(case, result)
                break
            except Exception:
                if attempt + 1 == max_attempts:
                    # A single provider failure must not hide the rest of the benchmark.
                    # Do not render exception messages because SDK errors may contain raw
                    # output or provider metadata.
                    scoreboard.add_provider_error(case)
                    break
                sleep(float(2**attempt))
        if delay_seconds and index + 1 < len(cases):
            sleep(delay_seconds)
    return scoreboard


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the opt-in OpenLoop AI evaluation suite")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--adapter", action="store_true", help="Use adapter configured by environment")
    target.add_argument("--api-base-url", help="Use a running OpenLoop API")
    parser.add_argument("--live", action="store_true", help="Acknowledge live cost and privacy boundary")
    parser.add_argument("--dataset", type=Path, default=Path(__file__).with_name("cases.json"))
    parser.add_argument(
        "--case-id",
        action="append",
        help="Evaluate only this case id; repeat to select multiple cases",
    )
    parser.add_argument("--limit", type=int)
    parser.add_argument(
        "--min-accuracy",
        type=float,
        default=95.0,
        help="Minimum percentage required for every metric (default: 95)",
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--delay-seconds",
        type=float,
        default=4.0,
        help="Minimum delay between live requests to avoid provider rate limits (default: 4)",
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        default=3,
        help="Attempts per case for transient provider failures (default: 3)",
    )
    parser.add_argument("--critical-image", type=Path)
    parser.add_argument("--critical-case", help="Case id whose text expectation applies to the image")
    parser.add_argument(
        "--allow-deterministic",
        action="store_true",
        help="Allow the credential-free adapter for harness smoke testing",
    )
    return parser


def _validate_args(args: argparse.Namespace, cases: list[EvalCase]) -> None:
    if not args.live:
        raise HarnessConfigurationError("live evaluation requires explicit --live acknowledgement")
    if args.limit is not None and args.limit < 1:
        raise HarnessConfigurationError("--limit must be positive")
    if not 0 <= args.min_accuracy <= 100:
        raise HarnessConfigurationError("--min-accuracy must be between 0 and 100")
    if not math.isfinite(args.delay_seconds) or args.delay_seconds < 0:
        raise HarnessConfigurationError("--delay-seconds must be a finite non-negative number")
    if args.max_attempts < 1:
        raise HarnessConfigurationError("--max-attempts must be positive")
    known_ids = {case.id for case in cases}
    if args.case_id:
        unknown_ids = sorted(set(args.case_id) - known_ids)
        if unknown_ids:
            raise HarnessConfigurationError(
                "unknown --case-id: " + ",".join(unknown_ids)
            )
    if bool(args.critical_image) != bool(args.critical_case):
        raise HarnessConfigurationError(
            "--critical-image and --critical-case must be supplied together"
        )
    if args.critical_image:
        if not args.critical_image.is_file():
            raise HarnessConfigurationError("critical image path is not a local file")
        if args.critical_image.stat().st_size > 10 * 1024 * 1024:
            raise HarnessConfigurationError("critical image must be 10 MB or smaller")
        content_type = mimetypes.guess_type(args.critical_image.name)[0]
        if content_type not in ALLOWED_IMAGE_TYPES:
            raise HarnessConfigurationError("critical image type is not supported")
        if args.critical_case not in known_ids:
            raise HarnessConfigurationError("critical case id is not in the dataset")


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        cases = load_cases(args.dataset)
        _validate_args(args, cases)
        if args.adapter:
            load_dotenv()
            load_provider_secrets_from_env()
            adapter = analysis_adapter_from_env()
            if adapter.provider == "deterministic" and not args.allow_deterministic:
                raise HarnessConfigurationError(
                    "configured adapter is deterministic; configure a real provider or pass "
                    "--allow-deterministic for a smoke test"
                )
            evaluator: Evaluator = AdapterEvaluator(adapter)
        else:
            evaluator = ApiEvaluator(args.api_base_url, args.timeout)

        selected = select_cases(cases, args.case_id, args.limit)
        if not selected:
            raise HarnessConfigurationError("case selection is empty")
        if args.critical_case and args.critical_case not in {case.id for case in selected}:
            raise HarnessConfigurationError(
                "critical case is outside the selected case set"
            )
        # The aggregate report already records provider failures by case ID.
        # Keep per-request adapter warnings out of the benchmark output so it
        # cannot become a source of provider metadata or an unreadable log.
        adapter_logger = logging.getLogger("app.analyzer")
        previous_level = adapter_logger.level
        adapter_logger.setLevel(logging.ERROR)
        try:
            scoreboard = evaluate_cases(
                evaluator,
                selected,
                critical_image=args.critical_image,
                critical_case=args.critical_case,
                delay_seconds=args.delay_seconds,
                max_attempts=args.max_attempts,
            )
        finally:
            adapter_logger.setLevel(previous_level)
        scoreboard.print_report(evaluator.provider)
        return 0 if scoreboard.passes(args.min_accuracy, args.critical_case) else 1
    except HarnessConfigurationError as error:
        print(f"evaluation_failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        # Provider validation and HTTP errors can embed response bodies in their
        # string representation. Only the exception class is safe to disclose.
        print(f"evaluation_failed: {type(error).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
