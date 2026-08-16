FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.0 AS lambda-adapter

FROM python:3.13-slim

COPY --from=lambda-adapter /lambda-adapter /opt/extensions/lambda-adapter

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AWS_LWA_PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/health \
    AWS_LWA_READINESS_CHECK_MIN_UNHEALTHY_STATUS=500

WORKDIR /var/task

COPY services/api/requirements.txt ./requirements.txt
RUN python -m pip install --no-cache-dir --requirement requirements.txt

COPY services/api/app ./app

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
