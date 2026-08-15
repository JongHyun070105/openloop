from fastapi import FastAPI

from .demo_analyzer import analyze_demo
from .models import AnalyzeRequest, AnalyzeResponse

app = FastAPI(
    title="OpenLoop API",
    version="0.1.0",
    description="Turn unstructured context into actionable, confidence-aware loops.",
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/v1/analyze", response_model=AnalyzeResponse)
def analyze(request: AnalyzeRequest) -> AnalyzeResponse:
    return analyze_demo(request)
