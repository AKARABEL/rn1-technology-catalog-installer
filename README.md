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
- **Memory:** at least 24 GB for the containers is recommended - a full snapshot import loads MongoDB, the Catalog and OpenSearch at the same time. On macOS that is the memory of the Linux VM. See [Memory](#memory).

## Install with one command

On the server, in the folder where the Catalog should live (the installer keeps `.env`, `docker-compose.yml`, `snapshots/` and `backups/` next to itself):

```bash
wget -nv -O rn1-technology-catalog-installer.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh && chmod +x rn1-technology-catalog-installer.sh && ./rn1-technology-catalog-installer.sh
```

RHEL, Rocky and AlmaLinux minimal installations have no `wget`; use curl there:

```bash
curl -fsSL -o rn1-technology-catalog-installer.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh && chmod +x rn1-technology-catalog-installer.sh && ./rn1-technology-catalog-installer.sh
```

Behind a proxy, give it for this first download (wget reads only the lower-case name); the installer then asks for it in its first step (see [Internet access and proxies](#internet-access-and-proxies)):

```bash
https_proxy=http://proxy.example.com:8080 wget -nv -O rn1-technology-catalog-installer.sh https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh && chmod +x rn1-technology-catalog-installer.sh && ./rn1-technology-catalog-installer.sh
```

The first start in a new folder goes straight into the new installation (see [New installation](#new-installation)): the internet access, the container engine, a domain name, Nginx Proxy Manager and the versions, then the Catalog starts. **0** at any question opens the full menu. Option **7** generates, validates and starts in one go without these questions. The settings are at the top of `rn1-technology-catalog-installer.sh`; option **1** shows them on one screen to change and check them (**E** there opens them in `vi`).

- Run the script as a file, as shown above. Piping it into bash (`wget -O- ... | bash`) does not work, because the menu needs the keyboard and the script stores its settings in its own file.
- **The line above is for the first start only.** Later start the installer with `./rn1-technology-catalog-installer.sh` (or `bash rn1-technology-catalog-installer.sh`; an installation from before the rename: `bash catalog.sh`).
- **Later updates:** use option **22** (or `./rn1-technology-catalog-installer.sh self-update`) instead of the `wget` line. It downloads the newest version, keeps all your settings and then opens the menu. It just ends with `--no-menu` (for scripts run in a terminal), and without a terminal: cron, pipes, redirected input or output, or a run in the background (`timeout`, `&`). The first update of an installer from before this feature still ends without the menu, because the old version decides that; start the script again. The previous version is kept as `rn1-technology-catalog-installer.sh.bak-<timestamp>`. It does not run while a background job runs (a job may still change a setting). If the line seems to do nothing, the download failed: `wget -nv` prints why (network, DNS, proxy).
- Running the `wget` line again in the folder of an installation replaces the installer with one that has the default settings, for example an older Catalog version than the one installed. The installer notices it at its next start: see [Settings older than the installation](#settings-older-than-the-installation).

## Settings older than the installation

The installed Catalog is the version of the catalog-web container, running or stopped (or, while there is none, the one `.env` names, as long as the data volumes of the stack exist). The header, the cards and the guided update show that version; `CATALOG_VERSION` in the settings is what the next generate writes. Without containers and data volumes nothing is installed, even when `.env` and `docker-compose.yml` are still there (see [Menu](#menu)).

- When the settings name an older Catalog than the installed one, MongoDB below the installed one, or `.env` names an older Catalog than the catalog-web container has (for example after a new download of the installer and option 2 of an older version), the menu says so, for example *The settings say Catalog 25.4.4191.133, 26.3.4789.148 is installed - option 23 takes the installation's values over*. At its start the installer offers that take-over before anything else. MongoDB, OpenSearch, RabbitMQ and Nginx Proxy Manager count by their series: a patch may go back within it.
- When the versions fit but other values differ from `.env` (a new download with the installed Catalog version, or settings changed after option 2), the menu names them instead of advising option 2, for example *The settings differ from the installation in CATALOG_WEB_PORT, TZ - option 23 takes the installation's values over, option 2 writes the settings*. Option 2 writes the settings as before; nothing is offered at the start, because settings changed on purpose look the same. I (repair) offers the take-over before it writes the files.
- The take-over (option **23**, or `./rn1-technology-catalog-installer.sh adopt .`) lists every setting with its value and the installation's value. The versions come from the containers, the other values (time zone, domain, ports, job times, ...) from `.env`, or, when `.env` names another Catalog than the installed one, from its newest backup that names the installed one. It writes them all at once into the settings and keeps the previous installer as `rn1-technology-catalog-installer.sh.bak-<timestamp>`; `.env`, `docker-compose.yml` and the containers stay as they are. If such a backup was used, it then offers to put that backup and the `docker-compose.yml` backup of the same second back (the current files are kept as backups, the passwords are those of the running stack).
- Until then nothing lowers the installation: option 2, `generate`, `setup`, I (repair), the apply of option 8, the patch updates and the upgrade refuse to write a Catalog older than the installed one or a MongoDB series below the one that runs; option 6, `up` and the jobs refuse to start such files. While the files name older versions, option 13, `down` and R (when it keeps the data) do not remove the containers either: their images are what shows the installed versions, and a later start would start the files. All of them say what would happen (*Catalog 25.4.4191.133 would replace the installed 26.3.4789.148; the database was migrated by 26.3*), offer the take-over in the menu and end with an error on the command line. Only going back after a failed upgrade (option 21) or a cancelled patch update returns to the version it came from.

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
- In the live view of a job, **q** goes back to the menu and the job continues. The view shows the last lines of the job's log, wrapped at its width, as many as the terminal has room for. When the job has ended, it shows every step of an import or a synchronization from the first on. A job that stopped following a task that goes on elsewhere (an import in the Catalog) ends without a result, not as failed.
- A cancelled job cleans up first:
  - a snapshot download removes its partial file;
  - an offline bundle removes its half-written folder or archive;
  - an upgrade cancelled before `compose down` changes nothing, and after it goes back to the previous version.
- Holding X again while a job is still cleaning up stops it at once.
- Jobs of the same kind (for example two jobs that change the stack) do not run at the same time.
- From the command line: `./rn1-technology-catalog-installer.sh jobs [list | follow N | cancel N | log N]`.

## Menu

The product logo sits centred above the menu in a terminal of at least 80 columns with rows enough for the whole menu below it (in plain ASCII when the locale is not UTF-8).

Three cards at the top lead through the usual tasks step by step:

| Key | Task | Steps |
|---|---|---|
| **I** | **Install** | The new installation in nine steps: Internet, Engine, Domain, Proxy, Versions, Install, License, Data, Done (see [New installation](#new-installation)). In a folder that is already installed it offers repair (check, settings, files, start), the license and the catalog data, update or remove instead; when another installation runs on the server, it offers to take it over. Where only `.env` and `docker-compose.yml` are left (option 99, or R that kept them), it is the new installation on these files: the recommended versions, the passwords of `.env`. |
| **U** | **Update** | Updates this installer first. If there is a new version, the menu restarts and continues with the next step. Then the guided upgrade of the Catalog (backup, new version, health check) and the patch updates of the other components. |
| **R** | **Remove** | Shows what is installed. You choose what goes: data volumes, images, `.env` and `docker-compose.yml`, job logs and keys are selected; snapshots, backups, offline bundles and the installer itself only if you select them. Containers and networks always go. Type `DELETE` to confirm. R removes only what clearly belongs to this folder: nothing of another installation or app with the same project name, only the files the installer wrote in `snapshots/` and `backups/`, and never `.env` while data that needs its passwords stays. |

The header and the cards show what is installed in this folder; status (9) and the check of the server (16) say the same:

- **running** or **stopped** - containers of the stack are there: *Catalog 26.3.4789.148 ✔ up to date* (or ▲ with the newer version), the I card with the running services, or *stopped - 6 starts it*;
- **data kept, no containers** - after option 13: the same header, the I card *Data kept, no containers - 6 starts it again*;
- **only the files** - after option 99, or R that kept `.env` and `docker-compose.yml`: no Catalog is installed. The header says *Catalog not installed · 26.3.4789.148 would be installed (the newest)* - the version `.env` names, which option 6 starts, with a newer one on Docker Hub named -, never *up to date*. When the settings name another version than `.env`, the header names both: *26.3.4789.148 would be installed (the files) · option 2 writes 25.4.4191.133*. The I card says *Not installed: no containers, no data - 6 starts a new, empty Catalog*, U has nothing to update, I makes a new installation on these files, and option 8 shows the Catalog as *not installed*. 99 and R with the data also remove the mark of a failed upgrade: there is nothing left to go back to;
- **nothing** - a new folder: the same header with the version of the settings, the I card *New installation, step by step*.

When the engine does not answer, or the files are incomplete, the installed version cannot be read: the header names the version of the settings, *Catalog 26.3.4789.148 (the settings)*, and neither it nor the U card says *up to date*. In the plain menu, the state of the Catalog moves to a line of its own (*Catalog: ...*) when it does not fit beside the title.

Below the cards, the options are grouped by what you want to do. The numbers are the same as in earlier versions; inside a group they go up. On a screen of 190 columns or more every option has a short description, and while you type a number the two lines above the prompt say what it will do (99 adds that it asks for `DELETE`).

| Group | Options |
|---|---|
| **SETUP** · install on this host | **7** install in one go: generate, validate and start · **16** check this server: the container engine and its compose, kernel, ports, `vm.max_map_count`, time zone, internet access · **23** take over an existing installation on this host (its `.env`, `docker-compose.yml`, passwords and data), or the values of the installation in this folder after a new download of the installer · **26** internet access: the sites the installation needs, a proxy, the company certificate (see [Internet access and proxies](#internet-access-and-proxies)) |
| **CONFIGURE** · settings and files | **1** edit the settings: all settings of the script on one screen, grouped by name (see below) · **2** generate `.env` and `docker-compose.yml`; existing passwords are kept · **3**, **4** edit the generated files by hand (**2** writes them again) · **5** check the files (`podman compose config` or `docker compose config`). After a change of the settings, **2** writes the files and **6** applies them |
| **ACCESS** · addresses and logins | **14** user names and passwords, also of Nginx Proxy Manager · **15** URLs and the Nginx Proxy Manager login · **24** domain name and HTTPS: with Nginx Proxy Manager also the proxy host and a Let's Encrypt certificate, set up automatically (see [Domain and HTTPS](#domain-and-https)) · **25** the license: shows it and activates the Catalog by order number, license file or e-mail (see [License](#license)) |
| **START & STOP** · the containers | **6** start or apply changes (`up -d`) · **12** restart · **13** stop; the data is kept |
| **MONITOR** · is it running well? | **9** status and health · **10** logs · **J** background jobs: follow, cancel and read the log |
| **CATALOG DATA** · snapshots, sync | **17** download catalog snapshots from rayventorycatalog.raynet.de: the full snapshot and all changes up to today (default), the changes since a date, or the latest daily or full snapshot · **18** API keys for the online and the local catalog: show, change, test, delete · **19** import downloaded snapshots into the local catalog, file by file: full import, then delta · **20** let the local catalog synchronize itself daily (servers with internet access) |
| **UPDATE** · newer versions | **8** recommended versions of all components on Docker Hub and GHCR, version picker inside the series Raynet runs (see Versions), pinning of floating tags, **Download only** (offline bundle) · **11** pull the images named in `docker-compose.yml` · **21** upgrade the Catalog: backup, newest version, health check, patch updates of the other components · **22** update this installer from GitHub; your settings are kept |
| **REMOVE** · cannot be undone | **99** remove the containers **and all data volumes** (you must type `DELETE`); **R** removes step by step and lets you choose |

The **I** card says **Incomplete** when containers of this folder exist but `.env` or `docker-compose.yml` is missing. Its repair takes the passwords from the newest `.env` backup; without one it warns first, because new passwords would not open the existing MongoDB and RabbitMQ data.

## New installation

**I** in a folder without an installation asks a few questions, then installs. The menu starts with it by itself on the first start in a new folder: in a terminal, when the folder has no `.env`, no `docker-compose.yml` and no containers of this project in any engine, no other installation is found on the server and no job runs. It does not start by itself after a restart of the menu (settings saved, installer updated), without a terminal, or while the engine `CONTAINER_ENGINE` names does not answer (a stopped Docker daemon, Docker Desktop or Colima not started yet): such an engine could hide the installation of this folder, so the menu opens and offers to start it first.

When data volumes of this project exist but `.env` and its backups are gone, **I** says so before any question and stops: new passwords would not open that data. Put the old `.env` back, or remove the volumes with **R**.

1. **Internet:** the check of every site the installation needs (see [Internet access and proxies](#internet-access-and-proxies)). When they all answer, it goes on without a question. When a required one cannot be reached, it asks how this server reaches the internet: through a proxy (its address, a PAC file, or WPAD), directly (it prints the sites for the network team and goes on), or not at all (the offline bundle).
2. **Engine:** the engines of this machine with their state (ready, installed, not installed) - on Linux Podman and Docker Engine, on macOS Podman, Docker Desktop and Colima. One that cannot be used here is shown with the reason (for example Podman too old for the distribution) and cannot be chosen. **Enter** takes the engine that holds the data of this folder (then no other one can be chosen), else `CONTAINER_ENGINE`, else one that is ready, else one that is installed, else one the setup installs: Podman (on macOS Colima before Docker Desktop, whose license comes first). The installer then sets it up when it is not ready: it shows the commands and asks first. If that fails or is declined: try again, choose another engine (**Enter** then takes another one), or stop. Rootful Podman needs root on Linux: as a normal user only another engine or stop are offered. When the engine then shows containers of this folder (an engine that did not answer before), **I** goes on with their repair instead.
3. **Domain:** the domain name of the Catalog, for example `catalog.example.com`. **Enter** without one: the Catalog runs on `http://<address of the server>:8080`. A URL is cut down to its host name; an invalid name or an IP address is asked again. **Enter** keeps a saved domain, **-** removes it. The step shows the DNS records of the name; when it is not in DNS (a typo?), **n** types another one.
4. **Proxy:** whether Nginx Proxy Manager runs in front of the Catalog. With a domain it gives HTTPS with a free Let's Encrypt certificate, set up automatically; the default is yes (a saved no stays the default while the domain stays the same). Without a domain it only forwards `http://<address>` (set up by hand), and the default is no. When another program listens on its ports (80, 443, 81), the step names them and the default is no. With a domain and Nginx Proxy Manager it asks for the e-mail address for Let's Encrypt, which is also its login; **Enter** without one: no certificate now, option **24** adds HTTPS later. A name Let's Encrypt gives no certificate for (`.lan`, `.local`, `.internal`, `.test` ...) gets `http://` through Nginx Proxy Manager, without the e-mail question; HTTPS then needs an own certificate in its admin page. The step shows the DNS records of the domain again, and asks for another port of Catalog Web when 8080 is in use.
5. **Versions:** first the addresses the answers give, then the versions screen (see [Versions](#versions)); **Enter** takes all recommendations.
6. **Install:** one summary with one value per row (engine, address, direct address, Nginx Proxy Manager, HTTPS, versions, folder), the time zone question (see [Time zone](#time-zone)), a check of the server (only its warnings when it passes; on problems it shows them and asks), below 24 GB of memory the offer for more (macOS) and "Continue with 14 GB anyway?" (see [Memory](#memory)), then one question: "Write the files and start the Catalog?". The start with the health check runs as a background job. With a domain and Nginx Proxy Manager it then creates the proxy host and requests the certificate (see [Domain and HTTPS](#domain-and-https)) and says whether the Catalog answers on `https://` or, with the reason, on `http://` only until option **24** retries.
7. **License:** without a license the Catalog takes no data. When it has none yet, the step offers the three ways of activation (see [License](#license)): by order number (Catalog Web fetches the license from Raynet; needs internet), by license file or by the license text of Raynet's e-mail; `root` logs in for it. **0** (or **Enter**) means later.
8. **Data:** the daily self-sync, the snapshots, or later; it names the valid license first. Without a license it is skipped: the summary says that option **25** activates the Catalog, then options **20** or **17** and **19** load the data.
9. **Done:** the URLs and the login of Catalog Web (`root`, with the default password `root` unless it was changed - change it in the web interface); then the full menu with every option (**H** explains them).

Every answer is saved in the settings at once, so **I** starts again with them as defaults. **0** or the end of input at any question stops the task and returns to the menu; nothing is half-written; the **0** of the license and the data step means later. Stopping at the very first question (how this server reaches the internet, or the engine when every site answers) writes `.setup-later`: the next start opens the menu directly, and **I** still starts the installation. A completed installation removes the file.

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
./rn1-technology-catalog-installer.sh network-check           the sites the installation needs; exit code 0 when every required one answers
./rn1-technology-catalog-installer.sh network-hosts           the sites (host:port) for a firewall request
./rn1-technology-catalog-installer.sh updates                 available updates of all components
./rn1-technology-catalog-installer.sh timezone                use the server's time zone for TZ (job times converted)
./rn1-technology-catalog-installer.sh domain [NAME|-]         domain name and HTTPS (Nginx Proxy Manager, Let's Encrypt); - removes it
./rn1-technology-catalog-installer.sh license [status | file PATH | order | text]   the license: status (no login) or activation
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

## Internet access and proxies

The installation downloads from a few sites: the images (Docker Hub and its layer host, `ghcr.io` and its layer host), the packages of the engine (the repositories of the distribution, `download.docker.com` for Docker Engine), Docker Compose (`github.com`), and optionally the version list, updates of the installer, the catalog data and the license from Raynet, and Let's Encrypt with a domain. The list is built from the settings, the engine, the system and the domain; `./rn1-technology-catalog-installer.sh network-hosts` prints it as `host:port` lines for a firewall request.

**The check** tests every site at the same time, with one request each (a few for the layer hosts, which it learns from the redirect of a download), and shows one line per site:

| Word | Meaning |
|---|---|
| `OK` | the site answered as itself (not only some answer: block pages and portals also answer) |
| `NO DNS` | the name does not resolve - this server probably reaches out only through a proxy (then no other site is tried) |
| `PROXY DNS` | the name of the proxy does not resolve |
| `BLOCKED` | no answer in time - a firewall drops the connection |
| `REFUSED` | the connection was refused (firewall, wrong proxy port) |
| `PROXY LOGIN` | the proxy asks for a login (Basic, NTLM, Negotiate or Digest) |
| `DENIED` | the proxy or the firewall refuses this site |
| `TLS INSPECTED` | the network inspects HTTPS: the certificate comes from the named company CA (each certificate is checked against the certificates of the server, as the engine and the downloads check it) |
| `CLOCK` | the certificate is not valid yet or any more: check the clock of the server |
| `TLS RESET` | the encrypted connection was cut, often by a filter on the site name |
| `WRONG ANSWER` | an answer came, but not from the site (a block or login page) |
| `LIMIT` | the Docker Hub pull limit is reached (the check itself spends no pull and shows the pulls left) |
| `-` | not needed here, with the reason (no domain, the engine is installed ...) |

It runs:

- as the first step of a new installation (before the engine is installed);
- before the setup of an engine, for the sites of that engine (only the ones that fail are shown);
- at every start of the menu, in the background: the menu does not wait for it, and the header shows `Internet ✔`, or `Internet: 2 required sites blocked - 26 shows them`, when it is done. The result is kept in `.jobs/internet-check` and used for 15 minutes (or until the internet settings change); a menu left open checks again after that. The check stops when the menu quits. After choice 5 below (offline) the menu start checks nothing and shows no internet line, until option 26 finds the sites or a proxy is saved;
- in option **16** (one line) and option **26**;
- as `./rn1-technology-catalog-installer.sh network-check`: no questions, exit code 0 when every required site answers.

`RN1_NET_CHECK=off` turns the automatic checks off (menu start, new installation, option 16, engine setup).

**A proxy only the shell has** (`https_proxy` in `/etc/environment` or a profile, with an empty `INTERNET_PROXY`) covers only the installer's own downloads: Docker, Podman and the Catalog's containers do not read the shell's environment. When the check passes through it, the new installation and option 26 say so and offer to save it in the settings (Enter: yes); `network-check` and option 16 name it.

**Option 26** shows the internet settings, runs the check and offers to set or change the proxy, to remove it, the company certificate, the list for the network team, to read the PAC file again, and to apply the settings to the engine and the Catalog again (after they were changed in option 1). When a required site cannot be reached and nothing is saved yet, it asks at once how this server reaches the internet; with a saved proxy or certificate the choices above stay (choice 1 asks):

1. **Through a proxy server:** its address, for example `proxy.example.com:8080`, `http://192.0.2.10:3128`, `[2001:db8::1]:3128`, an `https://` proxy, or `socks5h://` (accepted with a warning: Let's Encrypt in Nginx Proxy Manager and wget cannot use SOCKS). A missing port is asked for, never guessed. When the proxy asks for a login (Basic), the user name (`DOMAIN\user` is fine) and the password (hidden) are asked and tried at once; three tries. A login typed into the address is moved out of it. A proxy that takes only Windows domain logins (NTLM or Kerberos) or Digest cannot be used by Docker, Podman and apt: the installer explains the two ways out - an exemption from the network team, or a local relay that logs in for the server (`cntlm` or `px`, set up by you) whose address, for example `127.0.0.1:3128`, is then entered as a normal proxy.
2. **Through a PAC file** (an address or a file): it is read once and turned into one fixed proxy - curl, Docker, Podman, dnf and wget cannot read PAC files. The proxies it names (as `pactester` or libproxy's `proxy` tool evaluate it, when one of them is installed) and DIRECT are tried on the required sites; the first that reaches them all is taken, and the sites only DIRECT reaches become internal names. When no single proxy reaches them all, it says so; a proxy that reaches no site itself is never taken, and when DIRECT reaches every required site no proxy is set. Its failover between proxies is lost: a load-balanced proxy name is better.
3. **WPAD:** only when chosen. It looks for `http://wpad.<domain>/wpad.dat` for the domains of the server, never below two labels and never at a public suffix such as `co.uk` (anyone could register `wpad.co.uk`), shows what it finds and uses it only after a yes.
4. **Directly:** it prints the sites for the network team and goes on; a saved proxy is removed after a yes.
5. **Not at all:** the offline bundle (option **8** on a computer with internet). The answer is remembered (`.jobs/internet-offline`): the menu start no longer checks the internet. The bundle's installer has no internet settings: the proxy, internal names, PAC file and certificate of the download computer belong to its network.

Then every site is checked through the proxy, the internal names are asked (the domain of the server is the default; this server, its addresses and the services of the Catalog always go directly), a summary shows where the proxy goes (this run, the engine, the Catalog), and it is saved and applied after a yes. Proxies set elsewhere on the server are shown first, with their passwords masked, and the first one is the default answer: the shell, `/etc/environment`, `/etc/profile.d`, dnf, yum, `rhsm.conf`, apt, `/etc/sysconfig/proxy`, the Docker and Podman services, `daemon.json`, `containers.conf`, `~/.docker/config.json` and on macOS the network settings.

When the network inspects HTTPS, the installer asks for the file of the company's root certificate (PEM or DER; a bundle is shown certificate by certificate, a private key is refused), shows its name, validity and SHA-256 fingerprint to compare with the IT department, and after a yes keeps it as `proxy-ca.pem` (`INTERNET_PROXY_CA_FILE`). On Linux it then offers to add it to the trust store of the server, one file per certificate, named after the installation folder so another installation on the server keeps its own (RHEL family: `/etc/pki/ca-trust/source/anchors/rn1-proxy-ca-<folder checksum>-1.pem` and `update-ca-trust extract`; Debian and Ubuntu: `/usr/local/share/ca-certificates/rn1-proxy-ca-<folder checksum>-1.crt` and `update-ca-certificates`; SUSE: `/etc/pki/trust/anchors/` and `update-ca-certificates`), restarts the engine as below (it reads the certificates when it starts), and checks the sites again - now they must answer `OK`. On macOS the installer runs without root: add the certificate to the System keychain yourself (`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain proxy-ca.pem`); Docker Desktop reads it from there.

**Where it is kept:**

- `INTERNET_PROXY`, `INTERNET_NO_PROXY`, `INTERNET_PROXY_CA_FILE` and `INTERNET_PROXY_PAC` in the settings (group **Internet access** of option 1). The address never holds a login: the script may be passed on.
- The login in `.proxy_login` next to the installer: percent-encoded `user:password`, mode 600, after a line `proxy=<address>` naming the proxy it belongs to. A proxy changed elsewhere (option 1) gets no login until option 26 asks for it - the password of one proxy never goes to another. It goes into no command line, no log and no job step. An `https://` proxy that gets the login must show a certificate the server trusts (the check does not skip it).
- With an empty `INTERNET_PROXY` a proxy exported in the shell is used as before.

**This run:** the installer exports the proxy (`http_proxy`, `https_proxy` and the upper-case names, `no_proxy` with this server, its addresses, the domain of the Catalog, the internal names and the private address ranges) for its own downloads and the programs it starts. sudo drops these variables, so the steps that run as root (package installs, the Docker Compose download) read them from a file only root can read (`/run/rn1-proxy.<pid>.env`), which is removed after the steps, also after Ctrl+C, a kill or a cancelled job. When apt or dnf have a proxy of their own configured, which would win, they get a copy of their configuration with this proxy for these steps (`apt-get -c`, `dnf --config=`); nothing in `/etc` is changed. zypper takes its proxy only from `/etc/sysconfig/proxy` (`yast proxy`): the installer says what to set there.

**The engine** pulls the images later too (updates, option 11), so it keeps the proxy:

- **Docker and Podman on Linux:** a drop-in of their service, `/etc/systemd/system/docker.service.d/50-rn1-proxy.conf` (or `podman.service.d`), holds only `EnvironmentFile=-/etc/rn1-technology-catalog/engine-proxy.env`. That file holds the proxy with its login and `NO_PROXY` (this server, the domain of the Catalog, the internal names, the private address ranges), mode 600 and readable only by root - an `Environment=` line could be read by every user. Both files start with a marker line: the installer changes or removes only files that have it. The engine serves every installation folder of the server, so the env file names the folders whose settings it holds (one `# Folder:` line each; folders with the same proxy are all recorded); the proxy of another folder is replaced only after a yes, and the files stay while another recorded folder still has a proxy set. For Podman, `/etc/containers/containers.conf.d/50-rn1-proxy.conf` (`http_proxy = false`) keeps Podman from handing its own proxy to every container it creates - also when Podman keeps a proxy of the administrator. It applies to every rootful Podman container of the server.
- **When:** at the setup of the engine the files are written before the packages are installed (Debian's Docker package starts the daemon at once), with `systemctl daemon-reload` before the service starts; afterwards whenever the proxy is saved, changed or removed in option 26. A running Docker must restart to read them: the installer asks first (`Restart Docker now? [y/N]`; the Catalog is unreachable for about a minute, then its containers come back). Podman's service is just stopped: its socket starts it again with the proxy, and the containers keep running.
- **Left alone:** a proxy in Docker's `daemon.json` wins over every other setting, so the installer writes nothing and says so. A proxy in a drop-in of the administrator is shown, and the installer's drop-in (which wins over it) is written only after a yes; that file stays as it is.
- **macOS:** the LaunchAgent of the Podman machine gets the proxy in `EnvironmentVariables` (mode 600): Podman sets the proxy in the machine at every start from the variables of the process that starts it. Option 26 offers to restart the machine. Colima gets it in `env:` of its `colima.yaml` (mode 600) and restarts to use it (at its setup at once, in option 26 after a yes). Docker Desktop takes its proxy only from its own settings (Settings > Resources > Proxies: System, which follows macOS and its PAC file, or Manual): the installer says what to enter there.
- Option **16** names an engine that does not use the proxy of the settings yet.

**The Catalog's containers:** only catalog-web (license activation, the daily synchronization, the package store) and Nginx Proxy Manager (Let's Encrypt) go out through the proxy. `.env` holds `RN1_HTTPS_PROXY` (with the login), `RN1_HTTP_PROXY` (empty unless the online catalog is an `http://` address) and `RN1_NO_PROXY` (every service of the stack, this server, the host name of catalog-web, the domain of the Catalog, the online catalog when it is internal - an address, or a name in the server's domains or the internal names -, the internal names as `name` and `.name`, the private address ranges, which .NET does not read); the compose file passes them to these two services in upper and lower case, with `ALL_PROXY` empty. HTTPS only on purpose: every internal call is plain `http://` or no HTTP at all, so even a missing `NO_PROXY` entry cannot send it to the company's proxy. MongoDB, MinIO, RabbitMQ, OpenSearch and the workers get no proxy: the compose file gives them the same names empty, so a proxy an engine hands to every container (the Podman machine of a Mac, `~/.docker/config.json`) cannot reach them either. Nginx Proxy Manager does not fetch the address ranges of the CDNs at its start (`IP_RANGES_FETCH_ENABLED: "false"`: not needed here, and behind a proxy it would wait for them). A relay on this server (`127.0.0.1`) is `host.containers.internal` for Podman and `host.docker.internal` (with `host-gateway`) for Docker; the relay must also listen there - for Docker the address of the bridge (`172.17.0.1`), for Podman the server's own LAN address. A relay that logs in as a domain user is then an open proxy for the whole network unless a firewall lets only the containers in (for example `10.88.0.0/16` for Podman). With a company certificate, `proxy-ca-bundle.pem` (the certificates of the server plus the company's; option 2 builds it again) is mounted read-only into both, with `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS`. Saving the proxy generates `.env` and the compose file again (passwords and host name kept) and, when the stack runs, creates the containers whose proxy settings changed again after a yes (about a minute without the web interface; the data and the license stay). When other settings differ from the files too (a new version, ports ...), nothing is written: option **2** (or **U** for a new version) applies them together, with their backup and checks. Without an internet proxy and certificate the files are byte for byte as before.

**Removing** (option 26): the settings and `.proxy_login` go, the installer's drop-ins and env file go (with the engine restart as above), the files are generated without the proxy; the company certificate is forgotten and taken out of the trust store only after its own yes. **R** also offers to remove the engine's proxy files and the certificate in the trust store, when no other installation on the server uses them. Option **23** takes over the proxy of an installation (from its `.env`), its `.proxy_login` and its `proxy-ca.pem`.

**When a download fails** (option 11, the upgrade, the installer update, Docker Compose, the first start in **I**), the installer offers the check of the internet access in a terminal, and names `network-check` otherwise.

The Catalog's own synchronization proxy (in its web interface) stays empty: catalog-web uses the proxy of its environment. Option **20** sends only the address and the key of the online catalog, so a proxy set there is kept as it is.

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

**19** lists the downloaded chains first, then the single files, and uploads to the local catalog (`/v1/synchronization/snapshot`). It follows each import until it finishes. A chain is imported file by file: the next upload starts only after the previous import finished, and the import stops at the first failure. It needs a valid license (option **25**) and a local API key (role Synchronizer or Admin) or a local administrator login. The password is never stored.

While an import (or a synchronization of **20**) runs, its job shows:

- the progress the web interface shows (the synchronization history of the operation) with the step and the time so far, e.g. `Import 46% · importing versions · 31m05s`; the status of the operation needs the Admin or SiteAdmin role;
- `Preparing` while the Catalog copies the snapshot and unpacks it: it reports no progress for this, and a full snapshot can take a long time;
- every step the Catalog writes to the log of catalog-web, once and with its time: `13:50:15 Extracted archive`, `13:52:33 Synchronized EXT_nist_cpe items`, errors and a full disk included (an exception with the line it belongs to, never its stack); where to read on comes from the time stamps of the container engine, so a clock of the virtual machine on macOS that differs from the Mac does not matter;
- at the end, that the Catalog rebuilds its search index in an operation of its own: searches can be incomplete until it has ended.

The access token of a login lasts 30 minutes; the job renews it with its refresh token every 25 minutes. The refresh token lasts 12 hours and the Catalog gives a new one only in its last 30 minutes, which a renewal every 25 minutes always reaches. When the login cannot be renewed, the job stops following and says so; the import goes on in the Catalog (option **10** shows its log) and the job ends without a result. An API key does not expire, so it is the better choice for long imports.

Without the Admin or SiteAdmin role the job cannot read the operation: it takes the end and the result from the synchronization history, a failure before the history has a record (a full disk while the Catalog copies the snapshot) from the log of catalog-web. Catalog 26.x cancels an import while another synchronization runs; the log says so. Where the log cannot be read, a running synchronization of someone else in the history only makes it probable: the job then ends without a result.

Before an import (19, `import`, `import-chain`, the Data step of **I**) the installer checks the memory of the engine: below 24 GB it says so, offers more memory for the Linux VM on macOS and asks whether to go on (without a terminal it only warns). When the import fails because the kernel stopped a container for lack of memory, it says so, offers the memory again on macOS, and offers the same import again - a snapshot import replaces the data, so the half import does no harm (a daily snapshot, which builds on the day before, is not offered again by itself). See [Memory](#memory).

Every file must fit the upload limit of the local catalog. The script checks this before the upload:

- Catalog 25.x accepts at most 10 GB per file, a fixed limit. If the full snapshot is larger, use **20** (servers with internet access) or upgrade to 26.x with **21** first.
- Catalog 26.x takes the limit from `SYNC_MAX_UPLOAD` in the settings (default `32GB`; the Catalog itself defaults to 8 GB). It is passed to catalog-web as `Synchronization__MaxUploadFileSize`.

**20** (it needs a valid license too) writes the online URL and key into the local catalog's synchronization settings (only these two: its other settings, a proxy of the synchronization with its password, stay as they are). From then on the catalog downloads and imports the right snapshots itself, every day at `AUTOSYNC_CRON`. On a server with internet access this is the simplest way: no files to move and no upload limit.

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
| `.proxy_login` | the login of the internet proxy, percent-encoded `user:password` (mode 600; never in the script) |
| `proxy-ca.pem` | the company's root certificate for a network that inspects HTTPS (`INTERNET_PROXY_CA_FILE`) |
| `proxy-ca-bundle.pem` | the certificates of the server plus the company's, read-only in catalog-web and Nginx Proxy Manager (option 2 builds it) |
| `.jobs/internet-check` | the last internet check with its time: the menu header and option 16 use it for 15 minutes |

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

## License

The Catalog works only with a license from Raynet. Without one, Catalog Web shows its activation page, and its API answers everything that needs the license with HTTP 520: no snapshot import, no self-sync, no API keys. The installer then says "The Catalog is not activated yet (no valid license) - option 25 activates it" instead of an unexpected error.

**I** activates it in its own step, in a new installation and in a repair: after the start and before the data; **0** there means later. Afterwards option **25** (or `./rn1-technology-catalog-installer.sh license`) shows the license - status, edition, the Catalog versions it is for, the expiry date and the hardware ID of this Catalog - and activates it in one of the three ways of the Catalog's own page:

| Way | What happens | Needs |
|---|---|---|
| **1** By order number | Catalog Web fetches the license from Raynet's license server, `licenses.raynet.de`. The order number, your name, company and e-mail address (default: `NPM_ADMIN_EMAIL`) go to Raynet. It can take a few minutes. | HTTPS (port 443) from catalog-web to `licenses.raynet.de`, through the proxy of the network where there is one |
| **2** By license file | The `.rswl` file from Raynet is uploaded as it is. Raynet makes it for the hardware ID that option 25 shows. | - |
| **3** By e-mail | Paste the license text of Raynet's e-mail, from its line `LICENSE STARTS HERE` to its line `LICENSE ENDS HERE`. Text before the first line (a greeting), e-mail quotes (`> `) and, in a terminal, what the paste brings after the last line are dropped; two empty lines or the end of the input end it too. It is sent with its line breaks. Like the file, Raynet makes it for the hardware ID of this Catalog. | - |

- Only a site administrator activates (role SiteAdmin; `admin` is not one). The installer asks for a login with `root` as the default user name; a new Catalog has `root` with the password `root` - change it in the web interface. Another user is refused before any question. The password is not stored.
- The password, the order number and the license text never appear on a command line: curl reads the login from stdin and the license from a temporary file of mode 600. Ctrl+C removes these files too.
- When the Catalog refuses a license, the installer says why in plain words and what helps: a license for another server (hardware ID), an expired one, one for another product or an older Catalog version, Raynet's license server not reached, an unknown order number, a damaged text. Then it offers the ways again; three failures stop it. In **I** the outcome stays on the screen until a key.
- Command line: `license status` needs no login (exit code 0 when the license is valid); `license file PATH`, `license order` and `license text` ask for the login (a missing file is named before it); `license` alone works like option 25.
- After an upgrade (**U**, option **21**) or a patch update, the job checks the license once the stack is healthy: a license for an older Catalog version, or for another host name, stops working at an upgrade, and the job log then says so.

**The host name of catalog-web.** The Catalog binds its license to the host name of its container (its hardware ID). Docker and Podman give a container its ID as host name, so a license stopped working whenever catalog-web was created again (an upgrade, changed files). catalog-web now gets a fixed host name, `CATALOG_HOSTNAME`:

- Empty (the default): the name in `.env`; files that get one for the first time keep the name of a licensed catalog-web (see below), else they get the short name of this server in lower case, without the domain (on macOS its local host name). A name that is a service of the stack (for example `mongo`) gets `catalog-` in front; a server without a name of its own (`localhost`) gives `catalog-web`.
- It is written to `.env` and kept there like the passwords: a later rename of the server does not change it, so the license stays valid. Only a `CATALOG_HOSTNAME` set in the settings replaces it; on an installation with data, option **2** then says that the Catalog needs a license for the new name (unless catalog-web has it already). A value in `.env` that is no usable host name is replaced with a warning.
- It must be a host name without the domain: letters, digits and `-`, at most 63 characters, not `localhost` and not the name of a service of the stack.
- Option **1** shows the name catalog-web has or gets (`Effective`) when `CATALOG_HOSTNAME` is opened. Another name on a Catalog with a valid license (or one that does not answer: it may hold one) is named there: after options 2 and 6 the license must be activated again (option **25**).
- Option 25 and the License step of **I** compare the name with the host name catalog-web runs with. When the files have another one that option **6** has not applied yet, or `CATALOG_HOSTNAME` in the settings names another one, a license activated then would stop working at the next start: they say so and ask first (default no).

**Installations from before this version** get the fixed host name the first time option **2** (or the repair of **I**, an upgrade, a patch update or option **8**) writes the files with this installer. A license is never lost on the way:

- When Catalog Web answers that it holds a valid license, catalog-web keeps the host name it has now - the ID of its container, for example `4f9c2d71e8a3`. It goes into `.env` as `CATALOG_HOSTNAME`, so the license survives this and every later new container. The output (for an upgrade or a patch update: the job log) says so once: "catalog-web keeps its host name ...: the Catalog's license is bound to it (CATALOG_HOSTNAME in .env)".
- When Catalog Web does not answer (the stack is stopped or starting, or no answer within 15 seconds) while its container exists, it keeps that name too: the Catalog may hold a license, and keeping the name costs nothing.
- When Catalog Web answers that it has no valid license, or there is no catalog-web container, there is nothing to lose: catalog-web gets the name of this server, and option **25** activates the license for it after the next start.
- A host name with a domain counts up to the first dot, as the Catalog reads it: `catalog.example.com` is kept as `catalog`. A name that cannot be a fixed host name (for example with `_`) is not kept: catalog-web gets the name of this server, and the output says that a license must then be activated again.
- When the container engine does not answer (the Podman machine, Colima, Docker Desktop or the Docker daemon not started), writing the files stops with an error and changes nothing: only the engine knows the name to keep. Start it, then write the files again.
- `CATALOG_HOSTNAME` set in the settings always wins; a name in the newest backup of `.env` too, when `.env` is missing. **U** and option **21** say before they start that a licensed Catalog keeps its host name. Only writing the files and the `CATALOG_HOSTNAME` screen of option **1** ask Catalog Web; the menu never does. Until the files are written again the menu shows that they differ from the settings.

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

On a Mac the installer runs as your normal user (not with sudo). macOS ships bash 3.2, so the installer first checks, one by one, what it needs: [Homebrew](https://brew.sh) (when it is missing, it says so and installs it with the official script of brew.sh after a yes), then Homebrew's bash and the GNU tools `coreutils gnu-sed grep findutils` (it names the missing ones and installs them after a yes). Then it starts itself in Homebrew's bash. Catalog Web and the workers get `platform: linux/amd64` on Apple Silicon. Three engines are possible:

- **Podman** (`CONTAINER_ENGINE="podman"`, Apple Silicon and macOS 26 or newer): see below.
- **Docker Desktop** (`CONTAINER_ENGINE="docker"`): a Docker that answers (`docker info`) is used as it is. When Docker Desktop is missing, the installer shows its license first - it is free only for companies with fewer than 250 employees **and** less than 10 million USD annual revenue, for personal use, education and non-commercial open source; everyone else needs a paid Docker subscription - and asks (also with `install-docker`; without a terminal it does not install it), then installs it with `brew install --cask docker-desktop`, starts it (`open -a Docker`) and waits until it answers. At its first start, accept the agreement and turn on Settings > General > "Use Rosetta for x86_64/amd64 emulation"; the installer warns when the settings show Rosetta off.
- **Colima** (`CONTAINER_ENGINE="colima"`, free): `brew install colima docker`, the newest Docker Compose into `~/.docker/cli-plugins`, and a VM with Apple's virtualization and Rosetta: `colima start --vm-type=vz --vz-rosetta --cpu N --memory GB --disk 100` (up to 6 CPUs; 24 GB on a Mac with 32 GB or more, else all but 8 GB - see [Memory](#memory)). It sets `vm.max_map_count` in the VM and keeps it with a provision script in `colima.yaml` of the default profile (`~/.colima/default/`, or where `COLIMA_HOME` or `XDG_CONFIG_HOME` put it, as Colima does), checks Rosetta in the VM, and starts Colima at login (`brew services start colima`). An existing Colima VM is used when it runs with Apple's virtualization.
- With Docker Desktop and Colima, Rosetta fails with Linux 6.13 and newer in the VM before macOS 26: the installer refuses that combination. Intel Macs run the images without Rosetta.

With Podman the installer uses a Podman machine (a Linux VM):

- It installs `podman` with Homebrew after asking.
- It creates a rootful Podman machine with Apple's hypervisor and Rosetta (the Catalog images are amd64), up to 6 CPUs and 24 GB of memory on a Mac with 32 GB or more (else all but 8 GB, at least 8 GB; see [Memory](#memory)), and sets `vm.max_map_count` in it. An existing machine is used when it runs with Apple's hypervisor; the installer switches it to rootful and turns Rosetta on (the machine restarts).
- Rosetta works with the Linux kernel of current Podman machines only from macOS 26 (Tahoe); older macOS versions are refused.
- The Podman machine does not start by itself after a restart of the Mac; a LaunchAgent (`~/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist`) starts it when you log in, and the containers come back with it.
- The data lives inside the Podman machine: `podman machine rm` or `podman machine reset` deletes it.
- The MongoDB kernel check uses the kernel of the Podman machine (with Docker Desktop and Colima: the kernel of their VM).

## Memory

The containers share one machine: on Linux the server, on macOS the Linux VM of the engine. 24 GB is recommended: a full snapshot import keeps MongoDB, catalog-web, the workers and OpenSearch busy at the same time, and with less the kernel may stop MongoDB in the middle of it (the import then fails with a `MongoConnectionException`).

- **The check (option 16)** shows the memory of the engine (`podman info`, `docker info`; on Linux else `/proc/meminfo`) in whole GB: `Memory: 14 GB for the containers - at least 24 GB is recommended` as a warning below 24 GB (92 % of it counts, the kernel keeps some), else `Memory: 32 GB for the containers - enough for a full snapshot import`. The same check runs in the Install step of **I**, with option **7** and `setup`, and before every snapshot import: below 24 GB they say so and ask "Continue with 14 GB anyway?" (default no; **no** stops the guided task). Without a terminal they only warn.
- **macOS:** a new Podman machine or Colima VM gets 24 GB on a Mac with 32 GB or more, else all but 8 GB (at least 8 GB) with a warning. The memory of the VM is a ceiling: macOS gives it memory only as it uses it and takes it back when the VM stops. Below 24 GB, on a Mac that keeps 8 GB for itself, the installer offers "Give the Podman machine 24 GB now?" - after a yes it stops the VM, sets the memory and starts it again, as your user (about a minute; a running Catalog restarts with it: the installer waits until the Podman machine has started its containers of before, starts the Catalog and waits until it is healthy again). By hand:
  - Podman: `podman machine stop`, `podman machine set --memory 24576`, `podman machine start` (the memory changes only while the machine is stopped);
  - Colima started at login by `brew services` (as the installer sets it up): `brew services stop colima`, `colima stop`, `memory: 24` in `colima.yaml`, `brew services start colima` - while the VM runs, the `colima start -f` of `brew services` ends at once and launchd starts it again, so after a plain `colima stop` it would start the VM again with the old memory;
  - Colima without `brew services`: `colima stop`, then `colima start --cpu N --memory 24`;
  - Docker Desktop: Settings > Resources > Memory, then Apply & restart (the installer only names it).
- **Linux:** the memory of the server is raised by whoever runs it (VM settings or hardware); the installer never changes it.
- **The cache of MongoDB** (`MONGO_CACHE_GB`): MongoDB's WiredTiger cache takes half of the memory of the whole machine minus 1 GB by default, because the container has no limit - while catalog-web, the workers, OpenSearch, RabbitMQ and MinIO need the rest. Empty (the default) means automatic: (memory of the engine - 10 GB) / 2 in steps of 0.5 GB, at least 1 - 14 GB give 2, 24 GB give 7, 32 GB give 11, 64 GB give 27; about 10 GB stay for the other services. A value (for example `4` or `2.5`, at least `0.25`) fixes it; a smaller one also helps a server whose memory cannot grow. The result goes into `.env` as `MONGO_WT_CACHE_GB` and to mongod as `--wiredTigerCacheSizeGB`; it is written again whenever the files are written (**2**, install, upgrade) and at every start (**6**, `up`), so a VM that got more memory gives MongoDB more after the next start, and only mongo is created again. The setting itself stays as you wrote it. Files of an older installer get it with option **2**; without it in `.env`, mongo starts with 1 GB.
- **Out of memory:** status (**9**) and the check (**16**) name a container the kernel stopped for lack of memory: `MongoDB was stopped by the kernel: out of memory.`, then the memory of the engine - below 24 GB with the recommendation and how the VM or the server gets more, from 24 GB on with `MONGO_CACHE_GB`. Podman keeps `OOMKilled` until the container is created again, also when its restart policy starts it again (a new stop shows as one more restart); Docker clears it at that start, so with Docker (also Docker Desktop and Colima) the installer reads the `oom` events of the daemon instead - status and check look back 24 hours, but the daemon keeps only its last 256 events. A failed import or self-sync names, at the end of its job, a stop that happened while it ran, and only then is the import offered again: the same file or the chain (a snapshot import replaces the data, so the half import does no harm). A daily snapshot builds on the data of the day before: it is not offered again by itself - import again from a full snapshot on.

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
bash tests/run_license_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_memory_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
bash tests/run_network_tests.sh "$PWD/rn1-technology-catalog-installer.sh"
```

Podman, Docker, ssh, scp, the Raynet APIs, the API of Nginx Proxy Manager and DNS are replaced by fakes. The Updates tests query Docker Hub and GHCR, so they need internet access. The jobs tests close the menu's session the way a lost SSH connection does, cancel jobs, and hold X in the full screen menu; they need Linux (`setsid` and `script` from util-linux). The time zone tests need tzdata. The distribution tests check the Podman and Docker setup for the machine they run on and the macOS flows (fake Homebrew, Podman machine, Docker Desktop and Colima). The Docker tests run the installer against a fake Docker with Docker's own behaviour and check that one engine per server holds. The versions tests use fake registries with the tags of October 2026. The license tests run the installer against a fake Catalog that answers 520 until it is activated, and check the three ways of activation byte for byte. The memory tests give the fake engines 8 to 64 GB, a Podman machine whose memory changes only while it is stopped, a Colima under `brew services` and a Docker that clears `OOMKilled` at the restart and keeps `oom` events, and check the warnings, the questions (also in a terminal and in **I**), the offer for the VM on macOS and its failures, the cache of MongoDB, and imports and a synchronization that fail because the kernel stopped MongoDB. The network tests answer every site from a table (a fake curl, fake proxies with Basic, NTLM and Digest logins, a fake TLS inspection), write the engine's drop-ins, the trust store, `.env`, the compose file, the LaunchAgent and `colima.yaml` into a test folder, and check that the proxy password reaches no command line, log or file but those of mode 600. GitHub Actions runs all sixteen suites on every push: on Ubuntu, and with `tests/run_in_container.sh` as a normal user in RHEL 8, 9 and 10 (UBI), CentOS 7 (bash 4.2), CentOS Stream 9, Rocky Linux 9, AlmaLinux 9, Debian 12 and openSUSE Leap 15.6. It also starts the whole Catalog on real Podman and on real Docker (Ubuntu 24.04 and 26.04: `install-podman` or `install-docker`, `setup`, `health`, `down`/`up`), installs Podman and pulls the images through a real squid with a Basic login while root and apt have no other way out (and checks that only catalog-web and Nginx Proxy Manager got the proxy), and runs the macOS flows on an Apple Silicon Mac.
