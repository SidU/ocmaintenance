# Setting Up a Teams Bot for OpenClaw Testing

One-time setup to register an Azure Bot and configure OpenClaw to receive messages from Microsoft Teams.

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Dev tunnel CLI installed (`brew install --cask devtunnel` on macOS)
- Docker and Docker Compose
- OpenClaw repo cloned at `~/r/openclaw`

## Step 1: Create Azure Resources

```bash
# Resource group for testing (one-time)
az group create --name openclaw-testing --location westus2

# Bot name must be globally unique
BOT_NAME="openclaw-test-bot-$(date +%s | tail -c 6)"

# Create Azure AD App Registration (SingleTenant — MultiTenant is deprecated)
APP_ID=$(az ad app create \
  --display-name "$BOT_NAME" \
  --sign-in-audience "AzureADMyOrg" \
  --query appId -o tsv)

# CRITICAL: Create a Service Principal (without this the bot can't respond)
az ad sp create --id $APP_ID

# Create a client secret (save this — it won't be shown again)
APP_SECRET=$(az ad app credential reset \
  --id $APP_ID \
  --display-name "Bot Secret" \
  --query password -o tsv)

# Get your Tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)

# Print credentials — save these
echo "BOT_NAME:   $BOT_NAME"
echo "APP_ID:     $APP_ID"
echo "APP_SECRET: $APP_SECRET"
echo "TENANT_ID:  $TENANT_ID"
```

## Step 2: Create Dev Tunnel

```bash
devtunnel create openclaw-gw-tunnel --allow-anonymous
devtunnel port create openclaw-gw-tunnel -p 3979
devtunnel host openclaw-gw-tunnel &

# Note the tunnel URL from the output, e.g.:
# https://abc123-3979.usw2.devtunnels.ms
```

## Step 3: Register the Azure Bot

```bash
TUNNEL_URL="https://<your-tunnel-id>-3979.usw2.devtunnels.ms"

az bot create \
  --resource-group openclaw-testing \
  --name "$BOT_NAME" \
  --app-type SingleTenant \
  --appid "$APP_ID" \
  --tenant-id "$TENANT_ID" \
  --endpoint "${TUNNEL_URL}/api/messages"

# Enable the Teams channel
az bot msteams create \
  --resource-group openclaw-testing \
  --name "$BOT_NAME"
```

## Step 4: Fix OpenClaw Dockerfile

The Dockerfile needs extension `package.json` files copied before `pnpm install` so workspace dependencies (like `@microsoft/agents-hosting` for msteams) are installed. Add this line after the existing `COPY` commands and before `pnpm install`:

```dockerfile
COPY --chown=node:node --parents extensions/*/package.json packages/*/package.json ./
```

## Step 5: Expose Webhook Port in docker-compose.yml

Add port 3978 mapping under `openclaw-gateway.ports`:

```yaml
- "${OPENCLAW_MSTEAMS_PORT:-3979}:3978"
```

Use host port 3979 (or another free port) since 3978 may be occupied.

## Step 6: Configure OpenClaw

Edit `~/.openclaw/openclaw.json`:

```json
{
  "channels": {
    "msteams": {
      "enabled": true,
      "appId": "<APP_ID>",
      "appPassword": "<APP_SECRET>",
      "tenantId": "<TENANT_ID>",
      "webhook": {
        "port": 3978,
        "path": "/api/messages"
      },
      "dmPolicy": "open",
      "allowFrom": ["*"],
      "groupPolicy": "allowlist"
    }
  },
  "gateway": {
    "mode": "local"
  },
  "plugins": {
    "entries": {
      "msteams": { "enabled": true }
    },
    "installs": {}
  }
}
```

> **Important:** Do NOT install the msteams plugin from npm (`openclaw plugins install @openclaw/msteams`) when testing a branch that already bundles it. The downloaded version conflicts with the bundled one.

## Step 7: Configure Auth Profile

Create `~/.openclaw/agents/main/agent/auth-profiles.json`:

```json
{
  "profiles": {
    "anthropic:default": {
      "type": "api_key",
      "provider": "anthropic",
      "key": "<your-anthropic-api-key>"
    }
  }
}
```

> **Warning:** The format matters. Using `{ "anthropic": { "apiKey": "..." } }` will NOT work.

## Step 8: Build and Run

```bash
cd ~/r/openclaw
docker build -t openclaw:local -f Dockerfile .
docker compose up -d openclaw-gateway
```

## Step 9: Create Teams App Package

```bash
mkdir -p appPackage && cd appPackage

# Create manifest.json (replace placeholders)
cat > manifest.json << EOF
{
  "\$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.20/MicrosoftTeams.schema.json",
  "manifestVersion": "1.20",
  "version": "1.0.0",
  "id": "$(uuidgen)",
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
      "botId": "<APP_ID>",
      "scopes": ["personal", "team", "groupChat"],
      "supportsFiles": true,
      "isNotificationOnly": false
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["<your-tunnel-id>-3979.usw2.devtunnels.ms"]
}
EOF

# Generate placeholder icons (requires Python with PIL, or use any 192x192 / 32x32 PNGs)
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
open('color.png','wb').write(png(192,192,98,100,167))
open('outline.png','wb').write(png(32,32,255,255,255))
"

# Package
zip -r ../openclaw-test-bot.zip manifest.json color.png outline.png
```

## Step 10: Sideload in Teams

1. Open Microsoft Teams
2. **Apps** → **Manage your apps** → **Upload an app** → **Upload a custom app**
3. Select `openclaw-test-bot.zip`
4. Click **Add**
5. Find the bot and send a message to test

## Subsequent Branch Testing

Once the above is done, use `openclaw-test-branch.sh` to switch branches:

```bash
./openclaw-test-branch.sh cwatts-sage/openclaw fix/some-branch

# With auto Azure bot endpoint update:
BOT_NAME=openclaw-test-bot-23984 RESOURCE_GROUP=openclaw-testing \
  ./openclaw-test-branch.sh cwatts-sage/openclaw fix/some-branch
```

Only re-sideload the app package if the manifest changes.

## Cleanup

```bash
az bot delete --resource-group openclaw-testing --name $BOT_NAME
az ad app delete --id $APP_ID
az group delete --name openclaw-testing --yes
devtunnel delete openclaw-gw-tunnel --force
docker compose down
```

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| Bot receives messages but can't respond | Missing service principal | `az ad sp create --id $APP_ID` |
| "No API key found for provider anthropic" | Wrong auth-profiles.json format | Use `profiles` → `type: "api_key"` → `key` format |
| "Cannot find module '@microsoft/agents-hosting'" | Extension deps not in Docker image | Add `COPY --parents extensions/*/package.json` to Dockerfile |
| Gateway won't start: "set gateway.mode=local" | Missing config | Add `"mode": "local"` to `gateway` in openclaw.json |
| Port 3978 not reachable | Not exposed in docker-compose.yml | Add `3979:3978` port mapping |
| Duplicate plugin ID warning | npm-installed plugin conflicts with bundled | Remove `~/.openclaw/extensions/msteams/` |
| `docker compose exec` fails with "no configuration file" | CLI wrapper issue | Use `docker exec <container>` directly |
| Tunnel URL changed | Dev tunnel recreated | Update `az bot update --endpoint` and manifest `validDomains` |
