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

Two builds of the same commit are byte-identical (tarball included). CI
(`.github/workflows/pocketforge-build.yml`, logic in `pocketforge/build/ci.sh`) builds aarch64 twice
on separate runners and compares, and builds the x86_64 `pf_diag` harness binary. Artifacts are
never stored on GitHub: `pocketforge/build/publish-mm.sh` publishes a clean build's tarball and
manifest to the PocketForge content-addressed artifact store from a trusted host.

## Build modes

`compile-linux-gles.hxml` sets:

- `-D gles`: requests an OpenGL ES 3.0 context without MSAA. Pair it with a hashlink built with
  `-DWITH_SDL_GLES=ON`, so that `sdl.hdll` links libGLESv2 and not libGL.
- `-D offline`: online features are off. Http requests fail locally without opening a socket, and the
  master server websocket is never opened, so leaderboards, Marbleland, multiplayer and the changelog
  check stay off. The `stubs/datachannel` stub replaces hxDatachannel, so no WebRTC native is linked.
- `-D handheld`: fresh settings default to vsync on and reflection detail 1.

You can also add:

- `-D pf_diag`: regression-harness diagnostics in `Main.hx`, controlled by environment variables:
  mission autoplay, back-buffer PNG dumps, `glGetError` counting and a fixed exit frame. This define is
  never part of the default build.

## Removed

Analytics, the Umami telemetry module and all of its call sites, are deleted from the source. No
build of this tree sends telemetry.

## Assets

PocketForge redistributes no game assets. The `data/` directory stays as upstream ships it in this
repository, and PocketForge adds no assets. PocketForge images and artifacts do not bundle game
data. The user-installed app downloads the data from a pinned upstream release.

## Contributing

Commits carry `Assisted-by: LLM` where an LLM assisted. Agents never add `Signed-off-by`.
