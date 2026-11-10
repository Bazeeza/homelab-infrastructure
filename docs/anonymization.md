# Anonymization rules

This repository describes a real, running infrastructure. It is public, so every value that could locate, identify or attack it is replaced by a placeholder **before** it is written here. This page is the reference for those placeholders and for what is never published.

> [!IMPORTANT]
> A value that reached a public Git repository must be treated as leaked, even if the commit is deleted later: forks, caches and clones keep it. Rotating the secret or changing the address is the only real fix. Prevention is cheaper.

## Placeholders used everywhere

| Real item | Placeholder in this repository | Why it is hidden |
|---|---|---|
| Critical server (remote management, monitoring) | `node-a` | A real hostname helps an attacker guess the provider, the region and the role. |
| Automation server (workflows, alert relay, cross-check) | `node-b` | Same reason. |
| Administrator laptop | `admin-ws` | The workstation is the starting point of every administrative session. |
| Public domain and sub-domains | `example.com`, `remote.example.com` | `example.com` is reserved for documentation ([RFC 2606](https://www.rfc-editor.org/rfc/rfc2606)). |
| Public IPv4 addresses | `198.51.100.0/24`, `203.0.113.0/24` | Ranges reserved for documentation ([RFC 5737](https://www.rfc-editor.org/rfc/rfc5737)). |
| Mesh VPN addresses (real ones are in the `100.64/10` range) | `192.0.2.10` (node-a), `192.0.2.20` (node-b), `192.0.2.30` (admin-ws) | The real mesh addresses are stable and tied to the account. The documentation range keeps the examples readable. |
| Administrative Linux account | `<ADMIN_USER>` | A valid user name is half of a login attempt. |
| Telegram user ID and bot token | `<TELEGRAM_USER_ID>`, `<TELEGRAM_BOT_TOKEN>` | The ID is the only filter between the bot and strangers; the token *is* the bot. |
| Tunnel ID, API keys, encryption keys | `<TUNNEL_ID>`, `<API_KEY>`, `<N8N_ENCRYPTION_KEY>` | Credentials. |
| Hosting providers | "provider 1", "provider 2" | Not needed to understand the design; named only where a provider feature matters. |

## Never published, even anonymized

- Secret **values** of any kind. The documentation names *where* a secret lives (for example `/etc/<service>/secret`) and *who* can read it, never its content.
- Exact listening ports of services that are not meant to be public, when combined with a real address.
- Account recovery details, backup locations off the servers, personal information about the owner.
- Projects unrelated to this infrastructure that ran on the same servers.

## How the rules are enforced

1. **Placeholders at writing time.** Configuration files are copied into this repository only after every value is replaced by an environment variable or a placeholder from the table above.
2. **`.gitignore`.** `.env` files, private keys, Terraform state and local backups are ignored ([`.gitignore`](../.gitignore)).
3. **Automatic check on every push and pull request.** [`scripts/check-public-safety.sh`](../scripts/check-public-safety.sh) fails the build if it finds an IPv4 address outside the documentation ranges, a mesh VPN address, a private key, a known token format or a sensitive file name. It also accepts extra private patterns (real hostnames, real domains) from a repository secret, so the list of what to hide is never itself published. See [How the safety check works](#how-the-safety-check-works).

## How the safety check works

```bash
# From the root of the repository
bash scripts/check-public-safety.sh

# With extra private patterns, one extended regular expression per line,
# kept outside the repository (never commit this file)
EXTRA_PATTERNS_FILE=~/private-patterns.txt bash scripts/check-public-safety.sh
```

In GitHub Actions the extra patterns come from the `PUBLIC_SAFETY_PATTERNS` repository secret. If the secret is not defined, only the generic rules run.

| Rule | What it catches | Allowed exceptions |
|---|---|---|
| IPv4 address | Any `a.b.c.d` address | `127.0.0.0/8`, `0.0.0.0`, the three documentation ranges of RFC 5737 |
| Mesh VPN address | Addresses in the `100.64/10` shared range (carrier-grade NAT space used by the mesh VPN) | None |
| Private key | PEM private key headers | None |
| Token formats | GitHub, AWS, Slack and Telegram bot token formats | None |
| Sensitive files | Tracked `.env`, key, certificate, `.tfstate` and `.tfvars` files | `.env.example`, `*.tfvars.example` |
| Extra patterns | Whatever the secret lists | None |

Reference: [GitHub Docs, Using secrets in GitHub Actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions), [RFC 5737](https://www.rfc-editor.org/rfc/rfc5737), [RFC 6598 (shared address space)](https://www.rfc-editor.org/rfc/rfc6598).
