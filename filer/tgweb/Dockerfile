FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# sw.js 也要进镜像：播放器的加密流全靠它拦截 /media/ 并本地解密（漏了它视频就放不了）
COPY app.py index.html sw.js ./
RUN mkdir -p data
EXPOSE 9393
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9393"]
