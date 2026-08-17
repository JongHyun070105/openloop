# OpenLoop

> 캡처만 하세요. 일정은 OpenLoop가 만듭니다.

OpenLoop는 카카오톡 대화, 공지, 포스터처럼 흩어진 비정형 정보를 이해해 실행 가능한 일정으로 만들고 완료까지 연결하는 **AI Action Calendar**입니다.

## Product loop

```text
Capture -> Create -> Close
```

- **Capture** — screenshot/image 한 장 또는 text를 공유합니다.
- **Create** — AI가 최종 합의, 요약, 누락 필드, 신뢰도를 포함한 저장 전 `Analysis Draft`를 만듭니다. 사용자가 승인할 때만 Open Loop가 생성됩니다.
- **Close** — calendar, reminder, checklist, checkpoint를 연결해 완료까지 추적합니다.

현재 앱은 `Appointment`, `Deadline`, `Place`, `Coupon` 네 가지 intent를 지원합니다. AI가 확실하면 한 번의 확인으로 저장하고, 애매하면 해당 타입에 실제로 필요한 필드 하나만 묻습니다.

## Repository

```text
apps/
  demo/       React + Vite 심사용 클릭 프로토타입
  mobile/     Flutter Android/iOS 서비스 클라이언트
services/
  api/        FastAPI 분석/Loop API
infra/        AWS SAM 서버리스 인프라
docs/
  ARCHITECTURE.md
  AWS_DEPLOYMENT.md
  PRODUCT_SCOPE.md
```

## Quick start

### Web demo

```bash
cd apps/demo
npm install
npm run dev
```

### API

```bash
cd services/api
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# Fill the ignored services/api/.env file; leave .env.example blank.
.venv/bin/uvicorn --env-file .env app.main:app --reload
```

API docs: <http://127.0.0.1:8000/docs>

Server provider values belong only in `services/api/.env`; copy its `.env.example` first and leave the template blank. Do not put Gemini, Kakao, or KMA keys in a Flutter build.

### Flutter

```bash
cd apps/mobile
flutter run --dart-define=OPENLOOP_API_BASE_URL=http://127.0.0.1:8000
```

Optional Flutter analytics, Sentry, and Firebase client identifiers belong in `apps/mobile/.env` (copy `apps/mobile/.env.example`) and are passed with `--dart-define-from-file=.env`.

## Current product contract

- 앱 선택기, Android `SEND`, iOS Share Extension, API가 이미지 한 장만 받습니다. 이미지 업로드는 실제 MIME type과 10 MB 제한을 사용합니다.
- `/v1/analyze`와 `/v1/analyze/image`는 저장되지 않은 `Analysis Draft`를 반환합니다. Review에서 승인하면 `/v1/loops`가 구조화된 Loop, action, checklist, checkpoint를 저장합니다.
- Capture 시각을 `reference_at`으로 함께 보내 Gemini의 모든 요청을 `Asia/Seoul` 기준시각에 고정합니다. text는 `MINIMAL`, image는 `LOW` thinking을 사용하며, 상대 날짜·생략 연도·최종 합의를 후처리와 회귀 테스트로 검증합니다.
- 필수 필드가 없거나 confidence가 `0.65` 미만이면 해당 필드 하나만 확인합니다. 정상 빌드에서는 원시 confidence 백분율을 숨깁니다.
- 설정된 원격 AI의 text/image 실패는 로컬 분석 성공으로 위장하지 않고 재시도 가능한 오류로 표시합니다.
- Appointment 승인 버튼은 Loop를 저장한 뒤 시스템 calendar composer를 엽니다. 삭제 확인은 iOS Cupertino, Android Material 방식입니다.
- Appointment는 `T-1h` 또는 남은 가장 가까운 준비 시점, Deadline/Coupon은 `D-1` 또는 유효한 당일 시점에 알림 한 번만 만듭니다. Place에는 알림을 만들지 않습니다.
- 같은 설치에서 장소명이 명시적으로 같은 Loop는 서로 연결해 상세 화면에 표시합니다. 모호한 제목 유사도는 관계로 추측하지 않습니다.
- Open Loop 목록/상세, action/checklist/checkpoint 완료, local reminder, Kakao place handoff, KMA weather, Close & Forget 보관 정책이 연결돼 있습니다.
- FastAPI lifecycle API, SQLite/DynamoDB 저장소와 Lambda/API Gateway 기반 AWS 배포 구성이 있습니다.

현재 dev API: <https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com/dev>

원격 API를 의도적으로 비워 둔 로컬 개발에서만 결정적 text fallback이 명시된 값을 추출합니다. image는 픽셀을 읽을 수 있는 Gemini가 없거나 실패하면 분석 성공을 만들지 않습니다. 공급자 키는 커밋하지 않고 로컬 `services/api/.env` 또는 AWS Secrets Manager로만 주입합니다. `.env.example`은 공유 가능한 빈 템플릿입니다.

FCM remote push, PostHog, Sentry는 구현돼 있지만 대응 자격증명과 실제 기기 권한이 없으면 안전하게 비활성입니다. 현재 installation UUID는 데이터 분리용 식별자이지 production authentication이 아닙니다.

## Validation

```bash
cd apps/demo && npm run build
cd services/api && .venv/bin/python -m unittest discover -s tests -v
cd apps/mobile && flutter analyze && flutter test
```

자세한 제품 범위와 경계는 [PRODUCT_SCOPE.md](docs/PRODUCT_SCOPE.md), 시스템 구조는 [ARCHITECTURE.md](docs/ARCHITECTURE.md), AI 평가 방법은 [AI_EVALUATION.md](docs/AI_EVALUATION.md), AWS 운영은 [AWS_DEPLOYMENT.md](docs/AWS_DEPLOYMENT.md)를 참고하세요.
