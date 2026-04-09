# infologger-stack

Container image for the InfoLogger server (v2.10.1) + companion MariaDB init
script, built on UBI9 (RHEL9).

Intended to be included as a service in `../observability-bootstrap`; the
two stacks are wired together via a shared Docker network.

## Architecture

```
DPL processes (host)
  └─► infoLoggerD (host daemon, UNIX socket /tmp/infoLoggerD.socket)
           └─► infologger-server:6006   (push — infoLoggerD → server)

o2-infologger-bridge (host script)
  └─► infologger-server:6102            (subscribe — bridge reads live stream)
           └─► /tmp/syslog.sock → Fluent Bit → OTel Collector → OpenSearch
```

## Building the image

```bash
cd infologger-stack
docker build -t infologger-server:v2.10.1 ./server
```

## Using in observability-bootstrap

Add to `observability-bootstrap/docker-compose.yml`:

```yaml
services:
  mariadb:
    image: mariadb:11
    environment:
      MARIADB_ROOT_PASSWORD: rootpass
      MARIADB_DATABASE: INFOLOGGER
    volumes:
      - mariadb-data:/var/lib/mysql
      - ./infologger/init.sh:/docker-entrypoint-initdb.d/init.sh:ro
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 20

  infologger-server:
    image: infologger-server:v2.10.1
    depends_on:
      mariadb:
        condition: service_healthy
    ports:
      - "6006:6006"
      - "6102:6102"
    environment:
      DB_HOST: mariadb
      DB_NAME: INFOLOGGER
      DB_SERVER_USER: infoLoggerServer
      DB_SERVER_PASS: ilgserver
      DB_ADMIN_USER: infoLoggerAdmin
      DB_ADMIN_PASS: ilgadmin
      DB_BROWSER_USER: infoBrowser
      DB_BROWSER_PASS: ilgbrowser
    restart: unless-stopped
```

Copy `mariadb/init.sh` to `observability-bootstrap/infologger/init.sh`.

## Connecting infoLoggerD on the host (macOS)

InfoLogger clients connect to infoLoggerD via a UNIX socket.  On macOS the
default abstract socket is not available, so a filesystem socket must be used.

1. Edit (or create) `~/infoLoggerD.cfg`:
   ```ini
   [infoLoggerD]
   serverHost=localhost
   serverPort=6006
   rxSocketPath=/tmp/infoLoggerD.socket
   ```

2. Edit (or create) `~/infoLoggerClient.cfg` (read by DPL processes):
   ```ini
   [client]
   txSocketPath=/tmp/infoLoggerD.socket
   ```

3. Start the daemon:
   ```bash
   export O2_INFOLOGGER_CONFIG=file:$HOME/infoLoggerD.cfg
   o2-infologger-daemon &
   ```

4. Set DPL environment (add to your run script):
   ```bash
   export O2_INFOLOGGER_MODE=infoLoggerD
   export O2_INFOLOGGER_CONFIG=file:$HOME/infoLoggerClient.cfg
   ```

5. Test injection from the command line:
   ```bash
   o2-infologger-log "hello from the host"
   ```

## Passwords

Default credentials (change for non-development use):

| User | Password | Purpose |
|---|---|---|
| `infoLoggerServer` | `ilgserver` | server ↔ DB (insert + select) |
| `infoLoggerAdmin`  | `ilgadmin`  | admindb (table create/archive) |
| `infoBrowser`      | `ilgbrowser`| bridge / read-only queries |

Override via environment variables when running the container.
