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

### Builder container (`pocketforge/build/`, tsp-0qwbh.2)

The reference builds run in the builder container; `pocketforge/build/pins.lock` is the
machine-readable copy of this section.

| item | pin |
|---|---|
| base image | `docker.io/library/debian:bookworm-20260518@sha256:ed4fcc40bb1162b6d2d32e7bec15044d13963779abbe63f67f1cd62b06220519` (OCI index; amd64 used) |
| packages | Debian snapshot `20260601T000000Z` (same as the sysroots below), base dist-upgraded to it |
| compilers | gcc-12 12.2.0-14+deb12u1 (x86_64), gcc-12-aarch64-linux-gnu 12.2.0-14cross1 |
| tools | binutils 2.40-2, cmake 3.25.1-1, ninja-build 1.11.1-2~deb12u1, tar 1.34+dfsg-1.2+deb12u1, zstd 1.5.4+dfsg2-5 |

The full builder package set is written to `/etc/pf-builder-packages.txt` in the image and its
SHA256 is recorded in every build manifest. Both compilers are wrapped (`pf_write_toolchain` in
`pocketforge/build/lib.sh`) so they use only the bookworm sysroot's headers, start files and
libraries. The wrapper matters most on Ubuntu hosts, whose cross gcc picks up its own glibc 2.39
headers and libs before `--sysroot`. Host (non-container) builds use the same wrapper around the
host gcc; the tsp-0qwbh.1 references below came from Ubuntu 24.04 gcc 13.3.0-6ubuntu2~24.04.1.

Debian signing keys in `pocketforge/build/keys/` (from https://ftp-master.debian.org/keys/):

| file | fingerprint | SHA256 |
|---|---|---|
| archive-key-11.asc | `1F89983E0081FDE018F3CC9673A4F27B8DD47936` | `0b7dc94b880f0b63e2093394b113cafd870badb86e020a35614f49b9d83beb1e` |
| archive-key-11-security.asc | `AC530D520F2F3269F5E98313A48449044AAD5C5D` | `716e79393c724d14ecba8be46e99ecbe1b689f67ceff3cb3cab28f6e69e8b8b8` |
| archive-key-12.asc | `B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8` | `c2a9a16fde95e037bafd0fa6b7e31f41b4ff1e85851de5558f19a2a2f0e955e2` |
| archive-key-12-security.asc | `05AB90340C0C5E797F44A8C8254CF3B5AEC0A8F0` | `74f81645b4e3156d1e9a88c8dd9259271b89c7099d64af89a2a6996b592faa1f` |
| release-12.asc | `4D64FEC119C2029067D6E791F8D2585B8783D481` | `521e9f6a9f9b92ee8d5ce74345e8cfd04028dae9db6f571259d584b293549824` |

## Source

| repo | fork (default branch `pocketforge`) | upstream base | pinned head |
|---|---|---|---|
| MBHaxe | https://github.com/pocketforge-os/MBHaxe | RandomityGuy/MBHaxe `mbu-port` @ `ad0c7851c8b5dc9471c6ac5ba7ded0064ad4a23f` | this commit |
| hashlink | https://github.com/pocketforge-os/hashlink | RandomityGuy/hashlink `master` @ `e3e864e3fc9633cf448f13e333ebd5dca0866d11` | `be2de2bac3b65b1c9266914c34163bbabd653a14` |
| heaps | https://github.com/pocketforge-os/heaps | RandomityGuy/heaps `master` @ `9317e1a4ac6bc6936a7d9062555081afedadc0ae` | `8510842b438d8cc05e049ba954d735641fe5d985` |

PocketForge series on top of each base:

- hashlink: `60c8c362` hl.h ARM breakpoint for hl_debug_break on Linux aarch64/arm;
  `82fc09f6` optional x86-only JIT `hl` executable (WITH_HL_JIT); `3bc54f24` Linux OpenGL ES 3 mode
  (WITH_SDL_GLES / HL_GLES); `731abd82` executable path from /proc/self/exe before `$_`;
  merge `be2de2ba`.
- heaps: `6371a992` GlDriver BGRA textures and cube maps valid on OpenGL ES 3; merge `1016de5b`;
  `4a4b6f5f` GlslOut `-D pf_highp` highp fragment precision; `6262f5ac` GLSL precision test
  (`pocketforge/tests/`); merge `8510842b`.
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
| heaps | dev -> pocketforge-os/heaps @ `8510842b438d8cc05e049ba954d735641fe5d985` | git | git |
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
- Built by `pocketforge/build/sysroot.sh` (rootless apt isolated from the host's apt configuration,
  `dpkg-deb -x`, absolute symlinks made relative). Each build writes the per-.deb SHA256 list
  (`debs.sha256`) and the manifest records its SHA256. Snapshot URLs are plain http, as Debian's
  defaults: integrity comes from the signed InRelease files and the hashes they sign.

## Build configuration

`pocketforge/build/build.sh` is the authoritative recipe; in short:

- hashlink: `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DWITH_SDL_GLES=ON -DWITH_SQLITE=OFF -DWITH_VIDEO=OFF -DBUILD_TESTING=OFF -DWITH_HL_JIT=OFF`
  with the sysroot toolchain file and `-ffile-prefix-map` for the work and source directories.
- game: `haxe compile-linux-gles.hxml` (product) or `haxe compile-linux-gles.hxml -D pf_diag` (regression
  harness), with the `-hl` output redirected into the work directory, then a single-TU
  `cc -O2 -std=c11 -D_GNU_SOURCE -fno-strict-aliasing` of `marblegame.c` (`-I <gen> -I <hashlink>/src`),
  linked against the hdlls, `libhl.so.1` and `-lSDL2-2.0 -luv -lm -lpthread`, rpath `$ORIGIN`, `--as-needed`.
- gates: `pocketforge/build/gates.sh` (GLIBC <= 2.36, gcc 12 C++ ceilings, `needed.allow`, no libGL,
  `$ORIGIN`-only rpaths).

## App root and game data (tsp-0qwbh.5)

Game data, `pocketforge/app/app.toml` `[fetch]` (never committed, uploaded or bundled; fetched on
the installing machine):

| item | value |
|---|---|
| URL | https://github.com/RandomityGuy/MBHaxe/releases/download/1.3.2-mbu/MBHaxe-Ultra-Linux.tar.gz |
| SHA256 | `515487e0f9eac03dd660ddedc856bee989c7921464aa96e3cb4f5407267573f2` (equals GitHub's asset digest) |
| size | 57876762 bytes |
| extraction | `tar.gz`, `strip_components = 2`, `dest = "data"`: the 752 files of `data/` only |

`1.3.2-mbu` (published 2026-10-18) is the newest `-mbu` release as of 2026-10-19 (then 1.3.1-mbu,
1.3.0-mbu). Its `data/` is byte-identical to this repository's `data/` (`diff -r`, including
`data/tmp`), and `pf-fetch.py` installs it with upstream's mtimes, so heaps' converter cache
(`data/tmp/cache.dat`) stays valid and nothing is written beside the read-only executable.

Bundled libraries, `pocketforge/app/bundle.lock`: Debian snapshot 20260601T000000Z, the same
`.debs` as the build sysroot (`app-root.sh` refuses any other when run from `build.sh --app-root`).
Missing from the image package closure (image `0e835bb0` rootfs-packages.txt,
rootfs-packages-mainline.txt, rootfs-packages-a133-open-7x-gpu.txt plus the gamescope runtime,
resolved against the snapshot): libopenal1, libturbojpeg0, libvorbisfile3, libuv1 and libopenal1's
dependency libsndio7.0. Their own dependencies (libasound2, libbsd0, libmd0, libvorbis0a, libogg0,
libc6) are in the image.

| package | version | arm64 .deb SHA256 | arm64 file SHA256 | amd64 .deb SHA256 | amd64 file SHA256 |
|---|---|---|---|---|---|
| libopenal1 (`lib/libopenal.so.1`) | 1:1.19.1-2 | `848f7cb93823c780ab58c0da67535316ef797666934d06ed6d64e902d4e2df11` | `9bcff6eeedfd40543a31d0d39399b4c1390b51e9ee2b1c9db1399123222eb98b` | `b027d29d37786e4dacb21a7268e911566efb09f5a20facc66c57dd22a7c31e83` | `4c0acaa919cbdd14830d1ce30dab448cfc33aa6262dd49f7b605aa6bbd07c889` |
| libsndio7.0 (`lib/libsndio.so.7.0`) | 1.9.0-0.3+b2 | `e7c787895eacf8363a4dea6a0cb3237a78857691d8d53f60a1a3ffeea3819808` | `1dc7015db86b9bf122384c7e9799d6980c02ff7ed8173bd9c5a62680bdd06e47` | `c4cc979126cc558549db25d42e2849a9d5dcdf7928e0ece69c38c374021a078b` | `c2a65f3e29b49ab7d6a730bc16f9e6cb2da89421e4c8b66c9171637453f452f8` |
| libturbojpeg0 (`lib/libturbojpeg.so.0`) | 1:2.1.5-2 | `85a0914484efe5bfa51c79bc45ccb5133373f65a94e7bd867c89a6a45188d148` | `a953fad5cc022e6d728084973371401cdb6e74cce66d8c334d5caf8842ba3468` | `466d8e2a6b501c43d9064e19972465e7703611a9c344f0244cb3bedbc2a328bc` | `4292207ec19b9543d29e13a71263ecd6ad89a28f880e5d201c76cfb168e6d056` |
| libvorbisfile3 (`lib/libvorbisfile.so.3`) | 1.3.7-1 | `f8f418e15f99905d4a2d532617511a11d700e814f8ead1a883deea2f7241970c` | `719c0288d8fc1b553d084be0c55ff72917f8159de438686d3701c97128128358` | `68f84034ae1c9fa0ab6a45f5b6c406a50faae4421f0d78874260aefa2df68efc` | `893839d05f0d02ce9f4beb8a24a5dc8d7feda2ab85cee1eaeaf390204daa9703` |
| libuv1 (`lib/libuv.so.1`) | 1.44.2-1+deb12u1 | `96022663d045c9599cf664b98db45e254b05b0661860ad89f1501b7dbf0da258` | `74e5a3690dcabe793ccde78521843cb1de85069b859d46d15dca8301f3ca6e3f` | `204f0e13354b44e6d19317887a53dab6f26696e8d95838db970b81f2a393f7fd` | `c85c14dbe2fc8d38cedcacf3a7f9b4f71cd9fc40b2ea5f29eb6b8e929cb32bfb` |

Licences shipped in `licenses/`: MBHaxe (MIT), hashlink (MIT), heaps (MIT), Haxe standard library,
mbedtls (static in ssl.hdll), minimp3, colyseus-websocket, the format haxelib (BSD-2; its zip has no
licence file, so `pocketforge/build/licenses/haxe-format.txt` is upstream's LICENSE at
HaxeFoundation/format `914c2fa2b6a0ff7b0786aec5ebabbb7a622a0b9d`) and hxDatachannel (MIT,
`stubs/datachannel/LICENSE` from RandomityGuy/hxDatachannel
`76a6ee4638881355a95155fbef3583039941cde9`), plus each bundled package's Debian `copyright` in
`licenses/debian/`.

## Reference artifacts (pipeline, builder container, tsp-0qwbh.2)

`pocketforge/build/container.sh` from the pins above. Builds are bit-reproducible: two runs in fresh
work directories gave identical `marblegame`, tarball and manifest, and `-ffile-prefix-map` keeps
work paths out of libhl and the hdlls. These `marblegame` hashes change only with the sources or
pins; tarball and manifest hashes also cover the MBHaxe commit and are recorded per build.
Values below: tsp-0qwbh.4 handheld series (built at MBHaxe `1240d2d4`, heaps `8510842b`; one run per
variant, the reproducibility check is tsp-0qwbh.2's). The tsp-0qwbh.5 builds at `ccda565b` (aarch64
product, x86_64 `pf_diag`) gave the same `marblegame` hashes.

| artifact | SHA256 |
|---|---|
| aarch64 `marblegame` (product) | `a02cbb72bd6a991cf5c01db3bf8f3d0652c8d44dacb205cdd26bf14a38b950aa` |
| x86_64 `marblegame` (product) | `ed1310a7e8b38611bbbc5adbf6a31bfc57b5dc734d89dc963c06fe8268e6d512` |
| x86_64 `marblegame` (`-D pf_diag`) | `69e51f6ee2d7cbb33f4461632c9ba116986a95a42fbbe3f42dd86fe9980f641d` |
| generated C tree (product, both arches) | `e890903fa9452b3a0899b84b0a43b49cdca266377981e7829cf6f04b582a0389` |

Gates on all three: highest GLIBC symbol version GLIBC_2.34; NEEDED within `pocketforge/build/needed.allow`;
no libGL; rpath `$ORIGIN` only.

App roots from those builds (`container.sh ... --app-root`, MBHaxe `ccda565b`, one run each). The
host re-assembly of the aarch64 one with `app-root.sh` gave the same tarball. The tarball and
manifest hashes also cover the MBHaxe commit and change with it.

| artifact | SHA256 |
|---|---|
| aarch64 build tarball `mbhaxe-pf-1.3.2-pf.20261019.ccda565b0a-aarch64.tar.zst` | `cae7cd34acb1b63e215c2634dc6917bb6c7b72d0273112a668ef1b9f98c72052` |
| aarch64 app root `org.pocketforge.mbhaxe-1.3.2-pf.20261019.ccda565b0a-aarch64.app.tar.zst` | `9f3a72122b3bf9a3ef20f9378364a4a9ac2f902fd2d7503d91ab1ba9dbf49935` |
| aarch64 `APP-MANIFEST.json` | `74f6e4ae999d74948990be5079da8d8f7235f72d6e8d351fff66c02c6600fc32` |
| x86_64 diag build tarball | `c6b657ba4c6643e03b6499d593afae592d954477681563135d8de676f5be5ca6` |
| x86_64 diag app root `org.pocketforge.mbhaxe-1.3.2-pf.20261019.ccda565b0a-x86_64-diag.app.tar.zst` | `c99c3cab78002570a5be1a8b1abc78044611da7db78d5f361220300a324d3dfd` |

App-root gates (both arches, top level and `lib/`): GLIBC_2.34 highest; NEEDED closed over the
app root plus `pocketforge/app/image-sonames.allow`; no libGL; `$ORIGIN`-only rpaths.
Laptop measurements (`tests/launch-smoke.sh`, x86_64 diag under Zink/lavapipe, orientation only, not
a device number): peak RSS 518700 KiB (lavapipe renders on the CPU); aarch64 app root 13.4 MiB plus
`data/` 70.8 MiB.

## Reference artifacts (tsp-0qwbh.1 reproduction, host gcc 13, 2026-10-19)

Built from fresh clones of the forks at the tsp-0qwbh.1 pins (heaps `1016de5b`). Bit-reproducibility is not yet a requirement;
the hdlls and libhl embed build paths and differ between build directories.

| artifact | SHA256 |
|---|---|
| amd64 `marblegame` (product) | `2b33367a6fd2871b29ccd522bfba64c95cb38ed9866310d919ac6e4568194cae` |
| amd64 `marblegame` (`-D pf_diag`) | `974cc7e3346202aa06de25a1bdb73e477ba9f1803f684067c2880f6a627dc967` (same as the spike diag build) |
| arm64 `marblegame` (product) | `f1d87ffcb548397278c9897080cb9a954e8aae1396d1901336723228f14f34d3` (same as the spike product build) |

sdl.hdll NEEDED (both arches): libSDL2-2.0.so.0, libhl.so.1, libGLESv2.so.2, libc.so.6 (no libGL).
Highest GLIBC symbol version over marblegame, libhl and all hdlls: GLIBC_2.34 (device bookworm has 2.36).
