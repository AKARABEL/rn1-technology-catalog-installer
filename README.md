# RN1 Technology Catalog Installer

`rn1-technology-catalog-installer.sh` installs and runs the **Raynet One Technology Catalog** with Docker Compose. A menu guides you through setup, updates, offline installations and catalog snapshots.

## Requirements

- Linux (Ubuntu, Debian or RHEL family) with Docker Engine and the Docker Compose plugin. The older `docker-compose` 1.27 or newer also works.
- bash 4.2 or newer and curl. Snapshot features also need `jq` or `python3`.
- For OpenSearch: `vm.max_map_count` of at least 262144. Menu option 16 checks this.

## Install with one command

On the server, in the folder where the Catalog should live (the installer keeps `.env`, `docker-compose.yml`, `snapshots/` and `backups/` next to itself):

```bash
wget -nv -O rn1-technology-catalog-installer.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh && chmod +x rn1-technology-catalog-installer.sh && ./rn1-technology-catalog-installer.sh
```

Then choose **7** (generate + validate + start). The settings are at the top of `rn1-technology-catalog-installer.sh`; option **1** opens them in `vi`.

- Run the script as a file, as shown above. Piping it into bash (`wget -O- ... | bash`) does not work, because the menu needs the keyboard and the script stores its settings in its own file.
- **Later updates:** use option **22** (or `./rn1-technology-catalog-installer.sh self-update`) instead of the `wget` line. It downloads the newest version and keeps all your settings. The previous version is kept as `rn1-technology-catalog-installer.sh.bak-<timestamp>`. Running the `wget` line again would overwrite your settings. If the line seems to do nothing, the download failed: `wget -nv` prints why (network, DNS, proxy).

## A Catalog already runs on the server

If the Catalog was installed earlier in another folder, for example with an older script in `/root`, the menu shows where that installation is. Option **23** then takes it over:

- It finds the installation from the Docker Compose labels of its containers: project, folder, compose file and env file. If the containers carry no labels, it searches `/root`, `/home`, `/opt` and `/srv`, or uses the folder you name with `./rn1-technology-catalog-installer.sh adopt FOLDER`.
- It shows the version, the ports and which passwords were found; the passwords themselves are not displayed.
- It copies `.env` (with the passwords) and `docker-compose.yml` into this folder, and writes the values into the settings of `rn1-technology-catalog-installer.sh`.
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
- From the command line: `./rn1-technology-catalog-installer.sh jobs [list | follow N | cancel N | log N]`.

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
| 17 | Download catalog snapshots from rayventorycatalog.raynet.de: the full snapshot and all changes up to today (default), the changes since a date, or the latest daily or full snapshot |
| 18 | API keys for the online and the local catalog: show, change, test, delete |
| 19 | Import downloaded snapshots into the local catalog; a downloaded chain is imported file by file, in order |
| 20 | Let the local catalog synchronize itself daily (servers with internet access) |
| 21 | **Guided upgrade**: Catalog to the newest version, health check, patch updates of the other components |
| 22 | Update this installer from GitHub; your settings are kept |
| 23 | Take over an existing installation on this host (its `.env`, `docker-compose.yml`, passwords and data) |
| 99 | Remove containers **and all data volumes** (you must type `DELETE`) |
| J | Jobs: follow, cancel and read the log of running and finished tasks |

## Command line

```text
./rn1-technology-catalog-installer.sh help                    all commands
./rn1-technology-catalog-installer.sh setup                   generate + validate + up
./rn1-technology-catalog-installer.sh generate [--new-passwords]
./rn1-technology-catalog-installer.sh up | down | status | logs [service] | pull | restart
./rn1-technology-catalog-installer.sh updates                 available updates of all components
./rn1-technology-catalog-installer.sh timezone                use the server's time zone for TZ (job times converted)
./rn1-technology-catalog-installer.sh upgrade                 guided upgrade (asks first, then runs as a job)
./rn1-technology-catalog-installer.sh jobs [list | follow N | cancel N | log N]
./rn1-technology-catalog-installer.sh self-update             newest installer from GitHub, settings kept
./rn1-technology-catalog-installer.sh adopt [FOLDER]          take over an existing installation
./rn1-technology-catalog-installer.sh download                offline bundle with all images (+ .tar.gz)
./rn1-technology-catalog-installer.sh versions | set-version VERSION|stable
./rn1-technology-catalog-installer.sh snapshot [daily|full|chain]   needs a stored online API key (default: daily)
./rn1-technology-catalog-installer.sh snapshot since YYYY-MM-DD     only the changes after that date
./rn1-technology-catalog-installer.sh import FILE             needs a stored local API key
./rn1-technology-catalog-installer.sh import-chain [CHAINFILE]   a downloaded chain, file by file (default: the newest)
```

## Offline installation

1. On a machine with internet access, open **8**, choose the versions, then **d** (Download only). The script creates `RN1-Technology-Catalog-<timestamp>/` with these files:
   - `images/*.tar`
   - `images.txt`
   - `SHA256SUMS`
   - `import-images.sh`
   - a copy of `rn1-technology-catalog-installer.sh`

   It can also create a `.tar.gz` and copy it with scp. Before any password is sent, it shows the SSH host key fingerprint for confirmation.
2. On the target: unpack the archive, run `./import-images.sh` (it detects docker or podman and verifies the checksums), then run the installer it names (`./rn1-technology-catalog-installer.sh`, or `./catalog.sh` in bundles from older versions) and choose **7**.

The bundle contains no `.env`. The target generates its own passwords.

## Catalog snapshots

The online catalog publishes its data through the v3 synchronization API (`/v3/synchronization/manifest`):

- one **full** snapshot: the complete catalog of one day;
- **daily** deltas for about the last 31 days, each building on the day before;
- **weekly** and **monthly** deltas that cover 7 or 30 days in one file.

**17** asks for the API key of rayventorycatalog.raynet.de and tests it right away (401: invalid or expired key; 403: the key has no Synchronizer role). If the key works, you can save it. Then you choose what to download:

| Choice | Downloads | For |
|---|---|---|
| 1 (default) | Full + all changes up to today: the full snapshot and the deltas that bring it to the newest date | a new installation |
| 2 | Changes since a date: only the deltas after the date of the newest data in the local catalog | a catalog that is behind |
| 3 | The latest daily delta | a catalog that has the previous day's data |
| 4 | The latest full snapshot only | |

- For 1 and 2 the script takes, step by step, the delta that builds on the current state and reaches furthest, so a weekly file replaces seven daily ones. Example from 2026-09-01: monthly up to 2026-10-01, weekly up to 2026-10-04, daily 2026-10-05.
- The free disk space is checked first. Every file is verified against its sha256 from the manifest; files that are already there are not downloaded again.
- With more than one file, `snapshots/chain-<first>-to-<last>.tsv` records the order in which they must be applied.
- If no delta builds on the given date (it is older than the deltas the online catalog keeps), the script says so. Use choice 1 then.

**19** lists the downloaded chains first, then the single files, and uploads to the local catalog (`/v1/synchronization/snapshot`). It follows each import until it finishes. A chain is imported file by file: the next upload starts only after the previous import finished, and the import stops at the first failure. It needs a local API key (role Synchronizer or Admin) or a local administrator login. The password is never stored. A login stays valid for about one hour, so use an API key for long chains.

Every file must fit the upload limit of the local catalog. The script checks this before the upload:

- Catalog 25.x accepts at most 10 GB per file, a fixed limit. If the full snapshot is larger, use **20** (servers with internet access) or upgrade to 26.x with **21** first.
- Catalog 26.x takes the limit from `SYNC_MAX_UPLOAD` in the settings (default `32GB`; the Catalog itself defaults to 8 GB). It is passed to catalog-web as `Synchronization__MaxUploadFileSize`.

**20** writes the online URL and key into the local catalog's synchronization settings. From then on the catalog downloads and imports the right snapshots itself, every day at `AUTOSYNC_CRON`. On a server with internet access this is the simplest way: no files to move and no upload limit.

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
| `snapshots/` | downloaded catalog snapshots and `chain-*.tsv` (the order of a downloaded chain) |
| `backups/` | MongoDB backups taken before an upgrade (mode 600) |
| `RN1-Technology-Catalog-*` | offline bundles |
| `.jobs/` | state and logs of background jobs (mode 700; the newest 25 finished jobs are kept) |
| `.upgrade-failed` | marker of an upgrade that did not become healthy |
| `.timezone-kept` | `TZ` was kept although the server uses another zone (not asked again) |

## Time zone

The Catalog runs its daily synchronization (`AUTOSYNC_CRON`, default `30 7 * * *`) and the vulnerability caching (`VULNERABILITIES_CACHING_CRON`) in the local time of its containers, which is `TZ` (default `Europe/Berlin`), including summer and winter time.

- Options **2** and **7** compare `TZ` with the time zone of the server. If they differ, they show both times and offer to use the server's zone. With **yes**, `TZ` and the job times change together, so the jobs keep running at the same moment. Example on a server in `Asia/Singapore`: `30 7 * * *` (07:30 Europe/Berlin) becomes `30 13 * * *` during German summer time and `30 14 * * *` during winter time.
- When the two zones change their clocks on different dates, the converted time matches the old one only for part of the year; the question says so.
- For an existing installation the question defaults to **no**, so only an explicit yes changes it. With **no**, `TZ` stays and the question is not repeated for this server zone. `./rn1-technology-catalog-installer.sh timezone` asks again.
- A job time that one cron line cannot express in the other zone (for example a day of the month that moves to the next day) is left as it is and named in the question.
- Option **16** shows both zones.

## Installations from before the rename

Until 2026-10-05 the installer was called `catalog.sh`. Such installations keep working under their old name:

- Option **22** updates them. The repository still contains `catalog.sh` as an identical copy, because their update address points to it; after this first update they fetch `rn1-technology-catalog-installer.sh` themselves.
- To use the new name, rename the file while no job runs (check with **J**): `mv catalog.sh rn1-technology-catalog-installer.sh`. The installer finds its settings and files by its own location, so nothing else changes. If you keep the old name, use `./catalog.sh` wherever this README writes `./rn1-technology-catalog-installer.sh`.
- If you run the one-line install in the folder of an installation that `catalog.sh` (or the original generator script) set up, the new installer starts with its default settings. Whenever another installer in the folder has other settings and generating would change the existing `.env` or `docker-compose.yml`, the menu says so, option 2 asks first, and `generate`, `setup`, the guided upgrade and the patch updates refuse. Option **23** (or `./rn1-technology-catalog-installer.sh adopt ./catalog.sh`) shows the differences, copies the settings of the old file and renames it (not while jobs run). If the other file is no longer used, rename or remove it instead. Differences in `CHECK_FOR_UPDATES` and `INSTALLER_URL` do not count.

## Known issues

- MongoDB 8 does not start on Linux kernels 6.19 to 7.0.13, which includes Ubuntu 26.04 with kernel 7.0.0 ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). Set `MONGO_TAG="7.0"`. The script warns about this in options 6 and 16.

## Tests

```bash
bash tests/run_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_bundle_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_snapshot_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_upgrade_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_selfupdate_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_adopt_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_jobs_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_timezone_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
```

Docker, ssh, scp and the Raynet APIs are replaced by fakes. The Updates tests query Docker Hub and GHCR, so they need internet access. The jobs tests close the menu's session the way a lost SSH connection does, cancel jobs, and hold X in the full screen menu; they need Linux (`setsid` and `script` from util-linux). The time zone tests need tzdata. GitHub Actions runs all eight suites on every push.
