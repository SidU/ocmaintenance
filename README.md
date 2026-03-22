# OpenClaw Maintenance

Internal maintenance docs, deployment scripts, test plans, and test evidence for [OpenClaw](https://github.com/openclaw/openclaw).

## Teams Plugin

### Deployment

- [VM Setup](teams/deployment/vm-setup.md) — Azure VM creation, Caddy HTTPS, systemd service, deploy workflow
- [Bot Registration](teams/deployment/bot-registration.md) — Azure Bot + dev tunnel + Teams app package
- [setup.sh](teams/deployment/setup.sh) — Automated setup script

### Testing

- [Test Plan](teams/testing/test-plan.md) — Reusable manual test plan (30 tests across 7 categories)
- [Test Reports](teams/testing/reports/) — Timestamped reports with steps, expected/actual, screenshots
- [Screenshots](teams/testing/screenshots/) — Test evidence images

### Plans

- [AI UX Best Practices](teams/plans/ai-ux.md)
- [Activity Events](teams/plans/activity-events.md)
- [Bot Actions](teams/plans/bot-actions.md)

### Scripts

- [test-branch.sh](teams/scripts/test-branch.sh) — Switch branches for testing
