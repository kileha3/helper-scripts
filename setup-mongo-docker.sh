#!/bin/bash

set -e

# --- Input validation ---
if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <admin-username> <admin-password> <host-port> <container-name>"
  exit 1
fi

ADMIN_USER=$3
ADMIN_PASS=$4
HOST_PORT=$1
CONTAINER_NAME=$2

PROJECT_DIR="/var/www/core-mongo-db"
CONFIGS_DIR="$PROJECT_DIR/configs"
DATA_DIR="/var/www/mongo_db"

# --- Create project directories ---
sudo mkdir -p "$CONFIGS_DIR"
sudo mkdir -p "$DATA_DIR"
sudo chown -R 999:999 "$PROJECT_DIR" "$DATA_DIR"

# --- Create .env file ---
cat > "$CONFIGS_DIR/.env" <<EOF
MONGO_INITDB_ROOT_USERNAME=$ADMIN_USER
MONGO_INITDB_ROOT_PASSWORD=$ADMIN_PASS
EOF

# --- Create mongo-init.js ---
cat > "$CONFIGS_DIR/mongo-init.js" <<'EOF'
// Optional initialization script
db = db.getSiblingDB("admin");

const username = process.env.MONGO_INITDB_ROOT_USERNAME;
const password = process.env.MONGO_INITDB_ROOT_PASSWORD;

if (!db.getUser(username)) {
  db.createUser({
    user: username,
    pwd: password,
    roles: [{ role: "root", db: "admin" }]
  });
}
EOF

# --- Create docker-compose.yml ---
cat > "$CONFIGS_DIR/docker-compose.yml" <<EOF
version: "3.9"

services:
  mongo:
    image: mongo:7.0
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:27017"
    env_file:
      - .env
    volumes:
      - $DATA_DIR:/data/db
      - ./mongo-init.js:/docker-entrypoint-initdb.d/mongo-init.js:ro
EOF

echo "✅ Files created in $CONFIGS_DIR. Starting MongoDB container..."

# --- Start MongoDB ---
cd "$CONFIGS_DIR"
docker-compose up -d

# --- Wait for MongoDB to be ready ---
echo "➡️ Waiting for MongoDB to start..."
until docker exec "$CONTAINER_NAME" mongosh "mongodb://$ADMIN_USER:$ADMIN_PASS@localhost:27017/admin?authSource=admin" --eval "db.runCommand({ connectionStatus: 1 }).ok" 2>/dev/null | grep -q "1"; do
  sleep 2
  echo -n "."
done
echo ""
echo "✅ MongoDB is ready and authenticated!"

# --- Output connection string ---
echo ""
echo "Connection URL:"
echo "mongosh \"mongodb://$ADMIN_USER:$ADMIN_PASS@localhost:$HOST_PORT/admin?authSource=admin\""
