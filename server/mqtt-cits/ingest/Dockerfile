FROM python:3.12-slim
RUN pip install --no-cache-dir paho-mqtt==2.1.0 "psycopg[binary]==3.2.3"
COPY citsdecode.py ingest.py schema.sql /app/
WORKDIR /app
CMD ["python", "-u", "ingest.py"]
