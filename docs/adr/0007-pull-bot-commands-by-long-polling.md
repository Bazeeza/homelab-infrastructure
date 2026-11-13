# 0007. Pull bot commands by long polling, never expose the workflow engine

- **Status:** Accepted, applied (relay running on node-b; its generic rewrite with tests is in this repository)
- **Decided:** 2026-11-13 (recorded; the relay was already running on node-b)
- **Applies to:** node-b

## Context

- The status bot is built in n8n. Its Telegram trigger works **only by webhook**: Telegram must be able to open an HTTPS connection to n8n from the Internet.
- n8n listens on `127.0.0.1` only ([ADR 0005](0005-publish-container-ports-on-loopback.md)), and node-b publishes no public service at all ([ADR 0002](0002-administration-only-over-mesh-vpn.md)).
- n8n is a large application with many integrations and frequent updates; it is the part of node-b most likely to have a vulnerability ([ADR 0003](0003-separate-critical-and-automation-roles.md)).
- Anyone who finds the bot's name can send it messages. Only one person should be able to use it.
- The Bot API offers a second way to receive messages: `getUpdates` with a timeout (long polling), where the server opens the connection.

## Decision

We will receive bot messages with a small relay that **pulls** them from the Bot API over an outbound connection, filters them, and forwards only known commands to the n8n webhook on loopback. No inbound port is opened for the bot, and n8n stays unreachable from the Internet.

- The relay drops, without answering, every message that is not from the single allowed user in a private chat, and forwards only a command name, never the message text.
- n8n checks the sender and the command again.
- The relay runs as a hardened systemd service with a dynamic user, and receives the token through `LoadCredential=` ([unit explained](../relay/systemd-unit.md)).

## Consequences

- **Positive:**
  - No public port, no certificate and no reverse proxy to maintain for the bot.
  - The large application (n8n) is never reached by Internet traffic; only a single Python file of a few hundred lines, with no dependency outside the standard library, is.
  - The filters run before n8n: a stranger's message never reaches the workflow engine, and its text is never logged.
  - Free text never reaches n8n, which matters the day a language model is connected behind it (prompt injection).
- **Negative:**
  - One more component to keep running. If the relay stops, the bot is silent; the cross-check does not watch it yet.
  - One more hop for each command. The delay stays small: the open `getUpdates` request returns as soon as a message arrives, so a command does not wait for the 50-second timeout.
  - The n8n Telegram trigger node cannot be used. A webhook trigger with a fixed path replaces it, and the workflow must check the sender itself.
  - The local webhook accepts a request from any process on node-b.
- **Follow-up:**
  - Replace the running relay with the tested version ([install steps](../relay/README.md#install-on-node-b)).
  - Add a shared secret header between the relay and the n8n webhook, so that only the relay can trigger the workflow.
  - Watch the relay: an Uptime Kuma push monitor or a check of `systemctl is-active` in the cross-check.

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| n8n Telegram trigger with n8n published on the Internet | Puts the largest, most often updated application of node-b in front of the Internet, against ADR 0002 and ADR 0005. |
| Publish only the webhook path through a reverse proxy or an outbound tunnel | Still lets Internet traffic reach n8n, adds a certificate or a tunnel to maintain, and the filtering would happen inside n8n, after the request is parsed. |
| A full bot framework (python-telegram-bot or similar) | Correct, but a dependency tree to update for a program that needs three API methods. The standard library is enough. |
| Poll from inside n8n with a scheduled workflow | One call every N seconds instead of an open long-poll request: slower answers and many more executions stored by n8n. |

## How to verify

```bash
# On node-b: the relay runs and listens on nothing
systemctl is-active telegram-relay.service
ss -tlnp | grep -i python || echo "no listening socket"

# From outside (admin-ws off the mesh, or any Internet host): the n8n port is closed
nmap -Pn -p 5678 <node-b public address>

# Webhook mode is off for the bot: "url" must be empty
curl -s -K - <<< "url = https://api.telegram.org/bot$(sudo cat /etc/telegram-relay/telegram.token)/getWebhookInfo"
```

Then a `/status` from another Telegram account must get **no answer**, and the journal must show `rejected: sender=...` ([test plan](../relay/README.md#verify)).

## References

- Telegram Bot API: [Getting updates](https://core.telegram.org/bots/api#getting-updates), [getUpdates](https://core.telegram.org/bots/api#getupdates), [getWebhookInfo](https://core.telegram.org/bots/api#getwebhookinfo).
- n8n documentation: [Telegram Trigger node](https://docs.n8n.io/integrations/builtin/trigger-nodes/n8n-nodes-base.telegramtrigger/), [Webhook node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/).
- systemd: [systemd.exec, credentials](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).
