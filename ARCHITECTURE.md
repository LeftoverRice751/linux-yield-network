# lyn.sh — System Architecture

`lyn.sh` is a single-file bash control desk for the PressPoint website. It has
no build system, no dependencies beyond standard Unix tools, and no runtime
of its own — it exists to start, stop, and clone the four programs that make
up PressPoint. This document tracks how the script is put together and grows
as new features are added.

## What PressPoint actually is

Not one program — four, that all have to run together:

| # | Program | Job |
|---|---------|-----|
| 1 | `npm` | rebuilds CSS/JS on file change (`watch`) or once (`prod`) |
| 2 | `gunicorn` | runs the Python (Masonite) app, listening on a Unix socket |
| 3 | `nginx` | listens on port 80, forwards visitors to gunicorn's socket |
| 4 | `cloudflared` | tunnels port 80 out to the public domain |

Request path: **internet → cloudflared tunnel → nginx :80 → unix socket → gunicorn workers → Masonite app**.

## Script layout (`lyn.sh`, ~2540 lines, 13 sections)

| Section | Lines (approx) | Purpose |
|---|---|---|
| 1. Settings box | 26–222 | every tunable value — paths, tunnel name, timeouts, peer host, kiosk/health settings |
| 1B. Health check & failover settings | 223–265 | `HEALTH_CHECK_*`, `LOCAL_FALLBACK_URL`, `MONITOR_PID_FILE`, `LOG_EVENTS` |
| 2. Helpers | 266–490 | colour/UTF-8 detection, `say_*` printers, `kill_family`, `sweep_project_strays`, PID/tunnel liveness checks |
| 3. Preflight | 491–587 | `check_tools` — verifies venv, gunicorn, npm, curl, cloudflared, cert, nginx exist before anything runs |
| 4. Node version | 588–620 | `use_project_node` — switches to the `.nvmrc` Node version via nvm |
| 5. Option 1 — start | 621–845 | `start_stack` — picks the kiosk target, activates venv, starts npm/gunicorn/cloudflared with `setsid`, opens the kiosk browser, starts the watchman |
| 6. Option 2 — stop | 846–927 | `stop_stack` — TERM then KILL each recorded process group, sweeps stragglers, closes the tunnel, closes the kiosk screen, stops the watchman, cleans PID/socket files |
| 7. Status board | 928–1009 | `show_status` — renders the build→engine→on-air dot chain |
| 8. Menu | 1010–1096 | logo, `ui_header`, `show_menu` (keys `1`/`2`/`3`/`4`/`q`) |
| 9. Peer plumbing | 1097–1282 | SSH helpers (`peer_ssh`, `on_source`/`on_target`, `copy_over` via rsync) shared by option 3 |
| 9B. Kiosk screen | 1283–1600 | target picker/persistence, its own SSH wrapper (`kiosk_run`), browser detection, kiosk-mode launch for Linux and Windows (see below) |
| 9C. The watchman | 1601–1729 | `check_public_url`, `monitor_loop`, `start_monitor`/`stop_monitor`, `show_live_log` (option 4) |
| 10. Option 3 — clone | 1730–2454 | the 9-step copy pipeline to a second machine (see below) |
| 11. Main loop | 2456–2529 | `main()` — preflight once, then loop on `show_menu` until `q`; a hidden `--monitor-loop-internal` re-entry point at the bottom lets the watchman be "this same script" running headless |

## Process lifecycle model

- Every long-running program is launched with `setsid`, putting it in its own
  process group so its children (e.g. npm's webpack helper) can be killed as
  a unit via `kill -- -PGID`.
- PIDs are written to `/tmp/presspoint.pids` as they're started
  (`remember_pid`); `stop_stack` reads that file to know what to shut down.
- `sweep_project_strays` is a belt-and-braces pass that only kills processes
  which are simultaneously (a) a known build tool, (b) running from
  `PROJECT_DIR`, and (c) actually `node`/`python` — so it can't take out an
  unrelated program on the same box.
- Logs go to `/tmp/presspoint_{npm,gunicorn,cloudflared}.log` instead of the
  screen, keeping the menu clean; failures print the tail of the relevant log.

## Option 3 — clone pipeline

Copies a **working** PressPoint install to a second machine over SSH/rsync
(deliberately not git — git doesn't track `.env`, the database, media, or
tunnel keys). Direction is chosen at runtime: **send** (this → peer) or
**receive** (peer → this), implemented once via `on_source`/`on_target`
indirection rather than duplicated logic.

Nine independently toggleable steps, run in order:

1. **tools** — installs nginx, MySQL, Python 3.11 (via deadsnakes PPA),
   cloudflared, Nextcloud on the target (needs passwordless sudo there)
2. **lyn** — copies `lyn.sh` itself; self-overwrite is avoided by writing
   `lyn.sh.new` and asking the user to swap it in after quitting
3. **code** — rsyncs the project, excluding `venv/`, `node_modules/`, `.env`;
   rebuilds the venv from `requirements.txt` on the target with Python 3.11
4. **assets** — copies the *built* CSS/JS (built on the source with Node 18)
   so the target never needs npm/nvm
5. **env** — streams `.env` through the SSH pipe (never touches disk as a
   temp file), forcing `APP_DEBUG=False` and `APP_ENV=production`
6. **database** — `mysqldump | mysql` over the pipe; takes a safety dump of
   the target's existing DB first; auto-disabled (must type `replace`) if the
   target is already live, to avoid wiping articles written there
7. **media** — rsyncs `MEDIA_DIR` and the app's own uploads folder, no
   `--delete` (never destroys content only the target has)
8. **tunnel** — copies `~/.cloudflared/cert.pem` and the *specific* key file
   for `TUNNEL_NAME` (looked up by UUID, not guessed from filenames — there
   are 3 tunnels on the account and only one is wired to the domain)
9. **nginx** — copies the site config, rewriting `PROJECT_DIR` paths if they
   differ between machines, reloads nginx

After copying, `clone_verify` re-checks the target the way the live site
would (venv works, is 3.11, gunicorn present, `.env` present with
`APP_DEBUG=False`, assets built, cert present, nginx active, DB reachable
with real credentials) and reports anything still missing.

**Known fragility points** (untested as of 2026-08-19 — start/stop has been
run for real, clone has not):
- Requires passwordless `sudo` on the target for 4 of 9 steps, or they
  degrade to manual instructions
- Multi-layer shell quoting through `on_target`/`peer_ssh` (local bash →
  SSH → remote shell) is the likeliest source of a silent breakage
- `cloudflared tunnel list` column parsing assumes a fixed CLI output format
- Only one tunnel may run at a time (Cloudflare has no leader election here)

## Kiosk screen, auto-failover, and the watchman (Sections 9B/9C)

Added so the site doesn't just run — it's actually *displayed*, and stays
displayed even if the public tunnel has trouble.

- **Target picked fresh every Start.** Before anything else, `kiosk_pick_target`
  asks whether the kiosk screen is this computer or a saved/ad-hoc remote
  machine (Linux or Windows). The **server always runs locally** regardless —
  only the browser's location is selectable. Remote machines are remembered
  in `~/.lyn_kiosk_targets` (pipe-delimited `name|host|user|port|os`) so each
  one only needs to be typed once.
- **A second, independent SSH channel.** `kiosk_run`/`kiosk_ssh` mirror
  Section 9's `on_target`/`peer_ssh` pattern but use their own ControlMaster
  socket (`KIOSK_SSH_CTL_DIR`), so a kiosk session and a clone session can't
  collide. Both funnel through one shared `lyn_exit_cleanup` EXIT trap.
- **Browser choice is a fixed priority list**, auto-detected on whichever
  machine is the target (`KIOSK_BROWSER_PRIORITY` for Linux, `..._WIN` for
  Windows) — exactly one browser launches, in `--kiosk` mode.
- **Local fallback URL is computed once per run** (`resolve_local_fallback_url`):
  `127.0.0.1` if the kiosk is local, or this machine's LAN IP if the kiosk is
  remote (since the remote box's own loopback wouldn't reach this server).
- **The watchman is the script re-running itself.** `start_monitor` exports
  the run's resolved state (`KIOSK_ACTIVE_*`, `KIOSK_BROWSER_*`,
  `LOCAL_FALLBACK_URL`) and launches `setsid bash "$0" --monitor-loop-internal`
  — the same file, re-read top to bottom, diverted at the very bottom into
  `monitor_loop` instead of `main()`. Every `HEALTH_CHECK_INTERVAL` seconds it
  checks the core processes, the kiosk browser's liveness, and `PUBLIC_URL`
  via `curl`; on `HEALTH_FAIL_THRESHOLD` consecutive failures it kills and
  relaunches the kiosk browser at `LOCAL_FALLBACK_URL` (a visible flash is an
  accepted trade-off over CDP-based in-place navigation), switching back on
  recovery. Everything it does is timestamped into `LOG_EVENTS`, viewable live
  via the new **option 4**, which just `tail -f`s all four logs at once.
- **Stop tears down everything** (server, watchman, kiosk browser); **quit
  leaves all of it running**, extending the pre-existing "q never stops
  anything" precedent to the new pieces.

**Known limitation, not solved by this feature:** a bare SSH login to a
remote Linux kiosk doesn't automatically get access to that machine's
already-open desktop display. `kiosk_launch_linux` guesses the display is
`:0` and its X authority file via `KIOSK_REMOTE_XAUTH_CMD` (default assumes
GNOME/gdm) — this needs verifying against the actual target machine and
tweaking for other display managers. Windows launch (`kiosk_launch_windows`)
is similarly unverified against a real Windows OpenSSH target.

## Key invariants worth knowing before touching this file

- `TUNNEL_NAME` must exactly match the Cloudflare dashboard, or the tunnel
  connects successfully while serving nobody (the "Error 1033" trap).
- `SOCKET_NAME` here and the matching line in
  `/etc/nginx/sites-enabled/presspoint` must agree exactly.
- The clone pipeline never uses `rsync --delete` and never overwrites a live
  target's database without the operator typing `replace`.

---

## Feature log

*(Newest first. Add an entry here whenever a feature is added to `lyn.sh`.)*

- **2026-08-19** — Added the kiosk screen, auto-failover, and the watchman
  (Sections 9B/9C, new option 4 "logs"). Pressing Start now also picks a
  kiosk display (local or remote SSH, Linux or Windows), opens a browser
  there in kiosk mode, and starts a background watchman that polls the
  public URL every 5s and fails the kiosk over to a local address on
  gateway errors, switching back on recovery. Stop tears the watchman and
  kiosk browser down along with the server; quit leaves all three running.
  Not yet tested against a real remote kiosk machine (Linux XAUTHORITY
  guess and the whole Windows path are unverified — see Section 9B notes
  above).
- **2026-08-19** — Architecture doc created. Baseline covers: start/stop
  stack (options 1/2, confirmed working per commit history), status board,
  and the 9-step clone pipeline (option 3, not yet exercised end-to-end).
