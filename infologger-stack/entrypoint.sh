#!/bin/bash
set -euo pipefail

ADMINDB=/opt/o2-InfoLogger/bin/o2-infologger-admindb
DAEMON=/opt/o2-InfoLogger/bin/o2-infologger-daemon
SERVER=/opt/o2-InfoLogger/bin/o2-infologger-server
CFG=/etc/o2.d/infologger/infoLogger.cfg

# Write configuration from environment variables
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
rxSocketPath=/tmp/infologger-socket/infologgerD.sock

[client]
txSocketPath=/tmp/infologger-socket/infologgerD.sock
EOF

# Wait for MariaDB to accept connections
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

# Create the messages table (idempotent: safe to run on every start)
echo "Initialising InfoLogger schema..."
"${ADMINDB}" -z "${CFG}" -c create 2>&1 | grep -v "already exists" || true

# Migrate existing schema: add traceid/spanid columns if missing
echo "Checking for traceid/spanid columns..."
mariadb --host="${DB_HOST:-mariadb}" \
        --user="${DB_ADMIN_USER:-infoLoggerAdmin}" \
        --password="${DB_ADMIN_PASS:-ilgadmin}" \
        "${DB_NAME:-INFOLOGGER}" \
        -e "ALTER TABLE messages ADD COLUMN IF NOT EXISTS traceid varchar(32) DEFAULT NULL AFTER errsource, ADD COLUMN IF NOT EXISTS spanid varchar(16) DEFAULT NULL AFTER traceid;" \
        2>/dev/null || true
echo "Schema ready."

# Start infoLoggerD (and create file socket) in the background
echo "Removing infologgerD socket if already present"
rm -rf /tmp/infologger-socket/infologgerD.sock
"${DAEMON}" -z "file:${CFG}" &
sleep 1

# start the bridge to fluent-bit
echo "Starting infologger bridge to local socket"
sed -i 's|"/tmp/syslog.sock"|"/tmp/fluent-bit-socket/syslog.sock"|' /opt/o2-InfoLogger/bin/o2-infologger-bridge

/opt/o2-InfoLogger/bin/o2-infologger-bridge &
echo "done"

chmod 777 /tmp/infologger-socket/infologgerD.sock

# Forward signals to all children so they shut down cleanly
trap 'kill $(jobs -p) 2>/dev/null; wait' TERM INT

# Start infoLoggerServer in the background (shell stays PID 1 to reap children)
"${SERVER}" -z "file:${CFG}" -o isInteractive=1 &
wait $!
