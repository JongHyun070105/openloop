#!/usr/bin/env python3
"""Synchronize non-empty local provider values into one AWS Secrets Manager secret.

The command never puts secret values on the command line or prints them. Existing
remote fields are retained when their local counterpart is blank, making it safe
to add one provider at a time.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Mapping, Sequence

from dotenv import dotenv_values


SUPPORTED_FIELDS = (
    "GEMINI_API_KEY",
    "GEMINI_MODEL",
    "KAKAO_REST_API_KEY",
    "KMA_AUTH_KEY",
    "POSTHOG_PROJECT_API_KEY",
    "POSTHOG_HOST",
    "SENTRY_DSN",
)


class SecretSyncError(RuntimeError):
    """A deliberately non-sensitive AWS synchronization failure."""


def merge_supported_values(
    existing: Mapping[str, object] | None, local: Mapping[str, str | None]
) -> dict[str, str]:
    """Apply non-empty local values without dropping already-issued remote values."""

    merged = {
        name: value
        for name, value in (existing or {}).items()
        if name in SUPPORTED_FIELDS and isinstance(value, str) and value
    }
    for name in SUPPORTED_FIELDS:
        value = local.get(name)
        if isinstance(value, str) and value:
            merged[name] = value
    return merged


def _aws_command(profile: str, region: str, arguments: Sequence[str]) -> list[str]:
    return ["aws", "--profile", profile, "--region", region, *arguments]


def _run(command: Sequence[str], payload: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603
        list(command),
        input=payload,
        text=True,
        capture_output=True,
        check=False,
    )


def _existing_secret(profile: str, region: str, secret_id: str) -> dict[str, object] | None:
    describe = _run(
        _aws_command(
            profile,
            region,
            ["secretsmanager", "describe-secret", "--secret-id", secret_id],
        )
    )
    if describe.returncode:
        if "ResourceNotFoundException" in describe.stderr:
            return None
        raise SecretSyncError("AWS secret lookup failed; details were withheld")

    read = _run(
        _aws_command(
            profile,
            region,
            [
                "secretsmanager",
                "get-secret-value",
                "--secret-id",
                secret_id,
                "--query",
                "SecretString",
                "--output",
                "text",
            ],
        )
    )
    if read.returncode:
        raise SecretSyncError("AWS secret read failed; details were withheld")
    try:
        value = json.loads(read.stdout)
    except json.JSONDecodeError as error:
        raise SecretSyncError("The existing integration secret is not valid JSON") from error
    if not isinstance(value, dict):
        raise SecretSyncError("The existing integration secret is not a JSON object")
    return value


def synchronize(
    *,
    env_file: Path,
    profile: str,
    region: str,
    secret_id: str,
    dry_run: bool,
) -> tuple[str, list[str]]:
    local = dotenv_values(env_file)
    existing = _existing_secret(profile, region, secret_id)
    payload = merge_supported_values(existing, local)
    if not payload:
        raise SecretSyncError("No supported non-empty local integration values were found")
    fields = sorted(payload)
    action = "update" if existing is not None else "create"
    if dry_run:
        return action, fields

    if action == "create":
        command = _aws_command(
            profile,
            region,
            [
                "secretsmanager",
                "create-secret",
                "--name",
                secret_id,
                "--description",
                "OpenLoop server-side integration credentials",
                "--secret-string",
                "file:///dev/stdin",
            ],
        )
    else:
        command = _aws_command(
            profile,
            region,
            [
                "secretsmanager",
                "put-secret-value",
                "--secret-id",
                secret_id,
                "--secret-string",
                "file:///dev/stdin",
            ],
        )
    result = _run(command, json.dumps(payload))
    if result.returncode:
        raise SecretSyncError("AWS secret write failed; details were withheld")
    return action, fields


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=Path(__file__).parents[1] / ".env")
    parser.add_argument("--profile", default="hermes-aws")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--secret-id", default="openloop/dev/integrations")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        action, fields = synchronize(
            env_file=args.env_file,
            profile=args.profile,
            region=args.region,
            secret_id=args.secret_id,
            dry_run=args.dry_run,
        )
    except SecretSyncError as error:
        print(str(error), file=sys.stderr)
        return 1
    state = "Would synchronize" if args.dry_run else "Synchronized"
    print(f"{state} ({action}): {', '.join(fields)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
