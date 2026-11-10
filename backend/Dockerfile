FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip git openssh-client && rm -rf /var/lib/apt/lists/*
ARG TERRAFORM_VERSION=1.17.1
RUN curl -fsSLo /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/terraform \
    && rm /tmp/terraform.zip
RUN pip install --no-cache-dir ansible-core==2.17.3
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -f http://localhost:8000/api/health || kill -TERM 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
