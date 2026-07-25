# Linux Backup to SMB

## Overview

This project creates local compressed backups on a Linux host and transfers them to a remote SMB share. It consists of two independent shell jobs:

- `backup.sh` creates a dated `.tar.gz` archive in the configured local backup directory.
- `transfer-backups.sh` copies pending archives to an SMB share, verifies them with SHA-256, removes successfully transferred local copies, and applies remote retention.

`update-status.py` maintains a JSON status file used by Homarr or another external status consumer. Runtime settings are kept in `backup.conf`.

The scripts are intended for a Linux system with Bash and GNU command-line utilities. The transfer job is designed to run with root privileges because mounting and unmounting the SMB share typically requires elevated permissions. In the current configuration, the paths, lock files, SMB credentials, and mount operation also normally require the backup job to run with suitable elevated permissions.

Before running either job, create the local configuration file from the tracked example:

```bash
cp backup.conf.example backup.conf
```

Review every value in `backup.conf` before the first run. The local configuration file is ignored by Git.

## Requirements

- Linux
- Bash
- Python 3
- GNU tar
- coreutils
- `mount.cifs`
- `sha256sum`
- `flock`

## Features

- Configurable source, backup, logging, data, SMB, retention, and lock paths
- Daily archive names in the form `YYYY-MM-DD - Backup of HOST_NAME.tar.gz`
- Compression with `tar` and gzip
- Source validation and free-space checking before archive creation
- At least the uncompressed source size plus 1 GiB of free backup space required
- Partial archive filenames during creation
- Atomic final publication using a hard link, without overwriting an existing archive
- Validation of new and existing archives with `tar --list`
- Per-job locking with `flock`
- SMB 3.0 transfer using a credentials file
- SHA-256 verification before deletion of a local archive
- Configurable count-based retention on the SMB destination
- Concurrent-safe, atomic JSON status updates for Homarr
- Dedicated backup and daily transfer logs

### Docker behavior

The backup script discovers the containers that are running before archive creation:

```bash
mapfile -t RUNNING_CONTAINERS < <(docker ps --format '{{.ID}}')
```

It stops those containers before creating the archive and attempts to restart only those containers after success, failure, or interruption.

## Folder structure

```text
linux-backup-to-smb/
├── .gitignore              # Excludes local configuration and runtime files
├── backup.conf.example     # Tracked configuration template
├── backup.conf             # Local configuration; created by the user and ignored
├── backup.sh               # Creates and validates local backup archives
├── transfer-backups.sh     # Transfers, verifies, and retains remote archives
├── update-status.py        # Updates the Homarr-compatible JSON status
├── LICENSE                 # MIT license
├── README.md               # Project documentation
├── data/
│   ├── .gitkeep                 # Keeps the empty runtime directory in Git
│   ├── backup_status.json       # Generated status document; ignored
│   └── backup_status.json.lock  # Generated status lock; ignored
└── logs/
    ├── .gitkeep            # Keeps the empty runtime directory in Git
    ├── backup.log          # Local backup log
    └── transfer-YYYY-MM-DD.log
                              # One transfer log per day
```

The `data` and `logs` directories contain runtime output. Their configured locations must remain accessible to the user running the jobs.

## `backup.conf` configuration reference

`backup.sh` and `transfer-backups.sh` locate `backup.conf` relative to their own script directory. This makes invocation independent of cron's working directory. The repository provides `backup.conf.example`; copy it to the ignored `backup.conf` file before use.

The file is Bash syntax and is sourced directly. Keep assignments properly quoted and retain Bash array syntax for `SOURCE_DIRS`.

| Option | Example value | Purpose |
| --- | --- | --- |
| `HOST_NAME` | `example-host` | Host label embedded in the backup filename. |
| `BACKUP_DIR` | `/path/to/local-backups` | Local directory where archives are created and await transfer. |
| `SOURCE_DIRS` | `("/path/to/source-directory")` | Bash array of files or directories passed to `tar`. Missing entries are logged and skipped. At least one configured entry must exist. |
| `REMOTE_SHARE` | `//smb-server/share` | SMB share receiving completed archives. |
| `MOUNT_POINT` | `/path/to/mount-point` | Local mountpoint for the SMB share. |
| `CREDENTIALS_FILE` | `/path/to/smb-credentials` | Credentials file referenced by the CIFS mount options. |
| `RETENTION_COUNT` | `4` | Number of most recently modified remote `.tar.gz` files to retain. It must be a positive integer greater than zero. |
| `LOG_DIR` | `${SCRIPT_DIR}/logs` | Directory containing backup and transfer logs. |
| `DATA_DIR` | `${SCRIPT_DIR}/data` | Directory containing `backup_status.json`. |
| `BACKUP_LOCK_FILE` | `/run/lock/backup-create.lock` | Lock file for the local backup job. |
| `TRANSFER_LOCK_FILE` | `/run/lock/backup-transfer.lock` | Lock file for the transfer job. |
| `MOUNT_OPTIONS` | See `backup.conf` | Complete CIFS option string, including the credentials file, SMB version, character encoding, ownership, and permissions. |

Both scripts stop before their normal work if `backup.conf` cannot be read or a required value is empty. `transfer-backups.sh` also rejects an invalid `RETENTION_COUNT`.

### Configuring source directories

Add or remove entries inside the Bash array:

```bash
SOURCE_DIRS=(
    "/path/to/source-directory"
    "/path/to/another-source"
)
```

Do not list a child directory separately when its parent is already included unless duplicate archive content is intentional. Archive paths are stored without a leading slash—for example, `/path/to/source-directory` is stored as `path/to/source-directory`.

### SMB credentials

The credentials file is consumed by `mount.cifs`; the project does not create or manage it. Its contents normally follow the format expected by `mount.cifs`:

```ini
username=SMB_USERNAME
password=SMB_PASSWORD
```

Protect the file so it is readable only by the appropriate privileged user.

## Cron jobs

The repository does not install a crontab or prescribe a schedule. Add the jobs to the root crontab, or another account with all required filesystem, lock, archive, and mount permissions:

```bash
sudo crontab -e
```

Example schedule:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 2 * * * /path/to/project/backup.sh
0 4 * * * /path/to/project/transfer-backups.sh
```

These example times create a backup at 02:00 and attempt transfer at 04:00 each day. Choose times appropriate for the host and network. Schedule transfer after backup so the newly created archive is eligible for upload.

Both jobs use nonblocking locks. If another instance of the same job already holds its lock, the new invocation logs that fact and exits without waiting. The backup and transfer jobs use different locks and are therefore not mutually exclusive with each other.

## How the backup process works

`backup.sh` performs the following sequence:

1. Resolves its own directory and sources `backup.conf`.
2. Validates the required configuration values and the `SOURCE_DIRS` array.
3. Creates the configured backup and log directories if necessary.
4. Acquires `BACKUP_LOCK_FILE` with `flock`.
5. Writes a `running` status to `backup_status.json`.
6. Builds the daily filename:

   ```text
   YYYY-MM-DD - Backup of example-host.tar.gz
   ```

7. If that final archive already exists, validates it with `tar --list`. A valid archive is accepted as today's backup, and a stale matching `.partial` file is removed. An invalid existing archive is left in place and the job fails.
8. Checks every configured source. Missing sources are logged and skipped; the job fails if none exist.
9. Calculates the uncompressed source size and requires that amount plus 1 GiB to be available in `BACKUP_DIR`.
10. Discovers and stops the Docker containers that are running before archive creation.
11. Creates the archive as:

    ```text
    YYYY-MM-DD - Backup of example-host.tar.gz.partial
    ```

12. Publishes the archive by creating a hard link at the final filename. This fails instead of overwriting a file that appeared at the destination.
13. Validates the final archive using `tar --list`.
14. Removes the partial filename and records the completed archive as pending transfer.

The `--one-file-system` tar option prevents recursion from crossing filesystem boundaries beneath a source.

If Docker restoration is active, only container IDs captured before the stop operation are restart candidates. Cleanup attempts restoration after success, failure, or interruption.

## How the transfer process works

`transfer-backups.sh` performs the following sequence:

1. Resolves its own directory and sources `backup.conf`.
2. Validates all required transfer settings and confirms that `RETENTION_COUNT` is greater than zero.
3. Acquires `TRANSFER_LOCK_FILE` with `flock`.
4. Confirms that it is running as root and that `BACKUP_DIR` exists.
5. Finds all top-level `*.tar.gz` files in `BACKUP_DIR`, sorted by filename.
6. Exits successfully if no local archives are waiting.
7. Writes a `running` transfer status.
8. Reuses `MOUNT_POINT` if it is already mounted; otherwise mounts `REMOTE_SHARE` with the configured CIFS options.
9. Copies each archive to the remote share using a temporary `.nosync` suffix.
10. Calculates SHA-256 checksums for the local archive and temporary remote copy.
11. If the checksums match, renames the remote temporary file to the final archive filename.
12. Deletes the local archive only after the verified remote rename succeeds.
13. If at least one archive was transferred and its local copy removed, sorts remote `*.tar.gz` files by modification time and deletes files beyond `RETENTION_COUNT`.
14. Writes a successful transfer status and clears `pending_transfer`.
15. Unmounts the share on exit only when this invocation mounted it.

If a per-file copy, checksum, rename, or local deletion step fails, the script logs the problem and continues with the next selected archive. Remote retention runs only when at least one archive was fully transferred during that invocation.

## Status JSON format

The status file is:

```text
DATA_DIR/backup_status.json
```

With the example configuration, that is the `data` directory beside the scripts:

```text
/path/to/project/data/backup_status.json
```

Example:

```json
{
  "overall_status": "success",
  "last_backup_started": "2026-07-25 16:39",
  "last_backup_finished": "2026-07-25 16:39",
  "last_backup_result": "Backup transferred to the SMB destination",
  "last_backup_file": "2026-07-25 - Backup of example-host.tar.gz",
  "last_backup_size": "4.0 KB",
  "docker_downtime_seconds": 0,
  "pending_transfer": false,
  "updated": "2026-07-25 16:39"
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `overall_status` | string | Current overall state. Values written by the jobs include `running`, `pending`, `success`, and `failed`. |
| `last_backup_started` | string | Local backup start time in `YYYY-MM-DD HH:MM` format. |
| `last_backup_finished` | string | Time at which `backup.sh` last wrote its status. |
| `last_backup_result` | string | English human-readable result from the most recent backup or transfer status update. |
| `last_backup_file` | string | Daily backup filename. |
| `last_backup_size` | string | Human-readable archive size recorded by `backup.sh`. |
| `docker_downtime_seconds` | integer | Measured Docker downtime between the stop and restart phases. |
| `pending_transfer` | boolean | Whether the most recent status update considers a backup pending transfer. |
| `updated` | string | Time of the most recent status update in `YYYY-MM-DD HH:MM` format. |

`update-status.py` preserves fields not included in a particular update. Transfer updates therefore retain backup filename, size, timing, and Docker information written previously.

Status updates are protected by an exclusive lock on `backup_status.json.lock`. While holding that lock, the updater reads the current JSON, applies the requested field changes, and writes the complete document to a temporary file in `DATA_DIR`. The temporary file is flushed and synchronized to disk before `os.replace()` atomically replaces `backup_status.json`. This prevents concurrent backup and transfer jobs from overwriting each other's field updates or exposing a partially written JSON document.

Temporary status files use names matching `.backup_status.*.tmp`. They are removed after a successful replacement and cleaned up if writing or replacement fails.

## Homarr integration

The project provides Homarr-compatible data by maintaining `backup_status.json`. It does not install or configure Homarr, expose an HTTP endpoint, or copy the JSON into a web server directory.

Make the configured status file available to the existing Homarr integration using the same path or serving mechanism currently used by the host. Homarr consumers should continue reading the field names and value types documented above.

For the example configuration, the source file is:

```text
/path/to/project/data/backup_status.json
```

Changing `DATA_DIR` changes the physical location of this file. Update the external serving or bind-mount configuration accordingly; the filename and JSON schema remain unchanged.

## Restore procedure

Restoration is manual. The project creates and transfers archives but does not include an automated restore script.

### 1. Locate an archive

Use either a pending archive in the configured local backup directory or a completed archive on the configured SMB share.

### 2. Verify the archive

List and validate its contents before extracting:

```bash
tar --list --gzip --file="/path/to/YYYY-MM-DD - Backup of example-host.tar.gz"
```

### 3. Extract to a staging directory

Restoring to an empty staging directory is safer than writing directly over the live filesystem:

```bash
mkdir -p /tmp/backup-restore
tar \
    --extract \
    --gzip \
    --file="/path/to/YYYY-MM-DD - Backup of example-host.tar.gz" \
    --directory=/tmp/backup-restore
```

The staged tree contains relative paths such as:

```text
/tmp/backup-restore/path/to/source-directory/
```

### 4. Review and copy the required data

Compare the staged content with the live destination, then copy only the required files with appropriate ownership and permissions. The backup scripts do not record or automate this decision.

Direct extraction with `--directory=/` would write archive contents back to their original absolute locations because the archive contains paths relative to `/`. Do this only after reviewing the archive and understanding which live files will be replaced.

## Troubleshooting

### Configuration file cannot be read

Both shell scripts expect `backup.conf` in the same directory as the script. Confirm that the file exists and is readable:

```bash
ls -l /path/to/project/backup.conf
```

### A required configuration value is rejected

Check for missing or empty assignments in `backup.conf`. `SOURCE_DIRS` must contain at least one entry. `RETENTION_COUNT` must contain only a positive integer greater than zero.

Syntax-check the configuration and scripts without running a backup:

```bash
bash -n \
    /path/to/project/backup.conf \
    /path/to/project/backup.sh \
    /path/to/project/transfer-backups.sh
```

### No valid source directories were found

Confirm that at least one configured source exists on the backup host. Source paths are case-sensitive.

### Insufficient backup space

The backup job requires the summed uncompressed source size plus 1 GiB. Inspect space on the filesystem containing `BACKUP_DIR`:

```bash
df -h /path/to/local-backups
```

### Today's backup is reported as invalid

The final daily archive exists but failed `tar --list`. The script intentionally leaves it untouched and will not overwrite it. Inspect it manually:

```bash
tar --list --gzip --file="/path/to/local-backups/YYYY-MM-DD - Backup of example-host.tar.gz"
```

Move or remove a confirmed invalid archive manually before retrying. This is intentionally not automated.

### Backup publication fails

The final hard link can fail if the destination filename already exists, the filesystem does not support the operation, or permissions are insufficient. The partial and final names reside in the same configured backup directory.

### Transfer script must run as root

`transfer-backups.sh` explicitly rejects non-root execution. Run it from root's crontab or invoke it with appropriate privilege.

### SMB mount fails

Verify:

- `REMOTE_SHARE` resolves and is reachable.
- `MOUNT_POINT` is available.
- `CREDENTIALS_FILE` exists and has valid credentials.
- CIFS support and `mount.cifs` are installed.
- The configured SMB version is supported by both systems.

Review the daily transfer log under `LOG_DIR`.

### Checksum mismatch

The temporary remote `.nosync` file is removed and the local archive is retained. Check network stability, remote storage health, and available space, then rerun the transfer job.

### Local archive remains after transfer

The script removes a local archive only after copy, checksum verification, and final remote rename. If local deletion fails, the archive remains eligible for a later transfer attempt.

### Job reports that another instance is running

Each job uses a nonblocking `flock`. Check for a genuinely active process before investigating or removing a stale lock file:

```bash
ps aux | grep -E '[b]ackup\.sh|[t]ransfer-backups\.sh'
```

### Logs and status disagree

The backup and transfer jobs use separate job locks and may update the same status document in succession. JSON writes are serialized and atomic, but the most recent status update still determines shared fields such as `overall_status`, `last_backup_result`, `pending_transfer`, and `updated`. Consult both the backup log and the applicable daily transfer log to reconstruct the sequence of events.

## Future improvements

The following are potential improvements and are not implemented:

- Verify Docker availability explicitly before attempting container discovery.
- Track partial success when multiple archives are selected for transfer.
- Derive `pending_transfer` from the actual local archive queue.
- Narrow transfer and retention matching to this host's exact filename pattern.
- Add automated failure-path tests using stubbed system commands.
- Add an optional, separately reviewed restore utility.

## MIT License

This project is licensed under the [MIT License](LICENSE).
