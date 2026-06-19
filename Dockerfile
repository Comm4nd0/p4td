# Build stage
FROM python:3.11-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies.
# requirements-prod.txt does `-r requirements.txt`, so BOTH files must be in the
# image for pip to resolve the include.
COPY requirements.txt requirements-prod.txt ./
RUN pip install --no-cache-dir -r requirements-prod.txt

# Production stage
FROM python:3.11-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy application code
COPY --chown=appuser:appuser . .

# Create staticfiles and media directories with correct permissions
RUN mkdir -p /app/staticfiles /app/media && chown -R appuser:appuser /app/staticfiles /app/media

# Switch to non-root user
USER appuser

# Collect static files. DEBUG and a throwaway secret are set inline for this
# single RUN only (collectstatic needs them) — they are NOT persisted as ENV, so
# the running container defaults to DJANGO_DEBUG unset (i.e. False) and requires
# a real DJANGO_SECRET_KEY from the environment at runtime.
RUN DJANGO_DEBUG=True DJANGO_SECRET_KEY=build-only python manage.py collectstatic --noinput

# Expose port
EXPOSE 8000

# Health check — hit the dependency-free liveness endpoint (see urls.py healthz)
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz/', timeout=5)" || exit 1

# Run with gunicorn. --max-requests + jitter recycle each worker after ~1000
# requests (staggered) to cap memory growth from any slow leaks.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--threads", "2", \
     "--max-requests", "1000", "--max-requests-jitter", "100", \
     "p4td_backend.wsgi:application"]
