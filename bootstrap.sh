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
        local input_val
        read -rsp "$prompt_msg: " input_val </dev/tty
        # Trim all whitespace and carriage returns
        input_val=$(echo "$input_val" | xargs | tr -d '\r')
        echo "" # New line after silent read
        if [[ -z "$input_val" ]]; then
            echo "❌ $var_name cannot be empty."
            exit 1
        fi
        export "$var_name"="$input_val"
    fi
}

echo "📝 Checking existing authentication status..."
# Ensure curl is installed before checking status
if ! command -v curl &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq curl > /dev/null 2>&1
fi
BW_STATUS=$(bw status 2>/dev/null | jq -r .status 2>/dev/null || echo "unauthenticated")

echo "📝 Please enter the required Bitwarden secrets:"

if [[ "$BW_STATUS" == "unauthenticated" ]]; then
    prompt_secret "BW_CLIENTID"      "Enter Bitwarden Client ID"
    prompt_secret "BW_CLIENTSECRET"  "Enter Bitwarden Client Secret"
fi

# Always double check ID/Secret if we might need to login
if [[ "$BW_STATUS" != "unlocked" ]]; then
    prompt_secret "BW_PASSWORD"      "Enter Bitwarden Master Password"
fi
echo "✅ Credentials captured."
echo ""

# Persist identity for future "Zero-Touch" operations
# This stores ONLY the Client ID and Secret, NOT the Master Password.
mkdir -p /opt/platform/config
cat <<EOF > /opt/platform/config/bw.identity
export BW_CLIENTID="$BW_CLIENTID"
export BW_CLIENTSECRET="$BW_CLIENTSECRET"
EOF
chmod 600 /opt/platform/config/bw.identity
if id "deploy" &>/dev/null; then
    chown deploy:deploy /opt/platform/config/bw.identity
else
    chown root:root /opt/platform/config/bw.identity 2>/dev/null || true
fi

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

# 4. Install Bitwarden CLI
if ! command -v bw &>/dev/null; then
    echo "🔐 Installing Bitwarden CLI..."
    BW_URL="https://vault.bitwarden.com/download/?app=cli&platform=linux"
    curl -sSL "$BW_URL" -o /tmp/bw.zip
    unzip -o /tmp/bw.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/bw
    rm -f /tmp/bw.zip
fi

# 5. Authenticate and Unlock Bitwarden
echo "🔑 Unlocking Bitwarden vault..."
export BW_CLIENTID="${BW_CLIENTID:-}"
export BW_CLIENTSECRET="${BW_CLIENTSECRET:-}"

if [[ "$(bw status | jq -r .status)" == "unauthenticated" ]]; then
    bw login --apikey
fi

export BW_SESSION=$(bw unlock "${BW_PASSWORD}" --raw)
if [[ -z "${BW_SESSION}" ]]; then
    echo "❌ Failed to unlock Bitwarden vault. Check BW_PASSWORD."
    exit 1
fi

echo "🔄 Syncing Bitwarden vault..."
bw sync

# 6. Fetch Infrastructure Secrets
echo "📂 Fetching infrastructure secrets..."
GITHUB_TOKEN=$(bw get item "Infra GitHub PAT" | jq -r '.login.password' | xargs | tr -d '\r')
TAILSCALE_KEY=$(bw get item "Infra Tailscale Auth Key" | jq -r '.login.password' | xargs | tr -d '\r')

if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
    echo "❌ Failed to fetch 'Infra GitHub PAT' from Bitwarden (Note or Password field required)."
    exit 1
fi

if [[ -z "$TAILSCALE_KEY" || "$TAILSCALE_KEY" == "null" ]]; then
    echo "⚠️  Failed to fetch 'Infra Tailscale Auth Key' from Bitwarden. Tailscale may require manual login."
fi

# Print safe debug info about the token
echo "🔍 Debug: PAT length is ${#GITHUB_TOKEN} characters."
echo "🔍 Debug: PAT starts with '${GITHUB_TOKEN:0:4}' and ends with '${GITHUB_TOKEN: -4}'"

# 7. Install and Setup Tailscale
echo "🔗 Configuring system identity and security..."

# Fetch Advanced Bootstrap Env from Bitwarden
BOOTSTRAP_ENV=$(bw get item "Infra Bootstrap Env" | jq -r '.notes' || echo "")

# 1. System Localization (Timezone)
TARGET_TZ=$(echo "$BOOTSTRAP_ENV" | grep "^TZ=" | cut -d'=' -f2 | xargs || echo "Asia/Kolkata")
echo "🕒 Setting timezone to: $TARGET_TZ"
timedatectl set-timezone "$TARGET_TZ" || true

# 2. System Identity (Hostname)
# Preference: VPS_HOSTNAME > Domain Prefix > default
TARGET_HOSTNAME=$(echo "$BOOTSTRAP_ENV" | grep "^VPS_HOSTNAME=" | cut -d'=' -f2 | xargs || echo "")
if [[ -z "$TARGET_HOSTNAME" ]]; then
    PRIMARY_DOMAIN=$(echo "$BOOTSTRAP_ENV" | grep "^PRIMARY_DOMAIN=" | cut -d'=' -f2 | xargs || echo "le-vps")
    TARGET_HOSTNAME=$(echo "$PRIMARY_DOMAIN" | cut -d'.' -f1)
fi

echo "🏷️  Setting system hostname to: $TARGET_HOSTNAME"
hostnamectl set-hostname "$TARGET_HOSTNAME"
echo "127.0.0.1 $TARGET_HOSTNAME" >> /etc/hosts

# 3. Security (Create Deploy User)
DEPLOY_PASS=$(echo "$BOOTSTRAP_ENV" | grep "^DEPLOY_USER_PASSWORD=" | cut -d'=' -f2 | xargs || echo "")

if [[ -n "$DEPLOY_PASS" ]]; then
    if ! id "deploy" &>/dev/null; then
        echo "👤 Creating 'deploy' user..."
        useradd -m -s /bin/bash deploy
        echo "deploy:$DEPLOY_PASS" | chpasswd
        usermod -aG sudo,docker deploy
        # Allow sudo without password for deploy user (automation friendly)
        echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
        
        # Setup path in .bashrc
        echo 'export PATH=$PATH:/opt/platform/bin' >> /home/deploy/.bashrc
        mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
        cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys 2>/dev/null || true
        chown -R deploy:deploy /home/deploy/.ssh
    else
        echo "ℹ️  'deploy' user already exists."
    fi
fi

# 4. Tailscale Integration
if ! command -v tailscale &>/dev/null; then
    echo "📦 Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | bash
fi

if [[ -n "$TAILSCALE_KEY" && "$TAILSCALE_KEY" != "null" ]]; then
    echo "🔑 Authenticating with Tailscale..."
    tailscale up --authkey "${TAILSCALE_KEY}" --hostname "${TARGET_HOSTNAME}" --accept-routes --ssh
else
    echo "ℹ️  Run 'tailscale up' manually to authenticate."
fi

# 8. Clone Private Core Repo
echo "📦 Cloning private platform core via HTTPS..."
rm -rf "$INSTALL_DIR"
git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "$INSTALL_DIR"

# 9. Trigger Platform Initialization
echo "🚀 Triggering Platform Initialization..."
# Pass the session to init so it doesn't have to re-auth
export BW_SESSION="$BW_SESSION"
bash "$INSTALL_DIR/bootstrap/platform-init.sh"

# 10. Success Guidance
TS_IP=$(tailscale ip -4 | head -n 1 || echo "unknown")
SSH_USER="root"
[[ -n "$DEPLOY_PASS" ]] && SSH_USER="deploy"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║ 🎉 LE-Platform Bootstrap Phase 1 & 2 Complete!             ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ System Hostname: $TARGET_HOSTNAME"
echo "✅ Timezone:        $TARGET_TZ"
echo "✅ Tailscale IP:    $TS_IP"
[[ -n "$DEPLOY_PASS" ]] && echo "✅ User Provisioned: $SSH_USER"
echo ""
echo "🚀 Next Steps:"
echo "1. Log out of this root session."
echo "2. Log back in via Tailscale SSH for better security:"
echo "   ssh $SSH_USER@$TS_IP"
echo ""
echo "3. Application Management:"
echo "   - To restore your previous apps: platform system restore"
echo "   - To add a new app manually:    platform app add <name>"
echo ""
echo "--------------------------------------------------------------"
