# Availability probes - Uptime Kuma

Uptime Kuma runs on node-a and answers one question per probe: **does this service answer right now?** This page describes how it is deployed, what it probes and how other components read its results without being able to change them.

| | |
|---|---|
| Node | node-a (critical) |
| Runs as | Docker container, data in a named volume |
| Web interface | port 3001, reached over the mesh VPN |
| Read by | the status bot on node-b, through `/metrics` and an API key |
| Probes | 8 since 2026-11-10 (a database probe was removed with the database) |

## What is probed

The probes cover the services that other devices depend on, seen from the network. The exact list lives in the Uptime Kuma interface; the table shows the kinds of probe in use:

| Kind of probe | Example target (placeholder) | What a failure means |
|---|---|---|
| HTTPS with certificate check | `https://remote.example.com` | Remote management front-end down, or certificate invalid |
| HTTPS through the outbound tunnel | `https://example.com` | Public site or tunnel down; the local web server may still be fine |
| TCP port over the mesh | `node-b`, port 22 | node-b, its SSH service or the mesh link is down |
| Ping over the mesh | `admin-ws` | The laptop sleeps, which is normal on battery |

Two choices behind this list:

- **Probe the public path, not only the process.** The public site is probed through its public name, so the probe covers DNS, the tunnel and the web server in one check. A process check on the node would say "running" while visitors get an error.
- **Probe node-b over the mesh.** SSH is closed on the public address of both nodes since 2026-11-11 ([ADR 0002](../adr/0002-administration-only-over-mesh-vpn.md)), so a probe of the public address would fail forever. The target must be the mesh name, resolved by MagicDNS (changed in the interface; to confirm, see [open points](README.md#open-points)).

## Deployment

Example deployment with the official image. The data lives in a named volume, so the probes, the history and the settings survive an image update:

```bash
# Published on the mesh address only, not on all interfaces (ADR 0005).
# 192.0.2.10 is the placeholder of the mesh address of node-a.
# Pin the major version in use; read the release notes before changing it.
docker run -d --name uptime-kuma --restart unless-stopped \
  -p 192.0.2.10:3001:3001 \
  -v uptime-kuma:/app/data \
  louislam/uptime-kuma:1
```

> [!WARNING]
> Publishing on a mesh address has a start-up trap: if Docker starts the container before the mesh interface has its address, the bind fails and the container does not start. Two ways out: start Docker after the mesh client (a systemd `After=` drop-in on `docker.service`), or publish on all interfaces and filter the port in the `DOCKER-USER` chain. The current bind address is on the [verification checklist](../network/access-verification.md) and is the open follow-up of [ADR 0005](../adr/0005-publish-container-ports-on-loopback.md).

## The metrics endpoint

Uptime Kuma exposes the state of every probe at `/metrics`, in the Prometheus text format. The endpoint is protected: it accepts HTTP basic authentication with an **empty user name and an API key as password**. API keys are created in *Settings > API Keys* and can be given an expiry date and revoked one by one.

The line that matters, one per probe:

```text
monitor_status{monitor_name="Public site",monitor_type="http",monitor_url="https://example.com",monitor_hostname="null",monitor_port="null"} 1
```

| Value | Meaning |
|---|---|
| `0` | Down |
| `1` | Up |
| `2` | Pending (failed, waiting for the retry before declaring it down) |
| `3` | Maintenance (a maintenance window is active) |

Other series in the same output: `monitor_response_time` (milliseconds), `monitor_cert_days_remaining` and `monitor_cert_is_valid` for HTTPS probes.

### Why an API key and not the admin account

| Choice | Reason |
|---|---|
| One key per consumer | The status bot uses a key of its own. Revoking it does not lock the administrator out, and does not break another consumer. |
| Key in a file, mode `600`, outside the workflow export | A workflow can be exported or shared; the key is stored as an n8n credential and as a root-only file, never in the workflow itself. |
| Read-only by nature | `/metrics` only returns data. The key cannot change a probe, a notification or a setting. A leaked key shows the state of the probes, nothing more. |

## Reading the probes from a terminal

[`scripts/kuma-status.sh`](../../scripts/kuma-status.sh) prints the same summary as the status bot: one line per probe, problems first.

```bash
# Live, from a node of the mesh. The key file holds only the API key.
KUMA_URL=http://node-a:3001 KUMA_KEY_FILE=/etc/kuma-status/api.key \
  bash scripts/kuma-status.sh --ignore admin-ws

# Offline, from saved output
bash scripts/kuma-status.sh --file tests/fixtures/kuma-metrics.txt
```

Output with the test file (synthetic data, placeholder names):

```text
PENDING  Public site
DOWN     admin-ws
UP       Beszel hub
UP       Mesh VPN exit node
UP       Outbound tunnel
UP       Remote management "agents" port
UP       Remote management (web)
UP       node-b SSH

Summary: 8 probe(s), 2 not up.
```

| Exit code | Meaning |
|---|---|
| 0 | Every probe is up (probes given with `--ignore` do not count) |
| 1 | At least one probe is down, pending, in maintenance or unknown |
| 2 | Usage error, unreadable input, or no probe found in the input |

Exit code 2 on an empty input is on purpose: under cron, stdin is often empty, and "no probe read" must not look like "everything is up".

The key never appears on the command line: the script reads it from the file and hands it to `curl` through a configuration read on stdin (`curl -K -`). Anything passed as an argument is visible to every user of the node in `ps`.

## Checks after a change

```bash
# The container runs and restarts by itself
docker ps --filter name=uptime-kuma --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

# The metrics need the key: without it, 401 is the expected answer
curl -s -o /dev/null -w '%{http_code}\n' http://node-a:3001/metrics
```

From outside the mesh, port 3001 must be closed or filtered: `nmap -Pn -p 3001 198.51.100.10`.

## References

- Uptime Kuma wiki, [Prometheus Integration](https://github.com/louislam/uptime-kuma/wiki/Prometheus-Integration) and [API Keys](https://github.com/louislam/uptime-kuma/wiki/API-Keys).
- Uptime Kuma, [installation with Docker](https://github.com/louislam/uptime-kuma#-how-to-install).
- Prometheus, [Exposition formats](https://prometheus.io/docs/instrumenting/exposition_formats/) (label value escaping).
- curl manual, [`-K, --config`](https://curl.se/docs/manpage.html#-K).
