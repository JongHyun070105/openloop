# OpenLoop

> 캡처만 하세요. 일정은 OpenLoop가 만듭니다.

OpenLoop는 카카오톡 대화, 공지, 포스터처럼 흩어진 비정형 정보를 이해해 실행 가능한 일정으로 만들고 완료까지 연결하는 **AI Action Calendar**입니다.

## Product loop

```text
Capture -> Create -> Close
```

- **Capture** — screenshot, image, text를 공유합니다.
- **Create** — AI가 최종 합의, 누락 필드, 신뢰도를 포함한 구조화된 일정을 만듭니다.
- **Close** — calendar, reminder, checklist, checkpoint를 연결해 완료까지 추적합니다.

MVP는 `Appointment`와 `Deadline` 두 가지 intent에 집중합니다. AI가 확실하면 한 번의 확인으로 등록하고, 애매하면 필요한 필드 하나만 묻습니다.

## Repository

```text
apps/
  demo/       React + Vite 심사용 클릭 프로토타입
  mobile/     Flutter 실제 서비스 클라이언트 뼈대
services/
  api/        FastAPI 분석/Loop API 뼈대
docs/
  ARCHITECTURE.md
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
.venv/bin/uvicorn app.main:app --reload
```

API docs: <http://127.0.0.1:8000/docs>

### Flutter

```bash
cd apps/mobile
flutter run
```

## Current foundation

- 카카오톡 약속 / 시간 변경 / 애매한 약속 / 공모전 마감 샘플
- field별 confidence 및 missing field 모델
- `OPEN -> CLOSED` Loop 상태 모델
- Event-driven checkpoint 구조
- Privacy-first 처리 원칙 문서화
- frontend, API, Flutter 기본 검증 명령

## Validation

```bash
cd apps/demo && npm run build
cd services/api && python3 -m unittest discover -s tests
cd apps/mobile && flutter analyze && flutter test
```

자세한 제품 범위와 경계는 [PRODUCT_SCOPE.md](docs/PRODUCT_SCOPE.md), 시스템 구조는 [ARCHITECTURE.md](docs/ARCHITECTURE.md)를 참고하세요.
