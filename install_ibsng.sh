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
  echo "\n----------------------------------------------"
  echo "$1"
  echo "----------------------------------------------"
}

# Update package list and install prerequisites
print_step "Updating package list and installing prerequisites"
sudo apt update -y

# Remove old versions of Docker if they exist
for pkg in docker docker.io containerd runc; do
    apt-get remove -y $pkg || true
done

# Install packages required to add the Docker repository
apt-get install -y wget jq ca-certificates curl gnupg lsb-release python3-pip dialog whiptail apt-utils

# --- Download and extract latest release from a GitHub project ---
print_step "Downloading and extracting latest GitHub release"

# !!! IMPORTANT: Replace with your target repository's owner and name !!!
GITHUB_OWNER="ArashAfkandeh"
GITHUB_REPO="iBsng-Installer"
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# Define where to extract the files
EXTRACT_DIR="/root/${GITHUB_REPO}"

echo "Fetching latest release URL for ${GITHUB_OWNER}/${GITHUB_REPO}..."

# Use GitHub API to get the URL of the .tar.gz for the latest release
LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest" | jq -r '.tarball_url')

# Check if the URL was fetched successfully
if [ -z "$LATEST_RELEASE_URL" ] || [ "$LATEST_RELEASE_URL" == "null" ]; then
  echo "Error: Could not find the latest release URL."
  echo "Please check the repository owner/name and ensure it has published releases."
  exit 1
fi

echo "Latest release URL: ${LATEST_RELEASE_URL}"
echo "Downloading archive..."

# Create a temporary file to download the archive
TEMP_ARCHIVE=$(mktemp)
wget -q -O "$TEMP_ARCHIVE" "$LATEST_RELEASE_URL"

echo "Extracting archive to ${EXTRACT_DIR}..."
mkdir -p "$EXTRACT_DIR"
# Extract the archive, strip the top-level directory, and place contents in EXTRACT_DIR
tar -xzf "$TEMP_ARCHIVE" -C "$EXTRACT_DIR" --strip-components=1

# Clean up the temporary archive file
rm "$TEMP_ARCHIVE"

echo "Successfully extracted project to ${EXTRACT_DIR}"
# --- End of GitHub download section ---

sudo pip3 install pyTelegramBotAPI jdatetime

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

# Create a path for persistent data storage
# First, we define the base directory and the database path
BASE_DIR="/opt/ibsng"
DATA_DIR="${BASE_DIR}/pgsql"
mkdir -p "$BASE_DIR"

# Run a temporary container to copy the initial database (only if data doesn't exist)
if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
  print_step "Running a temporary container to extract initial data"
  # Set proper permissions for PostgreSQL data directory
  mkdir -p "$DATA_DIR"
  chown -R 26:26 "$DATA_DIR"
  chmod 700 "$DATA_DIR"

  # Remove any potential temporary container
  docker rm -f ibsng_tmp 2>/dev/null || true
  # Run the container without port mapping for initial database setup
  docker run --name ibsng_tmp -v "${DATA_DIR}:/var/lib/pgsql" -d "$IMAGE_NAME"

  # Allow 20 seconds for the services to start properly
  echo "Waiting for services to initialize (20 seconds)..."
  for i in {1..20}; do
    echo -n "."
    sleep 1
  done
  
  echo -e "\nDatabase is ready. Proceeding with data copy."
  # --- END: Robust wait logic ---

  # Copy database contents from the container to the host
  # We copy the /var/lib/pgsql folder into the /opt/ibsng directory so that
  # the /opt/ibsng/pgsql structure is preserved
  docker cp ibsng_tmp:/var/lib/pgsql "$BASE_DIR"
  
  # Remove the temporary container
  docker rm -f ibsng_tmp
fi

# --- START: Host Network Port Validation ---
print_step "Validating Required Ports for Host Network Mode"

# Define default ports
DEFAULT_WEB_PORT=80
DEFAULT_RADIUS_AUTH_PORT=1812
DEFAULT_RADIUS_ACCT_PORT=1813

# Function to read input with timeout and return clean value
read_with_timeout() {
  local prompt="$1"
  local default_value="$2"
  local timeout=60
  local response=""
  local result=""

  # Show prompt for user input
  echo "You have ${timeout} seconds to enter a custom port or press Enter for default."
  if ! read -t $timeout -p "$prompt (default: $default_value): " response; then
    echo -e "\nTimeout reached, using default value: $default_value"
    result="$default_value"
  else
    # Use default if response is empty (user pressed Enter) or invalid
    if [ -z "$response" ] || ! [[ "$response" =~ ^[0-9]+$ ]]; then
      if [ -z "$response" ]; then
        echo "Using default value: $default_value"
      else
        echo "Invalid input, using default value: $default_value"
      fi
      result="$default_value"
    else
      result="$response"
    fi
  fi

  # Return clean value
  printf '%s' "$result"
}

# Check command line arguments first (1st=web, 2nd=auth, 3rd=acct)
WEB_PORT=${1:-""}
RADIUS_AUTH_PORT=${2:-""}
RADIUS_ACCT_PORT=${3:-""}

# If any port is not provided in arguments, ask interactively
if [ -z "$WEB_PORT" ]; then
  echo "Web port not provided in arguments."
  WEB_PORT=$(read_with_timeout "Enter Web Panel Port" "$DEFAULT_WEB_PORT")
fi

if [ -z "$RADIUS_AUTH_PORT" ]; then
  echo "RADIUS Authentication port not provided in arguments."
  RADIUS_AUTH_PORT=$(read_with_timeout "Enter RADIUS Authentication Port" "$DEFAULT_RADIUS_AUTH_PORT")
fi

if [ -z "$RADIUS_ACCT_PORT" ]; then
  echo "RADIUS Accounting port not provided in arguments."
  RADIUS_ACCT_PORT=$(read_with_timeout "Enter RADIUS Accounting Port" "$DEFAULT_RADIUS_ACCT_PORT")
fi

# Set defaults if still empty (timeout occurred)
WEB_PORT="${WEB_PORT:-$DEFAULT_WEB_PORT}"
RADIUS_AUTH_PORT="${RADIUS_AUTH_PORT:-$DEFAULT_RADIUS_AUTH_PORT}"
RADIUS_ACCT_PORT="${RADIUS_ACCT_PORT:-$DEFAULT_RADIUS_ACCT_PORT}"

# Export cleaned variables
export WEB_PORT RADIUS_AUTH_PORT RADIUS_ACCT_PORT

# Show selected ports
echo -e "\nSelected ports:"
echo "Web Panel Port: ${WEB_PORT}"
echo "RADIUS Authentication Port: ${RADIUS_AUTH_PORT}"
echo "RADIUS Accounting Port: ${RADIUS_ACCT_PORT}"

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

echo "All required ports (80/tcp, 1812/udp, 1813/udp) are available."
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
print_step "Running the IBSng service with Docker Compose"
docker compose -f "${COMPOSE_FILE}" down
docker compose -f "${COMPOSE_FILE}" up -d
# --- END: Docker Compose creation for Host Network ---

# Set the timezone to Asia/Tehran
sudo timedatectl set-timezone Asia/Tehran

# --- START: Telegram Bot Config with Arguments, Interactive Fallback, and 120s Timeout ---
print_step "Configuring Telegram Bot for Backups (Optional)"
echo "You can provide credentials as arguments: ./script.sh [args...] <TOKEN> <CHAT_ID>"

# Define the timeout for interactive prompts
TIMEOUT=120

# Initialize variables to be empty
TELEGRAM_BOT_TOKEN=""
CHAT_ID=""

# Check if both token and chat_id are provided as command-line arguments
# We assume they are the 4th and 5th arguments, after any potential port arguments.
if [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
  echo "Using Telegram Bot Token and Chat ID from command-line arguments."
  TELEGRAM_BOT_TOKEN="$4"
  CHAT_ID="$5"
else
  # If arguments are not provided, switch to interactive mode
  echo "Proceeding with interactive setup (${TIMEOUT}s timeout per prompt)."

  # Prompt for the Telegram Bot Token with a timeout
  if ! read -t ${TIMEOUT} -p "Enter Telegram Bot Token (or press Enter to skip): " TELEGRAM_BOT_TOKEN; then
      echo -e "\nTimeout reached or input skipped."
      # Ensure token is empty to skip the next step
      TELEGRAM_BOT_TOKEN=""
  fi

  # Only ask for Chat ID if a Token was provided
  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    if ! read -t ${TIMEOUT} -p "Enter your Telegram Chat ID: " CHAT_ID; then
        echo -e "\nTimeout reached or input skipped."
        # Ensure Chat ID is empty
        CHAT_ID=""
    fi
  fi
fi

# Final check: Create the config file only if BOTH variables have a value
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
  CONFIG_DIR="/root/iBsng-Installer"
  CONFIG_FILE="${CONFIG_DIR}/config.json"
  mkdir -p "$CONFIG_DIR"

  # Create the config.json file
  cat <<EOF > "$CONFIG_FILE"
{
  "bot_token": "$TELEGRAM_BOT_TOKEN",
  "chat_id": "$CHAT_ID"
}
EOF

  # Set appropriate permissions
  chmod 600 "$CONFIG_FILE"
  echo "Telegram configuration has been successfully saved to ${CONFIG_FILE}"
else
  # This message is shown if any part of the process was skipped or timed out
  echo "Telegram Token or Chat ID not provided. Skipping Telegram configuration."
fi
# --- END: Telegram Bot Config ---

# Install and enable the backup systemd service
print_step "Installing and Enabling Backup Service"

# Define the source and destination for the service file
SERVICE_SRC_FILE="/root/iBsng-Installer/backup-ibsng.service"
SERVICE_DEST_DIR="/etc/systemd/system/"

# Check if the source service file exists
if [ -f "$SERVICE_SRC_FILE" ]; then
  echo "Moving service file to ${SERVICE_DEST_DIR}..."
  mv "$SERVICE_SRC_FILE" "$SERVICE_DEST_DIR"

  echo "Reloading, enabling, and starting the backup service..."
  
  sudo systemctl daemon-reload && sudo systemctl enable backup-ibsng.service && sudo systemctl start backup-ibsng.service

  echo "Backup service has been successfully installed and started."
else
  echo "Warning: Service file ${SERVICE_SRC_FILE} not found. Skipping backup service installation."
fi

# Extract the server's IP address
SERVER_IP=$(hostname -I | awk '{print $1}')

# Print system access information
print_step "System Access Information"
echo "IBSng has been successfully installed on this server."
echo -e "Admin Panel URL: \e[32mhttp://${SERVER_IP}:${WEB_PORT}/IBSng/admin/\e[0m"
echo -e "Default Username: \e[33msystem\e[0m"
echo -e "Default Password: \e[31madmin\e[0m"
echo ""
echo "Your RADIUS Ports:"
echo -e "iBsng Web-Panel Port (TCP): \e[36m${WEB_PORT}\e[0m"
echo -e "RADIUS Auth Port (UDP): \e[36m${RADIUS_AUTH_PORT}\e[0m"
echo -e "RADIUS Acct Port (UDP): \e[36m${RADIUS_ACCT_PORT}\e[0m"
echo ""
echo "To manage the service, navigate to '${BASE_DIR}' and use:"
echo "  - To stop: 'docker compose down'"
echo "  - To start: 'docker compose up -d'"
echo "  - To view logs: 'docker compose logs -f'"
