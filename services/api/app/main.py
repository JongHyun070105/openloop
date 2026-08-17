import os
from datetime import datetime
from pathlib import Path
from typing import Literal
from uuid import UUID

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .analyzer import AnalysisAdapter, analysis_adapter_from_env
from .context_providers import (
    PlaceAdapter,
    WeatherAdapter,
    place_adapter_from_env,
    weather_adapter_from_env,
)
from .dynamo_repository import DynamoLoopRepository
from .device_tokens import DeviceTokenStore, device_token_store_from_env
from .errors import ExternalIntegrationError, ExternalIntegrationTimeout
from .models import (
    AmbiguityUpdate,
    AnalyzeRequest,
    AnalyzeResponse,
    CapabilitiesResponse,
    CompletionRequest,
    CompletionUpdate,
    CreateLoopRequest,
    LoopStatus,
    NormalizedPlace,
    OpenLoop,
    PushTokenRequest,
    PushTokenResponse,
    RetentionUpdate,
    WeatherForecast,
)
from .observability import Analytics, analytics_from_env, initialize_sentry_from_env
from .repository import LoopRepository
from .secrets import load_provider_secrets_from_env
from .service import LoopService


MAX_IMAGE_BYTES = 10 * 1024 * 1024
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"}


def _not_found(identifier: str) -> HTTPException:
    return HTTPException(status_code=404, detail=f"Loop or item '{identifier}' was not found")


def create_app(
    database_path: str | Path | None = None,
    analyzer: AnalysisAdapter | None = None,
    place_adapter: PlaceAdapter | None = None,
    weather_adapter: WeatherAdapter | None = None,
    analytics: Analytics | None = None,
    device_token_store: DeviceTokenStore | None = None,
) -> FastAPI:
    load_provider_secrets_from_env()
    sentry_enabled = initialize_sentry_from_env()
    api = FastAPI(
        title="OpenLoop API",
        version="0.2.0",
        description="Turn unstructured context into actionable, confidence-aware loops.",
    )
    cors_origins = [origin.strip() for origin in os.getenv("OPENLOOP_CORS_ORIGINS", "*").split(",") if origin.strip()]
    api.add_middleware(
        CORSMiddleware,
        allow_origins=cors_origins or ["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    table_name = os.getenv("OPENLOOP_TABLE_NAME")
    if database_path is None and table_name:
        repository = DynamoLoopRepository(table_name)
    else:
        configured_path = (
            database_path
            or os.getenv("OPENLOOP_DB_PATH")
            or Path(__file__).parents[1] / "data/openloop.db"
        )
        repository = LoopRepository(configured_path)
    service = LoopService(repository)
    analysis = analyzer or analysis_adapter_from_env()
    places = place_adapter or place_adapter_from_env()
    weather = weather_adapter or weather_adapter_from_env()
    telemetry = analytics or analytics_from_env()
    devices = device_token_store or device_token_store_from_env()
    api.state.repository = repository
    api.state.loop_service = service
    api.state.analysis_adapter = analysis
    api.state.place_adapter = places
    api.state.weather_adapter = weather
    api.state.analytics = telemetry
    api.state.device_token_store = devices

    @api.exception_handler(ExternalIntegrationTimeout)
    async def integration_timeout_handler(_request, _error) -> JSONResponse:  # type: ignore[no-untyped-def]
        return JSONResponse(status_code=504, content={"detail": "External provider timed out"})

    @api.exception_handler(ExternalIntegrationError)
    async def integration_error_handler(_request, _error) -> JSONResponse:  # type: ignore[no-untyped-def]
        return JSONResponse(status_code=502, content={"detail": "External provider unavailable"})

    def track_analysis(result: AnalyzeResponse) -> None:
        telemetry.capture(
            "analysis_completed",
            {
                "source": result.event.source,
                "status": result.status.value,
                "intent": result.event.type.value,
                "provider": analysis.provider,
            },
        )

    def push_dispatch_enabled() -> bool:
        return (
            os.getenv("OPENLOOP_PUSH_DISPATCH_ENABLED", "false").lower() == "true"
            and devices.provider != "disabled"
        )

    def owner_id(installation_id: UUID | None) -> str:
        if installation_id:
            return str(installation_id)
        require_install_id = os.getenv("OPENLOOP_REQUIRE_INSTALL_ID", "false").lower() == "true"
        if require_install_id:
            raise HTTPException(status_code=422, detail="X-OpenLoop-Install-Id is required")
        return os.getenv("OPENLOOP_DEFAULT_USER_ID", "dev-local")

    def require_client_identity(installation_id: UUID | None) -> str:
        """Apply the deployment's client-identity gate before any paid provider call.

        A UUID is only an MVP ownership boundary, not user authentication. It is
        nevertheless required by the deployed service so a request missing the
        mobile installation identity cannot consume Gemini/Kakao/KMA capacity.
        """

        return owner_id(installation_id)

    def require_owned(loop_id: str, installation_id: UUID | None) -> OpenLoop:
        try:
            loop = service.require(loop_id)
        except KeyError as error:
            raise _not_found(loop_id) from error
        if loop.owner_id != owner_id(installation_id):
            raise HTTPException(status_code=403, detail="Loop belongs to another installation")
        return loop

    def persist_analysis(result: AnalyzeResponse, installation_id: UUID | None) -> OpenLoop:
        loop = service.create(
            CreateLoopRequest(**result.model_dump()), owner_id=owner_id(installation_id)
        )
        telemetry.capture(
            "loop_created",
            {
                "source": loop.event.source,
                "status": loop.status.value,
                "intent": loop.event.type.value,
            },
        )
        return loop

    @api.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @api.get("/v1/capabilities", response_model=CapabilitiesResponse)
    def capabilities() -> CapabilitiesResponse:
        analysis_provider = analysis.provider
        push_enabled = push_dispatch_enabled()
        return CapabilitiesResponse(
            analysis_provider=analysis_provider,
            analysis_enabled=analysis_provider != "deterministic",
            analysis_model=getattr(analysis, "model", None),
            places_provider=places.provider,
            places_enabled=places.provider != "disabled",
            weather_provider=weather.provider,
            weather_enabled=weather.provider != "disabled",
            push_provider="fcm" if push_enabled else "disabled",
            push_enabled=push_enabled,
            analytics_provider=telemetry.provider,
            analytics_enabled=telemetry.provider != "disabled",
            sentry_enabled=sentry_enabled,
        )

    @api.post("/v1/analyze", response_model=AnalyzeResponse)
    def analyze(
        request: AnalyzeRequest,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> AnalyzeResponse:
        require_client_identity(installation_id)
        result = analysis.analyze(request)
        track_analysis(result)
        return result

    async def single_image_upload(
        request: Request,
        file: UploadFile = File(...),
    ) -> UploadFile:
        form = await request.form()
        uploads = form.getlist("file")
        if len(uploads) != 1:
            for upload in uploads:
                close = getattr(upload, "close", None)
                if close is not None:
                    await close()
            raise HTTPException(status_code=400, detail="Exactly one image is required")
        return file

    async def analyze_uploaded_image(
        file: UploadFile,
        companion_text: str | None,
        source: Literal["screenshot", "image"],
        reference_at: datetime | None,
    ) -> AnalyzeResponse:
        filename = file.filename or "capture"
        content_type = file.content_type
        try:
            if content_type not in ALLOWED_IMAGE_TYPES:
                raise HTTPException(status_code=415, detail="Unsupported image type")
            content = await file.read(MAX_IMAGE_BYTES + 1)
            if len(content) > MAX_IMAGE_BYTES:
                raise HTTPException(status_code=413, detail="Image must be 10 MB or smaller")
            if not content:
                raise HTTPException(status_code=400, detail="Image is empty")
        finally:
            await file.close()
        return analysis.analyze_image(
            filename=filename,
            content_type=content_type,
            content=content,
            companion_text=companion_text,
            source=source,
            reference_at=reference_at,
        )

    @api.post("/v1/analyze/image", response_model=AnalyzeResponse)
    async def analyze_image(
        file: UploadFile = Depends(single_image_upload),
        companion_text: str | None = Form(default=None, max_length=20_000),
        source: Literal["screenshot", "image"] = Form(default="image"),
        reference_at: datetime | None = Form(default=None),
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> AnalyzeResponse:
        require_client_identity(installation_id)
        if reference_at is not None and reference_at.tzinfo is None:
            raise HTTPException(status_code=422, detail="reference_at must include a timezone")
        result = await analyze_uploaded_image(file, companion_text, source, reference_at)
        track_analysis(result)
        return result

    @api.post("/v1/loops/analyze", response_model=OpenLoop, status_code=status.HTTP_201_CREATED)
    def analyze_and_create(
        request: AnalyzeRequest,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        require_client_identity(installation_id)
        result = analysis.analyze(request)
        track_analysis(result)
        return persist_analysis(result, installation_id)

    @api.post(
        "/v1/loops/analyze/image",
        response_model=OpenLoop,
        status_code=status.HTTP_201_CREATED,
    )
    async def analyze_image_and_create(
        file: UploadFile = Depends(single_image_upload),
        companion_text: str | None = Form(default=None, max_length=20_000),
        source: Literal["screenshot", "image"] = Form(default="image"),
        reference_at: datetime | None = Form(default=None),
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        require_client_identity(installation_id)
        if reference_at is not None and reference_at.tzinfo is None:
            raise HTTPException(status_code=422, detail="reference_at must include a timezone")
        result = await analyze_uploaded_image(file, companion_text, source, reference_at)
        track_analysis(result)
        return persist_analysis(result, installation_id)

    @api.post("/v1/loops", response_model=OpenLoop, status_code=status.HTTP_201_CREATED)
    def create_loop(
        request: CreateLoopRequest,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        loop = service.create(request, owner_id=owner_id(installation_id))
        telemetry.capture(
            "loop_created",
            {
                "source": loop.event.source,
                "status": loop.status.value,
                "intent": loop.event.type.value,
            },
        )
        return loop

    @api.get("/v1/places/search", response_model=list[NormalizedPlace])
    def search_places(
        q: str = Query(min_length=1, max_length=100),
        lat: float | None = Query(default=None, ge=-90, le=90),
        lon: float | None = Query(default=None, ge=-180, le=180),
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> list[NormalizedPlace]:
        require_client_identity(installation_id)
        if (lat is None) != (lon is None):
            raise HTTPException(status_code=422, detail="lat and lon must be provided together")
        results = places.search(q, latitude=lat, longitude=lon)
        telemetry.capture(
            "place_search_completed",
            {"provider": places.provider, "result_count": len(results)},
        )
        return results

    @api.get("/v1/weather", response_model=WeatherForecast)
    def get_weather(
        lat: float = Query(ge=31.0, le=44.0),
        lon: float = Query(ge=123.0, le=133.0),
        at: datetime | None = Query(default=None),
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> WeatherForecast:
        require_client_identity(installation_id)
        result = weather.forecast(latitude=lat, longitude=lon, at=at)
        telemetry.capture(
            "weather_lookup_completed",
            {"provider": result.provider, "available": result.available},
        )
        return result

    @api.post("/v1/devices/push-token", response_model=PushTokenResponse)
    def register_push_token(
        request: PushTokenRequest,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> PushTokenResponse:
        platform = request.platform
        result = (
            devices.register(request, owner_id(installation_id))
            if push_dispatch_enabled()
            else PushTokenResponse(registered=False, provider="disabled")
        )
        telemetry.capture(
            "push_token_registration",
            {"platform": platform, "registered": result.registered, "provider": result.provider},
        )
        return result

    @api.delete("/v1/devices/push-token", response_model=PushTokenResponse)
    def unregister_push_token(
        request: PushTokenRequest,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> PushTokenResponse:
        platform = request.platform
        result = devices.unregister(request, owner_id(installation_id))
        telemetry.capture(
            "push_token_unregistration",
            {"platform": platform, "registered": result.registered, "provider": result.provider},
        )
        return result

    @api.get("/v1/loops", response_model=list[OpenLoop])
    def list_loops(
        loop_status: LoopStatus | None = Query(default=None, alias="status"),
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> list[OpenLoop]:
        owner = owner_id(installation_id)
        return [
            loop
            for loop in repository.list(loop_status.value if loop_status else None)
            if loop.owner_id == owner
        ]

    @api.get("/v1/loops/{loop_id}", response_model=OpenLoop)
    def get_loop(
        loop_id: str,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        return require_owned(loop_id, installation_id)

    @api.patch("/v1/loops/{loop_id}/ambiguity", response_model=OpenLoop)
    def resolve_ambiguity(
        loop_id: str,
        request: AmbiguityUpdate,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        require_owned(loop_id, installation_id)
        try:
            return service.resolve_ambiguity(loop_id, request)
        except KeyError as error:
            raise _not_found(loop_id) from error

    @api.post("/v1/loops/{loop_id}/complete", response_model=OpenLoop)
    def complete_loop(
        loop_id: str,
        request: CompletionRequest | None = None,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        require_owned(loop_id, installation_id)
        try:
            return service.complete(loop_id, request.retention if request else None)
        except KeyError as error:
            raise _not_found(loop_id) from error

    @api.patch("/v1/loops/{loop_id}/retention", response_model=OpenLoop)
    def update_retention(
        loop_id: str,
        request: RetentionUpdate,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        require_owned(loop_id, installation_id)
        try:
            return service.set_retention(loop_id, request.retention)
        except KeyError as error:
            raise _not_found(loop_id) from error

    def update_item(
        loop_id: str,
        collection: str,
        item_id: str,
        request: CompletionUpdate,
        installation_id: UUID | None,
    ) -> OpenLoop:
        require_owned(loop_id, installation_id)
        try:
            return service.set_item_completion(loop_id, collection, item_id, request.completed)
        except KeyError as error:
            raise _not_found(item_id) from error

    @api.patch("/v1/loops/{loop_id}/checklist/{item_id}", response_model=OpenLoop)
    def update_checklist(
        loop_id: str,
        item_id: str,
        request: CompletionUpdate,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        return update_item(loop_id, "checklist", item_id, request, installation_id)

    @api.patch("/v1/loops/{loop_id}/actions/{item_id}", response_model=OpenLoop)
    def update_action(
        loop_id: str,
        item_id: str,
        request: CompletionUpdate,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        return update_item(loop_id, "actions", item_id, request, installation_id)

    @api.patch("/v1/loops/{loop_id}/checkpoints/{item_id}", response_model=OpenLoop)
    def update_checkpoint(
        loop_id: str,
        item_id: str,
        request: CompletionUpdate,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> OpenLoop:
        return update_item(loop_id, "checkpoints", item_id, request, installation_id)

    @api.delete("/v1/loops/{loop_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_loop(
        loop_id: str,
        installation_id: UUID | None = Header(default=None, alias="X-OpenLoop-Install-Id"),
    ) -> Response:
        require_owned(loop_id, installation_id)
        if not service.delete(loop_id):
            raise _not_found(loop_id)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return api


app = create_app()
