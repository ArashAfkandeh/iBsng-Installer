#!/bin/bash

# ============================================================================================= #
# IBSng automatic installation script in Docker                                                 #
# This script is designed for Ubuntu 22.04 systems and                                          #
# uses the pre-built IBSng image based on CentOS 7 from the Docker Hub repository.              #
# By running this file, Docker and Docker Compose will be installed, and then the IBSng service #
# will be launched in a container with configurable ports and persistent data.                  #
#                                                                                              #
# A new optional argument allows specifying a public domain name; if provided the script will   #
# automatically install and configure Caddy as a reverse‑proxy to provide HTTPS (Let’s Encrypt) #
# for the IBSng web panel.                                                                     #
# ============================================================================================= #

# Check if running as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Please use sudo or log in as the root user."
  exit 1
fi

set -euo pipefail

# Function to print step titles
print_step() {
  echo -e "\n----------------------------------------------"
  echo "$1"
  echo "----------------------------------------------"
}

# --- START: Port Check Function ---
# Move function to the top so we can use it during input phase
check_port() {
  local port=$1
  local proto=$2

  # Use ss (or netstat as fallback) to check for listening ports
  if command -v ss &> /dev/null; then
    # ss is faster and more modern
    if [ "$proto" = "udp" ]; then
      if ss -lnu | grep -q ":${port}"; then
        return 1 # Port is in use
      fi
    else
      if ss -lnt | grep -q ":${port}"; then
        return 1 # Port is in use
      fi
    fi
  elif command -v netstat &> /dev/null; then
    # Fallback to netstat if ss is not available
    local proto_flag=""
    if [ "$proto" = "udp" ]; then
      proto_flag="u"
    else
      proto_flag="t"
    fi
    if netstat -ln${proto_flag} | grep -q ":${port} "; then
      return 1 # Port is in use
    fi
  fi
  return 0 # Port is free
}
# --- END: Port Check Function ---

# --- START: Collect Interactive Inputs ---
print_step "Collecting Interactive Inputs"

# --- START: Host Network Port Validation ---
# Define default ports
DEFAULT_WEB_PORT=80
DEFAULT_RADIUS_AUTH_PORT=1812
DEFAULT_RADIUS_ACCT_PORT=1813

# Function to read input with timeout and return clean value
read_with_timeout() {
    local prompt="$1"
    local default_value="$2"
    local timeout=60
    local response

    # Show the prompt with colored lines and clear instructions
    echo -e "\e[34m--------------------------------------------------\e[0m" >&2
    echo -e "\e[33m${prompt}\e[0m" >&2
    echo -e "\e[32mYou have ${timeout} seconds to enter a custom port or press Enter to use default (${default_value}).\e[0m" >&2
    echo -e "\e[34m--------------------------------------------------\e[0m" >&2
    
    # Use read with timeout, reading directly from terminal
    if read -t "$timeout" -r -p "${prompt}: " response </dev/tty 2>/dev/null; then
        # Input was provided within timeout (including empty input)
        if [ -z "$response" ]; then
            echo -e "\e[32mUsing default value: $default_value\e[0m" >&2
            echo "$default_value"
        elif ! [[ "$response" =~ ^[0-9]+$ ]]; then
            echo -e "\e[31mInvalid input, using default value: $default_value\e[0m" >&2
            echo "$default_value"
        else
            echo -e "\e[32mUsing custom value: $response\e[0m" >&2
            echo "$response"
        fi
    else
        # Only timeout occurred (not user pressing Enter)
        echo "" >&2
        echo -e "\e[31mTimeout reached, using default value: $default_value\e[0m" >&2
        echo "$default_value"
    fi
}

# Check command line arguments first (1st=web, 2nd=auth, 3rd=acct, 4th/5th=telegram, 6th=domain_direct, 7th=domain_tunnel)
WEB_PORT=${1:-""}
RADIUS_AUTH_PORT=${2:-""}
RADIUS_ACCT_PORT=${3:-""}
# note: token/chat handled later, domains captured here
DOMAIN_DIRECT=${6:-""}
DOMAIN_TUNNEL=${7:-""}

# If any port is not provided in arguments, ask interactively
if [ -z "$WEB_PORT" ]; then
  echo -e "\e[31mWeb port not provided in arguments.\e[0m"
  WEB_PORT=$(read_with_timeout "Enter Web Panel Port (e.g., 80)" "$DEFAULT_WEB_PORT")
  # Clean the result immediately
  WEB_PORT=$(echo "$WEB_PORT" | tr -d '\n\r\t ' | grep -o '^[0-9]*')
  WEB_PORT="${WEB_PORT:-$DEFAULT_WEB_PORT}"
fi

if [ -z "$RADIUS_AUTH_PORT" ]; then
  echo -e "\e[31mRADIUS Authentication port not provided in arguments.\e[0m"
  RADIUS_AUTH_PORT=$(read_with_timeout "Enter RADIUS Authentication Port (e.g., 1812)" "$DEFAULT_RADIUS_AUTH_PORT")
  # Clean the result immediately
  RADIUS_AUTH_PORT=$(echo "$RADIUS_AUTH_PORT" | tr -d '\n\r\t ' | grep -o '^[0-9]*')
  RADIUS_AUTH_PORT="${RADIUS_AUTH_PORT:-$DEFAULT_RADIUS_AUTH_PORT}"
fi

if [ -z "$RADIUS_ACCT_PORT" ]; then
  echo -e "\e[31mRADIUS Accounting port not provided in arguments.\e[0m"
  RADIUS_ACCT_PORT=$(read_with_timeout "Enter RADIUS Accounting Port (e.g., 1813)" "$DEFAULT_RADIUS_ACCT_PORT")
  # Clean the result immediately
  RADIUS_ACCT_PORT=$(echo "$RADIUS_ACCT_PORT" | tr -d '\n\r\t ' | grep -o '^[0-9]*')
  RADIUS_ACCT_PORT="${RADIUS_ACCT_PORT:-$DEFAULT_RADIUS_ACCT_PORT}"
fi

# --- domains handling (Fixed to prevent absorbing script comments as input) ---
if [ -z "$DOMAIN_DIRECT" ]; then
  echo -e "\e[31mDirect Domain name not provided in arguments.\e[0m"
  # ask user directly from terminal; leaving blank will skip
  if read -r -p "Enter Direct domain name for Caddy (e.g. direct.example.com) or leave blank to skip: " DOMAIN_DIRECT </dev/tty 2>/dev/null; then
    DOMAIN_DIRECT=$(echo "$DOMAIN_DIRECT" | tr -d ' \t\n\r')
  else
    DOMAIN_DIRECT=""
  fi
fi

if [ -z "$DOMAIN_TUNNEL" ]; then
  echo -e "\e[31mTunnel Domain name not provided in arguments.\e[0m"
  # ask user directly from terminal; leaving blank will skip
  if read -r -p "Enter Tunnel domain name for Caddy (e.g. tunnel.example.com) or leave blank to skip: " DOMAIN_TUNNEL </dev/tty 2>/dev/null; then
    DOMAIN_TUNNEL=$(echo "$DOMAIN_TUNNEL" | tr -d ' \t\n\r')
  else
    DOMAIN_TUNNEL=""
  fi
fi

# Export domains
export DOMAIN_DIRECT DOMAIN_TUNNEL

# --- Smart Port Conflict Prevention for Caddy/HTTPS ---
if [ -n "$DOMAIN_DIRECT" ] || [ -n "$DOMAIN_TUNNEL" ]; then
  if [ "$WEB_PORT" = "80" ]; then
    echo -e "\e[33mWarning: You specified a domain name for HTTPS, which requires Caddy to use port 80.\e[0m"
    echo -e "\e[33mIBSng cannot also use port 80 on the host. Finding an alternative free port...\e[0m"
    
    TEMP_PORT=8080
    while ! check_port $TEMP_PORT "tcp"; do
      TEMP_PORT=$((TEMP_PORT + 1))
    done
    WEB_PORT=$TEMP_PORT
    echo -e "\e[32mIBSng host web port has been automatically adjusted to: ${WEB_PORT}\e[0m"
  fi
fi

# Export cleaned variables
export WEB_PORT RADIUS_AUTH_PORT RADIUS_ACCT_PORT

# Show selected ports
echo ""
echo -e "\e[34m--------------------------------------------------\e[0m"
echo -e "\e[33mSelected ports:\e[0m"
echo -e "\e[32mWeb Panel Port: ${WEB_PORT}\e[0m"
echo -e "\e[32mRADIUS Authentication Port: ${RADIUS_AUTH_PORT}\e[0m"
echo -e "\e[32mRADIUS Accounting Port: ${RADIUS_ACCT_PORT}\e[0m"

# Show domains if any
if [ -n "$DOMAIN_DIRECT" ]; then
    echo -e "\e[32mDirect Domain: ${DOMAIN_DIRECT}\e[0m"
else
    echo -e "\e[32mDirect Domain: (none)\e[0m"
fi

if [ -n "$DOMAIN_TUNNEL" ]; then
    echo -e "\e[32mTunnel Domain: ${DOMAIN_TUNNEL}\e[0m"
else
    echo -e "\e[32mTunnel Domain: (none)\e[0m"
fi

echo -e "\e[34m--------------------------------------------------\e[0m"
# --- END: Host Network Port Validation ---

# --- START: Telegram Bot Config (Interactive Part) ---
print_step "Configuring Telegram Bot for Backups (Optional)"
echo -e "\e[34m--------------------------------------------------\e[0m"
echo -e "\e[33mYou can provide credentials as arguments: ./script.sh [args...] <TOKEN> <CHAT_ID>\e[0m"
echo -e "\e[32mYou will be prompted to enter the Telegram Bot Token and Chat ID if not provided as arguments.\e[0m"
echo -e "\e[34m--------------------------------------------------\e[0m"

# Define the timeout for interactive prompts
TIMEOUT=120

# Initialize variables to be empty
TELEGRAM_BOT_TOKEN=""
CHAT_ID=""

# Function to read Telegram input with timeout
read_telegram_input() {
    local prompt="$1"
    local timeout="$2"
    local response

    # Show the prompt with colored lines and specific instructions
    echo -e "\e[34m--------------------------------------------------\e[0m" >&2
    echo -e "\e[33m${prompt}\e[0m" >&2
    if [[ "$prompt" == *"Bot Token"* ]]; then
        echo -e "\e[32mGet your Telegram Bot Token from \e[36mt.me/BotFather\e[32m. You have ${timeout} seconds to enter the value or press Enter to skip.\e[0m" >&2
    else
        echo -e "\e[32mGet your Telegram Chat ID from \e[36mt.me/chatIDrobot\e[32m. You have ${timeout} seconds to enter the value or press Enter to skip.\e[0m" >&2
    fi
    echo -e "\e[34m--------------------------------------------------\e[0m" >&2
    
    # Use read with timeout, reading directly from terminal
    if read -t "$timeout" -r -p "${prompt}: " response </dev/tty 2>/dev/null; then
        # Input was provided within timeout (including empty input for skip)
        if [ -z "$response" ]; then
            echo -e "\e[32mSkipped.\e[0m" >&2
            echo ""
        else
            echo -e "\e[32mValue received.\e[0m" >&2
            echo "$response"
        fi
    else
        # Only timeout occurred
        echo "" >&2
        echo -e "\e[31mTimeout reached, skipping.\e[0m" >&2
        echo ""
    fi
}

# Check if both token and chat_id are provided as command-line arguments
if [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
  echo -e "\e[32mUsing Telegram Bot Token and Chat ID from command-line arguments.\e[0m"
  TELEGRAM_BOT_TOKEN="$4"
  CHAT_ID="$5"
else
  # If arguments are not provided, switch to interactive mode
  echo -e "\e[33mProceeding with interactive setup (${TIMEOUT}s timeout per prompt).\e[0m"

  # Prompt for the Telegram Bot Token with a timeout
  TELEGRAM_BOT_TOKEN=$(read_telegram_input "Enter Telegram Bot Token" "$TIMEOUT")

  # Only ask for Chat ID if a Token was provided
  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    CHAT_ID=$(read_telegram_input "Enter your Telegram Chat ID" "$TIMEOUT")
    
    # If chat ID is empty, clear the token as well
    if [ -z "$CHAT_ID" ]; then
      echo -e "\e[31mChat ID not provided, clearing Telegram configuration.\e[0m"
      TELEGRAM_BOT_TOKEN=""
    fi
  fi
fi
# --- END: Telegram Bot Config (Interactive Part) ---
# --- END: Collect Interactive Inputs ---

# Update package list and install prerequisites
print_step "Updating package list and installing prerequisites"
sudo apt update -y

# Configuration for needrestart
print_step "Configuring needrestart for non-interactive mode"
sudo sed -i 's/^#\$nrconf{restart} = .*/\$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf || echo "Configuration of needrestart failed"

# Remove old versions of Docker if they exist
for pkg in docker docker.io containerd runc; do
    apt-get remove -y $pkg || true
done

# Install prerequisites
apt-get install -y git jq ca-certificates curl gnupg lsb-release python3-pip python3-venv dialog whiptail apt-utils

# If any domain has been specified, install Caddy for reverse proxy/SSL
if [ -n "$DOMAIN_DIRECT" ] || [ -n "$DOMAIN_TUNNEL" ]; then
  print_step "Installing Caddy web server"
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https || true
  
  # Clean up any potential stale files from previous failed runs
  rm -f /etc/apt/trusted.gpg.d/caddy-stable.asc 2>/dev/null || true
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
  
  # add Caddy's GPG key in official binary dearmor format and then add repo list
  mkdir -p /usr/share/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  
  apt-get update
  if ! apt-get install -y caddy; then
      echo "Warning: apt failed to install caddy, trying snap as a fallback"
      if command -v snap >/dev/null 2>&1; then
          snap install caddy --classic || echo "snap install failed too"
      else
          echo "snap is not available; please install Caddy manually"
      fi
  fi
fi

# Manage CA certificates to avoid rehash warning
print_step "Configuring CA certificates"
TEMP_CERT_DIR="/tmp/ca-certificates"
mkdir -p "$TEMP_CERT_DIR"
if cp /etc/ssl/certs/*.pem "$TEMP_CERT_DIR" 2>/dev/null; then
    if command -v c_rehash >/dev/null; then
        c_rehash "$TEMP_CERT_DIR" >/dev/null || echo "Warning: Failed to run c_rehash on certificates" >&2
    else
        echo "Warning: c_rehash not found, skipping certificate hashing" >&2
    fi
    rm -rf "$TEMP_CERT_DIR"
else
    echo "Warning: No individual .pem certificates found, skipping custom certificate processing" >&2
fi

if [ -d "iBsng-Installer" ]; then
    rm -rf iBsng-Installer
fi

if ! git clone https://github.com/ArashAfkandeh/iBsng-Installer.git; then
    echo "Error cloning repository, continuing..."
fi

# Create and activate virtual environment
VENV_DIR="/opt/ibsng/venv"
print_step "Setting up Python virtual environment"
if ! python3 -m venv "$VENV_DIR"; then
    echo "Error: Failed to create virtual environment. Ensure python3-venv is installed."
    echo "Try running: sudo apt install python3-venv"
    exit 1
fi
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "Error: Virtual environment was not created successfully at $VENV_DIR"
    exit 1
fi
source "$VENV_DIR/bin/activate"

# Install Python dependencies using the venv's pip
if ! "$VENV_DIR/bin/python3" -m pip install pyTelegramBotAPI jdatetime; then
    echo "Error: Failed to install Python dependencies in the virtual environment"
    deactivate
    exit 1
fi

deactivate

# Add Docker's official GPG key and register the stable repository
print_step "Adding the official Docker repository"
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and the Compose plugin
print_step "Installing Docker and the Docker Compose plugin"
apt update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start the Docker service
systemctl enable docker
systemctl start docker

# Pull the IBSng image from Docker Hub
print_step "Pulling IBSng image from Docker Hub"
IMAGE_NAME="epsil0n/ibsng:1.25"
docker pull "$IMAGE_NAME"

# Create paths for persistent data storage
BASE_DIR="/opt/ibsng"
DATA_DIR="${BASE_DIR}/pgsql"
BACKUP_DIR="${BASE_DIR}/backup_ibsng"
LOGS_DIR="${BASE_DIR}/logs"
mkdir -p "$BASE_DIR" "$DATA_DIR" "$BACKUP_DIR" "$LOGS_DIR"

# Initialize persistent PostgreSQL data if it doesn't already exist
if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
  print_step "Initializing PostgreSQL data directory from the IBSng image"
  mkdir -p "$DATA_DIR"
  docker rm -f ibsng_tmp 2>/dev/null || true
  docker run --name ibsng_tmp -d "$IMAGE_NAME"

  echo "Waiting for the temporary container to complete initial database setup..."
  for i in {1..20}; do
    if docker exec ibsng_tmp pgrep -x postgres > /dev/null 2>&1; then
      sleep 5
      break
    fi
    echo -n "#"
    sleep 1
  done
  echo ""

  echo "Copying database files from container to host at $DATA_DIR..."
  docker cp ibsng_tmp:/var/lib/pgsql/. "$DATA_DIR/"
  chown -R 26:26 "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  docker rm -f ibsng_tmp
  echo "Initial database extracted successfully. Persistent data directory prepared."
else
  echo "Database directory already exists, skipping initialization."
fi

# --- START: Host Network Port Validation ---
print_step "Validating Required Ports for IBSng Container"

# Configure firewall rules if UFW is active
print_step "Configuring Firewall (UFW)"
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
  echo "UFW is active. Opening necessary ports..."
  
  ufw allow ${WEB_PORT}/tcp comment 'IBSng Web Panel'
  echo "Allowed port ${WEB_PORT}/tcp for Web Panel"
  
  ufw allow ${RADIUS_AUTH_PORT}/udp comment 'IBSng RADIUS Auth'
  echo "Allowed port ${RADIUS_AUTH_PORT}/udp for RADIUS Authentication"

  ufw allow ${RADIUS_ACCT_PORT}/udp comment 'IBSng RADIUS Acct'
  echo "Allowed port ${RADIUS_ACCT_PORT}/udp for RADIUS Accounting"
  
  # if we are managing domains, open HTTP/HTTPS for Caddy
  if [ -n "$DOMAIN_DIRECT" ] || [ -n "$DOMAIN_TUNNEL" ]; then
    ufw allow 80/tcp comment 'Caddy HTTP'
    ufw allow 443/tcp comment 'Caddy HTTPS'
    echo "Allowed ports 80 and 443 for Caddy reverse proxy"
  fi
else
  echo "UFW is not installed or is inactive. Skipping firewall configuration."
fi

# Validate each required port
if ! check_port ${WEB_PORT} "tcp"; then
  HAS_ANY_DOMAIN=0
  if [ -n "$DOMAIN_DIRECT" ] || [ -n "$DOMAIN_TUNNEL" ]; then
     HAS_ANY_DOMAIN=1
  fi
  if [ "$HAS_ANY_DOMAIN" -eq 1 ] && [ "$WEB_PORT" = "80" ]; then
     echo "Caddy is utilizing port 80. Port translation handled via reverse proxy."
  else
     echo "Error: Port ${WEB_PORT}/tcp is already in use on this server."
     echo "Please stop the conflicting service or use a different installation method."
     exit 1
  fi
fi
if ! check_port ${RADIUS_AUTH_PORT} "udp"; then
  echo "Error: Port ${RADIUS_AUTH_PORT}/udp is already in use on this server."
  echo "Please stop the conflicting service or use a different installation method."
  exit 1
fi
if ! check_port ${RADIUS_ACCT_PORT} "udp"; then
  echo "Error: Port ${RADIUS_ACCT_PORT}/udp is already in use on this server."
  echo "Please stop the conflicting service or use a different installation method."
  exit 1
fi

echo "All required ports (${WEB_PORT}/tcp, ${RADIUS_AUTH_PORT}/udp, ${RADIUS_ACCT_PORT}/udp) are available/configured."
# --- END: Host Network Port Validation ---

# --- START: Docker Compose creation ---
print_step "Creating docker-compose.yml in ${BASE_DIR}"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

cat <<EOF > "$COMPOSE_FILE"
services:
  ibsng:
    image: ${IMAGE_NAME}
    container_name: ibsng
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:80"
      - "${RADIUS_AUTH_PORT}:1812/udp"
      - "${RADIUS_ACCT_PORT}:1813/udp"
    volumes:
      - "${DATA_DIR}:/var/lib/pgsql"
      - "${LOGS_DIR}:/var/log/IBSng"
EOF

echo "docker-compose.yml with bridge port mapping and logs volume created successfully."

# Set proper permissions for logs directory
print_step "Setting permissions for logs directory"
chown -R 48:48 "$LOGS_DIR"
chmod -R 755 "$LOGS_DIR"
echo "Logs directory permissions configured for Apache user (UID 48)"

# Run the service using Docker Compose
print_step "Running the IBSng service with Docker Composer"
if [ -n "$(docker compose -f "${COMPOSE_FILE}" ps -q -a)" ]; then
    echo "Found existing containers for project 'ibsng'. Stopping and removing them..."
    if ! docker compose -f "${COMPOSE_FILE}" down --remove-orphans; then
        echo "Error: Failed to stop existing containers" >&2
        exit 1
    fi
else
    echo "No existing containers found for project 'ibsng'. Proceeding with startup..."
fi
docker compose -f "${COMPOSE_FILE}" up -d

echo "Waiting for service to start..."
sleep 15

echo "Restarting service to ensure proper database connection..."
docker compose -f "${COMPOSE_FILE}" restart

echo "Waiting for service restart to complete..."
sleep 10

echo "IBSng service is now running and ready."

# --- configure Caddy if any domain was provided ---
if [ -n "$DOMAIN_DIRECT" ] || [ -n "$DOMAIN_TUNNEL" ]; then
  print_step "Configuring Caddy"
  
  # Clear existing configurations
  echo -n "" > /etc/caddy/Caddyfile
  
  if [ -n "$DOMAIN_DIRECT" ]; then
    cat <<EOF >> /etc/caddy/Caddyfile
${DOMAIN_DIRECT} {
    reverse_proxy 127.0.0.1:${WEB_PORT}
}
EOF
  fi

  if [ -n "$DOMAIN_TUNNEL" ]; then
    cat <<EOF >> /etc/caddy/Caddyfile
${DOMAIN_TUNNEL} {
    reverse_proxy 127.0.0.1:${WEB_PORT}
}
EOF
  fi

  # reload the service so it picks up new configuration
  if systemctl is-enabled --quiet caddy; then
      systemctl reload caddy || systemctl restart caddy
  else
      systemctl enable --now caddy
  fi
  echo "Caddy has been configured and is serving dockets/domains.";
fi
# --- END: Docker Compose creation ---

# Set the timezone to Asia/Tehran
sudo timedatectl set-timezone Asia/Tehran

SOURCE_DIR="/root/iBsng-Installer"

# List of essential files to copy
ESSENTIAL_FILES=(
    "backup_ibsng.sh"
    "bot.py"
    "restore_ibsng.sh"
)

# Copy each file with error handling
for file in "${ESSENTIAL_FILES[@]}"; do
    if [ -f "$SOURCE_DIR/$file" ]; then
        if ! cp "$SOURCE_DIR/$file" "$BACKUP_DIR/"; then
            echo "Error: Failed to copy $file" >&2
        else
            if ! chmod +x "$BACKUP_DIR/$file"; then
                echo "Warning: Failed to make $file executable" >&2
            fi
        fi
    else
        echo "Warning: Source file $file not found" >&2
    fi
done

# Final check: Create the config file only if BOTH variables have a value
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
  CONFIG_FILE="${BACKUP_DIR}/config.json"

  cat <<EOF > "$CONFIG_FILE"
{
  "bot_token": "$TELEGRAM_BOT_TOKEN",
  "chat_id": "$CHAT_ID"
}
EOF

  chmod 600 "$CONFIG_FILE"
  echo -e "\e[32mTelegram configuration has been successfully saved to ${CONFIG_FILE}\e[0m"
else
  echo -e "\e[31mTelegram Token or Chat ID not provided. Skipping Telegram configuration.\e[0m"
fi

# --- START: Service Installation ---
print_step "Installing and Enabling Backup Service"

if ! sudo tee /etc/systemd/system/ibsng-backup.service > /dev/null << EOL
[Unit]
Description=IBSng Backup Service with Telegram Integration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${VENV_DIR}/bin/python3 ${BACKUP_DIR}/bot.py
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL
then
    echo "Error: Failed to create service file" >&2
else
    sudo chmod 640 /etc/systemd/system/ibsng-backup.service || echo "Warning: Failed to set permissions" >&2
    sudo chown root:root /etc/systemd/system/ibsng-backup.service || echo "Warning: Failed to set ownership" >&2

    if ! sudo systemctl daemon-reload; then
        echo "Error: Failed to reload systemd daemon" >&2
    fi
    
    if ! sudo systemctl enable ibsng-backup.service; then
        echo "Error: Failed to enable service" >&2
    fi
    
    if ! sudo systemctl start ibsng-backup.service; then
        echo "Error: Failed to start service" >&2
    fi
fi
# --- END: Service Installation ---

# --- START: Cleanup Source Directory ---
print_step "Cleaning up source directory"

if [ -d "$SOURCE_DIR" ]; then
    echo "Removing source directory: $SOURCE_DIR"
    if ! sudo rm -rf "$SOURCE_DIR"; then
        echo "Error: Failed to remove source directory" >&2
    else
        echo "Source directory successfully removed"
    fi
else
    echo "Source directory not found, skipping removal"
fi
# --- END: Cleanup Source Directory ---

echo "Script execution completed (with any possible warnings)"

# Extract the server's IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

# Pre-check: Evaluate backup service status early
SERVICE_NAME="ibsng-backup.service"
SERVICE_DISPLAY_NAME="IBSng Backup Bot"
SERVICE_STATUS=$(systemctl is-active "$SERVICE_NAME")

# Display system access information in a clean and user-friendly format

print_step "🎯 System Access Information"

echo -e "\n📁 To manage the service, navigate to '\e[34m${BASE_DIR}\e[0m' and use the following commands:"
echo -e "   🛑 Stop the service: \e[33mdocker compose down\e[0m"
echo -e "   ▶️ Start the service: \e[32mdocker compose up -d\e[0m"
echo -e "   📜 View logs: \e[36mdocker compose logs -f\e[0m"

echo -e "\n✅ IBSng has been successfully installed on this server."

echo -e "\n🌐 Admin Panel Access:"
if [ -n "$DOMAIN_DIRECT" ]; then
  echo -e "   🔗 Direct URL: \e[32mhttps://${DOMAIN_DIRECT}/IBSng/admin/\e[0m"
fi
if [ -n "$DOMAIN_TUNNEL" ]; then
  echo -e "   🔗 Tunnel URL: \e[32mhttps://${DOMAIN_TUNNEL}/IBSng/admin/\e[0m"
fi
if [ -z "$DOMAIN_DIRECT" ] && [ -z "$DOMAIN_TUNNEL" ]; then
  echo -e "   🔗 URL: \e[32mhttp://${SERVER_IP}:${WEB_PORT}/IBSng/admin/\e[0m"
fi

echo -e "   👤 Default Username: \e[33msystem\e[0m"
echo -e "   🔑 Default Password: \e[31madmin\e[0m"

echo -e "\n📡 RADIUS & Web Panel Ports:"
echo -e "   🌐 IBSng Web Panel Port (TCP): \e[36m${WEB_PORT}\e[0m"
echo -e "   🔐 RADIUS Authentication Port (UDP): \e[36m${RADIUS_AUTH_PORT}\e[0m"
echo -e "   📊 RADIUS Accounting Port (UDP): \e[36m${RADIUS_ACCT_PORT}\e[0m"

echo -e "\n📋 Log Files:"
echo -e "   📂 Logs Directory: \e[36m${LOGS_DIR}\e[0m"
echo -e "   💡 Tip: Use '\e[33mtail -f ${LOGS_DIR}/*.log\e[0m' to monitor logs in real-time"

# Display backup bot service status with friendly name
if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "\n🤖 ${SERVICE_DISPLAY_NAME} Status: \e[32mRunning\e[0m"
else
    echo -e "\n⚠️ ${SERVICE_DISPLAY_NAME} Status: \e[31mNot Active\e[0m"
fi

echo -e "\n🎉 You're all set and ready to go!"
echo ""
