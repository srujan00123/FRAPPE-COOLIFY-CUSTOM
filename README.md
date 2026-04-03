# Frappe/ERPNext Custom Image + Coolify Deployment

Production-ready Coolify deployment for Frappe/ERPNext with custom apps:

- ERPNext, HRMS, CRM, Helpdesk, Telephony, WhatsApp, Mint, India Compliance
- Multi-stage Docker build based on official `frappe_docker` patterns
- Multi-site support with config-as-code (`sites.json`)
- Docker Compose template for Coolify with Traefik TLS routing

## 1) Configure apps

Edit `apps.json` to list apps baked into your image. Frappe is installed automatically by `bench init` -- do not include it in `apps.json`.

`apps.json` defines what's **available** in the image. `sites.json` defines which apps are **installed** on each site.

## 2) Configure sites

Define your sites as a JSON array:

```json
[
  {
    "name": "erp.example.com",
    "apps": ["erpnext", "hrms", "crm", "helpdesk", "telephony", "frappe_whatsapp", "mint", "india_compliance"],
    "default": true
  },
  {
    "name": "erp.example2.com",
    "apps": ["erpnext", "hrms", "india_compliance"]
  }
]
```

- `name`: site domain (used for routing and as the bench site name)
- `apps`: apps to install (must be a subset of what's in `apps.json`)
- `default`: which site `bench use` sets as default (one site only)

**Two ways to provide sites config:**

1. **`SITES_JSON_BASE64` env var** (recommended for Coolify) — base64-encode the JSON and set it in Coolify's environment variables. This lets you change sites without rebuilding the image:
   ```bash
   # Linux
   base64 -w 0 sites.json
   # macOS
   base64 -i sites.json
   ```

2. **Baked-in `sites.json`** (fallback) — edit `sites.json` in the repo. It's copied into the image at build time and used if `SITES_JSON_BASE64` is not set.

## 3) Build and push the image

### Manual build

Use `build.sh` to build and optionally push:

```bash
# Build only (local)
./build.sh

# Build and push to GHCR
PUSH=true ./build.sh

# Override image name or tag
IMAGE=ghcr.io/youruser/custom-frappe TAG=v1.0 PUSH=true ./build.sh
```

Defaults: `IMAGE=ghcr.io/youruser/custom-frappe`, `TAG=develop`, `FRAPPE_BRANCH=develop`.

Every build is also tagged with a date stamp (e.g., `develop-20260212`) for rollback.

The script handles base64-encoding `apps.json` automatically (works on Linux, macOS, and Git Bash on Windows).

### CI/CD (GitHub Actions)

Pushing to `main` automatically builds and deploys via `.github/workflows/deploy.yml`:

1. Builds the Docker image on GitHub Actions runners
2. Pushes to `ghcr.io/youruser/custom-frappe` with tags: `latest`, `develop`, `develop-<date>`, `develop-<sha>`
3. Triggers Coolify redeploy via webhook

**Setup required** (one-time, in GitHub repo Settings > Secrets):

| Secret | Value |
|---|---|
| `COOLIFY_WEBHOOK` | `https://<your-coolify>/api/v1/deploy?uuid=<resource-id>` |
| `COOLIFY_TOKEN` | API token from Coolify > Security > API Tokens |

`GITHUB_TOKEN` is automatic — no setup needed for GHCR.

Then set in Coolify:

- `FRAPPE_IMAGE=ghcr.io/youruser/custom-frappe`
- `FRAPPE_VERSION=develop`

## 4) Deploy to Coolify

1. In Coolify, create a new **Docker Compose Empty** resource.
2. Paste `docker-compose.coolify.yml` into the Compose editor.
3. Set environment variables in Coolify:

| Variable | Example | Notes |
|---|---|---|
| `FRAPPE_IMAGE` | `ghcr.io/youruser/custom-frappe` | Your registry image |
| `FRAPPE_VERSION` | `develop` | Image tag |
| `SERVICE_PASSWORD_DB` | (auto-generated) | MariaDB root password |
| `SERVICE_PASSWORD_ADMIN` | (auto-generated) | Frappe admin password |
| `SITES_JSON_BASE64` | (base64 string) | Sites config (see step 2) |
| `DOMAIN` | `erp.example.com` | Domain for Traefik routing |
| `ADMIN_PASSWORD_1` | | Per-site admin password (site 1) |
| `ADMIN_PASSWORD_2` | | Per-site admin password (site 2) |

Optional:

| Variable | Default | Notes |
|---|---|---|
| `FRAPPE_SITE_NAME_HEADER` | `$host` | Override if Host header doesn't match site names |
| `PROXY_READ_TIMEOUT` | `120` | Nginx upstream timeout (seconds) |
| `CLIENT_MAX_BODY_SIZE` | `50m` | Max upload size |

## 5) Traefik routing

Set `DOMAIN` to your site's domain (must match a site name in `sites.json`):

```
erp.example.com
```

If you run multiple stacks on the same Coolify server, rename `frappe-router` to a unique name per stack in the compose labels.

## 6) Login

After deployment completes:

- User: `Administrator`
- Password: value of `SERVICE_PASSWORD_ADMIN`

## Maintenance

### Update apps (safe update workflow)

Use `update.sh` for a safe update that backs up all sites first:

```bash
./update.sh              # backup → build → push → restart
./update.sh --local      # backup → build → restart (no push)
./update.sh --skip-backup  # skip backup (use with caution)
```

Or manually:

1. Edit `apps.json` branches/tags if needed
2. `PUSH=true ./build.sh` to rebuild and push the image
3. Redeploy in Coolify (or `docker compose ... up -d` locally)
4. The `migrate` service runs automatically on every deploy

### Backup

**Scheduled (production):** In Coolify, add a Scheduled Task on this application:
- Cron: `0 2 * * *` (daily at 2 AM)
- Command: `bench --site all backup --with-files`
- Container: `backend`

Backups are stored inside the `sites` volume at `sites/<name>/private/backups/`.

**Manual (local/SSH):**

```bash
./backup.sh                # backup all sites
./backup.sh erp.localhost  # backup one site
```

Backups are copied to `./backups/<site-name>/<timestamp>/` containing:
- `*-database.sql.gz` — database dump
- `*-files.tar` — public files
- `*-private-files.tar` — private files

### Restore

Use `restore.sh` to restore a site from a backup:

```bash
./restore.sh erp.localhost ./backups/erp.localhost/20260212_120000/
```

This copies the backup into the container, restores the database and files, and runs migrate.

### Rollback

Every build is tagged with a date stamp (`develop-20260212`) and CI builds also get a SHA tag (`develop-abc1234`). To rollback:

1. **Revert to a previous image** — change `FRAPPE_VERSION` in Coolify to the previous tag and redeploy:
   ```
   FRAPPE_VERSION=develop-20260211
   ```
   Locally:
   ```bash
   FRAPPE_VERSION=develop-20260211 docker compose -f docker-compose.coolify.yml up -d
   ```

2. **Restore from backup** (if data needs reverting too):
   ```bash
   ./restore.sh erp.localhost ./backups/erp.localhost/<timestamp>/
   ```

List available tags: `docker image ls ghcr.io/youruser/custom-frappe`

### Add a new site

1. Add an entry to `sites.json`
2. Update `DOMAIN` in Coolify to the new domain
3. Rebuild image → redeploy
4. `create-site` creates the new site, skips existing ones

### Add/remove app on existing site

- Install: exec into backend → `bench --site sitename install-app appname`
- Uninstall: exec into backend → `bench --site sitename uninstall-app appname`
- Then update `sites.json` to match (for future rebuilds)

## App Subdomains (e.g., helpdesk.example.com)

Instead of sharing `erp.example.com/helpdesk` with customers, you can expose Frappe apps on their own subdomains — `helpdesk.example.com`, `crm.example.com`, etc. — while keeping everything on a single Frappe site (shared database, users, sessions).

### How it works

```
helpdesk.example.com  ──→  Traefik  ──→  nginx (map → erp.example.com)  ──→  Frappe
erp.example.com       ──→  Traefik  ──→  nginx (passthrough)            ──→  Frappe
```

Three pieces make this work:

1. **`nginx/domain-map.conf`** — an nginx `map` block that translates subdomain hostnames to the actual Frappe site name:
   ```nginx
   map $host $frappe_site {
       default $host;
       helpdesk.example.com erp.example.com;
       crm.example.com      erp.example.com;
   }
   ```

2. **`FRAPPE_SITE_NAME_HEADER=$frappe_site`** (Dockerfile ENV) — tells nginx to use the mapped variable instead of `$host` for `X-Frappe-Site-Name`. This is how Frappe identifies which site to serve.

3. **`nginx/frappe.conf.template`** — custom nginx template (overrides the one in `frappe/base`) with one fix: the socket.io `Origin` header uses `$host` instead of `$frappe_site`. Without this, Frappe's socketio auth rejects WebSocket connections because it checks that `Host` and `Origin` hostnames match.

4. **Traefik redirect labels** (in `docker-compose.coolify.yml`) — redirect the subdomain root to the correct app path:
   ```
   helpdesk.example.com/  →  helpdesk.example.com/helpdesk/my-tickets
   crm.example.com/       →  crm.example.com/crm
   ```

### Adding a new app subdomain

1. **Add to `nginx/domain-map.conf`:**
   ```nginx
   newapp.example.com  erp.example.com;
   ```

2. **Add Traefik redirect labels** in `docker-compose.coolify.yml` (frontend service):
   ```yaml
   - traefik.http.middlewares.newapp-redirect.redirectregex.regex=^https://newapp\.example\.com/?$$
   - traefik.http.middlewares.newapp-redirect.redirectregex.replacement=https://newapp.example.com/newapp
   - traefik.http.middlewares.newapp-redirect.redirectregex.permanent=true
   ```

3. **Rebuild and push the image** (the domain map is baked into the image):
   ```bash
   PUSH=true ./build.sh
   ```

4. **In Coolify**, add `https://newapp.example.com` to the frontend service domains.

5. **DNS**: add an A/CNAME record for `newapp.example.com` pointing to your server.

### Important notes

- Subdomains share the **same Frappe site** — same database, users, sessions, and permissions.
- A subdomain is a **UX convenience, not a security boundary**. A user on `helpdesk.example.com` could navigate to `helpdesk.example.com/app` and access the full desk if they have permissions. Use Frappe's role-based permissions for access control.
- The `nginx/frappe.conf.template` is a copy of the upstream template from `frappe/base` with only the `Origin` header line changed. When upgrading Frappe versions, check if the upstream template has changed and sync accordingly.

## Local development

For testing locally without Coolify/Traefik:

1. Copy `.env.example` to `.env` and adjust values:

```env
FRAPPE_IMAGE=custom-frappe
FRAPPE_VERSION=develop
SERVICE_PASSWORD_DB=admin
SERVICE_PASSWORD_ADMIN=admin
DOMAIN=erp.localhost
```

2. Create `docker-compose.override.yml` to expose the frontend port:

```yaml
services:
  frontend:
    ports:
      - "8080:8080"
```

3. Build the image locally:

```bash
./build.sh
```

4. Start the stack:

```bash
docker compose -f docker-compose.coolify.yml -f docker-compose.override.yml up -d
```

5. Access at http://localhost:8080 (login: `Administrator` / `admin`)

   Use the `Host` header to reach each site:
   ```bash
   curl -H "Host: erp.example.com" http://localhost:8080/api/method/frappe.ping
   curl -H "Host: erp.example2.com" http://localhost:8080/api/method/frappe.ping
   ```

Both `.env` and `docker-compose.override.yml` are in `.gitignore`.

## Architecture

```
Client -> Coolify Traefik (:443) -> frontend (nginx :8080)
  -> static assets served directly
  -> /api/* -> backend (gunicorn :8000)
  -> /socket.io/* -> websocket (node :9000)

backend/workers/scheduler -> db (MariaDB :3306)
                          -> redis-cache (:6379)
                          -> redis-queue (:6379)
```

### Startup order

```
configure → create-site → migrate → backend, websocket, workers, scheduler
                                  ↗ frontend (waits for backend + websocket)
```

- **First deploy**: creates all sites from `sites.json` → migrate (no-op) → services start
- **Update deploy**: skips existing sites → migrate runs schema updates → services start

### Services

| Service | Role |
|---|---|
| `configure` | One-shot: writes `apps.txt` and `common_site_config.json` |
| `create-site` | One-shot: reads `sites.json`, creates sites with per-site app lists |
| `migrate` | One-shot: runs `bench --site all migrate` for schema updates |
| `backend` | Gunicorn application server |
| `frontend` | Nginx reverse proxy with Traefik labels |
| `websocket` | Socket.IO for real-time updates |
| `queue-long` | Background worker (long, default, short queues) |
| `queue-short` | Background worker (short, default queues) |
| `scheduler` | Periodic task scheduler |
| `db` | MariaDB 11.8 |
| `redis-cache` | Redis for caching (ephemeral) |
| `redis-queue` | Redis for job queues (persistent volume) |

## Notes

- `apps.json` defines apps at **image build time** (bakes code into the image).
- `sites.json` defines sites at **image build time** (read at runtime by `create-site`).
- `sites/apps.txt` is generated at **runtime** by the `configure` service.
- The `create-site` service reads `sites.json` via `jq` and creates each site with its specific app list.
- The `migrate` service runs on every deploy to apply schema changes.
- CRM, Helpdesk, and Mint compile their Vue/Vite frontends into standard Frappe assets during `bench build` at image build time -- no separate frontend server needed.
- `frappe_whatsapp` uses `master` branch (the repo has no `main` or `develop` branch).
- Nginx routes requests to the correct site using `X-Frappe-Site-Name` header, set to `$frappe_site` (a mapped variable that resolves subdomains to the actual site name — see [App Subdomains](#app-subdomains-eg-helpdeskexamplecom)).
