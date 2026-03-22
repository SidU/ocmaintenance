#!/usr/bin/env bash
# Quick script to build and run OpenClaw in Docker from a given branch/PR.
# Usage:
#   ./openclaw-test-branch.sh <github-user>/<repo> <branch-name>
#   ./openclaw-test-branch.sh cwatts-sage/openclaw fix/msteams-file-consent-card-update
#
# Prerequisites (one-time setup):
#   - Azure bot registered (openclaw-testing resource group)
#   - ~/.openclaw/openclaw.json configured (gateway.mode, channels.msteams, auth)
#   - Dev tunnel created: devtunnel create openclaw-gw-tunnel --allow-anonymous
#   - Teams app package sideloaded

set -euo pipefail

REPO="${1:?Usage: $0 <github-user/repo> <branch-name>}"
BRANCH="${2:?Usage: $0 <github-user/repo> <branch-name>}"
OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/r/openclaw}"
TUNNEL_NAME="${TUNNEL_NAME:-openclaw-gw-tunnel}"

cd "$OPENCLAW_DIR"

echo "==> Fetching $BRANCH from $REPO..."
git fetch "https://github.com/${REPO}.git" "$BRANCH"
LOCAL_BRANCH="${REPO%%/*}/${BRANCH}"
git checkout FETCH_HEAD -B "$LOCAL_BRANCH"

echo "==> Building Docker image..."
docker build --build-arg OPENCLAW_EXTENSIONS="msteams" -t openclaw:local -f Dockerfile .

echo "==> Restarting gateway..."
docker compose down 2>/dev/null || true
docker compose up -d openclaw-gateway

echo "==> Starting dev tunnel..."
# Kill any existing tunnel host
pkill -f "devtunnel host $TUNNEL_NAME" 2>/dev/null || true
sleep 1
devtunnel host "$TUNNEL_NAME" &
TUNNEL_PID=$!
sleep 3

# Get tunnel URL
TUNNEL_URL=$(devtunnel show "$TUNNEL_NAME" --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); ports=d.get('tunnel',{}).get('ports',[]); print(ports[0]['portUri'].rstrip('/') if ports else '')" 2>/dev/null || echo "")

if [ -n "$TUNNEL_URL" ]; then
  echo "==> Tunnel URL: $TUNNEL_URL"

  # Update Azure bot endpoint if BOT_NAME and RESOURCE_GROUP are set
  if [ -n "${BOT_NAME:-}" ] && [ -n "${RESOURCE_GROUP:-}" ]; then
    echo "==> Updating Azure bot endpoint..."
    az bot update \
      --resource-group "$RESOURCE_GROUP" \
      --name "$BOT_NAME" \
      --endpoint "${TUNNEL_URL}/api/messages" \
      -o none
    echo "    Endpoint: ${TUNNEL_URL}/api/messages"
  else
    echo "    Set BOT_NAME and RESOURCE_GROUP env vars to auto-update Azure bot endpoint"
  fi
fi

echo ""
echo "==> Gateway running. Waiting for msteams channel..."
sleep 8
docker compose logs --tail 5 openclaw-gateway 2>&1 | grep -i "msteams" || true

echo ""
echo "Done. Send a message to the bot in Teams to test."
echo "Logs: docker compose logs -f openclaw-gateway"
echo "Tunnel PID: $TUNNEL_PID (kill $TUNNEL_PID to stop)"
