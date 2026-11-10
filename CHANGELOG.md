# Changelog

All notable changes to this documentation are listed here. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Architecture overview: role, size and services of `node-a`, `node-b` and `admin-ws`, traffic flows ([docs/architecture.md](docs/architecture.md)).
- SVG architecture diagram ([assets/architecture.svg](assets/architecture.svg)).
- Architecture decision records: index, template, ADR 0001 to 0004 ([docs/adr/](docs/adr/README.md)).
- Anonymization rules with the placeholder of every real value ([docs/anonymization.md](docs/anonymization.md)).
- Public safety check (`scripts/check-public-safety.sh`) with a `--staged` mode, a pre-commit hook and a CI workflow; ShellCheck, markdownlint and an offline link check in CI.
