# PocketForge build lock for MBHaxe

Every input to the PocketForge build of this tree, pinned by version, commit or SHA256.
`pocketforge/deps.lock` is the machine-readable copy that `pocketforge/setup-deps.sh` consumes;
change both together. Origin: the tsp-0qwbh laptop spike (2026-10-18), re-pinned to the
pocketforge-os forks in tsp-0qwbh.1.

## Toolchain

GitHub publishes no digest for these release assets; the SHA256 values were computed locally
when they were first downloaded (2026-10-18) and are verified on every fetch.

| item | URL | SHA256 |
|---|---|---|
| Haxe 4.3.6 linux64 | https://github.com/HaxeFoundation/haxe/releases/download/4.3.6/haxe-4.3.6-linux64.tar.gz | `810e1752c8eb3065dbff54c050b20a712ce276f407741f0bf94696b454a597ad` |
| Neko 2.4.0 linux64 (haxelib runtime only) | https://github.com/HaxeFoundation/neko/releases/download/v2-4-0/neko-2.4.0-linux64.tar.gz | `0a57a3eca92359da75eb0500a15766319f45e8f9eb7cc105f9f40391946b2ce7` |

Host compilers used for the reference builds (Ubuntu 24.04, not shipped): gcc and
aarch64-linux-gnu-gcc 13.3.0-6ubuntu2~24.04.1, binutils 2.42, cmake 3.28.3, ninja 1.13.0.
They are wrapped so they use only the bookworm sysroot's headers, start files and libraries
(Ubuntu's cross gcc otherwise picks up its own glibc 2.39 headers and libs before `--sysroot`).

## Source

| repo | fork (default branch `pocketforge`) | upstream base | pinned head |
|---|---|---|---|
| MBHaxe | https://github.com/pocketforge-os/MBHaxe | RandomityGuy/MBHaxe `mbu-port` @ `ad0c7851c8b5dc9471c6ac5ba7ded0064ad4a23f` | this commit |
| hashlink | https://github.com/pocketforge-os/hashlink | RandomityGuy/hashlink `master` @ `e3e864e3fc9633cf448f13e333ebd5dca0866d11` | `be2de2bac3b65b1c9266914c34163bbabd653a14` |
| heaps | https://github.com/pocketforge-os/heaps | RandomityGuy/heaps `master` @ `9317e1a4ac6bc6936a7d9062555081afedadc0ae` | `1016de5b0fe560e25b58b8be3fb0b9caf35cf12f` |

PocketForge series on top of each base:

- hashlink: `60c8c362` hl.h ARM breakpoint for hl_debug_break on Linux aarch64/arm;
  `82fc09f6` optional x86-only JIT `hl` executable (WITH_HL_JIT); `3bc54f24` Linux OpenGL ES 3 mode
  (WITH_SDL_GLES / HL_GLES); `731abd82` executable path from /proc/self/exe before `$_`;
  merge `be2de2ba`.
- heaps: `6371a992` GlDriver BGRA textures and cube maps valid on OpenGL ES 3; merge `1016de5b`.
- MBHaxe: see `git log ad0c7851..pocketforge`.

hxDatachannel is not used: `stubs/datachannel/` carries its platform-neutral base classes, copied
unmodified from RandomityGuy/hxDatachannel `76a6ee4638881355a95155fbef3583039941cde9` (MIT), plus a
native-free RTC stub.

## haxelib

Installed into a private repository (`HAXELIB_PATH=<deps>/haxelib`); the global haxelib
repository is never used. Tree SHA256 = `find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum`
inside the installed version directory.

| lib | pin | zip SHA256 | installed tree SHA256 |
|---|---|---|---|
| format | 3.8.0, https://lib.haxe.org/files/3.0/format-3,8,0.zip | `ea3a6725ee707d54965550d5331c8b1eab5c548c35b3680622fb0ffa15b509fd` | `997ea09817a237f97f7e971e0f01ab3b58ce5a43b2d1c41a5cd54c9f6feb493f` |
| colyseus-websocket | 1.0.15, https://lib.haxe.org/files/3.0/colyseus-websocket-1,0,15.zip | `23020faa1de9ab33e6bef87c493e2a1c526377c095be23f666a0352b9761cf3d` | `7ac107d6d2eecf008c9dd171d84fac6044b5f4a395f5a492bf041aa31fe4497b` |
| heaps | dev -> pocketforge-os/heaps @ `1016de5b0fe560e25b58b8be3fb0b9caf35cf12f` | git | git |
| hashlink | dev -> pocketforge-os/hashlink @ `be2de2ba...` `other/haxelib` | git | git |
| hlsdl | dev -> pocketforge-os/hashlink @ `be2de2ba...` `libs/sdl` | git | git |
| hlopenal | dev -> pocketforge-os/hashlink @ `be2de2ba...` `libs/openal` | git | git |

## Debian bookworm sysroots (amd64, arm64)

- Archive: https://snapshot.debian.org/archive/debian/20260601T000000Z and
  https://snapshot.debian.org/archive/debian-security/20260601T000000Z, suites bookworm,
  bookworm-updates and bookworm-security, component main.
- InRelease signatures verified by apt against a keyring built from https://ftp-master.debian.org/keys/:
  archive 12 `B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8`, release 12 `4D64FEC119C2029067D6E791F8D2585B8783D481`,
  archive 11 `1F89983E0081FDE018F3CC9673A4F27B8DD47936`, plus the bookworm/bullseye security keys.
- Requested packages (apt resolves the rest; 227 arm64 / 225 amd64 .debs, no recommends):
  libc6-dev libsdl2-dev libegl-dev libgles-dev libopenal-dev libpng-dev libturbojpeg0-dev
  libvorbis-dev libogg-dev zlib1g-dev libuv1-dev libmbedtls-dev.
- Key versions: libc6 2.36-9+deb12u14, libsdl2 2.26.5+dfsg-1, libglvnd (libgles2/libegl1) 1.6.0-1,
  libopenal1 1:1.19.1-2, libturbojpeg0 1:2.1.5-2, libvorbisfile3 1.3.7-1, libpng16-16 1.6.39-2+deb12u5,
  zlib1g 1:1.2.13.dfsg-1, libuv1 1.44.2-1+deb12u1.
- Per-.deb SHA256 lists are preserved with the spike evidence (`logs/debs-{arm64,amd64}.sha256`); the
  committed sysroot build is tsp-0qwbh.2.

## Build configuration

- hashlink: `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DWITH_SDL_GLES=ON -DWITH_SQLITE=OFF -DWITH_VIDEO=OFF -DBUILD_TESTING=OFF`
  (WITH_HL_JIT defaults OFF on aarch64).
- game: `haxe compile-linux-gles.hxml` (product) or `haxe compile-linux-gles.hxml -D pf_diag` (regression
  harness), then a single-TU `cc -O2 -std=c11 -D_GNU_SOURCE -fno-strict-aliasing -I native -I <hashlink>/src`
  of `native/marblegame.c`, linked against the hdlls and `-lhl -lSDL2-2.0 -luv -lm -lpthread`, rpath `$ORIGIN`.

## Reference artifacts (tsp-0qwbh.1 reproduction, 2026-10-19)

Built from fresh clones of the forks at the SHAs above. Bit-reproducibility is not yet a requirement;
the hdlls and libhl embed build paths and differ between build directories.

| artifact | SHA256 |
|---|---|
| amd64 `marblegame` (product) | `2b33367a6fd2871b29ccd522bfba64c95cb38ed9866310d919ac6e4568194cae` |
| amd64 `marblegame` (`-D pf_diag`) | `974cc7e3346202aa06de25a1bdb73e477ba9f1803f684067c2880f6a627dc967` (same as the spike diag build) |
| arm64 `marblegame` (product) | `f1d87ffcb548397278c9897080cb9a954e8aae1396d1901336723228f14f34d3` (same as the spike product build) |

sdl.hdll NEEDED (both arches): libSDL2-2.0.so.0, libhl.so.1, libGLESv2.so.2, libc.so.6 (no libGL).
Highest GLIBC symbol version over marblegame, libhl and all hdlls: GLIBC_2.34 (device bookworm has 2.36).
