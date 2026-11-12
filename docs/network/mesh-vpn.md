# Mesh VPN

All administration travels inside a mesh VPN: Tailscale, which builds direct [WireGuard](https://www.wireguard.com/) tunnels between every pair of devices. Why a mesh and not a public SSH port or a self-hosted VPN hub is explained in [ADR 0002](../adr/0002-administration-only-over-mesh-vpn.md).

## How it works, in four lines

1. Each device generates its own WireGuard key pair. The private key never leaves the device.
2. The coordination service only distributes **public** keys and the list of peers. It never sees the traffic.
3. Devices then connect **directly** to each other, through NAT, using UDP. If no direct path is possible, traffic goes through an encrypted relay (DERP), still end-to-end encrypted.
4. Each device gets a stable address in the `100.64/10` range and a name (MagicDNS) that resolves only inside the mesh.

Consequence for the servers: the mesh needs **no inbound port**. The client opens the connection outward, like a browser. That is what makes it possible to close SSH on the public address.

## Enroll a server

Run on the new server (Ubuntu), following the official install page:

```bash
# Install the client from the official package repository
curl -fsSL https://tailscale.com/install.sh | sh

# Join the mesh: prints a login URL to open on admin-ws
sudo tailscale up

# Check: the node, its mesh address and its peers
tailscale status
tailscale ip -4
```

Then, in the admin console of the mesh account:

| Setting | Recommended value for a server | Why |
|---|---|---|
| Machine name | `node-a`, `node-b` | The name is what SSH and scripts use. |
| Key expiry | **Disabled** for servers | By default a device must re-authenticate periodically. A server that silently drops out of the mesh is an outage of the only administrative path. Workstations keep the expiry. |

> [!WARNING]
> Install the mesh client and confirm `ssh <ADMIN_USER>@node-a` works **through the mesh** before touching the firewall or SSH configuration. The order is: new path works, then the old path is closed. Never the other way around.

## Exit node (node-b)

An exit node routes the **whole Internet traffic** of a device through a server. admin-ws uses it on networks that are not trusted (public Wi-Fi): the local network then only sees encrypted WireGuard packets.

```bash
# On node-b: allow the kernel to forward packets (required for an exit node on Linux)
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf

# Offer node-b as an exit node, then approve it in the admin console
sudo tailscale set --advertise-exit-node
```

```powershell
# On admin-ws: use node-b as exit node, and stop using it
tailscale set --exit-node=node-b
tailscale set --exit-node=
```

The exit node is on node-b and not on node-a on purpose: forwarding traffic for other devices is one more job, and node-a keeps only the critical ones ([ADR 0003](../adr/0003-separate-critical-and-automation-roles.md)).

## Who may reach what (access policy)

The mesh has an access policy (a JSON file edited in the admin console). With the default policy, every device of the account can reach every port of every other device. For three devices owned by one administrator, that is acceptable; it stops being acceptable as soon as a less trusted device joins (a second workstation, a test VM, a family laptop).

The tighter policy to adopt at that point, written with tags so it does not depend on addresses:

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:server:22"] },
    { "action": "accept", "src": ["tag:server"], "dst": ["tag:server:*"] }
  ]
}
```

| Rule | Meaning |
|---|---|
| `autogroup:admin` to `tag:server:22` | Devices of the account administrators may open SSH on the servers, nothing else. |
| `tag:server` to `tag:server:*` | Servers may talk to each other (node-b reads the metrics of node-a, cross-checks it). |
| Anything not listed | Denied. A new laptop added to the account reaches no server port until a rule says so. |

This policy is **proposed, not yet applied** (status kept in [ADR 0002](../adr/0002-administration-only-over-mesh-vpn.md)). Before applying it, use the *Preview rules* view of the admin console to check which device can reach which port.

## What the mesh does not do

- It does not replace the host firewall. If the mesh account is compromised, the attacker is "inside". The firewall and SSH keys are the next layers ([SSH access](ssh-access.md), [host firewall](host-firewall.md)).
- It does not protect the account that controls it. The identity provider used to sign in to the mesh must have two-factor authentication; it is effectively a key to every server.

## Fallback when the mesh is down

If the mesh client stops on a server, SSH through the mesh is gone. The fallback is the **web console of the hosting provider** (a virtual screen and keyboard), which does not depend on the network configuration of the server. It is tested, not assumed: see the [verification checklist](access-verification.md#fallback-path).

## References

- Tailscale, [Install Tailscale on Linux](https://tailscale.com/kb/1031/install-linux), [Key expiry](https://tailscale.com/kb/1028/key-expiry), [Exit nodes](https://tailscale.com/kb/1103/exit-nodes), [Tags](https://tailscale.com/kb/1068/tags), [Syntax reference for the tailnet policy file](https://tailscale.com/kb/1337/policy-syntax), [DERP servers](https://tailscale.com/kb/1232/derp-servers).
- WireGuard, [Protocol and cryptography](https://www.wireguard.com/protocol/).
