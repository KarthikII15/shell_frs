# FRS Deployment Manual
## Motivity Face Recognition System — Complete Deployment Guide

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Deployment Workflow](#4-deployment-workflow)
5. [Step 1 — Infrastructure Setup (`install.sh`)](#5-step-1--infrastructure-setup)
6. [Step 2 — Configuring `deploy.conf`](#6-step-2--configuring-deployconf)
7. [Step 3 — Application Deployment (`deploy-app.sh`)](#7-step-3--application-deployment)
8. [Deployment Scenarios](#8-deployment-scenarios)
9. [Post-Deployment: First Login & Admin Setup](#9-post-deployment-first-login--admin-setup)
10. [Service Management](#10-service-management)
11. [Log Locations](#11-log-locations)
12. [Updating the Application](#12-updating-the-application)
13. [Troubleshooting](#13-troubleshooting)
14. [Security Hardening](#14-security-hardening)
15. [Port Reference](#15-port-reference)
16. [File & Directory Reference](#16-file--directory-reference)

---

## 1. System Overview

The Motivity Face Recognition System (FRS) is a full-stack attendance and access management platform. It captures face recognition events from edge devices (Nvidia Jetson cameras), processes them through an event pipeline, and provides a web dashboard for attendance reports, employee management, and device administration.

### Components

| Component | Role |
|-----------|------|
| **React SPA** | Web dashboard served by nginx |
| **Node.js Backend** | Express API on port 8080, manages all business logic |
| **PostgreSQL 16** | Primary database with pgvector for face embeddings |
| **Keycloak 26** | Identity provider — handles login, SSO, multi-tenancy |
| **Kafka (KRaft)** | Event bus for camera events, detections, and alerts |
| **Redis** | Distributed rate limiting and session caching |
| **Face Quality Service** | Python/Flask microservice on port 5050 — scores enrollment photos |
| **Nginx** | Reverse proxy — routes `/api/`, `/socket.io/`, `/uploads/`, `/auth/` |

### Deployment Folder Structure

```
FRS/
├── Frs-Sh/                          ← All deployment files live here
│   ├── install.sh                   ← Step 1: Install infrastructure
│   ├── deploy.conf                  ← Step 2: Fill this in
│   ├── deploy-app.sh                ← Step 3: Deploy the application
│   ├── DEPLOYMENT_MANUAL.md         ← This file
│   ├── kafka_2.13-3.7.0.tgz         ← Offline: Kafka archive
│   ├── keycloak-26.6.0.tar.gz       ← Offline: Keycloak archive
│   ├── node-v20.20.2.tar.xz         ← Offline: Node.js archive
│   └── python.tar.gz                ← Offline: Python 3.12 archive
│
└── Motivity-Face_Recognition_System/ ← The application codebase
    ├── backend/                      ← Node.js API
    ├── src/                          ← React frontend
    ├── dist/                         ← Built frontend (created by deploy-app.sh)
    └── nginx.conf                    ← Reference nginx config (replaced by deploy-app.sh)
```

---

## 2. Architecture

```
                    ┌─────────────────────────────────┐
                    │           Internet / LAN         │
                    └────────────┬────────────────────┘
                                 │
                          ┌──────▼──────┐
                          │    Nginx    │  :80 / :443
                          │  (Reverse   │
                          │   Proxy)    │
                          └──┬──┬──┬───┘
               ┌─────────────┘  │  └──────────────┐
               │                │                 │
        /api/, /uploads/   /socket.io/         /auth/
        /static assets      (WebSocket)       (optional)
               │                │                 │
        ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐
        │  Node.js    │  │  Socket.IO  │  │  Keycloak   │
        │  Backend    │  │  (same      │  │   :9090     │
        │   :8080     │  │   process)  │  │             │
        └──┬──┬──┬────┘  └─────────────┘  └─────────────┘
           │  │  │
    ┌──────┘  │  └───────────┐
    │         │              │
┌───▼───┐ ┌──▼────┐  ┌──────▼──────┐
│Postgres│ │ Redis │  │    Kafka    │
│  :5432 │ │ :6379 │  │    :9092    │
└────────┘ └───────┘  └──────┬──────┘
                             │
                    ┌────────▼──────┐
                    │ Face Quality  │
                    │  Service :5050│
                    └───────────────┘
                             │
                    ┌────────▼──────┐
                    │Jetson Cameras │
                    │ (Edge devices)│
                    └───────────────┘
```

### Data Flow

1. Jetson camera detects a face → sends event to backend via HTTPS
2. Backend publishes to Kafka topic `scanalitix.events`
3. Kafka consumer processes the event → marks attendance in PostgreSQL
4. Frontend polls via REST API or receives real-time updates via Socket.IO
5. Reports and dashboards read from PostgreSQL

---

## 3. Prerequisites

### Server Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB |
| Disk | 50 GB SSD | 100 GB SSD |
| Architecture | x86_64 | x86_64 |

> **Jetson devices** (edge cameras) run separately and connect to this server. They are not covered in this manual.

### Network Requirements

| Port | Service | Who needs access |
|------|---------|-----------------|
| 22 | SSH | Administrators only |
| 80 | HTTP (nginx) | All users |
| 443 | HTTPS (nginx) | All users (SSL modes) |
| 9090 | Keycloak | All users (non-SSL modes), or internal only (SSL modes) |
| 9092 | Kafka | Internal only (not exposed to internet) |
| 5432 | PostgreSQL | Internal only |
| 6379 | Redis | Internal only |
| 5050 | Face quality service | Internal only |
| 8080 | Node.js backend | Internal only (nginx proxies it) |

### What You Need Before Starting

- Root/sudo access to the server
- The application code at `FRS/Motivity-Face_Recognition_System/`
- The deployment files at `FRS/Frs-Sh/`
- A domain name (optional — IP-only mode works without one)
- Your desired passwords for PostgreSQL and Keycloak admin

---

## 4. Deployment Workflow

The complete deployment is exactly two steps:

```
┌─────────────────────────────────────────────────────────────┐
│  STEP 1                                                     │
│  sudo ./Frs-Sh/install.sh                                   │
│                                                             │
│  Installs: Java 21, Node 20, Python 3.12, PostgreSQL 16,   │
│  Redis, Nginx, Certbot, Keycloak 26, Kafka 3.7             │
│  Time: 5–15 minutes (depends on internet/offline mode)     │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 2                                                     │
│  Edit Frs-Sh/deploy.conf  (fill in passwords & mode)       │
│  sudo ./Frs-Sh/deploy-app.sh                                │
│                                                             │
│  Builds app, writes .env files, runs DB migrations,        │
│  provisions Keycloak, creates Kafka topics, configures     │
│  nginx, sets up PM2, runs health checks.                   │
│  Time: 3–8 minutes                                         │
└─────────────────────────────────────────────────────────────┘
```

**Important:** You must run `install.sh` successfully before running `deploy-app.sh`. If `install.sh` was already run on this server previously, you can skip it and go straight to Step 2.

---

## 5. Step 1 — Infrastructure Setup

### Running `install.sh`

```bash
cd /home/ubuntu/FRS/Frs-Sh

# Provide passwords via environment variables
sudo KEYCLOAK_ADMIN_PASSWORD='your-strong-kc-password' \
     DB_PASSWORD='your-strong-db-password' \
     ./install.sh
```

> **Passwords set here must match what you put in `deploy.conf` later.** Write them down securely.

### What `install.sh` Does

The script is idempotent — running it twice is safe. It checks before each install step.

| Step | What it installs | Where |
|------|-----------------|-------|
| Base packages | curl, tar, build-essential, acl | apt |
| Java 21 | OpenJDK 21 headless | apt |
| Node.js 20.20.2 | From local `.tar.xz` or nodejs.org | `/opt/nodejs/` |
| pnpm 7 + PM2 7 | Global npm packages | `/opt/nodejs/bin/` |
| Python 3.12 | From local `python.tar.gz` | `/opt/python3.12/` |
| PostgreSQL 16 | PGDG apt repo | system |
| Redis | apt | system |
| Nginx 1.30 | Official nginx apt repo | system |
| Certbot | Python venv | `/opt/certbot/` |
| Keycloak 26.6 | From local `.tar.gz` | `/opt/keycloak/` |
| Kafka 3.7 (KRaft) | From local `.tgz` | `/opt/kafka/` |
| Face service venv | Python venv + pip | `/opt/face-service/venv/` |

### Offline vs Online

The `Frs-Sh/` folder contains pre-downloaded archives:
- `kafka_2.13-3.7.0.tgz` — Kafka
- `keycloak-26.6.0.tar.gz` — Keycloak
- `node-v20.20.2.tar.xz` — Node.js
- `python.tar.gz` — Python 3.12

If the archive exists in `Frs-Sh/`, `install.sh` uses it instead of downloading. This makes the install work fully offline.

### Verifying install.sh Succeeded

After `install.sh` finishes, verify all services are running:

```bash
# All of these should show "active (running)"
systemctl status postgresql
systemctl status keycloak
systemctl status kafka
systemctl status redis-server
systemctl status nginx
```

If any service failed to start:

```bash
# Check the logs for the failing service
journalctl -u keycloak -n 50
journalctl -u kafka -n 50
```

---

## 6. Step 2 — Configuring `deploy.conf`

Open `Frs-Sh/deploy.conf` in a text editor and fill in the values for your environment.

### Minimum Required Changes

You **must** set these four values. Everything else has sensible defaults.

```bash
# In Frs-Sh/deploy.conf:

# 1. Choose your deployment mode (see Section 8 for full explanation)
DEPLOY_MODE=ip-only       # or: domain-http, domain-ssl, selfsigned, dev

# 2. Your domain name (required for domain-* and selfsigned modes)
DOMAIN=frs.yourcompany.com

# 3. Must match the DB_PASSWORD you set during install.sh
DB_PASSWORD=your-strong-db-password

# 4. Must match the KEYCLOAK_ADMIN_PASSWORD you set during install.sh
KEYCLOAK_ADMIN_PASSWORD=your-strong-kc-password
```

### Common Optional Settings

```bash
# Your timezone (affects attendance calculations and cron jobs)
APP_TIMEZONE=Asia/Kolkata        # or: America/New_York, Europe/London, UTC

# Email for certbot SSL registration (required when DEPLOY_MODE=domain-ssl)
CERTBOT_EMAIL=admin@yourcompany.com

# SMTP for email invitations and password resets
SMTP_SERVICE=gmail
SMTP_USER=noreply@yourcompany.com
SMTP_PASSWORD=your-app-password

# Slack alerts for system issues
ALERT_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/HOOK/URL
```

### Auto-Generated Secrets

These are **safe to leave blank**. `deploy-app.sh` generates secure random values and saves them to `.deploy-secrets.env` in the application directory:

```bash
DEVICE_JWT_SECRET=         # leave blank → auto-generated
ENROLLMENT_TOKEN_SECRET=   # leave blank → auto-generated
METRICS_AUTH_TOKEN=        # leave blank → auto-generated
HEALTH_AUTH_TOKEN=         # leave blank → auto-generated
HRMS_WEBHOOK_API_KEY=      # leave blank → auto-generated
JETSON_WEBHOOK_SECRET=     # leave blank → auto-generated
```

> **Re-deploy note:** On re-deployment, these are read from the existing `backend/.env` and preserved automatically. They are never regenerated unless you delete `backend/.env`.

### Keycloak Settings

The default Keycloak configuration works for most deployments. Only change these if you have a specific reason:

```bash
KEYCLOAK_HTTP_PORT=9090         # port Keycloak runs on
KEYCLOAK_REALM=attendance       # realm name for the application
KEYCLOAK_CLIENT_ID=attendance-frontend   # frontend client ID
KEYCLOAK_API_CLIENT_ID=attendance-api    # API client ID
```

### deploy.conf Section Reference

| Section | Variables | When to configure |
|---------|-----------|------------------|
| Deployment Mode | `DEPLOY_MODE`, `DOMAIN`, `SERVER_IP`, `NODE_ENV`, `AUTH_MODE` | Always |
| Database | `DB_*` | Always |
| Keycloak | `KEYCLOAK_*` | When changing from defaults |
| App Secrets | `DEVICE_JWT_SECRET` etc. | Leave blank (auto-generated) |
| Redis | `REDIS_URL` | When using remote Redis |
| Kafka | `KAFKA_*` | When using remote/secured Kafka |
| SMTP | `SMTP_*` | For email features |
| Alerting | `ALERT_SLACK_*`, `PAGERDUTY_*` | For operational alerts |
| Jetson / Edge | `JETSON_*` | When connecting cameras |
| Face & AI | `ENABLE_FACE_RECOGNITION` etc. | When models are available |
| Google | `GOOGLE_CALENDAR_API_KEY` etc. | For holiday calendar integration |
| Monitoring | `SENTRY_DSN`, `LOG_LEVEL` | For error tracking |
| App Behaviour | `APP_TIMEZONE`, `INVITE_TOKEN_TTL_HOURS` etc. | Fine-tuning |
| Data Retention | `RETENTION_*` | Compliance requirements |
| Performance | `FRAME_QUEUE_SIZE`, `DB_POOL_MAX` etc. | High-load tuning |

---

## 7. Step 3 — Application Deployment

### Running `deploy-app.sh`

```bash
cd /home/ubuntu/FRS/Frs-Sh

# Reads deploy.conf automatically from the same directory
sudo ./deploy-app.sh
```

Or pass values directly on the command line (overrides `deploy.conf`):

```bash
sudo ./deploy-app.sh \
  --domain frs.yourcompany.com \
  --ssl \
  --db-password 'your-db-pass' \
  --kc-admin-password 'your-kc-pass'
```

### What `deploy-app.sh` Does

```
Phase 1  detect_environment   Find Node, PM2, app directory, server IP, Keycloak binary
Phase 2  validate             Check required values are set; abort with clear error if not
Phase 3  preflight            Verify PostgreSQL, Keycloak, nginx are running
Phase 4  derive_urls          Calculate BASE_URL, KC_EXTERNAL_URL, KEYCLOAK_ISSUER from mode
Phase 5  generate_secrets     Auto-generate 6 secrets; preserve existing ones on re-deploy
Phase 6  write_backend_env    Write backend/.env (~60 variables)
Phase 7  write_frontend_env   Write root .env (Vite build-time variables)
Phase 8  setup_dirs           Create uploads/, tmp/, data/ directories; check conf/ JSON files
Phase 9  install_and_build    npm ci (backend) + npm ci && npm run build (frontend)
Phase 10 run_migrations       Run DB migrations (idempotent — skips if schema exists)
Phase 11 deploy_face_service  Copy face_quality_service.py → /opt/face-service/app.py; restart
Phase 12 provision_keycloak   Create realm, 2 clients, 6 roles via REST API (idempotent)
Phase 13 create_kafka_topics  Create 10 Kafka topics (runs in dev mode to bypass SSL enforcement)
Phase 14 configure_nginx      Generate and deploy nginx config for the selected mode
Phase 15 setup_ssl            Run certbot OR generate self-signed cert (SSL modes only)
Phase 16 start_pm2            Start frs-backend under PM2 as ubuntu user; install systemd unit
Phase 17 health_check         Poll /api/health and Keycloak until they respond
Phase 18 print_summary        Print URLs, credentials file location, next steps
```

### Deployment Output

A successful deployment ends with a summary like this:

```
╔══════════════════════════════════════════════════════╗
║       FRS Deployment Complete                        ║
╚══════════════════════════════════════════════════════╝

  Application:   https://frs.yourcompany.com
  Backend API:   https://frs.yourcompany.com/api/health
  Keycloak:      https://frs.yourcompany.com/auth/admin

  DB Name:       FRS @ localhost:5432
  KC Realm:      attendance
  Auth Mode:     keycloak
  Deploy Mode:   domain-ssl

  Secrets file:  /home/ubuntu/FRS/Motivity-Face_Recognition_System/.deploy-secrets.env
  Deploy log:    /tmp/frs-deploy-20260627-120000.log
```

---

## 8. Deployment Scenarios

### Scenario A — IP-Only (Quickest Start)

Use when: new cloud instance, no domain configured yet, or internal testing.

**In `deploy.conf`:**
```bash
DEPLOY_MODE=ip-only
# DOMAIN=         ← leave blank
DB_PASSWORD=your-db-password
KEYCLOAK_ADMIN_PASSWORD=your-kc-password
```

**Run:**
```bash
sudo ./deploy-app.sh
```

**Result:**
- App served at `http://<your-server-ip>`
- Keycloak admin at `http://<your-server-ip>:9090/admin`
- No SSL — suitable for internal networks or initial testing

**Firewall:** Open ports `80` and `9090` in your cloud security group or `ufw`.

---

### Scenario B — Domain with HTTP (Internal / On-Premises)

Use when: you have an internal hostname (e.g. `frs.company.local`) but no public SSL certificate.

**In `deploy.conf`:**
```bash
DEPLOY_MODE=domain-http
DOMAIN=frs.company.local
DB_PASSWORD=your-db-password
KEYCLOAK_ADMIN_PASSWORD=your-kc-password
```

**Run:**
```bash
sudo ./deploy-app.sh
```

**Result:**
- App at `http://frs.company.local`
- Keycloak admin at `http://frs.company.local:9090/admin`
- Make sure your internal DNS resolves `frs.company.local` to the server IP

---

### Scenario C — Production with Certbot SSL

Use when: you have a public domain with DNS pointing to your server and want Let's Encrypt certificates.

**Prerequisites:**
- DNS A record: `frs.yourcompany.com` → your server's public IP
- Port 80 open (certbot needs it for the ACME challenge)
- Port 443 open

**In `deploy.conf`:**
```bash
DEPLOY_MODE=domain-ssl
DOMAIN=frs.yourcompany.com
CERTBOT_EMAIL=admin@yourcompany.com
DB_PASSWORD=your-db-password
KEYCLOAK_ADMIN_PASSWORD=your-kc-password
```

**Run:**
```bash
sudo ./deploy-app.sh
```

**Result:**
- App at `https://frs.yourcompany.com`
- Keycloak proxied through nginx at `https://frs.yourcompany.com/auth`
- SSL certificate auto-renews via certbot systemd timer

**Verify SSL auto-renewal works:**
```bash
sudo certbot renew --dry-run
```

---

### Scenario D — On-Premises with Self-Signed TLS

Use when: you need HTTPS on an internal server without a public DNS or Let's Encrypt.

**In `deploy.conf`:**
```bash
DEPLOY_MODE=selfsigned
DOMAIN=frs.company.local        # or an IP address
DB_PASSWORD=your-db-password
KEYCLOAK_ADMIN_PASSWORD=your-kc-password
```

**Run:**
```bash
sudo ./deploy-app.sh
```

**Result:**
- App at `https://frs.company.local`
- Self-signed certificate valid for 10 years at `/etc/ssl/frs/`
- Browser will show a security warning — click "Advanced → Proceed" or install the cert in your browser/OS trust store

**Install the self-signed cert in Chrome/Firefox (optional):**
```bash
# Copy the cert to a share so users can install it
scp /etc/ssl/frs/frs.crt user@workstation:~/frs-ca.crt
# In Chrome: Settings → Privacy → Certificates → Import frs-ca.crt
```

---

### Scenario E — Local Development

Use when: a developer wants to run the full stack locally without nginx/PM2/SSL.

**In `deploy.conf`:**
```bash
DEPLOY_MODE=dev
AUTH_MODE=api           # skip Keycloak for faster local iteration
NODE_ENV=development
DB_PASSWORD=postgres    # whatever your local postgres uses
KEYCLOAK_ADMIN_PASSWORD=admin
```

**Run (no sudo needed):**
```bash
./deploy-app.sh --mode dev
```

**Result:**
- Backend starts via PM2 on `http://localhost:8080`
- Frontend must be started separately: `npm run dev` (serves on `http://localhost:5173`)
- nginx is not configured

---

### Scenario F — Re-Deploy (Code Update)

Use when: you have pushed new code to the server and need to rebuild and restart.

Re-running `deploy-app.sh` is fully safe — it is idempotent:
- Secrets are preserved from existing `backend/.env`
- DB migrations are skipped (schema already applied)
- Keycloak realm/clients return `409 Already Exists` → treated as success
- Kafka topics are skipped if they already exist
- nginx config is regenerated and reloaded (not restarted)

```bash
# Pull new code first
cd /home/ubuntu/FRS/Motivity-Face_Recognition_System
git pull origin main

# Then re-deploy
cd /home/ubuntu/FRS/Frs-Sh
sudo ./deploy-app.sh
```

For a faster code-only update (skips Keycloak, Kafka, face-service):

```bash
cd /home/ubuntu/FRS/Motivity-Face_Recognition_System

# Rebuild frontend
npm ci && npm run build

# Restart backend
pm2 restart frs-backend

# Reload nginx (picks up new static files)
sudo nginx -s reload
```

---

## 9. Post-Deployment: First Login & Admin Setup

### Step 1 — Open Keycloak Admin Console

Navigate to the Keycloak admin console:

| Mode | URL |
|------|-----|
| ip-only / domain-http | `http://<IP-or-domain>:9090/admin` |
| domain-ssl / selfsigned | `https://<domain>/auth/admin` |

Log in with:
- **Username:** value of `KEYCLOAK_ADMIN_USER` (default: `admin`)
- **Password:** value of `KEYCLOAK_ADMIN_PASSWORD`

### Step 2 — Verify the Realm

In the top-left dropdown, you should see the `attendance` realm (or whatever `KEYCLOAK_REALM` was set to). Click on it to switch to that realm.

### Step 3 — Create Your First Application User

In Keycloak → `attendance` realm → **Users** → **Add user**:

1. Set **Username** and **Email**
2. Click **Save**
3. Go to the **Credentials** tab → Set a password → Turn off "Temporary"
4. Go to the **Role Mapping** tab → Assign realm role `super_admin`

### Step 4 — Log Into the Application

Navigate to the application URL (e.g. `https://frs.yourcompany.com`).

- You will be redirected to Keycloak for login
- Enter the credentials you just created
- On first login, you will be prompted to set up your organization (tenant)

### Step 5 — Create Your First Tenant

After logging in as `super_admin`, go to **Admin → Organizations → Create**.

This creates a Keycloak organization and the corresponding database records for your company.

### Step 6 — Configure Keycloak Email (for password resets)

If you configured SMTP in `deploy.conf`, Keycloak should already have email configured via the realm settings. Verify it:

Keycloak Admin → `attendance` realm → **Realm Settings** → **Email** tab

If the fields are blank, fill them in manually or re-run `deploy-app.sh` with SMTP vars set.

---

## 10. Service Management

### View All Running Services

```bash
# Application processes (PM2)
pm2 list

# Infrastructure services (systemd)
systemctl status postgresql keycloak kafka redis-server nginx face-service
```

### Backend (PM2)

```bash
# View status
pm2 list

# View live logs
pm2 logs frs-backend

# View last 100 log lines
pm2 logs frs-backend --lines 100

# Restart backend (after config change)
pm2 restart frs-backend

# Stop backend
pm2 stop frs-backend

# Start backend
pm2 start frs-backend
```

### Nginx

```bash
# Test config before applying
sudo nginx -t

# Reload config (no downtime)
sudo nginx -s reload

# Restart nginx
sudo systemctl restart nginx
```

### Keycloak

```bash
sudo systemctl restart keycloak
sudo systemctl stop keycloak
sudo systemctl start keycloak
journalctl -u keycloak -f          # live logs
```

### Kafka

```bash
sudo systemctl restart kafka
journalctl -u kafka -f             # live logs

# List topics
/opt/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092

# Describe a topic
/opt/kafka/bin/kafka-topics.sh --describe \
  --topic scanalitix.events \
  --bootstrap-server localhost:9092
```

### PostgreSQL

```bash
sudo systemctl restart postgresql

# Connect to the FRS database
sudo -u postgres psql -d FRS

# Useful queries
\dt                                -- list all tables
SELECT count(*) FROM frs_user;     -- count users
SELECT count(*) FROM attendance_event; -- count events
```

### Redis

```bash
sudo systemctl restart redis-server
redis-cli ping          # should return: PONG
redis-cli info          # server info and stats
```

### Face Quality Service

```bash
pm2 restart face-quality-svc       # if managed by PM2
# or
sudo systemctl restart face-service  # if managed by systemd

# Test it directly
curl http://localhost:5050/health
```

---

## 11. Log Locations

| Component | Log location | Command |
|-----------|-------------|---------|
| Backend (stdout) | `/var/log/frs/backend-out.log` | `tail -f /var/log/frs/backend-out.log` |
| Backend (errors) | `/var/log/frs/backend-err.log` | `tail -f /var/log/frs/backend-err.log` |
| Backend (PM2) | `~/.pm2/logs/frs-backend-*.log` | `pm2 logs frs-backend` |
| Nginx access | `/var/log/nginx/access.log` | `tail -f /var/log/nginx/access.log` |
| Nginx errors | `/var/log/nginx/error.log` | `tail -f /var/log/nginx/error.log` |
| Keycloak | systemd journal | `journalctl -u keycloak -f` |
| Kafka | systemd journal | `journalctl -u kafka -f` |
| PostgreSQL | `/var/log/postgresql/` | `tail -f /var/log/postgresql/*.log` |
| Redis | `/var/log/redis/redis-server.log` | `tail -f /var/log/redis/redis-server.log` |
| Face service | systemd journal | `journalctl -u face-service -f` |
| Deploy script | `/tmp/frs-deploy-<timestamp>.log` | Printed at end of deploy |

### Changing Log Level

In `deploy.conf`:
```bash
LOG_LEVEL=debug    # debug | info | warn | error
```

Then re-deploy or just update `backend/.env` and restart:
```bash
# Edit backend/.env and change LOG_LEVEL=debug
pm2 restart frs-backend
```

---

## 12. Updating the Application

### Full Re-Deploy (Config + Code Changed)

```bash
# 1. Pull latest code
cd /home/ubuntu/FRS/Motivity-Face_Recognition_System
git pull origin main

# 2. Update deploy.conf if needed
nano /home/ubuntu/FRS/Frs-Sh/deploy.conf

# 3. Re-deploy (idempotent — safe to run again)
cd /home/ubuntu/FRS/Frs-Sh
sudo ./deploy-app.sh
```

### Quick Code-Only Update (No Config Changes)

```bash
cd /home/ubuntu/FRS/Motivity-Face_Recognition_System

# Pull new code
git pull origin main

# Rebuild frontend
npm ci && npm run build

# Update backend dependencies if package.json changed
cd backend && npm ci --omit=dev && cd ..

# Restart backend
pm2 restart frs-backend

# Reload nginx (serves new frontend assets)
sudo nginx -s reload
```

### Updating Infrastructure (install.sh)

If a new version of `install.sh` is released with updated component versions, run it again. It will only install/upgrade what has changed:

```bash
sudo KEYCLOAK_ADMIN_PASSWORD='...' DB_PASSWORD='...' ./install.sh
```

### Rotating Secrets

If you need to rotate a secret (e.g., `DEVICE_JWT_SECRET`):

1. Generate a new value: `openssl rand -hex 32`
2. Update it in `backend/.env` directly
3. Also update `.deploy-secrets.env`
4. Restart the backend: `pm2 restart frs-backend`

> **Warning:** Rotating `DEVICE_JWT_SECRET` invalidates all existing device tokens. Jetson cameras will need to be re-registered.

---

## 13. Troubleshooting

### Backend Won't Start

```bash
pm2 logs frs-backend --lines 50
```

**Common causes:**

| Error in logs | Fix |
|--------------|-----|
| `[FATAL] DEVICE_JWT_SECRET is required` | Set `DEVICE_JWT_SECRET` in `backend/.env` or `deploy.conf` |
| `[FATAL] ENROLLMENT_TOKEN_SECRET is required` | Same — run `deploy-app.sh` to auto-generate |
| `Connection refused 5432` | PostgreSQL not running: `sudo systemctl start postgresql` |
| `Cannot connect to Kafka` | Kafka not running: `sudo systemctl start kafka` |
| `Missing required environment variables: DB_HOST` | `backend/.env` is missing or malformed — re-run `deploy-app.sh` |

### Keycloak Login Fails

**Symptom:** Clicking login redirects to Keycloak but credentials don't work.

```bash
# Check Keycloak is up
curl http://localhost:9090/health/live

# Check the realm exists
curl http://localhost:9090/realms/attendance
```

**If realm doesn't exist**, re-run the provisioning step:
```bash
sudo ./deploy-app.sh    # provision_keycloak will recreate it
```

**If admin password is wrong**, reset it:
```bash
sudo -u keycloak /opt/keycloak/bin/kc.sh show-config | grep admin
# Then update KEYCLOAK_ADMIN_PASSWORD in deploy.conf and in the systemd unit
```

### JWT Token Errors (401 on API calls)

**Symptom:** Frontend logs in via Keycloak but API calls return 401.

This usually means the `KEYCLOAK_ISSUER` in `backend/.env` doesn't match the issuer in the JWT token.

```bash
# Check what issuer is in backend/.env
grep KEYCLOAK_ISSUER /home/ubuntu/FRS/Motivity-Face_Recognition_System/backend/.env

# Check what issuer Keycloak is actually putting in tokens
# Log in via the frontend, open browser DevTools → Application → Local Storage
# Find the Keycloak token, decode it at jwt.io and check the "iss" field
```

The `iss` field in the JWT must exactly match `KEYCLOAK_ISSUER`. If they differ, update `deploy.conf` with the correct URL and re-run `deploy-app.sh`.

### Nginx Returns 502 Bad Gateway

The backend is not running or not responding on port 8080.

```bash
# Check if backend is running
pm2 list

# Check if port 8080 is listening
ss -tlnp | grep 8080

# Start backend if stopped
pm2 start frs-backend

# Check logs for startup errors
pm2 logs frs-backend --lines 30
```

### Nginx Config Test Fails

```bash
sudo nginx -t
```

If this fails, `deploy-app.sh` has already shown the error. Common causes:
- The `dist/` directory doesn't exist (frontend wasn't built) — re-run `deploy-app.sh`
- SSL certificate paths are wrong (certbot failed) — use `--ssl=selfsigned` as fallback

### Database Migration Failed

```bash
cd /home/ubuntu/FRS/Motivity-Face_Recognition_System/backend
node scripts/migrate.js
```

**Common causes:**

| Error | Fix |
|-------|-----|
| `Extension "vector" does not exist` | Install pgvector: `apt-get install postgresql-16-pgvector` |
| `role "postgres" does not exist` | PostgreSQL user setup failed — re-run `install.sh` |
| `database "FRS" does not exist` | DB not created — re-run `install.sh` |
| `password authentication failed` | `DB_PASSWORD` in `backend/.env` doesn't match PostgreSQL |

### Kafka Topics Missing

The backend logs will show Kafka connection errors. Topics auto-create on first message, but you can also create them manually:

```bash
cd /home/ubuntu/FRS/Motivity-Face_Recognition_System/backend
NODE_ENV=development node scripts/create-topics.js
```

### SSL Certificate Expired or Failed

```bash
# Check certificate expiry
sudo certbot certificates

# Renew manually
sudo certbot renew

# If certbot fails, fall back to self-signed
sudo ./deploy-app.sh --domain frs.yourcompany.com --ssl=selfsigned
```

### Face Quality Service Not Working

```bash
# Check it's running
curl http://localhost:5050/health

# Restart it
pm2 restart face-quality-svc
# or
sudo systemctl restart face-service

# Check logs
pm2 logs face-quality-svc
journalctl -u face-service -n 50
```

### Port Already in Use

```bash
# Find what's using a port (e.g. 9090)
ss -tlnp | grep 9090
# or
lsof -i :9090
```

### Check All Services at Once

```bash
echo "=== PM2 ===" && pm2 list
echo "=== PostgreSQL ===" && pg_isready -h localhost -p 5432
echo "=== Keycloak ===" && curl -sf http://localhost:9090/health/live && echo OK
echo "=== Nginx ===" && nginx -t
echo "=== Kafka ===" && nc -z localhost 9092 && echo OK || echo "NOT RUNNING"
echo "=== Redis ===" && redis-cli ping
echo "=== Face Svc ===" && curl -sf http://localhost:5050/health
echo "=== Backend ===" && curl -sf http://localhost:8080/api/health
```

---

## 14. Security Hardening

### After First Deployment (Do These Immediately)

1. **Change default Keycloak admin password** if you used a weak one during setup.

2. **Restrict port 9090** (Keycloak) to internal access only if using SSL mode (nginx proxies it):
   ```bash
   sudo ufw deny 9090
   sudo ufw allow from 127.0.0.1 to any port 9090
   ```

3. **Protect health/metrics endpoints** — set tokens in `deploy.conf`:
   ```bash
   HEALTH_AUTH_TOKEN=your-health-token
   METRICS_AUTH_TOKEN=your-metrics-token
   ```
   Then access with: `curl -H "Authorization: Bearer your-token" https://domain/api/health`

4. **Enable embedding encryption** for face data at rest:
   ```bash
   EMBEDDING_ENCRYPTION_KEY=$(openssl rand -hex 32)   # in deploy.conf
   ```
   > Set this before first enrollment. Cannot be changed after face data exists.

5. **Enable event signature enforcement** for Jetson webhooks:
   ```bash
   ENFORCE_EVENT_SIGNATURES=true
   JETSON_WEBHOOK_SECRET=your-shared-secret   # must match Jetson config
   ```

6. **Whitelist Jetson IP addresses**:
   ```bash
   JETSON_IP_ALLOWLIST=192.168.1.50,192.168.1.51
   ```

7. **Set up firewall rules**:
   ```bash
   sudo ufw allow 22/tcp    # SSH
   sudo ufw allow 80/tcp    # HTTP
   sudo ufw allow 443/tcp   # HTTPS
   sudo ufw enable
   # Close all other ports by default
   ```

### Secrets File

The auto-generated secrets are saved to:
```
/home/ubuntu/FRS/Motivity-Face_Recognition_System/.deploy-secrets.env
```

This file has `chmod 600`. Keep it secure:
- Add it to `.gitignore` (it already is)
- Back it up to a password manager or secrets vault
- Never commit it to version control

---

## 15. Port Reference

| Port | Service | Accessible From | Notes |
|------|---------|----------------|-------|
| `80` | Nginx HTTP | Public | HTTP → HTTPS redirect in SSL modes |
| `443` | Nginx HTTPS | Public | Main app entry point (SSL modes) |
| `8080` | Node.js backend | Internal only | Proxied by nginx at `/api/` |
| `9090` | Keycloak | Public (non-SSL) or Internal (SSL) | Admin UI + OIDC endpoints |
| `9092` | Kafka | Internal only | Event bus |
| `9093` | Kafka (KRaft controller) | Internal only | Cluster coordination |
| `5432` | PostgreSQL | Internal only | Primary database |
| `6379` | Redis | Internal only | Rate limiting, session cache |
| `5050` | Face quality service | Internal only | Enrollment photo scoring |

---

## 16. File & Directory Reference

### Deployment Files

| Path | Purpose |
|------|---------|
| `Frs-Sh/install.sh` | Infrastructure installer |
| `Frs-Sh/deploy.conf` | Your deployment configuration |
| `Frs-Sh/deploy-app.sh` | Application deployer |
| `Frs-Sh/DEPLOYMENT_MANUAL.md` | This file |

### Application Files (Written by `deploy-app.sh`)

| Path | Purpose |
|------|---------|
| `backend/.env` | Backend environment (all ~60 vars) |
| `.env` | Frontend build vars (Vite reads at build time) |
| `.deploy-secrets.env` | Auto-generated secrets — keep secure |
| `/tmp/frs-deploy-*.log` | Deploy log from most recent run |

### Runtime Directories

| Path | Purpose |
|------|---------|
| `backend/uploads/attendance-photos/` | Attendance event photos |
| `backend/uploads/enrollment-photos/` | Employee enrollment photos |
| `backend/uploads/remote-enrollment/` | Photos from Jetson cameras |
| `backend/tmp/snapshots/` | Temporary snapshot processing |
| `backend/data/faces.db` | SQLite face embedding index |
| `backend/conf/` | Runtime config JSON files (rules, models, search profiles) |
| `/var/log/frs/` | PM2 backend logs |
| `/opt/face-service/` | Python face quality service |
| `/opt/keycloak/` | Keycloak installation |
| `/opt/kafka/` | Kafka installation |
| `/opt/nodejs/` | Node.js installation |

### nginx Config

| Path | Purpose |
|------|---------|
| `/etc/nginx/sites-available/frs` | Generated nginx config |
| `/etc/nginx/sites-enabled/frs` | Symlink to active config |
| `/etc/ssl/frs/frs.crt` | Self-signed certificate (selfsigned mode) |
| `/etc/letsencrypt/live/<domain>/` | Certbot certificates (domain-ssl mode) |

---

## Quick Reference Card

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 FRS QUICK REFERENCE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DEPLOY (first time):
  sudo KEYCLOAK_ADMIN_PASSWORD='...' DB_PASSWORD='...' ./install.sh
  nano deploy.conf          ← set passwords + DEPLOY_MODE
  sudo ./deploy-app.sh

RE-DEPLOY (code update):
  git pull origin main
  sudo ./deploy-app.sh

BACKEND LOGS:
  pm2 logs frs-backend
  tail -f /var/log/frs/backend-err.log

RESTART BACKEND:
  pm2 restart frs-backend

RESTART NGINX:
  sudo nginx -s reload

STATUS CHECK:
  pm2 list
  systemctl status keycloak kafka postgresql nginx

HEALTH CHECK:
  curl http://localhost:8080/api/health
  curl http://localhost:9090/health/live
  curl http://localhost:5050/health

SECRETS FILE:
  cat /home/ubuntu/FRS/Motivity-Face_Recognition_System/.deploy-secrets.env
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
