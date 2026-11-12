# Verify access from outside

A firewall rule, a bind address or an SSH setting is only a claim until it is tested. This checklist proves the network design holds, in three places: **on the node**, **from inside the mesh**, and **from outside the mesh**. The last one is the one that counts: the node always reaches itself, so a check run on the node cannot prove a port is closed to the Internet.

## 1. On the node

```bash
# Every listening socket, classified (LOOPBACK, SPECIFIC, FILTERED, ALLOWED, FINDING)
sudo bash scripts/audit-listening-ports.sh --docker                                # node-b
sudo bash scripts/audit-listening-ports.sh --docker --allow "tcp/80 tcp/443 udp/41641"   # node-a

# Firewall rules: SSH only "on tailscale0", nothing else on node-b
sudo ufw status verbose

# SSH settings really in effect
sudo sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|allowusers|maxauthtries) '
```

[`scripts/audit-listening-ports.sh`](../../scripts/audit-listening-ports.sh) reads `ss -H -tuln` (and `docker ps` with `--docker`) and sorts each socket:

| Status | Meaning | Action |
|---|---|---|
| `LOOPBACK` | Bound to `127.0.0.1` or `::1`: unreachable from another machine | None |
| `SPECIFIC` | Bound to one address | Check it is the mesh address, not the public one |
| `FILTERED` | Listening on all interfaces, closed by the host firewall (default: SSH) | Confirm from outside (step 3) |
| `ALLOWED` | Listening on all interfaces, public on purpose (`--allow`) | None |
| `FINDING` | Listening on all interfaces, on neither list | Bind it to loopback or the mesh address, or justify it |

Exit code `1` when there is at least one finding, so the script can run from a timer and raise an alert. A Docker port is never `FILTERED`, because Docker bypasses ufw ([Docker on loopback](docker-loopback.md)).

The script is tested offline in CI with saved `ss` output ([`tests/run-tests.sh`](../../tests/run-tests.sh), fixtures in [`tests/fixtures/`](../../tests/fixtures/ss-clean.txt)).

## 2. From admin-ws, inside the mesh

```powershell
# SSH works with the key, through the mesh name
ssh <ADMIN_USER>@node-b "echo ok"

# Password login is refused: expected "Permission denied (publickey)"
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <ADMIN_USER>@node-b

# The n8n editor is reachable through the tunnel only
ssh -N -L 5678:127.0.0.1:5678 <ADMIN_USER>@node-b    # then open http://127.0.0.1:5678
```

## 3. From outside the mesh

Use a machine that is **not** in the mesh, or admin-ws with the mesh client disconnected (`tailscale down`), on a network that is not the node's own.

```bash
# node-b: nothing should be open
nmap -Pn -p 22,5678 203.0.113.20

# node-a: only 80 and 443 open
nmap -Pn -p 22,80,443 198.51.100.10

# A broader look at the 1000 most common TCP ports
nmap -Pn --top-ports 1000 198.51.100.10
```

| Result | Meaning |
|---|---|
| `open` | Something answers. Expected only for 80 and 443 on node-a. |
| `filtered` | No answer at all: the firewall drops the packet. Expected for SSH. |
| `closed` | The host answers "nothing listens here". Also acceptable for a port that should not be reachable. |

`198.51.100.10` and `203.0.113.20` stand for the public addresses of node-a and node-b ([anonymization rules](../anonymization.md)). Scan only addresses you are responsible for.

## Fallback path

A rescue path that has never been tried is not a rescue path. Once per quarter, and after any change to SSH or the firewall:

1. Open the web console of the hosting provider for each node.
2. Log in locally as `<ADMIN_USER>` (the console does not use SSH, so the password works there).
3. Run `tailscale status` and `sudo ufw status` from the console, then log out.

## Checklist

| Check | node-a | node-b | Last result |
|---|---|---|---|
| Audit script: no `FINDING` | To run | To run | — |
| `ufw status`: SSH only on `tailscale0` | Applied | Applied | 2026-11-11, applied while hardening SSH |
| `sshd -T`: passwords off, one allowed user | Applied | Applied | 2026-11-11, drop-in installed on both nodes |
| Password login refused from admin-ws | To run | To run | — |
| `nmap` from outside: SSH filtered or closed | To run | To run | — |
| `nmap` from outside: n8n port closed | — | To run | — |
| Provider console login tested | To run | To run | — |

"Applied" means the change was made; the checks above confirm it independently. The *Last result* column is updated each time the checks are run. Rows marked "To run" are the open follow-ups of [ADR 0002](../adr/0002-administration-only-over-mesh-vpn.md) and [ADR 0005](../adr/0005-publish-container-ports-on-loopback.md).

## References

- Nmap Reference Guide, [Port scanning basics](https://nmap.org/book/man-port-scanning-basics.html) (open, closed, filtered).
- man7.org, [ss(8)](https://man7.org/linux/man-pages/man8/ss.8.html).
- OpenBSD manual, [sshd(8)](https://man.openbsd.org/sshd) (`-T` extended test mode).
