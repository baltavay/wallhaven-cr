# AGENTS.md

Notes for anyone (human or agent) changing this codebase. `README.md` is the
short user-facing description; this file carries the reasoning that the code
comments only summarise, plus the invariants that are expensive to rediscover.

## What this is

A wallpaper manager for Omarchy: Crystal + raylib/raygui immediate-mode GUI,
SQLite storage, no GTK/Qt/webview. Everything the GUI does is also reachable
from the command line, which is deliberate — the CLI is how the app is verified
without opening a window.

## Build, test, verify

```sh
make            # bin/wallhaven-cr
make run        # build and open the GUI
make test       # crystal spec (pure logic, no window)
make release    # --release --debug (symbols kept on purpose: core dumps)
```

The `Makefile` exports `PKG_CONFIG_PATH`/`LD_LIBRARY_PATH` for a raylib under
`~/.local`. Run `crystal spec` by hand without those and the link fails with
`cannot find -lraylib`.

Verification recipes:

- **Never verify the GUI by reasoning about the drawing code.** Render a frame
  headlessly and look at it:
  `bin/wallhaven-cr --capture /tmp/frame.png --view theme --frames 30`
  (`--view browse|favourites|editor|queue|theme`). Capture mode runs the real
  UI with input disabled (`App#input_ready?`).
- `bin/wallhaven-cr --version` prints the **build time of the running binary**,
  which answers "am I testing the build I just made?".
- `bin/wallhaven-cr --stats` prints library, queue, monitor and theme state.
- `bin/wallhaven-cr --drain` runs queued background jobs to completion; useful
  for exercising the download/thumbnail/crop pipeline without the GUI.
- Crash: Crystal's fatal-signal handler prints a backtrace and `_exit(1)`s, so
  there is no core by default. `WALLHAVEN_CR_CORE=1 wallhaven-cr` restores the
  default handlers so the kernel writes a core; inspect with
  `coredumpctl info <binary>`.

## Source map

| Path | Contents |
|---|---|
| `src/main.cr` | CLI entry point, argument parsing, `--capture`, core-dump switch |
| `src/config.cr` | paths, `Settings` (JSON in `~/.config/wallhaven-cr/config.json`), thumbnail cache keys |
| `src/db.cr` | SQLite open/migrate, per-thread connections |
| `src/store.cr` | `Wallpaper`/`WallpaperFile` records and all SQL queries |
| `src/wallhaven.cr` | API client and search `Query` |
| `src/jobs.cr` | durable job queue (`jobs` table) and the single worker fiber |
| `src/images.cr` | vips/ImageMagick wrappers: thumbnail, preview, crop, import |
| `src/spawn.cr` | `posix_spawnp` helper used for every external program |
| `src/monitors.cr` | Hyprland monitor geometry + Omarchy theme integration |
| `src/aether_import.cr` | one-shot import of the old Aether favourites |
| `src/atomic_file.cr` | temp-file + rename writes, stale temp cleanup |
| `src/ui.cr` | `Ui::App`: the frame loop, views, widgets, overlays |
| `src/ui/*.cr` | one file per view, plus the pure-logic helpers (`fit`, `zoom`, `popup`) |
| `spec/*_spec.cr` | specs for the pure logic only |

## Invariants

These are load-bearing. Breaking one produces a SIGSEGV or silent data loss
that is hard to trace back here.

1. **The GL thread is pinned.** The window and every OpenGL call must stay on
   one system thread for the life of the process (`Fiber::ExecutionContext::Isolated.new("wh-ui")`).
   Crystal's default Parallel context may resume a fiber on a pool thread after
   any park, and raylib buffers draw calls, so the fault shows up later inside
   `libGLdispatch` with a NULL dispatch table. `App#run` re-checks the thread
   identity every frame and stops with a diagnostic rather than touching GL.
   Background workers never call raylib.
2. **Never `Process.run`, never `fork`.** The UI thread sits in GL/driver code
   and other threads allocate, so a forked child inherits locks those threads
   held and dies before `exec` (seen as a SIGSEGV inside `libGLdispatch`). All
   external programs go through `Spawn` (`posix_spawnp`: clone+exec, no
   user-space code in between).
3. **One SQLite connection per thread.** `Db.conn` keys a `DB::Database` on the
   current thread; a connection that migrates between scheduler threads races in
   crystal-db's statement cache (`SQLITE_MISUSE` → SIGSEGV). Single-connection
   pool, WAL, `busy_timeout`.
4. **Write through `AtomicFile`** whenever another thread or process can read the
   file while it is produced: thumbnails, previews, crops, theme copies. Rename
   within a directory is atomic, so readers only ever see a complete file.
5. **Omarchy theme writes go to `~/.config/omarchy/backgrounds/<theme>/`.**
   `omarchy-theme-set` searches that folder first and does not wipe it; the copy
   under `~/.local/state/omarchy/current/theme/` is deleted and recreated on
   every theme set. Added names keep an image extension, or the wallpaper search
   (`-iname '*.jpg'` …) never sees them. Identity is *content* (size, then
   SHA-1), not the name, so adding is idempotent and removing deletes every copy
   of that content.
6. **Thumbnails are whole images, contain-fit, never cropped or stretched.**
   The cache key is `favfit-<wallpaper id>-<file id>` (`Config.fit_thumb_key`).
   wallhaven's own JPEG is cached byte for byte; only local-only images are
   rendered through the image tool. Textures are loaded with mipmaps and
   trilinear filtering, because minifying a plain bilinear texture aliases fine
   detail.
7. **Overlays draw last.** An open dropdown or the colour picker is stored in
   `@open_dropdown` / `@color_picker_open` and drawn after the current view;
   raygui expands a dropdown inline, which otherwise puts its options underneath
   whatever is drawn next.
8. **Input goes through `App#input_ready?`** (`@frame > INPUT_SETTLE_FRAMES` and
   the window is focused, and never in capture mode). Raw `Raylib.mouse_*` calls
   outside that gate make a headless capture click on things.
9. **Job order is not FIFO:** `crop`/`import_local` (user just asked) → `thumbnail`
   → `download`. Plain FIFO buries every thumbnail behind every download, so a
   fresh library shows an empty grid for the whole download phase.

## Conventions

- Comments explain **why**, usually naming the bug or measurement that forced the
  decision. Keep that style; a comment that restates the code is noise.
- Specs cover pure logic — fit/zoom/popup arithmetic, atomic writes, theme
  add/remove, store queries, wallhaven URLs, spawn. View code is verified with
  `--capture`, not with specs.
- Specs that touch the theme set `WALLHAVEN_CR_THEME_DIR` to a temp directory
  (`spec/theme_spec.cr`) so they never write to a real theme.
- Image work shells out to libvips (preferred) or ImageMagick; an 8K JPEG is
  never decoded in the UI process.
- Environment overrides: `WALLHAVEN_CR_DATA` (data dir), `WALLHAVEN_CR_THEME_DIR`
  (theme target), `WALLHAVEN_CR_IMAGE_TOOL=vips|magick|convert`,
  `WALLHAVEN_CR_CORE=1` (allow core dumps).

## On-disk layout

`README.md` lists where the database, originals, crops, thumbnails and settings
live. Two details that matter when changing code: thumbnail files are
`thumbs/cache/<key>.jpg` with the key from `Config.thumb_cache_path` (the whole
path is derived, never hand-built), and the API key is seeded from
`~/.config/aether/wallhaven.json` on first run.
