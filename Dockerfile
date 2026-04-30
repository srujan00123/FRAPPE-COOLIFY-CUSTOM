ARG FRAPPE_BRANCH=develop

FROM frappe/build:${FRAPPE_BRANCH} AS builder

ARG FRAPPE_BRANCH=develop
ARG FRAPPE_PATH=https://github.com/frappe/frappe

USER frappe

ENV NODE_OPTIONS="--max-old-space-size=2048"

# apps.json is mounted as a BuildKit secret (not a build-arg), so it never
# enters the image's build cache key in plaintext and can contain repo URLs.
# github_token is optional; mount it when apps.json contains private repos.
RUN --mount=type=secret,id=apps_json,target=/opt/frappe/apps.json,uid=1000,gid=1000 \
    --mount=type=secret,id=github_token,uid=1000,gid=1000,required=false \
    --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000,sharing=locked \
    --mount=type=cache,target=/home/frappe/.npm,uid=1000,gid=1000,sharing=locked \
    --mount=type=cache,target=/home/frappe/.yarn,uid=1000,gid=1000,sharing=locked \
  if [ -s /run/secrets/github_token ]; then \
    TOKEN=$(cat /run/secrets/github_token) && \
    git config --global "url.https://x-access-token:${TOKEN}@github.com/.insteadOf" "https://github.com/" && \
    echo "Configured git to use token for github.com clones"; \
  fi && \
  export APP_INSTALL_ARGS="" && \
  if [ -f /opt/frappe/apps.json ] && [ -s /opt/frappe/apps.json ]; then \
    export APP_INSTALL_ARGS="--apps_path=/opt/frappe/apps.json"; \
  fi && \
  bench init ${APP_INSTALL_ARGS}\
    --frappe-branch=${FRAPPE_BRANCH} \
    --frappe-path=${FRAPPE_PATH} \
    --no-procfile \
    --no-backups \
    --skip-redis-config-generation \
    /home/frappe/frappe-bench && \
  cd /home/frappe/frappe-bench && \
  echo '{"socketio_port": 9000, "webserver_port": 8000, "redis_queue": "redis://redis-queue:11311", "redis_cache": "redis://redis-cache:13311"}' > sites/common_site_config.json && \
  find apps -mindepth 1 -path "*/.git" | xargs rm -fr && \
  rm -f /home/frappe/.gitconfig

FROM frappe/base:${FRAPPE_BRANCH} AS backend

# Custom nginx: domain map + template with Origin fix for subdomain socket.io
COPY nginx/domain-map.conf /etc/nginx/conf.d/00-domain-map.conf
COPY nginx/frappe.conf.template /templates/nginx/frappe.conf.template
ENV FRAPPE_SITE_NAME_HEADER="\$frappe_site"

USER frappe

COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/sites/assets", \
  "/home/frappe/frappe-bench/logs" \
]

CMD [ \
  "/home/frappe/frappe-bench/env/bin/gunicorn", \
  "--chdir=/home/frappe/frappe-bench/sites", \
  "--bind=0.0.0.0:8000", \
  "--threads=4", \
  "--workers=2", \
  "--worker-class=gthread", \
  "--worker-tmp-dir=/dev/shm", \
  "--timeout=120", \
  "--preload", \
  "frappe.app:application" \
]
