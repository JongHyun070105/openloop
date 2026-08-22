import re
from typing import Any


_PATTERNS = (
    (re.compile(r"(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)+", re.IGNORECASE), "[REDACTED_EMAIL]"),
    (re.compile(r"(?<!\d)(?:\+?82[- ]?)?0?1[016789][- ]?\d{3,4}[- ]?\d{4}(?!\d)"), "[REDACTED_PHONE]"),
    (re.compile(r"(?<!\d)\d{6}[- ]?[1-4]\d{6}(?!\d)"), "[REDACTED_ID]"),
    (re.compile(r"(?<!\d)(?:\d[ -]*?){13,19}(?!\d)"), "[REDACTED_PAYMENT]"),
)

_ZERO_WIDTH_AND_CONTROL = re.compile(r"[\u200B-\u200D\uFEFF\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]")

_INJECTION_PATTERNS = (
    # Direct instruction override (English)
    re.compile(r"(?i)\b(?:ignore|disregard|forget|override)\s+(?:all\s+)?(?:previous|prior|above)\s+(?:instructions|rules|prompts|commands)"),
    re.compile(r"(?i)\b(?:system\s*override|developer\s*mode|dan\s*mode|jailbreak|unrestricted\s*mode)\b"),
    re.compile(r"(?i)\byou\s+are\s+now\s+(?:an?\s+)?(?:unfiltered|evil|jailbroken|different|unrestricted)\b"),
    re.compile(r"(?i)\b(?:output|print|reveal|show|display|leak)\s+(?:the\s+)?(?:system\s*prompt|internal\s*instructions|hidden\s*prompt)\b"),
    re.compile(r"(?i)\b(?:assistant\s*:\s*|system\s*:\s*|human\s*:\s*|<\|im_start\|>|<\|im_end\|>|\[INST\]|\[/INST\])"),

    # Direct instruction override (Korean)
    re.compile(r"(?i)(?:이전|앞선|모든)\s*(?:지시|명령|프롬프트|규칙|설정)\s*(?:사항)?(?:을|를)?\s*(?:모두\s*)?(?:무시|삭제|취소|초기화)"),
    re.compile(r"(?i)(?:시스템\s*프롬프트|내부\s*지침|프롬프트\s*전문|비밀\s*지시)(?:를|을)?\s*(?:출력|보여|알려|말해|노출|표시)"),
    re.compile(r"(?i)(?:관리자\s*모드|탈옥|탈출\s*프롬프트|개발자\s*모드|루트\s*권한|역할\s*변경)\s*(?:활성화|적용|실행|시작|모드|전환|해제)"),
    re.compile(r"(?i)(?:너는\s*이제부터|당신은\s*이제)\s*(?:다른\s*AI|제한\s*없는|악당|해커)"),
    re.compile(r"(?i)(?:탈옥|jailbreak)\s*(?:모드|mode|프롬프트|prompt)"),
    re.compile(r"(?i)모든\s*제한\s*(?:을|를)?\s*(?:해제|풀어|없애)"),

    # Code injection & XSS
    re.compile(r"(?i)<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>"),
    re.compile(r"(?i)javascript\s*:\s*\w"),
    re.compile(r"(?i)data:text\/html"),
    re.compile(r"(?i)eval\s*\(\s*"),
)

_MAX_SAFE_TEXT_LENGTH = 8000
_MAX_SAFE_IMAGE_SIZE_BYTES = 10 * 1024 * 1024  # 10 MB


def sanitize_input_text(text: str | None) -> str:
    """Strip invisible zero-width/control characters and truncate excessive length."""
    if not text:
        return ""
    sanitized = _ZERO_WIDTH_AND_CONTROL.sub("", text)
    if len(sanitized) > _MAX_SAFE_TEXT_LENGTH:
        sanitized = sanitized[:_MAX_SAFE_TEXT_LENGTH]
    return sanitized.strip()


def redact_pii(text: str) -> str:
    """Remove common high-risk identifiers before text leaves the API boundary."""
    redacted = sanitize_input_text(text)
    for pattern, replacement in _PATTERNS:
        redacted = pattern.sub(replacement, redacted)
    return redacted


def detect_prompt_injection(text: str | None) -> tuple[bool, str | None]:
    """Scan text for adversarial prompt injection, jailbreak attempts, or exploit payloads."""
    if not text:
        return False, None
    sanitized = sanitize_input_text(text)
    for pattern in _INJECTION_PATTERNS:
        match = pattern.search(sanitized)
        if match:
            return True, match.group(0)
    return False, None


def is_safe_image_bytes(image_data: bytes | None) -> bool:
    """Validate image payload size and check magic bytes for supported, safe formats."""
    if not image_data:
        return False
    if len(image_data) > _MAX_SAFE_IMAGE_SIZE_BYTES:
        return False
    if len(image_data) < 8:
        return False

    # Magic byte signatures
    is_png = image_data.startswith(b"\x89PNG\r\n\x1a\n")
    is_jpeg = image_data.startswith(b"\xff\xd8\xff")
    is_webp = image_data.startswith(b"RIFF") and b"WEBP" in image_data[8:16]
    is_gif = image_data.startswith(b"GIF87a") or image_data.startswith(b"GIF89a")
    is_heic_or_avif = b"ftyp" in image_data[4:16]

    return is_png or is_jpeg or is_webp or is_gif or is_heic_or_avif

def sanitize_output_string(value: str | None) -> str | None:
    """Sanitize output fields to prevent XSS or prompt reflections."""
    if value is None:
        return None
    cleaned = _ZERO_WIDTH_AND_CONTROL.sub("", value)
    cleaned = re.sub(r"(?i)<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>", "", cleaned)
    # Remove javascript:xxx patterns (URL scheme injection)
    cleaned = re.sub(r"(?i)javascript\s*:\s*\S+\s*", "", cleaned)
    return cleaned.strip()
