FROM python:3.12-slim
RUN pip install --no-cache-dir paho-mqtt==2.1.0
COPY archiver.py /archiver.py
CMD ["python", "-u", "/archiver.py"]
