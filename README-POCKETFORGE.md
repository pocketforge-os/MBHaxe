# MBHaxe for PocketForge OS

This is the PocketForge OS fork of [RandomityGuy/MBHaxe](https://github.com/RandomityGuy/MBHaxe)
(branch `mbu-port`, the Marble Blast Ultra port). It builds the game for Linux handhelds that render
through OpenGL ES 3.0 (EGL + SDL2), such as the Allwinner A133 device, and for x86_64 Linux for testing.
The default branch is `pocketforge`; `upstream` is RandomityGuy/MBHaxe. The tree is pre-alpha.

## Dependencies

The build uses the PocketForge forks of [heaps](https://github.com/pocketforge-os/heaps) and
[hashlink](https://github.com/pocketforge-os/hashlink), pinned by commit. `LOCK.md` lists every input
with its version, commit or SHA256; `pocketforge/deps.lock` holds the same pins for scripts.

```sh
pocketforge/setup-deps.sh /path/to/deps   # default: ./.pf-deps (gitignored)
. /path/to/deps/env.sh
haxe compile-linux-gles.hxml              # writes native/marblegame.c
```

`setup-deps.sh` downloads Haxe 4.3.6, Neko 2.4.0 and the lib.haxe.org zips and checks each SHA256,
fetches the two forks at their pinned commits and checks `HEAD`, and links them into a private haxelib
repository with `haxelib dev`. It writes nothing outside the deps directory.

The script handles the pins because hxml `-lib` cannot name a git commit, and hlsdl and hlopenal are
subdirectories of the hashlink repository. The same hashlink checkout also supplies the C runtime and
hdlls (built with CMake and `-DWITH_SDL_GLES=ON`) and the headers for compiling `native/marblegame.c`.

## Building the game (pipeline)

`pocketforge/build/` turns pinned inputs into a gated, deterministic tarball in one step:

```sh
# reference build, in the builder container (podman or nerdctl; never Docker-branded tooling)
pocketforge/build/container.sh --work /path/to/work --arch aarch64              # device build
pocketforge/build/container.sh --work /path/to/work --arch x86_64 --variant diag # harness build
# same script without a container (host gcc; gates still apply, hashes differ from the reference)
pocketforge/build/build.sh --arch aarch64 --work /path/to/work
```

Steps, all from pins in `LOCK.md`, `pocketforge/deps.lock` and `pocketforge/build/pins.lock`:

1. Builder (`Containerfile`, `toolchain.sh`): Debian bookworm base image pinned by digest, every
   package from Debian snapshot 20260601T000000Z (InRelease signatures checked against
   `pocketforge/build/keys/`), bookworm gcc 12 native and aarch64 cross.
2. `setup-deps.sh`: Haxe, Neko, haxelibs and the heaps/hashlink forks.
3. `sysroot.sh`: bookworm arm64/amd64 sysroot from the same snapshot (rootless, isolated apt).
4. hashlink `libhl` + hdlls with `-DWITH_SDL_GLES=ON -DWITH_HL_JIT=OFF`, then Haxe->C and the
   single-TU `marblegame` link with rpath `$ORIGIN`. A compiler wrapper confines headers, start
   files and libraries to the sysroot (Ubuntu's cross gcc otherwise links its own glibc 2.39), and
   `-ffile-prefix-map` keeps build paths out of the binaries.
5. `gates.sh`: highest GLIBC symbol version <= 2.36 (bookworm), no GLIBCXX/CXXABI/GCC version above
   gcc 12, every DT_NEEDED in `needed.allow`, never libGL, only `$ORIGIN` rpaths, right ELF machine
   and loader. `tests/gates-test.sh` is the red/green test: stub and real probes that must trip each
   gate, including a probe linked by the unwrapped host compiler (fails on Ubuntu 24.04's glibc 2.39).
6. Output in `WORK/out/`: `mbhaxe-pf-<version>-<arch>[-diag].tar.zst` (top-level dir `mbhaxe-pf/`:
   `marblegame`, `libhl.so.1`, the six hdlls, `licenses/`, `SHA256SUMS`, `MANIFEST.json`), the
   manifest beside it, a `.sha256`, and `<arch>-<variant>.env` with key=value results (artifact,
   sha256s, stage dir). The manifest records per-file sha256, the MBHaxe/hashlink/heaps commits,
   the lock-file digests, the builder package-set digest and the sysroot .deb list digest.
   `<version>` is `<upstream version>-pf.<commit date>.<commit sha10>`.

Two builds of the same commit are byte-identical (tarball included). The CI workflow
(`pocketforge/build/ci/pocketforge-build.yml`, logic in `pocketforge/build/ci.sh`) builds aarch64
twice on separate runners and compares, and builds the x86_64 `pf_diag` harness binary. It is staged
there until this repository is admitted to the pf-public runner class; activating it is a move to
`.github/workflows/`. Artifacts are
never stored on GitHub: `pocketforge/build/publish-mm.sh` publishes a clean build's tarball and
manifest to the PocketForge content-addressed artifact store from a trusted host.

## PocketForge app (`org.pocketforge.mbhaxe`)

`pocketforge/app/` packages the build as a PocketForge app:

- `app.toml`: the schema-2 descriptor. GLES 3.0, `buttons` + `stick` (the runtime vocabulary has no
  `gamepad` token), audio + input, no network, `memory_mib` a placeholder until the device window
  measures it. `[fetch]` pins the upstream `1.3.2-mbu` Linux release asset by URL, SHA256 and size
  and installs only its `data/`, at `destination = "var"` (`/var/lib/pocketforge/apps/<id>/data`).
- `launch`: the `[launch].exec` wrapper. It puts the bundled `lib/` on `LD_LIBRARY_PATH`, sets
  `ALSOFT_CONF`, `SDL_VIDEODRIVER=wayland`, `TMPDIR`, `MBHAXE_CACHE_DIR` and, for fetched data,
  `MBHAXE_DATA_DIR`, and runs the game from a writable directory under `XDG_STATE_HOME` (the app
  directory is read-only under `pf-app@`).
- `bundle.lock`: libopenal1, libsndio7.0, libturbojpeg0, libvorbisfile3 and libuv1, the same
  snapshot `.debs` the sysroot links against. The image does not install them, and bundling them
  leaves the image unchanged. `image-sonames.allow` lists what the image provides.
- `pf-fetch.py`: the reference `[fetch]` implementation (pinned size and SHA256, GNU
  `strip_components`, unsafe members refused, atomic install, nothing changed on refusal);
  `tests/test-fetch.sh` is its red/green test.
- `stage-app.sh`, `tests/launch-smoke.sh`, `tests/data-dir-check.sh` and `DEV-INSTALL.md`: laptop
  staging (`--data-layout dev`, data in the app directory, or `release`, data at the `[fetch]`
  destination), the launch smoke under a private weston, the refusals for a bad data directory, and
  the device dev install and removal.

```sh
pocketforge/build/container.sh --work /path/to/work --arch aarch64 --app-root
# or, from an existing build: pocketforge/build/app-root.sh --build WORK/out/aarch64-product.env
```

`app-root.sh` verifies the build artifact (SHA256 and the inner `SHA256SUMS`) and downloads the
pinned `.debs` by SHA256 and size. It copies each library (dereferenced) into `lib/` and its Debian
`copyright` into `licenses/debian/`, and adds `app.toml`, `launch` and `alsoft.conf`. It then runs
`gates.sh` over the top level and `lib/` with a NEEDED closure allowlist (the image's sonames plus
every shipped ELF). The output is `org.pocketforge.mbhaxe-<version>-<arch>[-diag].app.tar.zst`
(top-level dir `org.pocketforge.mbhaxe/`, the device's `/opt/pocketforge/apps/org.pocketforge.mbhaxe`)
with `APP-MANIFEST.json`: bundled package, version, `.deb` SHA256 and file SHA256, plus every file's
SHA256, size and mode. The tarball is deterministic like the build tarball.

## Build modes

`compile-linux-gles.hxml` sets:

- `-D gles`: requests an OpenGL ES 3.0 context without MSAA. Pair it with a hashlink built with
  `-DWITH_SDL_GLES=ON`, so that `sdl.hdll` links libGLESv2 and not libGL.
- `-D offline`: online features are off. Http requests fail locally without opening a socket, and the
  master server websocket is never opened, so leaderboards, Marbleland, multiplayer and the changelog
  check stay off. The `stubs/datachannel` stub replaces hxDatachannel, so no WebRTC native is linked.
- `-D handheld`: the handheld build; see [Handheld build](#handheld-build).

You can also add:

- `-D pf_diag`: regression-harness diagnostics in `Main.hx`, controlled by environment variables:
  mission autoplay, back-buffer PNG dumps, `glGetError` counting and a fixed exit frame, plus a
  `[diag]` log of menu and level state and screenshots on request (`MBHAXE_SHOT_REQ`) for the gamepad
  walkthrough. This define is never part of the default build.
- `-D pf_highp`: highp fragment shaders; see [Precision](#precision).

## Handheld build

`-D handheld` makes the game usable on a handheld with only its gamepad, and `-D offline` hides what
needs the network:

- Menus: the main menu ends with Quit in place of upstream's Return to Arcade, and the Ko-fi and
  GitHub buttons are gone. `-D offline` also hides Multiplayer, Leaderboards, the changelog, Custom
  Levels (Marbleland), the level-select Leaderboard button and the end-of-level score submission
  with its name prompt. Options hide Import & Export (it needs a file dialog), Keyboard Controls and
  the resolution choices (the compositor owns the output); Key Bindings is called Controls.
- Everything is reachable with a gamepad: no screen needs a keyboard or mouse. Name dialogs that
  remain (replays) prefill a default name, and the gamepad's confirm button accepts it.
- Quit and window close (SDL_QUIT, which SDL also raises on SIGTERM and SIGINT) save settings, close
  OpenAL and exit with status 0.
- Fresh settings: vsync on, reflection detail 1 (sky only), render scale 100% at the window size
  (1280x720 on the device), no frame-rate cap. Video Options adds Render Scale (50%, 75%, 100%;
  the 3D scene renders at that fraction of the window and the 2D interface stays sharp) and Frame
  Rate Cap (Off, 30, 60 FPS; it sleeps after each present).
- Game data: `data/` must be a real directory next to the executable, or the directory that
  `MBHAXE_DATA_DIR` names (see [Data directory](#data-directory)). A missing data directory or a
  symlink stops the game at start with a message on stderr and exit status 2 (heaps resolves
  resource paths with realpath, so a symlinked tree loads nothing).
- Settings (`settings.json`) and `console.log` are written to the current directory, so the launcher
  should start the game in a writable per-user directory.

The gamepad is the device's Xbox 360 identity pad (SDL's stock mapping): A confirms, B goes back,
Start pauses, the d-pad and left stick move the selection. There is no L3/R3, L2/R2 are digital, and
Guide is reserved by the system and never used.

### Audio

`pocketforge/app/alsoft.conf` configures OpenAL Soft for the device: the ALSA backend only, on the
`default` PCM (plug, softvol, dmix at 48 kHz S16_LE), mixing at 48 kHz stereo with 1024-frame periods
so ALSA does not resample. The app package ships it beside the game, and the launcher sets
`ALSOFT_CONF=<app dir>/alsoft.conf`. OpenAL Soft reads `ALSOFT_CONF` after the system and per-user
config files, so its keys win.

### Precision

On OpenGL ES, heaps declares `precision mediump float;` in fragment shaders and `highp` in vertex
shaders. `-D pf_highp` (implemented in the pocketforge-os/heaps fork, `hxsl.GlslOut.FRAGMENT_HIGHP`)
makes fragment shaders `highp` too, for comparing FP16 artifacts on GPUs that honour mediump. It is
not part of the default build.

### Gamepad walkthrough

`pocketforge/walkthrough/gamepad_walkthrough.py` checks the handheld menus with a gamepad only. It
creates a virtual pad with the device's identity through `/dev/uinput` (write access is enough, for
example a logind seat ACL; no root), runs a `-D handheld -D pf_diag` build, and walks main menu, Help
& Options, Video Options, Single Player, level start, pause, restart, Main Menu and Quit. Every step
is confirmed from the game's `[diag]` state log, a screenshot is taken at each step, and the run
passes only if the game exits with status 0:

```sh
python3 pocketforge/walkthrough/gamepad_walkthrough.py --game-dir <dir with marblegame and data/> \
    --shot-dir <dir> --env WAYLAND_DISPLAY=<socket> --env SDL_VIDEODRIVER=wayland ...
```

## Data directory

HashLink desktop builds, not only `-D handheld`, read two environment variables
(`src/DataDir.hx`):

- `MBHAXE_DATA_DIR`: the game data directory, used instead of `data/` next to the executable. It
  must be a real directory called `data`, because resources resolve as `data/...` under its
  parent. A symlink, a missing directory or another name stops the game at start with a message
  on stderr and exit status 2.
- `MBHAXE_CACHE_DIR`: heaps' converter cache (fonts converted at first use), used instead of
  `data/tmp/`. The game creates the directory.

With neither variable set, a desktop build behaves as upstream does. If either is set, and always
in the `-D handheld` build, the data directory is checked at start. If `data/tmp/` cannot be
written and `MBHAXE_CACHE_DIR` is unset, the cache moves to `$XDG_CACHE_HOME/mbhaxe/converted`
(default `~/.cache`), so read-only game data works. Settings, `console.log`, replays and screenshots
stay in the current directory.

The PocketForge app's `launch` uses both variables: data fetched to
`/var/lib/pocketforge/apps/<id>/data` (`[fetch] destination = "var"`), and the cache under
`XDG_CACHE_HOME`. See `pocketforge/app/DEV-INSTALL.md`.

## Removed

Analytics, the Umami telemetry module and all of its call sites, are deleted from the source. No
build of this tree sends telemetry.

## Assets

PocketForge redistributes no game assets. The `data/` directory stays as upstream ships it in this
repository, and PocketForge adds no assets. PocketForge images and artifacts, including the app
root, do not bundle game data. The app's `[fetch]` downloads it from the pinned upstream release
(`MBHaxe-Ultra-Linux.tar.gz` of `1.3.2-mbu`, see `LOCK.md`) on the machine that installs the app.

## Contributing

Commits carry `Assisted-by: LLM` where an LLM assisted. Agents never add `Signed-off-by`.
