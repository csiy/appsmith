#!/usr/bin/env bash
# Appsmith Cloud Agent start script.
# Brings up the per-boot backing services: MongoDB (replica set), Redis, and the
# nginx reverse proxy. Dev servers (Java, RTS, client) run as terminals.
# Idempotent: safe to run on every boot.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

is_listening() { ss -ltn 2>/dev/null | grep -q ":$1\b"; }

echo "==> Ensuring /etc/hosts maps dev.appsmith.com -> 127.0.0.1"
grep -q "dev.appsmith.com" /etc/hosts || echo "127.0.0.1 dev.appsmith.com" | sudo tee -a /etc/hosts >/dev/null

echo "==> Starting Redis"
if ! is_listening 6379; then
  sudo systemctl start redis-server 2>/dev/null || redis-server --daemonize yes
fi

echo "==> Starting MongoDB (replica set rs0)"
sudo mkdir -p /data/db /var/log/mongodb
sudo chown -R "$(whoami)" /data/db /var/log/mongodb
if ! is_listening 27017; then
  mongod --replSet rs0 --dbpath /data/db --bind_ip 127.0.0.1 --port 27017 \
    --logpath /var/log/mongodb/mongod.log --fork
fi
# Wait for mongod to accept connections.
for _ in $(seq 1 30); do
  mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break
  sleep 1
done
# Initialise the replica set once (no-op if already initiated).
if ! mongosh --quiet --eval 'rs.status().ok' >/dev/null 2>&1; then
  mongosh --quiet --eval 'rs.initiate({_id:"rs0", members:[{_id:0, host:"localhost:27017"}]})'
fi

echo "==> Preparing nginx (bind privileges + writable temp dirs)"
sudo setcap 'cap_net_bind_service=+ep' "$(readlink -f "$(command -v nginx)")" || true
sudo chown -R "$(whoami)" /var/lib/nginx /var/log/nginx 2>/dev/null || true

echo "==> Starting nginx reverse proxy (https://dev.appsmith.com -> client:3000 / server:8080 / rts:8091)"
( cd app/client && bash ./start-https.sh http://localhost:8080 )

echo "==> Start complete. Backing services are up; dev servers run in terminals."
