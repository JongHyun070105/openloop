import re


_PATTERNS = (
    (re.compile(r"(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)+", re.IGNORECASE), "[REDACTED_EMAIL]"),
    (re.compile(r"(?<!\d)(?:\+?82[- ]?)?0?1[016789][- ]?\d{3,4}[- ]?\d{4}(?!\d)"), "[REDACTED_PHONE]"),
    (re.compile(r"(?<!\d)\d{6}[- ]?[1-4]\d{6}(?!\d)"), "[REDACTED_ID]"),
    (re.compile(r"(?<!\d)(?:\d[ -]*?){13,19}(?!\d)"), "[REDACTED_PAYMENT]"),
)


def redact_pii(text: str) -> str:
    """Remove common high-risk identifiers before text leaves the API boundary."""
    redacted = text
    for pattern, replacement in _PATTERNS:
        redacted = pattern.sub(replacement, redacted)
    return redacted
