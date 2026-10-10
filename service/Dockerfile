# ---- build stage: compile bytecode (no third-party deps needed) ----
FROM python:3.12-slim AS builder
WORKDIR /build
COPY app.py .
RUN python -m compileall -q app.py

# ---- runtime stage ----
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder --chown=app:app /build/app.py .
USER 10001:10001
EXPOSE 8080
CMD ["python", "app.py"]