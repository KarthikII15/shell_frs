#!/usr/bin/env bash
#==============================================================================
# deploy-app.sh  —  Motivity Face Recognition System — Application Deployer
#
# Run AFTER install.sh has set up the infrastructure.
# Reads Frs-Sh/deploy.conf for configuration, with CLI overrides.
#
# Usage:
#   sudo ./deploy-app.sh                           # reads deploy.conf beside it
#   sudo ./deploy-app.sh --config /path/to.conf
#   sudo ./deploy-app.sh --domain frs.example.com --ssl
#   sudo ./deploy-app.sh --mode dev                # local dev, no nginx/PM2/SSL
#
# Re-deploy (code update on same server):
#   sudo ./deploy-app.sh --domain frs.motivitylabs.com --ssl
#   (secrets & realm are preserved; only app code/config is refreshed)
#==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DEPLOY_LOG="/tmp/frs-deploy-$(date +%Y%m%d-%H%M%S).log"

#──────────────────────────────────────────────────────────────────────────────
# COLOUR HELPERS
#──────────────────────────────────────────────────────────────────────────────
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[1;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "\n${BLUE}[*]${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC}  $*"; }
info() { echo -e "    ${CYAN}→${NC}  $*"; }
die()  { echo -e "\n${RED}[FATAL]${NC} $*\n  Log: ${DEPLOY_LOG}" >&2; exit 1; }
banner(){
  echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${BLUE}  $*${NC}"
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

#──────────────────────────────────────────────────────────────────────────────
# DEFAULT VALUES  (overridden by deploy.conf, then CLI args)
#──────────────────────────────────────────────────────────────────────────────

# Deployment
DEPLOY_MODE=ip-only
SERVER_IP=
DOMAIN=
CERTBOT_EMAIL=
APP_DIR=
NODE_ENV=production
AUTH_MODE=keycloak

# Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=FRS
DB_USER=postgres
DB_PASSWORD=
DB_SSL=false
DB_SSL_REJECT_UNAUTHORIZED=false
DB_POOL_MAX=20
DB_IDLE_TIMEOUT_MS=30000
DB_CONNECTION_TIMEOUT_MS=5000
DB_KEEPALIVE=true
DB_KEEPALIVE_DELAY_MS=10000
STATEMENT_TIMEOUT_MS=30000

# Keycloak
KEYCLOAK_HTTP_PORT=9090
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=
KEYCLOAK_REALM=attendance
KEYCLOAK_CLIENT_ID=attendance-frontend
KEYCLOAK_API_CLIENT_ID=attendance-api
KEYCLOAK_LOGIN_THEME=motivity-frs
KEYCLOAK_CLOCK_TOLERANCE_SEC=5
KEYCLOAK_STRICT_AUDIENCE=false

# First super-admin (created in Keycloak during provisioning)
SUPER_ADMIN_EMAIL=
SUPER_ADMIN_USERNAME=admin
SUPER_ADMIN_PASSWORD=

# Secrets (auto-generated when blank)
DEVICE_JWT_SECRET=
ENROLLMENT_TOKEN_SECRET=
METRICS_AUTH_TOKEN=
HEALTH_AUTH_TOKEN=
HRMS_WEBHOOK_API_KEY=
JETSON_WEBHOOK_SECRET=
EMBEDDING_ENCRYPTION_KEY=
EMBEDDING_ENCRYPTION_KEY_ID=v1

# Redis
REDIS_URL=redis://localhost:6379

# Kafka
KAFKA_BROKERS=localhost:9092
KAFKA_TOPIC_PREFIX=scanalitix.
KAFKA_CLIENT_ID=scanalitix-node
KAFKA_GROUP_ID=scanalitix-consumer-group
KAFKA_NUM_PARTITIONS=3
KAFKA_REPLICATION_FACTOR=1
KAFKA_SSL_ENABLED=false
KAFKA_SASL_MECHANISM=
KAFKA_SASL_USERNAME=
KAFKA_SASL_PASSWORD=

# SMTP
SMTP_SERVICE=gmail
SMTP_USER=
SMTP_PASSWORD=
SMTP_HOST=
SMTP_PORT=587
SMTP_FROM=
SMTP_FROM_NAME=FRS
SMTP_REPLY_TO=

# Alerting
ALERT_SLACK_WEBHOOK_URL=
ALERT_SLACK_VERBOSE=false
PAGERDUTY_INTEGRATION_KEY=

# Jetson / Edge
JETSON_IP_ALLOWLIST=
HEALTH_IP_ALLOWLIST=
METRICS_IP_ALLOWLIST=
JETSON_EVENT_SECRET=
JETSON_FORCE_HTTP=true
JETSON_SIDECAR_URL=
JETSON_MODEL_VERSION=1.0.0
REMOTE_ENROLLMENT_PHOTO_DIR=

# AI features
ENABLE_FACE_RECOGNITION=false
ENABLE_ALPR=false
ENABLE_REID=false
FACE_MATCH_THRESHOLD=0.50
FACE_QUALITY_PORT=5050
DEFAULT_FACE_QUALITY_THRESHOLD=0.60
MODEL_PATH=
FACE_DB_PATH=

# Integrations
GOOGLE_CALENDAR_API_KEY=
COMPANY_CALENDAR_ID=
HOLIDAY_CALENDAR_ID=
SENTRY_DSN=
VITE_SENTRY_DSN=
LOG_LEVEL=info
MONITORING_URL=

# App behaviour
APP_NAME="FRS Backend"
APP_TIMEZONE=UTC
VITE_IDLE_TIMEOUT_MINUTES=30
DEVICE_OFFLINE_THRESHOLD_MIN=5
DEVICE_TOKEN_TTL_SECONDS=2592000
INVITE_TOKEN_TTL_HOURS=72
BIOMETRIC_CONSENT_VERSION=1.0
ENFORCE_EVENT_SIGNATURES=true
VITE_APP_VERSION=

# Retention
RETENTION_DAYS=30
RETENTION_ATTENDANCE_DAYS=730
RETENTION_AUDIT_LOG_DAYS=365
RETENTION_DEVICE_EVENTS_DAYS=90
RETENTION_GDPR_ERASURE_DAYS=365
RETENTION_FACE_EMBEDDINGS_YEARS=3
ATTENDANCE_PING_RETENTION_DAYS=90
PHOTO_PURGE_DELAY_HOURS=24
PHOTO_PURGE_INTERVAL_MINUTES=60

# Performance
FRAME_QUEUE_SIZE=100
EVENT_QUEUE_SIZE=1000
SNAPSHOT_QUEUE_SIZE=500
INFERENCE_THREADS=4
EVENT_PUSH_THREADS=2
MAX_HEAP_MEMORY_PERCENT=80
MOTION_SKIP_FRAMES=3
SNAPSHOT_UPLOAD_CONCURRENCY=3
SNAPSHOT_MAX_RETRIES=3
SNAPSHOT_MAX_TEMP_SIZE_MB=1024
SNAPSHOT_COMPRESSION_QUALITY=80
HTTP_TIMEOUT_MS=15000
HTTP_MAX_RETRIES=3
HTTP_RETRY_DELAY_MS=1000
INFRA_CPU_THRESHOLD=80
INFRA_MEM_THRESHOLD_MB=90

# AI monitoring
AI_DRIFT_THRESHOLD=0.03
AI_DRIFT_WINDOW_DAYS=7
AI_DRIFT_INTERVAL_MS=604800000
BIAS_ACCURACY_THRESHOLD=0.05
BIAS_SAMPLE_PERIOD_DAYS=30
DUPLICATE_SIMILARITY_BLOCK=0.92
DUPLICATE_SIMILARITY_FLAG=0.85

# Ports
BACKEND_PORT=8080
NGINX_HTTP_PORT=80
NGINX_HTTPS_PORT=443

#──────────────────────────────────────────────────────────────────────────────
# SOURCE CONF FILE
#──────────────────────────────────────────────────────────────────────────────
CONF_FILE="${SCRIPT_DIR}/deploy.conf"

load_conf() {
  local conf="${1:-$CONF_FILE}"

  # Load install.sh state file first — written automatically after install.sh runs.
  # It carries DB_PASSWORD, KEYCLOAK_ADMIN_PASSWORD, ports and versions so you
  # never have to copy them manually. deploy.conf (loaded next) can override any value.
  local install_state="/etc/frs/install.env"
  if [[ -f "$install_state" ]]; then
    set -o allexport
    source "$install_state"
    set +o allexport
    info "Loaded install state from $install_state"
  fi

  if [[ -f "$conf" ]]; then
    info "Loading config: $conf"
    # shellcheck source=/dev/null
    set -o allexport
    source "$conf"
    set +o allexport
  else
    info "No deploy.conf found — using install state + CLI args"
  fi
}

#──────────────────────────────────────────────────────────────────────────────
# PARSE CLI ARGUMENTS  (override conf values)
#──────────────────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)       CONF_FILE="$2";          load_conf "$2"; shift 2 ;;
      --mode)         DEPLOY_MODE="$2";         shift 2 ;;
      --domain)       DOMAIN="$2";              shift 2 ;;
      --ip)           SERVER_IP="$2";           shift 2 ;;
      --app-dir)      APP_DIR="$2";             shift 2 ;;
      --ssl)          DEPLOY_MODE=domain-ssl;   shift   ;;
      --ssl=selfsigned) DEPLOY_MODE=selfsigned; shift   ;;
      --certbot-email) CERTBOT_EMAIL="$2";      shift 2 ;;
      --node-env)     NODE_ENV="$2";            shift 2 ;;
      --auth-mode)    AUTH_MODE="$2";           shift 2 ;;
      --db-host)      DB_HOST="$2";             shift 2 ;;
      --db-port)      DB_PORT="$2";             shift 2 ;;
      --db-name)      DB_NAME="$2";             shift 2 ;;
      --db-user)      DB_USER="$2";             shift 2 ;;
      --db-password)  DB_PASSWORD="$2";         shift 2 ;;
      --kc-admin-user)     KEYCLOAK_ADMIN_USER="$2";     shift 2 ;;
      --kc-admin-password) KEYCLOAK_ADMIN_PASSWORD="$2"; shift 2 ;;
      --kc-port)      KEYCLOAK_HTTP_PORT="$2";  shift 2 ;;
      --kc-realm)     KEYCLOAK_REALM="$2";      shift 2 ;;
      --help|-h)
        echo "Usage: sudo $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --config FILE           Path to deploy.conf (default: ./deploy.conf)"
        echo "  --mode MODE             ip-only|domain-http|domain-ssl|selfsigned|dev"
        echo "  --domain DOMAIN         Domain name (e.g. frs.motivitylabs.com)"
        echo "  --ip IP                 Override auto-detected public IP"
        echo "  --app-dir DIR           Path to Motivity-Face_Recognition_System"
        echo "  --ssl                   Use certbot SSL (sets mode=domain-ssl)"
        echo "  --ssl=selfsigned        Use self-signed TLS cert"
        echo "  --certbot-email EMAIL   Email for Let's Encrypt registration"
        echo "  --node-env ENV          production|development (default: production)"
        echo "  --auth-mode MODE        keycloak|api (default: keycloak)"
        echo "  --db-password PASS      PostgreSQL password"
        echo "  --kc-admin-password P   Keycloak admin password"
        echo ""
        echo "Examples:"
        echo "  sudo $0                                           # IP-only, reads deploy.conf"
        echo "  sudo $0 --domain frs.company.com --ssl           # Production with certbot"
        echo "  sudo $0 --domain frs.local --ssl=selfsigned      # On-prem with self-signed"
        echo "  sudo $0 --mode dev                               # Local dev"
        exit 0
        ;;
      *) warn "Unknown argument: $1 (ignored)"; shift ;;
    esac
  done
}

#──────────────────────────────────────────────────────────────────────────────
# DETECT ENVIRONMENT
#──────────────────────────────────────────────────────────────────────────────

# Tool paths
NODE_BIN=""
NPM_BIN=""
PM2_BIN=""
KC_BIN=""
KC_HOME=""
KC_START_MODE=""   # "dev" or "production"
REAL_USER=""

detect_environment() {
  log "Detecting environment"

  # ── Running user ──────────────────────────────────────────────────────────
  REAL_USER="${SUDO_USER:-${USER:-ubuntu}}"
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "/home/$REAL_USER")
  info "Deploying as: $REAL_USER (home: $REAL_HOME)"

  # ── Node.js ───────────────────────────────────────────────────────────────
  for candidate in /opt/nodejs/bin/node /usr/bin/node /usr/local/bin/node; do
    if [[ -x "$candidate" ]]; then
      NODE_BIN="$candidate"
      NPM_BIN="$(dirname "$NODE_BIN")/npm"
      PM2_BIN="$(dirname "$NODE_BIN")/pm2"
      export PATH="$(dirname "$NODE_BIN"):$PATH"
      break
    fi
  done
  [[ -x "$NODE_BIN" ]] || die "Node.js not found. Run install.sh first."
  ok "Node.js: $($NODE_BIN --version) at $NODE_BIN"

  # ── PM2 ──────────────────────────────────────────────────────────────────
  [[ -x "$PM2_BIN" ]] || PM2_BIN=$(command -v pm2 2>/dev/null || true)
  [[ -n "$PM2_BIN" && -x "$PM2_BIN" ]] || die "PM2 not found. Run: npm install -g pm2"
  ok "PM2: $($PM2_BIN --version) at $PM2_BIN"

  # ── App directory ─────────────────────────────────────────────────────────
  if [[ -z "$APP_DIR" ]]; then
    for candidate in \
        "$(dirname "$SCRIPT_DIR")/Motivity-Face_Recognition_System" \
        "/home/$REAL_USER/FRS/Motivity-Face_Recognition_System" \
        "/home/$REAL_USER/FRS_DEV/Motivity-Face_Recognition_System" \
        "/opt/frs/Motivity-Face_Recognition_System" \
        "/opt/frs"; do
      if [[ -f "$candidate/backend/src/server.js" ]]; then
        APP_DIR="$candidate"
        break
      fi
    done
  fi
  [[ -n "$APP_DIR" && -f "$APP_DIR/backend/src/server.js" ]] \
    || die "Application directory not found. Set APP_DIR in deploy.conf or use --app-dir."
  ok "App directory: $APP_DIR"

  # ── Public / LAN IP ───────────────────────────────────────────────────────
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [[ -z "$SERVER_IP" ]]; then
      SERVER_IP=$(curl -sf --max-time 5 https://ifconfig.me || \
                  curl -sf --max-time 5 https://api.ipify.org || echo "127.0.0.1")
    fi
  fi
  ok "Server IP: $SERVER_IP"

  # ── Keycloak binary ───────────────────────────────────────────────────────
  if [[ -x /opt/keycloak/bin/kc.sh ]]; then
    KC_BIN=/opt/keycloak/bin/kc.sh
    KC_HOME=/opt/keycloak
    KC_START_MODE=production
  else
    # Look for keycloak-native inside the app repo
    local kc_native
    kc_native=$(find "$APP_DIR/keycloak-native" -name "kc.sh" 2>/dev/null | head -1 || true)
    if [[ -n "$kc_native" && -x "$kc_native" ]]; then
      KC_BIN="$kc_native"
      KC_HOME="$(dirname "$(dirname "$kc_native")")"
      KC_START_MODE=dev
    fi
  fi
  if [[ -n "$KC_BIN" ]]; then
    ok "Keycloak: $KC_HOME ($KC_START_MODE mode)"
  else
    warn "Keycloak binary not found — provisioning will still be attempted via REST API"
  fi
}

#──────────────────────────────────────────────────────────────────────────────
# VALIDATE
#──────────────────────────────────────────────────────────────────────────────
validate() {
  log "Validating configuration"

  # Required for all modes
  [[ -n "$DB_PASSWORD" ]]             || die "DB_PASSWORD is required. Set it in deploy.conf or pass --db-password."
  [[ -n "$KEYCLOAK_ADMIN_PASSWORD" ]] || die "KEYCLOAK_ADMIN_PASSWORD is required. Set it in deploy.conf or pass --kc-admin-password."

  # Mode-specific
  case "$DEPLOY_MODE" in
    domain-http|domain-ssl|selfsigned)
      [[ -n "$DOMAIN" ]] || die "DOMAIN is required for DEPLOY_MODE=$DEPLOY_MODE. Set it in deploy.conf or pass --domain."
      ;;
    domain-ssl)
      [[ -n "$CERTBOT_EMAIL" ]] || warn "CERTBOT_EMAIL not set — certbot will prompt interactively."
      ;;
    ip-only|dev) ;;
    *)
      die "Invalid DEPLOY_MODE '$DEPLOY_MODE'. Must be: ip-only | domain-http | domain-ssl | selfsigned | dev"
      ;;
  esac

  # Auth mode
  [[ "$AUTH_MODE" == "keycloak" || "$AUTH_MODE" == "api" || "$AUTH_MODE" == "mock" ]] \
    || die "AUTH_MODE must be keycloak, api, or mock."

  [[ "$AUTH_MODE" == "mock" && "$NODE_ENV" == "production" ]] \
    && die "AUTH_MODE=mock cannot be used with NODE_ENV=production."

  ok "Configuration valid (mode=$DEPLOY_MODE, auth=$AUTH_MODE, env=$NODE_ENV)"
}

#──────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
#──────────────────────────────────────────────────────────────────────────────
preflight() {
  log "Pre-flight: checking infrastructure services"

  local fail=0

  check_service() {
    local name="$1" cmd="$2" required="${3:-true}"
    if eval "$cmd" &>/dev/null; then
      ok "$name is running"
    else
      if [[ "$required" == "true" ]]; then
        warn "$name is NOT running — this is required"
        fail=1
      else
        warn "$name is not running — some features may be unavailable"
      fi
    fi
  }

  check_service "PostgreSQL"  "pg_isready -h $DB_HOST -p $DB_PORT -U $DB_USER -q" true
  # /health/live requires health-enabled=true in keycloak.conf (not on by default in production).
  # Prefer: systemctl active → port open → /realms/master responds.
  check_service "Keycloak"    "systemctl is-active keycloak --quiet 2>/dev/null || nc -z localhost ${KEYCLOAK_HTTP_PORT} 2>/dev/null" true
  check_service "Nginx"       "nginx -t" true
  check_service "Redis"       "redis-cli ping" false
  check_service "Kafka"       "nc -z localhost 9092" false

  if [[ "$DEPLOY_MODE" != "dev" ]]; then
    check_service "face-service (venv)" "test -x /opt/face-service/venv/bin/python" false
  fi

  [[ "$fail" -eq 0 ]] || die "Required services are not running. Run install.sh first, then retry."
}

#──────────────────────────────────────────────────────────────────────────────
# DERIVE URLS  (computed from mode + domain/ip)
#──────────────────────────────────────────────────────────────────────────────

# These are set after parsing so they can be referenced throughout the script
BASE_URL=""
KC_EXTERNAL_URL=""
KEYCLOAK_ISSUER=""
KEYCLOAK_JWKS_URI=""
CLIENT_ORIGIN=""
PUBLIC_BASE_URL=""
APP_URL_VAL=""
ENROLLMENT_PORTAL_URL=""
VITE_API_BASE_URL=""
VITE_KEYCLOAK_URL=""
VITE_APP_BASE_DOMAIN_VAL=""
# Set when nginx should proxy /auth/ to Keycloak (SSL modes only)
KC_NGINX_PROXY=false

derive_urls() {
  log "Deriving URLs for mode: $DEPLOY_MODE"

  case "$DEPLOY_MODE" in
    ip-only)
      BASE_URL="http://${SERVER_IP}"
      KC_EXTERNAL_URL="http://${SERVER_IP}:${KEYCLOAK_HTTP_PORT}"
      KC_NGINX_PROXY=false
      ;;
    domain-http)
      BASE_URL="http://${DOMAIN}"
      KC_EXTERNAL_URL="http://${DOMAIN}:${KEYCLOAK_HTTP_PORT}"
      KC_NGINX_PROXY=false
      ;;
    domain-ssl|selfsigned)
      BASE_URL="https://${DOMAIN}"
      # Keycloak proxied through nginx at /auth/ — keeps everything on port 443
      # and avoids mixed-content errors when the SPA is served over HTTPS.
      KC_EXTERNAL_URL="https://${DOMAIN}/auth"
      KC_NGINX_PROXY=true
      ;;
    dev)
      BASE_URL="http://localhost:${BACKEND_PORT}"
      KC_EXTERNAL_URL="http://localhost:${KEYCLOAK_HTTP_PORT}"
      KC_NGINX_PROXY=false
      ;;
  esac

  KEYCLOAK_ISSUER="${KC_EXTERNAL_URL}/realms/${KEYCLOAK_REALM}"
  KEYCLOAK_JWKS_URI="${KC_EXTERNAL_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"
  CLIENT_ORIGIN="${BASE_URL}"
  PUBLIC_BASE_URL="${BASE_URL}"
  APP_URL_VAL="${BASE_URL}"
  ENROLLMENT_PORTAL_URL="${BASE_URL}/enroll"
  VITE_API_BASE_URL="${BASE_URL}/api"
  VITE_KEYCLOAK_URL="${KC_EXTERNAL_URL}"
  VITE_APP_BASE_DOMAIN_VAL="${DOMAIN:-}"

  info "App URL:       $BASE_URL"
  info "Keycloak URL:  $KC_EXTERNAL_URL"
  info "JWT Issuer:    $KEYCLOAK_ISSUER"
}

#──────────────────────────────────────────────────────────────────────────────
# GENERATE SECRETS  (idempotent — preserves existing values)
#──────────────────────────────────────────────────────────────────────────────
SECRETS_FILE=""

generate_secrets() {
  log "Generating secrets"

  SECRETS_FILE="${APP_DIR}/.deploy-secrets.env"

  # Load existing backend .env to preserve already-generated secrets
  local existing_env="${APP_DIR}/backend/.env"

  _load_existing() {
    local varname="$1"
    local current="${!varname}"
    if [[ -z "$current" && -f "$existing_env" ]]; then
      local found
      found=$(grep -E "^${varname}=" "$existing_env" 2>/dev/null | head -1 | cut -d= -f2- || true)
      if [[ -n "$found" ]]; then
        printf -v "$varname" '%s' "$found"
        info "$varname: preserved from existing .env"
        return 0
      fi
    fi
    return 1
  }

  _gen_or_keep() {
    local varname="$1" label="$2"
    _load_existing "$varname" && return
    if [[ -z "${!varname}" ]]; then
      local val
      val=$(openssl rand -hex 32)
      printf -v "$varname" '%s' "$val"
      info "$label: generated"
    else
      info "$label: using value from config"
    fi
  }

  _gen_or_keep DEVICE_JWT_SECRET        "DEVICE_JWT_SECRET"
  _gen_or_keep ENROLLMENT_TOKEN_SECRET  "ENROLLMENT_TOKEN_SECRET"
  _gen_or_keep METRICS_AUTH_TOKEN       "METRICS_AUTH_TOKEN"
  _gen_or_keep HEALTH_AUTH_TOKEN        "HEALTH_AUTH_TOKEN"
  _gen_or_keep HRMS_WEBHOOK_API_KEY     "HRMS_WEBHOOK_API_KEY"
  _gen_or_keep JETSON_WEBHOOK_SECRET    "JETSON_WEBHOOK_SECRET"

  # Save secrets for operator reference
  cat > "$SECRETS_FILE" <<EOF
# FRS Deployment Secrets — $(date)
# Keep this file secure. Do not commit to version control.
DEVICE_JWT_SECRET=${DEVICE_JWT_SECRET}
ENROLLMENT_TOKEN_SECRET=${ENROLLMENT_TOKEN_SECRET}
METRICS_AUTH_TOKEN=${METRICS_AUTH_TOKEN}
HEALTH_AUTH_TOKEN=${HEALTH_AUTH_TOKEN}
HRMS_WEBHOOK_API_KEY=${HRMS_WEBHOOK_API_KEY}
JETSON_WEBHOOK_SECRET=${JETSON_WEBHOOK_SECRET}
EOF
  chmod 600 "$SECRETS_FILE"
  ok "Secrets saved to: $SECRETS_FILE"
}

#──────────────────────────────────────────────────────────────────────────────
# WRITE backend/.env
#──────────────────────────────────────────────────────────────────────────────
write_backend_env() {
  log "Writing backend/.env"

  local env_file="${APP_DIR}/backend/.env"
  local face_db="${FACE_DB_PATH:-${APP_DIR}/backend/data/faces.db}"
  local model_path="${MODEL_PATH:-${APP_DIR}/backend/models}"
  local remote_enroll_dir="${REMOTE_ENROLLMENT_PHOTO_DIR:-${APP_DIR}/backend/uploads/remote-enrollment}"

  cat > "$env_file" <<EOF
# ─── Generated by deploy-app.sh on $(date) ───────────────────────────────
# Mode: ${DEPLOY_MODE} | Host: ${SERVER_IP} | Domain: ${DOMAIN:-none}

# ── Server ──────────────────────────────────────────────────────────────────
PORT=${BACKEND_PORT}
NODE_ENV=${NODE_ENV}
CLIENT_ORIGIN=${CLIENT_ORIGIN}
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
APP_URL=${APP_URL_VAL}
BACKEND_URL=${PUBLIC_BASE_URL}

# ── Database ─────────────────────────────────────────────────────────────────
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_SSL=${DB_SSL}
DB_SSL_REJECT_UNAUTHORIZED=${DB_SSL_REJECT_UNAUTHORIZED}
DB_POOL_MAX=${DB_POOL_MAX}
DB_IDLE_TIMEOUT_MS=${DB_IDLE_TIMEOUT_MS}
DB_CONNECTION_TIMEOUT_MS=${DB_CONNECTION_TIMEOUT_MS}
DB_KEEPALIVE=${DB_KEEPALIVE}
DB_KEEPALIVE_DELAY_MS=${DB_KEEPALIVE_DELAY_MS}
STATEMENT_TIMEOUT_MS=${STATEMENT_TIMEOUT_MS}

# ── Auth ─────────────────────────────────────────────────────────────────────
AUTH_MODE=${AUTH_MODE}
ACCESS_TOKEN_TTL_MINUTES=30
REFRESH_TOKEN_TTL_DAYS=7

# ── Keycloak ─────────────────────────────────────────────────────────────────
KEYCLOAK_URL=http://localhost:${KEYCLOAK_HTTP_PORT}
KEYCLOAK_REALM=${KEYCLOAK_REALM}
KEYCLOAK_ISSUER=${KEYCLOAK_ISSUER}
KEYCLOAK_AUDIENCE=${KEYCLOAK_API_CLIENT_ID}
KEYCLOAK_JWKS_URI=${KEYCLOAK_JWKS_URI}
KEYCLOAK_CLOCK_TOLERANCE_SEC=${KEYCLOAK_CLOCK_TOLERANCE_SEC}
KEYCLOAK_STRICT_AUDIENCE=${KEYCLOAK_STRICT_AUDIENCE}
KEYCLOAK_ADMIN_USER=${KEYCLOAK_ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}

# ── Secrets ──────────────────────────────────────────────────────────────────
DEVICE_JWT_SECRET=${DEVICE_JWT_SECRET}
ENROLLMENT_TOKEN_SECRET=${ENROLLMENT_TOKEN_SECRET}
METRICS_AUTH_TOKEN=${METRICS_AUTH_TOKEN}
HEALTH_AUTH_TOKEN=${HEALTH_AUTH_TOKEN}
HRMS_WEBHOOK_API_KEY=${HRMS_WEBHOOK_API_KEY}
JETSON_WEBHOOK_SECRET=${JETSON_WEBHOOK_SECRET}
${EMBEDDING_ENCRYPTION_KEY:+EMBEDDING_ENCRYPTION_KEY=${EMBEDDING_ENCRYPTION_KEY}}
EMBEDDING_ENCRYPTION_KEY_ID=${EMBEDDING_ENCRYPTION_KEY_ID}

# ── Redis ────────────────────────────────────────────────────────────────────
REDIS_URL=${REDIS_URL}

# ── Kafka ────────────────────────────────────────────────────────────────────
KAFKA_BROKERS=${KAFKA_BROKERS}
KAFKA_CLIENT_ID=${KAFKA_CLIENT_ID}
KAFKA_GROUP_ID=${KAFKA_GROUP_ID}
KAFKA_TOPIC_PREFIX=${KAFKA_TOPIC_PREFIX}
KAFKA_NUM_PARTITIONS=${KAFKA_NUM_PARTITIONS}
KAFKA_REPLICATION_FACTOR=${KAFKA_REPLICATION_FACTOR}
KAFKA_SSL_ENABLED=${KAFKA_SSL_ENABLED}
${KAFKA_SASL_MECHANISM:+KAFKA_SASL_MECHANISM=${KAFKA_SASL_MECHANISM}}
${KAFKA_SASL_USERNAME:+KAFKA_SASL_USERNAME=${KAFKA_SASL_USERNAME}}
${KAFKA_SASL_PASSWORD:+KAFKA_SASL_PASSWORD=${KAFKA_SASL_PASSWORD}}

# ── SMTP ─────────────────────────────────────────────────────────────────────
${SMTP_USER:+SMTP_SERVICE=${SMTP_SERVICE}}
${SMTP_USER:+SMTP_USER=${SMTP_USER}}
${SMTP_PASSWORD:+SMTP_PASSWORD=${SMTP_PASSWORD}}
${SMTP_HOST:+SMTP_HOST=${SMTP_HOST}}
SMTP_PORT=${SMTP_PORT}
${SMTP_FROM:+SMTP_FROM=${SMTP_FROM}}
SMTP_FROM_NAME=${SMTP_FROM_NAME}
${SMTP_REPLY_TO:+SMTP_REPLY_TO=${SMTP_REPLY_TO}}

# ── Enrollment ───────────────────────────────────────────────────────────────
ENROLLMENT_PORTAL_URL=${ENROLLMENT_PORTAL_URL}
REMOTE_ENROLLMENT_PHOTO_DIR=${remote_enroll_dir}
INVITE_TOKEN_TTL_HOURS=${INVITE_TOKEN_TTL_HOURS}

# ── Face / AI ────────────────────────────────────────────────────────────────
EDGE_AI_URL=http://localhost:${FACE_QUALITY_PORT}
FACE_QUALITY_PORT=${FACE_QUALITY_PORT}
ENABLE_FACE_RECOGNITION=${ENABLE_FACE_RECOGNITION}
ENABLE_ALPR=${ENABLE_ALPR}
ENABLE_REID=${ENABLE_REID}
FACE_MATCH_THRESHOLD=${FACE_MATCH_THRESHOLD}
DEFAULT_FACE_QUALITY_THRESHOLD=${DEFAULT_FACE_QUALITY_THRESHOLD}
FACE_DB_PATH=${face_db}
MODEL_PATH=${model_path}
DUPLICATE_SIMILARITY_BLOCK=${DUPLICATE_SIMILARITY_BLOCK}
DUPLICATE_SIMILARITY_FLAG=${DUPLICATE_SIMILARITY_FLAG}

# ── Jetson / Edge devices ────────────────────────────────────────────────────
JETSON_FORCE_HTTP=${JETSON_FORCE_HTTP}
JETSON_MODEL_VERSION=${JETSON_MODEL_VERSION}
ENFORCE_EVENT_SIGNATURES=${ENFORCE_EVENT_SIGNATURES}
${JETSON_IP_ALLOWLIST:+JETSON_IP_ALLOWLIST=${JETSON_IP_ALLOWLIST}}
${JETSON_EVENT_SECRET:+JETSON_EVENT_SECRET=${JETSON_EVENT_SECRET}}
${JETSON_SIDECAR_URL:+JETSON_SIDECAR_URL=${JETSON_SIDECAR_URL}}
${HEALTH_IP_ALLOWLIST:+HEALTH_IP_ALLOWLIST=${HEALTH_IP_ALLOWLIST}}
${METRICS_IP_ALLOWLIST:+METRICS_IP_ALLOWLIST=${METRICS_IP_ALLOWLIST}}

# ── Alerting ─────────────────────────────────────────────────────────────────
${ALERT_SLACK_WEBHOOK_URL:+ALERT_SLACK_WEBHOOK_URL=${ALERT_SLACK_WEBHOOK_URL}}
ALERT_SLACK_VERBOSE=${ALERT_SLACK_VERBOSE}
${PAGERDUTY_INTEGRATION_KEY:+PAGERDUTY_INTEGRATION_KEY=${PAGERDUTY_INTEGRATION_KEY}}
APP_NAME=${APP_NAME}

# ── Google integrations ──────────────────────────────────────────────────────
${GOOGLE_CALENDAR_API_KEY:+GOOGLE_CALENDAR_API_KEY=${GOOGLE_CALENDAR_API_KEY}}
${COMPANY_CALENDAR_ID:+COMPANY_CALENDAR_ID=${COMPANY_CALENDAR_ID}}
${HOLIDAY_CALENDAR_ID:+HOLIDAY_CALENDAR_ID=${HOLIDAY_CALENDAR_ID}}

# ── Monitoring ───────────────────────────────────────────────────────────────
LOG_LEVEL=${LOG_LEVEL}
${SENTRY_DSN:+SENTRY_DSN=${SENTRY_DSN}}
${MONITORING_URL:+MONITORING_URL=${MONITORING_URL}}

# ── App behaviour ────────────────────────────────────────────────────────────
APP_TIMEZONE=${APP_TIMEZONE}
BIOMETRIC_CONSENT_VERSION=${BIOMETRIC_CONSENT_VERSION}
DEVICE_OFFLINE_THRESHOLD_MIN=${DEVICE_OFFLINE_THRESHOLD_MIN}
DEVICE_TOKEN_TTL_SECONDS=${DEVICE_TOKEN_TTL_SECONDS}

# ── Data retention ───────────────────────────────────────────────────────────
RETENTION_DAYS=${RETENTION_DAYS}
RETENTION_ATTENDANCE_DAYS=${RETENTION_ATTENDANCE_DAYS}
RETENTION_AUDIT_LOG_DAYS=${RETENTION_AUDIT_LOG_DAYS}
RETENTION_DEVICE_EVENTS_DAYS=${RETENTION_DEVICE_EVENTS_DAYS}
RETENTION_GDPR_ERASURE_DAYS=${RETENTION_GDPR_ERASURE_DAYS}
RETENTION_FACE_EMBEDDINGS_YEARS=${RETENTION_FACE_EMBEDDINGS_YEARS}
ATTENDANCE_PING_RETENTION_DAYS=${ATTENDANCE_PING_RETENTION_DAYS}
PHOTO_PURGE_DELAY_HOURS=${PHOTO_PURGE_DELAY_HOURS}
PHOTO_PURGE_INTERVAL_MINUTES=${PHOTO_PURGE_INTERVAL_MINUTES}

# ── Performance ──────────────────────────────────────────────────────────────
FRAME_QUEUE_SIZE=${FRAME_QUEUE_SIZE}
EVENT_QUEUE_SIZE=${EVENT_QUEUE_SIZE}
SNAPSHOT_QUEUE_SIZE=${SNAPSHOT_QUEUE_SIZE}
INFERENCE_THREADS=${INFERENCE_THREADS}
EVENT_PUSH_THREADS=${EVENT_PUSH_THREADS}
MAX_HEAP_MEMORY_PERCENT=${MAX_HEAP_MEMORY_PERCENT}
MOTION_SKIP_FRAMES=${MOTION_SKIP_FRAMES}
SNAPSHOT_UPLOAD_CONCURRENCY=${SNAPSHOT_UPLOAD_CONCURRENCY}
SNAPSHOT_MAX_RETRIES=${SNAPSHOT_MAX_RETRIES}
SNAPSHOT_MAX_TEMP_SIZE_MB=${SNAPSHOT_MAX_TEMP_SIZE_MB}
SNAPSHOT_COMPRESSION_QUALITY=${SNAPSHOT_COMPRESSION_QUALITY}
SNAPSHOT_TEMP_DIR=${APP_DIR}/backend/tmp/snapshots
HTTP_TIMEOUT_MS=${HTTP_TIMEOUT_MS}
HTTP_MAX_RETRIES=${HTTP_MAX_RETRIES}
HTTP_RETRY_DELAY_MS=${HTTP_RETRY_DELAY_MS}
INFRA_CPU_THRESHOLD=${INFRA_CPU_THRESHOLD}
INFRA_MEM_THRESHOLD_MB=${INFRA_MEM_THRESHOLD_MB}

# ── AI drift & bias monitoring ───────────────────────────────────────────────
AI_DRIFT_THRESHOLD=${AI_DRIFT_THRESHOLD}
AI_DRIFT_WINDOW_DAYS=${AI_DRIFT_WINDOW_DAYS}
AI_DRIFT_INTERVAL_MS=${AI_DRIFT_INTERVAL_MS}
BIAS_ACCURACY_THRESHOLD=${BIAS_ACCURACY_THRESHOLD}
BIAS_SAMPLE_PERIOD_DAYS=${BIAS_SAMPLE_PERIOD_DAYS}
EOF

  chmod 640 "$env_file"
  ok "backend/.env written"
}

#──────────────────────────────────────────────────────────────────────────────
# WRITE root .env  (Vite build-time vars)
#──────────────────────────────────────────────────────────────────────────────
write_frontend_env() {
  log "Writing frontend .env (Vite build vars)"

  cat > "${APP_DIR}/.env" <<EOF
# ─── Generated by deploy-app.sh on $(date) ───────────────────────────────
# Vite reads these at BUILD time. Rebuild the frontend after changing them.

VITE_AUTH_MODE=${AUTH_MODE}
VITE_API_BASE_URL=${VITE_API_BASE_URL}
VITE_KEYCLOAK_URL=${VITE_KEYCLOAK_URL}
VITE_KEYCLOAK_REALM=${KEYCLOAK_REALM}
VITE_KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID}
${VITE_APP_BASE_DOMAIN_VAL:+VITE_APP_BASE_DOMAIN=${VITE_APP_BASE_DOMAIN_VAL}}
VITE_IDLE_TIMEOUT_MINUTES=${VITE_IDLE_TIMEOUT_MINUTES}
${VITE_APP_VERSION:+VITE_APP_VERSION=${VITE_APP_VERSION}}
${VITE_SENTRY_DSN:+VITE_SENTRY_DSN=${VITE_SENTRY_DSN}}
EOF

  ok "root .env written"
}

#──────────────────────────────────────────────────────────────────────────────
# SETUP DIRECTORIES & CONF FILES
#──────────────────────────────────────────────────────────────────────────────
setup_dirs() {
  log "Setting up directories"

  # Backend runtime dirs
  mkdir -p "${APP_DIR}/backend/uploads/attendance-photos"
  mkdir -p "${APP_DIR}/backend/uploads/enrollment-photos"
  mkdir -p "${APP_DIR}/backend/uploads/remote-enrollment"
  mkdir -p "${APP_DIR}/backend/tmp/snapshots"
  mkdir -p "${APP_DIR}/backend/data"
  mkdir -p "${APP_DIR}/backend/logs"

  # PM2 / system log dir
  mkdir -p /var/log/frs

  # Ownership — backend runs as REAL_USER
  chown -R "${REAL_USER}:${REAL_USER}" "${APP_DIR}/backend/uploads" \
    "${APP_DIR}/backend/tmp" "${APP_DIR}/backend/data" \
    "${APP_DIR}/backend/logs" /var/log/frs 2>/dev/null || true

  # Ensure conf/ JSON files exist (they're in the repo; warn if missing)
  local conf_dir="${APP_DIR}/backend/conf"
  if [[ ! -f "${conf_dir}/config.json" ]]; then
    warn "backend/conf/config.json missing — creating minimal placeholder"
    mkdir -p "$conf_dir"
    echo '{"name":"frs-backend","version":"1.0.0"}' > "${conf_dir}/config.json"
  fi
  for f in model_config.json rule_config.json smart_search_profiles_config.json; do
    if [[ ! -f "${conf_dir}/${f}" ]]; then
      warn "backend/conf/${f} missing — creating empty placeholder"
      echo '{}' > "${conf_dir}/${f}"
    fi
  done

  ok "Directories ready"
}

#──────────────────────────────────────────────────────────────────────────────
# INSTALL DEPS & BUILD FRONTEND
#──────────────────────────────────────────────────────────────────────────────
install_and_build() {
  log "Installing dependencies and building frontend"

  # Backend deps
  info "Installing backend npm dependencies..."
  cd "${APP_DIR}/backend"
  sudo -u "$REAL_USER" "$NPM_BIN" ci --omit=dev --prefer-offline 2>/dev/null \
    || sudo -u "$REAL_USER" "$NPM_BIN" install --omit=dev
  ok "Backend dependencies installed"

  # Frontend build
  info "Installing frontend npm dependencies..."
  cd "${APP_DIR}"
  sudo -u "$REAL_USER" "$NPM_BIN" ci --prefer-offline 2>/dev/null \
    || sudo -u "$REAL_USER" "$NPM_BIN" install

  info "Building React frontend (Vite)..."
  sudo -u "$REAL_USER" "$NPM_BIN" run build
  ok "Frontend built → ${APP_DIR}/dist"
}

#──────────────────────────────────────────────────────────────────────────────
# DB MIGRATIONS
#──────────────────────────────────────────────────────────────────────────────
run_migrations() {
  log "Running database migrations"

  # Ensure pgvector extension is installed
  sudo -u postgres psql -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || \
    warn "pgvector extension not available — face embedding features will not work. Install with: apt-get install postgresql-16-pgvector"

  sudo -u postgres psql -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" 2>/dev/null || true

  local backend_env="${APP_DIR}/backend/.env"
  [[ -f "$backend_env" ]] || die "backend/.env not found at $backend_env — write_backend_env may have failed."

  # Use --env-file so dotenv.config() in env.js finds the file regardless of
  # what process.cwd() resolves to under sudo -u.
  sudo -u "$REAL_USER" env NODE_ENV="$NODE_ENV" \
    "$NODE_BIN" --env-file "$backend_env" \
    "${APP_DIR}/backend/scripts/migrate.js" \
    && ok "Migrations complete" \
    || die "Database migration failed. Check backend/.env and PostgreSQL connectivity."
}

#──────────────────────────────────────────────────────────────────────────────
# FACE QUALITY SERVICE
#──────────────────────────────────────────────────────────────────────────────
deploy_face_service() {
  [[ "$DEPLOY_MODE" == "dev" ]] && return

  log "Deploying Face Quality Microservice"

  local py_src="${APP_DIR}/backend/scripts/face_quality_service.py"
  local face_dir="/opt/face-service"

  if [[ ! -f "$py_src" ]]; then
    warn "face_quality_service.py not found at $py_src — skipping face service deploy"
    return
  fi

  if [[ ! -d "${face_dir}/venv" ]]; then
    warn "Face service Python venv not found at ${face_dir}/venv"
    warn "Run install.sh first to build the venv, then re-run this script"
    return
  fi

  cp "$py_src" "${face_dir}/app.py"
  chown faceapp:faceapp "${face_dir}/app.py" 2>/dev/null || true

  # Write environment override for face service port
  cat > "${face_dir}/env" <<EOF
FACE_QUALITY_PORT=${FACE_QUALITY_PORT}
EOF
  chown faceapp:faceapp "${face_dir}/env" 2>/dev/null || true

  # Update the systemd unit to pass FACE_QUALITY_PORT if non-default
  if [[ "$FACE_QUALITY_PORT" != "5050" ]]; then
    local svc=/etc/systemd/system/face-service.service
    if [[ -f "$svc" ]]; then
      sed -i "s|ExecStart=.*gunicorn.*|ExecStart=${face_dir}/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:${FACE_QUALITY_PORT} app:app|" "$svc"
    fi
  fi

  systemctl daemon-reload
  systemctl restart face-service && ok "Face service started on :${FACE_QUALITY_PORT}" \
    || warn "Face service failed to start — check: journalctl -u face-service"
}

#──────────────────────────────────────────────────────────────────────────────
# KEYCLOAK PROVISIONING  (idempotent — 409 = already exists → ok)
#──────────────────────────────────────────────────────────────────────────────
wait_for_keycloak() {
  info "Waiting for Keycloak to be ready (up to 90s)..."
  local i=0
  # /realms/master is the most reliable readiness probe — it responds as soon as
  # Keycloak is fully booted regardless of whether health-enabled=true is set.
  until curl -sf --max-time 5 "http://localhost:${KEYCLOAK_HTTP_PORT}/realms/master" &>/dev/null; do
    i=$((i + 1))
    [[ $i -ge 18 ]] && die "Keycloak did not become ready in 90s. Check: journalctl -u keycloak"
    sleep 5
    printf "."
  done
  echo ""
  ok "Keycloak is up"
}

kc_token() {
  local resp
  resp=$(curl -sf \
    -X POST "http://localhost:${KEYCLOAK_HTTP_PORT}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN_USER}&password=${KEYCLOAK_ADMIN_PASSWORD}") \
    || die "Could not get Keycloak admin token. Check KEYCLOAK_ADMIN_USER and KEYCLOAK_ADMIN_PASSWORD."
  python3 -c "import sys,json; print(json.loads('''${resp}''')['access_token'])" 2>/dev/null \
    || die "Could not parse Keycloak admin token response."
}

provision_keycloak() {
  [[ "$AUTH_MODE" != "keycloak" ]] && { info "AUTH_MODE=$AUTH_MODE — skipping Keycloak provisioning"; return; }
  log "Provisioning Keycloak"

  wait_for_keycloak
  local TOKEN
  TOKEN=$(kc_token)
  local KC_BASE="http://localhost:${KEYCLOAK_HTTP_PORT}"

  # ── Configure Keycloak relative path for SSL modes (nginx /auth/ proxy) ──
  if [[ "$KC_NGINX_PROXY" == "true" && -n "$KC_BIN" ]]; then
    info "Configuring Keycloak http-relative-path=/auth for nginx proxy"
    if [[ "$KC_START_MODE" == "production" ]]; then
      local kc_conf="${KC_HOME}/conf/keycloak.conf"
      if ! grep -q "http-relative-path" "$kc_conf" 2>/dev/null; then
        echo "http-relative-path=/auth" >> "$kc_conf"
        info "Running kc.sh build (required after conf change)..."
        sudo -u keycloak "$KC_BIN" build 2>/dev/null \
          || warn "kc.sh build reported issues — Keycloak may not serve at /auth/"
      fi
    elif [[ "$KC_START_MODE" == "dev" ]]; then
      # In start-dev mode, update the systemd ExecStart to include the flag
      local svc_file="/etc/systemd/system/keycloak.service"
      if [[ -f "$svc_file" ]] && ! grep -q "http-relative-path" "$svc_file"; then
        sed -i 's|\(ExecStart=.*kc\.sh start-dev\)|\1 --http-relative-path=/auth|' "$svc_file"
        systemctl daemon-reload
      fi
    fi
    systemctl restart keycloak 2>/dev/null || true
    sleep 8
    TOKEN=$(kc_token)  # refresh token after restart
  fi

  # ── Create realm ─────────────────────────────────────────────────────────
  local realm_status
  realm_status=$(curl -so /dev/null -w "%{http_code}" \
    -X GET "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}" \
    -H "Authorization: Bearer ${TOKEN}")

  if [[ "$realm_status" == "200" ]]; then
    ok "Realm '${KEYCLOAK_REALM}' already exists — skipping creation"
  else
    info "Creating realm '${KEYCLOAK_REALM}'..."
    local status
    status=$(curl -so /dev/null -w "%{http_code}" \
      -X POST "${KC_BASE}/admin/realms" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"id\": \"${KEYCLOAK_REALM}\",
        \"realm\": \"${KEYCLOAK_REALM}\",
        \"displayName\": \"FRS Attendance\",
        \"enabled\": true,
        \"resetPasswordAllowed\": true,
        \"loginWithEmailAllowed\": true,
        \"bruteForceProtected\": true,
        \"failureFactor\": 10,
        \"organizationsEnabled\": true
      }")
    [[ "$status" == "201" || "$status" == "204" ]] \
      || die "Failed to create Keycloak realm (HTTP $status)"
    ok "Realm '${KEYCLOAK_REALM}' created"
  fi

  # Refresh token after realm ops
  TOKEN=$(kc_token)

  # ── Create attendance-frontend client (public, PKCE) ──────────────────────
  info "Provisioning client '${KEYCLOAK_CLIENT_ID}'..."
  local wildcard_origin="${BASE_URL}/*"
  local fstatus
  fstatus=$(curl -so /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"${KEYCLOAK_CLIENT_ID}\",
      \"name\": \"FRS Attendance Frontend\",
      \"enabled\": true,
      \"publicClient\": true,
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": true,
      \"redirectUris\": [\"${BASE_URL}/*\", \"http://localhost:5173/*\"],
      \"webOrigins\": [\"${BASE_URL}\", \"http://localhost:5173\"],
      \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
    }")
  [[ "$fstatus" == "201" || "$fstatus" == "204" || "$fstatus" == "409" ]] \
    || die "Failed to create frontend client (HTTP $fstatus)"
  [[ "$fstatus" == "409" ]] && info "Client '${KEYCLOAK_CLIENT_ID}' already exists" \
    || ok "Client '${KEYCLOAK_CLIENT_ID}' created"

  # ── Create attendance-api client (bearer-only) ────────────────────────────
  info "Provisioning client '${KEYCLOAK_API_CLIENT_ID}'..."
  local astatus
  astatus=$(curl -so /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"${KEYCLOAK_API_CLIENT_ID}\",
      \"name\": \"FRS API\",
      \"enabled\": true,
      \"bearerOnly\": true,
      \"publicClient\": false
    }")
  [[ "$astatus" == "201" || "$astatus" == "204" || "$astatus" == "409" ]] \
    || die "Failed to create API client (HTTP $astatus)"
  [[ "$astatus" == "409" ]] && info "Client '${KEYCLOAK_API_CLIENT_ID}' already exists" \
    || ok "Client '${KEYCLOAK_API_CLIENT_ID}' created"

  # ── Seed realm roles ──────────────────────────────────────────────────────
  info "Seeding realm roles..."
  for role in super_admin tenant_admin site_admin hr_manager viewer device_operator; do
    local rstatus
    rstatus=$(curl -so /dev/null -w "%{http_code}" \
      -X POST "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/roles" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${role}\"}")
    [[ "$rstatus" == "201" || "$rstatus" == "409" ]] \
      || warn "Could not seed role '${role}' (HTTP $rstatus)"
  done
  ok "Realm roles seeded"

  # ── Create first super-admin user ─────────────────────────────────────────
  if [[ -n "$SUPER_ADMIN_EMAIL" && -n "$SUPER_ADMIN_PASSWORD" ]]; then
    info "Creating super-admin user: ${SUPER_ADMIN_EMAIL}..."

    # Refresh token before user operations
    TOKEN=$(kc_token)

    # Create user
    local ustatus
    ustatus=$(curl -so /dev/null -w "%{http_code}" \
      -X POST "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/users" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"${SUPER_ADMIN_USERNAME}\",
        \"email\": \"${SUPER_ADMIN_EMAIL}\",
        \"enabled\": true,
        \"emailVerified\": true
      }")

    if [[ "$ustatus" == "409" ]]; then
      ok "Super-admin '${SUPER_ADMIN_EMAIL}' already exists — skipping"
    elif [[ "$ustatus" == "201" ]]; then
      # Get the new user's ID
      local user_id
      user_id=$(curl -sf \
        "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/users?email=${SUPER_ADMIN_EMAIL}" \
        -H "Authorization: Bearer ${TOKEN}" \
        | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id']) if users else exit(1)" 2>/dev/null) \
        || die "Could not retrieve ID for newly created super-admin user."

      # Set password (non-temporary so user isn't forced to change on first login)
      curl -sf \
        -X PUT "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/users/${user_id}/reset-password" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\": \"password\", \"value\": \"${SUPER_ADMIN_PASSWORD}\", \"temporary\": false}" \
        || die "Could not set password for super-admin user."

      # Assign super_admin realm role
      local role_json
      role_json=$(curl -sf \
        "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/roles/super_admin" \
        -H "Authorization: Bearer ${TOKEN}") \
        || die "Could not fetch super_admin role definition."

      curl -sf \
        -X POST "${KC_BASE}/admin/realms/${KEYCLOAK_REALM}/users/${user_id}/role-mappings/realm" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "[${role_json}]" \
        || die "Could not assign super_admin role to user."

      ok "Super-admin created: ${SUPER_ADMIN_EMAIL} (role: super_admin)"
    else
      warn "Could not create super-admin user (HTTP $ustatus) — create it manually in Keycloak admin"
    fi
  else
    warn "SUPER_ADMIN_EMAIL or SUPER_ADMIN_PASSWORD not set — skipping user creation"
    warn "Create the first user manually at: http://localhost:${KEYCLOAK_HTTP_PORT}/admin"
  fi

  ok "Keycloak provisioning complete"
}

#──────────────────────────────────────────────────────────────────────────────
# KAFKA TOPICS
#──────────────────────────────────────────────────────────────────────────────
create_kafka_topics() {
  log "Creating Kafka topics"

  if ! nc -z localhost 9092 2>/dev/null; then
    warn "Kafka is not reachable on localhost:9092 — skipping topic creation"
    warn "Topics will auto-create when the backend first publishes to them"
    return
  fi

  local backend_env="${APP_DIR}/backend/.env"
  # Force NODE_ENV=development: KafkaConfig enforces SSL in production,
  # but install.sh provides a plain (no-SSL) single-node Kafka.
  sudo -u "$REAL_USER" env NODE_ENV=development KAFKA_SSL_ENABLED=false \
    "$NODE_BIN" --env-file "$backend_env" \
    "${APP_DIR}/backend/scripts/create-topics.js" \
    && ok "Kafka topics created/verified" \
    || warn "Kafka topic creation failed — topics will auto-create on first use"
}

#──────────────────────────────────────────────────────────────────────────────
# NGINX CONFIG
#──────────────────────────────────────────────────────────────────────────────

# Shared proxy location blocks (same across all modes)
_nginx_proxy_blocks() {
  local kc_port="$KEYCLOAK_HTTP_PORT"
  cat <<LOCATIONS

    # ── API proxy ──────────────────────────────────────────────────────────
    location ^~ /api/ {
        proxy_pass         http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        client_max_body_size 10M;
    }

    # ── WebSocket (Socket.IO) ──────────────────────────────────────────────
    location /socket.io/ {
        proxy_pass         http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       \$host;
        proxy_read_timeout 86400s;
    }

    # ── Uploads ───────────────────────────────────────────────────────────
    location ^~ /uploads/ {
        proxy_pass         http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host    \$host;
        proxy_read_timeout 30s;
        client_max_body_size 10M;
    }

    # ── Keycloak proxy (only used in SSL modes) ───────────────────────────
    location ^~ /auth/ {
        proxy_pass             http://127.0.0.1:${kc_port}/auth/;
        proxy_http_version     1.1;
        proxy_set_header       Host                \$host;
        proxy_set_header       X-Forwarded-Proto   \$scheme;
        proxy_set_header       X-Forwarded-Host    \$host;
        proxy_set_header       X-Forwarded-Port    \$server_port;
        proxy_set_header       X-Forwarded-For     \$proxy_add_x_forwarded_for;
        proxy_buffer_size      128k;
        proxy_buffers          4 256k;
        proxy_busy_buffers_size 256k;
    }

    # ── SPA fallback ──────────────────────────────────────────────────────
    location / {
        try_files \$uri \$uri/ /index.html;
    }
LOCATIONS
}

_nginx_static_blocks() {
  cat <<STATIC
    root  ${APP_DIR}/dist;
    index index.html;

    # Security headers
    add_header X-Frame-Options          "SAMEORIGIN"                   always;
    add_header X-Content-Type-Options   "nosniff"                      always;
    add_header X-XSS-Protection         "1; mode=block"                always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied    any;
    gzip_types text/plain text/css text/xml application/json
               application/javascript application/xml+rss font/woff2
               font/truetype font/opentype image/svg+xml;

    # Long-lived cache for versioned assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header X-Frame-Options        "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff"    always;
        access_log off;
    }

    # Never cache index.html — ensures users get the latest SPA shell
    location = /index.html {
        expires -1;
        add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0";
        add_header X-Frame-Options        "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff"    always;
    }
STATIC
}

generate_nginx_conf() {
  local server_name="${1:-_}"
  local mode="$2"

  case "$mode" in
    http)
      cat <<NGINX
server {
    listen ${NGINX_HTTP_PORT} default_server;
    server_name ${server_name};

$(_nginx_static_blocks)
$(_nginx_proxy_blocks)
}
NGINX
      ;;

    https-certbot)
      # Before certbot runs, serve HTTP so ACME challenge works.
      # Certbot will rewrite this file to add the SSL server block.
      cat <<NGINX
server {
    listen ${NGINX_HTTP_PORT};
    server_name ${server_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_HTTPS_PORT} ssl;
    server_name ${server_name};

    ssl_certificate     /etc/letsencrypt/live/${server_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${server_name}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

$(_nginx_static_blocks)
$(_nginx_proxy_blocks)
}
NGINX
      ;;

    https-selfsigned)
      local cert_dir="/etc/ssl/frs"
      cat <<NGINX
server {
    listen ${NGINX_HTTP_PORT};
    server_name ${server_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${NGINX_HTTPS_PORT} ssl;
    server_name ${server_name};

    ssl_certificate     ${cert_dir}/frs.crt;
    ssl_certificate_key ${cert_dir}/frs.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    ssl_prefer_server_ciphers on;

$(_nginx_static_blocks)
$(_nginx_proxy_blocks)
}
NGINX
      ;;
  esac
}

configure_nginx() {
  [[ "$DEPLOY_MODE" == "dev" ]] && { info "Dev mode — skipping nginx configuration"; return; }
  log "Configuring nginx"

  # Verify the frontend was built before writing a config that points at it
  [[ -f "${APP_DIR}/dist/index.html" ]] \
    || die "Frontend dist/index.html not found. Run install_and_build first."

  local nginx_conf_dest use_sites_dir=false
  if [[ -d /etc/nginx/sites-available ]]; then
    nginx_conf_dest=/etc/nginx/sites-available/frs
    use_sites_dir=true
  else
    nginx_conf_dest=/etc/nginx/conf.d/frs.conf
  fi

  local server_name="${DOMAIN:-_}"

  # Write the config file first, then enable/link it
  case "$DEPLOY_MODE" in
    ip-only|domain-http)
      generate_nginx_conf "$server_name" "http" > "$nginx_conf_dest"
      ;;
    domain-ssl)
      # Serve plain HTTP initially so certbot can complete the ACME challenge.
      # setup_ssl() rewrites this to the full HTTPS config after cert issuance.
      generate_nginx_conf "$server_name" "http" > "$nginx_conf_dest"
      ;;
    selfsigned)
      generate_nginx_conf "$server_name" "https-selfsigned" > "$nginx_conf_dest"
      ;;
  esac

  # Enable the site (must happen after the file is written)
  if [[ "$use_sites_dir" == "true" ]]; then
    rm -f /etc/nginx/sites-enabled/default        # remove default page
    ln -sfn "$nginx_conf_dest" /etc/nginx/sites-enabled/frs
    info "Enabled: sites-enabled/frs → $nginx_conf_dest"
  else
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
  fi

  nginx -t || die "nginx config test failed — check $nginx_conf_dest"
  systemctl reload nginx
  ok "nginx configured and reloaded → serving from ${APP_DIR}/dist"
}

#──────────────────────────────────────────────────────────────────────────────
# SSL SETUP
#──────────────────────────────────────────────────────────────────────────────
setup_ssl() {
  case "$DEPLOY_MODE" in
    ip-only|domain-http|dev)
      return ;;
  esac

  log "Setting up TLS"

  if [[ "$DEPLOY_MODE" == "selfsigned" ]]; then
    local cert_dir="/etc/ssl/frs"
    mkdir -p "$cert_dir"
    if [[ ! -f "${cert_dir}/frs.crt" ]]; then
      info "Generating self-signed certificate for ${DOMAIN}..."
      openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${cert_dir}/frs.key" \
        -out    "${cert_dir}/frs.crt" \
        -subj   "/CN=${DOMAIN}/O=FRS/C=IN" \
        -addext "subjectAltName=DNS:${DOMAIN},IP:${SERVER_IP}" 2>/dev/null
      chmod 600 "${cert_dir}/frs.key"
      ok "Self-signed certificate generated (valid 10 years)"
    else
      ok "Self-signed certificate already exists — keeping it"
    fi

    # Write the final https-selfsigned nginx config now that cert exists
    local nginx_conf_dest
    [[ -d /etc/nginx/sites-available ]] \
      && nginx_conf_dest=/etc/nginx/sites-available/frs \
      || nginx_conf_dest=/etc/nginx/conf.d/frs.conf
    generate_nginx_conf "$DOMAIN" "https-selfsigned" > "$nginx_conf_dest"
    nginx -t && systemctl reload nginx
    ok "nginx reloaded with TLS config"
    return
  fi

  # domain-ssl: certbot
  if ! command -v certbot &>/dev/null && [[ ! -x /opt/certbot/bin/certbot ]]; then
    warn "certbot not found — falling back to self-signed certificate"
    DEPLOY_MODE=selfsigned
    setup_ssl
    return
  fi

  local certbot_bin
  certbot_bin=$(command -v certbot 2>/dev/null || echo /opt/certbot/bin/certbot)

  local certbot_args=(--nginx -d "$DOMAIN" --non-interactive --agree-tos)
  [[ -n "$CERTBOT_EMAIL" ]] && certbot_args+=(--email "$CERTBOT_EMAIL") \
    || certbot_args+=(--register-unsafely-without-email)

  info "Running certbot for ${DOMAIN}..."
  if "$certbot_bin" "${certbot_args[@]}"; then
    ok "SSL certificate obtained via certbot"

    # Certbot rewrites the nginx conf — now write the full HTTPS config
    local nginx_conf_dest
    [[ -d /etc/nginx/sites-available ]] \
      && nginx_conf_dest=/etc/nginx/sites-available/frs \
      || nginx_conf_dest=/etc/nginx/conf.d/frs.conf
    generate_nginx_conf "$DOMAIN" "https-certbot" > "$nginx_conf_dest"
    nginx -t && systemctl reload nginx
    ok "nginx reloaded with certbot TLS"
  else
    warn "certbot failed (is ${DOMAIN} pointing to this server's IP?)"
    warn "Falling back to self-signed certificate"
    DEPLOY_MODE=selfsigned
    setup_ssl
  fi
}

#──────────────────────────────────────────────────────────────────────────────
# PM2  (Node backend process manager)
#──────────────────────────────────────────────────────────────────────────────
start_pm2() {
  [[ "$DEPLOY_MODE" == "dev" ]] && { info "Dev mode — skipping PM2 (run: npm run dev in backend/)"; return; }
  log "Starting backend with PM2"

  # Run all PM2 commands as the real user (not root)
  local pm2_env="PATH=$(dirname "$NODE_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  sudo -u "$REAL_USER" env $pm2_env \
    "$PM2_BIN" delete frs-backend 2>/dev/null || true

  sudo -u "$REAL_USER" env $pm2_env \
    "$PM2_BIN" start "${APP_DIR}/backend/src/server.js" \
      --name        "frs-backend" \
      --cwd         "${APP_DIR}/backend" \
      --node-args   "--env-file ${APP_DIR}/backend/.env" \
      --output      "/var/log/frs/backend-out.log" \
      --error       "/var/log/frs/backend-err.log" \
      --time \
    || die "PM2 failed to start frs-backend — check /var/log/frs/backend-err.log"

  sudo -u "$REAL_USER" env $pm2_env "$PM2_BIN" save

  # Install PM2 systemd startup unit (runs as REAL_USER on boot)
  env PATH="$(dirname "$NODE_BIN"):$PATH" \
    "$PM2_BIN" startup systemd -u "$REAL_USER" --hp "$REAL_HOME" 2>/dev/null \
    | grep -E "^sudo" | bash 2>/dev/null || true

  ok "PM2 frs-backend started and saved"
}

#──────────────────────────────────────────────────────────────────────────────
# HEALTH CHECK
#──────────────────────────────────────────────────────────────────────────────
health_check() {
  log "Running health checks"

  local all_ok=true

  wait_http() {
    local url="$1" label="$2" max="${3:-30}"
    local i=0
    until curl -sf "$url" &>/dev/null; do
      i=$((i + 1))
      [[ $i -ge $((max / 2)) ]] && { warn "$label not responding after ${max}s"; return 1; }
      sleep 2
    done
    ok "$label: OK"
  }

  if [[ "$DEPLOY_MODE" == "dev" ]]; then
    wait_http "http://localhost:${BACKEND_PORT}/api/health" "Backend (dev)" || all_ok=false
  else
    wait_http "${BASE_URL}/api/health" "Backend via nginx" || all_ok=false
    wait_http "http://localhost:${KEYCLOAK_HTTP_PORT}/realms/${KEYCLOAK_REALM}" "Keycloak realm" || all_ok=false
  fi

  "$all_ok" && ok "All health checks passed" \
    || warn "Some health checks failed — see $DEPLOY_LOG for details"
}

#──────────────────────────────────────────────────────────────────────────────
# SUMMARY
#──────────────────────────────────────────────────────────────────────────────
print_summary() {
  local kc_admin_url
  if [[ "$KC_NGINX_PROXY" == "true" ]]; then
    kc_admin_url="${BASE_URL}/auth/admin"
  else
    kc_admin_url="http://${SERVER_IP}:${KEYCLOAK_HTTP_PORT}/admin"
  fi

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║       FRS Deployment Complete                        ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Application:${NC}   ${CYAN}${BASE_URL}${NC}"
  echo -e "  ${BOLD}Backend API:${NC}   ${CYAN}${BASE_URL}/api/health${NC}"
  echo -e "  ${BOLD}Keycloak:${NC}      ${CYAN}${kc_admin_url}${NC}"
  echo ""
  echo -e "  ${BOLD}DB Name:${NC}       ${DB_NAME} @ ${DB_HOST}:${DB_PORT}"
  echo -e "  ${BOLD}KC Realm:${NC}      ${KEYCLOAK_REALM}"
  echo -e "  ${BOLD}Auth Mode:${NC}     ${AUTH_MODE}"
  echo -e "  ${BOLD}Deploy Mode:${NC}   ${DEPLOY_MODE}"
  echo ""
  echo -e "  ${BOLD}Secrets file:${NC}  ${SECRETS_FILE:-not written}"
  echo -e "  ${BOLD}Deploy log:${NC}    ${DEPLOY_LOG}"
  echo ""

  if [[ "$DEPLOY_MODE" == "ip-only" ]]; then
    echo -e "  ${YELLOW}[!]${NC}  IP-only mode: ensure port ${NGINX_HTTP_PORT} is open in your firewall/security group."
    echo -e "  ${YELLOW}[!]${NC}  Keycloak port ${KEYCLOAK_HTTP_PORT} must also be accessible to browsers."
  elif [[ "$DEPLOY_MODE" == "domain-ssl" || "$DEPLOY_MODE" == "selfsigned" ]]; then
    echo -e "  ${YELLOW}[!]${NC}  Ensure port ${NGINX_HTTPS_PORT} is open. Port ${NGINX_HTTP_PORT} is kept open for HTTP→HTTPS redirect."
  fi

  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"
  echo -e "    1. Open ${CYAN}${kc_admin_url}${NC} and create your first admin user"
  echo -e "    2. Log in at ${CYAN}${BASE_URL}${NC}"
  if [[ "$DEPLOY_MODE" == "domain-ssl" ]]; then
    echo -e "    3. Certbot auto-renewal: verify with  certbot renew --dry-run"
  fi
  echo ""
}

#──────────────────────────────────────────────────────────────────────────────
# MAIN
#──────────────────────────────────────────────────────────────────────────────
main() {
  banner "FRS Application Deployer"
  # Start tee logging only after --help check (parse_args exits for --help)
  exec > >(tee -a "$DEPLOY_LOG") 2>&1
  echo -e "  ${CYAN}Log file:${NC} $DEPLOY_LOG"

  # Load conf then parse args (args override conf)
  load_conf
  parse_args "$@"

  # Check root (required for nginx, systemd, etc. — except in dev mode)
  if [[ "$DEPLOY_MODE" != "dev" && $EUID -ne 0 ]]; then
    die "Run as root (use sudo). Dev mode is the only mode that doesn't require root."
  fi

  detect_environment
  validate
  preflight
  derive_urls
  generate_secrets
  write_backend_env
  write_frontend_env
  setup_dirs
  install_and_build
  run_migrations
  deploy_face_service
  provision_keycloak
  create_kafka_topics
  configure_nginx
  setup_ssl
  start_pm2
  health_check
  print_summary
}

main "$@"
