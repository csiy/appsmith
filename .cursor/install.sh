#!/usr/bin/env bash
# Appsmith Cloud Agent environment install script.
# Installs system toolchains and builds the client, server, and RTS service.
# Designed to be idempotent so it can run repeatedly or as a build baseline.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

JAVA_17_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
NODE_VERSION="18.17.1"

echo "==> [1/7] Installing base APT packages (Java 17, Maven, Redis, nginx, tooling)"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openjdk-17-jdk-headless \
  maven \
  redis-server \
  nginx \
  rsync \
  lsof \
  libnss3-tools \
  gnupg \
  curl \
  ca-certificates

echo "==> [2/7] Installing MongoDB 7.0 (jammy repo, compatible with noble)"
if ! command -v mongod >/dev/null 2>&1; then
  curl -fsSL https://pgp.mongodb.com/server-7.0.asc \
    | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor --yes
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
    | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org-server mongodb-mongosh
fi

echo "==> [3/7] Installing mkcert (locally trusted TLS certs for dev.appsmith.com)"
if ! command -v mkcert >/dev/null 2>&1; then
  curl -fsSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o /tmp/mkcert
  sudo install -m 0755 /tmp/mkcert /usr/local/bin/mkcert
  rm -f /tmp/mkcert
fi
# Register the local CA in the system + browser (NSS) trust stores.
mkdir -p "$HOME/.pki/nssdb"
certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password >/dev/null 2>&1 || true
mkcert -install

echo "==> [4/7] Installing Node ${NODE_VERSION} via nvm and enabling Yarn"
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
export PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"
corepack enable
corepack prepare yarn@3.5.1 --activate

echo "==> [5/7] Writing dev env files (idempotent)"
[ -f app/server/.env ] || cp app/server/envs/dev.env.example app/server/.env
[ -f .env ] || cp .env.example .env
cat > app/client/packages/rts/.env <<'EOF'
APPSMITH_API_BASE_URL=http://localhost:8080/api/v1
APPSMITH_RTS_PORT=8091
PORT=8091
APPSMITH_LOG_LEVEL=info
EOF

echo "==> [6/7] Installing client dependencies and building the RTS service"
( cd app/client && yarn install --immutable )
( cd app/client/packages/rts && ./build.sh )

echo "==> [7/7] Building the Appsmith server (skipping tests)"
(
  cd app/server
  export JAVA_HOME="$JAVA_17_HOME"
  export PATH="$JAVA_HOME/bin:$PATH"
  ./build.sh -DskipTests
)

echo "==> Install complete."
