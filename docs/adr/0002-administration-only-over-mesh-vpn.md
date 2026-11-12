# 0002. Administration only over a mesh VPN, no public administrative port

- **Status:** Accepted, applied for SSH on 2026-11-11; verification from outside still open (see *Follow-up*)
- **Decided:** 2026-10 (mesh VPN in place before SSH key access was set up on 2026-10-13)
- **Applies to:** node-a, node-b, admin-ws

## Context

- Both servers are rented VPS with a public IPv4 address. Anything that listens on that address is scanned within minutes. The fail2ban history of node-b shows **hundreds of thousands** of failed SSH login attempts since the server was installed (none succeeded). That is the normal background noise of the Internet, and every one of those attempts is a chance for a weak password or an unpatched daemon.
- Several services are for the administrator only: SSH, the monitoring dashboards, the n8n workflow editor. None of them needs to be reachable by anyone else.
- The first remote access solution was a **self-hosted WireGuard server** in a container on node-a. It worked, but it was a hub: one public UDP port, every connection through node-a, and no access at all if node-a was down, which is exactly when access is needed.
- The administrator laptop moves between networks, so allow-listing "the home IP address" in a firewall does not work.

## Decision

We will reach every administrative interface **only through a mesh VPN** (Tailscale, built on WireGuard) or through an **SSH local forward** inside it:

| Interface | How it is reached |
|---|---|
| SSH to node-a and node-b | Mesh VPN name of the node, key authentication |
| n8n editor (node-b) | `ssh -L 5678:127.0.0.1:5678 <ADMIN_USER>@node-b`, then `http://127.0.0.1:5678` on admin-ws; n8n itself listens on loopback only |
| Monitoring metrics read by n8n | Mesh VPN address of node-a, protected by an API key |
| Databases | Loopback only, never from another machine (the remote management server now uses its embedded database) |

Services meant for the public are not published by opening a port either: they go through an **outbound tunnel** (see the [architecture overview](../architecture.md#how-traffic-flows)).

node-b is also the mesh **exit node**: when admin-ws is on an untrusted network, its traffic can leave through node-b.

## Consequences

- **Positive:**
  - Each device has a direct, encrypted WireGuard tunnel to each other device. No hub: node-b stays reachable when node-a is down, and the other way around.
  - The mesh client works behind NAT without any inbound port on the servers, so the administrative ports can be closed on the public interface.
  - Node names resolve only inside the mesh: a leaked name is useless from outside.
- **Negative:**
  - The mesh VPN account and the identity provider used to sign in to it become keys to the infrastructure. They must be protected with two-factor authentication.
  - Dependence on the mesh coordination service for adding devices and distributing keys. Existing tunnels keep working during a short outage of the coordination service, but a new device cannot join.
  - If the mesh client stops on a server, the administrator needs another way in: the provider's web console. That path must be tested, not assumed.
- **Follow-up:**
  - **Done 2026-11-11:** SSH restricted to the mesh interface in the host firewall on both nodes; the public SSH rules removed ([host firewall](../network/host-firewall.md)).
  - **Done 2026-11-11:** SSH password authentication turned off on both nodes, with a new passphrase-protected key on admin-ws and the provider web console as the second access path ([SSH access](../network/ssh-access.md)).
  - **Done:** the legacy WireGuard server was removed from node-a.
  - **Open:** confirm from **outside** the mesh that SSH and every other administrative port are filtered or closed, and test the provider console login ([verification checklist](../network/access-verification.md)).
  - **Open:** add a third access path, a second administrator workstation with **its own** key (never a copy of the admin-ws key).
  - **Proposed:** a mesh access policy based on tags, so that a less trusted device added later reaches no server port by default ([mesh VPN](../network/mesh-vpn.md#who-may-reach-what-access-policy)).

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| Public SSH protected by fail2ban only | fail2ban slows attackers down; it does not remove the exposed service. A zero-day in the SSH daemon would still be reachable. |
| Moving SSH to a non-standard port | Cuts log noise, adds no real security: scanners find the port anyway. |
| Self-hosted WireGuard hub (previous solution) | Single point of failure on the critical node, one more public port, manual key distribution. |
| Provider firewall allowing only the administrator's address | The laptop changes networks; the rule would be wrong half of the time. |
| Bastion host | One more server to maintain and secure, for two servers. A mesh gives the same "single door" with less to run. |

## How to verify

```bash
# On a node: which processes listen, and on which address?
# Administrative services must show 127.0.0.1 or the mesh address, never 0.0.0.0.
sudo ss -tlnp

# On a node: firewall rules (SSH should be allowed on the mesh interface only)
sudo ufw status verbose

# On a node: mesh peers and the exit node
tailscale status
```

```bash
# From a machine OUTSIDE the mesh (mesh client disconnected):
# every administrative port must be reported as filtered or closed.
nmap -Pn -p 22,5678 198.51.100.10
```

`198.51.100.10` stands for the public address of the node being tested (documentation range, see [anonymization rules](../anonymization.md)).

## References

- Tailscale, [What is Tailscale?](https://tailscale.com/kb/1151/what-is-tailscale) and [Exit nodes](https://tailscale.com/kb/1103/exit-nodes).
- [WireGuard](https://www.wireguard.com/) protocol overview.
- OpenBSD manual, [sshd_config(5)](https://man.openbsd.org/sshd_config) (`PasswordAuthentication`, `ListenAddress`).
- How it is applied: [Network design and access](../network/README.md).
- Ubuntu community help, [UFW](https://help.ubuntu.com/community/UFW).
