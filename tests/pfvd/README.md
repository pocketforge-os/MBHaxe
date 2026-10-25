# pfvd desktop check

`mbhaxe-desktop.toml` runs the x86_64 diagnostic build in pfvd's desktop tier:
a private 1280x720 Xvfb, record-only input, X11/EGL, and Mesa Zink over
lavapipe. It captures the main menu, selects the first single-player level with
three `input tap start` actions, proves the in-level frame differs from the
menu, and holds the live level for ten minutes before checking the runtime and
diagnostic frame-time output.

Build and fetch the owner-local game data first:

```sh
pocketforge/build/ci.sh x86_64 diag
python3 -I pocketforge/app/pf-fetch.py \
  --app-toml pocketforge/app/app.toml \
  --root .pf-build/runtime \
  --cache .pf-build/fetch-cache
```

Run with a pfvd CLI that includes desktop scenario support
([pocketforge-os/pfvd#67](https://github.com/pocketforge-os/pfvd/pull/67)),
installed in the sibling admitted worktree. Keep its runtime and configuration
isolated from the user's regular pfvd setup:

```sh
install -d -m 700 .pf-build/pfvd-check/runtime .pf-build/pfvd-check/config
PFVD_RUNTIME_DIR="$PWD/.pf-build/pfvd-check/runtime" \
XDG_CONFIG_HOME="$PWD/.pf-build/pfvd-check/config" \
../pfvd/inst/bin/pfvd-cli check \
  --scenario tests/pfvd/mbhaxe-desktop.toml \
  --report-dir /home/matt/recovery/tsp-openmbu/pfvd/<run>
```

The report, captures, cache, and fetched game data are owner-local evidence and
must not be committed or uploaded.
