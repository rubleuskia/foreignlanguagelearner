# Build with immutable values, for example:
# docker build --build-arg PYTHON_BASE_IMAGE=python@sha256:<digest> \
#   --build-arg FFMPEG_VERSION=<debian-version> --build-arg MODEL_URL=<private-build-url> \
#   --build-arg MODEL_SHA256=<sha256> .
ARG PYTHON_BASE_IMAGE
FROM ${PYTHON_BASE_IMAGE}

ARG FFMPEG_VERSION
ARG MODEL_URL
ARG MODEL_SHA256

RUN test -n "$FFMPEG_VERSION" && apt-get update \
    && apt-get install -y --no-install-recommends "ffmpeg=${FFMPEG_VERSION}" ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY tools/subtitle-aligner/worker/requirements-worker.lock /tmp/requirements-worker.lock
RUN pip install --no-cache-dir --require-hashes -r /tmp/requirements-worker.lock

RUN test -n "$MODEL_URL" && test -n "$MODEL_SHA256" \
    && mkdir -p /opt/models \
    && curl --fail --silent --show-error --location "$MODEL_URL" --output /opt/models/base.pt \
    && echo "$MODEL_SHA256  /opt/models/base.pt" | sha256sum --check --strict

COPY backend /app/backend
COPY tools/subtitle-aligner /app/tools/subtitle-aligner
ENV PYTHONPATH=/app MODEL_DIR=/opt/models PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65532:65532
ENTRYPOINT ["python", "tools/subtitle-aligner/worker/worker.py"]
