#!/usr/bin/env bash
# deploy.sh
# Production-grade deployment script for Dockerized app to remote Linux server
# Features: prompts + validation, clone with PAT, remote provisioning, rsync transfer,
# docker / docker-compose deployment, Nginx reverse proxy, health checks, logging,
# idempotency, cleanup flag, traps and exit codes.
#
# Exit codes:
#  0 - success
# 10 - invalid params / validation
# 20 - git clone/pull error
# 30 - ssh/connection error
# 40 - remote provisioning error
# 50 - transfer error
# 60 - deployment error
# 70 - validation/healthcheck failure
# 80 - cleanup error

set -o errexit
set -o nounset
set -o pipefail

# -------------------------
# Config / defaults
# -------------------------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="./deploy_${TIMESTAMP}.log"
MASKED_PAT="<REDACTED>"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
RSYNC_OPTS="-az --delete --exclude .git"
DEFAULT_BRANCH="main"
CLEANUP=false

# -------------------------
# Helpers: logging & errors
# -------------------------
log() {
  local ts msg
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  msg="$1"
  echo -e "[$ts] [INFO]  $msg" | tee -a "$LOGFILE"
}

warn() {
  local ts msg
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  msg="$1"
  echo -e "[$ts] [WARN]  $msg" | tee -a "$LOGFILE" >&2
}

err() {
  local ts msg code
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  msg="$1"
  code="${2:-1}"
  echo -e "[$ts] [ERROR] $msg (exit $code)" | tee -a "$LOGFILE" >&2
  exit "$code"
}

# trap and cleanup on error or exit
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    err "Script exited with code $rc" "$rc"
  else
    log "Script completed successfully (exit 0)."
  fi
}
trap on_exit EXIT

# trap signals to ensure cleanup
cleanup_trap() {
  warn "Caught interrupt/termination signal. Cleaning up."
  # Add any additional cleanup here.
  exit 130
}
trap cleanup_trap INT TERM

# -------------------------
# Parse args
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)
      CLEANUP=true
      shift
      ;;
    --logfile)
      LOGFILE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: ./deploy.sh [--cleanup] [--logfile path]

--cleanup   : Remove deployed resources (containers, nginx config) on remote host.
--logfile   : Specify log file path.

This script will prompt for parameters interactively if not provided via environment vars.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 10
      ;;
  esac
done

# -------------------------
# User input collection & validation
# -------------------------
read_input() {
  # Git repo
  read -rp "Git repository URL (https://github.com/owner/repo.git): " GIT_REPO
  [[ -n "${GIT_REPO:-}" ]] || err "Git repository URL is required." 10

  # PAT (hidden)
  read -rsp "Personal Access Token (PAT) for Git (input hidden): " GIT_PAT
  echo
  [[ -n "${GIT_PAT:-}" ]] || err "PAT is required." 10

  # Branch
  read -rp "Branch name (default: ${DEFAULT_BRANCH}): " GIT_BRANCH
  GIT_BRANCH="${GIT_BRANCH:-$DEFAULT_BRANCH}"

  # Remote SSH details
  read -rp "Remote server SSH username: " REMOTE_USER
  [[ -n "${REMOTE_USER:-}" ]] || err "SSH username required." 10

  read -rp "Remote server IP or hostname: " REMOTE_HOST
  [[ -n "${REMOTE_HOST:-}" ]] || err "Remote host required." 10

  read -rp "SSH key path (default: ~/.ssh/id_rsa): " SSH_KEY_PATH
  SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
  [[ -f "$SSH_KEY_PATH" ]] || err "SSH key not found at $SSH_KEY_PATH" 10

  read -rp "Application internal container port (e.g. 3000): " APP_PORT
  if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
    err "Application port must be numeric." 10
  fi

  # Derived values
  REPO_NAME="$(basename -s .git "$GIT_REPO")"
  LOCAL_CLONE_DIR="./${REPO_NAME}"
  CONTAINER_NAME="${REPO_NAME//[^a-zA-Z0-9_-]/_}"
  REMOTE_APP_DIR="/home/${REMOTE_USER}/${REPO_NAME}"
  NGINX_SITE_CONF="/etc/nginx/sites-available/${CONTAINER_NAME}.conf"
  NGINX_SITE_LINK="/etc/nginx/sites-enabled/${CONTAINER_NAME}.conf"

  log "Collected parameters (sensitive values masked in logs)."
  log "GIT_REPO: $GIT_REPO"
  log "GIT_BRANCH: $GIT_BRANCH"
  log "REMOTE: ${REMOTE_USER}@${REMOTE_HOST}"
  log "SSH_KEY_PATH: ${SSH_KEY_PATH}"
  log "APP internal port: ${APP_PORT}"
  log "Local clone dir: ${LOCAL_CLONE_DIR}"
  log "Container name: ${CONTAINER_NAME}"
  log "Remote app dir: ${REMOTE_APP_DIR}"
}

# -------------------------
# Ensure required local tools
# -------------------------
require_local_tools() {
  local missing=()
  for cmd in git ssh rsync scp curl awk sed docker; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Some local tools are missing: ${missing[*]}"
    warn "docker is only required locally if you plan to build locally; remote will be provisioned too."
    # do not exit; just warn — but require git/ssh/rsync/curl
    for must in git ssh rsync curl; do
      if ! command -v "$must" &>/dev/null; then
        err "Required local tool missing: $must" 10
      fi
    done
  fi
}

# -------------------------
# Git clone / pull (using PAT)
# -------------------------
clone_or_update_repo() {
  log "Cloning or updating repository..."

  # Construct auth URL safely (do not log the raw URL with token)
  # Accept multiple remote forms: https vs ssh. If user provided ssh URL, use it directly.
  if [[ "$GIT_REPO" =~ ^https?:// ]]; then
    # Insert token into HTTPS URL: https://<token>@github.com/owner/repo.git
    AUTHED_URL="$(echo "$GIT_REPO" | sed -E "s#https?://#https://${GIT_PAT}@#")"
  else
    # user gave ssh URL; we cannot use PAT to clone via SSH, use ssh auth (must have key)
    AUTHED_URL="$GIT_REPO"
  fi

  if [[ -d "$LOCAL_CLONE_DIR/.git" ]]; then
    log "Repository already exists locally. Fetching and checking out branch '$GIT_BRANCH'."
    pushd "$LOCAL_CLONE_DIR" >/dev/null
    # Ensure remote is correct
    git remote set-url origin "$AUTHED_URL" >/dev/null 2>&1 || true
    git fetch origin || err "git fetch failed" 20
    if git show-ref --verify --quiet "refs/heads/$GIT_BRANCH"; then
      git checkout "$GIT_BRANCH" || err "git checkout $GIT_BRANCH failed" 20
      git pull origin "$GIT_BRANCH" || err "git pull failed" 20
    else
      git checkout -b "$GIT_BRANCH" "origin/$GIT_BRANCH" || err "create/checkout branch failed" 20
    fi
    popd >/dev/null
  else
    log "Cloning repository (branch: $GIT_BRANCH)..."
    # Don't leak PAT into logfile; run command but mask in log
    if git clone --branch "$GIT_BRANCH" --single-branch "$AUTHED_URL" "$LOCAL_CLONE_DIR" >/dev/null 2>&1; then
      log "Clone succeeded."
    else
      err "git clone failed (check URL, PAT, branch) " 20
    fi
  fi

  # Verify presence of Dockerfile or docker-compose.yml
  if [[ -f "$LOCAL_CLONE_DIR/Dockerfile" ]]; then
    DOCKER_PRESENT=true
    log "Dockerfile found."
  elif [[ -f "$LOCAL_CLONE_DIR/docker-compose.yml" || -f "$LOCAL_CLONE_DIR/docker-compose.yaml" ]]; then
    DOCKER_COMPOSE_PRESENT=true
    log "docker-compose.yml found."
  else
    warn "No Dockerfile or docker-compose.yml found in project root. Deployment may fail."
    # attempt to search subdirectories
    if find "$LOCAL_CLONE_DIR" -maxdepth 3 -type f \( -name Dockerfile -o -name docker-compose.yml -o -name docker-compose.yaml \) | read -r ; then
      warn "Found Dockerfile/docker-compose in a subdirectory; ensure you set correct remote dir or update script."
    fi
  fi
}

# -------------------------
# Test SSH connectivity
# -------------------------
ssh_test() {
  log "Testing SSH connectivity to ${REMOTE_USER}@${REMOTE_HOST}..."
  if ssh -i "$SSH_KEY_PATH" $SSH_OPTIONS "${REMOTE_USER}@${REMOTE_HOST}" 'echo SSH_OK' 2>/dev/null | grep -q SSH_OK; then
    log "SSH connectivity OK."
  else
    err "Unable to SSH to ${REMOTE_USER}@${REMOTE_HOST}. Check network, firewall and key access." 30
  fi
}

# -------------------------
# Remote helper: run command
# -------------------------
run_remote() {
  local cmd="$1"
  ssh -i "$SSH_KEY_PATH" $SSH_OPTIONS "${REMOTE_USER}@${REMOTE_HOST}" "bash -lc '$cmd'"
}

# -------------------------
# Remote provisioning (apt/dnf support)
# -------------------------
remote_provision() {
  log "Starting remote provisioning (installing docker, docker-compose, nginx if missing)..."

  # Determine OS and package manager
  read -r os_info <<'EOF' # placeholder; we'll replace it by reading on remote
EOF

  # Run a single multi-line remote script for provisioning idempotently
  REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
# Attempt to detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG="apt"
  UPDATE="sudo apt-get update -y"
  INSTALL="sudo apt-get install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG="yum"
  UPDATE="sudo yum makecache -y"
  INSTALL="sudo yum install -y"
elif command -v dnf >/dev/null 2>&1; then
  PKG="dnf"
  UPDATE="sudo dnf makecache -y"
  INSTALL="sudo dnf install -y"
else
  echo "No supported package manager found (apt/yum/dnf)"
  exit 1
fi

echo "Using package manager: $PKG"

# Update
$UPDATE

# Install prerequisites
$INSTALL curl ca-certificates gnupg lsb-release software-properties-common || true

# Install Docker (idempotent)
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker engine..."
  if [ "$PKG" = "apt" ]; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    # Simplified install for yum/dnf platforms
    sudo $INSTALL docker || true
  fi
else
  echo "Docker already installed: $(docker --version || true)"
fi

# docker-compose (standalone) if not plugin
if ! command -v docker-compose >/dev/null 2>&1; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "docker compose plugin available."
  else
    echo "Installing docker-compose binary..."
    COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.17.2/docker-compose-$(uname -s)-$(uname -m)"
    sudo curl -L "$COMPOSE_URL" -o /usr/local/bin/docker-compose || echo "compose download may have failed"
    sudo chmod +x /usr/local/bin/docker-compose || true
  fi
else
  echo "docker-compose present: $(docker-compose --version || true)"
fi

# Nginx
if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  if [ "$PKG" = "apt" ]; then
    sudo apt-get install -y nginx
  else
    sudo $INSTALL nginx || true
  fi
else
  echo "nginx present: $(nginx -v || true)"
fi

# Enable/start services
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable docker --now || true
  sudo systemctl enable nginx --now || true
fi

# Add user to docker group
if id "$USER" &>/dev/null; then
  sudo usermod -aG docker "$USER" || true
fi

# Report versions
echo "docker: $(docker --version || true)"
if command -v docker-compose >/dev/null 2>&1; then
  echo "docker-compose: $(docker-compose --version || true)"
elif docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin: $(docker compose version || true)"
fi
echo "nginx: $(nginx -v 2>&1 || true)"

REMOTE
)

  if run_remote "$REMOTE_SCRIPT" >/dev/null 2>&1; then
    log "Remote provisioning script executed successfully."
  else
    err "Remote provisioning failed." 40
  fi
}

# -------------------------
# Transfer project to remote
# -------------------------
transfer_project() {
  log "Syncing project files to remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}"
  # Ensure remote dir exists
  run_remote "mkdir -p '$REMOTE_APP_DIR' && chown -R ${REMOTE_USER}:${REMOTE_USER} '$REMOTE_APP_DIR' || true"

  # Use rsync for efficient updates. Hide PAT (we will not transfer .git/credentials)
  if rsync $RSYNC_OPTS -e "ssh -i $SSH_KEY_PATH $SSH_OPTIONS" --exclude '.git' "$LOCAL_CLONE_DIR"/ "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}/" >>"$LOGFILE" 2>&1; then
    log "rsync transfer complete."
  else
    err "rsync transfer failed." 50
  fi
}

# -------------------------
# Deploy on remote host
# -------------------------
remote_deploy() {
  log "Starting remote deployment steps..."

  # remote commands: build/run containers, stop existing, start new
  DEPLOY_SCRIPT=$(cat <<DEP
set -euo pipefail
cd "$REMOTE_APP_DIR"
# Ensure ownership
sudo chown -R "$REMOTE_USER":"$REMOTE_USER" "$REMOTE_APP_DIR" || true

# Stop & remove existing container(s) gracefully
# Use docker-compose if compose file present; otherwise use docker with container name
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  echo "Using docker-compose deployment..."
  # bring down previous stack
  docker compose -f docker-compose.yml down || docker-compose down || true
  # bring up
  docker compose -f docker-compose.yml up -d --build
else
  # If Dockerfile present:
  if [ -f Dockerfile ]; then
    echo "Building image and running container..."
    IMAGE_NAME="${CONTAINER_NAME}:latest"
    docker build -t "$IMAGE_NAME" .
    # Stop/remove existing container with same name
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
      docker stop "${CONTAINER_NAME}" || true
      docker rm "${CONTAINER_NAME}" || true
    fi
    # Run new container
    docker run -d --name "${CONTAINER_NAME}" -p ${APP_PORT}:${APP_PORT} --restart unless-stopped "$IMAGE_NAME"
  else
    echo "No Dockerfile or docker-compose.yml found in $REMOTE_APP_DIR"
    exit 1
  fi
fi

# Wait for container to be healthy if healthcheck is defined
sleep 2
# If container has health status, wait up to 30s
if docker inspect --format='{{json .State.Health}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q '"Status"'; then
  for i in {1..15}; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    echo "Container health: \$status"
    if [[ "\$status" == "healthy" ]]; then
      break
    fi
    sleep 2
  done
fi

# Output container status
docker ps --filter name="${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

DEP
)

  # Replace variables in here-doc with safe values before sending
  DEPLOY_SCRIPT="${DEPLOY_SCRIPT//\$\{CONTAINER_NAME\}/${CONTAINER_NAME}}"
  DEPLOY_SCRIPT="${DEPLOY_SCRIPT//\$\{APP_PORT\}/${APP_PORT}}"
  if run_remote "$DEPLOY_SCRIPT" >>"$LOGFILE" 2>&1; then
    log "Remote deployment executed."
  else
    err "Remote deployment failed." 60
  fi
}

# -------------------------
# Configure Nginx reverse proxy
# -------------------------
configure_nginx() {
  log "Configuring Nginx reverse proxy for ${CONTAINER_NAME} -> localhost:${APP_PORT}"

  # Create nginx config with proxy to internal port
  NGINX_CONF=$(cat <<NGCONF
server {
    listen 80;
    server_name ${REMOTE_HOST};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Optionally add basic SSL readiness
    # ssl_certificate /etc/letsencrypt/live/REPLACE/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/REPLACE/privkey.pem;
}
NGCONF
)

  # Transfer file and enable
  # Use sudo tee to write
  run_remote "echo \"${NGINX_CONF//\"/\\\"}\" | sudo tee '$NGINX_SITE_CONF' >/dev/null"
  run_remote "sudo ln -sf '$NGINX_SITE_CONF' '$NGINX_SITE_LINK' || true"
  # Test and reload
  if run_remote "sudo nginx -t" >>"$LOGFILE" 2>&1; then
    run_remote "sudo systemctl reload nginx" >>"$LOGFILE" 2>&1 || true
    log "Nginx configured and reloaded."
  else
    err "Nginx configuration test failed." 40
  fi
}

# -------------------------
# Validate deployment (local and remote)
# -------------------------
validate_deployment() {
  log "Validating deployment..."

  # Check docker service remote
  run_remote "sudo systemctl is-active --quiet docker && echo docker-running || echo docker-not-running" >/tmp/remote_docker_status 2>&1 || true
  DOCKER_STATUS=$(ssh -i "$SSH_KEY_PATH" $SSH_OPTIONS "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl is-active --quiet docker && echo docker-running || echo docker-not-running")
  if [[ "$DOCKER_STATUS" != "docker-running" ]]; then
    err "Docker service is not running on remote host." 70
  fi
  log "Docker service running."

  # Check container
  CONTAINER_STATUS=$(run_remote "docker ps --filter name='^${CONTAINER_NAME}\$' --format '{{.Status}}' || true")
  if [[ -z "$CONTAINER_STATUS" ]]; then
    err "Target container ${CONTAINER_NAME} is not running." 70
  fi
  log "Container status: $CONTAINER_STATUS"

  # Test proxy locally on remote (curl)
  REMOTE_CURL_OUTPUT=$(run_remote "curl -sS -m 10 http://127.0.0.1:${APP_PORT} || true")
  if [[ -n "$REMOTE_CURL_OUTPUT" ]]; then
    log "Application returned content on internal port ${APP_PORT} (remote localhost)."
  else
    warn "No content returned from app on internal port ${APP_PORT}. It may be fine (API returns empty) or not started."
  fi

  # Test from control machine to remote public IP via nginx
  if curl -sS -m 10 "http://${REMOTE_HOST}/" >/dev/null 2>&1; then
    log "HTTP test via nginx succeeded from control host."
  else
    warn "HTTP test via nginx failed from control host; check firewall or DNS. Trying direct IP:${APP_PORT}..."
    if curl -sS -m 10 "http://${REMOTE_HOST}:${APP_PORT}/" >/dev/null 2>&1; then
      log "Direct port test succeeded."
    else
      warn "Direct port test failed as well."
    fi
  fi

  log "Validation complete."
}

# -------------------------
# Cleanup mode
# -------------------------
perform_cleanup() {
  log "Performing cleanup on remote host for ${CONTAINER_NAME} and nginx config..."

  CLEAN_SCRIPT=$(cat <<CLEAN
set -euo pipefail
# Stop and remove containers
if docker ps -a --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}\$'; then
  docker stop ${CONTAINER_NAME} || true
  docker rm ${CONTAINER_NAME} || true
fi

# Remove image
if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^${CONTAINER_NAME}:latest\$'; then
  docker rmi ${CONTAINER_NAME}:latest || true
fi

# Remove nginx config
if [ -f "${NGINX_SITE_CONF}" ]; then
  sudo rm -f "${NGINX_SITE_CONF}" || true
fi
if [ -f "${NGINX_SITE_LINK}" ]; then
  sudo rm -f "${NGINX_SITE_LINK}" || true
fi
sudo nginx -t || true
sudo systemctl reload nginx || true

# Optionally remove app directory
# sudo rm -rf "${REMOTE_APP_DIR}"
echo "CLEANUP_DONE"
CLEAN
)

  if run_remote "$CLEAN_SCRIPT" >>"$LOGFILE" 2>&1; then
    log "Cleanup executed on remote host."
  else
    err "Cleanup failed." 80
  fi
}

# -------------------------
# Main execution
# -------------------------
main() {
  # Create or touch logfile
  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
  touch "$LOGFILE"
  log "Deployment started. Log: $LOGFILE"

  read_input
  require_local_tools

  # If cleanup flag, just run cleanup and exit
  if [[ "$CLEANUP" == true ]]; then
    ssh_test
    perform_cleanup
    log "Cleanup completed."
    exit 0
  fi

  clone_or_update_repo
  ssh_test
  remote_provision
  transfer_project
  remote_deploy
  configure_nginx
  validate_deployment

  log "All done. View logs at $LOGFILE"
  exit 0
}

# Execute main
main "$@"
