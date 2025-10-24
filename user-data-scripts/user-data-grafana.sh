#!/bin/bash
set -euxo pipefail

# This script is designed for Ubuntu 22.04+ EC2 instances.
# It sets up Docker, Docker Compose, Nginx reverse proxy, Loki, and Grafana containers.

# ========== CONFIG VARIABLES ==========
S3_BUCKET_NAME="viralo-loki-logs"
REGION="ap-south-1"
GF_SECURITY_ADMIN_USER="admin"
GF_SECURITY_ADMIN_PASSWORD="StrongPassword123!"
GRAFANA_PORT=3000
LOKI_PORT=3100

# ========== SYSTEM UPDATE & BASICS ==========
apt update -y
apt upgrade -y
apt install -y ca-certificates curl gnupg lsb-release

# ========== INSTALL DOCKER & DOCKER COMPOSE ==========
echo "🐳 Installing Docker..."

# Add Docker's official GPG key and repo
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start & enable Docker
systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group
usermod -aG docker ubuntu || true

# Install Docker Compose V2 binary explicitly
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64"
curl -L "${DOCKER_COMPOSE_URL}" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# ========== INSTALL & CONFIGURE NGINX ==========
echo "🌐 Installing and configuring Nginx..."
apt install -y nginx

mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# Ensure nginx.conf includes sites-enabled directory
if ! grep -q "include /etc/nginx/sites-enabled/" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
fi

# Create reverse proxy configuration
tee /etc/nginx/sites-available/backend.conf >/dev/null <<EOF
server {
    listen 80;
    server_name _;

    # Proxy Grafana
    location / {
        proxy_pass http://127.0.0.1:$GRAFANA_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Proxy Loki
    location /loki/ {
        proxy_pass http://127.0.0.1:$LOKI_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/backend.conf /etc/nginx/sites-enabled/backend.conf
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl restart nginx
systemctl enable nginx

# ========== LOKI & GRAFANA CONFIGURATION ==========
LOKI_DIR="/opt/loki"
GRAFANA_DIR="/opt/grafana"
mkdir -p $LOKI_DIR/config
mkdir -p $GRAFANA_DIR/data

tee $LOKI_DIR/config/loki-config.yaml >/dev/null <<EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9095
  log_level: info

distributor:
  ring:
    kvstore:
      store: inmemory

ingester:
  chunk_idle_period: 5m
  chunk_target_size: 2097152
  max_chunk_age: 1h
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
  wal:
    enabled: true
    dir: /loki/wal

querier:
  query_ingesters_within: 2h

query_range:
  align_queries_with_step: true
  max_retries: 5
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
        ttl: 24h

limits_config:
  split_queries_by_interval: 15m
  max_query_series: 100000
  max_cache_freshness_per_query: 10m
  retention_period: 240h
  max_streams_per_user: 100000
  max_entries_limit_per_query: 500000

schema_config:
  configs:
    - from: 2023-01-01
      store: tsdb
      object_store: s3
      schema: v12
      index:
        prefix: loki_index_
        period: 24h

storage_config:
  aws:
    region: $REGION
    bucketnames: $S3_BUCKET_NAME
    s3forcepathstyle: false
  tsdb_shipper:
    active_index_directory: /loki/boltdb-shipper-active
    cache_location: /loki/boltdb-shipper-cache
    cache_ttl: 24h

compactor:
  working_directory: /loki/compactor
  shared_store: s3
  retention_enabled: true
EOF

# ========== DOCKER COMPOSE SETUP ==========
tee /opt/docker-compose.yaml >/dev/null <<EOF
version: "3.7"
services:
  loki:
    image: grafana/loki:2.8.8
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      - $LOKI_DIR/config/loki-config.yaml:/etc/loki/config.yaml
      - loki-data:/loki
    command: -config.file=/etc/loki/config.yaml -config.expand-env=true -log.level=debug
    restart: unless-stopped
  
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_USER=$GF_SECURITY_ADMIN_USER
      - GF_SECURITY_ADMIN_PASSWORD=$GF_SECURITY_ADMIN_PASSWORD
    ports:
      - "3000:3000"
    depends_on:
      - loki
    volumes:
      - grafana-storage:/var/lib/grafana
    restart: unless-stopped

volumes:
  loki-data:
  grafana-storage:
EOF

# ========== START SERVICES ==========
cd /opt
docker-compose up -d

sleep 1
curl -f http://localhost:3100/ready || echo "Loki not ready yet, will retry in 15s..."
sleep 15
curl -f http://localhost:3100/ready || echo "Still waiting for Loki..."