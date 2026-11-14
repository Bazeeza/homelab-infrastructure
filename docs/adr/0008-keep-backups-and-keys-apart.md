# 0008. Keep backups off the node they protect, and the keys apart from the backups

- **Status:** Accepted, partly applied: daily local backups run on both nodes; the off-site copy waits for hardware
- **Decided:** 2026-11-14 (recorded; the local backups were already running)
- **Applies to:** node-a, node-b, admin-ws

## Context

- Each node makes a daily local backup: the remote management server data on node-a (14 days kept), the n8n workflows and credentials on node-b (7 copies kept). Today these copies live **on the same server** as the data.
- A local copy protects against a bad change or a deleted file. It does not protect against the loss of the server (provider incident, deleted instance, full disk failure) or against an attacker with root, who can delete the backups as easily as the data.
- Two backups carry secrets: the remote management archive contains the server private keys, and the n8n credentials are encrypted with an instance key. The n8n key is not in the archive; without it, the restored credentials cannot be decrypted.
- In November 2026 the remote management server was compromised through its web interface, and the intruder used its **restore** function with a crafted backup ([lessons learned](../lessons-learned.md#remote-management-server-compromise)). A backup is input that the server trusts completely.

## Decision

We will keep backups **away from the node they protect**, and keep the **keys apart from the backups**.

- The off-site copy is **pulled** by `admin-ws` over the mesh VPN onto an encrypted disk that is disconnected between copies. No node holds a credential that can write to or delete it.
- Encryption keys and account recovery codes are stored in the administrator's password manager, never on the backup disk.
- Every archive has a checksum written at creation and checked before any restore ([`scripts/verify-backup.sh`](../../scripts/verify-backup.sh)).
- After a compromise, the service is **rebuilt** and only data that predates the intrusion, checked by hand, is brought back. Secrets found in backups are rotated, never restored.

## Consequences

- **Positive:**
  - Losing a node, or root on a node, no longer means losing its backups once the off-site copy is in place.
  - A stolen backup disk gives encrypted data without the key to open it.
  - The checksum turns "is this the archive we wrote?" into a command with an answer.
- **Negative:**
  - The off-site copy depends on a person: if `admin-ws` does not pull, the copy gets old. The age check (`verify-backup.sh --max-age-hours`) must run on the off-site copy too.
  - Two places to keep in sync: if the n8n key changes and the password manager is not updated, the next restore fails. The key fingerprint check in [n8n backup](../backup/n8n.md#the-encryption-key) exists for that.
  - The RPO stays at 24 hours for the local copy and becomes the pulling interval for the off-site copy.
- **Follow-up:**
  - Buy and encrypt the off-site disk, then write the pull script and its schedule on `admin-ws`.
  - Run the first [restore test](../backup/restore-test.md) and record the result.
  - Replace the running backup jobs by the tested scripts of this repository, one node at a time.
  - Check what the node-a backup job actually includes against the [inventory](../backup/README.md#inventory).

## Alternatives considered

| Option | Why it was not chosen |
|---|---|
| Keep local backups only | Covers mistakes, not the loss of the server or an attacker with root. That gap is the reason for this decision. |
| Each node pushes its backups to a cloud bucket | The node would hold credentials able to write, and often delete, the remote copy: root on the node could erase the backups. Possible later with an append-only bucket and a write-only key. |
| Back up the two nodes onto each other | Cheap, but root on one node reaches the other's backups, which breaks the role separation of [ADR 0003](0003-separate-critical-and-automation-roles.md). The critical node would also store data written by the automation node. |
| Provider snapshots of the whole disk | Useful as a fast rollback before an upgrade, but stored at the same provider, in the same account, and they restore a whole system, including what an intruder changed. Kept as a complement, not as the backup. |
| Store the n8n key inside the archive | One file restores everything, and one stolen file opens every credential. Rejected. |

## How to verify

```bash
# On each node: the newest local archive is fresh and reads back
/usr/local/sbin/verify-backup.sh --latest /var/backups/<service> --max-age-hours 26

# On admin-ws, once the off-site copy exists: same check on the disk
bash scripts/verify-backup.sh --latest /media/<OFFSITE_DISK>/<node>/<service> --max-age-hours 192
```

## References

- CISA, [#StopRansomware Guide](https://www.cisa.gov/stopransomware/ransomware-guide) (offline, encrypted backups; attackers look for accessible backups).
- NIST, [SP 800-34 Rev. 1](https://csrc.nist.gov/pubs/sp/800/34/r1/upd1/final) (backup and recovery strategies).
