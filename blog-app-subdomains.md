# Custom Subdomains for Frappe Apps (Helpdesk, CRM) on Coolify

**TL;DR:** You can serve Frappe Helpdesk at `helpdesk.example.com` and CRM at `crm.example.com` while keeping a single Frappe site — no separate databases, no duplicate users. This post walks through the nginx + Traefik configuration to make it work with a Docker-based Frappe deployment on Coolify.

---

## The Problem

You've deployed ERPNext on Coolify at `erp.example.com`. It has Helpdesk, CRM, and other apps installed. Everything works, but:

- You don't want to share `erp.example.com/helpdesk` with customers — it exposes the ERP domain
- You want `helpdesk.example.com` to go directly to the customer portal
- You don't want to create a separate Frappe site (that means separate databases, separate users, no shared data between Helpdesk and ERPNext)

## The Solution

Map app subdomains to the same Frappe site using an nginx `map` block. Three files make this work:

### 1. nginx/domain-map.conf

This nginx config maps subdomain hostnames to the actual Frappe site name. It goes in `/etc/nginx/conf.d/` where it's loaded before the main Frappe config.

```nginx
map $host $frappe_site {
    default $host;

    # Your subdomains → actual site
    helpdesk.example.com erp.example.com;
    crm.example.com      erp.example.com;
}
```

When a request comes in for `helpdesk.example.com`, the `$frappe_site` variable resolves to `erp.example.com`. For `erp.example.com`, it passes through unchanged.

### 2. Dockerfile: Bake the config + set the env var

```dockerfile
FROM frappe/base:${FRAPPE_BRANCH} AS backend

# Domain map for subdomain → site resolution
COPY nginx/domain-map.conf /etc/nginx/conf.d/00-domain-map.conf

# Custom template with socket.io Origin fix (explained below)
COPY nginx/frappe.conf.template /templates/nginx/frappe.conf.template

# Tell nginx to use the mapped variable instead of $host
ENV FRAPPE_SITE_NAME_HEADER="$frappe_site"
```

The key is `FRAPPE_SITE_NAME_HEADER`. The Frappe Docker image uses this env var in its nginx template for the `X-Frappe-Site-Name` header — which is how Frappe identifies which site should handle a request. By setting it to `$frappe_site` (our mapped variable), nginx translates `helpdesk.example.com` → `erp.example.com` before Frappe ever sees it.

### 3. Traefik labels: Redirect root to the app path

In your `docker-compose.yml`, add redirect middlewares so `helpdesk.example.com/` lands on the right page:

```yaml
frontend:
  labels:
    - traefik.http.services.frontend.loadbalancer.server.port=8080
    # helpdesk.example.com/ → customer portal
    - traefik.http.middlewares.helpdesk-redirect.redirectregex.regex=^https://helpdesk\.example\.com/?$$
    - traefik.http.middlewares.helpdesk-redirect.redirectregex.replacement=https://helpdesk.example.com/helpdesk/my-tickets
    - traefik.http.middlewares.helpdesk-redirect.redirectregex.permanent=true
    # crm.example.com/ → CRM app
    - traefik.http.middlewares.crm-redirect.redirectregex.regex=^https://crm\.example\.com/?$$
    - traefik.http.middlewares.crm-redirect.redirectregex.replacement=https://crm.example.com/crm
    - traefik.http.middlewares.crm-redirect.redirectregex.permanent=true
```

Note: For Helpdesk, we redirect to `/helpdesk/my-tickets` (the customer portal) rather than `/helpdesk` (the agent dashboard). Frappe Helpdesk's Vue router automatically redirects non-agent users to the customer view, but this ensures the right page loads even for agents visiting the customer-facing domain.

## The Socket.IO Gotcha

After setting up the above, pages load fine but WebSocket connections fail with:

```
WebSocket connection to 'wss://helpdesk.example.com/socket.io/...' failed
```

### Why

Frappe's Socket.IO authentication middleware (`realtime/middlewares/authenticate.js`) validates that the `Host` and `Origin` headers match:

```javascript
if (get_hostname(socket.request.headers.host) != get_hostname(socket.request.headers.origin)) {
    next(new Error("Invalid origin"));
    return;
}
```

The default Frappe nginx template sets both `X-Frappe-Site-Name` and the socket.io `Origin` to the same variable:

```nginx
proxy_set_header X-Frappe-Site-Name $frappe_site;  # erp.example.com
proxy_set_header Origin https://$frappe_site;       # https://erp.example.com
proxy_set_header Host $host;                        # helpdesk.example.com
```

`Host` is `helpdesk.example.com` but `Origin` is `erp.example.com` — they don't match, Socket.IO rejects the connection.

### Fix

Create a custom `nginx/frappe.conf.template` (copy of the upstream template) with one change in the `location /socket.io` block:

```nginx
location /socket.io {
    # ... other headers ...
    proxy_set_header X-Frappe-Site-Name $frappe_site;  # mapped site name for Frappe
    proxy_set_header Origin $proxy_x_forwarded_proto://$host;  # actual hostname for auth
    proxy_set_header Host $host;
}
```

The `Origin` now uses `$host` (the actual domain from the browser) while `X-Frappe-Site-Name` still uses the mapped site name. The Socket.IO auth check passes because `Host` and `Origin` now match, and Frappe still resolves the correct site via the `X-Frappe-Site-Name` header.

## Coolify Setup

After deploying the updated image:

1. **Coolify UI** — Add the subdomains to the frontend service's domain list:
   ```
   https://erp.example.com,https://helpdesk.example.com,https://crm.example.com
   ```
   Coolify + Traefik handle SSL cert provisioning automatically.

2. **DNS** — Add A/CNAME records for the subdomains pointing to your server.

That's it. No `bench add-domain`, no separate sites, no database changes.

## What You Get

| Domain | Lands on | Same site? |
|--------|----------|------------|
| `erp.example.com` | ERPNext desk | Yes |
| `helpdesk.example.com` | Helpdesk customer portal | Yes |
| `crm.example.com` | CRM app | Yes |

- Shared database — Helpdesk tickets can reference ERPNext customers and orders
- Shared users — one login works across all subdomains
- Shared sessions — if you're logged in on one, you're logged in on all
- Role-based access still works — a "Support Agent" role only sees Helpdesk doctypes regardless of which domain they use

## Important Caveats

- **Not a security boundary.** A user on `helpdesk.example.com` can navigate to `helpdesk.example.com/app` and access the full Frappe desk if their role allows it. Use Frappe's role permissions for access control, not subdomains.

- **Image rebuild required.** The `nginx/domain-map.conf` is baked into the Docker image. Adding a new subdomain requires rebuilding and redeploying. (You could mount it as a volume instead to avoid rebuilds, but that adds operational complexity.)

- **Template maintenance.** The custom `nginx/frappe.conf.template` is a copy of the upstream Frappe template. When upgrading Frappe versions, diff the upstream template and sync any changes.

## File Structure

```
your-repo/
  nginx/
    domain-map.conf          # map $host → $frappe_site
    frappe.conf.template      # custom nginx template (Origin fix)
  Dockerfile                  # COPY configs + ENV FRAPPE_SITE_NAME_HEADER
  docker-compose.coolify.yml  # Traefik redirect labels
```

All changes are in the infrastructure layer — zero modifications to Frappe application code.
