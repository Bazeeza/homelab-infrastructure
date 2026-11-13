# Changelog

All notable changes to this documentation are listed here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Architecture overview: role, size and services of `node-a`, `node-b` and `admin-ws`, traffic flows ([docs/architecture.md](docs/architecture.md)).
- SVG architecture diagram ([assets/architecture.svg](assets/architecture.svg)).
- Architecture decision records: index, template, ADR 0001 to 0004 ([docs/adr/](docs/adr/README.md)).
- Anonymization rules with the placeholder of every real value ([docs/anonymization.md](docs/anonymization.md)).
- Public safety check (`scripts/check-public-safety.sh`) with a `--staged` mode, a pre-commit hook and a CI workflow; ShellCheck, markdownlint and an offline link check in CI.
- Network design and access section: zones, address plan and port matrix; mesh VPN; SSH keys and hardening; host firewall; Docker on loopback; verification checklist ([docs/network/](docs/network/README.md)).
- Example configuration with placeholders: sshd hardening drop-in, admin-ws SSH client config, n8n Compose file (`configs/`).
- ADR 0005: publish container ports on loopback only.
- `scripts/ufw-baseline.sh` (prints the firewall plan, applies it only with `--apply`, refuses to cut the running SSH session) and `scripts/audit-listening-ports.sh` (flags sockets open on all interfaces), with offline tests run in CI.
- Monitoring section: overview of the three layers and who watches whom, Uptime Kuma guide, Beszel guide, cross-check guide with install, alert path test and rollback ([docs/monitoring/](docs/monitoring/README.md)).
- ADR 0006: watch each node from another node.
- `scripts/cross-check.sh` (generic rewrite of the cross-check of node-a: per-probe failure counter, one alert per outage, recovery message, configuration read as data) with an example configuration and cron schedule (`configs/monitoring/`).
- `scripts/kuma-status.sh` (one line per Uptime Kuma probe, problems first, API key kept out of the command line).
- Offline tests of both monitoring scripts, run in CI with the network tests.
- Telegram relay (`relay/telegram_relay.py`): generic rewrite of the relay on node-b, every installation value in environment variables, token through a systemd credential, loopback-only webhook, two filters.
- Hardened systemd unit and settings example for the relay (`configs/systemd/`), with `RestartPreventExitStatus=2` on configuration errors.
- `scripts/install-telegram-relay.sh`: dry-run mode, `--expect-host` guard, refuses a placeholder left in the settings or a token readable by others, never overwrites a unit.
- Relay unit tests with a fake Bot API and a fake webhook (`tests/test_telegram_relay.py`), run in CI on Python 3.10 and 3.12; installer tests in `tests/run-tests.sh`.
- Relay guide and line-by-line explanation of its unit ([docs/relay/](docs/relay/README.md)).
- ADR 0007: pull bot commands by long polling, never expose the workflow engine.

### Changed

- ADR 0002: SSH restricted to the mesh interface and passwords turned off on both nodes (2026-11-11); remaining checks listed.
- Architecture overview and diagram: the remote management server uses its embedded database, no separate database server.
