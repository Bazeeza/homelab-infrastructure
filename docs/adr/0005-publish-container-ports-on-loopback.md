# 0005. Publish container ports on loopback only

- **Status:** Accepted, applied to n8n on node-b; to confirm for the other containers (see *Follow-up*)
- **Decided:** 2026-11-11 (recorded; the rule was already applied when n8n was installed)
- **Applies to:** node-a, node-b

## Context

- Both nodes run some services in Docker containers (n8n on node-b, monitoring on node-a).
- The host firewall (ufw) denies every inbound connection that is not explicitly allowed ([host firewall](../network/host-firewall.md)).
- Docker publishes a container port by writing its own packet filter rules (NAT and the `DOCKER` chains). Packets for a published port are redirected to the container **before** the ufw input rules are evaluated. A container started with `-p 5678:5678` is therefore reachable from the Internet while `ufw status` still says "deny". The firewall looks right and is not.
- The n8n editor gives full control over the workflows and the credentials they use. Exposing it, even behind its own login, would put a high-value target on the public address.

## Decision

We will publish every container port on **`127.0.0.1`** (`-p 127.0.0.1:HOST:CONTAINER`, or `"127.0.0.1:HOST:CONTAINER"` in Compose), never on all interfaces. A container that must be reached from another node is reached through the mesh VPN or through an SSH local forward; a container that must be public goes through an outbound tunnel or a reverse proxy that is itself the only public port.

Example: [`configs/docker/n8n.compose.example.yml`](../../configs/docker/n8n.compose.example.yml).

## Consequences

- **Positive:**
  - The rule does not depend on the firewall being right: a service bound to loopback cannot be reached from outside, whatever the packet filter says.
  - Easy to audit: `docker ps` shows `127.0.0.1:5678->5678/tcp` or `0.0.0.0:5678->5678/tcp`; the second one is a finding.
- **Negative:**
  - Reaching a loopback service from admin-ws needs an SSH tunnel (`ssh -L`). One more step for the administrator.
  - A container that another node must read (monitoring metrics read by node-b) cannot be on loopback only. It has to be bound to the mesh address, or published normally and filtered in the `DOCKER-USER` chain. That case is the open follow-up.
- **Follow-up:**
  - Confirm the bind address of the monitoring containers on node-a with [`scripts/audit-listening-ports.sh`](../../scripts/audit-listening-ports.sh) and from outside with `nmap` ([verification checklist](../network/access-verification.md)).
  - Optionally set `"ip": "127.0.0.1"` in `/etc/docker/daemon.json`, so that a port published without an address defaults to loopback. It protects against a forgotten `127.0.0.1:` in a future `docker run`.

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| Rely on ufw | Docker rules are evaluated first; ufw does not filter published ports. |
| Disable Docker's packet filter management (`"iptables": false`) | Breaks outbound networking of the containers unless every NAT rule is rewritten by hand. Easy to get wrong, hard to maintain. |
| Filter published ports in the `DOCKER-USER` chain | Works and is the method recommended by Docker for filtering, but it is a second rule set to maintain next to ufw. Kept for the case where loopback is not possible. |
| Host networking (`--network host`) | The container sees every interface of the node and binds wherever its own configuration says. The isolation is lost. |

## How to verify

```bash
# Published ports of every container: no 0.0.0.0 or [::] expected
docker ps --format '{{.Names}}\t{{.Ports}}'

# Listening sockets: the audit script flags anything open on all interfaces
sudo ss -H -tuln | bash scripts/audit-listening-ports.sh
```

From a machine outside the mesh, the published port must be closed or filtered: `nmap -Pn -p 5678 203.0.113.20`.

## References

- Docker Docs, [Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/) and [Port publishing and mapping](https://docs.docker.com/engine/network/port-publishing/).
- Docker Docs, [dockerd reference: daemon configuration file](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file) (`ip`).
- Compose Specification, [ports](https://docs.docker.com/reference/compose-file/services/#ports).
