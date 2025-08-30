#!/bin/bash

# Usage:
# ./setup_mongo.sh --project-dir /var/www/core-mongo-db \
#                  --container-name db-ubongo-mongo \
#                  --username myuser \
#                  --password mypass \
#                  --port 27000 \
#                  --num-containers 2

# Parse named parameters
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project-dir) PROJECT_DIR="$2"; shift ;;
        --container-name) CONTAINER_NAME="$2"; shift ;;
        --username) MONGO_USERNAME="$2"; shift ;;
        --password) MONGO_PASSWORD="$2"; shift ;;
        --port) HOST_PORT="$2"; shift ;;
        --num-containers) NUM_CONTAINERS="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Validate
if [[ -z "$PROJECT_DIR" || -z "$CONTAINER_NAME" || -z "$MONGO_USERNAME" || -z "$MONGO_PASSWORD" || -z "$HOST_PORT" || -z "$NUM_CONTAINERS" ]]; then
  echo "Missing parameters. Please provide all required flags."
  exit 1
fi

# Derived vars
DATA_DIR_BASE="$PROJECT_DIR/data"
ENV_FILE="$PROJECT_DIR/.env"
DOCKER_COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
INIT_FILE="$PROJECT_DIR/mongo-init.js"
NETWORK_NAME="${CONTAINER_NAME}-net"

# Prepare dirs
mkdir -p "$PROJECT_DIR"
mkdir -p "$DATA_DIR_BASE"

# Write .env
cat > "$ENV_FILE" <<EOL
MONGO_INITDB_ROOT_USERNAME=$MONGO_USERNAME
MONGO_INITDB_ROOT_PASSWORD=$MONGO_PASSWORD
REPLICA_SET_NAME=rs0
EOL

# Write mongo-init.js (used for replica setup if NUM_CONTAINERS > 1)
cat > "$INIT_FILE" <<EOL
rs.initiate({
  _id: "rs0",
  members: [
    $(for i in $(seq 1 $NUM_CONTAINERS); do
      port=$((27017))
      echo "{ _id: $((i-1)), host: \\"${CONTAINER_NAME}-$i:27017\\" }$( [[ $i -lt $NUM_CONTAINERS ]] && echo , )"
    done)
  ]
})
EOL

# Write docker-compose.yml
cat > "$DOCKER_COMPOSE_FILE" <<EOL
version: "3.9"

networks:
  $NETWORK_NAME:
    driver: bridge

services:
EOL

for i in $(seq 1 $NUM_CONTAINERS); do
  CONTAINER_INSTANCE_NAME="${CONTAINER_NAME}-$i"
  CONTAINER_DATA_DIR="$DATA_DIR_BASE/$i"
  mkdir -p "$CONTAINER_DATA_DIR"

  if [[ $i -eq 1 ]]; then
    MAPPED_PORT="$HOST_PORT"
  else
    MAPPED_PORT=$((HOST_PORT + i - 1))
  fi

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
      - $INIT_FILE:/docker-entrypoint-initdb.d/mongo-init.js:ro
    networks:
      - $NETWORK_NAME

EOL
done

# Bring up containers
docker compose -f "$DOCKER_COMPOSE_FILE" up -d

# Wait a bit for containers
sleep 5

# If single instance, just print connection
if [[ $NUM_CONTAINERS -eq 1 ]]; then
  CONNECTION_URL="mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:$HOST_PORT/?authSource=admin"
  echo "MongoDB single instance running."
  echo "Connection URL: $CONNECTION_URL"
else
  # Initiate replica set on the first container
  docker exec -it "${CONTAINER_NAME}-1" mongosh -u "$MONGO_USERNAME" -p "$MONGO_PASSWORD" --authenticationDatabase admin "$INIT_FILE"

  CONNECTION_URL="mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@localhost:$HOST_PORT/?replicaSet=rs0&authSource=admin"
  echo "MongoDB replica set with $NUM_CONTAINERS nodes running."
  echo "Connection URL: $CONNECTION_URL"
fi
