# RN1 Technology Catalog Installer

`catalog.sh` installs and runs the **Raynet One Technology Catalog** with Docker Compose. A menu guides you through setup, updates, offline installations and catalog snapshots.

## Requirements

- Linux (Ubuntu, Debian or RHEL family) with Docker Engine and the Docker Compose plugin. The older `docker-compose` 1.27 or newer also works.
- bash 4.2 or newer and curl. Snapshot features also need `jq` or `python3`.
- For OpenSearch: `vm.max_map_count` of at least 262144. Menu option 16 checks this.

## Install with one command

On the server, in the folder where the Catalog should live:

```bash
mkdir -p ~/rn1-technology-catalog && cd ~/rn1-technology-catalog && wget -qO catalog.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/catalog.sh && bash catalog.sh
```

Then choose **7** (generate + validate + start). The settings are at the top of `catalog.sh`; option **1** opens them in `vi`.

- Run the script as a file, as shown above. Piping it into bash (`wget -O- ... | bash`) does not work, because the menu needs the keyboard and the script stores its settings in its own file.
- **Later updates:** use option **22** (or `./catalog.sh self-update`) instead of the `wget` line. It downloads the newest version and keeps all your settings. The previous version is kept as `catalog.sh.bak-<timestamp>`. Running the `wget` line again would overwrite your settings.

## A Catalog already runs on the server

If the Catalog was installed earlier in another folder, for example with an older script in `/root`, the menu shows where that installation is. Option **23** then takes it over:

- It finds the installation from the Docker Compose labels of its containers: project, folder, compose file and env file. If the containers carry no labels, it searches `/root`, `/home`, `/opt` and `/srv`, or uses the folder you name with `./catalog.sh adopt FOLDER`.
- It shows the version, the ports and which passwords were found; the passwords themselves are not displayed.
- It copies `.env` (with the passwords) and `docker-compose.yml` into this folder, and writes the values into the settings of `catalog.sh`.
- It sets `COMPOSE_PROJECT_NAME` to the existing project (for example `root`), so that the same containers and data volumes stay in use. A new folder name would otherwise start a second, empty stack.
- The running containers and the old folder are not changed. If the old compose file differs from what this installer generates (for example another MinIO image), the differences are listed. They take effect only with option 2 (generate) and 6 (start).

## Background jobs and the Current processes box

Long tasks run as background jobs: start, pull, restart, stop, snapshot download and import, self-sync, offline bundle, guided upgrade and patch updates. A job keeps running when you leave its view, close the menu or lose the SSH session.

- The menu shows a **Current processes** box in the bottom right corner with every running job, its progress, size, speed and remaining time. It refreshes every second.
- **J** lists all jobs (follow, cancel, log). **Tab** selects a job in the box.
- **Hold X for 2 seconds** to cancel the selected job. A bar fills while you hold, and letting go before it is full cancels nothing. Terminals report only one held key, so a combination such as Ctrl+U+O cannot be detected; a single held key works in every SSH client.
- In the live view of a job, **q** goes back to the menu and the job continues.
- A cancelled job cleans up first:
  - a snapshot download removes its partial file;
  - an offline bundle removes its half-written folder or archive;
  - an upgrade cancelled before `docker compose down` changes nothing, and after it goes back to the previous version.
- Holding X again while a job is still cleaning up stops it at once.
- Jobs of the same kind (for example two jobs that change the stack) do not run at the same time.
- From the command line: `./catalog.sh jobs [list | follow N | cancel N | log N]`.

## Menu

| Option | Purpose |
|---|---|
| 1 | Edit the settings at the top of the script; errors are caught before reload |
| 2 | Generate `.env` and `docker-compose.yml`; existing passwords are kept |
| 3, 4 | Review or edit the generated files |
| 5, 6 | Validate (`docker compose config`), start or apply changes (`up -d`) |
| 7 | Full setup: generate, validate and start |
| 8 | **Updates**: newest versions of all components on Docker Hub and GHCR, version picker, pinning of floating tags, **Download only** (offline bundle) |
| 9 to 16 | Status, logs, pull, restart, stop, credentials, URLs and Nginx Proxy Manager steps, prerequisites check |
| 17 | Download the daily or full catalog snapshot from rayventorycatalog.raynet.de |
| 18 | API keys for the online and the local catalog: show, change, test, delete |
| 19 | Import a downloaded snapshot into the local catalog |
| 20 | Let the local catalog synchronize itself daily (servers with internet access) |
| 21 | **Guided upgrade**: Catalog to the newest version, health check, patch updates of the other components |
| 22 | Update this installer from GitHub; your settings are kept |
| 23 | Take over an existing installation on this host (its `.env`, `docker-compose.yml`, passwords and data) |
| 99 | Remove containers **and all data volumes** (you must type `DELETE`) |
| J | Jobs: follow, cancel and read the log of running and finished tasks |

## Command line

```text
./catalog.sh help                    all commands
./catalog.sh setup                   generate + validate + up
./catalog.sh generate [--new-passwords]
./catalog.sh up | down | status | logs [service] | pull | restart
./catalog.sh updates                 available updates of all components
./catalog.sh upgrade                 guided upgrade (asks first, then runs as a job)
./catalog.sh jobs [list | follow N | cancel N | log N]
./catalog.sh self-update             newest installer from GitHub, settings kept
./catalog.sh adopt [FOLDER]          take over an existing installation
./catalog.sh download                offline bundle with all images (+ .tar.gz)
./catalog.sh versions | set-version VERSION|stable
./catalog.sh snapshot [daily|full]   needs a stored online API key
./catalog.sh import FILE             needs a stored local API key
```

## Offline installation

1. On a machine with internet access, open **8**, choose the versions, then **d** (Download only). The script creates `RN1-Technology-Catalog-<timestamp>/` with these files:
   - `images/*.tar`
   - `images.txt`
   - `SHA256SUMS`
   - `import-images.sh`
   - a copy of `catalog.sh`

   It can also create a `.tar.gz` and copy it with scp. Before any password is sent, it shows the SSH host key fingerprint for confirmation.
2. On the target: unpack the archive, run `./import-images.sh` (it detects docker or podman and verifies the checksums), then run `./catalog.sh` and choose **7**.

The bundle contains no `.env`. The target generates its own passwords.

## Catalog snapshots

- **17** asks for the API key of rayventorycatalog.raynet.de and tests it right away:
  - 401: invalid or expired key.
  - 403: the key has no Synchronizer role.
  - If the key works, you can save it.

  It then downloads the newest daily snapshot (or the full one) and verifies its sha256.
- A daily snapshot only applies on top of a catalog that has the previous day's data. A new installation needs the full snapshot.
- **19** uploads a snapshot to the local catalog (`/v1/synchronization/snapshot`) and follows the import until it finishes. It needs a local API key (role Synchronizer or Admin) or a local administrator login. The password is never stored.
- **20** writes the online URL and key into the local catalog's synchronization settings. From then on the catalog downloads and imports the right snapshots itself, every day at `AUTOSYNC_CRON`.

API keys and passwords are passed to curl through stdin. They never appear on a command line or in a URL.

## Guided upgrade

Option **21** compares the running Catalog with the newest version on Docker Hub (the `stable` tag). If the running version is older, the script:

1. takes a MongoDB backup (`mongodump`, stored in `backups/`; the password stays inside the container);
2. pulls the new images while the old version still runs;
3. runs `docker compose down` (data volumes are kept);
4. sets `CATALOG_VERSION` and regenerates the files (the passwords are kept);
5. runs `docker compose up -d`;
6. runs a health check: every container must be running (and healthy where a healthcheck exists), and Catalog Web must answer. The script waits at most `HEALTH_TIMEOUT` seconds (default 600).

Steps 1 to 6 run as one background job. If the health check fails, the script shows the logs and offers to go back to the previous version, together with the `mongorestore` command for the backup. If you were not watching, the menu shows a note and option 21 offers the way back. If you cancel the job, the script goes back by itself.

Afterwards it offers patch updates in the same release series, for example MongoDB 8.0.4 to 8.0.32, OpenSearch 2.19.5 to 2.19.6 and RabbitMQ 3.13.6 to 3.13.7. Major upgrades are never offered there; use option 8 for those.

## Files next to the script

These files are created at runtime and are listed in `.gitignore`. Do not commit them:

| File | Content |
|---|---|
| `.env` (+ `.env.bak-*`) | generated settings including the passwords (mode 600) |
| `docker-compose.yml` (+ backups) | generated stack definition |
| `.catalog_api_key`, `.catalog_local_api_key` | stored API keys (mode 600) |
| `snapshots/` | downloaded catalog snapshots |
| `backups/` | MongoDB backups taken before an upgrade (mode 600) |
| `RN1-Technology-Catalog-*` | offline bundles |
| `.jobs/` | state and logs of background jobs (mode 700; the newest 25 finished jobs are kept) |
| `.upgrade-failed` | marker of an upgrade that did not become healthy |

## Known issues

- MongoDB 8 does not start on Linux kernels 6.19 to 7.0.13, which includes Ubuntu 26.04 with kernel 7.0.0 ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). Set `MONGO_TAG="7.0"`. The script warns about this in options 6 and 16.

## Tests

```bash
bash tests/run_tests.sh "$PWD/catalog.sh"
bash tests/run_bundle_tests.sh "$PWD/catalog.sh"
bash tests/run_snapshot_tests.sh "$PWD/catalog.sh"
bash tests/run_upgrade_tests.sh "$PWD/catalog.sh"
bash tests/run_selfupdate_tests.sh "$PWD/catalog.sh"
bash tests/run_adopt_tests.sh "$PWD/catalog.sh"
bash tests/run_jobs_tests.sh "$PWD/catalog.sh"
```

Docker, ssh, scp and the Raynet APIs are replaced by fakes. The Updates tests query Docker Hub and GHCR, so they need internet access. The jobs tests close the menu's session the way a lost SSH connection does, cancel jobs, and hold X in the full screen menu; they need Linux (`setsid` and `script` from util-linux). GitHub Actions runs all seven suites on every push.
