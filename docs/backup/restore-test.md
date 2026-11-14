# Restore test

A backup is proven only by a restore. This page is the procedure for that proof and the place where its result is recorded. Placeholders only (see [anonymization rules](../anonymization.md)).

> [!NOTE]
> **State:** no full restore test has been run yet on a scratch machine. The table at the end is empty on purpose: it is filled in only with real, timed results. Until then, the recovery times in the [backup overview](README.md#recovery-objectives) are targets, not facts.

## Three levels of proof

| Level | What it proves | How | How often |
|---|---|---|---|
| 1. The archive reads back | The file is complete and not corrupted | [`scripts/verify-backup.sh`](../../scripts/verify-backup.sh), run by the backup job itself after each archive | Every backup |
| 2. The data opens in the application | The content is usable, the keys match | Restore into a scratch instance of the service | After any change to the backup job, and every 3 months |
| 3. The service runs again from nothing | The whole procedure, including the parts that are not in the archive (keys, versions, DNS, firewall) | Rebuild the node on a fresh server with only this repository, the archive and the password manager | Once a year, or before relying on a new node |

Level 1 is automatic. Levels 2 and 3 need a human and a scratch machine.

## The scratch machine

- A local virtual machine on `admin-ws`, or a throwaway cloud server destroyed right after the test.
- Same Ubuntu release and same pinned application version as the node.
- **Isolated.** A restored remote management server holds the real server keys: the managed devices would trust it. It must not get the real DNS name, must not join the mesh VPN with a node tag, and is destroyed at the end of the test, with its disk.
- Never on the production node itself: a restore that goes wrong there becomes the outage.

## Level 2: n8n

1. Install Docker and start n8n with the [example Compose file](../../configs/docker/n8n.compose.example.yml), the same pinned version, and the encryption key **copied from the password manager**, not from node-b. This also tests that the stored key is the right one.
2. Copy the newest archive from node-b over the mesh (`scp`), check it with `verify-backup.sh --keep-scratch`.
3. Import credentials, then workflows, as in [n8n restore](n8n.md#restore).
4. Open the editor through an SSH tunnel and check:
   - every workflow is listed;
   - opening a credential shows its fields, with no decryption error;
   - a manual run of the status workflow reaches the step that reads Uptime Kuma (it may fail there: the scratch machine is not on the mesh).
5. Note the time from step 1 to step 4, then destroy the scratch machine.

## Level 2: remote management server (node-a)

1. Install the same version of the remote management server on the scratch machine, as a dedicated user without shell, and stop the service.
2. Copy the newest local archive of node-a, check its checksum, extract it into the server data folder.
3. Start the service **without** its real domain name (access by the scratch machine address; refused origins are expected and can be allowed for the test only).
4. Check that the administrator account can log in with its second factor, and that the device groups and devices are listed (they show offline: the agents keep talking to the real server).
5. Note the time, then destroy the scratch machine and its disk: it held the real server keys.

## Level 3: rebuild a node

Start from a new server with nothing but:

- this repository (configuration examples, scripts, the [network and access](../network/README.md) steps);
- the newest archive of the node;
- the password manager (encryption key, private values that replace the placeholders).

Write down every step that needed something **not** on that list: each one is a gap in the documentation or in the backup, and gets fixed before the next test.

## What to record

Copy this row for each test. Only real results; a failed test is recorded too, it is the most useful row.

| Date | Level | Component | Archive used | Result | Time to restore | Problems found | Fixed by |
|---|---|---|---|---|---|---|---|
| — | — | — | — | Not yet performed | — | — | — |

## References

- CISA, [#StopRansomware Guide](https://www.cisa.gov/stopransomware/ransomware-guide): "regularly test the availability and integrity of backups in a disaster recovery scenario".
- NIST, [SP 800-34 Rev. 1](https://csrc.nist.gov/pubs/sp/800/34/r1/upd1/final), chapter on plan testing, training and exercises.
