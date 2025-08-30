#!/bin/bash
set -e

# Usage:
# ./setup-mongo-docker.sh --username myuser --password mypass --host-port 27000 --containers 2 --container-name ubongo

# --- Parse named params ---
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --username) MONGO_USERNAME="$2"; shift ;;
    --password) MONGO_PASSWORD="$2"; shift ;;
    --host-port) HOST_PORT="$2"; shift ;;
    --containers) NUM_CONTAINERS="$2"; shift ;;
    --container-name) CONTAINER_NAME="$2"; shift ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$MONGO_USERNAME" || -z "$MONGO_PASSWORD" || -z "$HOST_PORT" || -z "$NUM_CONTAINERS" || -z "$CONTAINER_NAME" ]]; then
  echo "Missing required parameters"
  echo "Usage: ./setup-mongo-docker.sh --username myuser --password mypass --host-port 27000 --containers 2 --container-name ubongo"
  exit 1
fi

# --- Setup directories ---
PROJECT_DIR="/var/www/core-mongo-db/$CONTAINER_NAME"
CONFIG_DIR="$PROJECT_DIR/configs"
DATA_DIR_BASE="$PROJECT_DIR/data"
DOCKER_COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"
INIT_FILE="$CONFIG_DIR/mongo-init.js"

mkdir -p "$CONFIG_DIR"
[[ ! -d "$DATA_DIR_BASE" ]] && mkdir -p "$DATA_DIR_BASE"

# --- Write .env ---
cat > "$ENV_FILE" <<EOL
MONGO_INITDB_ROOT_USERNAME=$MONGO_USERNAME
MONGO_INITDB_ROOT_PASSWORD=$MONGO_PASSWORD
REPLICA_SET_NAME=rs_default
EOL

# --- Write docker-compose.yml ---
cat > "$DOCKER_COMPOSE_FILE" <<EOL
version: '3.9'
services:
EOL

NETWORK_NAME="${CONTAINER_NAME}_network"

for i in $(seq 1 $NUM_CONTAINERS); do
  if [[ $NUM_CONTAINERS -eq 1 ]]; then
    CONTAINER_INSTANCE_NAME="${CONTAINER_NAME}"
    MAPPED_PORT="$HOST_PORT"
    EXTRA_VOLUME="- $INIT_FILE:/docker-entrypoint-initdb.d/mongo-init.js:ro"
  else
    if [[ $i -eq 1 ]]; then
      CONTAINER_INSTANCE_NAME="${CONTAINER_NAME}-master"
      MAPPED_PORT="$HOST_PORT"
      EXTRA_VOLUME="- $INIT_FILE:/docker-entrypoint-initdb.d/mongo-init.js:ro"
    else
      CONTAINER_INSTANCE_NAME="${CONTAINER_NAME}-$i"
      MAPPED_PORT=$((HOST_PORT + i - 1))
      EXTRA_VOLUME=""
    fi
  fi

  CONTAINER_DATA_DIR="$DATA_DIR_BASE/$CONTAINER_INSTANCE_NAME"
  [[ ! -d "$CONTAINER_DATA_DIR" ]] && mkdir -p "$CONTAINER_DATA_DIR"

  cat >> "$DOCKER_COMPOSE_FILE" <<EOL
  $CONTAINER_INSTANCE_NAME:
    image: mongo:7.0
    container_name: $CONTAINER_INSTANCE_NAME
    ports:
      - "$MAPPED_PORT:27017"
    env_file:
      - $ENV_FILE
    command: ["mongod", "--replSet", "\${REPLICA_SET_NAME}", "--auth"]
    volumes:
      - $CONTAINER_DATA_DIR:/data/db
      $EXTRA_VOLUME
    networks:
      - $NETWORK_NAME

EOL
done

cat >> "$DOCKER_COMPOSE_FILE" <<EOL
networks:
  $NETWORK_NAME:
    driver: bridge
EOL

# --- Write init script (used only by master) ---
cat > "$INIT_FILE" <<EOL
rs.initiate({
  _id: "rs_default",
  members: [
EOL

for i in $(seq 1 $NUM_CONTAINERS); do
  if [[ $NUM_CONTAINERS -eq 1 ]]; then
    NAME="${CONTAINER_NAME}"
  else
    if [[ $i -eq 1 ]]; then
      NAME="${CONTAINER_NAME}-master"
    else
      NAME="${CONTAINER_NAME}-$i"
    fi
  fi

  COMMA=","
  if [[ $i -eq $NUM_CONTAINERS ]]; then COMMA=""; fi
  echo "    { _id: $((i-1)), host: \"$NAME:27017\" }$COMMA" >> "$INIT_FILE"
done

cat >> "$INIT_FILE" <<EOL
  ]
});
EOL

# --- Start containers ---
docker compose -f "$DOCKER_COMPOSE_FILE" up -d

# --- Wait for master ---
if [[ $NUM_CONTAINERS -eq 1 ]]; then
  MASTER_NAME="$CONTAINER_NAME"
else
  MASTER_NAME="${CONTAINER_NAME}-master"
fi

echo "Waiting for $MASTER_NAME to start..."
until docker exec "$MASTER_NAME" mongosh --eval "db.adminCommand('ping')" >/dev/null 2>&1; do
  sleep 3
done

# --- Initiate replica set if more than 1 node ---
if [[ $NUM_CONTAINERS -eq 1 ]]; then
  CONNECTION_URL="mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:$HOST_PORT/?authSource=admin"
  echo "MongoDB single instance running."
  echo "Connection URL: $CONNECTION_URL"
else
  docker exec "$MASTER_NAME" mongosh -u "$MONGO_USERNAME" -p "$MONGO_PASSWORD" --authenticationDatabase admin --eval "
    try {
      rs.status()
    } catch (e) {
      load('/docker-entrypoint-initdb.d/mongo-init.js')
    }"
  CONNECTION_URL="mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:$HOST_PORT/?replicaSet=rs_default&authSource=admin"
  echo "MongoDB replica set with $NUM_CONTAINERS nodes running."
  echo "Connection URL: $CONNECTION_URL"
fi
