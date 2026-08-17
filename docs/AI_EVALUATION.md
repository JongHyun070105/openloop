# AI evaluation

OpenLoop's analysis quality is measured with a checked-in, privacy-safe Korean dataset at
[`services/api/evals/cases.json`](../services/api/evals/cases.json). The dataset contains exactly
100 synthetic cases derived from the product requirements:

| Scenario | Cases |
| --- | ---: |
| Clear appointments | 20 |
| Time corrections and final agreement | 20 |
| Place corrections and final agreement | 15 |
| Relative dates | 15 |
| Missing required fields | 15 |
| Poster and deadline extraction | 15 |

Every case carries an explicit `Asia/Seoul` `reference_at` and expected intent, date, time, place,
missing fields, and final-agreement facts. The harness sends that value through the same request
field as Flutter, so relative-date results do not change with the machine clock and synthetic
evaluation metadata is never mixed into the user-content channel.
For `담주` / `다음 주`, OpenLoop uses a Korean Sunday–Saturday calendar convention; for example,
on Sunday 2026-08-16, `다음 주 화요일` resolves to 2026-08-25.
The cases use generic places and synthetic activities; they contain no user attachments, names,
email addresses, phone numbers, account identifiers, or credentials.

## Validate the dataset without making AI calls

From `services/api`:

```sh
.venv/bin/python -m unittest evals.test_dataset -v
```

This validates the exact count, category distribution, unique IDs, KST reference timestamps,
privacy-shaped values, expected field formats, and final-agreement consistency.

## Opt-in live evaluation

Live evaluation is deliberately never the default. It can send all selected synthetic prompts to
the configured provider and can incur API or AWS charges. The runner requires `--live` to make that
boundary explicit. It never prints prompts, API keys, image bytes, or raw provider responses; the
report contains only aggregate metrics and failed case IDs with metric names.

Use the provider configured by the normal OpenLoop environment:

```sh
.venv/bin/python -m evals.run --adapter --live
```

The full 100-case run is paced at four seconds per request and retries a transient
provider error up to three times. It normally takes about seven minutes; that is
intentional so the inexpensive model stays below its per-minute quota. Tune the
explicit controls only when the provider's documented quota changes:

```sh
.venv/bin/python -m evals.run --adapter --live \
  --delay-seconds 4 --max-attempts 3
```

Or evaluate a deployed/running API without exposing its credentials to the runner:

```sh
.venv/bin/python -m evals.run \
  --api-base-url https://your-openloop-api.example \
  --live
```

For a low-cost smoke run, add `--limit 5`. To select exact cases, repeat `--case-id`, for example
`--case-id relative_date-01 --case-id time_change-01`. Filtering happens before `--limit`. The
credential-free deterministic adapter is rejected by default because its scores are not evidence
of model quality. It can be exercised only for harness smoke testing with
`--adapter --live --allow-deterministic`.

The report includes:

- **Field Accuracy**: intent and the exact `missing_fields` set are both correct.
- **Date Accuracy**: resolved date, including an expected null, is exact.
- **Time Accuracy**: resolved local time to the minute, including an expected null, is exact.
- **Location Accuracy**: normalized place name, including an expected null, is exact.
- **Final Agreement Accuracy**: resolved date, time, and place all match the latest agreement.

Every metric must reach `95%` by default. Override the gate only when a different threshold was
approved explicitly, using `--min-accuracy 98` for example. Exit code `0` means every metric passed;
exit code `1` means a metric missed the threshold or the selected critical image case failed; exit
code `2` means the harness configuration or setup was invalid.

Provider errors are isolated per case: evaluation continues, the failed case counts as incorrect
for every metric, and only its ID is printed under `provider_error_case_ids`. A transient error is
retried with a short exponential backoff before it is counted. SDK exception details and raw
responses are suppressed.

## Critical local image

A locally supplied critical screenshot can replace one named text case during a run. The path and
bytes are read only for that invocation and are not copied into the repository or report:

```sh
.venv/bin/python -m evals.run \
  --adapter \
  --live \
  --case-id relative_date-01 \
  --critical-image /absolute/local/path/capture.png \
  --critical-case relative_date-01
```

Choose a case whose expected facts match the screenshot. The runner accepts exactly one local image
up to 10 MB. Do not use a real attachment unless its contents are appropriate to send to the
configured provider under that provider's privacy terms. A critical case must pass every field even
when aggregate accuracy is above the threshold. Never commit the image, `.env`, evaluation output,
or provider credentials.

## Interpreting results

The 100-case suite is a repeatable regression gate, not proof that all real-world screenshots are
safe or correctly understood. Review category-level failures before changing prompts or models, and
repeat the same dataset after any change. Real user captures remain outside this dataset and should
only be tested with explicit consent and a separate privacy review.
