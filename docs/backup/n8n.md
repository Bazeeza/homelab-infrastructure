# n8n backup and restore

How the workflow engine of the status bot on node-b is backed up, why its encryption key is kept apart, and how to bring it back. Placeholders: `<N8N_CONTAINER>`, `<N8N_ENCRYPTION_KEY>` (see [anonymization rules](../anonymization.md)).

## What has to survive

| Item | Where it lives | In the daily archive? |
|---|---|---|
| Workflows | n8n database, inside the `n8n_data` volume | Yes, one JSON file per workflow |
| Credentials (Telegram bot, Uptime Kuma API key) | n8n database, **encrypted** with the instance key | Yes, still encrypted |
| Encryption key | `.env` next to the Compose file (`N8N_ENCRYPTION_KEY`); without it, n8n generates one in `~/.n8n` on first start | **No**, on purpose |
| Execution history | n8n database, pruned after 7 days | No: not needed to run the bot |
| Compose file and version | [`configs/docker/n8n.compose.example.yml`](../../configs/docker/n8n.compose.example.yml) with the pinned version | Rebuilt from this repository |

## The encryption key

n8n encrypts each credential with its instance key before writing it to the database. A database or a credential export restored **without the same key** gives credentials that n8n cannot decrypt: every workflow that uses them fails, and the only fix is to type each secret again.

That makes the key the single most important item, and also the most dangerous one: key plus archive opens every credential. So the two are kept **apart** ([ADR 0008](../adr/0008-keep-backups-and-keys-apart.md)):

- the archive stays on node-b (and later on the off-site disk);
- the key is stored once in the administrator's password manager, as a note named after the instance, and nowhere else outside node-b.

Check once, after any change to `.env`, that the copy in the password manager is the same as the one on the node. Compare a fingerprint, never print the key:

```bash
# On node-b, as root: prints a hash of the key, not the key
grep '^N8N_ENCRYPTION_KEY=' /opt/n8n/.env | cut -d= -f2- | tr -d '\n' | sha256sum
```

Run the same pipeline on the copy from the password manager (pasted into a file with mode 600, deleted afterwards) and compare the two hashes.

## How the daily backup works

The example unit and timer are in [`configs/backup/`](../../configs/backup/). In order:

1. Empty the export folder, in the container and on the host, so a deleted workflow does not live on.
2. `n8n export:workflow --backup` and `n8n export:credentials --backup` inside the container. `--backup` means `--all --pretty --separate`: one readable file per item. **No `--decrypted`**: that flag writes every secret in clear text.
3. `docker cp` the export to the host, then [`scripts/backup-rotate.sh`](../../scripts/backup-rotate.sh) writes `n8n-<UTC timestamp>.tar.gz` and its `.sha256` in `/var/backups/n8n` (mode 700) and keeps the newest 7.
4. [`scripts/verify-backup.sh`](../../scripts/verify-backup.sh) reads the new archive back. If it fails, the unit is marked failed.

Why the command-line export instead of copying the database file: the export is consistent while n8n runs, it is plain JSON that can be compared between two days, and it can be imported into a newer n8n version. A copied database file is tied to the version and must be taken with n8n stopped.

### Install on node-b

```bash
# On node-b, as root. Back up first, write the rollback before the change.
install -o root -g root -m 755 scripts/backup-rotate.sh  /usr/local/sbin/backup-rotate.sh
install -o root -g root -m 755 scripts/verify-backup.sh  /usr/local/sbin/verify-backup.sh
install -o root -g root -m 644 configs/backup/n8n-backup.service /etc/systemd/system/
install -o root -g root -m 644 configs/backup/n8n-backup.timer   /etc/systemd/system/
sudoedit /etc/systemd/system/n8n-backup.service   # replace <N8N_CONTAINER>
systemd-analyze verify /etc/systemd/system/n8n-backup.service
systemctl daemon-reload

# First run by hand, then read the result
systemctl start n8n-backup.service
systemctl status n8n-backup.service --no-pager
ls -l /var/backups/n8n/

# Only then schedule it
systemctl enable --now n8n-backup.timer
systemctl list-timers n8n-backup.timer
```

The backup job already running on node-b predates this repository. Disable it before enabling this timer, so two jobs do not write to the same folder.

### Rollback

```bash
systemctl disable --now n8n-backup.timer
rm /etc/systemd/system/n8n-backup.service /etc/systemd/system/n8n-backup.timer
systemctl daemon-reload
# The archives in /var/backups/n8n are kept; re-enable the previous job if there was one.
```

## Restore

Always restore into a **scratch** n8n first ([restore test](restore-test.md)), then into production only if the scratch copy works.

```bash
# 1. Check the archive and extract it into a scratch folder
/usr/local/sbin/verify-backup.sh /var/backups/n8n/n8n-<TIMESTAMP>.tar.gz --keep-scratch
#    -> prints "scratch kept: /tmp/tmp.XXXXXX"

# 2. Start n8n with the SAME encryption key (from the password manager in .env),
#    then copy the export into the container
docker cp /tmp/tmp.XXXXXX/n8n-staging <N8N_CONTAINER>:/home/node/restore

# 3. Import credentials first, then workflows (workflows refer to credentials)
docker exec -u node <N8N_CONTAINER> n8n import:credentials --separate --input=/home/node/restore/credentials/
docker exec -u node <N8N_CONTAINER> n8n import:workflow   --separate --input=/home/node/restore/workflows/

# 4. Clean up the copies that contain the (encrypted) credentials
docker exec -u node <N8N_CONTAINER> rm -rf /home/node/restore
rm -rf /tmp/tmp.XXXXXX
```

Imported workflows are **deactivated** by the import: activate the status bot workflow in the editor (through the SSH tunnel), then send the bot command from Telegram to test the whole path.

> [!WARNING]
> Before any maintenance command that touches n8n users or the database (for example a password reset of the owner account), take an export first, even if the documentation says the credentials are kept. On this instance, a reset of the owner account made the credentials disappear from the editor; they came back only because they had been exported just before. See [lessons learned](../lessons-learned.md#an-account-reset-removed-the-n8n-credentials).

## References

- n8n Docs, [CLI commands](https://docs.n8n.io/hosting/cli-commands/) (`export:workflow`, `export:credentials`, `--backup`, `--decrypted`, `import:*`, imports deactivate workflows).
- n8n Docs, [Set a custom encryption key](https://docs.n8n.io/hosting/configuration/configuration-examples/encryption-key/).
- systemd, [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html) (`Persistent=`, `RandomizedDelaySec=`) and [systemd.time](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html) (time zone in calendar events).
