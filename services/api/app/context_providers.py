import json
import math
import os
import re
import socket
from datetime import UTC, datetime, timedelta
from typing import Callable, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

from .errors import ExternalIntegrationError, ExternalIntegrationTimeout
from .models import NormalizedPlace, WeatherForecast


OpenUrl = Callable[..., object]
KST = ZoneInfo("Asia/Seoul")


def _clean_place_query(query: str) -> str:
    cleaned = re.sub(r"\s*\d+\s*(?:번\s*)?(?:출구|출입구|게이트|번홈|홈)", "", query)
    cleaned = re.sub(r"\s*(?:앞|건너편|맞은편|인근|근처|주변|내부|입구|부근|방면|출구쪽)", "", cleaned)
    cleaned = re.sub(r"\s*(?:지하\s*\d+\s*층|지상\s*\d+\s*층|\d+\s*층|B\d+F?)\b", "", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def _extract_core_tokens(cleaned_query: str) -> list[str]:
    words = re.findall(r"[가-힣a-zA-Z0-9]+", cleaned_query)
    tokens: set[str] = set()
    for w in words:
        if len(w) >= 2:
            tokens.add(w.lower())
        if w.endswith("역") and len(w) > 2:
            tokens.add(w[:-1].lower())
        if w.endswith("점") and len(w) > 2:
            tokens.add(w[:-1].lower())
    return list(tokens)


def _rank_and_filter_places(
    raw_query: str, cleaned_query: str, places: list[NormalizedPlace]
) -> list[NormalizedPlace]:
    core_tokens = _extract_core_tokens(cleaned_query or raw_query)
    raw_tokens = [t.lower() for t in re.findall(r"[가-힣a-zA-Z0-9]+", raw_query)]

    seen: set[tuple[str, str]] = set()
    scored: list[tuple[float, NormalizedPlace]] = []

    for place in places:
        key = (place.name.strip(), place.address.strip())
        if key in seen:
            continue
        seen.add(key)

        name_lower = place.name.lower()
        addr_lower = place.address.lower()
        score = 0.0

        if name_lower == raw_query.lower():
            score += 120
        elif cleaned_query and name_lower == cleaned_query.lower():
            score += 100
        elif cleaned_query and name_lower.startswith(cleaned_query.lower()):
            score += 80
        elif any(token in name_lower for token in core_tokens):
            score += 50
        elif any(token in addr_lower for token in core_tokens):
            score += 15
        else:
            score -= 60

        for t in raw_tokens:
            if t in name_lower:
                score += 10
            elif t in addr_lower:
                score += 3

        scored.append((score, place))

    scored.sort(key=lambda x: x[0], reverse=True)
    positive = [p for s, p in scored if s > 0]
    return positive[:8] if positive else [p for s, p in scored][:8]


class PlaceAdapter(Protocol):
    provider: str

    def search(
        self, query: str, latitude: float | None = None, longitude: float | None = None
    ) -> list[NormalizedPlace]: ...


class DisabledPlaceAdapter:
    provider = "disabled"

    def search(
        self, query: str, latitude: float | None = None, longitude: float | None = None
    ) -> list[NormalizedPlace]:
        del query, latitude, longitude
        return []


class KakaoLocalAdapter:
    provider = "kakao"

    def __init__(self, api_key: str, timeout_seconds: float = 5.0, opener: OpenUrl = urlopen) -> None:
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds
        self.opener = opener

    def _fetch_places(
        self, query: str, latitude: float | None = None, longitude: float | None = None
    ) -> list[NormalizedPlace]:
        params: dict[str, str | int] = {"query": query, "size": 10}
        if latitude is not None and longitude is not None:
            params.update({"x": str(longitude), "y": str(latitude), "sort": "distance"})
        request = Request(
            f"https://dapi.kakao.com/v2/local/search/keyword.json?{urlencode(params)}",
            headers={"Authorization": f"KakaoAK {self.api_key}"},
        )
        payload = _read_json(request, self.timeout_seconds, self.opener, "Kakao Local")
        try:
            return [
                NormalizedPlace(
                    name=document["place_name"],
                    address=document.get("road_address_name") or document.get("address_name") or "",
                    latitude=float(document["y"]),
                    longitude=float(document["x"]),
                    kakao_map_url=document.get("place_url") or "",
                )
                for document in payload.get("documents", [])
            ]
        except (KeyError, TypeError, ValueError) as error:
            raise ExternalIntegrationError("Kakao Local returned an invalid response") from error

    def search(
        self, query: str, latitude: float | None = None, longitude: float | None = None
    ) -> list[NormalizedPlace]:
        raw_query = query.strip()
        cleaned_query = _clean_place_query(raw_query)

        primary_results = self._fetch_places(raw_query, latitude=latitude, longitude=longitude)

        secondary_results: list[NormalizedPlace] = []
        if cleaned_query and cleaned_query != raw_query:
            try:
                secondary_results = self._fetch_places(cleaned_query, latitude=latitude, longitude=longitude)
            except Exception:
                secondary_results = []

        all_candidates = primary_results + secondary_results
        if not all_candidates:
            return []

        return _rank_and_filter_places(raw_query, cleaned_query, all_candidates)


class WeatherAdapter(Protocol):
    provider: str

    def forecast(self, latitude: float, longitude: float, at: datetime | None) -> WeatherForecast: ...


class DisabledWeatherAdapter:
    provider = "disabled"

    def forecast(self, latitude: float, longitude: float, at: datetime | None) -> WeatherForecast:
        del latitude, longitude, at
        return WeatherForecast(available=False, summary="날씨 연동이 설정되지 않았습니다.", provider="disabled")


class KmaShortTermForecastAdapter:
    provider = "kma"
    endpoint = (
        "https://apihub.kma.go.kr/api/typ02/openApi/"
        "VilageFcstInfoService_2.0/getVilageFcst"
    )

    def __init__(
        self,
        api_key: str,
        timeout_seconds: float = 6.0,
        opener: OpenUrl = urlopen,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.api_key = api_key
        self.timeout_seconds = timeout_seconds
        self.opener = opener
        self.now = now or (lambda: datetime.now(KST))

    def forecast(self, latitude: float, longitude: float, at: datetime | None) -> WeatherForecast:
        nx, ny = coordinates_to_kma_grid(latitude, longitude)
        base = _latest_forecast_base(self.now())
        params = {
            "pageNo": 1,
            "numOfRows": 1000,
            "dataType": "JSON",
            "base_date": base.strftime("%Y%m%d"),
            "base_time": base.strftime("%H00"),
            "nx": nx,
            "ny": ny,
            "authKey": self.api_key,
        }
        payload = _read_json(
            Request(f"{self.endpoint}?{urlencode(params)}"),
            self.timeout_seconds,
            self.opener,
            "KMA forecast",
        )
        try:
            response = payload["response"]
            if response["header"]["resultCode"] != "00":
                raise ExternalIntegrationError("KMA forecast request was rejected")
            items = response["body"]["items"]["item"]
            return _normalize_forecast(items, at or self.now())
        except ExternalIntegrationError:
            raise
        except (KeyError, TypeError, ValueError) as error:
            raise ExternalIntegrationError("KMA returned an invalid response") from error


def place_adapter_from_env() -> PlaceAdapter:
    api_key = os.getenv("KAKAO_REST_API_KEY")
    if not api_key:
        return DisabledPlaceAdapter()
    return KakaoLocalAdapter(
        api_key,
        timeout_seconds=float(os.getenv("KAKAO_TIMEOUT_SECONDS", "5")),
    )


def weather_adapter_from_env() -> WeatherAdapter:
    api_key = os.getenv("KMA_AUTH_KEY")
    if not api_key:
        return DisabledWeatherAdapter()
    return KmaShortTermForecastAdapter(
        api_key,
        timeout_seconds=float(os.getenv("KMA_TIMEOUT_SECONDS", "6")),
    )


def _read_json(request: Request, timeout: float, opener: OpenUrl, provider: str) -> dict:
    try:
        with opener(request, timeout=timeout) as response:
            payload = response.read(1_000_001)
        if len(payload) > 1_000_000:
            raise ExternalIntegrationError(f"{provider} response exceeded the size limit")
        parsed = json.loads(payload)
        if not isinstance(parsed, dict):
            raise ValueError("response root is not an object")
        return parsed
    except (TimeoutError, socket.timeout) as error:
        raise ExternalIntegrationTimeout(f"{provider} timed out") from error
    except HTTPError as error:
        raise ExternalIntegrationError(f"{provider} request failed") from error
    except URLError as error:
        if isinstance(error.reason, (TimeoutError, socket.timeout)):
            raise ExternalIntegrationTimeout(f"{provider} timed out") from error
        raise ExternalIntegrationError(f"{provider} request failed") from error
    except ExternalIntegrationError:
        raise
    except (json.JSONDecodeError, ValueError, TypeError) as error:
        raise ExternalIntegrationError(f"{provider} returned an invalid response") from error


def _latest_forecast_base(now: datetime) -> datetime:
    local_now = now.replace(tzinfo=KST) if now.tzinfo is None else now.astimezone(KST)
    available_at = local_now - timedelta(minutes=15)
    base_hours = (2, 5, 8, 11, 14, 17, 20, 23)
    valid_hours = [hour for hour in base_hours if hour <= available_at.hour]
    if valid_hours:
        return available_at.replace(hour=max(valid_hours), minute=0, second=0, microsecond=0)
    previous = available_at - timedelta(days=1)
    return previous.replace(hour=23, minute=0, second=0, microsecond=0)


def _normalize_forecast(items: list[dict], target: datetime) -> WeatherForecast:
    target_local = target.replace(tzinfo=KST) if target.tzinfo is None else target.astimezone(KST)
    grouped: dict[datetime, dict[str, str]] = {}
    for item in items:
        forecast_at = datetime.strptime(
            f"{item['fcstDate']}{item['fcstTime']}", "%Y%m%d%H%M"
        ).replace(tzinfo=KST)
        grouped.setdefault(forecast_at, {})[item["category"]] = item["fcstValue"]
    candidates = [(forecast_at, values) for forecast_at, values in grouped.items() if "TMP" in values]
    if not candidates:
        raise ExternalIntegrationError("KMA forecast did not contain temperature data")
    future = [candidate for candidate in candidates if candidate[0] >= target_local]
    forecast_at, values = min(future or candidates, key=lambda candidate: abs(candidate[0] - target_local))
    return WeatherForecast(
        available=True,
        summary=_weather_summary(values.get("SKY"), values.get("PTY")),
        temperature_c=float(values["TMP"]),
        precipitation_probability=int(values["POP"]) if "POP" in values else None,
        forecast_at=forecast_at.astimezone(UTC),
        provider="kma",
    )


def _weather_summary(sky: str | None, precipitation_type: str | None) -> str:
    precipitation = {
        "1": "비",
        "2": "비 또는 눈",
        "3": "눈",
        "4": "소나기",
        "5": "빗방울",
        "6": "빗방울 또는 눈날림",
        "7": "눈날림",
    }
    if precipitation_type and precipitation_type != "0":
        return precipitation.get(precipitation_type, "강수")
    return {"1": "맑음", "3": "구름많음", "4": "흐림"}.get(sky or "", "날씨 정보")


def coordinates_to_kma_grid(latitude: float, longitude: float) -> tuple[int, int]:
    """Convert WGS84 coordinates to KMA's 5 km Lambert grid."""
    radius = 6371.00877 / 5.0
    first_parallel = math.radians(30.0)
    second_parallel = math.radians(60.0)
    origin_longitude = math.radians(126.0)
    origin_latitude = math.radians(38.0)
    origin_x, origin_y = 43.0, 136.0
    sn = math.log(math.cos(first_parallel) / math.cos(second_parallel)) / math.log(
        math.tan(math.pi * 0.25 + second_parallel * 0.5)
        / math.tan(math.pi * 0.25 + first_parallel * 0.5)
    )
    sf = (
        math.tan(math.pi * 0.25 + first_parallel * 0.5) ** sn
        * math.cos(first_parallel)
        / sn
    )
    ro = radius * sf / math.tan(math.pi * 0.25 + origin_latitude * 0.5) ** sn
    ra = radius * sf / math.tan(math.pi * 0.25 + math.radians(latitude) * 0.5) ** sn
    theta = math.radians(longitude) - origin_longitude
    if theta > math.pi:
        theta -= 2.0 * math.pi
    if theta < -math.pi:
        theta += 2.0 * math.pi
    theta *= sn
    return (
        int(ra * math.sin(theta) + origin_x + 0.5),
        int(ro - ra * math.cos(theta) + origin_y + 0.5),
    )
