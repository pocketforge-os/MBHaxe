# MBHaxe on PocketForge: dev install (tsp-0qwbh.5, tsp-0qwbh.9, tsp-0qwbh.10)

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
| `/var/cache/pocketforge/apps/org.pocketforge.mbhaxe/mbhaxe/converted/` | created by the game: `MBHAXE_CACHE_DIR`, heaps' resource-converter cache (converted fonts) | gamer, 0700 parent |

`pf-app@.service` already exists on the image: it runs `pf-app-launch <id>` as `gamer` with
the app directory as working directory, `XDG_STATE_HOME`/`XDG_CACHE_HOME` set to the paths
above, `ProtectSystem=strict` and `ReadOnlyPaths=` on the app directory. `pf-app-launch`
resolves `app.toml`, checks `[requirements]` against
`/usr/share/pocketforge/platform-capabilities.toml` (GLES 3.0 against `gles_max`,
`memory_mib` against `app_memory_budget_mib`, inputs against `inputs`), applies Landlock and
execs `launch`. `launch` changes to the writable state directory, puts the bundled `lib/` on
`LD_LIBRARY_PATH`, sets `ALSOFT_CONF`, `SDL_VIDEODRIVER=wayland`, `TMPDIR` and
`MBHAXE_CACHE_DIR`, and execs `marblegame` (see the comments in `launch`). The dev install keeps
`data/` inside the app directory, which `launch` falls back to when
`/var/lib/pocketforge/apps/org.pocketforge.mbhaxe/data` (the release location) does not exist: the
current image's sandbox cannot read the release location yet (see "Release path").

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
tar -C STAGE --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
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
require_absent_real_path() {   # refuse existing targets, dangling symlinks and symlinked parents
  p=$1
  sudo -n test ! -e "$p" && sudo -n test ! -L "$p" || return 1
  while [ "$p" != / ]; do
    p=${p%/*}; [ -n "$p" ] || p=/
    sudo -n test ! -L "$p" || return 1
  done
}
require_absent_real_path /opt/pocketforge/apps/org.pocketforge.mbhaxe
require_absent_real_path /usr/share/pocketforge/app-policy/org.pocketforge.mbhaxe.resources.json
require_absent_real_path /etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d
sudo -n tar -xf mbhaxe-stage.tar -C / --no-same-owner --no-overwrite-dir \
  opt/pocketforge/apps/org.pocketforge.mbhaxe \
  usr/share/pocketforge/app-policy/org.pocketforge.mbhaxe.resources.json \
  etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d
mkdir -p check && tar -xf mbhaxe-stage.tar -C check PF-STAGE.sha256
(cd / && sudo -n sha256sum --quiet -c "$R/check/PF-STAGE.sha256")   # every installed file
sudo -n systemctl daemon-reload
systemctl cat pf-app@org.pocketforge.mbhaxe.service | grep -c '^# /etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d/10-policy.conf'
```

The three preflights refuse to replace any install target, including dangling symlinks, and
refuse symlinked parent components. `--no-same-owner` as root makes every file root-owned;
`--no-overwrite-dir` leaves the metadata of existing `/opt`, `/usr`, `/etc` directories untouched.

## 4. Window step 1: device probe (before the game)

Nobody has yet shown a native Wayland EGL client rendering under `gamescope --expose-wayland` on
the device, so the window runs `pf-probe` (source `tests/pf-probe/pf-probe.c`, tsp-0qwbh.10) first.
It ships in the app root next to `marblegame`, is built by the same pipeline from the same
bookworm sysroot, and links the same libraries: the image's `libSDL2-2.0.so.0` and
`libGLESv2.so.2`, and the app root's bundled OpenAL Soft. It runs through the app's own `launch`
(`MBHAXE_PROBE=1` makes `launch` exec `pf-probe` in place of `marblegame`), so it gets the game's
`LD_LIBRARY_PATH`, `ALSOFT_CONF`, `SDL_VIDEODRIVER=wayland` and working directory. It runs
through `pf-app@`, so it also gets the unit's sandbox, Landlock policy and session environment.
A probe PASS therefore means the game's own stack renders on the device.

It does, in order:

1. `SDL_Init(SDL_INIT_EVERYTHING)`, as `sdl.hdll` does.
2. Checks that the video driver is `wayland`.
3. Creates an OpenGL ES 3.0 context, with the game's attributes: ES profile, 3.0, depth 24,
   stencil 8, double-buffered.
4. Prints GL_VERSION, GL_RENDERER, the GLSL version and the extension count.
5. Draws a VAO quad with `#version 300 es` shaders into the default framebuffer, then reads it
   back with `glReadPixels`. It does this twice, with a buffer swap in between.
6. Presents frames for `--hold` seconds.
7. Lists the SDL game controllers.
8. Plays a 0.5 s 440 Hz tone on the default OpenAL device.

Every check prints one `PROBE CHECK <name> PASS|FAIL|WARN|SKIP ...` line, and the run ends with
`PROBE RESULT PASS [warn=...]` or `PROBE RESULT FAIL reason=<check>`. The exit status is 0 only
when every GL check passed. A missing gamepad or a silent speaker is a `WARN`, reported but not
fatal. A built-in watchdog turns a hang into `reason=timeout`, naming the stage it hung in. A
fatal signal becomes `reason=crash`, naming the signal and the stage. Either way the probe always
ends with a named result.

Run it after step 3 (install), with the shell idle and before the game is started. The drop-in
lives in `/run`, so a reboot also removes it.

```sh
U=pf-app@org.pocketforge.mbhaxe.service
D=/run/systemd/system/$U.d
probe() {   # $1 = pf-probe options (no spaces inside an option)
  sudo -n install -d -m 0755 "$D"
  printf '[Service]\nEnvironment=MBHAXE_PROBE=1\nEnvironment="MBHAXE_PROBE_ARGS=%s"\n' "$1" \
    | sudo -n tee "$D/50-probe.conf" >/dev/null
  sudo -n systemctl daemon-reload
  cur=$(sudo -n journalctl -n 0 --show-cursor | sed -n 's/^-- cursor: //p')
  sudo -n systemctl start --wait "$U"; echo "systemctl rc=$?"
  echo "probe exit status=$(systemctl show -p ExecMainStatus --value "$U")"
  sudo -n journalctl --after-cursor "$cur" -u "$U" -o cat | grep '^PROBE '
  sudo -n systemctl reset-failed "$U" 2>/dev/null || true
}

# arm 1, positive: must end "PROBE RESULT PASS" (warn=gamepad/audio allowed), exit status 0.
# --hold 5 keeps the test pattern on screen: capture it with capture-screen.sh + review-screen.sh.
probe '--expect-renderer zink --reject-renderer llvmpipe --reject-renderer softpipe --hold 5'

# arm 2, negative control: must end "PROBE RESULT FAIL reason=sdl-init-video", exit status 1.
probe '--negative'

# clean up before launching the game (section 5)
sudo -n rm -f "$D/50-probe.conf"; sudo -n rmdir "$D" 2>/dev/null; sudo -n systemctl daemon-reload
```

Expected output of arm 1 on the device. The `...` parts vary. GL_VERSION is 3.0 on the shipping
profile (3.2 appears only under the CTS-profile drirc). Each value in angle brackets is what the
window records.

```text
PROBE INFO probe version=1.3.2-pf.<date>.<sha10> mode=positive sdl=2.26.5 timeout=60 hold=5.0
PROBE INFO env SDL_VIDEODRIVER="wayland" WAYLAND_DISPLAY="wayland-0" XDG_RUNTIME_DIR="<...>" DISPLAY="" ALSOFT_CONF="/opt/pocketforge/apps/org.pocketforge.mbhaxe/alsoft.conf"
PROBE INFO libs sdl="/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0" gles="/usr/lib/aarch64-linux-gnu/libGLESv2.so.2" openal="/opt/pocketforge/apps/org.pocketforge.mbhaxe/lib/libopenal.so.1"
PROBE CHECK sdl-init PASS flags=everything
PROBE INFO sdl video_driver="wayland" audio_driver="alsa"
PROBE CHECK video-driver PASS driver="wayland" expected="wayland"
PROBE CHECK window PASS
PROBE CHECK gl-context PASS profile=es requested=3.0
PROBE INFO gl_config rgba=<8880|8888> depth=24 stencil=8 context=3.0 profile_mask=0x4 swap_interval=<n>
PROBE INFO egl vendor="Mesa Project" version="1.5" client_apis="<...OpenGL_ES...>"
PROBE INFO gl GL_VERSION="OpenGL ES 3.0 Mesa 26.1.7<...>" GL_RENDERER="zink Vulkan 1.<n>(<PowerVR device name> ...)" GL_VENDOR="Mesa" GL_SHADING_LANGUAGE_VERSION="OpenGL ES GLSL ES 3.00"
PROBE INFO gl extensions=<n> max_texture_size=<n> version_int=3.0
PROBE INFO gl frag_highp_float=range:<...>,precision:<n> frag_mediump_float=range:<...>,precision:<n>
PROBE CHECK gl-version PASS GL_VERSION="OpenGL ES 3.0 Mesa 26.1.7<...>"
PROBE CHECK glsl-version PASS GL_SHADING_LANGUAGE_VERSION="OpenGL ES GLSL ES 3.00"
PROBE CHECK gl-renderer PASS GL_RENDERER="zink Vulkan 1.<n>(<PowerVR ...>)" expect="zink" reject="llvmpipe" reject="softpipe"
PROBE CHECK gl-program PASS glsl=300es vao=1
PROBE CHECK gl-framebuffer PASS status=0x8cd5 size=<w>x<h>
PROBE CHECK gl-draw PASS centre=51,153,204 want=51,153,204 corner=204,51,102 want=204,51,102 tol=8 size=<w>x<h> glerror=0x0000
PROBE CHECK gl-draw-after-swap PASS centre=204,102,153 want=204,102,153 corner=102,204,51 want=102,204,51 tol=8 size=<w>x<h> glerror=0x0000
PROBE CHECK gl-present PASS frames=<n> seconds=<about 5> fps=<about 60> glerror=0x0000
PROBE CHECK gl-errors PASS after_strings=0x0000 after_present=0x0000
PROBE INFO gamepad index=0 name="<...>" guid=<...> vendor=0x<...> product=0x<...> gamecontroller=1 mapping="<...>"
PROBE CHECK gamepad PASS joysticks=<n> gamecontrollers=<1 or more>
PROBE INFO openal device="<ALSA device name>" AL_VERSION="1.1 ALSOFT 1.19.1" AL_RENDERER="OpenAL Soft" AL_VENDOR="OpenAL Community" frequency=48000
PROBE CHECK audio PASS device="<...>" tone=440Hz duration_ms=500 played_ms=<about 500> state=0x1014 al_error=0x0000 alc_error=0x0000
PROBE RESULT PASS
```

While `--hold` runs, the screen shows a blue rectangle (51,153,204) over the middle half of a
magenta-red background (204,51,102). Expected output of arm 2:

```text
PROBE INFO probe version=1.3.2-pf.<date>.<sha10> mode=negative sdl=2.26.5 timeout=60 hold=0.0
PROBE INFO env SDL_VIDEODRIVER="x11" WAYLAND_DISPLAY="wayland-0" ... DISPLAY="" ...
PROBE INFO libs ...
PROBE CHECK sdl-init-video FAIL sdl_error="x11 not available"
PROBE RESULT FAIL reason=sdl-init-video
```

How to read a failed arm 1. Record the full `PROBE` output on the bead whatever the result. Each
item is the `reason=` the run ended with, then what it means.

- `sdl-init-video`: SDL could not connect to the compositor. Look at the `env` line: is
  `WAYLAND_DISPLAY` or `XDG_RUNTIME_DIR` missing, or does the socket not exist? Without
  `--expose-wayland` the result is the same as the laptop's no-socket control.
- `video-driver`: SDL picked a driver other than `wayland`.
- `window`: EGL init failed. The `sdl_error` names the step, for example "Could not initialize
  EGL".
- `gl-context`: no ES 3.0 EGL config or context.
- `gl-version` or `glsl-version`: the context is not ES 3.x.
- `gl-renderer`: Mesa fell back to a software rasteriser, or the renderer is not Zink.
- `gl-program`: the shader compiler failed. The log is in the line.
- `gl-framebuffer`, `gl-draw` or `gl-draw-after-swap`: the default framebuffer is incomplete,
  or read back the wrong colours. The line shows centre and corner pixels against the expected
  ones. A channel swap shows here.
- `gl-present` or `gl-errors`: presenting raised a GL error.
- `timeout`: a hang. The `stage=` value names the step, for example `gl-swap`, a swap that never
  returned.
- `crash`: a fatal signal, with its stage.

In a `PASS` run, `warn=gamepad` means SDL sees no standard gamepad. Check the input broker's
virtual pad and its v3 map. `warn=audio` means OpenAL could not open or play the default device:
the line names the step and the AL/ALC error. Neither stops the window, but each is recorded.

On the laptop or in CI the same probe runs from a staged app root with
`<app root>/probe-launch [options]`, which sets `MBHAXE_PROBE=1` and execs `launch`.
`tests/pf-probe/run.sh` drives the positive run, the negative controls and the qemu-aarch64
smoke, and `tests/pf-probe/ci.sh` is the CI step.

## 5. Launch

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

## 6. Remove

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
descriptor needs (pinned URL, size and SHA256; `destination`; `strip_components` with GNU tar
rules; refusal of unsafe members; atomic install; no change on refusal).

What the release layout looks like (tsp-0qwbh.9, the MBHaxe side of gap 1):

- `app.toml` declares `[fetch] destination = "var"` with `dest = "data"`, so the executor installs
  the game data at `/var/lib/pocketforge/apps/org.pocketforge.mbhaxe/data`, and nothing goes into
  the read-only app directory.
- The game takes its data directory from `MBHAXE_DATA_DIR` (`src/DataDir.hx`): a real
  directory called `data`, not a symlink (otherwise it stops at start with a message on stderr and
  exit status 2). It takes heaps' converter cache from `MBHAXE_CACHE_DIR`; without that variable, a
  data directory whose `data/tmp/` cannot be written sends the cache to
  `$XDG_CACHE_HOME/mbhaxe/converted`. With neither variable set, the game behaves as upstream does.
- `launch` sets `MBHAXE_DATA_DIR` to `/var/lib/pocketforge/apps/<id>/data` when that exists. It
  finds the path as the parent of the `XDG_STATE_HOME` that `pf-app@` sets. It always sets
  `MBHAXE_CACHE_DIR` under `XDG_CACHE_HOME`, so the game never writes to its data.
- On the laptop, `stage-app.sh --data-layout release` stages that layout
  (`var/lib/pocketforge/apps/<id>/data`, no `data/` in the app root), and
  `tests/launch-smoke.sh` runs it with the data beside the state directory, optionally read-only
  (`--readonly-data`). `tests/data-dir-check.sh` covers the refusals: a symlinked, missing or
  wrongly named data directory in either location.

What remains is platform-side (runtime, image and platform repositories, tracked from
tsp-mc9m.41.996.4 and tsp-ziac.4):

1. Destination access (the platform half of gap 1). `pf-app@.service` already lists
   `/var/lib/pocketforge/apps/%i` in `ReadWritePaths=`. However, `pf-app-launch`'s Landlock
   policy (runtime `crates/pf-app-launch/src/policy.rs`, `derive_policy`) grants only the app
   directory and `XDG_CONFIG_HOME`/`XDG_STATE_HOME`/`XDG_CACHE_HOME`, so the game cannot read
   `/var/lib/pocketforge/apps/<id>/data` until the policy grants the fetch destination
   (read-only is enough). The `"home"` destination (`~/.local/share/<dest>`) is no alternative:
   the unit has `ProtectHome=yes`. Until the grant lands, the dev install keeps `data/` in the app
   directory.
2. Member selection. `strip_components = 2` already drops everything outside `data/`
   (the upstream binaries sit at depth 2). An explicit include filter would say so directly and
   survive a change in the upstream layout. The schema has none.
3. The JSON schema (`abi/app.schema.json`) does not list `[requirements]`, although the
   Python validator and the runtime resolver both accept it.
4. No on-device fetch executor exists yet. `pf-fetch.py` is the reference: it runs on the
   staging host, and the device has no Python.
