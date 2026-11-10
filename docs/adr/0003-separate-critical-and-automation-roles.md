# 0003. Separate the critical node from the automation node

- **Status:** Accepted, applied
- **Decided:** 2026-10 (before the status bot was built; bot in service on 2026-10-23)
- **Applies to:** node-a, node-b

## Context

- **node-a is critical.** It runs the remote management server of the owner's devices. Whoever controls node-a can open a remote session on every managed computer. It also runs the monitoring that tells when something is down.
- **The automation is the most exposed part.** The status bot reads messages from Telegram, which anyone can send to a bot. Later it may read web pages or e-mails. The workflow engine (n8n) is a large application with many integrations and frequent updates. Input from outside plus a large code base is where bugs and injection attacks happen.
- If both ran on the same server, a flaw in the automation would be one step away from the remote management server. Containers on the same host do not change that: they share the kernel, and the Docker daemon runs as root.
- A server cannot reliably report its own failure: if node-a stops, its own monitoring stops with it.

## Decision

We will run **all automation on node-b and never on node-a**, and give it **read-only** access to node-a:

| Rule | How it is applied |
|---|---|
| No automation on node-a | n8n, the Telegram relay and the cross-check script run on node-b only. |
| Read-only data access | n8n reads the Uptime Kuma `/metrics` endpoint of node-a over the mesh VPN with a **read-only API key**. It has no SSH key and no shell on node-a. |
| Limited sudo for tooling | The administrative account used by tools has password-less `sudo` only for read-only commands (`docker ps`, `docker logs`, `docker inspect`, `docker stats`, `systemctl status`, `systemctl is-active`, `systemctl is-enabled`, `journalctl`). Everything else, including `docker exec`, asks for the password, so a human runs it. |
| Sandboxed relay | The Telegram relay is a systemd service with `DynamicUser=yes`, a read-only file system and a 64 MB memory limit. It reads the bot token through `LoadCredential=`, so the token is never in an environment variable or in the code. |
| Two filters | The relay ignores, without answering, any message that is not from the single allowed user ID (`<TELEGRAM_USER_ID>`) in a private chat, and forwards only known commands. n8n checks the sender and the command a second time. Free text never reaches n8n. |
| Cross-check | node-b probes node-a every 2 minutes and sends a Telegram alert after 3 consecutive failures, so an outage of node-a is reported by a machine that is still running. |

## Consequences

- **Positive:**
  - **Smaller blast radius.** A compromised automation node gives read access to monitoring data, not control of the managed devices.
  - node-b can be rebuilt from scratch without touching node-a.
  - Failures are reported from the outside: the watcher does not depend on the watched machine.
- **Negative:**
  - Two servers to patch and pay for instead of one.
  - The bot depends on the mesh VPN to read the metrics. If the mesh is down, the bot answers that the monitoring is unreachable (the workflow is built to say so instead of failing silently).
  - The watcher can fail too. An outage of node-b must also raise an alert, from a different machine.
- **Follow-up:** document how node-b itself is watched (monitoring page, planned), and list each sudo rule with the reason it is safe.

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| Everything on one larger server | Cheaper and simpler, but the automation would sit next to the remote management server: one flaw away from every managed device. |
| Automation on node-a so it can act directly | Gives the most exposed component the most powerful position. The opposite of least privilege. |
| Containers on the same host as isolation | Shared kernel and a root Docker daemon: a container escape or a Docker socket mount reaches the host. |
| An SSH key for the bot "for later actions" | An unused privilege is still a privilege an attacker can use. Actions are added one by one when needed (see [ADR 0004](0004-human-approval-for-irreversible-actions.md)). |

## How to verify

```bash
# On node-a: no automation service or container
systemctl list-units --type=service | grep -Ei 'n8n|relay' || echo "none"
sudo docker ps --format '{{.Names}}'

# On node-a and node-b: what the tooling account may run without a password
sudo -l -U <ADMIN_USER>

# On node-b: sandboxing score of the relay unit (lower is better)
systemd-analyze security <relay-service-name>.service
```

A forged message from another Telegram account must stop at the first filter with no answer at all. This test was done when the bot was put in service.

## References

- systemd, [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html) (`DynamicUser=`, `LoadCredential=`, `ProtectSystem=`).
- Docker, [Docker Engine security](https://docs.docker.com/engine/security/) (attack surface of the Docker daemon).
- sudo, [sudoers(5)](https://www.sudo.ws/docs/man/sudoers.man/).
- NIST, [Least privilege](https://csrc.nist.gov/glossary/term/least_privilege) (glossary).
