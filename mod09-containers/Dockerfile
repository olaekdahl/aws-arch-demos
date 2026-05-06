FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask==3.0.3 gunicorn==22.0.0
COPY app.py .
EXPOSE 80
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:80", "--access-logfile", "-", "app:app"]
