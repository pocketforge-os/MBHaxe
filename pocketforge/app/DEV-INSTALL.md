# MBHaxe on PocketForge: dev install (tsp-0qwbh.5)

This puts `org.pocketforge.mbhaxe` on a running A133 device inside a live device window,
without changing the image. It is written from the sources (image `pf-app@.service`,
runtime `pf-app-launch`/`pf-app-manifest`, mission-control device rules) and has not yet
been run on a device: the first run is the tsp-0qwbh.6 window, which records the evidence.

A whole-image reflash wipes everything below. The release path is the platform's `[fetch]`
executor plus an app package, not this procedure (see "Release path" at the end).

## What goes where

| Device path | Content | Owner, mode |
|---|---|---|
| `/opt/pocketforge/apps/org.pocketforge.mbhaxe/` | app root (`app-root.sh` output) plus `data/` installed by `[fetch]` | root, read-only to the app |
| `/usr/share/pocketforge/app-policy/org.pocketforge.mbhaxe.resources.json` | resource inventory read by `pf-app-launch` | root, 0644 |
| `/etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d/10-policy.conf` | unit policy rendered by runtime `pf-app-policy-render` | root, 0644 |
| `/var/lib/pocketforge/apps/org.pocketforge.mbhaxe/state/mbhaxe/` | created at launch: `settings.json`, `console.log`, `data/replays/` | gamer, 0700 parent |
| `/var/cache/pocketforge/apps/org.pocketforge.mbhaxe/mbhaxe/tmp/` | created at launch: `TMPDIR` | gamer, 0700 parent |

`pf-app@.service` already exists on the image: it runs `pf-app-launch <id>` as `gamer` with
the app directory as working directory, `XDG_STATE_HOME`/`XDG_CACHE_HOME` set to the paths
above, `ProtectSystem=strict` and `ReadOnlyPaths=` on the app directory. `pf-app-launch`
resolves `app.toml`, checks `[requirements]` against
`/usr/share/pocketforge/platform-capabilities.toml` (GLES 3.0 against `gles_max`,
`memory_mib` against `app_memory_budget_mib`, inputs against `inputs`), applies Landlock and
execs `launch`. `launch` changes to the writable state directory, puts the bundled `lib/` on
`LD_LIBRARY_PATH`, sets `ALSOFT_CONF`, `SDL_VIDEODRIVER=wayland` and `TMPDIR`, and execs
`marblegame` (see the comments in `launch`).

Preconditions: an A133-open image with the gamescope session (`g1`), `pf-app@.service`,
`pf-app-launch` and a schema-2 `platform-capabilities.toml`; the openmbu lane holds an open
live window with its `lane-ssh` bundle. The game data is upstream's: keep it on the laptop
cache and the device, never upload or re-host it, and never put it in a repository, bead,
artifact store or message.

## 1. Stage on the laptop

Inputs, all by SHA256:

- the aarch64 app root from the pipeline (`build.sh --arch aarch64 --app-root`, or
  `app-root.sh --build OUT/aarch64-product.env`):
  `org.pocketforge.mbhaxe-<version>-aarch64.app.tar.zst` and its `.sha256`;
- the `[fetch]` archive, downloaded once to a local cache (`pf-fetch.py` refuses it unless it
  matches the size and SHA256 pinned in `app.toml`);
- runtime `pf-app-policy-render` built from the runtime commit the device image pins
  (`cargo build -p pf-app-launch --bin pf-app-policy-render`);
- the device's own `/usr/share/pocketforge/platform-capabilities.toml` and resource inventory
  (any `/usr/share/pocketforge/app-policy/*.resources.json` from the image, which is the
  image's `build/app-policy-a133-open-g1-v1.json`), pulled in the window with the
  lane-ssh `scp` options. Both are small; record their SHA256.

```sh
pocketforge/app/stage-app.sh \
  --app-artifact OUT/org.pocketforge.mbhaxe-<version>-aarch64.app.tar.zst \
  --root STAGE \
  --data-archive CACHE/MBHaxe-Ultra-Linux.tar.gz \
  --policy-render RUNTIME/target/release/pf-app-policy-render \
  --platform-contract PULLED/platform-capabilities.toml \
  --resource-inventory PULLED/app-policy.resources.json
tar -C STAGE --sort=name --owner=0 --group=0 --numeric-owner \
  -cf mbhaxe-stage.tar opt usr etc PF-STAGE.files PF-STAGE.sha256
sha256sum mbhaxe-stage.tar > mbhaxe-stage.tar.sha256
```

`stage-app.sh` verifies the app artifact and its inner `SHA256SUMS`, runs `pf-fetch.py`
(data/ only, atomic, refused on any mismatch) and renders the drop-in against the device's
contract. A refusal from the renderer (for example `memory_mib` above the device budget) is
a stop: fix the descriptor, do not hand-edit the drop-in. Optionally validate the staged app
root with the image's `pf-app-validate` wrapper
(`pf-app-validate STAGE/opt/pocketforge/apps PULLED/platform-capabilities.toml org.pocketforge.mbhaxe`).

## 2. Transport (network or image load, never the console)

Follow mission-control `.rules/device-operations.md` ("Staging location" and "Data
transport"). The serial console carries no payload.

- Preferred when a reflash is due anyway: put `mbhaxe-stage.tar` on the FAT root as part of
  the window's kit payload during the whole-image load (`/boot` on the device), hash-bound in
  the sealed request.
- Inside an open window: copy it over the seeded Wi-Fi with the lane-ssh bundle's exact
  `scp` options into a disk staging directory:

```sh
# on the device (lane-ssh), generation <gen> from the window grant
R=/var/tmp/pf-openmbu/<gen>
sudo -n /usr/bin/install -d -o gamer -g gamer -m 0755 "$R"
findmnt -n -o FSTYPE -T "$R"            # must print ext4; anything else: stop
# on the laptop
scp <lane-ssh options> mbhaxe-stage.tar mbhaxe-stage.tar.sha256 <dut>:/var/tmp/pf-openmbu/<gen>/
```

Never stage in `/run`, `/dev/shm` or a tmpfs: the A133 has no swap and the payload would
come out of the memory under test.

## 3. Install

```sh
R=/var/tmp/pf-openmbu/<gen>
cd "$R"
sha256sum -c mbhaxe-stage.tar.sha256                       # before every use
sudo -n test ! -e /opt/pocketforge/apps/org.pocketforge.mbhaxe   # refuse to overlay an old install
sudo -n tar -xf mbhaxe-stage.tar -C / --no-same-owner --no-overwrite-dir --keep-old-files \
  opt/pocketforge/apps/org.pocketforge.mbhaxe \
  usr/share/pocketforge/app-policy/org.pocketforge.mbhaxe.resources.json \
  etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d
mkdir -p check && tar -xf mbhaxe-stage.tar -C check PF-STAGE.sha256
(cd / && sudo -n sha256sum --quiet -c "$R/check/PF-STAGE.sha256")   # every installed file
sudo -n systemctl daemon-reload
systemctl cat pf-app@org.pocketforge.mbhaxe.service | grep -c '^# /etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d/10-policy.conf'
```

`--no-same-owner` as root makes every file root-owned; `--no-overwrite-dir` leaves the
metadata of existing `/opt`, `/usr`, `/etc` directories untouched; `--keep-old-files`
refuses to replace anything already present.

## 4. Launch

- Launcher: `pf-shell` scans `/opt/pocketforge/apps` when it starts, so restart the shell
  to pick the app up (`sudo -n systemctl restart pf-shell-selected.service`) and start
  "Marble Blast Ultra" from its tile. Whether the current launcher build lists and
  activates it is one of the things the window checks.
- Direct, for evidence or if no tile appears:
  `sudo -n systemctl start pf-app@org.pocketforge.mbhaxe.service`; stop with
  `sudo -n systemctl stop pf-app@org.pocketforge.mbhaxe.service` (the game also quits
  cleanly from its menu).
- Observe: `systemctl status pf-app@org.pocketforge.mbhaxe.service`,
  `journalctl -u pf-app@org.pocketforge.mbhaxe.service -b`,
  `/var/lib/pocketforge/apps/org.pocketforge.mbhaxe/state/mbhaxe/console.log`, and the screen
  through `capture-screen.sh` + `review-screen.sh`. Measure peak memory for
  `[requirements].memory_mib` (for example the unit's `MemoryPeak` from `systemctl show`,
  plus the PVR heap use the GPU tooling reports) and record it on the bead.

## 5. Remove

```sh
sudo -n systemctl stop pf-app@org.pocketforge.mbhaxe.service
sudo -n rm -rf /opt/pocketforge/apps/org.pocketforge.mbhaxe \
  /etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d \
  /usr/share/pocketforge/app-policy/org.pocketforge.mbhaxe.resources.json \
  /var/lib/pocketforge/apps/org.pocketforge.mbhaxe \
  /var/cache/pocketforge/apps/org.pocketforge.mbhaxe
sudo -n systemctl daemon-reload
sudo -n systemctl restart pf-shell-selected.service
rm -rf /var/tmp/pf-openmbu/<gen>
```

The last two state paths hold the player's settings and replays; keep them if the next
install should reuse them. The next whole-image load removes everything anyway.

## Evidence to record on the bead

Per the live-window contract and direct-SSH rules: boot ID and the image descriptor/raw
SHA256 verified at that boot; MBHaxe commit, app artifact SHA256 and `APP-MANIFEST.json`
SHA256; SHA256 of `mbhaxe-stage.tar` as pushed and as verified on the device; the pulled
platform contract and inventory SHA256; every command with its rc; output hashes; the
`PF-STAGE.sha256` check result; before/after SHA256 of every changed device file (all new
paths here, none replaced). The data archive is identified by its pinned SHA256 only.

## Release path (b)

The image-shipped route installs the app root from a package and lets the platform's fetch
executor run `[fetch]` on the device. `pf-fetch.py` is the reference for the semantics this
descriptor needs (pinned URL, size and SHA256; `strip_components` with GNU tar rules;
refusal of unsafe members; atomic install; no change on refusal). Open points for the
executor (platform/runtime, tracked from tsp-mc9m.41.996.4), all recorded in the
tsp-0qwbh.5 report:

1. Destination. The game needs `data/` beside `marblegame`, and the descriptor's
   `dest = "data"` is relative to the app directory. The platform schema's
   `destination` only offers `var`/`home`, and the app directory is read-only to the app
   (Landlock, `ReadOnlyPaths=`). Either the executor installs into the app directory as
   root before first launch, or the game gains a data-root override that points into
   `XDG_DATA_HOME`/state (a game change; resource paths are exe-relative today).
2. Member selection. `strip_components = 2` already drops everything outside `data/`
   (the upstream binaries sit at depth 2). An explicit include filter would say so
   directly and survive an upstream layout change; the schema has none.
3. The JSON schema (`abi/app.schema.json`) does not list `[requirements]`, although the
   Python validator and the runtime resolver both accept it.
