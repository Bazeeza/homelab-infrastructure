# 0006. Watch each node from another node

- **Status:** Accepted, applied for node-a (cross-check on node-b); the alert for node-b is a follow-up
- **Decided:** 2026-11-12 (recorded; the cross-check of node-a was already running from cron on node-b)
- **Applies to:** node-a, node-b

## Context

- Uptime Kuma, the availability monitor, runs on node-a. It probes the services well, but it shares the fate of node-a: if node-a crashes, loses its network or its provider has an outage, Uptime Kuma stops too and **sends nothing**. Silence looks exactly like "everything is fine".
- node-a is the critical node: the managed devices depend on it ([ADR 0003](0003-separate-critical-and-automation-roles.md)).
- node-b is at another provider, in another region. A failure that takes down node-a is unlikely to take down node-b at the same time.
- The administrator already receives messages from the Telegram bot on node-b, and the bot token is already stored there.

## Decision

We will check that each node is alive **from the other node**, never only from itself.

- node-b runs a cross-check every 2 minutes (generic version in this repository: [`scripts/cross-check.sh`](../../scripts/cross-check.sh)). It probes node-a over the mesh VPN and sends **one** Telegram alert after **3 consecutive failures**, then **one** recovery message when node-a answers again.
- node-a watches node-b with an Uptime Kuma probe of SSH over the mesh.

## Consequences

- **Positive:**
  - The most serious failure, node-a gone, now produces an alert instead of silence.
  - Probing over the mesh also catches a broken mesh link, which would cut administration.
  - The script is small, has no dependency beyond `bash` and `curl`, and is tested offline in CI.
- **Negative:**
  - About 6 minutes between the start of an outage and the alert (3 checks, 2 minutes apart). Accepted: a single lost probe is common and an alert every time would be ignored.
  - The alert path depends on node-b and on Telegram. If both nodes fail together, or Telegram is down, nothing arrives.
  - One more secret on node-b: the bot token, in a file readable only by the service account.
- **Follow-up:**
  - The script running on node-b predates this repository and follows the same rules (cron every 2 minutes, secret in a root-only file, alert after 3 failures). `scripts/cross-check.sh` is its generic rewrite, with tests; replace the running script with it, following the [installation steps](../monitoring/cross-check.md#install-on-node-b).
  - Configure an Uptime Kuma notification for the node-b probe, so that "node-b is down" also raises an alert, not only a red line in the dashboard.
  - Optional third watcher outside both providers (a free external uptime service probing the public site), to cover "both nodes down".

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| Rely on Uptime Kuma on node-a only | Cannot report the death of its own host. That is the gap this decision closes. |
| Move Uptime Kuma to node-b | Then nothing watches node-b, and the read-only automation node would own the monitoring of the critical node. The same gap, moved. |
| A second full Uptime Kuma on node-b | Two dashboards and two sets of probes to keep in sync for one question: "is node-a alive?". Heavier than one small script. |
| A paid external monitoring service | Covers more, costs money, and would need the probes to reach the services from the Internet. Kept as an option for the public site only. |
| Alert on the first failure | Too many false alarms from network hiccups; the channel would end up muted. |

## How to verify

```bash
# On node-b: the last runs, one line per probe
journalctl -t cross-check --since "15 min ago" --no-pager

# Full test of the alert path, in a maintenance window: see docs/monitoring/cross-check.md
```

## References

- Google SRE book, [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) and [Being On-Call](https://sre.google/sre-book/being-on-call/) (alert fatigue).
- Telegram Bot API, [sendMessage](https://core.telegram.org/bots/api#sendmessage).
