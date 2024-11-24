#!/bin/bash

# Check if domain name is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <domain_name> [port_number]"
  exit 1
fi

DOMAIN=$1
PORT=$2

# Update package list
sudo apt update

# Check if nginx is installed, if not install it
if ! dpkg -l | grep -q nginx; then
  sudo apt install -y nginx
fi

# Install certbot
sudo apt install -y certbot python3-certbot-nginx

# Create directory for the domain if it doesn't exist
if [ ! -d "/var/www/$DOMAIN" ]; then
  sudo mkdir -p /var/www/$DOMAIN
fi

# Create the Nginx config file
CONFIG_FILE="/etc/nginx/sites-available/$DOMAIN"

if [ -z "$PORT" ]; then
  # Default server block
  cat <<EOL | sudo tee $CONFIG_FILE
server {
    root /var/www/$DOMAIN;
    index index.html index.htm index.nginx-debian.html;
    server_name $DOMAIN www.$DOMAIN;

    location / {
      try_files \$uri \$uri/ /index.html;
    }
}
EOL
else
  # Proxy server block
  cat <<EOL | sudo tee $CONFIG_FILE
server {
  server_name $DOMAIN www.$DOMAIN;
  location / {
    proxy_pass http://127.0.0.1:$PORT;
    proxy_pass_header       Access-Control-Allow-Origin;
    proxy_set_header        X-Real-IP \$remote_addr;
    proxy_set_header        Host \$http_host;
    proxy_set_header        X-NginX-Proxy true;
    proxy_pass_header       Set-Cookie;
    proxy_pass_header       X-UA-Compatible;
    proxy_pass_header       Server;
    proxy_http_version      1.1;
    proxy_set_header        Upgrade \$http_upgrade;
    proxy_set_header        Connection \$http_connection;
    proxy_read_timeout      300s;
    proxy_connect_timeout   300s;
    proxy_redirect          off;
    proxy_request_buffering off;
    proxy_buffering         off;
    proxy_buffer_size       256K;
    proxy_buffers 16        128K;
    proxy_busy_buffers_size 256K;
    proxy_temp_file_write_size 256K;
    client_max_body_size   100m;
  }
}
EOL
fi

# Enable the site
sudo ln -s $CONFIG_FILE /etc/nginx/sites-enabled/

# Restart Nginx
sudo systemctl restart nginx

# Run certbot to configure SSL
sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN

