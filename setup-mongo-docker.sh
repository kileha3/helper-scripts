#!/bin/bash
set -e

# Script: setup-mongo-standalone.sh
# Usage:
# ./setup-mongo-standalone.sh --username myuser --password mypass --host-port 27017 --container-name ubongo [--project-dir /custom/path]

# --- Parse named params ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --username) MONGO_USERNAME="$2"; shift ;;
    --password) MONGO_PASSWORD="$2"; shift ;;
    --host-port) HOST_PORT="$2"; shift ;;
    --container-name) CONTAINER_NAME="$2"; shift ;;
    --project-dir) PROJECT_DIR="$2"; shift ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# --- Validate required params ---
if [[ -z "$MONGO_USERNAME" || -z "$MONGO_PASSWORD" || -z "$HOST_PORT" || -z "$CONTAINER_NAME" ]]; then
  echo "Missing required parameters"
  echo "Usage: ./setup-mongo-standalone.sh --username myuser --password mypass --host-port 27017 --container-name ubongo [--project-dir /custom/path]"
  exit 1
fi

# --- Setup directories ---
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="/var/www/mongo-standalone/$CONTAINER_NAME"
fi

DATA_DIR="$PROJECT_DIR/data"
KEYS_DIR="$PROJECT_DIR/keys"
ENV_FILE="$PROJECT_DIR/.env"
DOCKER_COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
KEY_FILE_HOST="$KEYS_DIR/mongo-keyfile"

# Only create DATA_DIR if it doesn't exist (preserve existing data)
mkdir -p "$KEYS_DIR"
[[ ! -d "$DATA_DIR" ]] && mkdir -p "$DATA_DIR"

# --- Generate key file ---
echo "Generating MongoDB keyfile..."
openssl rand -base64 756 > "$KEY_FILE_HOST"
chmod 400 "$KEY_FILE_HOST"

sudo chown -R 999:999 "$PROJECT_DIR"

# --- Remove existing container ---
EXISTING_CONTAINER=$(docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}")
if [[ -n "$EXISTING_CONTAINER" ]]; then
  echo "Removing existing container $EXISTING_CONTAINER..."
  docker rm -f "$EXISTING_CONTAINER" || true
fi

# --- Write .env ---
cat > "$ENV_FILE" <<EOL
MONGO_INITDB_ROOT_USERNAME=$MONGO_USERNAME
MONGO_INITDB_ROOT_PASSWORD=$MONGO_PASSWORD
EOL

# --- Write docker-compose.yml ---
cat > "$DOCKER_COMPOSE_FILE" <<EOL
version: "3.9"

services:
  $CONTAINER_NAME:
    image: mongo:7.0
    container_name: $CONTAINER_NAME
    ports:
      - "$HOST_PORT:27017"
    env_file:
      - $ENV_FILE
    command: ["mongod", "--auth", "--keyFile", "/etc/mongo-keyfile"]
    volumes:
      - $DATA_DIR:/data/db
      - $KEY_FILE_HOST:/etc/mongo-keyfile:ro
    healthcheck:
      test: ["CMD", "mongosh", "-u", "$MONGO_USERNAME", "-p", "$MONGO_PASSWORD", "--authenticationDatabase", "admin", "--eval", "db.adminCommand('ping')"]
      interval: 20s
      timeout: 10s
      retries: 5
    restart: unless-stopped
EOL

# --- Start container ---
docker compose -f "$DOCKER_COMPOSE_FILE" up -d

# --- Wait for health check ---
echo "Waiting for $CONTAINER_NAME to pass health check..."
RETRIES=10
until [ "$(docker inspect --format='{{.State.Health.Status}}' $CONTAINER_NAME)" = "healthy" ]; do
  echo "Waiting 5s..."
  sleep 5
  ((RETRIES--))
  if [[ $RETRIES -le 0 ]]; then
    echo "Error: $CONTAINER_NAME did not become healthy in time."
    exit 1
  fi
done

# --- Output connection info ---
CONNECTION_URL="mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:$HOST_PORT/?authSource=admin"
echo "MongoDB standalone instance is running."
echo "Connection URL: $CONNECTION_URL"
