import unittest

from evals.schema import EXPECTED_CATEGORY_COUNTS, load_cases


class EvaluationDatasetTests(unittest.TestCase):
    def test_dataset_contains_exactly_one_hundred_cases(self) -> None:
        self.assertEqual(len(load_cases()), 100)

    def test_dataset_matches_required_category_distribution(self) -> None:
        cases = load_cases()
        actual = {category: 0 for category in EXPECTED_CATEGORY_COUNTS}
        for case in cases:
            actual[case.category] += 1
        self.assertEqual(actual, EXPECTED_CATEGORY_COUNTS)

    def test_every_case_has_explicit_korean_reference_instant(self) -> None:
        for case in load_cases():
            self.assertEqual(case.timezone, "Asia/Seoul")
            self.assertTrue(case.reference_at.endswith("+09:00"))

    def test_final_agreement_repeats_the_expected_resolved_facts(self) -> None:
        for case in load_cases():
            self.assertEqual(
                (
                    case.expected.final_agreement.date,
                    case.expected.final_agreement.time,
                    case.expected.final_agreement.place,
                ),
                (case.expected.date, case.expected.time, case.expected.place),
            )


if __name__ == "__main__":
    unittest.main()
