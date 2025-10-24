#!/bin/bash
set -euxo pipefail

# ========== CONFIG VARIABLES ==========
REPO_URL="https://github.com/VB2004/prod-ready-node-test.git"
BRANCH="main"
APP_DIR="/opt/app"
APP_PORT=3000
# TODO: REPLACE THE IP BELOW
LOKI_URL="http://10.0.7.183:3100/loki/api/v1/push"
PROMTAIL_VERSION="2.8.8"

# ========== UPDATE & BASICS ==========
apt-get update -y
apt-get upgrade -y
apt-get install -y git unzip curl build-essential

# ========== NODEJS + PM2 ==========
# Install Node.js LTS via NodeSource with secure keyring
apt-get update -y
apt-get install -y ca-certificates curl gnupg

mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

NODE_VERSION="20"  # LTS version, change if needed
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list

apt-get update -y
apt-get install -y nodejs

# Install PM2 globally
npm install -g pm2


# ========== CLONE APP ==========
rm -rf $APP_DIR
git clone -b $BRANCH $REPO_URL $APP_DIR
cd $APP_DIR

if [ -f "tsconfig.json" ]; then
  npm install -g typescript
  npm install
  npm run build
else
  npm install
fi

# ========== START APP VIA PM2 ==========
# Create ec2-user equivalent on Ubuntu if not exists
if ! id "ubuntu" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" ubuntu
fi

su - ubuntu -c "
  pm2 start ${APP_DIR}/dist/server.js --name backend --env production || pm2 start ${APP_DIR}/server.js --name backend --env production
  pm2 save
"

# Create systemd service for PM2
cat >/etc/systemd/system/pm2-ubuntu.service <<EOF
[Unit]
Description=PM2 for the ubuntu user
After=network.target

[Service]
Type=forking
User=ubuntu
ExecStart=/usr/bin/pm2 resurrect
ExecReload=/usr/bin/pm2 reload all
ExecStop=/usr/bin/pm2 kill
Restart=always
TimeoutSec=30
Environment=HOME=/home/ubuntu

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pm2-ubuntu.service
systemctl start pm2-ubuntu.service

# ========== NGINX REVERSE PROXY ==========
apt-get install -y nginx
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

tee /etc/nginx/sites-available/backend.conf >/dev/null <<EOF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ln -sf /etc/nginx/sites-available/backend.conf /etc/nginx/sites-enabled/backend.conf
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
systemctl enable nginx

# ========== INSTALL PROMTAIL ==========
PROMTAIL_HOME="/usr/local/bin"
cd /opt
curl -LO "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip
chmod +x promtail-linux-amd64
mv promtail-linux-amd64 $PROMTAIL_HOME/promtail

# Create Promtail system user
if ! id "promtail" >/dev/null 2>&1; then
  adduser --system --no-create-home --shell /usr/sbin/nologin promtail
fi

# ========== PROMTAIL CONFIG ==========
chown -R ubuntu:ubuntu /home/ubuntu/.pm2/logs

tee /etc/promtail-config.yaml >/dev/null <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: debug

positions:
  filename: /tmp/positions.yaml

clients:
  - url: $LOKI_URL
    batchwait: 2s
    batchsize: 102400
    backoff_config:
      min_period: 500ms
      max_period: 5s

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: ubuntu-system
          __path__: /var/log/*.log

  - job_name: app
    static_configs:
      - targets:
          - localhost
        labels:
          job: nodejs-backend
          __path__: /home/ubuntu/.pm2/logs/*.log
EOF

# ========== CREATE SYSTEMD SERVICE FOR PROMTAIL ==========
cat >/etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail service
After=network.target

[Service]
User=root
ExecStart=$PROMTAIL_HOME/promtail -config.file=/etc/promtail-config.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable promtail
systemctl start promtail
