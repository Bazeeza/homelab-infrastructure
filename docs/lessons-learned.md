# Lessons learned

What went wrong on this infrastructure, what was learned, and what changed because of it. Written in a **blameless** way: the question is "what let this happen?", not "who did it?". Names, addresses and versions are left out on purpose (see [anonymization rules](anonymization.md)).

> [!NOTE]
> Only real events are listed. Each lesson points to the rule, script or decision record that came out of it. A lesson that changed nothing is only an anecdote.

## Summary

| When | What happened | Main lesson | What changed |
|---|---|---|---|
| 2026-11 | [Remote management server compromise](#remote-management-server-compromise) | A web interface left open is an attack surface; a backup is trusted input | Server rebuilt, hardened; [ADR 0008](adr/0008-keep-backups-and-keys-apart.md) |
| 2026-10 | [An account reset removed the n8n credentials](#an-account-reset-removed-the-n8n-credentials) | Export before maintenance, even when the docs say nothing is lost | Export step in [n8n backup](backup/n8n.md) |
| 2026-11 | [Monitoring kept checking things that no longer existed](#monitoring-kept-checking-things-that-no-longer-existed) | A change is finished when monitoring follows it | Monitoring step in the [rollback plan](rollback.md#before-the-change) |
| Ongoing | [An expected red light](#an-expected-red-light) | Document what "normal" looks like | Expected states in [monitoring](monitoring/README.md) |
| Design | [Docker publishes around the firewall](#docker-publishes-around-the-firewall) | Check from outside, not from the rules | [ADR 0005](adr/0005-publish-container-ports-on-loopback.md), [access checks](network/access-verification.md) |

## Remote management server compromise

**Short version.** An attacker abused a stored cross-site scripting (XSS) flaw of the remote management server, already fixed in a newer upstream release, through the administrator's open browser session. The server was taken offline, examined, and rebuilt from nothing.

### Timeline

| Step | What happened |
|---|---|
| Day 1 | A forged agent sent an event with JavaScript in one of its fields. The web interface displayed that field without escaping it. |
| Day 1 | The code ran inside an **administrator tab left open for hours**, with the administrator's rights. It used the server's restore function to upload a crafted backup and installed two plugins: a backdoor and a command console reaching every managed device. |
| Day 1 to 2 | A bug in one of the plugins made the server crash and restart in a loop. That crash is what revealed the incident. |
| Day 2 | Server stopped and examined. Server rebuilt on a fixed release, under a dedicated user without shell, with a hardened unit. Old certificate revoked as compromised; a tunnel token found in the old configuration treated as leaked (tunnel deleted). The administrator workstation checked and old remote access tools removed. |
| Day 3 | Evidence (plugins, old data folder, old database, payload) kept **off the servers** in an archive checked by SHA-256, then removed from the servers. The separate database server that the old setup used was uninstalled; SSH closed on the public address of both nodes ([ADR 0002](adr/0002-administration-only-over-mesh-vpn.md)). |

### What was found

- No persistence on the operating system of node-a, and the installed server package matched the original.
- No action of the attacker visible on the managed devices.
- The only destination the injected code sent data to was a local port on the administrator's own machine, where nothing was listening: the theft probably did not succeed. The attacker's address could not be found, because it was **not logged**.
- The server keys, its configuration and its certificate were still treated as stolen: when you cannot prove a secret is safe, you rotate it.

### What let it happen

| Factor | Why it mattered |
|---|---|
| The server ran a version with a known, already fixed flaw | The fix existed; it was not applied in time. |
| An administrator tab stayed open for hours | The injected code ran with full rights, without needing a password. |
| The restore function accepted any uploaded backup | A backup is code-like input: restoring it rewrites the server. |
| Plugins were enabled | The attacker could add features to the server, including a console on every device. |
| Source addresses of agents were not logged | The investigation could not say where the attack came from. |

### What changed

- **Rebuilt, not cleaned.** A cleaned server can still hide one change you missed; a rebuild from a known source cannot.
- **Smaller attack surface on the rebuilt server:** plugins off, invitation codes off, account creation off, second factor mandatory, one administrator, strict allowed origin, dedicated system user, hardened systemd unit with write access to its own folder only.
- **Habits:** log out of administrative interfaces after use; no permanent sharing links; never install a plugin that has not been reviewed; apply security releases of internet-facing services quickly.
- **Backups:** checksums on every archive, restores only from archives older than the intrusion and checked by hand, secrets rotated instead of restored ([ADR 0008](adr/0008-keep-backups-and-keys-apart.md)).
- **Evidence kept off the servers**, so the investigation does not depend on the machine under investigation.

## An account reset removed the n8n credentials

**What happened.** The password of the n8n owner account was lost and reset with the n8n command line. After the reset, the stored credentials (Telegram bot, monitoring API key) no longer appeared in the editor, contrary to what was expected.

**Why it did not become an outage.** The credentials had been exported just before the reset. They were imported again with the same encryption key and the bot worked.

**What changed.** An export is now the first step of any maintenance on n8n users or its database, and the daily backup exports the credentials too ([n8n backup](backup/n8n.md)). n8n cannot send a recovery e-mail on this instance, so the owner password lives in the password manager.

## Monitoring kept checking things that no longer existed

**What happened.** After the rebuild, some Uptime Kuma probes still pointed at removed components: the health port of a deleted tunnel, the database server that was uninstalled, and the SSH port of node-b on its public address, closed since. Those probes were red for reasons that no longer meant anything, which hides the next real red.

A related trap: the health port of the tunnel client changes when it restarts, so a probe of that port breaks at every restart. Probing the **public result** (the web page answers through the tunnel) is more reliable than probing an internal detail.

**What changed.** Updating the probes is now a step of every change ([rollback plan](rollback.md#before-the-change)), and the open points are tracked in [monitoring](monitoring/README.md#open-points).

## An expected red light

**What happened.** The administrator laptop is probed by Uptime Kuma. It sleeps on battery, so the probe is often red. A light that is red for a normal reason teaches everyone to ignore red.

**What changed.** The expected state is written down next to the probe ([monitoring](monitoring/README.md#who-watches-whom)). The longer-term fix is a desktop machine that stays on, so the probe means something again.

## Docker publishes around the firewall

**What happened.** No incident, but a near miss in the design: Docker writes its own iptables rules, so a container published on all interfaces is reachable from the Internet even when ufw denies the port. The firewall rules look right and the service is still exposed.

**What changed.** Containers are published on `127.0.0.1` only ([ADR 0005](adr/0005-publish-container-ports-on-loopback.md)), and exposure is checked **from outside** and with [`scripts/audit-listening-ports.sh`](../scripts/audit-listening-ports.sh), never by reading the firewall rules alone.

## References

- Google SRE book, [Postmortem Culture: Learning from Failure](https://sre.google/sre-book/postmortem-culture/).
- OWASP, [Cross Site Scripting (XSS)](https://owasp.org/www-community/attacks/xss/).
- NIST, [SP 800-61 Rev. 3, Incident Response Recommendations and Considerations for Cybersecurity Risk Management](https://csrc.nist.gov/pubs/sp/800/61/r3/final) (2025; recovery and lessons learned as part of incident response).
