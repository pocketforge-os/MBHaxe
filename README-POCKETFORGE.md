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
The bookworm cross-build pipeline (sysroots, compiler wrappers, artifact upload) is separate work;
`LOCK.md` records the exact build configuration.

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
