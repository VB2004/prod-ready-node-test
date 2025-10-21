#!/bin/bash
set -euxo pipefail

# This script is designed for an Amazon Linux 2023 AMI.
# It sets up Docker and Docker Compose, then deploys Grafana and Loki as containers.

# ========== CONFIG VARIABLES ==========
S3_BUCKET_NAME="loki-logs-bharath-test"
REGION="ap-south-1"
GF_SECURITY_ADMIN_USER="admin"
GF_SECURITY_ADMIN_PASSWORD="admin"
GRAFANA_PORT=3000
LOKI_PORT=3100

# ========== INSTALL DOCKER & DOCKER COMPOSE ==========
yum update -y
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Install Docker Compose V2
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64"
curl -L "${DOCKER_COMPOSE_URL}" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

# ========== NGINX REVERSE PROXY ==========
echo "🚀 Installing and configuring Nginx..."
yum install -y nginx

# Ensure directory structure exists
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# Ensure nginx.conf includes sites-enabled directory
if ! grep -q "include /etc/nginx/sites-enabled/\*" /etc/nginx/nginx.conf; then
    echo "🔧 Adding include for sites-enabled to nginx.conf"
    sed -i '/http {/a\    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
fi

# Create backend reverse proxy config
tee /etc/nginx/sites-available/backend.conf >/dev/null <<EOF
server {
    listen 80;
    server_name _;

    # Proxy Grafana (port 3000)
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

    # Proxy Loki (port 3100)
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

# Enable the site and reload nginx
ln -sf /etc/nginx/sites-available/backend.conf /etc/nginx/sites-enabled/backend.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx


# ========== LOKI & GRAFANA CONFIGURATION ==========
# Use a common parent directory for all configurations and data
LOKI_DIR="/opt/loki"
GRAFANA_DIR="/opt/grafana"
mkdir -p $LOKI_DIR/config
mkdir -p $GRAFANA_DIR/data

# Create Loki configuration file
tee $LOKI_DIR/config/loki-config.yaml >/dev/null <<EOF
auth_enabled: false
server:
  http_listen_port: $LOKI_PORT
  grpc_listen_port: 9095

common:
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
  path_prefix: /tmp/loki
  storage:
    s3:
      bucketnames: $S3_BUCKET_NAME
      region: $REGION

ingester:
  chunk_idle_period: 5m
  chunk_target_size: 1048576
  max_chunk_age: 1h
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    heartbeat_period: 1m
  wal:
    enabled: true
    dir: /loki/wal

schema_config:
  configs:
  - from: 2020-05-15
    store: tsdb
    object_store: s3
    schema: v13
    index:
      prefix: index_
      period: 24h

compactor:
  working_directory: /loki/compactor
  shared_store: s3

storage_config:
  boltdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/cache
    resync_interval: 5m
    shared_store: s3
    cache_ttl: 24h
  aws:
    s3:
      bucketnames: $S3_BUCKET_NAME
      region: $REGION
      endpoint: s3.$REGION.amazonaws.com

limits_config:
  enforce_metric_name: false
  reject_old_samples: false
  reject_old_samples_max_age: 168h

chunk_store_config:
  max_look_back_period: 0s

ruler:
  enable_api: true
  enable_alertmanager_v2: true
  enable_local_storage: true
  storage:
    type: s3
    s3:
      bucketnames: $S3_BUCKET_NAME
      region: $REGION
      endpoint: s3.$REGION.amazonaws.com

query_range:
  split_queries_by_interval: 15m
  max_retries: 5
  parallelism: 32

EOF

# Docker Compose file - Writes to /opt/docker-compose.yaml
tee /opt/docker-compose.yaml >/dev/null <<EOF
version: "3.7"
services:
  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      # Use the variable $LOKI_DIR for host path resolution
      - $LOKI_DIR/config/loki-config.yaml:/etc/loki/config.yaml
      - loki-data:/loki
    restart: unless-stopped
  
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_USER=$GF_SECURITY_ADMIN_USER
      - GF_SECURITY_ADMIN_PASSWORD=$GF_SECURITY_ADMIN_PASSWORD
    ports:
      - "3000:3000"
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

sleep 2
curl http://localhost:3100/ready
sleep 15
curl http://localhost:3100/ready