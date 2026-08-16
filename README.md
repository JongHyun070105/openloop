# OpenLoop

> 캡처만 하세요. 일정은 OpenLoop가 만듭니다.

OpenLoop는 카카오톡 대화, 공지, 포스터처럼 흩어진 비정형 정보를 이해해 실행 가능한 일정으로 만들고 완료까지 연결하는 **AI Action Calendar**입니다.

## Product loop

```text
Capture -> Create -> Close
```

- **Capture** — screenshot, image, text를 공유합니다. 공유된 이미지는 최대 5장을 한 번의 맥락으로 분석합니다.
- **Create** — AI가 최종 합의, 한두 문장 요약, 누락 필드, 신뢰도를 포함한 구조화된 일정을 만듭니다.
- **Close** — calendar, reminder, checklist, checkpoint를 연결해 완료까지 추적합니다.

MVP는 `Appointment`와 `Deadline` 두 가지 intent에 집중합니다. AI가 확실하면 한 번의 확인으로 등록하고, 애매하면 필요한 필드 하나만 묻습니다.

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

## Implemented

- 텍스트·사진·공유 Capture(최대 5장)와 Appointment/Deadline 분석
- Gemini 구조화 결과의 AI 요약과 필드별 신뢰도 리뷰
- confidence review와 필요한 모호성 필드 하나만 재질문
- Open Loop 목록, 상세, 체크리스트, 마감, 완료 보관함, retention 설정
- Android 공유 인텐트와 iOS Share Extension
- 캘린더·로컬 알림 연결 및 네트워크 실패 시 local-first 저장
- FastAPI lifecycle API, SQLite/DynamoDB 저장소, 개인정보 redaction
- Lambda/API Gateway/DynamoDB 기반 pay-per-use AWS 배포

현재 dev API: <https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com/dev>

실제 AI 공급자 키가 없을 때는 결정적 fallback 분석기가 동작합니다. 이 모드는 입력에 명시된 값만 추출하고 빈 날짜·시간·장소는 질문으로 남기며, 예시용 가짜 일정을 만들지 않습니다. 공급자를 정하면 키는 커밋하지 않고 로컬 `services/api/.env` 또는 AWS Secrets Manager로만 주입합니다. `.env.example`은 공유 가능한 빈 템플릿입니다.

## Validation

```bash
cd apps/demo && npm run build
cd services/api && .venv/bin/python -m unittest discover -s tests -v
cd apps/mobile && flutter analyze && flutter test
```

자세한 제품 범위와 경계는 [PRODUCT_SCOPE.md](docs/PRODUCT_SCOPE.md), 시스템 구조는 [ARCHITECTURE.md](docs/ARCHITECTURE.md), AWS 운영은 [AWS_DEPLOYMENT.md](docs/AWS_DEPLOYMENT.md)를 참고하세요.
