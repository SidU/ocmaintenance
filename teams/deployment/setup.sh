#!/usr/bin/env bash
# Setup OpenClaw in Docker with latest main + register an Azure Bot for Teams.
#
# Prerequisites:
#   - Azure CLI installed and logged in (`az login`)
#   - Dev tunnel CLI (`brew install --cask devtunnel` on macOS)
#   - Docker and Docker Compose
#   - OpenClaw repo cloned
#
# Usage:
#   ./setup-openclaw-teams.sh                      # full setup (first time)
#   ./setup-openclaw-teams.sh --skip-azure         # rebuild + restart only
#   ./setup-openclaw-teams.sh --skip-docker        # Azure bot setup only
#
# Environment variables (override defaults):
#   OPENCLAW_DIR         - path to openclaw repo (default: ~/r/openclaw)
#   RESOURCE_GROUP       - Azure resource group (default: openclaw-testing)
#   BOT_DISPLAY_NAME     - Bot display name (default: openclaw-test-bot-<random>)
#   TUNNEL_NAME          - Dev tunnel name (default: openclaw-gw-tunnel)
#   TUNNEL_HOST_PORT     - Host port mapped to container 3978 (default: 3979)
#   ANTHROPIC_API_KEY    - If set, configures auth profile automatically

set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/r/openclaw}"
RESOURCE_GROUP="${RESOURCE_GROUP:-openclaw-testing}"
BOT_DISPLAY_NAME="${BOT_DISPLAY_NAME:-openclaw-test-bot-$(date +%s | tail -c 6)}"
TUNNEL_NAME="${TUNNEL_NAME:-openclaw-gw-tunnel}"
TUNNEL_HOST_PORT="${TUNNEL_HOST_PORT:-3979}"
SKIP_AZURE=false
SKIP_DOCKER=false

for arg in "$@"; do
  case "$arg" in
    --skip-azure)  SKIP_AZURE=true ;;
    --skip-docker) SKIP_DOCKER=true ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
  esac
done

log() { echo ""; echo "===> $1"; }
info() { echo "     $1"; }
warn() { echo "     [WARN] $1"; }

# ── Prerequisite checks ──────────────────────────────────────
log "Checking prerequisites..."

if [ "$SKIP_DOCKER" = false ]; then
  if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found. Install Docker first."; exit 1
  fi
  info "docker: $(docker --version | head -1)"
fi

if [ "$SKIP_AZURE" = false ]; then
  if ! command -v az &>/dev/null; then
    echo "ERROR: az CLI not found. Install with: brew install azure-cli"; exit 1
  fi
  info "az CLI: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null)"

  if ! command -v devtunnel &>/dev/null; then
    echo "ERROR: devtunnel not found. Install with: brew install --cask devtunnel"; exit 1
  fi
  info "devtunnel: found"
fi

if [ ! -d "$OPENCLAW_DIR" ]; then
  echo "ERROR: OpenClaw repo not found at $OPENCLAW_DIR"; exit 1
fi
info "repo: $OPENCLAW_DIR"

# ── Docker build ──────────────────────────────────────────────
if [ "$SKIP_DOCKER" = false ]; then
  log "Switching to latest main and pulling..."
  cd "$OPENCLAW_DIR"

  git checkout main 2>/dev/null
  git pull --ff-only
  info "HEAD is now at $(git rev-parse --short HEAD)"

  log "Building Docker image (this may take a few minutes)..."
  info "Image tag: openclaw:main"
  info "Build arg: OPENCLAW_EXTENSIONS=msteams (includes @microsoft/agents-hosting)"

  docker build \
    --build-arg OPENCLAW_EXTENSIONS="msteams" \
    -t openclaw:main .

  info "Docker image openclaw:main built successfully."
  info "Image size: $(docker images openclaw:main --format '{{.Size}}')"
fi

# ── Azure Bot registration ────────────────────────────────────
if [ "$SKIP_AZURE" = false ]; then
  log "Creating Azure resource group '$RESOURCE_GROUP' in westus2..."
  az group create --name "$RESOURCE_GROUP" --location westus2 -o none 2>/dev/null || true
  info "Resource group ready."

  log "Creating Azure AD App Registration (SingleTenant)..."
  info "Display name: $BOT_DISPLAY_NAME"
  APP_ID=$(az ad app create \
    --display-name "$BOT_DISPLAY_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --query appId -o tsv)
  info "App ID: $APP_ID"

  log "Creating service principal for the app (required for bot to respond)..."
  az ad sp create --id "$APP_ID" -o none 2>/dev/null || true
  info "Service principal created."

  log "Generating client secret..."
  APP_SECRET=$(az ad app credential reset \
    --id "$APP_ID" \
    --display-name "Bot Secret" \
    --query password -o tsv)
  info "Client secret generated (will be written to openclaw config)."

  TENANT_ID=$(az account show --query tenantId -o tsv)
  info "Tenant ID: $TENANT_ID"

  # ── Dev tunnel ────────────────────────────────────────────────
  log "Setting up dev tunnel '$TUNNEL_NAME' on port $TUNNEL_HOST_PORT..."

  devtunnel create "$TUNNEL_NAME" --allow-anonymous 2>/dev/null || true
  info "Tunnel created (or already exists)."

  devtunnel port create "$TUNNEL_NAME" -p "$TUNNEL_HOST_PORT" 2>/dev/null || true
  info "Port $TUNNEL_HOST_PORT registered on tunnel."

  log "Starting tunnel host (killing any existing instance first)..."
  pkill -f "devtunnel host $TUNNEL_NAME" 2>/dev/null || true
  sleep 1

  devtunnel host "$TUNNEL_NAME" &
  TUNNEL_PID=$!
  info "Tunnel host started (PID: $TUNNEL_PID). Waiting for URL..."
  sleep 3

  TUNNEL_URL=$(devtunnel show "$TUNNEL_NAME" --json 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
ports = d.get('tunnel', {}).get('ports', [])
url = ports[0]['portUri'].rstrip('/') if ports else ''
print(url)
" 2>/dev/null || echo "")

  if [ -z "$TUNNEL_URL" ]; then
    warn "Could not determine tunnel URL. You will need to set the messaging endpoint manually."
    TUNNEL_URL="https://YOUR-TUNNEL-URL"
  else
    info "Tunnel URL: $TUNNEL_URL"
  fi

  # ── Register Azure Bot + enable Teams channel ──────────────────
  log "Registering Azure Bot with messaging endpoint..."
  info "Endpoint: ${TUNNEL_URL}/api/messages"

  az bot create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BOT_DISPLAY_NAME" \
    --app-type SingleTenant \
    --appid "$APP_ID" \
    --tenant-id "$TENANT_ID" \
    --endpoint "${TUNNEL_URL}/api/messages" \
    -o none
  info "Azure Bot '$BOT_DISPLAY_NAME' registered."

  log "Enabling Microsoft Teams channel on the bot..."
  az bot msteams create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BOT_DISPLAY_NAME" \
    -o none
  info "Teams channel enabled."

  # ── Configure OpenClaw ──────────────────────────────────────────
  log "Configuring OpenClaw (~/.openclaw/openclaw.json)..."

  OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
  mkdir -p "$OPENCLAW_CONFIG_DIR"

  CONFIG_FILE="$OPENCLAW_CONFIG_DIR/openclaw.json"
  if [ -f "$CONFIG_FILE" ]; then
    info "Existing config found — merging msteams settings..."
    python3 -c "
import json, sys

with open('$CONFIG_FILE') as f:
    config = json.load(f)

config.setdefault('channels', {})
config['channels']['msteams'] = {
    'enabled': True,
    'appId': '$APP_ID',
    'appPassword': '$APP_SECRET',
    'tenantId': '$TENANT_ID',
    'webhook': {'port': 3978, 'path': '/api/messages'},
    'dmPolicy': 'open',
    'groupPolicy': 'open'
}
config.setdefault('gateway', {})['mode'] = 'local'
config.setdefault('plugins', {}).setdefault('entries', {})['msteams'] = {'enabled': True}

with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
"
    info "Updated $CONFIG_FILE"
  else
    info "No existing config — creating fresh openclaw.json..."
    cat > "$CONFIG_FILE" <<EOJSON
{
  "channels": {
    "msteams": {
      "enabled": true,
      "appId": "$APP_ID",
      "appPassword": "$APP_SECRET",
      "tenantId": "$TENANT_ID",
      "webhook": {
        "port": 3978,
        "path": "/api/messages"
      },
      "dmPolicy": "open",
      "groupPolicy": "open"
    }
  },
  "gateway": {
    "mode": "local"
  },
  "plugins": {
    "entries": {
      "msteams": { "enabled": true }
    }
  }
}
EOJSON
    info "Created $CONFIG_FILE"
  fi

  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log "Configuring Anthropic auth profile..."
    AUTH_DIR="$OPENCLAW_CONFIG_DIR/agents/main/agent"
    mkdir -p "$AUTH_DIR"
    cat > "$AUTH_DIR/auth-profiles.json" <<EOJSON
{
  "profiles": {
    "anthropic:default": {
      "type": "api_key",
      "provider": "anthropic",
      "key": "$ANTHROPIC_API_KEY"
    }
  }
}
EOJSON
    info "Auth profile written to $AUTH_DIR/auth-profiles.json"
  else
    info "ANTHROPIC_API_KEY not set — skipping auth profile. Set it manually later."
  fi

  log "Saving bot metadata for later use (branch switching, cleanup)..."
  cat > "$OPENCLAW_CONFIG_DIR/.azure-bot-metadata.json" <<EOJSON
{
  "botName": "$BOT_DISPLAY_NAME",
  "appId": "$APP_ID",
  "tenantId": "$TENANT_ID",
  "resourceGroup": "$RESOURCE_GROUP",
  "tunnelName": "$TUNNEL_NAME",
  "tunnelUrl": "$TUNNEL_URL",
  "tunnelHostPort": "$TUNNEL_HOST_PORT",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON
  info "Saved to $OPENCLAW_CONFIG_DIR/.azure-bot-metadata.json"
fi

# ── Start gateway container ──────────────────────────────────────
if [ "$SKIP_DOCKER" = false ]; then
  log "Preparing .env for Docker Compose..."
  cd "$OPENCLAW_DIR"

  if [ -f .env ]; then
    if grep -q "^OPENCLAW_IMAGE=" .env; then
      sed -i '' 's|^OPENCLAW_IMAGE=.*|OPENCLAW_IMAGE=openclaw:main|' .env
      info "Updated OPENCLAW_IMAGE=openclaw:main in .env"
    else
      echo "OPENCLAW_IMAGE=openclaw:main" >> .env
      info "Appended OPENCLAW_IMAGE=openclaw:main to .env"
    fi
    if ! grep -q "^OPENCLAW_MSTEAMS_PORT=" .env; then
      echo "OPENCLAW_MSTEAMS_PORT=${TUNNEL_HOST_PORT:-3979}" >> .env
      info "Appended OPENCLAW_MSTEAMS_PORT=${TUNNEL_HOST_PORT:-3979} to .env"
    fi
  fi

  log "Stopping any existing gateway container..."
  docker compose down 2>/dev/null || true

  log "Starting gateway container (openclaw:main)..."
  OPENCLAW_IMAGE=openclaw:main docker compose up -d openclaw-gateway

  log "Waiting for gateway to initialize (8s)..."
  sleep 8

  log "Checking msteams channel status..."
  if docker compose logs --tail 30 openclaw-gateway 2>&1 | grep -q "\[msteams\].*starting provider"; then
    if docker compose logs --tail 30 openclaw-gateway 2>&1 | grep -q "\[msteams\].*channel exited"; then
      warn "msteams channel failed to start. Check logs:"
      warn "  docker compose logs openclaw-gateway | grep msteams"
    else
      info "msteams channel started successfully on port 3978."
    fi
  else
    warn "msteams channel log not found. Check: docker compose logs openclaw-gateway"
  fi
fi

# ── Teams app package ──────────────────────────────────────────
if [ "$SKIP_AZURE" = false ]; then
  log "Creating Teams app package for sideloading..."

  APP_PACKAGE_DIR="/tmp/openclaw-teams-app"
  rm -rf "$APP_PACKAGE_DIR"
  mkdir -p "$APP_PACKAGE_DIR"

  info "Generating manifest.json with bot ID $APP_ID..."
  cat > "$APP_PACKAGE_DIR/manifest.json" <<EOJSON
{
  "\$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.20/MicrosoftTeams.schema.json",
  "manifestVersion": "1.20",
  "version": "1.0.0",
  "id": "$(uuidgen | tr '[:upper:]' '[:lower:]')",
  "developer": {
    "name": "OpenClaw Test",
    "websiteUrl": "https://openclaw.ai",
    "privacyUrl": "https://openclaw.ai/privacy",
    "termsOfUseUrl": "https://openclaw.ai/privacy"
  },
  "name": {
    "short": "OpenClaw Test Bot",
    "full": "OpenClaw Teams Test Bot"
  },
  "description": {
    "short": "Test bot for OpenClaw MS Teams changes",
    "full": "Test bot for validating OpenClaw MS Teams channel integration"
  },
  "icons": {
    "color": "color.png",
    "outline": "outline.png"
  },
  "accentColor": "#6264A7",
  "bots": [
    {
      "botId": "$APP_ID",
      "scopes": ["personal", "team", "groupChat"],
      "supportsFiles": true,
      "isNotificationOnly": false
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": []
}
EOJSON

  info "Generating placeholder icons (192x192 color, 32x32 outline)..."
  python3 -c "
import struct, zlib
def png(w, h, r, g, b, a=255):
    raw = b''
    for y in range(h):
        raw += b'\x00' + bytes([r,g,b,a]) * w
    def chunk(t, d):
        c = t + d
        return struct.pack('>I',len(d)) + c + struct.pack('>I',zlib.crc32(c)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0)) + chunk(b'IDAT',zlib.compress(raw)) + chunk(b'IEND',b'')
open('$APP_PACKAGE_DIR/color.png','wb').write(png(192,192,98,100,167))
open('$APP_PACKAGE_DIR/outline.png','wb').write(png(32,32,255,255,255))
"

  info "Packaging into zip..."
  (cd "$APP_PACKAGE_DIR" && zip -q -r /tmp/openclaw-test-bot.zip manifest.json color.png outline.png)
  info "App package ready: /tmp/openclaw-test-bot.zip"
fi

# ── Summary ────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Setup complete!"
echo "=========================================="
if [ "$SKIP_AZURE" = false ]; then
  echo ""
  echo "Azure Bot:"
  echo "  Name:     $BOT_DISPLAY_NAME"
  echo "  App ID:   $APP_ID"
  echo "  Tenant:   $TENANT_ID"
  echo "  Endpoint: ${TUNNEL_URL:-<unknown>}/api/messages"
  echo "  Tunnel:   kill $TUNNEL_PID to stop"
fi
echo ""
echo "Next steps:"
echo "  1. Sideload /tmp/openclaw-test-bot.zip in Teams"
echo "     (Apps > Manage your apps > Upload a custom app)"
echo "  2. Send a message to the bot to test"
echo ""
echo "Useful commands:"
echo "  docker compose logs -f openclaw-gateway    # gateway logs"
echo "  docker compose restart openclaw-gateway    # restart"
echo "  docker compose down                        # stop"
echo ""
echo "To test a different branch later:"
echo "  ./openclaw-test-branch.sh <user>/<repo> <branch>"
echo ""
echo "Cleanup:"
echo "  az bot delete --resource-group $RESOURCE_GROUP --name $BOT_DISPLAY_NAME"
echo "  az ad app delete --id ${APP_ID:-\$APP_ID}"
echo "  az group delete --name $RESOURCE_GROUP --yes"
