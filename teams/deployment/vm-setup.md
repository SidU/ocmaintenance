# Azure VM Deployment for OpenClaw Teams Bot

Deploy OpenClaw with the Teams plugin to an Azure VM for shared testing. This uses a persistent VM instead of dev tunnels, so testers can use the bot without you running anything locally.

## Current Deployment

- **VM:** `riley-inbestments.westus2.cloudapp.azure.com` (IP: `4.154.188.23`)
- **SKU:** Standard_D2ps_v6 (ARM64, 2 vCPUs, 8GB RAM)
- **OS:** Ubuntu 24.04 LTS
- **Resource Group:** INBESTMENTS-RG
- **Azure Bot:** `riley-cofs-manager` (display name: "OpenClaw Bot")
- **App ID:** `4671c526-70bc-4652-a862-d2300f539f69`
- **Tenant ID:** `e3212828-419c-41f9-a76d-0002ba820c4e`
- **Branch:** `claude/migrate-teams-sdk-PKHin` (from `SidU/openclaw` fork)
- **Teams app package:** `/tmp/openclaw-teams-app.zip` (sideload in Teams)

## Architecture

```
Teams Cloud
  └─ POST /api/messages ──▶ Caddy (port 443, auto-HTTPS)
                              ├─ /api/messages ──▶ msteams Express (port 3979)
                              └─ everything else ──▶ OpenClaw gateway (port 3978)
```

- **Caddy** handles TLS (Let's Encrypt auto-cert) and routes traffic
- **msteams plugin** runs its own Express server on port 3979
- **OpenClaw gateway** runs on port 3978 (loopback only)
- Both managed by a single `openclaw-gateway` systemd service

## SSH Access

```bash
ssh azureuser@4.154.188.23
# or
ssh azureuser@riley-inbestments.westus2.cloudapp.azure.com
```

## Deploy Local Changes

Push your branch to the fork, then pull and rebuild on the VM:

```bash
# From your local machine
git push origin claude/migrate-teams-sdk-PKHin

# On the VM
ssh azureuser@4.154.188.23 'cd ~/openclaw && git pull && pnpm build && sudo systemctl restart openclaw-gateway'
```

Or as a one-liner from local:

```bash
git push origin claude/migrate-teams-sdk-PKHin && ssh azureuser@4.154.188.23 'cd ~/openclaw && git pull && pnpm build && sudo systemctl restart openclaw-gateway'
```

## Check Status

```bash
# Gateway service status
ssh azureuser@4.154.188.23 'sudo systemctl status openclaw-gateway --no-pager'

# Recent logs
ssh azureuser@4.154.188.23 'sudo journalctl -u openclaw-gateway --since "5 min ago" --no-pager'

# msteams-specific logs
ssh azureuser@4.154.188.23 'grep msteams /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | tail -20'

# Verify ports are listening
ssh azureuser@4.154.188.23 'ss -tlnp | grep -E "3978|3979"'

# Test HTTPS endpoint externally (401 = working, rejects unauthenticated)
curl -s -o /dev/null -w "%{http_code}" -X POST https://riley-inbestments.westus2.cloudapp.azure.com/api/messages -H "Content-Type: application/json" -d '{}'
```

## Key Config Files on the VM

### Systemd service: `/etc/systemd/system/openclaw-gateway.service`

Contains env vars: `MSTEAMS_APP_ID`, `MSTEAMS_APP_PASSWORD`, `MSTEAMS_TENANT_ID`, `ANTHROPIC_API_KEY`.

After editing:
```bash
sudo systemctl daemon-reload && sudo systemctl restart openclaw-gateway
```

### Caddy config: `/etc/caddy/Caddyfile`

Routes `/api/messages` to msteams (3979), everything else to gateway (3978).

After editing:
```bash
sudo systemctl reload caddy
```

### OpenClaw config: `~/.openclaw/openclaw.json`

Contains gateway settings, plugin enablement, and channel credentials.

## Install Teams App for Testers

1. Open Microsoft Teams
2. **Apps** > **Manage your apps** > **Upload an app** > **Upload a custom app**
3. Select `openclaw-teams-app.zip`
4. Click **Add**
5. Find "OpenClaw Bot" and send a message

## Recreating the VM from Scratch

If you need to rebuild from zero:

```bash
# 1. Delete old VM
az vm delete -g INBESTMENTS-RG -n riley-vm --yes

# 2. Clean up orphaned resources
az disk list -g INBESTMENTS-RG --query '[].name' -o tsv | xargs -I{} az disk delete -g INBESTMENTS-RG -n {} --yes
az network nic list -g INBESTMENTS-RG --query '[].name' -o tsv | xargs -I{} az network nic delete -g INBESTMENTS-RG -n {}

# 3. Create fresh VM (reuses existing public IP and NSG)
az vm create \
  -g INBESTMENTS-RG \
  -n riley-vm \
  --image Canonical:ubuntu-24_04-lts:server-arm64:latest \
  --size Standard_D2ps_v6 \
  --location westus2 \
  --public-ip-address riley-vmPublicIP \
  --nsg riley-vmNSG \
  --admin-username azureuser \
  --generate-ssh-keys \
  --os-disk-size-gb 30

# 4. Remove stale SSH host key (same IP, new host keys)
ssh-keygen -R 4.154.188.23

# 5. Install Node 22
ssh azureuser@4.154.188.23 'curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs'

# 6. Install pnpm
ssh azureuser@4.154.188.23 'sudo npm install -g pnpm'

# 7. Install Caddy
ssh azureuser@4.154.188.23 'sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl && curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" | sudo tee /etc/apt/sources.list.d/caddy-stable.list && sudo apt-get update && sudo apt-get install -y caddy'

# 8. Configure Caddy
ssh azureuser@4.154.188.23 'cat << '\''EOF'\'' | sudo tee /etc/caddy/Caddyfile
riley-inbestments.westus2.cloudapp.azure.com {
    handle /api/messages {
        reverse_proxy localhost:3979
    }
    handle {
        reverse_proxy localhost:3978
    }
}
EOF
sudo systemctl restart caddy'

# 9. Clone repo and build
ssh azureuser@4.154.188.23 'git clone --branch claude/migrate-teams-sdk-PKHin --single-branch https://github.com/SidU/openclaw.git ~/openclaw && cd ~/openclaw && pnpm install --frozen-lockfile && pnpm build'

# 10. Install msteams extension runtime deps
ssh azureuser@4.154.188.23 'cd ~/openclaw/dist/extensions/msteams && node -e "const p=require(\"./package.json\"); delete p.devDependencies; require(\"fs\").writeFileSync(\"package.json\",JSON.stringify(p,null,2))" && npm install --omit=dev'

# 11. Enable msteams plugin and configure
ssh azureuser@4.154.188.23 'cd ~/openclaw && node dist/index.js config set gateway.mode local && node dist/index.js config set gateway.port 3978 && node dist/index.js plugins enable msteams && node dist/index.js config set channels.msteams.enabled true && node dist/index.js config set channels.msteams.appId 4671c526-70bc-4652-a862-d2300f539f69 && node dist/index.js config set channels.msteams.appPassword "<APP_SECRET>" && node dist/index.js config set channels.msteams.tenantId e3212828-419c-41f9-a76d-0002ba820c4e && node dist/index.js config set channels.msteams.webhook.port 3979'

# 12. Create systemd service (replace <APP_SECRET> and <ANTHROPIC_KEY>)
ssh azureuser@4.154.188.23 'cat << '\''EOF'\'' | sudo tee /etc/systemd/system/openclaw-gateway.service
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/home/azureuser/openclaw
Environment=MSTEAMS_APP_ID=4671c526-70bc-4652-a862-d2300f539f69
Environment=MSTEAMS_APP_PASSWORD=<APP_SECRET>
Environment=MSTEAMS_TENANT_ID=e3212828-419c-41f9-a76d-0002ba820c4e
Environment=ANTHROPIC_API_KEY=<ANTHROPIC_KEY>
ExecStart=/usr/bin/node /home/azureuser/openclaw/dist/index.js gateway run --bind loopback --port 3978 --force
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable openclaw-gateway && sudo systemctl start openclaw-gateway'
```

## Rotating the Bot Secret

```bash
# Create new secret
az ad app credential reset --id 4671c526-70bc-4652-a862-d2300f539f69 --append --display-name "riley-vm-openclaw"

# Update on VM (edit the systemd service and openclaw.json, then restart)
ssh azureuser@4.154.188.23 'cd ~/openclaw && node dist/index.js config set channels.msteams.appPassword "<NEW_SECRET>"'
# Also update /etc/systemd/system/openclaw-gateway.service, then:
ssh azureuser@4.154.188.23 'sudo systemctl daemon-reload && sudo systemctl restart openclaw-gateway'
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `EADDRINUSE :3978` from msteams | Set `channels.msteams.webhook.port` to 3979 (separate from gateway port) |
| 502 from Caddy | Gateway or msteams not running — check `systemctl status openclaw-gateway` |
| msteams keeps restarting | Check `journalctl -u openclaw-gateway` for errors; usually missing credentials |
| "MSTeams runtime not initialized" | Channel credentials not in config — run `config set channels.msteams.*` |
| SSH host key changed warning | `ssh-keygen -R 4.154.188.23` (expected after VM recreation) |
| Build fails on UNRESOLVED_IMPORT | Ensure `scripts/tsdown-build.mjs` allows `node_modules/` warnings |
| `workspace:*` npm install error | Delete `devDependencies` from `dist/extensions/msteams/package.json` before `npm install` |
