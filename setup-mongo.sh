#!/bin/bash

# Exit on errors
set -e

# --- Input validation ---
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <admin-username> <admin-password>"
  exit 1
fi

ADMIN_USER=$1
ADMIN_PASS=$2

# --- Cleanup old MongoDB if installed ---
echo "➡️ Removing existing MongoDB installation (if any)..."
sudo systemctl stop mongod || true
sudo apt purge -y mongodb-org* || true
sudo rm -rf /var/log/mongodb /var/lib/mongodb
sudo rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list
sudo apt autoremove -y

# --- Add MongoDB 7.0 repo using jammy for Ubuntu 24.04 ---
echo "➡️ Adding MongoDB 7.0 repository for Ubuntu 22.04 (jammy)..."
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

# --- Install MongoDB ---
echo "➡️ Installing MongoDB..."
sudo apt update
sudo apt install -y mongodb-org

# --- Start MongoDB temporarily (without auth) to create admin user ---
echo "➡️ Starting MongoDB..."
sudo systemctl enable mongod
sudo systemctl start mongod
sleep 5

# --- Create root admin user ---
echo "➡️ Creating admin user with root privileges..."
mongosh <<EOF
use admin
db.createUser({
  user: "$ADMIN_USER",
  pwd: "$ADMIN_PASS",
  roles: [ { role: "root", db: "admin" } ]
})
EOF

# --- Enable authentication globally ---
echo "➡️ Enabling authentication for all users..."
if ! grep -q "^security:" /etc/mongod.conf; then
  echo -e "\nsecurity:\n  authorization: \"enabled\"" | sudo tee -a /etc/mongod.conf
else
  sudo sed -i '/^security:/,/^[^ ]/ s/^  authorization:.*$/  authorization: "enabled"/' /etc/mongod.conf
fi

# --- Restart MongoDB with auth ---
echo "➡️ Restarting MongoDB with authentication enabled..."
sudo systemctl restart mongod
sleep 5

# --- Test the admin connection ---
echo "➡️ Testing authenticated connection..."
mongosh "mongodb://$ADMIN_USER:$ADMIN_PASS@localhost:27017/admin?authSource=admin" --eval "db.runCommand({ connectionStatus: 1 })"

# --- Print connection string ---
echo ""
echo "✅ MongoDB setup complete with authentication enabled for all users."
echo "Use this connection string:"
echo ""
echo "mongosh 'mongodb://$ADMIN_USER:$ADMIN_PASS@example.domain.com:27017/admin?authSource=admin'"
