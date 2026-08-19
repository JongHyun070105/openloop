import json
import unittest
from datetime import datetime
from urllib.error import URLError
from zoneinfo import ZoneInfo

from app.context_providers import (
    KakaoLocalAdapter,
    KmaShortTermForecastAdapter,
    coordinates_to_kma_grid,
)
from app.errors import ExternalIntegrationError


class _Response:
    def __init__(self, payload: dict) -> None:
        self.payload = json.dumps(payload).encode()

    def __enter__(self):  # type: ignore[no-untyped-def]
        return self

    def __exit__(self, *_args):  # type: ignore[no-untyped-def]
        return None

    def read(self, limit: int = -1) -> bytes:
        return self.payload if limit < 0 else self.payload[:limit]


class ContextProviderTests(unittest.TestCase):
    def test_kakao_normalizes_place_without_exposing_key(self) -> None:
        captured = {}
        payload = {
            "documents": [
                {
                    "place_name": "난포 성수",
                    "road_address_name": "서울 성동구 서울숲4길 18-8",
                    "address_name": "서울 성동구 성수동1가",
                    "x": "127.043",
                    "y": "37.547",
                    "place_url": "https://place.map.kakao.com/1",
                }
            ]
        }

        def opener(request, timeout):  # type: ignore[no-untyped-def]
            captured["request"] = request
            captured["timeout"] = timeout
            return _Response(payload)

        result = KakaoLocalAdapter("server-secret", opener=opener).search("난포", 37.5, 127.0)

        self.assertEqual(result[0].name, "난포 성수")
        self.assertEqual(result[0].latitude, 37.547)
        self.assertEqual(captured["request"].headers["Authorization"], "KakaoAK server-secret")
        self.assertNotIn("server-secret", captured["request"].full_url)

    def test_kma_normalizes_short_term_forecast(self) -> None:
        captured = {}
        payload = {
            "response": {
                "header": {"resultCode": "00", "resultMsg": "NORMAL_SERVICE"},
                "body": {
                    "items": {
                        "item": [
                            {"fcstDate": "20260816", "fcstTime": "1200", "category": "TMP", "fcstValue": "28"},
                            {"fcstDate": "20260816", "fcstTime": "1200", "category": "POP", "fcstValue": "60"},
                            {"fcstDate": "20260816", "fcstTime": "1200", "category": "SKY", "fcstValue": "4"},
                            {"fcstDate": "20260816", "fcstTime": "1200", "category": "PTY", "fcstValue": "1"},
                        ]
                    }
                },
            }
        }

        def opener(request, timeout):  # type: ignore[no-untyped-def]
            captured["url"] = request.full_url
            captured["timeout"] = timeout
            return _Response(payload)

        now = lambda: datetime(2026, 8, 16, 10, 30, tzinfo=ZoneInfo("Asia/Seoul"))
        result = KmaShortTermForecastAdapter("auth-key", opener=opener, now=now).forecast(
            37.5665, 126.978, datetime(2026, 8, 16, 12, 0, tzinfo=ZoneInfo("Asia/Seoul"))
        )

        self.assertTrue(result.available)
        self.assertEqual(result.summary, "비")
        self.assertEqual(result.temperature_c, 28)
        self.assertEqual(result.precipitation_probability, 60)
        self.assertIn("authKey=auth-key", captured["url"])
        self.assertIn("base_time=0800", captured["url"])
        self.assertEqual(coordinates_to_kma_grid(37.5665, 126.978), (60, 127))

    def test_kakao_cleans_exit_numbers_and_ranks_core_places(self) -> None:
        calls = []

        def opener(request, timeout):  # type: ignore[no-untyped-def]
            del timeout
            url = request.full_url
            calls.append(url)
            if "query=%EC%A2%85%EB%A1%9C5%EA%B0%80%EC%97%AD+12%EB%B2%88+%EC%B6%9C%EA%B5%AC" in url:
                # Raw query: 종로5가역 12번 출구 -> returns unrelated places with 12번출구
                return _Response({
                    "documents": [
                        {
                            "place_name": "종오지하쇼핑센터 12번출구",
                            "road_address_name": "서울 종로구 종로 지하 200",
                            "x": "127.001",
                            "y": "37.570",
                            "place_url": "https://place.map.kakao.com/1",
                        },
                        {
                            "place_name": "종로3가역 1호선 12번출구",
                            "road_address_name": "서울 종로구 종로3가 45-4",
                            "x": "126.991",
                            "y": "37.570",
                            "place_url": "https://place.map.kakao.com/2",
                        },
                        {
                            "place_name": "동대문역사문화공원역 2호선 12번출구",
                            "road_address_name": "서울 중구 을지로6가 21-11",
                            "x": "127.008",
                            "y": "37.565",
                            "place_url": "https://place.map.kakao.com/3",
                        },
                    ]
                })
            # Cleaned query: 종로5가역
            return _Response({
                "documents": [
                    {
                        "place_name": "종로5가역 1호선",
                        "road_address_name": "서울 종로구 종로5가 82-1",
                        "x": "127.001",
                        "y": "37.570",
                        "place_url": "https://place.map.kakao.com/4",
                    },
                    {
                        "place_name": "종로5가역 1호선 1번출구",
                        "road_address_name": "서울 종로구 종로5가 82-1",
                        "x": "127.001",
                        "y": "37.570",
                        "place_url": "https://place.map.kakao.com/5",
                    },
                ]
            })

        adapter = KakaoLocalAdapter("server-secret", opener=opener)
        results = adapter.search("종로5가역 12번 출구", 37.57, 127.00)

        # Cleaned query was also queried
        self.assertEqual(len(calls), 2)
        # Main core station is prioritized, unrelated stations are filtered out
        names = [r.name for r in results]
        self.assertIn("종로5가역 1호선", names)
        self.assertNotIn("종로3가역 1호선 12번출구", names)
        self.assertNotIn("동대문역사문화공원역 2호선 12번출구", names)


if __name__ == "__main__":
    unittest.main()
