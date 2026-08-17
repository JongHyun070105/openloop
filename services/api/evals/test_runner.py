import contextlib
import io
import unittest
from unittest.mock import patch

from app.models import AnalyzeResponse
from evals.run import (
    AdapterEvaluator,
    Scoreboard,
    _build_parser,
    evaluate_cases,
    main,
    select_cases,
)
from evals.schema import load_cases


def _exact_result(case) -> AnalyzeResponse:
    return AnalyzeResponse.model_validate(
        {
            "status": "needs_input" if case.expected.missing_fields else "open",
            "event": {
                "type": case.expected.intent,
                "title": "평가 일정",
                "date": case.expected.date,
                "start_time": case.expected.time,
                "place": {"name": case.expected.place} if case.expected.place else None,
                "source": "text",
                "confidence": {"date": 1, "time": 1, "location": 1, "title": 1},
                "missing_fields": list(case.expected.missing_fields),
            },
            "suggested_question": "확인이 필요합니다" if case.expected.missing_fields else None,
        }
    )


class _ExactEvaluator:
    provider = "test"

    def evaluate_text(self, case):
        return _exact_result(case)

    def evaluate_image(self, case, image_path):
        return _exact_result(case)


class _FirstCaseErrorEvaluator(_ExactEvaluator):
    def __init__(self, error_case_id: str) -> None:
        self.error_case_id = error_case_id

    def evaluate_text(self, case):
        if case.id == self.error_case_id:
            raise RuntimeError("raw-secret-provider-body")
        return super().evaluate_text(case)


class _RetryOnceEvaluator(_ExactEvaluator):
    def __init__(self) -> None:
        self.calls = 0

    def evaluate_text(self, case):
        self.calls += 1
        if self.calls == 1:
            raise RuntimeError("transient-provider-failure")
        return super().evaluate_text(case)


class _CapturingAdapter:
    provider = "capture"

    def __init__(self, result: AnalyzeResponse) -> None:
        self.result = result
        self.request = None

    def analyze(self, request):
        self.request = request
        return self.result


class EvaluationRunnerTests(unittest.TestCase):
    def test_minimum_accuracy_defaults_to_ninety_five_percent(self) -> None:
        args = _build_parser().parse_args(
            ["--api-base-url", "http://local.invalid", "--live"]
        )

        self.assertEqual(args.min_accuracy, 95.0)
        self.assertEqual(args.delay_seconds, 4.0)
        self.assertEqual(args.max_attempts, 3)

    def test_exact_result_passes_every_metric(self) -> None:
        case = load_cases()[0]
        scoreboard = Scoreboard()

        scoreboard.add(case, _exact_result(case))

        self.assertEqual(set(scoreboard.correct.values()), {1})

    def test_adapter_evaluation_uses_reference_field_without_polluting_user_text(self) -> None:
        case = load_cases()[0]
        adapter = _CapturingAdapter(_exact_result(case))

        AdapterEvaluator(adapter).evaluate_text(case)

        self.assertEqual(adapter.request.text, case.input)
        self.assertNotEqual(adapter.request.text, case.evaluation_input)
        self.assertEqual(adapter.request.reference_at.isoformat(), case.reference_at)

    def test_report_does_not_print_case_input(self) -> None:
        case = load_cases()[0]
        scoreboard = Scoreboard(total=1)
        scoreboard.failures[case.id] = ["date"]
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            scoreboard.print_report("test")

        self.assertNotIn(case.input, output.getvalue())

    def test_case_id_filter_selects_only_requested_cases(self) -> None:
        cases = load_cases()

        selected = select_cases(cases, ["relative_date-01", "time_change-01"], None)

        self.assertEqual(
            [case.id for case in selected], ["time_change-01", "relative_date-01"]
        )

    def test_provider_error_does_not_stop_later_cases(self) -> None:
        cases = load_cases()[:2]

        scoreboard = evaluate_cases(_FirstCaseErrorEvaluator(cases[0].id), cases)

        self.assertEqual(scoreboard.total, 2)
        self.assertEqual(scoreboard.provider_errors, [cases[0].id])
        self.assertEqual(set(scoreboard.correct.values()), {1})

    def test_transient_provider_error_is_retried_without_counting_as_failure(self) -> None:
        case = load_cases()[0]
        waits: list[float] = []

        scoreboard = evaluate_cases(
            _RetryOnceEvaluator(),
            [case],
            max_attempts=2,
            sleep=waits.append,
        )

        self.assertEqual(scoreboard.total, 1)
        self.assertEqual(scoreboard.provider_errors, [])
        self.assertEqual(set(scoreboard.correct.values()), {1})
        self.assertEqual(waits, [1.0])

    def test_provider_error_report_does_not_print_exception_details(self) -> None:
        case = load_cases()[0]
        scoreboard = evaluate_cases(_FirstCaseErrorEvaluator(case.id), [case])
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            scoreboard.print_report("test")

        self.assertIn(f"- {case.id}", output.getvalue())
        self.assertNotIn("raw-secret-provider-body", output.getvalue())

    def test_scoreboard_fails_when_any_metric_is_below_minimum(self) -> None:
        scoreboard = Scoreboard(total=100)
        scoreboard.correct = {metric: 95 for metric in scoreboard.correct}
        scoreboard.correct["date"] = 94

        self.assertFalse(scoreboard.passes(95))

    def test_scoreboard_fails_when_critical_case_has_field_mismatch(self) -> None:
        scoreboard = Scoreboard(total=100)
        scoreboard.correct = {metric: 100 for metric in scoreboard.correct}
        scoreboard.failures["relative_date-01"] = ["date"]

        self.assertFalse(scoreboard.passes(95, "relative_date-01"))

    def test_scoreboard_fails_when_critical_case_has_provider_error(self) -> None:
        scoreboard = Scoreboard(total=100)
        scoreboard.correct = {metric: 100 for metric in scoreboard.correct}
        scoreboard.provider_errors.append("relative_date-01")

        self.assertFalse(scoreboard.passes(95, "relative_date-01"))

    def test_main_returns_nonzero_when_accuracy_gate_fails(self) -> None:
        case = load_cases()[0]
        failing_result = _exact_result(case).model_copy(
            update={
                "event": _exact_result(case).event.model_copy(update={"date": None})
            }
        )

        class FailingEvaluator(_ExactEvaluator):
            def evaluate_text(self, selected_case):
                return failing_result

        with (
            patch("evals.run.ApiEvaluator", return_value=FailingEvaluator()),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = main(
                [
                    "--api-base-url",
                    "http://local.invalid",
                    "--live",
                    "--case-id",
                    case.id,
                    "--min-accuracy",
                    "100",
                    "--max-attempts",
                    "1",
                ]
            )

        self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
