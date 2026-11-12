# SSH access

SSH is the only shell access to node-a and node-b. Since 2026-11-11 on both nodes it accepts **keys only**, for **one** account, and only **through the mesh VPN** (the public port is closed by the [host firewall](host-firewall.md)).

| Layer | Setting | What it stops |
|---|---|---|
| Network | SSH allowed only on `tailscale0` | Internet-wide scanning and password guessing never reach `sshd` |
| Authentication | Keys only, passwords off | A guessed or reused password is useless |
| Authorization | `AllowUsers <ADMIN_USER>`, root login off | Default or service accounts cannot be used to log in |
| Key on admin-ws | Ed25519, protected by a passphrase, loaded in the SSH agent | A copied key file alone is not enough |
| Fallback | Provider web console | Losing the key or the mesh is not a permanent lockout |

## 1. Create the key on admin-ws

One key **per workstation**, never copied from one machine to another: if a laptop is lost, only its key is revoked.

```powershell
# Windows OpenSSH client. Choose a passphrase when asked.
ssh-keygen -t ed25519 -C "admin-ws-2026-11" -f "$env:USERPROFILE\.ssh\id_ed25519_admin-ws"
```

| Choice | Why |
|---|---|
| `-t ed25519` | Short keys, fast, no weak parameter to choose. Supported by every current OpenSSH. |
| `-C "admin-ws-2026-11"` | The comment shows up in `authorized_keys`: it tells *which* machine and *when*, so the right line is removed during a rotation. |
| A passphrase | The private key file is encrypted. A stolen copy of the disk does not give access to the servers. |

Load it once in the Windows SSH agent, so the passphrase is not typed at each connection:

```powershell
# As administrator, once: start the agent with Windows
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent

# As the user: add the key (asks for the passphrase once)
ssh-add "$env:USERPROFILE\.ssh\id_ed25519_admin-ws"
ssh-add -l
```

The client configuration that goes with it (names, key, n8n tunnel) is in [`configs/ssh/admin-ws.ssh_config.example`](../../configs/ssh/admin-ws.ssh_config.example).

## 2. Install the public key on the node

Windows has no `ssh-copy-id`. The public key (the `.pub` file, safe to share) is appended to the account's `authorized_keys`:

```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519_admin-ws.pub" |
  ssh <ADMIN_USER>@node-a "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
```

`umask 077` makes the folder `700` and the file `600`. With looser permissions, `sshd` ignores the file (`StrictModes`), and key login fails with no clear error on the client side.

Test the key **before** going further:

```powershell
ssh -o PreferredAuthentications=publickey <ADMIN_USER>@node-a "echo key login works"
```

## 3. Harden `sshd` without locking yourself out

The full drop-in file is [`configs/ssh/00-hardening.conf`](../../configs/ssh/00-hardening.conf). It is rewritten from the file deployed on both nodes, with the account name replaced.

> [!WARNING]
> Turn off passwords only when at least **two** independent ways in are confirmed: the key on admin-ws, and the provider web console. A second workstation with its own key is the third path ([ADR 0002](../adr/0002-administration-only-over-mesh-vpn.md), follow-up).

```bash
# Session 1: stays open during the whole procedure. It is the way back.
sudo install -m 644 00-hardening.conf /etc/ssh/sshd_config.d/00-hardening.conf

# Syntax check: prints nothing when the configuration is valid
sudo sshd -t

# Effective values, after every Include and default is applied
sudo sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers|maxauthtries|allowtcpforwarding) '

# Apply: existing sessions are not cut
sudo systemctl reload ssh
```

Then, from a **new** terminal on admin-ws (session 1 still open):

```powershell
# Must work
ssh <ADMIN_USER>@node-a "echo ok"

# Must be refused with: Permission denied (publickey)
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <ADMIN_USER>@node-a
```

Only when both results are as expected is session 1 closed. If anything fails, session 1 removes the file and reloads: `sudo rm /etc/ssh/sshd_config.d/00-hardening.conf && sudo systemctl reload ssh`.

### Why the file is named `00-...`

Ubuntu's `/etc/ssh/sshd_config` starts with `Include /etc/ssh/sshd_config.d/*.conf`, and `sshd` keeps the **first** value it reads for each keyword. Cloud images often ship `50-cloud-init.conf` with `PasswordAuthentication yes`. A hardening file named `99-...` would be read last and silently ignored for that keyword. `sshd -T` shows the value really in effect; the file content alone does not prove anything.

### Line by line

| Setting | Effect |
|---|---|
| `PermitRootLogin no` | Root cannot log in directly. Administration goes through `<ADMIN_USER>` and `sudo`, which leaves a trace of who ran what. |
| `AllowUsers <ADMIN_USER>` | Every other account is refused, including accounts created later by a package. |
| `AuthenticationMethods publickey`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no` | Keys only. The keyboard-interactive line matters: it is another way to ask for a password. |
| `MaxAuthTries 3`, `LoginGraceTime 30` | Few attempts per connection, short time to authenticate. Limits what a single connection can try. |
| `X11Forwarding no`, `AllowAgentForwarding no`, `PermitTunnel no` | Features not needed on a server. Agent forwarding in particular would let a compromised server use the administrator's keys while the session is open. |
| `AllowTcpForwarding local` | Keeps `ssh -L` (the n8n editor tunnel) and refuses remote forwards, which could open a port on the server toward the outside. |
| `KexAlgorithms`, `Ciphers`, `MACs` | Only modern algorithms. Check support first with `ssh -Q kex`, `ssh -Q cipher` and `ssh -Q mac`. |
| `ClientAliveInterval 300`, `ClientAliveCountMax 2` | Closes a session whose client disappeared after about 10 minutes. |

## 4. Rotate or revoke a key

Done on 2026-11-11: a new key with a passphrase replaced the first one, and the old one was removed from both nodes.

1. Create the new key (step 1) and add it to `authorized_keys` (step 2). Both keys work for a moment.
2. Test the new key alone: `ssh -i <new key> -o IdentitiesOnly=yes <ADMIN_USER>@node-a`.
3. On each node, remove the line of the old key (the comment identifies it):

   ```bash
   cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
   grep -v 'admin-ws-old-comment' ~/.ssh/authorized_keys.bak > ~/.ssh/authorized_keys
   ```

4. Check that the old key is refused, then delete it on admin-ws and remove it from the agent (`ssh-add -d`).

A lost or stolen workstation is handled the same way, starting at step 3, from another access path.

## Fallback path

If the key or the mesh is lost, the provider web console gives a local login (virtual screen and keyboard). It does not go through `sshd`, so the password of `<ADMIN_USER>` still works there even with `PasswordAuthentication no`. That password must be long and unique, and kept offline or in a password manager: since SSH refuses passwords, it is never sent over the network.

## References

- OpenBSD manual, [sshd_config(5)](https://man.openbsd.org/sshd_config), [ssh_config(5)](https://man.openbsd.org/ssh_config), [ssh-keygen(1)](https://man.openbsd.org/ssh-keygen).
- Microsoft Learn, [Key-based authentication in OpenSSH for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement).
- Ubuntu Server documentation, [OpenSSH server](https://documentation.ubuntu.com/server/how-to/security/openssh-server/).
- Mozilla, [OpenSSH security guidelines](https://infosec.mozilla.org/guidelines/openssh).
