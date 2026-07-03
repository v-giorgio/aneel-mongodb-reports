FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY scripts/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY scripts/app ./app

EXPOSE 5000

CMD ["flask", "--app", "app.main", "run", "--host", "0.0.0.0", "--port", "5000"]
