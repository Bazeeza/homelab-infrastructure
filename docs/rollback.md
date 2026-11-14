# Rollback plan

How a change on a node is undone. The rule behind every line of this page: **the way back is written before the change is made.** A rollback improvised during an outage is slow and often makes things worse. Placeholders only (see [anonymization rules](anonymization.md)).

> [!NOTE]
> Rollback and restore are different tools. A **rollback** undoes a change you just made (a configuration file, a version, a unit), in minutes, with the copy you kept a moment ago. A **restore** brings back data from a [backup](backup/README.md) after a loss. Most incidents need the first one.

## Before the change

A short checklist, done every time, on one node at a time.

1. **Say where.** Run `hostname` at the top of the session and name the node in the change note. The same command on the wrong node is a second incident.
2. **Keep a copy of what you change**, next to it, with a suffix that the configuration loader ignores or that cannot be confused with a live file:

   ```bash
   sudo cp -a /etc/ssh/sshd_config.d/00-hardening.conf /root/00-hardening.conf.before-$(date -u +%Y%m%d)
   ```

   Keep the copy **outside** folders that are read as a whole (`sshd_config.d/`, `sudoers.d/`, `systemd/system/`): some loaders read every file in the folder, and an old copy would be loaded too.
3. **Write the rollback command** in the change note, and check that it would work (the copy exists, the old version can still be pulled).
4. **Keep a way in that the change cannot cut**: a second SSH session left open, and the provider web console tested recently. For a firewall change, schedule the automatic rollback described in [Host firewall](network/host-firewall.md#safety-net-for-a-remote-change).
5. **Know what "working" means**: the check that proves the change is good, and the one that proves the service still runs (`systemctl is-active <unit>`, an HTTP test, the bot command).
6. **Plan the monitoring update**: if the change removes, moves or renames something, list the probes to change ([lessons learned](lessons-learned.md#monitoring-kept-checking-things-that-no-longer-existed)).

## Rollback by type of change

| Change | How to undo it | Expected time | Details |
|---|---|---|---|
| sshd drop-in | Remove or restore the file, `sshd -t`, `systemctl reload ssh` from the session kept open | 1 min | [SSH access](network/ssh-access.md#3-harden-sshd-without-locking-yourself-out) |
| ufw rules | Automatic: `ufw disable` after 10 minutes unless cancelled; then `ufw reset` and re-apply the baseline | 10 min | [Host firewall](network/host-firewall.md#safety-net-for-a-remote-change) |
| Mesh VPN access policy | Paste back the copy of the policy saved before the edit; if the mesh is cut, use the provider web console | 5 min | [Mesh VPN](network/mesh-vpn.md#fallback-when-the-mesh-is-down) |
| Container version (n8n) | Put the previous pinned tag back in the Compose file, `docker compose up -d`; export before any upgrade, a database migration may not go backwards | 5 min | [n8n backup](backup/n8n.md#restore) |
| Container port binding | Restore the Compose file copy, `docker compose up -d`, check with the port audit | 2 min | [Docker on loopback](network/docker-loopback.md#check) |
| Telegram relay | `systemctl disable --now`, remove the unit and the code folder, `daemon-reload` | 2 min | [Relay rollback](relay/README.md#rollback) |
| Cross-check | Remove the cron line, the script and its user | 2 min | [Cross-check rollback](monitoring/cross-check.md#roll-back) |
| Backup job | Disable the timer, remove the units; archives are kept | 2 min | [n8n backup rollback](backup/n8n.md#rollback) |
| Remote management server upgrade | Stop the service, put back the previous package version and the data copy taken just before, start | 15 min | Copy of the data folder **and** a checksum before the upgrade |
| Monitoring agents (Beszel) | Reinstall the previous version | 5 min | [Beszel updating](monitoring/beszel.md#updating) |

## When to roll back, and when not to

| Situation | Decision |
|---|---|
| The change breaks the service and the cause is not obvious within the time planned | **Roll back first**, investigate after, with the service running. |
| The change works but something unrelated breaks at the same time | Roll back anyway if the link cannot be ruled out quickly: two simultaneous changes are rarely a coincidence. |
| A security fix breaks a minor feature | Keep the fix, work around the feature. Rolling back reopens the hole. |
| A data migration has already run (a new application version upgraded its database) | Do not downgrade the application over the migrated data: **restore** the export taken before the upgrade instead. |
| The node is compromised | Not a rollback: isolate, keep the evidence, rebuild ([lessons learned](lessons-learned.md#remote-management-server-compromise)). |

## After the change, or after the rollback

- Run the checks of step 5 again, from **outside** the node when the change is about access ([access verification](network/access-verification.md)).
- Update the probes listed in step 6 ([Uptime Kuma, checks after a change](monitoring/uptime-kuma.md#checks-after-a-change)).
- Delete the `.before` copy only after a few days without problems; it may contain a secret, so it stays in `/root`, readable by root only, until then.
- If the change was a decision, record it in an [ADR](adr/README.md); if it went wrong, add it to the [lessons learned](lessons-learned.md).

## References

- Google SRE book, [Release Engineering](https://sre.google/sre-book/release-engineering/) (reproducible, versioned releases that can be rolled back).
- OpenSSH, [sshd(8)](https://man.openbsd.org/sshd.8) (`-t` and `-T` test modes used before a reload).
