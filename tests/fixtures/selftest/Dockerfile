# 打版流水線的自我測試 image。純標準庫，build 幾秒鐘。
FROM python:3.12-slim
WORKDIR /app
COPY tests/fixtures/selftest/app.py /app/app.py
ENV PYTHONUNBUFFERED=1
EXPOSE 8099
CMD ["python", "/app/app.py"]
