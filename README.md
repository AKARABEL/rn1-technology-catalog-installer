# RN1 Technology Catalog Installer

`rn1-technology-catalog-installer.sh` installs and runs the **Raynet One Technology Catalog** with Podman (`podman compose`) or Docker (`docker compose`). A menu guides you through setup, updates, offline installations and catalog snapshots.

## Requirements

- **Linux (x86_64), run as root:** the Catalog runs with **rootful Podman** 4.9 or newer or with **rootful Docker**; the installer sets up the one you choose (see [Container engine](#container-engine)).
  - Podman: Ubuntu 24.04 or newer, Debian 13 or newer, RHEL 8 to 10, CentOS Stream, Rocky Linux, AlmaLinux, Oracle Linux, Fedora or openSUSE.
  - Docker: Ubuntu 22.04 or newer, Debian 12 or newer, RHEL 8 to 10, CentOS Stream, Rocky Linux, AlmaLinux, Oracle Linux, Fedora (from Docker's repository), openSUSE and SLES (their own packages).
- **macOS** with Homebrew, run as your normal user: Podman on Apple Silicon with macOS 26 (Tahoe) or newer, Docker Desktop, or Colima; see [macOS](#macos).
- Not supported: RHEL/CentOS 7 and ARM Linux. Debian 12 and Ubuntu 22.04 only with Docker (their Podman is too old), Intel Macs only with Docker Desktop or Colima. The Catalog images exist only for amd64.
- bash 4.2 or newer and curl. Snapshot features and the automatic setup of Nginx Proxy Manager (option 24) also need `jq` or `python3`.
- For OpenSearch: `vm.max_map_count` of at least 262144. Menu option 16 checks this.

## Install with one command

On the server, in the folder where the Catalog should live (the installer keeps `.env`, `docker-compose.yml`, `snapshots/` and `backups/` next to itself):

```bash
wget -nv -O rn1-technology-catalog-installer.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh && chmod +x rn1-technology-catalog-installer.sh && ./rn1-technology-catalog-installer.sh
```

RHEL, Rocky and AlmaLinux minimal installations have no `wget`; use curl there:

```bash
curl -fsSL -o rn1-technology-catalog-installer.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh && chmod +x rn1-technology-catalog-installer.sh && ./rn1-technology-catalog-installer.sh
```

The first start in a new folder goes straight into the new installation (see [New installation](#new-installation)): the container engine, a domain name, Nginx Proxy Manager and the versions, then the Catalog starts. **0** at any question opens the full menu. Option **7** generates, validates and starts in one go without these questions. The settings are at the top of `rn1-technology-catalog-installer.sh`; option **1** shows them on one screen to change and check them (**E** there opens them in `vi`).

- Run the script as a file, as shown above. Piping it into bash (`wget -O- ... | bash`) does not work, because the menu needs the keyboard and the script stores its settings in its own file.
- **Later updates:** use option **22** (or `./rn1-technology-catalog-installer.sh self-update`) instead of the `wget` line. It downloads the newest version, keeps all your settings and then opens the menu. It just ends with `--no-menu` (for scripts run in a terminal), and without a terminal: cron, pipes, redirected input or output, or a run in the background (`timeout`, `&`). The first update of an installer from before this feature still ends without the menu, because the old version decides that; start the script again. The previous version is kept as `rn1-technology-catalog-installer.sh.bak-<timestamp>`. Running the `wget` line again would overwrite your settings. If the line seems to do nothing, the download failed: `wget -nv` prints why (network, DNS, proxy).

## A Catalog already runs on the server

If the Catalog was installed earlier in another folder, for example with an older script in `/root`, the menu shows where that installation is. Option **23** then takes it over:

- It finds the installation from the Compose labels of its containers: project, folder, compose file and env file. If the containers carry no labels, it searches `/root`, `/home`, `/opt` and `/srv`, or uses the folder you name with `./rn1-technology-catalog-installer.sh adopt FOLDER`.
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
  - an upgrade cancelled before `compose down` changes nothing, and after it goes back to the previous version.
- Holding X again while a job is still cleaning up stops it at once.
- Jobs of the same kind (for example two jobs that change the stack) do not run at the same time.
- From the command line: `./rn1-technology-catalog-installer.sh jobs [list | follow N | cancel N | log N]`.

## Menu

Three cards at the top lead through the usual tasks step by step:

| Key | Task | Steps |
|---|---|---|
| **I** | **Install** | The new installation in seven steps: Engine, Domain, Proxy, Versions, Install, Data, Done (see [New installation](#new-installation)). In a folder that is already installed it offers repair (check, settings, files, start), the catalog data, update or remove instead; when another installation runs on the server, it offers to take it over. |
| **U** | **Update** | Updates this installer first. If there is a new version, the menu restarts and continues with the next step. Then the guided upgrade of the Catalog (backup, new version, health check) and the patch updates of the other components. |
| **R** | **Remove** | Shows what is installed. You choose what goes: data volumes, images, `.env` and `docker-compose.yml`, job logs and keys are selected; snapshots, backups, offline bundles and the installer itself only if you select them. Containers and networks always go. Type `DELETE` to confirm. R removes only what clearly belongs to this folder: nothing of another installation or app with the same project name, only the files the installer wrote in `snapshots/` and `backups/`, and never `.env` while data that needs its passwords stays. |

Below the cards, the options are grouped by what you want to do. The numbers are the same as in earlier versions; inside a group they go up. On a screen of 190 columns or more every option has a short description, and while you type a number the two lines above the prompt say what it will do (99 adds that it asks for `DELETE`).

| Group | Options |
|---|---|
| **SETUP** · install on this host | **7** install in one go: generate, validate and start · **16** check this server: the container engine and its compose, kernel, ports, `vm.max_map_count`, time zone · **23** take over an existing installation on this host (its `.env`, `docker-compose.yml`, passwords and data) |
| **CONFIGURE** · settings and files | **1** edit the settings: all settings of the script on one screen, grouped by name (see below) · **2** generate `.env` and `docker-compose.yml`; existing passwords are kept · **3**, **4** edit the generated files by hand (**2** writes them again) · **5** check the files (`podman compose config` or `docker compose config`). After a change of the settings, **2** writes the files and **6** applies them |
| **ACCESS** · addresses and logins | **14** user names and passwords, also of Nginx Proxy Manager · **15** URLs and the Nginx Proxy Manager login · **24** domain name and HTTPS: with Nginx Proxy Manager also the proxy host and a Let's Encrypt certificate, set up automatically (see [Domain and HTTPS](#domain-and-https)) |
| **START & STOP** · the containers | **6** start or apply changes (`up -d`) · **12** restart · **13** stop; the data is kept |
| **MONITOR** · is it running well? | **9** status and health · **10** logs · **J** background jobs: follow, cancel and read the log |
| **CATALOG DATA** · snapshots, sync | **17** download catalog snapshots from rayventorycatalog.raynet.de: the full snapshot and all changes up to today (default), the changes since a date, or the latest daily or full snapshot · **18** API keys for the online and the local catalog: show, change, test, delete · **19** import downloaded snapshots into the local catalog, file by file: full import, then delta · **20** let the local catalog synchronize itself daily (servers with internet access) |
| **UPDATE** · newer versions | **8** recommended versions of all components on Docker Hub and GHCR, version picker inside the series Raynet runs (see Versions), pinning of floating tags, **Download only** (offline bundle) · **11** pull the images named in `docker-compose.yml` · **21** upgrade the Catalog: backup, newest version, health check, patch updates of the other components · **22** update this installer from GitHub; your settings are kept |
| **REMOVE** · cannot be undone | **99** remove the containers **and all data volumes** (you must type `DELETE`); **R** removes step by step and lets you choose |

The **I** card says **Incomplete** when containers of this folder exist but `.env` or `docker-compose.yml` is missing. Its repair takes the passwords from the newest `.env` backup; without one it warns first, because new passwords would not open the existing MongoDB and RabbitMQ data.

## New installation

**I** in a folder without an installation asks a few questions, then installs. The menu starts with it by itself on the first start in a new folder: in a terminal, when the folder has no `.env`, no `docker-compose.yml` and no containers of this project in any engine, no other installation is found on the server and no job runs. It does not start by itself after a restart of the menu (settings saved, installer updated), without a terminal, or while the engine `CONTAINER_ENGINE` names does not answer (a stopped Docker daemon, Docker Desktop or Colima not started yet): such an engine could hide the installation of this folder, so the menu opens and offers to start it first.

When data volumes of this project exist but `.env` and its backups are gone, **I** says so before any question and stops: new passwords would not open that data. Put the old `.env` back, or remove the volumes with **R**.

1. **Engine:** the engines of this machine with their state (ready, installed, not installed) - on Linux Podman and Docker Engine, on macOS Podman, Docker Desktop and Colima. One that cannot be used here is shown with the reason (for example Podman too old for the distribution) and cannot be chosen. **Enter** takes the engine that holds the data of this folder (then no other one can be chosen), else `CONTAINER_ENGINE`, else one that is ready, else one that is installed, else one the setup installs: Podman (on macOS Colima before Docker Desktop, whose license comes first). The installer then sets it up when it is not ready: it shows the commands and asks first. If that fails or is declined: try again, choose another engine (**Enter** then takes another one), or stop. Rootful Podman needs root on Linux: as a normal user only another engine or stop are offered. When the engine then shows containers of this folder (an engine that did not answer before), **I** goes on with their repair instead.
2. **Domain:** the domain name of the Catalog, for example `catalog.example.com`. **Enter** without one: the Catalog runs on `http://<address of the server>:8080`. A URL is cut down to its host name; an invalid name or an IP address is asked again. **Enter** keeps a saved domain, **-** removes it. The step shows the DNS records of the name; when it is not in DNS (a typo?), **n** types another one.
3. **Proxy:** whether Nginx Proxy Manager runs in front of the Catalog. With a domain it gives HTTPS with a free Let's Encrypt certificate, set up automatically; the default is yes (a saved no stays the default while the domain stays the same). Without a domain it only forwards `http://<address>` (set up by hand), and the default is no. When another program listens on its ports (80, 443, 81), the step names them and the default is no. With a domain and Nginx Proxy Manager it asks for the e-mail address for Let's Encrypt, which is also its login; **Enter** without one: no certificate now, option **24** adds HTTPS later. A name Let's Encrypt gives no certificate for (`.lan`, `.local`, `.internal`, `.test` ...) gets `http://` through Nginx Proxy Manager, without the e-mail question; HTTPS then needs an own certificate in its admin page. The step shows the DNS records of the domain again, and asks for another port of Catalog Web when 8080 is in use.
4. **Versions:** first the addresses the answers give, then the versions screen (see [Versions](#versions)); **Enter** takes all recommendations.
5. **Install:** one summary with one value per row (engine, address, direct address, Nginx Proxy Manager, HTTPS, versions, folder), the time zone question (see [Time zone](#time-zone)), a check of the server (only its warnings when it passes; on problems it shows them and asks), then one question: "Write the files and start the Catalog?". The start with the health check runs as a background job. With a domain and Nginx Proxy Manager it then creates the proxy host and requests the certificate (see [Domain and HTTPS](#domain-and-https)) and says whether the Catalog answers on `https://` or, with the reason, on `http://` only until option **24** retries.
6. **Data:** the daily self-sync, the snapshots, or later.
7. **Done:** the URLs; then the full menu with every option (**H** explains them).

Every answer is saved in the settings at once, so **I** starts again with them as defaults. **0** or the end of input at any question stops the task and returns to the menu; nothing is half-written; the data step's **0** means later. Stopping at the very first question (the engine) writes `.setup-later`: the next start opens the menu directly, and **I** still starts the installation. A completed installation removes the file.

## Settings screen

Option **1** reads the settings section at the top of the script and groups the settings by their names:

- names ending in `_TAG`: the image tags;
- names that share their first word with another setting, for example `CATALOG_*`, `MINIO_*` and `RABBITMQ_*`;
- names that share their last word, for example `*_CRON`;
- all other settings under **General**.

A setting added to the script later appears in its group by itself.

- To change a value, type its number or its name. Values are checked as you type them: ports, `true`/`false`, time zones, cron times, sizes and URLs.
- `/text` shows only the settings whose name or value contains the text.
- **S** checks all changes together and writes them into the script, then the menu restarts with them. The previous script is kept as `<script>.bak-<time>`. **U** undoes the changes, and **0** asks before it drops them.
- When `TZ` changes, the screen offers to move the job times (`*_CRON`), so they keep running at the same moment.
- **E** opens the settings in the text editor (`$EDITOR`, default `vi`), as before.

## Command line

```text
./rn1-technology-catalog-installer.sh help                    all commands
./rn1-technology-catalog-installer.sh setup                   generate + validate + up
./rn1-technology-catalog-installer.sh generate [--new-passwords]
./rn1-technology-catalog-installer.sh up | down | status | logs [service] | pull | restart
./rn1-technology-catalog-installer.sh install-engine          set up the engine of CONTAINER_ENGINE (install-podman, install-docker)
./rn1-technology-catalog-installer.sh updates                 available updates of all components
./rn1-technology-catalog-installer.sh timezone                use the server's time zone for TZ (job times converted)
./rn1-technology-catalog-installer.sh domain [NAME|-]         domain name and HTTPS (Nginx Proxy Manager, Let's Encrypt); - removes it
./rn1-technology-catalog-installer.sh upgrade                 guided upgrade (asks first, then runs as a job)
./rn1-technology-catalog-installer.sh jobs [list | follow N | cancel N | log N]
./rn1-technology-catalog-installer.sh self-update [--no-menu] newest installer from GitHub, settings kept, then the menu
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
2. On the target: unpack the archive and run `sudo ./import-images.sh` as root. It takes the engine the bundled installer names in `CONTAINER_ENGINE` (empty in a new bundle, whatever the machine that made it uses: the engine installed on the target, Podman before Docker), verifies the checksums and loads the images: into the Podman of root (root is needed), or into Docker (root or the docker group). As root it also enables the engine's services and installs the Docker Compose the bundle carries (for Docker only when Docker has no Compose plugin). Then run the installer it names (`./rn1-technology-catalog-installer.sh`, or `./catalog.sh` in bundles from older versions) and choose **7**.

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

## Versions

The installer offers and recommends only versions of the release series Raynet runs with the Catalog:

| Component | Series | Recommended |
|---|---|---|
| Catalog | all versions | the newest version on Docker Hub (marked stable when the `stable` tag points to it) |
| MongoDB | 8.0 | the newest 8.0.x |
| OpenSearch and OpenSearch Dashboards | 2 | the newest 2.x, the same for both |
| RabbitMQ | 3 | the newest 3.x (`-management-alpine`) |
| Nginx Proxy Manager | 2 | the newest 2.x |
| MinIO | all releases | the newest release |

- The series are part of the installer (`SERIES_ALLOWED`, below the settings section), not a setting. Raynet raises a series when it moves its own servers; installations get it with the installer update (option 22 or U). A newer series is named but never offered, for example "RabbitMQ 4 exists - not released for the Catalog yet".
- Option 8 shows the recommended version of every component. Its version picker lists only versions of the series and refuses a typed version outside it. Option 21 and U offer the patch and minor steps inside the series, for example OpenSearch 2.17 to 2.19 or RabbitMQ 3.12 to 3.13 (enable all RabbitMQ feature flags before each step; the installer shows the command). They pull only the images of the components that change, so the moving tag of another component does not move with them.
- A version that runs outside its series, for example MongoDB 8.3 from the old default tag `8`, is named with a warning and never downgraded automatically. For MongoDB the version that runs counts, not the version the tag points to today.
- The default tags stay inside the series: `MONGO_TAG="8.0"`, `OPENSEARCH_TAG="2"`, `RABBITMQ_TAG="3.13-management-alpine"`, `NGINX_PROXY_MANAGER_TAG="2"`. The versions screen of the install wizard writes exact versions, so a later pull does not move them; when Docker Hub and GHCR cannot be read, it keeps the Catalog version and uses the moving tags of the series. In a folder that is installed already, the versions screen keeps the Catalog: U or option 21 upgrades it with backup, health check and rollback.

## Guided upgrade

Option **21** compares the running Catalog with the newest version on Docker Hub. If the running version is older, the script:

1. takes a MongoDB backup (`mongodump`, stored in `backups/`; the password stays inside the container);
2. pulls the new images while the old version still runs;
3. runs `podman compose down` or `docker compose down` (data volumes are kept);
4. sets `CATALOG_VERSION` and regenerates the files (the passwords are kept);
5. runs `podman compose up -d` or `docker compose up -d`;
6. runs a health check: every container must be running (and healthy where a healthcheck exists), and Catalog Web must answer. The script waits at most `HEALTH_TIMEOUT` seconds (default 600).

Steps 1 to 6 run as one background job. If the health check fails, the script shows the logs and offers to go back to the previous version, together with the `mongorestore` command for the backup. If you were not watching, the menu shows a note and option 21 offers the way back. If you cancel the job, the script goes back by itself.

Afterwards it offers the updates inside the series Raynet runs (see Versions), for example MongoDB 8.0.4 to 8.0.32, OpenSearch 2.17.1 to 2.19.6 and RabbitMQ 3.12.14 to 3.13.7. Nothing outside the series is offered there.

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
| `.domain-certificate` | the domain whose proxy host in Nginx Proxy Manager has a certificate (option 15 then shows `https://`) |
| `.npm-login` | the login of the Nginx Proxy Manager admin, or `-` when its admin was not created from `.env` (options 14 and 15 show it) |
| `.setup-later` | the first start was stopped at its first question: the menu opens without the new installation (**I** still starts it) |

## Time zone

The Catalog runs its daily synchronization (`AUTOSYNC_CRON`, default `30 7 * * *`) and the vulnerability caching (`VULNERABILITIES_CACHING_CRON`) in the local time of its containers, which is `TZ` (default `Europe/Berlin`), including summer and winter time.

- Options **2** and **7** compare `TZ` with the time zone of the server. If they differ, they show both times and offer to use the server's zone. With **yes**, `TZ` and the job times change together, so the jobs keep running at the same moment. Example on a server in `Asia/Singapore`: `30 7 * * *` (07:30 Europe/Berlin) becomes `30 13 * * *` during German summer time and `30 14 * * *` during winter time.
- When the two zones change their clocks on different dates, the converted time matches the old one only for part of the year; the question says so.
- For an existing installation the question defaults to **no**, so only an explicit yes changes it. With **no**, `TZ` stays and the question is not repeated for this server zone. `./rn1-technology-catalog-installer.sh timezone` asks again.
- A job time that one cron line cannot express in the other zone (for example a day of the month that moves to the next day) is left as it is and named in the question.
- Option **16** shows both zones.

## Domain and HTTPS

Without a domain (`CATALOG_DOMAIN=""`, the default) the Catalog answers on the address of the server, for example `http://192.0.2.10:8080`. The new installation (**I**) asks for it; option **24** (or `./rn1-technology-catalog-installer.sh domain NAME`) gives it a name later:

- It asks for the domain, for example `catalog.example.com`. A URL is cut down to its host name (`https://Catalog.Example.com:8443/x` becomes `catalog.example.com`). **Enter** keeps the current domain, **-** removes it. An IP address is refused; leave the domain empty to use the IP address.
- When Nginx Proxy Manager is off, it offers to turn it on; when another program already listens on its ports (80, 443, 81), it says so and the answer defaults to no. Then it asks for an e-mail address when there is none: Let's Encrypt needs a real one (not at `example.com`, `example.net` or `example.org`), and it also becomes the login of Nginx Proxy Manager (`NPM_ADMIN_EMAIL`, in lower case).
- It checks the DNS records of the domain and says whether they point to this server, to another address (fine behind NAT, for example the public address of a cloud server) or do not exist yet. It never blocks.
- It saves `CATALOG_DOMAIN`, `INSTALL_NGINX_PROXY_MANAGER`, `NPM_ADMIN_EMAIL` and `BASEURL` together (`https://DOMAIN` behind Nginx Proxy Manager, `http://DOMAIN` there for a name Let's Encrypt gives no certificate for, otherwise `http://DOMAIN:PORT`). When they changed, it writes `.env` and `docker-compose.yml` again (passwords kept) and applies them. When the files differ from the settings for another reason (for example a hand edit), the menu asks first, and `domain NAME` without a terminal leaves them as they are and only sets up Nginx Proxy Manager.

With Nginx Proxy Manager it then sets it up through its API on this server, no clicks needed:

1. It logs in with `NPM_ADMIN_EMAIL` and `NPM_ADMIN_PASSWORD` from `.env` (option **14** shows them). When `NPM_ADMIN_EMAIL` changed since the first start, it logs in with the old address and changes the login to the new one.
2. It requests a Let's Encrypt certificate for the domain. Let's Encrypt checks `http://DOMAIN/`, so the domain must point to this server and port 80 must be open from the internet. There is one attempt per run, because Let's Encrypt allows only 5 failed attempts per hour. The menu asks first; `domain NAME` without a terminal skips the request while the domain is not in DNS.
3. It creates the proxy host: the domain to `catalog-web` port 80 with Websockets Support, Block Common Exploits and HTTP/2, Force SSL with the certificate, no upload size limit and one-hour timeouts.
4. It checks the result on this server, through `127.0.0.1`.

If Let's Encrypt refuses the certificate, the proxy host is created for HTTP only, and the script prints the reason (DNS record, port 80). Run option **24** again later: it reuses the proxy host and only adds the certificate. A proxy host of the domain that forwards somewhere other than `catalog-web` port 80 (made by hand) is left as it is, and the setup stops. A certificate from an earlier run is used again instead of a new one. Nginx Proxy Manager renews the certificate itself, so port 80 must stay open.

- **The admin of Nginx Proxy Manager:** since version 2.13 it has no default user, and its setup page on port 81 belongs to whoever opens it first. The installer passes `INITIAL_ADMIN_EMAIL` and `INITIAL_ADMIN_PASSWORD`, so it creates its admin on the first start (as `admin@example.com` while `NPM_ADMIN_EMAIL` is empty; option 24 changes it to the real address). Nginx Proxy Manager writes that password into its log once. Options **14** and **15** show the login only while it is the one of `.env`: after new passwords (`generate --new-passwords`, or an installation from before this setting) its existing admin keeps its own login, like MongoDB and RabbitMQ keep theirs, until its volumes are removed (option **99**).
- The automatic setup needs Nginx Proxy Manager 2.13.0 or newer. If its admin was created on its own page, or its password was changed there, the script cannot log in; set up the proxy host by hand then (option **15** shows the steps).
- With Nginx Proxy Manager, catalog-web trusts the `X-Forwarded-Proto` header from the private networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16), so its links use `https`. Podman gives compose networks addresses in 10.89.x.x, outside the default of the Catalog.
- Without Nginx Proxy Manager the Catalog answers on `http://DOMAIN:8080`, or `http://DOMAIN` when `CATALOG_WEB_PORT` is 80.

## Installations from before the rename

Until 2026-10-05 the installer was called `catalog.sh`. Such installations keep working under their old name:

- Option **22** updates them. The repository still contains `catalog.sh` as an identical copy, because their update address points to it; after this first update they fetch `rn1-technology-catalog-installer.sh` themselves.
- To use the new name, rename the file while no job runs (check with **J**): `mv catalog.sh rn1-technology-catalog-installer.sh`. The installer finds its settings and files by its own location, so nothing else changes. If you keep the old name, use `./catalog.sh` wherever this README writes `./rn1-technology-catalog-installer.sh`.
- If you run the one-line install in the folder of an installation that `catalog.sh` (or the original generator script) set up, the new installer starts with its default settings. Whenever another installer in the folder has other settings and generating would change the existing `.env` or `docker-compose.yml`, the menu says so, option 2 asks first, and `generate`, `setup`, the guided upgrade and the patch updates refuse. Option **23** (or `./rn1-technology-catalog-installer.sh adopt ./catalog.sh`) shows the differences, copies the settings of the old file and renames it (not while jobs run). If the other file is no longer used, rename or remove it instead. Differences in `CHECK_FOR_UPDATES` and `INSTALLER_URL` do not count.

## Container engine

`CONTAINER_ENGINE` in the settings names the engine of this folder: `podman`, `docker` or, on macOS, `colima`. The generated `docker-compose.yml` and `.env` are the same for all of them.

- **Empty** (the default) means: the engine that alone holds the containers or data volumes of this project; otherwise Podman when it is installed, a Docker that answers when Podman is not, and Podman when neither is there. Installations from earlier versions keep their engine this way. The new installation (**I**) writes the engine you choose into `CONTAINER_ENGINE`; setting up an engine (the menu of an installation, `install-podman`, `install-docker`) writes it there when it is empty.
- **One engine per server:** when another engine holds containers or data volumes of this project and the engine of this folder holds none, start, setup, the guided upgrade, the patch updates and the setup of the engine refuse, because the new stack would start empty and the data would be left behind. Option **1** does not switch to an engine without data while another one has data either. On macOS, Docker Desktop and Colima count as two engines: each has its own Linux VM, and the installer talks to the one `CONTAINER_ENGINE` names (Docker context `desktop-linux` or `colima`, unless `DOCKER_HOST` or `DOCKER_CONTEXT` are set). Option **16** names it.
- **Data in two engines** (for example old Docker volumes next to a Podman installation): with `CONTAINER_ENGINE` set, the installer goes on with that engine and names the other one; to remove the other installation, set `CONTAINER_ENGINE` to it, use **R**, and set it back. With `CONTAINER_ENGINE` empty it asks you to choose first.
- `./rn1-technology-catalog-installer.sh install-engine` sets up the engine `CONTAINER_ENGINE` names, without asking.

## Podman

The Catalog runs in rootful Podman. `podman compose` runs the official **Docker Compose** as its engine.

- **Setup:** when Podman is not ready, the Engine step of **I** and the menu (of an installation, or of a folder whose `CONTAINER_ENGINE` is set) say why and offer to set it up (option **16** says why); `./rn1-technology-catalog-installer.sh install-podman` does it without asking. On Linux it:
  - installs Podman from the packages of the distribution (`apt-get install podman netavark aardvark-dns`, `dnf install ...`, `zypper install podman`);
  - enables the API socket that `podman compose` needs (`systemctl enable --now podman.socket`) and the restart of the containers after a reboot (`systemctl enable podman-restart.service`; every service has `restart: always`);
  - installs the newest Docker Compose release from github.com/docker/compose into `/usr/local/lib/docker/cli-plugins/docker-compose`, after checking its checksum. No version is fixed: every check takes the newest release, and a release that does not work with the installed Podman is not installed (the working one stays, and the installer says so).
- **Root:** run the installer as root (or with sudo). Rootless Podman cannot publish the ports 80 and 443 of Nginx Proxy Manager, give OpenSearch its memory lock, or keep the containers after the SSH session ends.
- **Firewall:** Podman forwards the published ports before ufw/firewalld see them. OpenSearch Dashboards has no login - restrict access in the network firewall.
- **SELinux** can stay enforcing: the stack keeps its data in named volumes and mounts no host folders.
- **vm.max_map_count** is 65530 by default; OpenSearch wants 262144 (option 16 shows the two commands).
- **Offline servers:** Podman itself comes from the distribution's package mirror. The offline bundle carries the newest Docker Compose of the day it was made; `import-images.sh` enables the API socket and the restart service and installs that Docker Compose, unless it does not work with the installed Podman (then the installed one stays).

## Docker

With `CONTAINER_ENGINE="docker"` the Catalog runs in rootful Docker with its Compose plugin (`docker compose`).

- **Setup:** `./rn1-technology-catalog-installer.sh install-docker` (or the menu and **I**, after asking). On Linux it:
  - installs the newest Docker Engine with its Compose plugin from Docker's repository (download.docker.com), as docs.docker.com describes it for the distribution: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. No version is fixed. RHEL takes Docker's `rhel` repository; its rebuilds (CentOS Stream, Rocky, AlmaLinux, Oracle Linux) take `rhel` for version 8 and `centos` for newer ones; Fedora takes `fedora`. openSUSE and SLES get the `docker` package of the distribution and the newest Docker Compose from GitHub as its plugin (`/usr/local/lib/docker/cli-plugins`);
  - first removes the packages that conflict with Docker's, as Docker's page for the distribution lists them (for example `docker.io`, `podman-docker`; only with the `rhel` repository also `podman` and `runc`) - never while Podman holds this installation's data;
  - enables the daemon (`systemctl enable --now docker`); Docker restarts the containers after a reboot by itself.
  - A Docker that is already installed only gets its daemon enabled.
- Not used: Podman's emulation `podman-docker` (it is refused), the Docker snap (it has no `docker.service` and cannot reach folders outside `/home`: `snap remove docker`, then `install-docker`) and rootless Docker (the ports 80 and 443 of Nginx Proxy Manager and the memory lock of OpenSearch need the rootful daemon). Run as root or as a member of the `docker` group. `DOCKER_HOST` and the Docker context are kept.
- **Firewall:** ports that Docker publishes are not filtered by ufw/firewalld. OpenSearch Dashboards has no login - restrict access in the network firewall or in the `DOCKER-USER` iptables chain.
- **Offline bundle:** made with Docker, the images are saved with `docker save` (for `linux/amd64` where Docker can choose).

## macOS

On a Mac the installer runs as your normal user. It needs [Homebrew](https://brew.sh) and Homebrew's bash: macOS ships bash 3.2, so install it first (`brew install bash coreutils gnu-sed grep findutils`). The installer starts itself in Homebrew's bash, uses the GNU tools and installs what is missing of them with Homebrew after asking. Catalog Web and the workers get `platform: linux/amd64` on Apple Silicon. Three engines are possible:

- **Podman** (`CONTAINER_ENGINE="podman"`, Apple Silicon and macOS 26 or newer): see below.
- **Docker Desktop** (`CONTAINER_ENGINE="docker"`): a Docker that answers (`docker info`) is used as it is. When Docker Desktop is missing, the installer shows its license first - it is free only for companies with fewer than 250 employees **and** less than 10 million USD annual revenue, for personal use, education and non-commercial open source; everyone else needs a paid Docker subscription - and asks (also with `install-docker`; without a terminal it does not install it), then installs it with `brew install --cask docker-desktop`, starts it (`open -a Docker`) and waits until it answers. At its first start, accept the agreement and turn on Settings > General > "Use Rosetta for x86_64/amd64 emulation"; the installer warns when the settings show Rosetta off.
- **Colima** (`CONTAINER_ENGINE="colima"`, free): `brew install colima docker`, the newest Docker Compose into `~/.docker/cli-plugins`, and a VM with Apple's virtualization and Rosetta: `colima start --vm-type=vz --vz-rosetta --cpu N --memory GB --disk 100` (up to 6 CPUs, 8 or 12 GB). It sets `vm.max_map_count` in the VM and keeps it with a provision script in `colima.yaml` of the default profile (`~/.colima/default/`, or where `COLIMA_HOME` or `XDG_CONFIG_HOME` put it, as Colima does), checks Rosetta in the VM, and starts Colima at login (`brew services start colima`). An existing Colima VM is used when it runs with Apple's virtualization.
- With Docker Desktop and Colima, Rosetta fails with Linux 6.13 and newer in the VM before macOS 26: the installer refuses that combination. Intel Macs run the images without Rosetta.

With Podman the installer uses a Podman machine (a Linux VM):

- It installs `podman` with Homebrew after asking.
- It creates a rootful Podman machine with Apple's hypervisor and Rosetta (the Catalog images are amd64), up to 6 CPUs and 8 or 12 GB of memory, and sets `vm.max_map_count` in it. An existing machine is used when it runs with Apple's hypervisor; the installer switches it to rootful and turns Rosetta on (the machine restarts).
- Rosetta works with the Linux kernel of current Podman machines only from macOS 26 (Tahoe); older macOS versions are refused.
- The Podman machine does not start by itself after a restart of the Mac; a LaunchAgent (`~/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist`) starts it when you log in, and the containers come back with it.
- The data lives inside the Podman machine: `podman machine rm` or `podman machine reset` deletes it.
- The MongoDB kernel check uses the kernel of the Podman machine (with Docker Desktop and Colima: the kernel of their VM).

## Known issues

- **MongoDB 8 on Linux 6.19 to 7.0.x, for example Ubuntu 26.04:** these kernels broke the rseq behaviour that the per-CPU caches of TCMalloc in MongoDB 8 rely on, and the released MongoDB refuses to start there ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). Ubuntu's `7.0.0-NN` always counts as 7.0.0, even with the kernel fix. On such a kernel the installer starts MongoDB with `GLIBC_TUNABLES=glibc.pthread.rseq=1` (in `.env` and `docker-compose.yml`): glibc then registers rseq, TCMalloc uses per-thread caches, and MongoDB starts, with some performance cost (startup warning 8718500). MongoDB's own tests use the same setting. The full fix is an Ubuntu kernel 7.0.0-31 or newer (option 16 says when the kernel is older) together with MongoDB 8.0.35, 8.3.14 or 9.0.4; until those images are out, the setting stays. Files generated by an older version get it with option 2.

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
bash tests/run_wizard_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_distro_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_docker_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_versions_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_domain_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
```

Podman, Docker, ssh, scp, the Raynet APIs, the API of Nginx Proxy Manager and DNS are replaced by fakes. The Updates tests query Docker Hub and GHCR, so they need internet access. The jobs tests close the menu's session the way a lost SSH connection does, cancel jobs, and hold X in the full screen menu; they need Linux (`setsid` and `script` from util-linux). The time zone tests need tzdata. The distribution tests check the Podman and Docker setup for the machine they run on and the macOS flows (fake Homebrew, Podman machine, Docker Desktop and Colima). The Docker tests run the installer against a fake Docker with Docker's own behaviour and check that one engine per server holds. The versions tests use fake registries with the tags of October 2026. GitHub Actions runs all thirteen suites on every push: on Ubuntu, and with `tests/run_in_container.sh` as a normal user in RHEL 8, 9 and 10 (UBI), CentOS 7 (bash 4.2), CentOS Stream 9, Rocky Linux 9, AlmaLinux 9, Debian 12 and openSUSE Leap 15.6. It also starts the whole Catalog on real Podman and on real Docker (Ubuntu 24.04 and 26.04: `install-podman` or `install-docker`, `setup`, `health`, `down`/`up`) and runs the macOS flows on an Apple Silicon Mac.
