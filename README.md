# RN1 Technology Catalog Installer

`catalog.sh` installs and runs the **Raynet One Technology Catalog** (RayVentory Catalog) with Docker Compose. A menu guides you through setup, updates, offline installations and catalog snapshots.

## Requirements

- Linux (Ubuntu, Debian or RHEL family) with Docker Engine and the Docker Compose plugin. The older `docker-compose` 1.27 or newer also works.
- bash 4.2 or newer and curl. Snapshot features also need `jq` or `python3`.
- For OpenSearch: `vm.max_map_count` of at least 262144. Menu option 16 checks this.

## Quick start

```bash
git clone https://github.com/AKARABEL/rn1-technology-catalog-installer.git
cd rn1-technology-catalog-installer
./catalog.sh
```

Choose **7** (generate + validate + start). The settings are at the top of `catalog.sh`; option **1** opens them in `vi`.

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
| 99 | Remove containers **and all data volumes** (you must type `DELETE`) |

## Command line

```text
./catalog.sh help                    all commands
./catalog.sh setup                   generate + validate + up
./catalog.sh generate [--new-passwords]
./catalog.sh up | down | status | logs [service] | pull | restart
./catalog.sh updates                 available updates of all components
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

## Files next to the script

These files are created at runtime and are listed in `.gitignore`. Do not commit them:

| File | Content |
|---|---|
| `.env` (+ `.env.bak-*`) | generated settings including the passwords (mode 600) |
| `docker-compose.yml` (+ backups) | generated stack definition |
| `.catalog_api_key`, `.catalog_local_api_key` | stored API keys (mode 600) |
| `snapshots/` | downloaded catalog snapshots |
| `RN1-Technology-Catalog-*` | offline bundles |

## Known issues

- MongoDB 8 does not start on Linux kernels 6.19 to 7.0.13, which includes Ubuntu 26.04 with kernel 7.0.0 ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). Set `MONGO_TAG="7.0"`. The script warns about this in options 6 and 16.

## Tests

```bash
bash tests/run_tests.sh "$PWD/catalog.sh"
bash tests/run_bundle_tests.sh "$PWD/catalog.sh"
bash tests/run_snapshot_tests.sh "$PWD/catalog.sh"
```

Docker, ssh, scp and the Raynet APIs are replaced by fakes. The Updates tests query Docker Hub and GHCR, so they need internet access. GitHub Actions runs all three suites on every push.
