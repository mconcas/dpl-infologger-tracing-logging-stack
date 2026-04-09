#!/bin/bash
set -euo pipefail

ADMINDB=/opt/o2-InfoLogger/bin/o2-infologger-admindb
SERVER=/opt/o2-InfoLogger/bin/o2-infologger-server
CFG=/etc/o2.d/infologger/infoLogger.cfg

# ── Write configuration from environment variables ───────────────────────────
cat > "${CFG}" <<EOF
[infoLoggerServer]
dbHost=${DB_HOST:-mariadb}
dbUser=${DB_SERVER_USER:-infoLoggerServer}
dbPassword=${DB_SERVER_PASS:-ilgserver}
dbName=${DB_NAME:-INFOLOGGER}

[admin]
dbHost=${DB_HOST:-mariadb}
dbUser=${DB_ADMIN_USER:-infoLoggerAdmin}
dbPassword=${DB_ADMIN_PASS:-ilgadmin}
dbName=${DB_NAME:-INFOLOGGER}

[infoBrowser]
dbHost=${DB_HOST:-mariadb}
dbUser=${DB_BROWSER_USER:-infoBrowser}
dbPassword=${DB_BROWSER_PASS:-ilgbrowser}
dbName=${DB_NAME:-INFOLOGGER}

[infoLoggerD]
serverHost=localhost
serverPort=6006

[client]
EOF

# ── Wait for MariaDB to accept connections ────────────────────────────────────
echo "Waiting for MariaDB at ${DB_HOST:-mariadb}:${DB_PORT:-3306}..."
until "${ADMINDB}" -z "${CFG}" -c status >/dev/null 2>&1 \
   || mariadb --host="${DB_HOST:-mariadb}" \
              --user="${DB_ADMIN_USER:-infoLoggerAdmin}" \
              --password="${DB_ADMIN_PASS:-ilgadmin}" \
              --execute="SELECT 1" \
              "${DB_NAME:-INFOLOGGER}" >/dev/null 2>&1; do
    sleep 2
done
echo "MariaDB is up."

# ── Create the messages table (idempotent: safe to run on every start) ────────
echo "Initialising InfoLogger schema..."
"${ADMINDB}" -z "${CFG}" -c create 2>&1 | grep -v "already exists" || true
echo "Schema ready."

# ── Start infoLoggerServer in the foreground ──────────────────────────────────
exec "${SERVER}" -z "file:${CFG}" -o isInteractive=1
