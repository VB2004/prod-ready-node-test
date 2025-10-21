#!/bin/bash
set -euxo pipefail

# This script is designed for an Amazon Linux 2023 AMI.
# It is robust against common failures, including package conflicts and permission issues.

# ========== CONFIG VARIABLES ==========
REPO_URL="https://github.com/VB2004/prod-ready-node-test.git"
BRANCH="main"
APP_DIR="/opt/app"
APP_PORT=3000
# TODO: REPLACE THE IP BELOW
LOKI_URL="http://10.0.7.183:3100/loki/api/v1/push"
PROMTAIL_VERSION="2.8.8"

# ========== GET INSTANCE METADATA USING IMDSv2 ==========
# Retrieves instance metadata securely using a session token.
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/instance-id)
HOSTNAME=$(hostname)

# ========== UPDATE & BASICS ==========
# Uses `yum` for Amazon Linux. The `--allowerasing` flag resolves curl-minimal conflicts.
yum update -y
yum install -y git unzip --allowerasing
# Install curl separately to be safe from dependency issues
yum install -y curl --allowerasing

# ========== NODEJS + PM2 ==========
# Installs Node.js and PM2, ensuring a consistent user context for PM2.
yum install -y nodejs
npm install -g pm2

# ========== CLONE APP ==========
# Clones the application repository and handles TypeScript build process.
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
# Starts the application and manages it with PM2 under the 'ec2-user' context.
su - ec2-user -c "
  pm2 start ${APP_DIR}/dist/server.js --name backend --env production || pm2 start ${APP_DIR}/server.js --name backend --env production
  pm2 save
"

# Create a systemd service for PM2 to ensure the app auto-starts on reboot.
cat >/etc/systemd/system/pm2-ec2-user.service <<EOF
[Unit]
Description=PM2 for the ec2-user
After=network.target

[Service]
Type=forking
User=ec2-user
ExecStart=/usr/bin/pm2 resurrect
ExecReload=/usr/bin/pm2 reload all
ExecStop=/usr/bin/pm2 kill
Restart=always
TimeoutSec=30
Environment=HOME=/home/ec2-user

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pm2-ec2-user.service
systemctl start pm2-ec2-user.service

# ========== NGINX REVERSE PROXY ==========
# Installs and configures Nginx, creating necessary directories to prevent failure.
yum install -y nginx
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# Use `tee` with `sudo` for reliable file creation with root permissions.
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
# Installs Promtail to ship logs to Loki. It also creates a dedicated user for security.
PROMTAIL_HOME="/usr/local/bin"

cd /opt
curl -LO "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip
chmod +x promtail-linux-amd64
mv promtail-linux-amd64 $PROMTAIL_HOME/promtail

useradd --system --no-create-home --shell /bin/false promtail

# ========== PROMTAIL CONFIG ==========
# Creates the Promtail configuration file with scrape jobs.
chown -R ec2-user:ec2-user /home/ec2-user/.pm2/logs

tee /etc/promtail-config.yaml >/dev/null <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: debug

positions:
  filename: /tmp/positions.yaml

clients:
  - url: $LOKI_URL

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: ec2-system
          instance: $INSTANCE_ID
          host: $HOSTNAME
          __path__: /var/log/*.log

  - job_name: app
    static_configs:
      - targets:
          - localhost
        labels:
          job: nodejs-backend
          instance: $INSTANCE_ID
          host: $HOSTNAME
          __path__: /home/ec2-user/.pm2/logs/*.log
EOF

# ========== CREATE SYSTEMD SERVICE FOR PROMTAIL ==========
# Creates and enables a systemd service to run Promtail.
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