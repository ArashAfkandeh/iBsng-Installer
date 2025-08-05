#!/bin/bash

# ============================================================================================= #
# IBSng automatic installation script in Docker                                                 #
# This script is designed for Ubuntu 22.04 systems and                                          #
# uses the pre-built IBSng image based on CentOS 7 from the Docker Hub repository.              #
# By running this file, Docker and Docker Compose will be installed, and then the IBSng service #
# will be launched in a container with configurable ports and persistent data.                  #
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

# Check command line arguments first (1st=web, 2nd=auth, 3rd=acct)
WEB_PORT=${1:-""}
RADIUS_AUTH_PORT=${2:-""}
RADIUS_ACCT_PORT=${3:-""}

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

# Export cleaned variables
export WEB_PORT RADIUS_AUTH_PORT RADIUS_ACCT_PORT

# Show selected ports
echo ""
echo -e "\e[34m--------------------------------------------------\e[0m"
echo -e "\e[33mSelected ports:\e[0m"
echo -e "\e[32mWeb Panel Port: ${WEB_PORT}\e[0m"
echo -e "\e[32mRADIUS Authentication Port: ${RADIUS_AUTH_PORT}\e[0m"
echo -e "\e[32mRADIUS Accounting Port: ${RADIUS_ACCT_PORT}\e[0m"
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

# Remove old versions of Docker if they exist
for pkg in docker docker.io containerd runc; do
    apt-get remove -y $pkg || true
done

# Install prerequisites
apt-get install -y git jq ca-certificates curl gnupg lsb-release python3-pip python3-venv dialog whiptail apt-utils

# Manage CA certificates to avoid rehash warning
print_step "Configuring CA certificates"
# Create a temporary directory for certificate processing
TEMP_CERT_DIR="/tmp/ca-certificates"
mkdir -p "$TEMP_CERT_DIR"
# Copy individual certificates to avoid processing ca-certificates.crt
if cp /etc/ssl/certs/*.pem "$TEMP_CERT_DIR" 2>/dev/null; then
    # Run c_rehash on individual certificates
    if command -v c_rehash >/dev/null; then
        c_rehash "$TEMP_CERT_DIR" >/dev/null || echo "Warning: Failed to run c_rehash on certificates" >&2
    else
        echo "Warning: c_rehash not found, skipping certificate hashing" >&2
    fi
    # Clean up temporary directory
    rm -rf "$TEMP_CERT_DIR"
else
    echo "Warning: No individual .pem certificates found, skipping custom certificate processing" >&2
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

# Install Python dependencies in the virtual environment
if ! pip3 install pyTelegramBotAPI jdatetime; then
    echo "Error: Failed to install Python dependencies in the virtual environment"
    deactivate
    exit 1
fi

# Deactivate the virtual environment after installation
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
# First, we define the base directory, database path, and backup directory
BASE_DIR="/opt/ibsng"
DATA_DIR="${BASE_DIR}/pgsql"
BACKUP_DIR="${BASE_DIR}/backup_ibsng"
mkdir -p "$BASE_DIR" "$DATA_DIR" "$BACKUP_DIR"

# ----------------------------------------------------------------------------
# Initialize persistent PostgreSQL data if it doesn't already exist
#
# The IBSng Docker image already contains a pre-initialized PostgreSQL cluster
# populated with the IBSng schema and the default "ibs" user.  Attempting to
# re-run `initdb` or manually create the database inside the container can
# result in permission errors and "database does not exist" messages during
# installation.  To ensure the host has a copy of this pre-built data for
# persistence, we spin up a temporary container, allow it to initialise the
# database using its own entrypoint (run.sh), then copy the resulting
# `/var/lib/pgsql` directory out to the host.  On subsequent runs we simply
# re-use the existing host data.
if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
  print_step "Initializing PostgreSQL data directory from the IBSng image"

  # Ensure target directory exists
  mkdir -p "$DATA_DIR"

  # Remove any previous temporary container
  docker rm -f ibsng_tmp 2>/dev/null || true

  # Start a throwaway container in the background.  Do not mount the host
  # directory yet; we want the container to start with its internal data so
  # that the entrypoint script can perform its own initialization.
  docker run --name ibsng_tmp -d "$IMAGE_NAME"

  echo "Waiting for the temporary container to complete initial database setup..."
  # Poll for the presence of a running postgres process.  Once the process
  # exists, we assume the initialisation phase has finished.
  for i in {1..20}; do
    if docker exec ibsng_tmp pgrep -x postgres > /dev/null 2>&1; then
      # Give the service a little extra time to finish writing files
      sleep 5
      break
    fi
    echo -n "#"
    sleep 1
  done
  echo ""

  # Copy the fully initialized database directory to the host.  We use the
  # trailing `.` to copy the contents rather than the parent folder itself.
  echo "Copying database files from container to host at $DATA_DIR..."
  docker cp ibsng_tmp:/var/lib/pgsql/. "$DATA_DIR/"

  # Set ownership and permissions so the PostgreSQL user inside the container
  # (UID 26) can read/write the data.  We deliberately avoid chmod 777; the
  # service requires 700 on the data directory for security.
  chown -R 26:26 "$DATA_DIR"
  chmod 700 "$DATA_DIR"

  # Remove the temporary container now that the data has been extracted
  docker rm -f ibsng_tmp

  echo "Initial database extracted successfully.  Persistent data directory prepared."
else
  echo "Database directory already exists, skipping initialization."
fi

# --- START: Host Network Port Validation ---
print_step "Validating Required Ports for Host Network Mode"

# Function to check if a port is in use
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
  else
    echo "Warning: Neither 'ss' nor 'netstat' found. Cannot check for port conflicts."
  fi
  return 0 # Port is free
}

# Configure firewall rules if UFW is active
print_step "Configuring Firewall (UFW)"
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
  echo "UFW is active. Opening necessary ports..."
  
  # Allow Web Port (TCP)
  ufw allow ${WEB_PORT}/tcp comment 'IBSng Web Panel'
  echo "Allowed port ${WEB_PORT}/tcp for Web Panel"
  
  # Allow RADIUS Authentication Port (UDP)
  ufw allow ${RADIUS_AUTH_PORT}/udp comment 'IBSng RADIUS Auth'
  echo "Allowed port ${RADIUS_AUTH_PORT}/udp for RADIUS Authentication"

  # Allow RADIUS Accounting Port (UDP)
  ufw allow ${RADIUS_ACCT_PORT}/udp comment 'IBSng RADIUS Acct'
  echo "Allowed port ${RADIUS_ACCT_PORT}/udp for RADIUS Accounting"
  
else
  echo "UFW is not installed or is inactive. Skipping firewall configuration."
fi

# Validate each required port
if ! check_port ${WEB_PORT} "tcp"; then
  echo "Error: Port ${WEB_PORT}/tcp is already in use on this server."
  echo "Please stop the conflicting service or use a different installation method (without host network)."
  exit 1
fi
if ! check_port ${RADIUS_AUTH_PORT} "udp"; then
  echo "Error: Port ${RADIUS_AUTH_PORT}/udp is already in use on this server."
  echo "Please stop the conflicting service or use a different installation method (without host network)."
  exit 1
fi
if ! check_port ${RADIUS_ACCT_PORT} "udp"; then
  echo "Error: Port ${RADIUS_ACCT_PORT}/udp is already in use on this server."
  echo "Please stop the conflicting service or use a different installation method (without host network)."
  exit 1
fi

echo "All required ports (${WEB_PORT}/tcp, ${RADIUS_AUTH_PORT}/udp, ${RADIUS_ACCT_PORT}/udp) are available."
# --- END: Host Network Port Validation ---

# --- START: Docker Compose creation for Host Network ---
print_step "Creating docker-compose.yml in ${BASE_DIR}"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

cat <<EOF > "$COMPOSE_FILE"
services:
  ibsng:
    image: ${IMAGE_NAME}
    container_name: ibsng
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - "${DATA_DIR}:/var/lib/pgsql"
EOF

echo "docker-compose.yml with network_mode:host created successfully."

# Run the service using Docker Compose
print_step "Running the IBSng service with Docker Composer"
# Check if the project has any containers (running or stopped)
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

# Wait for the service to fully start and then restart once to ensure proper initialization
echo "Waiting for service to start..."
sleep 15

echo "Restarting service to ensure proper database connection..."
docker compose -f "${COMPOSE_FILE}" restart

# Wait for the restart to complete
echo "Waiting for service restart to complete..."
sleep 10

echo "IBSng service is now running and ready."
# --- END: Docker Compose creation for Host Network ---

# Set the timezone to Asia/Tehran
sudo timedatectl set-timezone Asia/Tehran

SOURCE_DIR="/root/iBsng-Installer"

# List of essential files to copy
ESSENTIAL_FILES=(
    "backup_ibsng.sh"
    "main.py"
    "restore_ibsng.sh"
)

# Copy each file with error handling
for file in "${ESSENTIAL_FILES[@]}"; do
    if [ -f "$SOURCE_DIR/$file" ]; then
        if ! cp "$SOURCE_DIR/$file" "$BACKUP_DIR/"; then
            echo "Error: Failed to copy $file" >&2
        else
            # Set executable permissions
            if ! chmod +x "$BACKUP_DIR/$file"; then
                echo "Warning: Failed to make $file executable" >&2
            fi
        fi
    else
        echo "Warning: Source file $file not found" >&2
    fi
done
# --- END: Copy Essential Files ---

# Final check: Create the config file only if BOTH variables have a value
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
  CONFIG_FILE="${BACKUP_DIR}/config.json"

  # Create the config.json file
  cat <<EOF > "$CONFIG_FILE"
{
  "bot_token": "$TELEGRAM_BOT_TOKEN",
  "chat_id": "$CHAT_ID"
}
EOF

  # Set appropriate permissions
  chmod 600 "$CONFIG_FILE"
  echo -e "\e[32mTelegram configuration has been successfully saved to ${CONFIG_FILE}\e[0m"
else
  # This message is shown if any part of the process was skipped or timed out
  echo -e "\e[31mTelegram Token or Chat ID not provided. Skipping Telegram configuration.\e[0m"
fi
# --- END: Telegram Bot Config ---

# --- START: Service Installation ---
print_step "Installing and Enabling Backup Service"

# Create service file with error handling
if ! sudo tee /etc/systemd/system/ibsng-backup.service > /dev/null << EOL
[Unit]
Description=IBSng Backup Service with Telegram Integration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${VENV_DIR}/bin/python3 ${BACKUP_DIR}/main.py
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL
then
    echo "Error: Failed to create service file" >&2
else
    # Set secure permissions (640: root:root)
    sudo chmod 640 /etc/systemd/system/ibsng-backup.service || echo "Warning: Failed to set permissions" >&2
    sudo chown root:root /etc/systemd/system/ibsng-backup.service || echo "Warning: Failed to set ownership" >&2

    # Reload and enable service with error handling
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

print_step "🔐 System Access Information"

echo -e "\n📁 To manage the service, navigate to '\e[34m${BASE_DIR}\e[0m' and use the following commands:"
echo -e "   🛑 Stop the service: \e[33mdocker compose down\e[0m"
echo -e "   ▶️ Start the service: \e[32mdocker compose up -d\e[0m"
echo -e "   📜 View logs: \e[36mdocker compose logs -f\e[0m"

echo -e "\n✅ IBSng has been successfully installed on this server."

echo -e "\n🌐 Admin Panel Access:"
echo -e "   🔗 URL: \e[32mhttp://${SERVER_IP}:${WEB_PORT}/IBSng/admin/\e[0m"
echo -e "   👤 Default Username: \e[33msystem\e[0m"
echo -e "   🔑 Default Password: \e[31madmin\e[0m"

echo -e "\n📡 RADIUS & Web Panel Ports:"
echo -e "   🌍 IBSng Web Panel Port (TCP): \e[36m${WEB_PORT}\e[0m"
echo -e "   🔐 RADIUS Authentication Port (UDP): \e[36m${RADIUS_AUTH_PORT}\e[0m"
echo -e "   📊 RADIUS Accounting Port (UDP): \e[36m${RADIUS_ACCT_PORT}\e[0m"

# Display backup bot service status with friendly name
if [ "$SERVICE_STATUS" = "active" ]; then
    echo -e "\n🤖 ${SERVICE_DISPLAY_NAME} Status: \e[32mRunning\e[0m"
else
    echo -e "\n⚠️ ${SERVICE_DISPLAY_NAME} Status: \e[31mNot Active\e[0m"
fi

echo -e "\n🎉 You're all set and ready to go!"
echo ""
