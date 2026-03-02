#!/usr/bin/env bash
set -euo pipefail

# linux-init.sh
# Target: Ubuntu 24.04+ (incl. WSL). Run as a normal user; script will use sudo when needed.

log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

need_cmd sudo
need_cmd curl

if ! sudo -n true >/dev/null 2>&1; then
  log "sudo needs a password (not NOPASSWD). You may be prompted."
fi

log "Step 0: sanity checks"
if [ ! -f /etc/os-release ]; then
  echo "Cannot detect OS (/etc/os-release missing)." >&2
  exit 1
fi
. /etc/os-release
log "Detected: ${PRETTY_NAME:-unknown}"

# ----------------------------
# 0.5) Enable passwordless sudo for user 'keymorek'
# ----------------------------
log "Step 0.5: configure passwordless sudo for user 'keymorek'"
SUDOERS_D="/etc/sudoers.d/90-keymorek-nopasswd"
# Use visudo to validate syntax. This will still require sudo rights once.
sudo bash -lc "printf '%s\n' 'keymorek ALL=(ALL) NOPASSWD: ALL' > '$SUDOERS_D' && chmod 0440 '$SUDOERS_D'"
# Verify (non-interactive)
if sudo -n true >/dev/null 2>&1; then
  log "NOPASSWD sudo is active for keymorek"
else
  log "WARNING: NOPASSWD sudo not active (you may need to re-login or check sudoers)"
fi

# ----------------------------
# 1) Replace ubuntu.sources
# ----------------------------
log "Step 1: replace /etc/apt/sources.list.d/ubuntu.sources"
SRC_FILE="/etc/apt/sources.list.d/ubuntu.sources"
BACKUP="${SRC_FILE}.bak.$(date +%s)"

if [ -f "$SRC_FILE" ]; then
  log "Backing up current sources to: $BACKUP"
  sudo cp -a "$SRC_FILE" "$BACKUP"
fi

# Default: TUNA mirror for mainland CN + official security.
# You can edit this block if you prefer official archive.ubuntu.com.
CODENAME="${VERSION_CODENAME:-noble}"

sudo tee "$SRC_FILE" >/dev/null <<EOF
Types: deb
URIs: https://mirrors.tuna.tsinghua.edu.cn/ubuntu
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

# ----------------------------
# 2) Update/upgrade
# ----------------------------
log "Step 2: apt update/upgrade"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

# ----------------------------
# 3) Install build-essential
# ----------------------------
log "Step 3: install build-essential"
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install build-essential ca-certificates git unzip qemu-guest-agent spice-vdagent bash-completion unzip wget curl axel net-tools iputils-ping iputils-arping iputils-tracepath nano most screen less vim bzip2 lldpd mtr-tiny htop dnsutils zstd

# ----------------------------
# 4) Install custom root CA
# ----------------------------
log "Step 4: download and install SurgeCA.crt into system trust store"
CA_URL="https://github.com/Keymorek/CAinuse/releases/download/Main/SurgeCA.crt"
TMP_CA="/tmp/SurgeCA.crt"

# Use -L to follow GitHub release redirects.
curl -fsSL -L "$CA_URL" -o "$TMP_CA"

# NOTE: per user request, no content validation here.
# We download the .crt and install it into the system trust store.

sudo cp "$TMP_CA" /usr/local/share/ca-certificates/SurgeCA.crt
sudo update-ca-certificates

# ----------------------------
# 5) Install nvm + Node 24
# ----------------------------
log "Step 5: install nvm + Node.js 24"
NVM_VERSION="v0.40.3"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Install nvm (idempotent)
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# Load nvm for this script
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"

nvm install 24
nvm alias default 24

# Ensure nvm is loaded for future shells (bash/zsh)
ensure_line() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file"
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

ensure_line "$HOME/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
ensure_line "$HOME/.zshrc" 'export NVM_DIR="$HOME/.nvm"'
ensure_line "$HOME/.zshrc" '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'

log "Node version: $(node -v)"
log "npm version: $(npm -v)"

# ----------------------------
# 6) Install Homebrew (Linuxbrew)
# ----------------------------
log "Step 6: install Homebrew (Linuxbrew)"
if command -v brew >/dev/null 2>&1; then
  log "Homebrew already installed: $(command -v brew)"
else
  # Official installer
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Add brew to PATH for future shells
BREW_BIN_CANDIDATES=("/home/linuxbrew/.linuxbrew/bin/brew" "$HOME/.linuxbrew/bin/brew")
BREW_BIN=""
for c in "${BREW_BIN_CANDIDATES[@]}"; do
  if [ -x "$c" ]; then BREW_BIN="$c"; break; fi
done
if [ -z "$BREW_BIN" ]; then
  log "brew not found in expected locations; try opening a new shell or locate it manually."
else
  # IMPORTANT: do NOT inline the output of `brew shellenv` into .bashrc.
  # It contains quotes; if written inside another quoted string it will break bash.
  # Write the standard safe line literally.
  ensure_line "$HOME/.bashrc" 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  ensure_line "$HOME/.zshrc" 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  # Activate for current script
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  log "Homebrew ready: $(brew --version | head -n 1)"
fi

log "DONE. Recommended: open a new shell to pick up updated environment (.bashrc/.zshrc)."
