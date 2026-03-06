#!/usr/bin/env bash
# bootstrap.sh — Public entry point for VPS bootstrap
# Part of Platform Strategy V2.1

set -euo pipefail

# Required environment variables before running (or will prompt):
# TAILSCALE_AUTHKEY
# BW_CLIENTID
# BW_CLIENTSECRET
# BW_PASSWORD

GITHUB_ORG="${GITHUB_ORG:-prabhakarjee}"
GITHUB_REPO="le-platform-core"
INSTALL_DIR="/opt/platform"

echo "╔════════════════════════════════════════════╗"
echo "║        LE-Platform V2.1 Bootstrap          ║"
echo "╚════════════════════════════════════════════╝"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run as root (e.g. sudo bash bootstrap.sh)"
    exit 1
fi

# --- Interactive Credential Prompting ---
prompt_secret() {
    local var_name="$1"
    local prompt_msg="$2"
    if [[ -z "${!var_name:-}" ]]; then
        read -rsp "$prompt_msg: " input_val
        echo "" # New line after silent read
        if [[ -z "$input_val" ]]; then
            echo "❌ $var_name cannot be empty."
            exit 1
        fi
        export "$var_name"="$input_val"
    fi
}

echo "📝 Please enter the required foundation secrets:"
prompt_secret "TAILSCALE_AUTHKEY" "Enter Tailscale Auth Key"
prompt_secret "BW_CLIENTID"      "Enter Bitwarden Client ID"
prompt_secret "BW_CLIENTSECRET"  "Enter Bitwarden Client Secret"
prompt_secret "BW_PASSWORD"      "Enter Bitwarden Master Password"
echo "✅ Credentials captured."
echo ""

# 1. Update OS and Install Core Tools
echo "📦 Updating OS and installing core tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl git jq yq ufw unzip gpg > /dev/null 2>&1

# 2. Install Docker
if ! command -v docker &>/dev/null; then
    echo "🐳 Installing Docker Engine..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
fi

# 3. Install rclone
if ! command -v rclone &>/dev/null; then
    echo "📦 Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash
fi

# 4. Install Tailscale
if ! command -v tailscale &>/dev/null; then
    echo "🔗 Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash
    tailscale up --authkey "${TAILSCALE_AUTHKEY}"
fi

# 5. Install Bitwarden CLI
if ! command -v bw &>/dev/null; then
    echo "🔐 Installing Bitwarden CLI..."
    BW_URL="https://vault.bitwarden.com/download/?app=cli&platform=linux"
    curl -sSL "$BW_URL" -o /tmp/bw.zip
    unzip -o /tmp/bw.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/bw
    rm -f /tmp/bw.zip
fi

# 6. Authenticate with Bitwarden
echo "🔑 Unlocking Bitwarden vault..."
export BW_CLIENTID="${BW_CLIENTID}"
export BW_CLIENTSECRET="${BW_CLIENTSECRET}"
bw login --apikey

export BW_SESSION=$(bw unlock "${BW_PASSWORD}" --raw)
if [[ -z "${BW_SESSION}" ]]; then
    echo "❌ Failed to unlock Bitwarden vault. Check BW_PASSWORD."
    exit 1
fi

# 7. Fetch GitHub PAT
echo "📂 Fetching GitHub PAT..."
GITHUB_TOKEN=$(bw get item "Infra GitHub PAT" | jq -r '.notes // .login.password')

if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    echo "❌ Failed to fetch 'Infra GitHub PAT' from Bitwarden."
    exit 1
fi

# 8. Clone Private Core Repo
echo "📦 Cloning private platform core via HTTPS..."
# Use the token in the URL for the initial clone
git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR"

# 9. Trigger Platform Initialization
echo "🚀 Triggering Platform Initialization..."
bash "$INSTALL_DIR/bootstrap/platform-init.sh"

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║   Bootstrap Phase 1 Complete.             ║"
echo "║   Platform is now initializing...         ║"
echo "╚════════════════════════════════════════════╝"
