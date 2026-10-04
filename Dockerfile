# iHost runs a Rockchip RV1126 (quad Cortex-A7) -- 32-bit ARMv7.
# Build with:  docker buildx build --platform linux/arm/v7 ...
# Every dependency here is pure Python on purpose: no compiler, no native
# wheels, nothing that needs a 64-bit build.
FROM python:3.12-alpine

LABEL org.opencontainers.image.title="iHost Sensor Log" \
      org.opencontainers.image.description="Local time-series capture and off-box backup for SONOFF iHost / eWeLink CUBE" \
      org.opencontainers.image.source="https://github.com/YOUR-USER/ihost-sensorlog"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DATA_DIR=/data \
    WEB_PORT=8126

WORKDIR /app

# tzdata so timestamps in alerts match your wall clock (set TZ=Asia/Bahrain)
RUN apk add --no-cache tzdata

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

# The iHost mounts volumes owned by UID 1000. Run as that user so /data is
# writable without any chown dance in the add-on UI.
RUN adduser -D -u 1000 app && mkdir -p /data && chown -R app:app /data /app
USER app

VOLUME ["/data"]
EXPOSE 8126

HEALTHCHECK --interval=60s --timeout=10s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,os,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('WEB_PORT','8126')+'/healthz',timeout=5).status==200 else 1)"

CMD ["python", "-m", "app.main"]
