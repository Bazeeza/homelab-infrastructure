# Host firewall

Each node runs **ufw** (Uncomplicated Firewall, the front-end of the Linux packet filter on Ubuntu). The rule set is short on purpose: a rule nobody can explain is a rule nobody dares to remove.

## Baseline

| Order | Rule | node-a | node-b | Why |
|---|---|---|---|---|
| 1 | Default: deny incoming, allow outgoing | Yes | Yes | Anything not explicitly opened is closed. Outbound stays open: updates, mesh VPN, tunnels and the Telegram relay all start from the inside. |
| 2 | Allow TCP 22 **in on `tailscale0` only** | Yes | Yes | SSH reachable through the mesh VPN, not through the public address ([ADR 0002](../adr/0002-administration-only-over-mesh-vpn.md)). |
| 3 | Remove the public SSH rules (`OpenSSH`, `22/tcp`) | Yes | Yes | Cloud images usually open SSH to the world at install time. Applied on both nodes on 2026-11-11. |
| 4 | Allow TCP 80 and 443 | Yes | No | node-a publishes the remote management front-end and its agents' connections over HTTPS; port 80 redirects to HTTPS and answers certificate validation. node-b publishes nothing. |

> [!NOTE]
> Rule 2 is added **before** rule 3 removes the public one. During the change, SSH is reachable both ways for a few seconds instead of zero ways. Order matters more than speed.

The baseline is written as a script that **prints** the plan by default and runs it only with `--apply`: [`scripts/ufw-baseline.sh`](../../scripts/ufw-baseline.sh).

```bash
# See what would change, as any user
bash scripts/ufw-baseline.sh --role node-b

# Apply, as root, from an SSH session that comes through the mesh VPN
sudo bash scripts/ufw-baseline.sh --role node-b --apply
```

In `--apply` mode the script refuses to run when:

- the mesh interface is missing or has no address (the only SSH rule left would point at nothing);
- the current SSH session does **not** come through the mesh: it compares the server address in `SSH_CONNECTION` with the addresses of `tailscale0`. Applying from a public session would cut the session that is running the script. `--force` skips this check, for use from the provider web console only.

## Safety net for a remote change

A firewall change made over SSH can cut the session that made it. Before a change that is not covered by the script, schedule an automatic rollback, then cancel it once the new rules are confirmed:

```bash
# Disable ufw automatically in 10 minutes, unless cancelled
sudo systemd-run --unit=ufw-rollback --on-active=10min /usr/sbin/ufw disable

# ... make the change, test from a NEW SSH session ...

# Everything works: cancel the rollback
sudo systemctl stop ufw-rollback.timer
```

If the new rules lock the administrator out, ufw switches itself off after 10 minutes and SSH through the mesh comes back. The provider web console stays the last resort.

## Expected result

On node-b (placeholders, `ufw status verbose`):

```text
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)

To                         Action      From
--                         ------      ----
22/tcp on tailscale0       ALLOW IN    Anywhere          # SSH over mesh VPN only
22/tcp (v6) on tailscale0  ALLOW IN    Anywhere (v6)     # SSH over mesh VPN only
```

`deny (routed)` is the ufw default for forwarded traffic, and node-b forwards traffic for the exit node. The mesh client adds its own forwarding rules for `tailscale0`, but after any firewall change the exit node is tested from admin-ws (`tailscale set --exit-node=node-b`, then open any website). If it stops working, the routed policy is the first thing to check (`ufw route allow in on tailscale0`).

## What ufw does not see

- **Docker published ports.** Docker writes its own packet filter rules, evaluated before the ufw rules. A container published on all interfaces is reachable from the Internet even with ufw set to deny. That is the reason for [Docker on loopback](docker-loopback.md).
- **Outbound tunnels.** A service published through an outbound tunnel needs no inbound rule at all; it is controlled in the tunnel configuration, not in ufw.
- **The provider firewall.** Some providers offer a network firewall in front of the server. It is a useful second layer, but it is not used here as the main one: rules kept in two places drift apart.

## fail2ban

node-b also runs **fail2ban**, which reads the authentication logs and bans addresses after repeated failures. Its history shows hundreds of thousands of failed SSH attempts while SSH was public, and no successful one. Now that SSH is no longer public, fail2ban should see almost nothing: the firewall removes the noise at the source. It stays installed as a second layer in case a port is opened by mistake.

## References

- Ubuntu Server documentation, [Firewall (ufw)](https://documentation.ubuntu.com/server/how-to/security/firewalls/); manual page [ufw(8)](https://manpages.ubuntu.com/manpages/noble/en/man8/ufw.8.html).
- Docker Docs, [Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
- systemd, [systemd-run(1)](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html) (`--on-active`).
- Tailscale, [Exit nodes](https://tailscale.com/kb/1103/exit-nodes).
