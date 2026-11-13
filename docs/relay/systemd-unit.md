# The relay unit, line by line

The relay holds the bot token and reads messages that anyone on Telegram can send. If a bug in it, in Python or in a library were ever exploited, the unit decides what the attacker gets. The answer this unit aims for: **a throw-away user, a read-only system, no privileges, no devices, 64 MB of memory, and the token**. Nothing else on node-b.

File: [`configs/systemd/telegram-relay.service`](../../configs/systemd/telegram-relay.service). Back to the [relay guide](README.md).

## [Unit]

| Line | What it does | Why here |
|---|---|---|
| `Description=...` | Name shown by `systemctl status` and in the journal | Says what the service is without naming the bot or the node |
| `After=network-online.target docker.service` | Start order only: after the network is configured and after Docker | The first `getUpdates` needs the network; n8n runs in Docker. `After=` does not *require* Docker: if n8n is not up yet, the relay answers "unreachable" and the next command works |
| `Wants=network-online.target` | Asks systemd to actually reach the "network online" state | `After=` alone would only order against a target that might never be started |

## [Service]: start and settings

| Line | What it does | Why here |
|---|---|---|
| `Type=simple` | The service is up as soon as the process is started | The relay is one long-running process that does not fork |
| `ExecStart=/usr/bin/python3 -u /usr/local/lib/telegram-relay/telegram_relay.py` | Runs the root-owned copy of the code | `-u` turns off output buffering, so each log line reaches the journal at once. The code is in a root-owned folder: the service user cannot change the program that receives the token |
| `EnvironmentFile=/etc/telegram-relay/relay.conf` | Loads `KEY=value` lines into the environment of the process | Settings without secrets. systemd reads the file itself: no `$VARIABLE` is expanded and no command runs, unlike a shell `source` |
| `LoadCredential=telegram.token:/etc/telegram-relay/telegram.token` | At start, systemd (as root) reads the token file and puts a read-only copy in a private directory, `$CREDENTIALS_DIRECTORY` | Only the service user and root can read that copy. The original file stays mode 600, root only: the service never needs, and never gets, access to it. The token is not in the environment either |

## [Service]: identity and state

| Line | What it does | Why here |
|---|---|---|
| `DynamicUser=yes` | systemd creates a user with a free UID when the service starts and releases it when it stops | No permanent account with a password, a home or a shell. Files owned by it nowhere else on the system. It also turns on several protections by itself: `ProtectSystem=strict`, `ProtectHome=read-only`, a private `/tmp`, `NoNewPrivileges=`, `RestrictSUIDSGID=` and `RemoveIPC=` |
| `StateDirectory=telegram-relay` | Creates `/var/lib/telegram-relay`, writable by the service, and sets `$STATE_DIRECTORY` | The only place where the relay may write: the update offset. With `DynamicUser=` the real folder is `/var/lib/private/telegram-relay`, which is why the rollback removes that path |

## [Service]: restart policy

| Line | What it does | Why here |
|---|---|---|
| `Restart=on-failure` | Restarts after a non-zero exit, a crash signal, a timeout or an out-of-memory kill | A network error does not stop the relay (it retries by itself), but a crash should not leave the bot silent |
| `RestartSec=10` | Waits 10 seconds before the restart | Avoids a tight loop that would flood the journal and the Bot API |
| `RestartPreventExitStatus=2` | Never restarts after exit code 2 | The relay exits with 2 on a configuration error. Restarting cannot fix a wrong setting; it would only hide the message under hundreds of identical ones |

## [Service]: sandbox

Several lines repeat what `DynamicUser=yes` already implies. They are written anyway: the unit then stays safe if someone replaces `DynamicUser=` by a fixed `User=` later, and a reader sees every protection without knowing the implied list.

| Line | What it does | What it blocks |
|---|---|---|
| `NoNewPrivileges=yes` | The process and its children can never gain privileges | A setuid program such as `sudo` or `su` cannot raise the rights of the relay |
| `ProtectSystem=strict` | The whole file system is read-only for the service, except its own state directory and the API file systems | Writing a backdoor, a cron job or a changed binary anywhere on node-b |
| `ProtectHome=yes` | `/home`, `/root` and `/run/user` look empty | Reading SSH keys or files of the administrator. Stricter than the read-only view `DynamicUser=` gives alone |
| `PrivateTmp=yes` | A private, empty `/tmp` and `/var/tmp` | Reading or planting files in the shared temporary folders |
| `PrivateDevices=yes` | A minimal `/dev` with only pseudo devices such as `/dev/null` and `/dev/urandom` | Raw access to disks or other hardware |
| `ProtectKernelTunables=yes` | `/proc/sys` and `/sys` are read-only | Changing kernel settings such as IP forwarding |
| `ProtectKernelModules=yes` | No module loading | Loading a kernel module, the shortest path to full control |
| `ProtectKernelLogs=yes` | No access to the kernel log buffer | Reading kernel messages, which can leak addresses useful for an exploit |
| `ProtectControlGroups=yes` | The control group tree is read-only | Raising its own memory limit or moving into another group |
| `ProtectClock=yes` | No writes to the system or hardware clock | Changing the time, which would break logs, certificates and timers |
| `ProtectHostname=yes` | No change of host or domain name | Changing how node-b names itself in logs and monitoring |
| `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` | Only IPv4, IPv6 and local sockets may be opened | Raw packet sockets and netlink (sniffing, changing routes). The relay only needs HTTPS out and HTTP to loopback |
| `RestrictNamespaces=yes` | No new namespaces | Building a container-like environment to escape the sandbox |
| `RestrictRealtime=yes` | No real-time scheduling | Freezing the CPU with a real-time busy loop |
| `LockPersonality=yes` | The execution domain cannot be changed | Old compatibility modes used by some exploits |
| `MemoryDenyWriteExecute=yes` | No memory that is writable and executable at the same time | Injecting machine code and running it. CPython does not need such memory, so the relay runs normally |
| `SystemCallArchitectures=native` | Only the system calls of the native architecture | Using the 32-bit system call interface to get around filters |
| `CapabilityBoundingSet=` | Empty: no Linux capability, ever, even through a setuid file | Binding a low port, changing file owners, raw sockets: every root power split into capabilities |
| `MemoryMax=64M` | Hard memory limit of the control group | A leak or an attack cannot take the memory n8n needs on a node with under 4 GB. Above the limit the kernel kills the relay and `Restart=` brings it back |

## [Install]

| Line | What it does | Why here |
|---|---|---|
| `WantedBy=multi-user.target` | `systemctl enable` links the unit to the normal boot target | The relay starts at every boot, without a logged-in user |

## Measure it

```bash
# Exposure score from 0 (locked down) to 10 (no sandbox), with one line per setting
systemd-analyze security telegram-relay.service

# What the service actually sees
sudo systemd-run --pty -p DynamicUser=yes -p ProtectSystem=strict -p ProtectHome=yes \
    /bin/sh -c 'id; touch /etc/test 2>&1; ls /home'
```

The second command starts a throw-away shell with some of the same settings: `id` shows a dynamic user, `touch` fails with "Read-only file system" and `/home` looks empty.

## Further hardening, not applied

These settings would lower the score further. They are **not** in the unit yet, because each one must be tested on node-b with the phone tests of the [relay guide](README.md#verify) before it is kept.

| Setting | Effect | Risk to check |
|---|---|---|
| `SystemCallFilter=@system-service` | Allows only the system calls a normal service uses | Python or its SSL library may need a call outside the set |
| `SystemCallErrorNumber=EPERM` | A blocked call fails instead of killing the process | Errors become quieter; read the journal after the change |
| `ProtectProc=invisible` and `ProcSubset=pid` | Hides the other processes of node-b | None expected for the relay |
| `UMask=0077` | New files readable by the service only | The offset file is the only file the relay writes |
| `PrivateUsers=yes` | The service sees a user namespace with no other users | Interaction with `DynamicUser=` to confirm on the systemd version of node-b |

Reference: [systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html) (sandboxing, credentials, `DynamicUser=`), [systemd.service](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html) (`Restart=`, `RestartPreventExitStatus=`), [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html) (`MemoryMax=`), [systemd-analyze security](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html).
