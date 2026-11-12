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

### Changed

- ADR 0002: SSH restricted to the mesh interface and passwords turned off on both nodes (2026-11-11); remaining checks listed.
- Architecture overview and diagram: the remote management server uses its embedded database, no separate database server.
