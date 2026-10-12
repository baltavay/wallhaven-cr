# wallhaven-cr

Wallpaper manager for [Omarchy](https://omarchy.org), written in Crystal with an
immediate-mode GUI (raylib + raygui). No GTK, no Qt, no webview.

* Browse wallhaven.cc with the full search surface: categories (general / anime /
  people), purity (SFW / sketchy / NSFW), sorting and order, toplist range,
  `atleast` minimum size, exact resolutions, aspect ratio and colour filter.
* Favourites are downloaded in the background (SQLite job queue, one worker
  thread) and get grid thumbnails.
* Crop editor: zoom with the scroll wheel or the zoom bar, drag the image under
  a frame locked to the target monitor's aspect ratio, and write a version at
  exactly that monitor's pixel size.
* Every wallpaper keeps its original plus any number of cropped versions; each
  version is a separate row and can be deleted on its own.
* Add favourites (originals and versions) to the current Omarchy theme with one
  copy into `~/.local/share/omarchy/current/theme/backgrounds`.
* Add wallpapers that are already on disk.

## Layout

| Path | Contents |
|---|---|
| `~/.local/share/wallhaven-cr/wallhaven.db` | wallpapers, versions, job queue |
| `~/.local/share/wallhaven-cr/originals/` | downloaded / imported originals |
| `~/.local/share/wallhaven-cr/crops/` | cropped + monitor-sized versions |
| `~/.local/share/wallhaven-cr/thumbs/` | grid thumbnails and editor previews |
| `~/.config/wallhaven-cr/config.json` | API key and last used filters |

The API key is seeded from `~/.config/aether/wallhaven.json` on first run, so an
existing wallhaven key keeps working. NSFW purity needs a key.

## Requirements

* Crystal >= 1.15 (built and tested with 1.21)
* `raylib` (5.5) and `raygui` (4.0) — raylib from the AUR/`raylib` package or a
  local install in `~/.local`; raygui is built from
  `raysan5/raygui` as `libraygui.so` (see `Makefile`)
* libvips (`vips`, `vipsheader`) **or** ImageMagick (`magick`/`convert`) for
  thumbnails, previews and cropping. libvips is preferred when installed: on
  5500x8000 sources it is ~2x faster and peaks at 60-120 MB instead of
  550-710 MB per image (thumb 0.31s/61MB vs 0.60s/546MB, preview 0.56s/119MB vs
  0.80s/682MB, crop to 1920x1080 0.34s/110MB vs 0.76s/710MB). Set
  `WALLHAVEN_CR_IMAGE_TOOL=magick` to force the fallback.
* Hyprland (`hyprctl`) for monitor geometry; falls back to 1920x1080
* Optionally Omarchy, for the theme integration

## Build

```sh
make            # builds bin/wallhaven-cr
make run        # builds and starts the GUI
make test       # runs the specs
```

`Makefile` sets `PKG_CONFIG_PATH`/`LD_LIBRARY_PATH` for a raylib installed under
`~/.local`. It also builds `libraygui.so` from `RAYGUI_SRC` (default
`/tmp/raygui`) if it is missing.

## Usage

```sh
wallhaven-cr                       # GUI
wallhaven-cr --search -q anime -c 010 -p 100 --pages 2 --json
wallhaven-cr --download ID         # queue a download and drain the queue
wallhaven-cr --convert ID          # write a monitor-sized version (centred crop)
wallhaven-cr --import-local PATH   # add an image from disk to favourites
wallhaven-cr --import-aether       # queue the old Aether favourites (no drain)
wallhaven-cr --drain               # run queued jobs to completion
wallhaven-cr --monitors            # Hyprland monitors and their pixel sizes
wallhaven-cr --stats               # library and queue counts
wallhaven-cr --capture PATH        # render one frame to a PNG (--frames, --view)
wallhaven-cr --version             # version plus the build time of this binary
```

Search options: `-q/--query`, `-c/--categories` (bitmask `111`), `-p/--purity`
(bitmask `100` = SFW), `-s/--sorting`, `-o/--order`, `--atleast`, `--resolutions`,
`--ratios`, `--colors`, `--top-range`, `--page`, `--pages`.

In the GUI: left click selects, right click toggles the favourite, scroll wheel
scrolls the grid, `Escape` closes the file picker, `Ctrl+Q` quits.

Debugging a crash: Crystal's fatal-signal handler prints a backtrace and then
`_exit(1)`s, so a segfault leaves no core dump. Run with
`WALLHAVEN_CR_CORE=1 wallhaven-cr` to restore the default handlers instead and
let the kernel write a core, then inspect it with
`coredumpctl info <binary>`. `wallhaven-cr --version` prints the build time of
the running binary, which settles "am I running the fixed build?".

## Threads, and why the UI is pinned

The window and every OpenGL call must happen on one thread for the life of the
process: a GL context is only current on the thread that created it. Crystal's
default (Parallel) execution context is free to resume the main fiber on a pool
thread after *any* park (a contended `Mutex`, a blocking channel, a sleep), and
the UI loop is full of those. That is not a theoretical hazard — a core dump
caught it: the UI loop was running on thread `DEFAULT-0` while the real main
thread sat idle in Crystal's thread pool, and the next flush of raylib's render
batch (raylib buffers draw calls, so `draw_text`/`draw_rectangle` do not touch
GL) segfaulted inside `libGLdispatch` with a NULL dispatch table (`rax = 0`,
faulted at +0x1700).

So the UI runs inside `Fiber::ExecutionContext::Isolated.new("wh-ui")`, which
guarantees its fiber always runs on the same system thread, and the window is
created *there*. `App#run` also re-checks the thread identity every frame: if it
ever changed, the loop stops before touching GL again and prints a diagnostic
instead of dying with an unexplained SIGSEGV. Workers stay in their own contexts
(`wh-jobs`, `wh-thumbs`, `wh-previews`, `wh-search`) and never call raylib.

## How the background work runs

`Jobs` keeps durable rows in the `jobs` table (`download`, `thumbnail`, `crop`,
`import_local`). One dedicated execution context
(`Fiber::ExecutionContext::Isolated`) claims the next queued job, runs it and
records the outcome — the same shape as `binance_bot_cr`. Downloads are written
to a `.part` file and renamed on completion, so a crash never registers a
half-written original. Jobs left `running` by a killed process are requeued at
startup and abandoned after three attempts.

Service order is not plain FIFO: things you just asked for (`crop`,
`import_local`) go first, then `thumbnail`, then `download`. A plain queue puts
every thumbnail behind every download, so a freshly imported library shows an
empty grid for the whole download phase; with this order each download is
followed by its own thumbnail and the grid fills in as it goes.

Image work shells out to libvips (or ImageMagick) so an 8K JPEG is never decoded
into memory by the UI process, and the GUI thread only ever loads finished
thumbnails.

External programs are started with `posix_spawnp` (`src/spawn.cr`), **not**
Crystal's `Process.run`. `Process.run` forks, and forking this process is unsafe:
the UI thread is inside GL/driver code most of the time and three other threads
allocate, so the forked child inherits mutexes those threads held at fork time.
The child then runs libglvnd's and the NVIDIA driver's `atfork` handlers against
those locked structures and dies before `exec` — observed as
`Invalid memory access (signal 11) ... in libGLdispatch.so.0` while the app kept
rendering, and reproducible as a hang when a worker forked ImageMagick during the
render loop. `posix_spawnp` does clone+exec with no user-space code in between, so
no inherited lock can deadlock the child.
