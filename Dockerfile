# --- build stage: install dependencies into a venv ---
FROM python:3.13-slim AS build

WORKDIR /build
COPY app/requirements.txt .
RUN python -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# --- runtime stage: code + venv only, non-root ---
FROM python:3.13-slim

COPY --from=build /opt/venv /opt/venv
COPY app/main.py /srv/app/main.py

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

USER 10001:10001
WORKDIR /srv/app
EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
