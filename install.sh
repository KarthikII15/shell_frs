#!/usr/bin/env bash
#==============================================================================
# install-stack-debian.sh
# Full application stack installer for DEBIAN / UBUNTU.
# Backup for environments without Ansible. Run as root (sudo).
#
#   sudo KEYCLOAK_ADMIN_PASSWORD='xxx' DB_PASSWORD='yyy' ./install-stack-debian.sh
#
# Idempotent-ish: each step checks before installing, so re-running is safe.
#==============================================================================
set -euo pipefail

#------------------------------- CONFIG ---------------------------------------
NODE_VERSION="20.20.2"
PNPM_VERSION="7.0.1"
PM2_VERSION="7.0.1"                 # NOTE: pm2 3.7.0 does not exist on npm
PYTHON_VERSION="3.12"
PYTHON_PATCH="3.12.11"
PYTHON_BUILD_DATE="20250612"        # python-build-standalone release tag
POSTGRES_MAJOR="16"
NGINX_VERSION="1.30.0"
KEYCLOAK_VERSION="26.6.0"
KAFKA_VERSION="3.7.0"
KAFKA_SCALA="2.13"
CERTBOT_VERSION="2.9.0"
KEYCLOAK_HTTP_PORT="9090"
KAFKA_PORT="9092"
FACE_PORT="5050"
FACE_DIR="/opt/face-service"

# Secrets (override via environment; do NOT hardcode for production)
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-CHANGE_ME}"
KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
FRS_DB_NAME="${FRS_DB_NAME:-FRS}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-CHANGE_ME}"

ARCH="$(uname -m)"   # expected: x86_64
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
#------------------------------------------------------------------------------

log()  { echo -e "\n\033[1;34m[*]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[X]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."
[[ "$ARCH" == "x86_64" ]] || die "This script targets x86_64; detected $ARCH."
command -v apt-get >/dev/null || die "apt-get not found — this is the Debian/Ubuntu script."

export DEBIAN_FRONTEND=noninteractive
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
log "Detected Ubuntu/Debian codename: ${CODENAME:-unknown}"

#============================== BASE PACKAGES =================================
install_base() {
  log "Installing base packages"
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg tar xz-utils gzip zstd \
                     build-essential acl lsb-release
  ok "Base packages installed"
}

#================================== JAVA =====================================
install_java() {
  if command -v java >/dev/null && java -version 2>&1 | grep -q '21\.'; then
    ok "Java 21 already present"; return
  fi
  log "Installing OpenJDK 21"
  apt-get install -y openjdk-21-jdk-headless
  ok "Java installed: $(java -version 2>&1 | head -1)"
}

#================================= NODE.JS ====================================
install_node() {
  if [[ -x /opt/node-v${NODE_VERSION}-linux-x64/bin/node ]]; then
    ok "Node ${NODE_VERSION} already installed"
  else
    if [[ -f "$SCRIPT_DIR/node-v${NODE_VERSION}-linux-x64.tar.xz" ]]; then
      log "Using local archive for Node.js ${NODE_VERSION}"
      tar -xJf "$SCRIPT_DIR/node-v${NODE_VERSION}-linux-x64.tar.xz" -C /opt/
    else
      log "Installing Node.js ${NODE_VERSION} (official tarball)"
      curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
      tar -xJf /tmp/node.tar.xz -C /opt/
    fi
    ln -sfn "/opt/node-v${NODE_VERSION}-linux-x64" /opt/nodejs
    for b in node npm npx; do ln -sf /opt/nodejs/bin/$b /usr/bin/$b; done
    echo 'export PATH=/opt/nodejs/bin:$PATH' > /etc/profile.d/nodejs.sh
    ok "Node installed: $(/opt/nodejs/bin/node --version)"
  fi
  log "Installing global npm packages (pnpm@${PNPM_VERSION}, pm2@${PM2_VERSION})"
  /opt/nodejs/bin/node /opt/nodejs/bin/npm install -g "pnpm@${PNPM_VERSION}" "pm2@${PM2_VERSION}"
  ok "Global npm packages installed"
}

#================================= PYTHON 3.12 ===============================
install_python() {
  if [[ -x /opt/python${PYTHON_VERSION}/bin/python${PYTHON_VERSION} ]]; then
    ok "Python ${PYTHON_VERSION} already installed"; return
  fi
  if [[ -f "$SCRIPT_DIR/cpython-${PYTHON_PATCH}+${PYTHON_BUILD_DATE}-x86_64-unknown-linux-gnu-install_only.tar.gz" ]]; then
    log "Using local archive for Python ${PYTHON_PATCH}"
    tar -xzf "$SCRIPT_DIR/cpython-${PYTHON_PATCH}+${PYTHON_BUILD_DATE}-x86_64-unknown-linux-gnu-install_only.tar.gz" -C /opt/
  elif [[ -f "$SCRIPT_DIR/python.tar.gz" ]]; then
    log "Using local archive for Python (python.tar.gz)"
    tar -xzf "$SCRIPT_DIR/python.tar.gz" -C /opt/
  else
    log "Installing standalone Python ${PYTHON_PATCH}"
    curl -fsSL -o /tmp/python.tar.gz "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_DATE}/cpython-${PYTHON_PATCH}+${PYTHON_BUILD_DATE}-x86_64-unknown-linux-gnu-install_only.tar.gz"
    tar -xzf /tmp/python.tar.gz -C /opt/
  fi
  mv /opt/python "/opt/python${PYTHON_VERSION}"
  ln -sf "/opt/python${PYTHON_VERSION}/bin/python${PYTHON_VERSION}" "/usr/local/bin/python${PYTHON_VERSION}"
  ok "Python installed: $(/opt/python${PYTHON_VERSION}/bin/python${PYTHON_VERSION} --version)"
}
PYBIN="/opt/python${PYTHON_VERSION}/bin/python${PYTHON_VERSION}"

#================================ POSTGRESQL =================================
install_postgres() {
  if command -v psql >/dev/null; then
    ok "PostgreSQL already installed"
  else
    log "Installing PostgreSQL ${POSTGRES_MAJOR} via PGDG (fallback to distro)"
    if curl -fsSL -o /etc/apt/keyrings/pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc 2>/dev/null; then
      echo "deb [signed-by=/etc/apt/keyrings/pgdg.asc] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
      apt-get update -y || true
    fi
    if ! apt-get install -y "postgresql-${POSTGRES_MAJOR}" "postgresql-${POSTGRES_MAJOR}-pgvector"; then
      warn "PGDG failed (codename '${CODENAME}' may be too new) — using distro PostgreSQL"
      rm -f /etc/apt/sources.list.d/pgdg.list
      apt-get update -y
      apt-get install -y postgresql postgresql-contrib
    fi
    systemctl enable --now postgresql
    ok "PostgreSQL installed"
  fi
  provision_db
}

provision_db() {
  log "Provisioning databases '${KEYCLOAK_DB_NAME}' and '${FRS_DB_NAME}' / user '${DB_USER}'"
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  
  for db in "${KEYCLOAK_DB_NAME}" "${FRS_DB_NAME}"; do
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1 || \
      sudo -u postgres psql -c "CREATE DATABASE $db OWNER ${DB_USER};"
  done
  ok "Databases provisioned"
}

#================================== REDIS ====================================
install_redis() {
  if systemctl is-active --quiet redis-server 2>/dev/null; then
    ok "Redis already running"; return
  fi
  log "Installing Redis"
  apt-get install -y redis-server
  systemctl enable --now redis-server
  ok "Redis installed and running"
}

#================================== NGINX ====================================
install_nginx() {
  if command -v nginx >/dev/null && nginx -v 2>&1 | grep -q "${NGINX_VERSION}"; then
    ok "nginx ${NGINX_VERSION} already installed"; return
  fi
  log "Installing nginx ${NGINX_VERSION} (not from source)"
  
  if [[ -f "$SCRIPT_DIR/nginx_${NGINX_VERSION}.deb" ]]; then
    log "Using local deb package for nginx ${NGINX_VERSION}"
    apt-get install -y "$SCRIPT_DIR/nginx_${NGINX_VERSION}.deb"
  else
    log "Configuring official NGINX APT repository"
    apt-get install -y curl gnupg2 ca-certificates lsb-release debian-archive-keyring
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg || true
    OS_ID=$(. /etc/os-release && echo "$ID")
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${OS_ID} $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
    apt-get update -y
    
    log "Downloading and installing nginx ${NGINX_VERSION}"
    apt-get install -y "nginx=${NGINX_VERSION}*"
  fi

  systemctl enable --now nginx
  ok "nginx installed: $(nginx -v 2>&1)"
}

#================================= CERTBOT ===================================
install_certbot() {
  if [[ -x /opt/certbot/bin/certbot ]]; then ok "certbot already installed"; return; fi
  log "Installing certbot ${CERTBOT_VERSION} (isolated venv)"
  "$PYBIN" -m venv /opt/certbot
  /opt/certbot/bin/pip install --upgrade pip setuptools wheel
  /opt/certbot/bin/pip install "certbot==${CERTBOT_VERSION}"
  ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
  ok "certbot installed: $(/opt/certbot/bin/certbot --version 2>&1)"
}

#================================= KEYCLOAK ==================================
install_keycloak() {
  if [[ -d /opt/keycloak-${KEYCLOAK_VERSION} ]]; then
    ok "Keycloak ${KEYCLOAK_VERSION} already present"
  else
    log "Installing Keycloak ${KEYCLOAK_VERSION}"
    id keycloak &>/dev/null || useradd --system --shell /sbin/nologin keycloak
    if [[ -f "$SCRIPT_DIR/keycloak-${KEYCLOAK_VERSION}.tar.gz" ]]; then
      log "Using local archive for Keycloak ${KEYCLOAK_VERSION}"
      tar -xzf "$SCRIPT_DIR/keycloak-${KEYCLOAK_VERSION}.tar.gz" -C /opt/
    else
      log "Downloading Keycloak ${KEYCLOAK_VERSION}"
      curl -fsSL -o /tmp/keycloak.tar.gz "https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz"
      tar -xzf /tmp/keycloak.tar.gz -C /opt/
    fi
    ln -sfn "/opt/keycloak-${KEYCLOAK_VERSION}" /opt/keycloak
    chown -R keycloak:keycloak "/opt/keycloak-${KEYCLOAK_VERSION}"
  fi

  log "Writing Keycloak config (Postgres backend)"
  cat > /opt/keycloak/conf/keycloak.conf <<EOF
db=postgres
db-username=${DB_USER}
db-password=${DB_PASSWORD}
db-url=jdbc:postgresql://localhost/${KEYCLOAK_DB_NAME}
health-enabled=true
metrics-enabled=true
http-enabled=true
http-port=${KEYCLOAK_HTTP_PORT}
hostname-strict=false
proxy-headers=xforwarded
EOF
  chown keycloak:keycloak /opt/keycloak/conf/keycloak.conf

  log "Building Keycloak (one-time, for --optimized start)"
  sudo -u keycloak /opt/keycloak/bin/kc.sh build || warn "kc.sh build reported issues (often safe on first run)"

  cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak ${KEYCLOAK_VERSION}
After=network.target postgresql.service
[Service]
User=keycloak
Group=keycloak
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=${KEYCLOAK_ADMIN_USER}
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now keycloak
  ok "Keycloak running on :${KEYCLOAK_HTTP_PORT} (admin console at /admin/)"
}

#================================== KAFKA ====================================
install_kafka() {
  if [[ -d /opt/kafka_${KAFKA_SCALA}-${KAFKA_VERSION} ]]; then
    ok "Kafka ${KAFKA_VERSION} already present"
  else
    log "Installing Kafka ${KAFKA_VERSION} (KRaft single-node)"
    id kafka &>/dev/null || useradd --system --shell /sbin/nologin kafka
    mkdir -p /var/lib/kafka && chown kafka:kafka /var/lib/kafka
    if [[ -f "$SCRIPT_DIR/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz" ]]; then
      log "Using local archive for kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz"
      tar -xzf "$SCRIPT_DIR/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz" -C /opt/
    else
      log "Downloading Kafka ${KAFKA_VERSION}"
      curl -fsSL -o /tmp/kafka.tgz "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz"
      tar -xzf /tmp/kafka.tgz -C /opt/
    fi
    ln -sfn "/opt/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}" /opt/kafka
    chown -R kafka:kafka "/opt/kafka_${KAFKA_SCALA}-${KAFKA_VERSION}"
  fi

  cat > /opt/kafka/config/kraft/server.properties <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@localhost:9093
listeners=PLAINTEXT://:${KAFKA_PORT},CONTROLLER://:9093
inter.broker.listener.name=PLAINTEXT
advertised.listeners=PLAINTEXT://localhost:${KAFKA_PORT}
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
log.dirs=/var/lib/kafka
num.partitions=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
EOF
  chown kafka:kafka /opt/kafka/config/kraft/server.properties

  if [[ ! -f /var/lib/kafka/meta.properties ]]; then
    log "Formatting KRaft storage (first run)"
    KID="$(/opt/kafka/bin/kafka-storage.sh random-uuid)"
    /opt/kafka/bin/kafka-storage.sh format -t "$KID" -c /opt/kafka/config/kraft/server.properties
    chown -R kafka:kafka /var/lib/kafka
  fi

  cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka ${KAFKA_VERSION} (KRaft)
After=network.target
[Service]
User=kafka
Group=kafka
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/kraft/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now kafka
  ok "Kafka running on :${KAFKA_PORT}"
}

#============================== FACE SERVICE =================================
install_face_service() {
  log "Setting up Face Quality Microservice venv"
  apt-get install -y libgl1 libglib2.0-0 cmake gcc g++
  id faceapp &>/dev/null || useradd --system --shell /sbin/nologin --home-dir "$FACE_DIR" faceapp
  mkdir -p "$FACE_DIR" && chown faceapp:faceapp "$FACE_DIR"

  if [[ ! -f "$FACE_DIR/requirements.txt" ]]; then
    cat > "$FACE_DIR/requirements.txt" <<'EOF'
flask==3.1.3
werkzeug==3.1.8
insightface==1.0.1
onnx==1.21.0
onnxruntime==1.26.0
opencv-python==4.13.0.92
numpy==2.4.6
scipy==1.17.1
EOF
  fi

  [[ -x "$FACE_DIR/venv/bin/python" ]] || "$PYBIN" -m venv "$FACE_DIR/venv"
  "$FACE_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
  warn "Installing pinned pip packages — if a version is missing on PyPI this step fails; adjust requirements.txt"
  "$FACE_DIR/venv/bin/pip" install -r "$FACE_DIR/requirements.txt"
  "$FACE_DIR/venv/bin/pip" install gunicorn

  cat > /etc/systemd/system/face-service.service <<EOF
[Unit]
Description=Face Quality Microservice
After=network.target
[Service]
User=faceapp
Group=faceapp
WorkingDirectory=${FACE_DIR}
ExecStart=${FACE_DIR}/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:${FACE_PORT} app:app
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable face-service
  warn "face-service enabled but NOT started — deploy your Flask app to ${FACE_DIR}/app.py then: systemctl start face-service"
}

#================================== MAIN =====================================
main() {
  [[ "$KEYCLOAK_ADMIN_PASSWORD" == "CHANGE_ME" ]] && warn "KEYCLOAK_ADMIN_PASSWORD not set — using placeholder!"
  [[ "$DB_PASSWORD" == "CHANGE_ME" ]] && warn "DB_PASSWORD not set — using placeholder!"
  install_base
  install_java
  install_node
  install_python
  install_postgres
  install_redis
  install_nginx
  install_certbot
  install_keycloak
  install_kafka
  install_face_service
  echo
  ok "All components processed. Services: keycloak:${KEYCLOAK_HTTP_PORT} kafka:${KAFKA_PORT} face:${FACE_PORT}(manual start)"
  echo "Remember to open these ports in your cloud security group / ufw."
}
main "$@"
