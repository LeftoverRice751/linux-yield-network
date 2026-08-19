#!/usr/bin/env bash
# =============================================================================
#  A tiny remote-control for the PressPoint website.
#
#  WHAT IS THIS?
#  PressPoint is not one program. It is four small programs that have to be
#  running at the same time for the website to work:
#
#     1. npm  ........... rebuilds the CSS/JavaScript when you edit the code
#     2. gunicorn ....... the Python engine that actually runs the website
#     3. nginx .......... the doorman that passes visitors to gunicorn
#     4. cloudflared .... the tunnel that puts the site on the real internet
#
#  Remembering four commands in the right order is annoying. So this script
#  does it for you. Press 1 to turn everything ON. Press 2 to turn it OFF.
#  Press Q to leave. That is the whole thing.
#
#  You do NOT need to understand Linux to use this. You only need to press keys.
# =============================================================================

# "set -u" means: if I ever use a setting that doesn't exist, stop and complain
# instead of quietly doing something weird. It's a seatbelt.
set -u

# =============================================================================
#  SECTION 1 — THE SETTINGS BOX  (this is the part you are allowed to change)
# =============================================================================
# Everything you might ever want to tweak lives right here in one place.
# You should not need to touch anything below Section 2.

# --- WHERE IS THE WEBSITE'S CODE? --------------------------------------------
# This is the folder that holds the whole PressPoint project.
# TWEAK THIS if you ever move the project somewhere else, for example to
# "/home/$USER/presspoint" or "/var/www/presspoint".
PROJECT_DIR="/your/project/directory"

# --- THE PYTHON "TOOLBOX" ----------------------------------------------------
# A virtual environment ("venv") is a private toolbox of Python programs that
# belongs to this project only, so it can't get mixed up with other projects.
# We have to "activate" it before running anything Python.
# TWEAK THIS only if your toolbox folder is named something other than "venv".
VENV_ACTIVATE="$PROJECT_DIR/venv/bin/activate"

# We call gunicorn by its FULL path from inside the toolbox. This matters:
# if we just typed "gunicorn" we might accidentally grab a different one that
# is installed elsewhere on the computer, and it would fail in a confusing way.
GUNICORN_BIN="$PROJECT_DIR/yourvenv/bin/gunicorn"

# --- THE FRONT DOOR (the socket) ---------------------------------------------
# A "socket" is a special file that works like a doorway. gunicorn sits behind
# the doorway, and nginx knocks on it to hand over visitors.
# TWEAK THIS only if you also change the matching line inside nginx's config at
# /etc/nginx/sites-enabled/presspoint. The two names MUST match exactly, or
# nginx will knock on a door that nobody is standing behind.
SOCKET_NAME="yoursockfile.sock"
SOCKET_PATH="$PROJECT_DIR/$SOCKET_NAME"

# --- HOW MANY WORKERS? -------------------------------------------------------
# A "worker" is one helper that can serve one visitor at a time. Three workers
# means three visitors can be served at once; a fourth waits a moment in line.
# TWEAK THIS: more workers = handles more people at once, but uses more memory.
# A common rule of thumb is (number of CPU cores x 2) + 1. Three is fine here.
GUNICORN_WORKERS=9

# --- WHICH PYTHON FILE STARTS THE WEBSITE? -----------------------------------
# This reads as "in the file wsgi.py, run the thing named application".
# TWEAK THIS basically never. It only changes if the project is restructured.
WSGI_APP="wsgi:application"

# --- WHICH NPM JOB SHOULD WE RUN? --------------------------------------------
# "watch" = build the CSS/JS now, then STAY RUNNING and rebuild automatically
#           every time you save a file. This is what you want while working.
# "dev"   = build once and immediately quit. Useful for a one-off build, but
#           there is then nothing left running for option 2 to switch off.
# TWEAK THIS to "dev" if you only ever want a single build.
NPM_SCRIPT="watch"

# --- THE INTERNET TUNNEL -----------------------------------------------------
# cloudflared is what makes the site reachable at its real web address instead
# of only on this one computer.
#
# IMPORTANT - READ THIS BIT, IT IS THE EASIEST THING TO GET WRONG:
# This Cloudflare account has THREE tunnels, and they are not interchangeable:
#
#     Presspoint-Server  (e75ec32f...)  <- runs automatically at boot, but the
#                                          web address does NOT point at it
#     kadiwa             (183ed18c...)  <- something else entirely
#     presspoint-tunnel  (2929ead3...)  <- THIS is the one presspoint-gears.me
#                                          is actually wired to
#
# The web address is glued to ONE specific tunnel. Start the wrong one and your
# browser shows "Error 1033", because Cloudflare is holding the door open for a
# tunnel that never turned up. That is true even if another tunnel is happily
# running - which is exactly what makes this so confusing.
#
# TWEAK THIS only if you re-point the domain at a different tunnel in the
# Cloudflare dashboard. The name below must match the dashboard EXACTLY.
TUNNEL_NAME="your-tunnel"

# Where the tunnel should send visitors once they arrive. Port 80 is nginx,
# which then passes them along to gunicorn through the socket door.
# TWEAK THIS if nginx is ever moved to a different port, e.g. http://127.0.0.1:8080
TUNNEL_TARGET_URL="http://ur-url"

# How the tunnel talks to Cloudflare. "http2" is the reliable choice here;
# the default ("quic") uses UDP, which some Wi-Fi and hotspot connections block.
# TWEAK THIS to "quic" only if you know your network allows UDP port 7844.
TUNNEL_PROTOCOL="http2"

# The public web address, used only for the friendly message at the end.
# TWEAK THIS if the domain changes.
PUBLIC_URL="https://site-url"

# --- THE NOTEBOOK AND THE DIARIES --------------------------------------------
# When we start a program, Linux gives it an ID number (a "PID"). We write those
# numbers into this notebook file so that later, option 2 knows exactly which
# programs to switch off. Without it we'd be guessing.
PID_FILE="/tmp/yourpids.pids"

# Programs like to talk while they work. We send all that chatter into these
# log files ("diaries") instead of the screen, so the menu stays clean. If
# something breaks, these are the first place to look.
LOG_NPM="/tmp/your_npm.log"
LOG_GUNICORN="/tmp/your_gunicorn.log"
LOG_TUNNEL="/tmp/your_cloudflared.log"

# How many seconds to wait for gunicorn to open its door before we assume it
# has fallen over. TWEAK THIS higher on a slow computer.
STARTUP_TIMEOUT=15

# How many seconds to wait for Cloudflare to accept the tunnel. This one needs
# to be much more generous than the number above: the tunnel has to reach
# Cloudflare's servers over the internet, and on a slow or busy connection
# (a phone hotspot, for example) it can easily take 20-30 seconds just to get
# started. If you often see "Cloudflare has not accepted it yet" even though
# the site works a moment later, TWEAK THIS number higher.
TUNNEL_TIMEOUT=60

# --- THE OTHER COMPUTER ------------------------------------------------------
# Option 3 copies this whole setup onto a second computer over the home network,
# so that computer can put the website on the internet instead of this one.
#
# The idea is a split of jobs:
#     this computer   -> where you WRITE the website
#     other computer  -> where the website LIVES for the public
#
# Leave PEER_HOST empty and option 3 will simply ask you for the address the
# first time you use it. Fill it in here if you got tired of typing it.
#
# TWEAK THIS to the other computer's address on your network. An IP address
# like "192.168.1.50" always works. A name like "presspoint-prod" works too, if
# you have set one up in ~/.ssh/config.
PEER_HOST=""

# The username to log in as on the other computer. Defaults to the same name
# you use here, which is right most of the time.
# TWEAK THIS if the other computer's account has a different name.
PEER_USER="$USER"

# The "door number" SSH uses. 22 is the standard one and almost never changes.
# TWEAK THIS only if you deliberately moved SSH to another port.
PEER_PORT="22"

# Where things should live on the other computer. These deliberately mirror the
# layout on this one, so both machines look the same when you sit down at them.
# TWEAK THIS if the other computer keeps its files somewhere else.
PEER_PROJECT_DIR="/home/$PEER_USER/Downloads/presspoint"
PEER_LYN_DIR="/home/$PEER_USER/lyn"

# Which npm job the OTHER computer should run.
#
# This computer uses "watch", which stays running and rebuilds the CSS every
# time you save a file - exactly what you want while writing the website. The
# other computer is not being edited by anybody, so a watcher there would sit
# burning electricity forever, rebuilding files nobody touched. "prod" builds
# everything once, minified and tidy, and then finishes.
# TWEAK THIS basically never.
PEER_NPM_SCRIPT="prod"

# The folder holding the Cloudflare login certificate and the tunnel's keys.
# The other computer needs a copy of these or it cannot open the tunnel at all.
CLOUDFLARED_DIR="$HOME/.cloudflared"

# Where nginx keeps the website's door policy on both computers.
NGINX_SITE_SRC="/etc/nginx/sites-available/presspoint"

# The website's filing cabinet: archive PDFs, videos, branding images. This is
# a plain folder on the disk despite the "NAS" in its name.
# TWEAK THIS if you move the media folder. It must match GEARSNAS_BASE in the
# project's .env file.
MEDIA_DIR="/mnt/nas_storage/gears_data"

# --- THE KIOSK BROWSER --------------------------------------------------------
# When you press 1, lyn also opens a browser pointed at the site, in "kiosk
# mode" (no address bar, no tabs, just the website filling the screen). This
# is the list of browsers it will look for, in order - the first one it finds
# on the target machine is the one it uses. Only ever one browser, never more.
# TWEAK THIS to reorder or add a browser name.
KIOSK_BROWSER_PRIORITY=(brave chromium firefox)
# The same list, but for a Windows target - browser binary names differ there.
KIOSK_BROWSER_PRIORITY_WIN=(brave chrome msedge firefox)

# Which screen (X11 display number) the browser should open on, when the
# kiosk is THIS computer. ":0" is almost always right for a normal desktop
# login. TWEAK THIS only if you know this machine uses a different display.
KIOSK_LOCAL_DISPLAY=":0"

# Where lyn remembers the remote kiosk machines you've told it about before,
# so you only have to type each one's address once, ever.
KIOSK_TARGETS_FILE="$HOME/.lyn_kiosk_targets"

# --- READING A REMOTE SCREEN'S "PERMISSION SLIP" -----------------------------
# A plain SSH login does NOT automatically get to draw on a machine's already
# open desktop - it needs two things: which screen (DISPLAY, see above) and a
# "permission slip" file (XAUTHORITY) proving it's allowed to draw there. This
# command is run ON THE REMOTE MACHINE to guess where that file lives; the
# guess below is right for GNOME (gdm). TWEAK THIS if the kiosk machine uses a
# different desktop (e.g. lightdm, sddm) - the folder name is the part that
# changes.
KIOSK_REMOTE_XAUTH_CMD='echo /run/user/$(id -u)/gdm/Xauthority'

# =============================================================================
#  SECTION 1B — HEALTH CHECK AND FAILOVER
# =============================================================================
# Once the site is on air, lyn keeps watching it. If the public web address
# starts failing, lyn switches the kiosk screen to a LOCAL web address instead
# (this computer talking to nginx directly, skipping Cloudflare entirely) so
# the kiosk keeps showing something instead of an error page. It switches back
# automatically once the public address is healthy again.

# How often to check, in seconds. TWEAK THIS higher to check less often (and
# use less network), lower to notice trouble sooner.
HEALTH_CHECK_INTERVAL=5

# How long to wait for the public address to answer before counting it as a
# failure.
HEALTH_CHECK_TIMEOUT=4

# How many checks in a row must fail before lyn actually switches to the local
# fallback. TWEAK THIS higher if a single slow response (rather than a real
# outage) keeps triggering an unwanted switch.
HEALTH_FAIL_THRESHOLD=2

# The local web address to fall back to. Leave this BLANK and lyn works it out
# for you: if the kiosk is this computer, it uses http://127.0.0.1; if the
# kiosk is a remote machine, it uses this computer's address on the local
# network instead (127.0.0.1 on the kiosk machine would mean "myself", not
# "this server", so that would not work).
# TWEAK THIS only if the automatic guess is wrong for your network.
#
# (Written as ${LOCAL_FALLBACK_URL:-} rather than a plain "" - the watchman
# is this same script re-run from the top with the answer already worked out
# and handed to it as an environment variable; a plain "" here would erase
# that answer before the watchman ever got to use it. See start_monitor.)
LOCAL_FALLBACK_URL="${LOCAL_FALLBACK_URL:-}"

# --- THE WATCHMAN AND THE EVENT DIARY -----------------------------------------
# The "monitor" is a quiet helper that runs in the background once the site is
# on air, doing the every-5-seconds health check above. Like the other
# programs, we write its ID number down so option 2 knows how to switch it
# off, and its own diary of what it saw.
MONITOR_PID_FILE="/tmp/presspoint_monitor.pid"
LOG_EVENTS="/tmp/presspoint_events.log"

# =============================================================================
#  SECTION 2 — HELPERS  (below here is machinery; you can just read it)
# =============================================================================

# --- COLOURS -----------------------------------------------------------------
# These are secret codes that tell the terminal "paint the next words amber".
# We only turn them on if we're actually printing to a real screen; if the
# output is being saved to a file, colour codes would just be ugly garbage.
#
# Terminals come in two flavours: fancy ones that know 256 colours, and plain
# ones that only know 8. We ask which we're dealing with and pick accordingly,
# so the menu looks right either way instead of looking broken on the old ones.
if [ -t 1 ]; then
    UI_TTY=1
    UI_COLORS="$(tput colors 2>/dev/null || echo 8)"
else
    UI_TTY=0
    UI_COLORS=0
fi

if [ "$UI_TTY" = "1" ] && [ "$UI_COLORS" -ge 256 ]; then
    # The good stuff. Flat, solid colours - no fades or gradients anywhere.
    C_ACCENT=$'\033[38;5;214m'   # amber  - the accent colour
    C_LIVE=$'\033[38;5;78m'      # green  - this thing is running
    C_DOWN=$'\033[38;5;203m'     # red    - this thing is off or broken
    C_WARN=$'\033[38;5;179m'     # sand   - worth reading, not an emergency
    C_MUTED=$'\033[38;5;245m'    # grey   - supporting detail
    C_FAINT=$'\033[38;5;240m'    # darker grey - rules, lines, hints
    C_BOLD=$'\033[1m'
    C_KEY=$'\033[48;5;214m\033[38;5;232m'   # amber block with dark text: a keycap
    C_OFF=$'\033[0m'             # "stop colouring now"
elif [ "$UI_TTY" = "1" ]; then
    C_ACCENT=$'\033[1;33m'; C_LIVE=$'\033[1;32m'; C_DOWN=$'\033[1;31m'
    C_WARN=$'\033[0;33m';   C_MUTED=$'\033[0;37m'; C_FAINT=$'\033[2m'
    C_BOLD=$'\033[1m';      C_KEY=$'\033[7m';      C_OFF=$'\033[0m'
else
    C_ACCENT=''; C_LIVE=''; C_DOWN=''; C_WARN=''; C_MUTED=''
    C_FAINT='';  C_BOLD='';  C_KEY='';  C_OFF=''
fi

# --- SYMBOLS -----------------------------------------------------------------
# The nice round dots and lines below are "Unicode" characters. Almost every
# modern Linux terminal draws them perfectly. A few very old ones don't, and
# would show meaningless boxes instead - so we check first and keep a plain
# keyboard-character version in reserve.
if [ "$(locale charmap 2>/dev/null)" = "UTF-8" ]; then
    G_ON="●"; G_OFF="○"; G_LINK="━"; G_RULE="─"; G_BAR="▌"
    G_OK="✓"; G_BAD="✗"; G_WARN="!"; G_INFO="·"; G_PROMPT="▸"
    SPIN=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
else
    G_ON="*"; G_OFF="o"; G_LINK="="; G_RULE="-"; G_BAR="|"
    G_OK="+"; G_BAD="x"; G_WARN="!"; G_INFO="."; G_PROMPT=">"
    SPIN=("-" "\\" "|" "/")
fi

# Four tiny shortcuts so the rest of the script reads like plain English.
say_ok()   { printf '   %s%s%s  %s\n'   "$C_LIVE"  "$G_OK"   "$C_OFF" "$*"; }
say_warn() { printf '   %s%s%s  %s%s%s\n' "$C_WARN" "$G_WARN" "$C_OFF" "$C_WARN" "$*" "$C_OFF"; }
say_err()  { printf '   %s%s%s  %s%s%s\n' "$C_DOWN" "$G_BAD"  "$C_OFF" "$C_DOWN" "$*" "$C_OFF"; }
say_info() { printf '   %s%s  %s%s\n'   "$C_FAINT" "$G_INFO" "$*" "$C_OFF"; }

# --- A LINE ACROSS THE SCREEN ------------------------------------------------
# A hairline rule. Used to separate one area of the screen from the next, which
# does the same job as a blank line but reads as more deliberate.
ui_rule() {
    local i line=""
    for ((i = 0; i < 54; i++)); do line="${line}${G_RULE}"; done
    printf '   %s%s%s\n' "$C_FAINT" "$line" "$C_OFF"
}

# --- A SMALL HEADING ---------------------------------------------------------
# A short amber bar followed by a quiet label, e.g.  ▌ SIGNAL
ui_eyebrow() {
    printf '\n   %s%s%s %s%s%s\n\n' "$C_ACCENT" "$G_BAR" "$C_OFF" "$C_MUTED" "$1" "$C_OFF"
}

# --- THE SPINNING "PLEASE WAIT" MARK -----------------------------------------
# When we are waiting for something slow (like Cloudflare accepting the tunnel)
# a still screen looks frozen, and people reasonably assume it has crashed.
# A little spinning mark plus a seconds counter says "still working, hang on".
#
# The "\r" at the start means "jump back to the beginning of this line", which
# is how we redraw over the top of ourselves instead of filling the screen.
ui_waiting() {
    local seconds="$1" message="$2"
    [ "$UI_TTY" = "1" ] || return 0
    local frame="${SPIN[$(( seconds % ${#SPIN[@]} ))]}"
    printf '\r   %s%s%s  %s %s(%ss)%s ' \
        "$C_ACCENT" "$frame" "$C_OFF" "$message" "$C_FAINT" "$seconds" "$C_OFF"
}

# Wipes the spinner line clean once the waiting is over, so the final result
# message doesn't get printed on top of leftover spinner text.
ui_waiting_done() {
    [ "$UI_TTY" = "1" ] || return 0
    printf '\r%*s\r' 70 ''
}

# --- IS THIS PROGRAM STILL ALIVE? --------------------------------------------
# "kill -0" sounds scary but it kills nothing. It's the polite way of asking
# Linux "does a program with this ID number still exist?" It answers yes or no.
is_alive() {
    local pid="$1"
    # If we were handed something that isn't a plain number, the answer is no.
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

# --- REMEMBER A PROGRAM WE STARTED -------------------------------------------
# Writes one ID number into the notebook, along with a friendly label so a
# human peeking at the file can tell which line is which.
remember_pid() {
    local label="$1" pid="$2"
    printf '%s %s\n' "$pid" "$label" >> "$PID_FILE"
}

# --- SWITCH OFF A PROGRAM *AND* ALL ITS HELPERS ------------------------------
# Programs often start helpers of their own. npm, for example, starts webpack.
# If we only switch off npm, webpack carries on running by itself - an orphan.
#
# Linux keeps related programs together in a "process group" (think: a family,
# all sharing one family number). Because we started them with setsid, each
# program we launched is the head of its own family. So we look up the family
# number and switch off the whole family in one go.
#
# The minus sign in "kill -- -1234" is what means "the FAMILY numbered 1234"
# rather than "the single program numbered 1234". It is easy to miss but it is
# the entire trick.
kill_family() {
    local pid="$1" signal="$2"

    is_alive "$pid" || return 0

    # Ask Linux which family this program belongs to.
    local pgid
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"

    # Safety check: never switch off our OWN family, or we'd kill this script
    # halfway through its own tidying up.
    if [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
        kill "$signal" -- "-$pgid" 2>/dev/null && return 0
    fi

    # Fallback, if the family trick didn't work for some reason: switch off the
    # program itself, then hunt down any children it left behind.
    kill "$signal" "$pid" 2>/dev/null
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill "$signal" "$child" 2>/dev/null
    done
}

# --- FIND STRAYS THAT BELONG TO *THIS* PROJECT -------------------------------
# A last sweep for anything still running from this project. We are deliberately
# fussy about what we switch off: a program only counts as ours if it is BOTH
# a build tool AND standing inside this project's folder. Being that careful
# means this script can never accidentally shut down somebody else's unrelated
# work on the same computer.
#
# We insist on THREE things being true before switching anything off, because
# a careless match here really can shoot down the wrong program:
#   1. its command line mentions this project's gunicorn or its build tool,
#   2. it is standing inside this project's folder,
#   3. it really is a Python or Node program.
# Rule 3 is what stops us from switching off, say, a text editor or a search
# that merely happens to have the word "gunicorn" typed inside it.
sweep_project_strays() {
    local pid cwd exe

    for pid in $(pgrep -f "$GUNICORN_BIN|laravel-mix/bin/cli.js|webpack --watch" 2>/dev/null); do
        # Never switch off ourselves, or whoever launched us.
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue

        # /proc/<id>/cwd tells us which folder that program is standing in.
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        [ "$cwd" = "$PROJECT_DIR" ] || continue

        # /proc/<id>/exe tells us which actual program is running.
        exe="$(basename "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null)"
        case "$exe" in
            node|node*|python|python*) ;;   # ours - fine to switch off
            *) continue ;;                  # something else - leave it alone
        esac

        kill -9 "$pid" 2>/dev/null && say_info "Swept up a stray from this project (PID $pid)"
    done
}

# --- IS *OUR* INTERNET TUNNEL CURRENTLY ON? ----------------------------------
# Note we look specifically for OUR tunnel by name. Just asking "is any
# cloudflared running?" would give the wrong answer, because a different tunnel
# (Presspoint-Server) runs on this computer all the time and would fool us into
# thinking the website was published when it wasn't.
# It returns the ID numbers of any REAL cloudflared programs running our tunnel.
# We double-check that each one really is the cloudflared program itself, and
# not just some other command that happens to have the words "cloudflared" and
# "presspoint-tunnel" typed inside it (a search, a text editor, or even this
# very script). Getting that wrong means switching off innocent bystanders.
tunnel_pids() {
    local pid exe
    for pid in $(pgrep -f "cloudflared.*$TUNNEL_NAME" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        exe="$(basename "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null)"
        [ "$exe" = "cloudflared" ] || continue
        printf '%s\n' "$pid"
    done
}

tunnel_is_up() {
    [ -n "$(tunnel_pids)" ]
}

# --- IS ANYTHING FROM A PREVIOUS RUN STILL GOING? ----------------------------
# Reads the notebook and checks each ID. Answers "yes" if even one is alive.
stack_is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid _label
    while read -r pid _label; do
        is_alive "$pid" && return 0
    done < "$PID_FILE"
    return 1
}

# =============================================================================
#  SECTION 3 — PREFLIGHT: DO WE HAVE ALL THE TOOLS?
# =============================================================================
# Before doing anything, check that every program we depend on actually exists.
# It is much friendlier to say "npm is missing, here's how to install it" than
# to let the user press 1 and watch it explode.
check_tools() {
    local missing=0

    ui_header big
    ui_rule
    ui_eyebrow "PREFLIGHT"

    # Does the project folder even exist? Nothing else matters if it doesn't.
    if [ -d "$PROJECT_DIR" ]; then
        say_ok "Project folder found: $PROJECT_DIR"
    else
        say_err "Project folder NOT found: $PROJECT_DIR"
        say_info "Fix: open this script and change PROJECT_DIR near the top."
        missing=1
    fi

    # The Python toolbox.
    if [ -f "$VENV_ACTIVATE" ]; then
        say_ok "Python toolbox (venv) found"
    else
        say_err "Python toolbox missing: $VENV_ACTIVATE"
        say_info "Fix: cd $PROJECT_DIR && python3 -m venv venv"
        missing=1
    fi

    # gunicorn — the website engine. Must be the one INSIDE the toolbox.
    if [ -x "$GUNICORN_BIN" ]; then
        say_ok "gunicorn found (inside the venv)"
    else
        say_err "gunicorn missing: $GUNICORN_BIN"
        say_info "Fix: source $VENV_ACTIVATE && pip install gunicorn"
        missing=1
    fi

    # npm — the thing that builds the CSS and JavaScript.
    if command -v npm >/dev/null 2>&1; then
        say_ok "npm found ($(command -v npm))"
    else
        say_err "npm is not installed"
        say_info "Fix: install Node.js 18, e.g. via nvm  ->  nvm install 18"
        missing=1
    fi

    # curl — the watchman uses this to check the public address every few
    # seconds. Without it, the site still works, but nothing notices if it
    # breaks.
    if command -v curl >/dev/null 2>&1; then
        say_ok "curl found (needed for the watchman's health checks)"
    else
        say_warn "curl is not installed - the watchman cannot check the site."
        say_info "Fix: sudo apt install curl"
    fi

    # cloudflared — the internet tunnel.
    if command -v cloudflared >/dev/null 2>&1; then
        say_ok "cloudflared found ($(command -v cloudflared))"
    else
        say_warn "cloudflared is not on the PATH"
        say_info "The site will still work on this computer, but will not be"
        say_info "reachable from the internet."
    fi

    # The tunnel's login certificate. Without it, cloudflared has no idea which
    # Cloudflare account the tunnel name belongs to and simply refuses to run.
    if [ -f "$HOME/.cloudflared/cert.pem" ]; then
        say_ok "Cloudflare login certificate found"
    else
        say_warn "No ~/.cloudflared/cert.pem - the tunnel will not start."
        say_info "Fix: cloudflared tunnel login"
    fi

    # nginx is the doorman that stands on port 80 and passes visitors to the
    # socket. The tunnel points at port 80, so if nginx is off, the public site
    # breaks even though everything else looks perfectly healthy.
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            say_ok "nginx is running (it listens on port 80 for the tunnel)"
        else
            say_warn "nginx is NOT running - the public web address will fail."
            say_info "Fix: sudo systemctl start nginx"
        fi
    fi

    if [ "$missing" -ne 0 ]; then
        printf '\n'
        say_warn "Some required tools are missing (see FAIL lines above)."
        say_warn "Pressing 1 will probably not work until those are fixed."
    fi
    printf '\n'
}

# =============================================================================
#  SECTION 4 — USE THE RIGHT VERSION OF NODE
# =============================================================================
# This project was built for Node version 18 (it says so in the .nvmrc file).
# This computer's default Node is much newer, and the build tool PressPoint uses
# is old enough that a newer Node can make it fail in a very confusing way.
# "nvm" is a little program that can switch between Node versions on demand,
# so we ask it to switch to whatever .nvmrc asks for, just for us.
use_project_node() {
    local nvm_script="$HOME/.nvm/nvm.sh"

    if [ ! -s "$nvm_script" ]; then
        say_warn "nvm not found - using whatever Node is currently default."
        say_info "Current Node: $(node -v 2>/dev/null || echo 'not installed')"
        return 0
    fi

    # shellcheck disable=SC1090
    # "source" means: run this file's contents as if they were typed here, so
    # that the "nvm" command becomes available to us.
    . "$nvm_script" >/dev/null 2>&1

    # With no version number, "nvm use" reads the .nvmrc file in the current
    # folder and switches to the version written inside it (here: 18).
    if nvm use >/dev/null 2>&1; then
        say_ok "Switched Node to $(node -v) (as requested by .nvmrc)"
    else
        say_warn "Could not switch Node version - .nvmrc asks for $(cat "$PROJECT_DIR/.nvmrc" 2>/dev/null || echo '?')"
        say_info "Fix: nvm install 18"
        say_info "Continuing with Node $(node -v 2>/dev/null || echo 'unknown')"
    fi
}

# =============================================================================
#  SECTION 5 — OPTION 1: START EVERYTHING
# =============================================================================
start_stack() {
    ui_header
    ui_rule
    ui_eyebrow "STARTING UP"

    # --- Guard: don't start twice -------------------------------------------
    # If things are already running, starting a second copy would cause two
    # programs to fight over the same doorway. So we refuse politely.
    if stack_is_running; then
        say_warn "PressPoint already appears to be running."
        say_info "Press 2 to stop it first, then press 1 again."
        return 1
    fi
    if [ -f "$MONITOR_PID_FILE" ] && is_alive "$(cat "$MONITOR_PID_FILE" 2>/dev/null)"; then
        say_warn "The watchman is already running from an earlier start."
        say_info "Press 2 to stop it first, then press 1 again."
        return 1
    fi

    # --- Step 0: which screen is showing the site? ---------------------------
    kiosk_pick_target || return 1
    resolve_local_fallback_url
    ui_header
    ui_rule
    ui_eyebrow "STARTING UP"
    say_ok "Kiosk screen: $(kiosk_target_name)"

    # A leftover notebook from a crashed run would only confuse us. Start fresh.
    rm -f "$PID_FILE"

    # --- Step 1: go to the project folder -----------------------------------
    # Everything after this must happen from inside the project folder, because
    # npm and gunicorn both look for files relative to where they are standing.
    if ! cd "$PROJECT_DIR"; then
        say_err "Could not enter $PROJECT_DIR - is the path correct?"
        return 1
    fi
    say_ok "Moved into the project folder"

    # --- Step 2: open the Python toolbox ------------------------------------
    if [ -f "$VENV_ACTIVATE" ]; then
        # shellcheck disable=SC1090
        . "$VENV_ACTIVATE"
        say_ok "Activated the Python virtual environment"
    else
        say_err "Cannot activate the venv - $VENV_ACTIVATE is missing."
        return 1
    fi

    # --- Step 3: pick the right Node, then start the asset builder ----------
    use_project_node

    if command -v npm >/dev/null 2>&1; then
        # The "&" at the end means "run this in the background and give me my
        # prompt back straight away". The ">>" sends its chatter to the diary,
        # and "2>&1" means "send the error chatter to the same place".
        #
        # "setsid" puts this program into its own little family group. That is
        # important: npm starts helpers of its own (webpack and friends), and
        # switching off only npm would leave those helpers running forever like
        # lights left on in an empty house. Because of setsid we can later
        # switch off the whole family in one go.
        setsid npm run "$NPM_SCRIPT" >> "$LOG_NPM" 2>&1 &
        # "$!" is Linux handing us the ID number of the program we just started.
        local npm_pid=$!
        remember_pid "npm-$NPM_SCRIPT" "$npm_pid"
        say_ok "Asset builder running: npm run $NPM_SCRIPT  ${C_FAINT}pid $npm_pid${C_OFF}"
    else
        say_warn "npm missing - skipping the asset build step."
    fi

    # --- Step 4: clear away any old doorway ---------------------------------
    # If the computer was switched off badly, an old socket file can be left
    # behind. gunicorn refuses to start if one is already sitting there, so we
    # sweep it away first.
    if [ -e "$SOCKET_PATH" ]; then
        rm -f "$SOCKET_PATH"
        say_info "Removed a leftover socket file from a previous run"
    fi

    # --- Step 5: start the website engine -----------------------------------
    if [ ! -x "$GUNICORN_BIN" ]; then
        say_err "gunicorn is missing - the website cannot start."
        return 1
    fi

    # This is the heart of the whole script. Read it as:
    #   "run gunicorn, with 3 helpers, listening at the doorway file
    #    presspoint.sock, serving the app found in wsgi.py"
    # (setsid again, so gunicorn and its 3 workers form one family we can
    #  switch off together - see the longer explanation up at the npm step.)
    setsid "$GUNICORN_BIN" \
        --workers "$GUNICORN_WORKERS" \
        --bind "unix:$SOCKET_NAME" \
        "$WSGI_APP" >> "$LOG_GUNICORN" 2>&1 &
    local gunicorn_pid=$!
    remember_pid "gunicorn" "$gunicorn_pid"
    # --- Step 6: wait until the doorway actually appears --------------------
    # Starting a program is not the same as the program working. We watch for
    # the socket file to show up. If gunicorn dies instead, we show the last
    # few lines of its diary so the user can see the real reason.
    local waited=0
    local started=0
    while [ "$waited" -lt "$STARTUP_TIMEOUT" ]; do
        ui_waiting "$waited" "starting the website engine"
        if ! is_alive "$gunicorn_pid"; then
            ui_waiting_done
            say_err "The website engine stopped straight away. Here is why:"
            printf '%s' "$C_FAINT"
            tail -n 20 "$LOG_GUNICORN" 2>/dev/null | sed 's/^/      /'
            printf '%s\n' "$C_OFF"
            return 1
        fi
        if [ -S "$SOCKET_PATH" ]; then
            started=1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    ui_waiting_done

    if [ "$started" -eq 1 ]; then
        say_ok "Website engine listening on $SOCKET_NAME  ${C_FAINT}pid $gunicorn_pid, $GUNICORN_WORKERS workers${C_OFF}"
    else
        say_warn "The engine is running but the doorway never appeared after ${STARTUP_TIMEOUT}s."
        say_info "Check the diary: $LOG_GUNICORN"
    fi

    # --- Step 7: put the site on the internet -------------------------------
    # We start the tunnel ourselves, by name, so we know it is the RIGHT one
    # (see the big warning about Error 1033 in the settings box at the top).
    # No password is needed, because this runs as you and not as an administrator.
    if ! command -v cloudflared >/dev/null 2>&1; then
        say_warn "cloudflared is not installed - the site works on this"
        say_warn "computer only, and not on the internet."
    elif tunnel_is_up; then
        say_ok "Internet tunnel '$TUNNEL_NAME' was already running"
    else
        # Wipe this one diary before we start. We are about to read it to find
        # out whether the tunnel connected, and yesterday's "connected!" note
        # would happily fool us into thinking today's tunnel worked.
        : > "$LOG_TUNNEL"

        # Read this as: "open the tunnel called presspoint-tunnel, and send
        #                everyone who arrives to nginx on port 80"
        setsid cloudflared tunnel \
            --protocol "$TUNNEL_PROTOCOL" \
            --url "$TUNNEL_TARGET_URL" \
            run "$TUNNEL_NAME" >> "$LOG_TUNNEL" 2>&1 &
        local tunnel_pid=$!
        remember_pid "cloudflared" "$tunnel_pid"
        # A tunnel is only useful once Cloudflare has actually accepted it.
        # Until then, visitors get "Error 1033". So we wait and watch the diary
        # for the words that mean "Cloudflare said yes". This is the slowest
        # step by far, which is why it gets the spinning "please wait" mark.
        local twait=0 tready=0
        while [ "$twait" -lt "$TUNNEL_TIMEOUT" ]; do
            ui_waiting "$twait" "asking Cloudflare to accept the tunnel"
            if ! is_alive "$tunnel_pid"; then
                ui_waiting_done
                say_err "The tunnel stopped straight away. Here is why:"
                printf '%s' "$C_FAINT"
                tail -n 15 "$LOG_TUNNEL" 2>/dev/null | sed 's/^/      /'
                printf '%s\n' "$C_OFF"
                break
            fi
            if grep -q "Registered tunnel connection" "$LOG_TUNNEL" 2>/dev/null; then
                tready=1
                break
            fi
            sleep 1
            twait=$((twait + 1))
        done
        ui_waiting_done

        if [ "$tready" -eq 1 ]; then
            say_ok "Tunnel accepted by Cloudflare  ${C_FAINT}pid $tunnel_pid, took ${twait}s${C_OFF}"
        elif is_alive "$tunnel_pid"; then
            say_warn "Tunnel is running but Cloudflare has not accepted it yet."
            say_warn "If your browser shows Error 1033, wait a few seconds and retry."
            say_info "Diary: $LOG_TUNNEL"
        fi
    fi

    # --- Step 8: open the kiosk screen ---------------------------------------
    printf '\n'
    ui_rule
    ui_eyebrow "THE KIOSK SCREEN"
    KIOSK_BROWSER_BIN="$(detect_browser)"
    if [ -z "$KIOSK_BROWSER_BIN" ]; then
        say_warn "No known browser found on $(kiosk_target_name) - skipping it."
        say_info "Install one of: ${KIOSK_BROWSER_PRIORITY[*]}"
    else
        say_ok "Using $KIOSK_BROWSER_BIN in kiosk mode on $(kiosk_target_name)"
        kiosk_relaunch "$PUBLIC_URL"
        if [ -n "$KIOSK_BROWSER_PID" ]; then
            say_ok "Kiosk screen opened  ${C_FAINT}pid $KIOSK_BROWSER_PID${C_OFF}"
        else
            say_warn "Could not confirm the kiosk browser started."
        fi
    fi

    # --- Step 9: start the watchman ------------------------------------------
    start_monitor

    # --- Step 10: the happy summary -------------------------------------------
    # We show the same signal chain as the main menu. Seeing the identical
    # picture in both places means there is only one thing to learn to read.
    printf '\n'
    ui_rule
    ui_eyebrow "ON AIR"
    show_status
    printf '\n'
    printf '   %s%-9s%s %s%s%s\n' "$C_MUTED" "socket"  "$C_OFF" "$C_FAINT" "$SOCKET_PATH" "$C_OFF"
    printf '   %s%-9s%s %s%s%s\n' "$C_MUTED" "logs"    "$C_OFF" "$C_FAINT" "$LOG_NPM" "$C_OFF"
    printf '   %s%-9s%s %s%s%s\n' "$C_MUTED" ""        "$C_OFF" "$C_FAINT" "$LOG_GUNICORN" "$C_OFF"
    printf '   %s%-9s%s %s%s%s\n' "$C_MUTED" ""        "$C_OFF" "$C_FAINT" "$LOG_TUNNEL" "$C_OFF"
    printf '   %s%-9s%s %s%s%s\n' "$C_MUTED" ""        "$C_OFF" "$C_FAINT" "$LOG_EVENTS" "$C_OFF"
    printf '\n'
}

# =============================================================================
#  SECTION 6 — OPTION 2: STOP EVERYTHING
# =============================================================================
stop_stack() {
    ui_header
    ui_rule
    ui_eyebrow "SHUTTING DOWN"

    # --- Step 1: switch off everything in the notebook ----------------------
    if [ -f "$PID_FILE" ]; then
        local pid label
        while read -r pid label; do
            if is_alive "$pid"; then
                # "-TERM" is a tap on the shoulder: "please finish up nicely".
                kill_family "$pid" "-TERM"
                say_info "Asked $label (PID $pid) and its helpers to stop"
            fi
        done < "$PID_FILE"

        # Give them three seconds of good manners to close down tidily.
        sleep 3

        # Anyone still ignoring us gets "-KILL", which is not a request.
        while read -r pid label; do
            if is_alive "$pid"; then
                kill_family "$pid" "-KILL"
                say_warn "$label (PID $pid) ignored us - forced it to stop"
            fi
        done < "$PID_FILE"
        say_ok "All recorded programs stopped"
    else
        say_info "No notebook file found - nothing was recorded as running"
    fi

    # --- Step 2: careful sweep for stragglers -------------------------------
    # Belt and braces. If anything from this project somehow survived Step 1,
    # this catches it. It only touches programs standing inside THIS project's
    # folder - see sweep_project_strays() up in Section 2 for why that matters.
    # (A blunt "kill anything called gunicorn" could shoot down somebody else's
    #  completely unrelated website on this same computer. We don't do that.)
    sweep_project_strays

    # --- Step 3: close the internet tunnel ----------------------------------
    # Step 1 already switched off the tunnel we started, because its ID number
    # was written in the notebook like everything else. This is just a check for
    # a leftover from a run whose notebook went missing.
    #
    # Notice we hunt for our tunnel BY NAME. There is another tunnel
    # (Presspoint-Server) that Linux runs by itself on this computer, and it is
    # none of our business - switching it off could break something else.
    if tunnel_is_up; then
        local tpid
        for tpid in $(tunnel_pids); do kill "$tpid" 2>/dev/null; done
        sleep 1
        for tpid in $(tunnel_pids); do kill -9 "$tpid" 2>/dev/null; done
        say_ok "Internet tunnel '$TUNNEL_NAME' closed - public site is offline"
    fi

    # --- Step 4: close the kiosk screen and the watchman ---------------------
    # A LOCAL kiosk browser was already stopped in Step 1 - it was written
    # into the same notebook as everything else, under the label
    # "kiosk-browser". A REMOTE one was not, so we close it here by hand.
    if [ -n "$KIOSK_BROWSER_PID" ] && [ -n "$KIOSK_ACTIVE_HOST" ]; then
        kiosk_run "kill $KIOSK_BROWSER_PID" >/dev/null 2>&1
        say_ok "Kiosk screen on $(kiosk_target_name) closed"
    fi
    stop_monitor
    say_ok "Watchman stopped"

    # --- Step 5: tidy up the leftovers --------------------------------------
    # The doorway file and the notebook are both meaningless now, and leaving
    # them behind would confuse the next start. Bin them.
    rm -f "$SOCKET_PATH" "$PID_FILE"
    say_ok "Cleaned up the socket file and the PID notebook"

    printf '\n'
    ui_rule
    ui_eyebrow "OFF AIR"
    show_status
    printf '\n'
}

# =============================================================================
#  SECTION 7 — THE LIVE STATUS BOARD
# =============================================================================
# Shown above the menu every time, so you can always see what is on and off
# without having to remember what you pressed last.
# Why a chain and not a plain list? Because these three really ARE a chain:
# the builder feeds the engine, and the engine feeds the tunnel that carries
# the site to the outside world. Drawing it this way means you don't just see
# THAT something is off, you see WHERE the chain breaks - and everything to the
# right of the break is the part the public cannot reach.
#
#     ●━━━━━━━━━━━●━━━━━━━━━━━○
#     build        engine       on air
#     pid 117668   pid 117669   stopped
#
# A filled dot (●) means running. A hollow dot (○) means stopped.

# Draws one dot: filled and green if that thing is running, hollow and red if not.
ui_dot() {
    if [ -n "$1" ]; then printf '%s%s%s' "$C_LIVE" "$G_ON" "$C_OFF"
    else                 printf '%s%s%s' "$C_DOWN" "$G_OFF" "$C_OFF"; fi
}

# Draws the joining line between two dots. It only lights up when BOTH ends are
# running, because a chain with a dead link isn't carrying anything.
ui_link() {
    local i line=""
    for ((i = 0; i < 11; i++)); do line="${line}${G_LINK}"; done
    if [ -n "$1" ] && [ -n "$2" ]; then printf '%s%s%s' "$C_LIVE" "$line" "$C_OFF"
    else                                printf '%s%s%s' "$C_FAINT" "$line" "$C_OFF"; fi
}

show_status() {
    # Empty means "not running". A number means "running, and here's its ID".
    local npm_pid="" gun_pid="" tun_pid=""

    if [ -f "$PID_FILE" ]; then
        local pid label
        while read -r pid label; do
            if is_alive "$pid"; then
                case "$label" in
                    npm-*)       npm_pid="$pid" ;;
                    gunicorn)    gun_pid="$pid" ;;
                    cloudflared) tun_pid="$pid" ;;
                esac
            fi
        done < "$PID_FILE"
    fi

    # Catch a tunnel that is running but isn't in our notebook (e.g. left over
    # from a previous run whose notebook was deleted).
    if [ -z "$tun_pid" ]; then
        tun_pid="$(tunnel_pids | head -1)"
    fi

    # Row 1: the chain of dots and connecting lines.
    printf '   %s%s%s%s%s\n' \
        "$(ui_dot "$npm_pid")" "$(ui_link "$npm_pid" "$gun_pid")" \
        "$(ui_dot "$gun_pid")" "$(ui_link "$gun_pid" "$tun_pid")" \
        "$(ui_dot "$tun_pid")"

    # Row 2: what each dot is called.
    printf '   %s%-12s%-12s%s%s\n' "$C_BOLD" "build" "engine" "on air" "$C_OFF"

    # Row 3: the ID number if running, or the word "stopped" if not.
    local a b c
    [ -n "$npm_pid" ] && a="pid $npm_pid" || a="stopped"
    [ -n "$gun_pid" ] && b="pid $gun_pid" || b="stopped"
    [ -n "$tun_pid" ] && c="pid $tun_pid" || c="stopped"
    printf '   %s%-12s%-12s%s%s\n' "$C_FAINT" "$a" "$b" "$c" "$C_OFF"

    # And the one line most people actually care about: can the public see it?
    printf '\n'
    if [ -n "$gun_pid" ] && [ -n "$tun_pid" ]; then
        printf '   %s%s live%s  %s%s%s\n' \
            "$C_LIVE" "$G_ON" "$C_OFF" "$C_MUTED" "$PUBLIC_URL" "$C_OFF"
    else
        printf '   %s%s offline%s  %sthe public cannot reach the site%s\n' \
            "$C_DOWN" "$G_OFF" "$C_OFF" "$C_FAINT" "$C_OFF"
    fi
}

# =============================================================================
#  SECTION 8 — THE MENU YOU ACTUALLY SEE
# =============================================================================
# The name plate at the top of the screen. The name sits in a solid amber block
# so it reads as a badge rather than as just more text, with a one-line
# description of what this script does sitting quietly underneath.
# --- THE BRAND ---------------------------------------------------------------
# The LINUX YIELD NETWORK wordmark, drawn out of solid block characters.
# Flat and solid on purpose - no fades, no shadows, no gradients.
#
# TWEAK THIS if you ever rebrand. Keep every line in a block the same length as
# the others, or the letters will come out crooked.
LOGO_A=(
"█    ████ █  █ █  █ █  █    █  █ ████ ████ █    ███ "
"█     ██  ██ █ █  █  ██     █  █  ██  █    █    █  █"
"█     ██  █ ██ █  █  ██      ██   ██  ███  █    █  █"
"█     ██  █  █ █  █  ██      ██   ██  █    █    █  █"
"████ ████ █  █ ████ █  █     ██  ████ ████ ████ ███ "
)
LOGO_B=(
"█  █ ████ ████ █  █ ████ ███  █  █"
"██ █ █     ██  █  █ █  █ █  █ █ █ "
"█ ██ ███   ██  █ ██ █  █ ███  ██  "
"█  █ █     ██  ████ █  █ █ █  █ █ "
"█  █ ████  ██  █  █ ████ █  █ █  █"
)

# Draws the name plate at the top of every screen.
#
# The big wordmark is eleven rows tall, which is lovely on a roomy window and
# a disaster on a small one - it would push the menu off the bottom of the
# screen. So we measure the window first and only draw the big version when
# there is genuinely room for it. Otherwise we draw a one-line version that
# says exactly the same thing. The brand is never lost, only resized.
#
# Pass "big" as the first argument on screens that have little else on them
# (like the opening check), where the wordmark fits more easily.
ui_header() {
    local mode="${1:-normal}"
    local cols rows min_rows
    cols="$(tput cols 2>/dev/null || echo 80)"
    rows="$(tput lines 2>/dev/null || echo 24)"
    [ "$mode" = "big" ] && min_rows=20 || min_rows=34

    printf '\n'

    # We need a UTF-8 terminal (for the block characters), enough width for the
    # letters, and enough height that the menu still fits underneath.
    if [ "$G_ON" = "●" ] && [ "$cols" -ge 56 ] && [ "$rows" -ge "$min_rows" ]; then
        local line
        for line in "${LOGO_A[@]}"; do printf '   %s%s%s\n' "$C_ACCENT" "$line" "$C_OFF"; done
        printf '\n'   # a breathing space, so the two words don't collide
        for line in "${LOGO_B[@]}"; do printf '   %s%s%s\n' "$C_ACCENT" "$line" "$C_OFF"; done
        printf '\n   %sPressPoint broadcast control%s\n\n' "$C_FAINT" "$C_OFF"
    else
        printf '   %s%s%s %sLINUX YIELD NETWORK%s\n' \
            "$C_ACCENT" "$G_BAR" "$C_OFF" "$C_BOLD" "$C_OFF"
        printf '   %s  PressPoint broadcast control%s\n\n' "$C_FAINT" "$C_OFF"
    fi
}

# One keycap plus its label, e.g.   1  start the website
# The label column is 7 wide because "receive" is the longest word any menu
# uses. Too narrow and that one row shunts its description sideways, which
# makes the whole list look accidental.
ui_key() {
    printf '   %s %s %s  %s%-7s%s %s%s%s\n' \
        "$C_KEY" "$1" "$C_OFF" "$C_BOLD" "$2" "$C_OFF" "$C_FAINT" "$3" "$C_OFF"
}

show_menu() {
    ui_header
    ui_rule
    ui_eyebrow "SIGNAL"
    show_status
    printf '\n'
    ui_rule
    ui_eyebrow "CONTROLS"
    ui_key "1" "start"  "bring the website online"
    ui_key "2" "stop"   "take it offline and tidy up"
    ui_key "3" "clone"  "copy this whole setup to another computer"
    ui_key "4" "logs"   "watch build, engine, tunnel and watchman live"
    ui_key "q" "quit"   "leave this menu, keep the site running"
    printf '\n   %spress a key%s\n' "$C_FAINT" "$C_OFF"
    printf '   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
}

# =============================================================================
#  SECTION 9 — TALKING TO THE OTHER COMPUTER
# =============================================================================
# Everything in this section is about reaching across the network. Nothing here
# changes anything by itself; it is the plumbing that Section 10 uses.
#
# WHY NOT GIT?
# The original plan was to send the code with git. Git is wonderful at what it
# does, but it only carries files you have COMMITTED - and the things that make
# the difference between "the code is there" and "the website actually works"
# are all files git deliberately refuses to track:
#
#     .env ................ the passwords and settings
#     the database ........ every news article ever written
#     the media folder .... the archive PDFs and videos
#     ~/.cloudflared ...... the keys that open the internet tunnel
#
# So we copy files directly instead, with a tool called rsync. One method for
# everything, and nothing gets left behind because somebody forgot to commit.

# Which way round are we copying? Set by the menu before anything else runs.
#     "send"    = this computer has the working setup, the other one gets it
#     "receive" = the other computer has it, and this one is being set up
CLONE_DIRECTION=""

# --- THE ADDRESS OF THE OTHER COMPUTER ---------------------------------------
# Glues the username and address together into the form ssh expects.
peer_target() { printf '%s@%s' "$PEER_USER" "$PEER_HOST"; }

# The settings we hand to ssh every single time.
#
# "ControlMaster" is worth knowing about: a clone makes dozens of separate
# connections, and without this each one would log in from scratch. Instead the
# first connection stays open quietly in the background and all the others ride
# along inside it. It is the difference between a clone taking two minutes and
# taking ten.
#
# "BatchMode=yes" means "never stop and ask for a password". We want key-based
# login only; if the key is not set up we would rather fail with a clear
# explanation than leave a password prompt hanging in the middle of a copy.
SSH_CTL_DIR=""

# Note the SINGLE % signs in ControlPath below. Those are ssh's own shorthand
# for user/host/port and must reach ssh exactly as written. printf only expands
# % signs inside its FORMAT string, never inside the text it is handed - so
# writing %%r here would hand ssh a literal "%%r" and every single connection
# would fail with an error that points nowhere near the real cause.
peer_ssh_opts() {
    printf '%s' "-p $PEER_PORT -o BatchMode=yes -o ConnectTimeout=8 \
-o StrictHostKeyChecking=accept-new -o ControlMaster=auto \
-o ControlPath=$SSH_CTL_DIR/%r@%h:%p -o ControlPersist=120"
}

# One tidy-up point for every kind of SSH connection this script opens
# (the clone feature's, and separately the kiosk feature's). Both call this
# same function when they connect, so neither one's cleanup gets forgotten
# just because the other set the EXIT trap more recently.
lyn_exit_cleanup() {
    [ -n "$SSH_CTL_DIR" ] && peer_disconnect
    [ -n "$KIOSK_SSH_CTL_DIR" ] && kiosk_disconnect
}

# Open the shared connection, and arrange to close it when the script exits.
peer_connect() {
    [ -n "$SSH_CTL_DIR" ] && return 0
    SSH_CTL_DIR="$(mktemp -d /tmp/lyn-ssh.XXXXXX)"
    trap lyn_exit_cleanup EXIT
}

peer_disconnect() {
    [ -n "$SSH_CTL_DIR" ] || return 0
    # shellcheck disable=SC2046
    ssh $(peer_ssh_opts) -O exit "$(peer_target)" 2>/dev/null
    rm -rf "$SSH_CTL_DIR"
    SSH_CTL_DIR=""
}

# Run one command over there and hand back whatever it printed.
peer_ssh() {
    # shellcheck disable=SC2046
    ssh $(peer_ssh_opts) "$(peer_target)" "$1"
}

# --- CAN WE ACTUALLY REACH IT? -----------------------------------------------
# Checked before anything else, because every other failure in this section
# looks identical from the outside if the answer here is "no".
peer_reachable() {
    peer_connect
    peer_ssh true 2>/dev/null
}

# --- ASK FOR THE ADDRESS IF WE DON'T HAVE ONE --------------------------------
ask_peer_address() {
    [ -n "$PEER_HOST" ] && return 0

    printf '\n   %sWhat is the other computer'\''s address?%s\n' "$C_BOLD" "$C_OFF"
    printf '   %san IP like 192.168.1.50, or a name from ~/.ssh/config%s\n\n' "$C_FAINT" "$C_OFF"
    printf '   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
    read -r PEER_HOST

    if [ -z "$PEER_HOST" ]; then
        say_err "No address given - going back."
        return 1
    fi

    printf '   %sand the username there?%s %s[%s]%s ' \
        "$C_BOLD" "$C_OFF" "$C_FAINT" "$PEER_USER" "$C_OFF"
    local answer
    read -r answer
    [ -n "$answer" ] && PEER_USER="$answer"

    # The folder settings were worked out from the old username, so if the name
    # just changed they are now pointing at a home folder that does not exist.
    PEER_PROJECT_DIR="/home/$PEER_USER/Downloads/presspoint"
    PEER_LYN_DIR="/home/$PEER_USER/lyn"
    return 0
}

# --- WHICH END IS WHICH? -----------------------------------------------------
# Sending and receiving move exactly the same files between exactly the same two
# computers. The only difference is which end is holding the working setup.
#
# So instead of writing the whole copy twice - once for each direction, with all
# the arguments backwards the second time - we write it ONCE in terms of
# "source" (the one that has it) and "target" (the one getting it), and let
# these three little functions work out which is which. Two copies of the same
# logic would drift apart the first time either was fixed.

# Run a command on whichever computer currently HAS the working setup.
on_source() {
    if [ "$CLONE_DIRECTION" = "send" ]; then bash -c "$1"; else peer_ssh "$1"; fi
}

# Run a command on whichever computer is BEING SET UP.
on_target() {
    if [ "$CLONE_DIRECTION" = "send" ]; then peer_ssh "$1"; else bash -c "$1"; fi
}

# Plain-English names for the two ends, used in every message and question.
source_name() {
    if [ "$CLONE_DIRECTION" = "send" ]; then printf 'this computer'
    else printf '%s' "${PEER_HOST:-the other computer}"; fi
}
target_name() {
    if [ "$CLONE_DIRECTION" = "send" ]; then printf '%s' "${PEER_HOST:-the other computer}"
    else printf 'this computer'; fi
}

# Where the working setup lives, and where it is going. Filled in once the
# direction is known, so the copy steps can just use them.
SRC_PROJECT=""; SRC_LYN=""; SRC_HOME=""
DST_PROJECT=""; DST_LYN=""; DST_HOME=""

resolve_paths() {
    if [ "$CLONE_DIRECTION" = "send" ]; then
        SRC_PROJECT="$PROJECT_DIR";      SRC_LYN="$(cd "$(dirname "$0")" && pwd)"
        SRC_HOME="$HOME"
        DST_PROJECT="$PEER_PROJECT_DIR"; DST_LYN="$PEER_LYN_DIR"
        DST_HOME="/home/$PEER_USER"
    else
        SRC_PROJECT="$PEER_PROJECT_DIR"; SRC_LYN="$PEER_LYN_DIR"
        SRC_HOME="/home/$PEER_USER"
        DST_PROJECT="$PROJECT_DIR";      DST_LYN="$(cd "$(dirname "$0")" && pwd)"
        DST_HOME="$HOME"
    fi
}

# --- COPY A FOLDER OR FILE ACROSS --------------------------------------------
# rsync only sends the parts that actually differ, so running a clone a second
# time is quick instead of copying everything again from scratch.
#
# We never pass "--delete". On the day the other computer is the live one, it
# will be holding archive PDFs and videos that editors uploaded there and this
# computer has never seen. "--delete" would mean "make the other end match mine
# exactly", which would quietly destroy every one of them.
copy_over() {
    local from="$1" to="$2"; shift 2
    local ssh_cmd; ssh_cmd="ssh $(peer_ssh_opts)"

    if [ "$CLONE_DIRECTION" = "send" ]; then
        rsync -az --info=stats1 -e "$ssh_cmd" "$@" "$from" "$(peer_target):$to"
    else
        rsync -az --info=stats1 -e "$ssh_cmd" "$@" "$(peer_target):$from" "$to"
    fi
}

# =============================================================================
#  SECTION 9B — THE KIOSK SCREEN
# =============================================================================
# This is the screen that actually shows the website to the public - a
# monitor in a lobby, a hallway, wherever. It can be this computer, or a
# completely different machine reached over SSH (Linux or Windows). Whichever
# it is, this section's job is: work out which browser it has, and open that
# browser pointed at the site with no address bar, no tabs - just the site
# filling the screen ("kiosk mode").
#
# Note this SSH connection is entirely separate from the one Section 9 uses
# for cloning. They can't get mixed up because each keeps its own control
# socket, but both share the same cleanup point - see lyn_exit_cleanup above.

# Which machine is the kiosk screen right now. Empty host means "this
# computer" - no SSH involved at all.
#
# Written with ${VAR:-} rather than a plain "" - see the same note on
# LOCAL_FALLBACK_URL near the top of the file. The watchman re-runs this
# whole script from the top with these already answered and handed to it as
# environment variables, so a plain "" here would wipe the answer out again
# before monitor_loop ever got to use it.
KIOSK_ACTIVE_HOST="${KIOSK_ACTIVE_HOST:-}"
KIOSK_ACTIVE_USER="${KIOSK_ACTIVE_USER:-}"
KIOSK_ACTIVE_PORT="${KIOSK_ACTIVE_PORT:-}"
KIOSK_ACTIVE_OS="${KIOSK_ACTIVE_OS:-linux}"

# The browser we found, and the process ID of the copy we opened. Kept here
# so the watchman (Section 9C) can check on it and relaunch it later without
# having to detect the browser all over again.
KIOSK_BROWSER_BIN="${KIOSK_BROWSER_BIN:-}"
KIOSK_BROWSER_PID="${KIOSK_BROWSER_PID:-}"

# The kiosk feature's own SSH control socket - see peer_connect's comment
# in Section 9 for what this trick buys us.
KIOSK_SSH_CTL_DIR=""

kiosk_target() { printf '%s@%s' "$KIOSK_ACTIVE_USER" "$KIOSK_ACTIVE_HOST"; }

kiosk_ssh_opts() {
    printf '%s' "-p $KIOSK_ACTIVE_PORT -o BatchMode=yes -o ConnectTimeout=8 \
-o StrictHostKeyChecking=accept-new -o ControlMaster=auto \
-o ControlPath=$KIOSK_SSH_CTL_DIR/%r@%h:%p -o ControlPersist=120"
}

kiosk_connect() {
    [ -n "$KIOSK_SSH_CTL_DIR" ] && return 0
    KIOSK_SSH_CTL_DIR="$(mktemp -d /tmp/lyn-kiosk-ssh.XXXXXX)"
    trap lyn_exit_cleanup EXIT
}

kiosk_disconnect() {
    [ -n "$KIOSK_SSH_CTL_DIR" ] || return 0
    # shellcheck disable=SC2046
    ssh $(kiosk_ssh_opts) -O exit "$(kiosk_target)" 2>/dev/null
    rm -rf "$KIOSK_SSH_CTL_DIR"
    KIOSK_SSH_CTL_DIR=""
}

kiosk_ssh() {
    kiosk_connect
    # shellcheck disable=SC2046
    ssh $(kiosk_ssh_opts) "$(kiosk_target)" "$1"
}

kiosk_reachable() {
    kiosk_ssh true 2>/dev/null
}

# Run one command wherever the kiosk screen actually is: directly, if it's
# this computer, or over SSH if it's a remote one. Every other kiosk function
# below goes through this, so none of them need to know or care which.
kiosk_run() {
    if [ -z "$KIOSK_ACTIVE_HOST" ]; then
        bash -c "$1"
    else
        kiosk_ssh "$1"
    fi
}

kiosk_target_name() {
    if [ -z "$KIOSK_ACTIVE_HOST" ]; then printf 'this computer'
    else printf '%s' "$(kiosk_target)"; fi
}

# --- REMEMBERING KIOSK SCREENS YOU'VE USED BEFORE ----------------------------
# So you only ever have to type a remote screen's address once. Stored as
# plain pipe-separated lines: name|host|user|port|os
KIOSK_KEYS=(); KIOSK_HOSTS=(); KIOSK_USERS=(); KIOSK_PORTS=(); KIOSK_OS=()

kiosk_load_targets() {
    KIOSK_KEYS=(); KIOSK_HOSTS=(); KIOSK_USERS=(); KIOSK_PORTS=(); KIOSK_OS=()
    [ -f "$KIOSK_TARGETS_FILE" ] || return 0
    local k h u p o
    while IFS='|' read -r k h u p o; do
        [ -n "$k" ] || continue
        KIOSK_KEYS+=("$k"); KIOSK_HOSTS+=("$h"); KIOSK_USERS+=("$u")
        KIOSK_PORTS+=("$p"); KIOSK_OS+=("$o")
    done < "$KIOSK_TARGETS_FILE"
}

kiosk_save_targets() {
    : > "$KIOSK_TARGETS_FILE"
    local i
    for i in "${!KIOSK_KEYS[@]}"; do
        printf '%s|%s|%s|%s|%s\n' \
            "${KIOSK_KEYS[$i]}" "${KIOSK_HOSTS[$i]}" "${KIOSK_USERS[$i]}" \
            "${KIOSK_PORTS[$i]}" "${KIOSK_OS[$i]}" >> "$KIOSK_TARGETS_FILE"
    done
}

# --- ASKING FOR A NEW REMOTE SCREEN -------------------------------------------
kiosk_add_new() {
    printf '\n   %sA short name for this screen%s %s(e.g. lobby, hallway)%s\n' \
        "$C_BOLD" "$C_OFF" "$C_FAINT" "$C_OFF"
    printf '   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
    local name; read -r name
    [ -n "$name" ] || { say_err "No name given - going back."; sleep 1; return 1; }

    printf '   %sits address%s %s(an IP like 192.168.1.60, or a name from ~/.ssh/config)%s\n' \
        "$C_BOLD" "$C_OFF" "$C_FAINT" "$C_OFF"
    printf '   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
    local host; read -r host
    [ -n "$host" ] || { say_err "No address given - going back."; sleep 1; return 1; }

    printf '   %susername there%s %s[%s]%s ' "$C_BOLD" "$C_OFF" "$C_FAINT" "$USER" "$C_OFF"
    local user; read -r user
    [ -n "$user" ] || user="$USER"

    printf '   %sSSH port%s %s[22]%s ' "$C_BOLD" "$C_OFF" "$C_FAINT" "$C_OFF"
    local port; read -r port
    [ -n "$port" ] || port="22"

    printf '   %sis that screen Linux or Windows?%s %s[l/w]%s ' \
        "$C_BOLD" "$C_OFF" "$C_FAINT" "$C_OFF"
    local osk; read -rn 1 -s osk; printf '\n'
    local os="linux"
    { [ "$osk" = "w" ] || [ "$osk" = "W" ]; } && os="windows"

    KIOSK_KEYS+=("$name"); KIOSK_HOSTS+=("$host"); KIOSK_USERS+=("$user")
    KIOSK_PORTS+=("$port"); KIOSK_OS+=("$os")
    kiosk_save_targets

    KIOSK_ACTIVE_HOST="$host"; KIOSK_ACTIVE_USER="$user"
    KIOSK_ACTIVE_PORT="$port"; KIOSK_ACTIVE_OS="$os"
    say_ok "Remembered '$name' for next time"
    sleep 1
    return 0
}

# --- THE PICKER ---------------------------------------------------------------
# Asked every time you press 1, before anything starts.
kiosk_pick_target() {
    kiosk_load_targets
    local key i

    while true; do
        clear
        ui_header
        ui_rule
        ui_eyebrow "WHERE IS THE KIOSK SCREEN?"
        printf '   %sWhich screen should show the website once it is up?%s\n\n' \
            "$C_FAINT" "$C_OFF"

        ui_key "1" "here" "this computer's own screen"

        local n=2
        for i in "${!KIOSK_KEYS[@]}"; do
            ui_key "$n" "${KIOSK_KEYS[$i]}" \
                "${KIOSK_USERS[$i]}@${KIOSK_HOSTS[$i]} (${KIOSK_OS[$i]})"
            n=$((n + 1))
        done
        ui_key "a" "add" "a new remote screen"

        printf '\n   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
        read -r key
        printf '\n'

        case "$key" in
            ""|1)
                KIOSK_ACTIVE_HOST=""; KIOSK_ACTIVE_USER=""; KIOSK_ACTIVE_PORT=""
                KIOSK_ACTIVE_OS="linux"
                return 0
                ;;
            a|A)
                kiosk_add_new && return 0
                ;;
            *[0-9]*)
                local idx=$((key - 2))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#KIOSK_KEYS[@]}" ]; then
                    KIOSK_ACTIVE_HOST="${KIOSK_HOSTS[$idx]}"
                    KIOSK_ACTIVE_USER="${KIOSK_USERS[$idx]}"
                    KIOSK_ACTIVE_PORT="${KIOSK_PORTS[$idx]}"
                    KIOSK_ACTIVE_OS="${KIOSK_OS[$idx]}"
                    return 0
                fi
                say_warn "No screen numbered $key."
                sleep 1
                ;;
            *)
                say_warn "Press a number or 'a'."
                sleep 1
                ;;
        esac
    done
}

# --- WHICH BROWSER IS ACTUALLY THERE? ----------------------------------------
detect_browser_linux() {
    local b
    for b in "${KIOSK_BROWSER_PRIORITY[@]}"; do
        kiosk_run "command -v $b" >/dev/null 2>&1 && { printf '%s' "$b"; return 0; }
    done
    return 1
}

# Windows browser binaries aren't reliably on PATH, so we ask PowerShell to
# look them up by name, which also checks the usual install locations.
detect_browser_windows() {
    local b out
    for b in "${KIOSK_BROWSER_PRIORITY_WIN[@]}"; do
        out="$(kiosk_run "powershell -NoProfile -Command \"(Get-Command $b -ErrorAction SilentlyContinue).Source\"" 2>/dev/null | tr -d '\r')"
        [ -n "$out" ] && { printf '%s' "$b"; return 0; }
    done
    return 1
}

detect_browser() {
    if [ "$KIOSK_ACTIVE_OS" = "windows" ]; then detect_browser_windows
    else detect_browser_linux; fi
}

# --- OPENING THE BROWSER -------------------------------------------------------
kiosk_launch_linux() {
    local browser="$1" url="$2"
    KIOSK_BROWSER_PID=""

    if [ -z "$KIOSK_ACTIVE_HOST" ]; then
        setsid "$browser" --kiosk "$url" >>"$LOG_EVENTS" 2>&1 &
        KIOSK_BROWSER_PID=$!
        remember_pid "kiosk-browser" "$KIOSK_BROWSER_PID"
    else
        # A bare SSH login does not inherit the target's already-open desktop
        # session, so we work out its screen's "permission slip" first. See
        # KIOSK_REMOTE_XAUTH_CMD in the settings box - this is the single
        # most likely thing to need adjusting on a real remote kiosk.
        local xauth
        xauth="$(kiosk_run "$KIOSK_REMOTE_XAUTH_CMD" 2>/dev/null | tr -d '\r')"
        KIOSK_BROWSER_PID="$(kiosk_run "setsid env DISPLAY='$KIOSK_LOCAL_DISPLAY' XAUTHORITY='$xauth' $browser --kiosk '$url' >/dev/null 2>&1 & echo \$!" 2>/dev/null | tr -d '\r')"
    fi
}

# Bash -> SSH -> PowerShell is three layers of quoting fighting each other.
# Rather than fight them with an inline -Command string, we write a tiny
# script file on the target first and just tell it to run that - the same
# trick clone_step_nginx (Section 10) uses for its own config file.
kiosk_launch_windows() {
    local browser="$1" url="$2"
    KIOSK_BROWSER_PID=""
    local ps1='C:\Windows\Temp\lyn-kiosk.ps1'

    kiosk_run "printf 'Start-Process -FilePath \"%s\" -ArgumentList \"--kiosk\",\"%s\"\n' '$browser' '$url' > $ps1" >/dev/null 2>&1
    kiosk_run "powershell -NoProfile -ExecutionPolicy Bypass -File $ps1" >/dev/null 2>&1
    KIOSK_BROWSER_PID="$(kiosk_run "powershell -NoProfile -Command \"(Get-Process $browser -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Id)\"" 2>/dev/null | tr -d '\r')"
}

# Close whatever the kiosk is currently showing (if anything) and open it
# again at a new address. We relaunch rather than navigate in place - simpler
# and far more reliable than trying to remote-control a running browser, at
# the cost of a brief flash on screen each time the address changes.
kiosk_relaunch() {
    local url="$1"

    if [ -n "$KIOSK_BROWSER_PID" ]; then
        if [ -z "$KIOSK_ACTIVE_HOST" ]; then
            kill_family "$KIOSK_BROWSER_PID" "-TERM"
        else
            kiosk_run "kill $KIOSK_BROWSER_PID" >/dev/null 2>&1
        fi
    fi

    if [ -z "$KIOSK_BROWSER_BIN" ]; then
        say_err "No known browser found on $(kiosk_target_name) - nothing to open."
        return 1
    fi

    if [ "$KIOSK_ACTIVE_OS" = "windows" ]; then
        kiosk_launch_windows "$KIOSK_BROWSER_BIN" "$url"
    else
        kiosk_launch_linux "$KIOSK_BROWSER_BIN" "$url"
    fi
    printf '%s [switch] kiosk now showing %s\n' "$(date '+%H:%M:%S')" "$url" >> "$LOG_EVENTS"
}

# --- WORKING OUT THE LOCAL FALLBACK ADDRESS -----------------------------------
# If the kiosk is THIS computer, "local" means 127.0.0.1 - straight to nginx,
# skipping Cloudflare entirely. If the kiosk is a REMOTE screen, 127.0.0.1
# there would mean "myself" and never reach this server at all - so we work
# out this computer's address on the local network instead.
resolve_local_fallback_url() {
    [ -n "$LOCAL_FALLBACK_URL" ] && return 0

    if [ -z "$KIOSK_ACTIVE_HOST" ]; then
        LOCAL_FALLBACK_URL="$TUNNEL_TARGET_URL"
        return 0
    fi

    local lan_ip
    lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$lan_ip" ]; then
        LOCAL_FALLBACK_URL="http://$lan_ip:80"
    else
        LOCAL_FALLBACK_URL="$TUNNEL_TARGET_URL"
        say_warn "Could not work out this computer's network address -"
        say_warn "the fallback address may not be reachable from $(kiosk_target_name)."
    fi
}

# =============================================================================
#  SECTION 9C — THE WATCHMAN
# =============================================================================
# Once the site is on air, something needs to keep watching it - otherwise
# nobody finds out the public address broke until someone walks past the
# kiosk screen and sees an error page. The watchman checks every few seconds,
# switches the kiosk to a local address if the public one is failing, switches
# it back once the public one recovers, and writes down everything it sees.
#
# The watchman is its own small copy of this same script, running Section 9C
# alone instead of the menu - see the hidden door at the very bottom of this
# file. It is started with setsid, exactly like npm/gunicorn/cloudflared, so
# it survives on its own even after you close the menu with q.

# One quick check: is the public address answering normally right now?
check_public_url() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$HEALTH_CHECK_TIMEOUT" "$PUBLIC_URL" 2>/dev/null)"
    case "$code" in
        2??|3??) return 0 ;;
        *)       return 1 ;;
    esac
}

monitor_loop() {
    local fails=0 showing_fallback=0

    while true; do
        # --- Is the core stack still breathing? -----------------------------
        if [ -f "$PID_FILE" ]; then
            local pid label
            while read -r pid label; do
                case "$label" in
                    npm-*|gunicorn|cloudflared)
                        if ! is_alive "$pid"; then
                            printf '%s [warn] %s (pid %s) is no longer running\n' \
                                "$(date '+%H:%M:%S')" "$label" "$pid" >> "$LOG_EVENTS"
                        fi
                        ;;
                esac
            done < "$PID_FILE"
        fi

        # --- Is the kiosk browser still up? ----------------------------------
        local browser_alive=0
        if [ -n "$KIOSK_BROWSER_PID" ]; then
            if [ -z "$KIOSK_ACTIVE_HOST" ]; then
                is_alive "$KIOSK_BROWSER_PID" && browser_alive=1
            else
                kiosk_run "kill -0 $KIOSK_BROWSER_PID" >/dev/null 2>&1 && browser_alive=1
            fi
        fi
        if [ "$browser_alive" -eq 0 ]; then
            printf '%s [warn] the kiosk browser is not running - relaunching\n' \
                "$(date '+%H:%M:%S')" >> "$LOG_EVENTS"
            if [ "$showing_fallback" -eq 1 ]; then kiosk_relaunch "$LOCAL_FALLBACK_URL"
            else kiosk_relaunch "$PUBLIC_URL"; fi
        fi

        # --- Is the public site healthy? -------------------------------------
        if check_public_url; then
            fails=0
            if [ "$showing_fallback" -eq 1 ]; then
                printf '%s [ok] the public site is back - switching the kiosk back\n' \
                    "$(date '+%H:%M:%S')" >> "$LOG_EVENTS"
                kiosk_relaunch "$PUBLIC_URL"
                showing_fallback=0
            fi
        else
            fails=$((fails + 1))
            if [ "$fails" -ge "$HEALTH_FAIL_THRESHOLD" ] && [ "$showing_fallback" -eq 0 ]; then
                printf '%s [warn] the public site failed %s check(s) in a row - switching the kiosk to the local address\n' \
                    "$(date '+%H:%M:%S')" "$fails" >> "$LOG_EVENTS"
                kiosk_relaunch "$LOCAL_FALLBACK_URL"
                showing_fallback=1
            fi
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

start_monitor() {
    if [ -f "$MONITOR_PID_FILE" ] && is_alive "$(cat "$MONITOR_PID_FILE" 2>/dev/null)"; then
        return 0
    fi
    : > "$LOG_EVENTS"

    # The watchman is a brand new process - hand it the pieces of state it
    # needs (which screen, which browser, which fallback address) through
    # the environment, since it won't inherit our variables any other way.
    export KIOSK_ACTIVE_HOST KIOSK_ACTIVE_USER KIOSK_ACTIVE_PORT KIOSK_ACTIVE_OS \
           KIOSK_BROWSER_PID KIOSK_BROWSER_BIN LOCAL_FALLBACK_URL

    setsid bash "$0" --monitor-loop-internal >> "$LOG_EVENTS" 2>&1 &
    local pid=$!
    printf '%s' "$pid" > "$MONITOR_PID_FILE"
    say_ok "Watching the site  ${C_FAINT}pid $pid, every ${HEALTH_CHECK_INTERVAL}s${C_OFF}"
}

stop_monitor() {
    [ -f "$MONITOR_PID_FILE" ] || return 0
    local pid; pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null)"
    if is_alive "$pid"; then
        kill_family "$pid" "-TERM"
        sleep 1
        is_alive "$pid" && kill_family "$pid" "-KILL"
    fi
    rm -f "$MONITOR_PID_FILE"
}

# --- THE LIVE LOG VIEW ---------------------------------------------------------
show_live_log() {
    ui_header
    ui_rule
    ui_eyebrow "LIVE LOG"
    say_info "Everything as it happens - build, engine, tunnel, and the watchman."
    say_info "Press any key to go back."
    printf '\n'

    touch "$LOG_NPM" "$LOG_GUNICORN" "$LOG_TUNNEL" "$LOG_EVENTS" 2>/dev/null

    tail -f "$LOG_NPM" "$LOG_GUNICORN" "$LOG_TUNNEL" "$LOG_EVENTS" &
    local tpid=$!

    read -rn 1 -s
    kill "$tpid" 2>/dev/null
}

# =============================================================================
#  SECTION 10 — OPTION 3: COPY THE WHOLE SETUP TO THE OTHER COMPUTER
# =============================================================================
# What this does, in one sentence: it makes the other computer an exact working
# copy of this one, so that when somebody sits down at it and presses 1, the
# website comes up first time instead of after an afternoon of fixing things.
#
# There are NINE separate things that have to be in place. Copying only the code
# gets you a folder full of Python that cannot start, which is the trap this
# whole section exists to avoid.

# The list of things we can copy. Each line is: a short name, a label for the
# screen, and a sentence explaining what it is in plain English.
CLONE_KEYS=(tools lyn code assets env database media tunnel nginx)
CLONE_LABELS=(
"Programs"
"This control desk"
"The website's code"
"The built CSS and JavaScript"
"The settings and passwords"
"The database"
"The media folder"
"The internet tunnel keys"
"The nginx door policy"
)
CLONE_NOTES=(
"nginx, MySQL, Python, Node 18 and cloudflared"
"lyn.sh itself, so you can drive that computer too"
"the PressPoint project, minus the bits that must be rebuilt"
"built here with Node 18, so that computer never needs npm"
".env - streamed straight across, never saved to a file"
"every news article, member and archive record"
"$MEDIA_DIR - the PDFs, videos and branding"
"~/.cloudflared - without these the tunnel cannot open"
"/etc/nginx/sites-available/presspoint"
)
# 1 = copy it, 0 = skip it. Everything is on for a first clone.
CLONE_ON=(1 1 1 1 1 1 1 1 1)

# Look a short name up and tell us whether it is switched on.
clone_wants() {
    local want="$1" i
    for i in "${!CLONE_KEYS[@]}"; do
        if [ "${CLONE_KEYS[$i]}" = "$want" ]; then
            [ "${CLONE_ON[$i]}" = "1" ] && return 0 || return 1
        fi
    done
    return 1
}

# --- IS THE OTHER COMPUTER ALREADY THE LIVE ONE? -----------------------------
# This matters enormously for the database. On the day the other computer is
# serving the public, its database holds real articles that editors have
# written THERE. Copying this computer's database over the top would erase
# every one of them, and there is no undo.
#
# So we ask first, and if the answer is yes we switch the database off in the
# list by default. It can still be switched back on deliberately - it just
# cannot happen by accident.
TARGET_IS_LIVE=0

check_if_target_is_live() {
    TARGET_IS_LIVE=0
    local running
    running="$(on_target "pgrep -f 'cloudflared.*$TUNNEL_NAME' >/dev/null 2>&1 && echo yes" 2>/dev/null)"
    if [ "$running" = "yes" ]; then
        TARGET_IS_LIVE=1
        local i
        for i in "${!CLONE_KEYS[@]}"; do
            [ "${CLONE_KEYS[$i]}" = "database" ] && CLONE_ON[$i]=0
        done
    fi
}

# --- THE TICK LIST -----------------------------------------------------------
# Shows the nine things and lets you switch any of them off before starting.
clone_checklist() {
    local key i

    while true; do
        clear
        ui_header
        ui_rule
        ui_eyebrow "WHAT TO COPY"

        printf '   %s%s%s  %s%s%s  %s%s\n\n' \
            "$C_MUTED" "$(source_name)" "$C_OFF" \
            "$C_ACCENT" "$G_LINK$G_LINK$G_LINK" "$C_OFF" \
            "$C_BOLD$(target_name)" "$C_OFF"

        for i in "${!CLONE_KEYS[@]}"; do
            if [ "${CLONE_ON[$i]}" = "1" ]; then
                printf '   %s%s%s %s %s%-28s%s %s%s%s\n' \
                    "$C_LIVE" "$G_ON" "$C_OFF" "$((i + 1))" \
                    "$C_BOLD" "${CLONE_LABELS[$i]}" "$C_OFF" \
                    "$C_FAINT" "${CLONE_NOTES[$i]}" "$C_OFF"
            else
                printf '   %s%s%s %s %s%-28s%s %s%s%s\n' \
                    "$C_DOWN" "$G_OFF" "$C_OFF" "$((i + 1))" \
                    "$C_FAINT" "${CLONE_LABELS[$i]}" "$C_OFF" \
                    "$C_FAINT" "${CLONE_NOTES[$i]}" "$C_OFF"
            fi
        done

        if [ "$TARGET_IS_LIVE" = "1" ]; then
            printf '\n'
            say_warn "$(target_name) is ON AIR right now."
            say_info "The database is switched off above so a copy from here"
            say_info "cannot wipe articles written over there. Press 6 only if"
            say_info "you really mean to replace them."
        fi

        printf '\n'
        ui_rule
        printf '   %spress 1-9 to switch one on or off%s\n' "$C_FAINT" "$C_OFF"
        printf '   %sa%s all   %sn%s none   %sc%s start copying   %sb%s back\n' \
            "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF"
        printf '\n   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"

        read -rn 1 -s key || return 1
        case "$key" in
            [1-9])
                i=$((key - 1))
                if [ "$i" -lt "${#CLONE_KEYS[@]}" ]; then
                    [ "${CLONE_ON[$i]}" = "1" ] && CLONE_ON[$i]=0 || CLONE_ON[$i]=1
                fi
                ;;
            a|A) for i in "${!CLONE_ON[@]}"; do CLONE_ON[$i]=1; done ;;
            n|N) for i in "${!CLONE_ON[@]}"; do CLONE_ON[$i]=0; done ;;
            c|C)
                for i in "${!CLONE_ON[@]}"; do
                    [ "${CLONE_ON[$i]}" = "1" ] && return 0
                done
                say_warn "Nothing is switched on - there is nothing to copy."
                sleep 1.5
                ;;
            b|B) return 1 ;;
        esac
    done
}

# --- THE NINE COPYING STEPS --------------------------------------------------
# Each one checks before it acts, so running the clone twice is safe and quick.

# 1. PROGRAMS ------------------------------------------------------------------
# The other computer needs the same tools installed before any of our files are
# any use. Python 3.11 is the fussy one: Ubuntu 24.04 ships Python 3.12 only,
# and this project's toolbox is built for 3.11, so we have to add the "deadsnakes"
# source first or the toolbox silently comes out the wrong version.
clone_step_tools() {
    clone_wants tools || return 0
    ui_eyebrow "PROGRAMS"

    say_info "Installing on $(target_name) - this can take a few minutes."

    if ! on_target "sudo -n true 2>/dev/null"; then
        say_warn "Installing programs needs an administrator password over there."
        say_info "Either run this once on that computer:"
        say_info "    sudo apt install -y nginx mysql-server python3.11 python3.11-venv rsync"
        say_info "or give that account password-free sudo, then switch step 1 off."
        return 0
    fi

    on_target "
        set -e
        if [ ! -x /usr/bin/python3.11 ]; then
            sudo -n apt-get update -qq
            sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
            sudo -n add-apt-repository -y ppa:deadsnakes/ppa
            sudo -n apt-get update -qq
        fi
        sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            nginx mysql-server rsync curl python3.11 python3.11-venv python3.11-dev
    " && say_ok "nginx, MySQL and Python 3.11 are installed" \
      || { say_err "Could not install the programs - see the message above."; return 1; }

    # cloudflared is not in Ubuntu's own list of programs, so it comes straight
    # from Cloudflare.
    on_target "command -v cloudflared >/dev/null 2>&1" \
      && say_ok "cloudflared already installed" \
      || { on_target "
            set -e
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
              | sudo -n tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
            echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
              | sudo -n tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
            sudo -n apt-get update -qq
            sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloudflared
          " && say_ok "cloudflared installed" || say_warn "Could not install cloudflared."; }

    # Nextcloud is not part of the website - PressPoint never talks to it - but
    # it is expected to be on the newsroom machine, so we put it there and leave
    # it at its own setup screen for somebody to finish by hand.
    on_target "snap list nextcloud >/dev/null 2>&1" \
      && say_ok "Nextcloud already installed" \
      || { on_target "sudo -n snap install nextcloud" >/dev/null 2>&1 \
           && say_ok "Nextcloud installed (left at its setup screen)" \
           || say_info "Skipped Nextcloud - nothing on the website depends on it."; }
}

# 2. THIS CONTROL DESK ---------------------------------------------------------
# lyn.sh lives outside the website's folder, in its own place. If we did not
# copy it, the other computer would have all the files and no way to press 1.
clone_step_lyn() {
    clone_wants lyn || return 0
    ui_eyebrow "THIS CONTROL DESK"

    on_target "mkdir -p '$DST_LYN'" || { say_err "Could not create $DST_LYN"; return 1; }

    # WHEN RECEIVING, THE TARGET IS THE SCRIPT YOU ARE RUNNING RIGHT NOW.
    #
    # Bash does not read a script all at once - it reads a bit, runs it, comes
    # back for more. Overwriting the file underneath itself means bash returns
    # for the next line and finds something completely different sitting at that
    # position, then runs whatever fragment it lands on. It is a genuinely nasty
    # way to break, so we never do it: the new copy is written alongside, and
    # you swap it in yourself after quitting.
    local dest="$DST_LYN/lyn.sh" swap_needed=0
    if [ "$CLONE_DIRECTION" = "receive" ]; then
        dest="$DST_LYN/lyn.sh.new"
        swap_needed=1
    fi

    copy_over "$SRC_LYN/lyn.sh" "$dest" >/dev/null \
        && on_target "chmod +x '$dest'" \
        || { say_err "Could not copy lyn.sh"; return 1; }

    # Over there, "watch" would be a file-watcher nobody is feeding, rebuilding
    # files no one is editing for as long as the computer is switched on. Swap
    # it for a single build. This edits only the copy that just arrived.
    on_target "sed -i 's|^NPM_SCRIPT=.*|NPM_SCRIPT=\"$PEER_NPM_SCRIPT\"|' '$dest'" \
        && say_ok "set to build assets once, not watch forever"

    if [ "$swap_needed" = "1" ]; then
        if on_target "cmp -s '$DST_LYN/lyn.sh' '$dest'"; then
            on_target "rm -f '$dest'"
            say_ok "this control desk is already up to date"
        else
            say_warn "A newer lyn.sh arrived, but this script is running from"
            say_warn "the old one and cannot safely replace itself."
            say_info "After you quit (press q), run:"
            say_info "    mv $DST_LYN/lyn.sh.new $DST_LYN/lyn.sh"
        fi
    else
        say_ok "lyn.sh copied to $DST_LYN"
    fi
}

# 3. THE WEBSITE'S CODE --------------------------------------------------------
clone_step_code() {
    clone_wants code || return 0
    ui_eyebrow "THE WEBSITE'S CODE"

    on_target "mkdir -p '$DST_PROJECT'" || { say_err "Could not create $DST_PROJECT"; return 1; }

    # We leave out three things on purpose:
    #   venv         - a Python toolbox has the folder it lives in written
    #                  inside it, so a copied one is broken. Rebuilt below.
    #   node_modules - thousands of tiny files, and it is rebuilt anyway.
    #   .env         - carried separately, in step 5, so it never sits in a
    #                  half-finished copy with the wrong permissions.
    copy_over "$SRC_PROJECT/" "$DST_PROJECT/" \
        --exclude '.git/' --exclude 'venv/' --exclude 'node_modules/' \
        --exclude '__pycache__/' --exclude '.pytest_cache/' \
        --exclude 'storage/framework/cache/' --exclude '*.sock' \
        --exclude '.env' \
        && say_ok "code copied to $DST_PROJECT" \
        || { say_err "Could not copy the code"; return 1; }

    # Rebuild the Python toolbox over there, using 3.11 by name. Typing
    # "python3" instead would quietly build a 3.12 toolbox on Ubuntu 24.04, and
    # the website would fail later in a way that looks like a bug in the code.
    say_info "Rebuilding the Python toolbox (this takes a minute)..."
    if on_target "
        set -e
        cd '$DST_PROJECT'
        /usr/bin/python3.11 -m venv venv
        ./venv/bin/pip install --quiet --upgrade pip
        ./venv/bin/pip install --quiet -r requirements.txt
    "; then
        local ver; ver="$(on_target "'$DST_PROJECT/venv/bin/python' -V 2>&1")"
        say_ok "Python toolbox rebuilt ($ver)"
    else
        say_err "Could not build the Python toolbox over there."
        say_info "Check that Python 3.11 is installed (step 1 does this)."
        return 1
    fi
}

# 4. THE BUILT CSS AND JAVASCRIPT ----------------------------------------------
# Built HERE with Node 18 and copied across finished, so the other computer
# never needs npm, nvm or node at all. One less thing to install and one less
# thing to go wrong.
clone_step_assets() {
    clone_wants assets || return 0
    ui_eyebrow "THE BUILT CSS AND JAVASCRIPT"

    if ! on_source "test -d '$SRC_PROJECT/storage/compiled'"; then
        say_warn "No built assets found on $(source_name)."
        say_info "Build them first:  cd $SRC_PROJECT && npm run prod"
        return 1
    fi

    # If anything in resources/ is newer than the build, the build is out of
    # date and the website would come up wearing last week's stylesheet.
    local stale
    stale="$(on_source "cd '$SRC_PROJECT' && find resources -type f -newer mix-manifest.json -print -quit 2>/dev/null")"
    if [ -n "$stale" ]; then
        say_warn "The built assets are older than the code that makes them."
        say_info "Newer file: $stale"
        say_info "Fix:  cd $SRC_PROJECT && npm run prod"
    fi

    on_target "mkdir -p '$DST_PROJECT/storage/compiled'"
    copy_over "$SRC_PROJECT/storage/compiled/" "$DST_PROJECT/storage/compiled/" >/dev/null \
        && copy_over "$SRC_PROJECT/mix-manifest.json" "$DST_PROJECT/mix-manifest.json" >/dev/null \
        && say_ok "built assets copied" \
        || say_err "Could not copy the built assets"
}

# 5. THE SETTINGS AND PASSWORDS ------------------------------------------------
# The .env file holds the database password, the mail keys, everything. We pipe
# it straight from one computer into the other through the SSH connection, so it
# is never written into a temporary file that somebody could later find.
clone_step_env() {
    clone_wants env || return 0
    ui_eyebrow "THE SETTINGS AND PASSWORDS"

    # "umask 077" means the file is created readable by its owner ONLY.
    if on_source "cat '$SRC_PROJECT/.env'" \
        | sed -e 's|^APP_DEBUG=.*|APP_DEBUG=False|' \
              -e 's|^APP_ENV=.*|APP_ENV=production|' \
        | on_target "umask 077; cat > '$DST_PROJECT/.env'"
    then
        say_ok ".env copied (never touched the disk on the way)"
        say_info "APP_DEBUG forced to False - a public site must never show"
        say_info "its error pages to visitors."
    else
        say_err "Could not copy .env"
        return 1
    fi
}

# 6. THE DATABASE --------------------------------------------------------------
# Every article, member and archive record. Sent as a "dump", which is a single
# long list of instructions for rebuilding the database exactly as it is here.
clone_step_database() {
    clone_wants database || return 0
    ui_eyebrow "THE DATABASE"

    local db user pass
    db="$(  on_source "grep -E '^DB_DATABASE=' '$SRC_PROJECT/.env' | cut -d= -f2-")"
    user="$(on_source "grep -E '^DB_USERNAME=' '$SRC_PROJECT/.env' | cut -d= -f2-")"
    pass="$(on_source "grep -E '^DB_PASSWORD=' '$SRC_PROJECT/.env' | cut -d= -f2-")"

    if [ -z "$db" ]; then
        say_err "No DB_DATABASE setting found - skipping the database."
        return 1
    fi

    # Make the empty database and its user over there first.
    if ! on_target "sudo -n mysql -e \"
        CREATE DATABASE IF NOT EXISTS \\\`$db\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '$user'@'127.0.0.1' IDENTIFIED BY '$pass';
        CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED BY '$pass';
        GRANT ALL PRIVILEGES ON \\\`$db\\\`.* TO '$user'@'127.0.0.1';
        GRANT ALL PRIVILEGES ON \\\`$db\\\`.* TO '$user'@'localhost';
        FLUSH PRIVILEGES;\" 2>/dev/null"
    then
        say_warn "Could not create the database over there (needs sudo)."
        say_info "Run this once on that computer, then try again:"
        say_info "    sudo mysql -e \"CREATE DATABASE $db; CREATE USER '$user'@'localhost' IDENTIFIED BY '...'; GRANT ALL ON $db.* TO '$user'@'localhost';\""
        return 1
    fi
    say_ok "database '$db' and its user are ready"

    # Always keep a copy of whatever was there before, even if we think it was
    # empty. It costs nothing and it is the only thing standing between a
    # mistake and a lost archive.
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    on_target "mysqldump --single-transaction --no-tablespaces -u'$user' -p'$pass' '$db' 2>/dev/null | gzip > '/tmp/presspoint-before-$stamp.sql.gz'" \
        && say_info "kept a safety copy at /tmp/presspoint-before-$stamp.sql.gz"

    # "--single-transaction" takes a consistent picture without locking anybody
    # out of the database while it reads.
    say_info "Copying the database across..."
    if on_source "mysqldump --single-transaction --no-tablespaces --routines -u'$user' -p'$pass' '$db'" \
        | on_target "mysql -u'$user' -p'$pass' '$db'"
    then
        local tables
        tables="$(on_target "mysql -u'$user' -p'$pass' -N -B -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';\" 2>/dev/null")"
        say_ok "database copied (${tables:-?} tables)"
    else
        say_err "The database copy failed."
        return 1
    fi
}

# 7. THE MEDIA FOLDER ----------------------------------------------------------
clone_step_media() {
    clone_wants media || return 0
    ui_eyebrow "THE MEDIA FOLDER"

    # 2775 sets the "sticky group" bit, which makes every file created inside
    # inherit the www-data group. That is what keeps nginx able to read things
    # editors upload through the dashboard later on.
    on_target "
        sudo -n mkdir -p '$MEDIA_DIR' 2>/dev/null || mkdir -p '$MEDIA_DIR'
        sudo -n chown www-data:www-data '$MEDIA_DIR' 2>/dev/null
        sudo -n chmod 2775 '$MEDIA_DIR' 2>/dev/null
        for d in Archives Videos About Branding; do
            sudo -n mkdir -p \"$MEDIA_DIR/\$d\" 2>/dev/null || mkdir -p \"$MEDIA_DIR/\$d\"
        done
        sudo -n setfacl -R -m u:$PEER_USER:rwx '$MEDIA_DIR' 2>/dev/null
    " >/dev/null 2>&1
    say_ok "media folder ready at $MEDIA_DIR"

    # The media folder sits at the same absolute path on both computers, so the
    # from and to are the same text - it is the direction that decides which end
    # each one refers to.
    if copy_over "$MEDIA_DIR/" "$MEDIA_DIR/" --no-perms --no-owner --no-group >/dev/null
    then
        local size; size="$(on_target "du -sh '$MEDIA_DIR' 2>/dev/null | cut -f1")"
        say_ok "media copied (${size:-unknown size})"
    else
        say_warn "Could not copy the media folder - is $MEDIA_DIR readable?"
    fi

    # The website also keeps some uploads inside its own folder.
    copy_over "$SRC_PROJECT/storage/framework/public/" "$DST_PROJECT/storage/framework/public/" >/dev/null 2>&1 \
        && say_ok "the website's own uploads folder copied"
}

# 8. THE INTERNET TUNNEL KEYS --------------------------------------------------
# THIS is the step people forget, and without it the other computer can do
# everything except the one thing it exists for.
#
# Read the big warning in the settings box at the top: the tunnel we care about
# is a NAMED tunnel, "presspoint-tunnel". Running it needs two files - a login
# certificate for the Cloudflare account, and a key file for this one tunnel.
# There is a completely separate tunnel on this computer (Presspoint-Server)
# started by Linux at boot, which the web address does NOT point at. Copying
# that one instead is the classic way to end up with a tunnel that connects
# beautifully and serves nobody.
clone_step_tunnel() {
    clone_wants tunnel || return 0
    ui_eyebrow "THE INTERNET TUNNEL KEYS"

    if ! on_source "test -f '$SRC_HOME/.cloudflared/cert.pem'"; then
        say_err "No cert.pem on $(source_name) - the tunnel cannot be copied."
        say_info "Fix on that computer:  cloudflared tunnel login"
        return 1
    fi

    on_target "mkdir -p '$DST_HOME/.cloudflared' && chmod 700 '$DST_HOME/.cloudflared'"

    copy_over "$SRC_HOME/.cloudflared/cert.pem" "$DST_HOME/.cloudflared/cert.pem" >/dev/null \
        && say_ok "Cloudflare login certificate copied" \
        || { say_err "Could not copy cert.pem"; return 1; }

    # Find the key file belonging to OUR tunnel, by asking cloudflared for its
    # ID rather than guessing from the file names.
    local uuid
    uuid="$(on_source "cloudflared tunnel list 2>/dev/null | awk -v n='$TUNNEL_NAME' '\$2==n {print \$1}'")"

    if [ -z "$uuid" ]; then
        say_warn "Could not look up the ID of tunnel '$TUNNEL_NAME'."
        say_info "Copying every tunnel key instead."
        copy_over "$SRC_HOME/.cloudflared/" "$DST_HOME/.cloudflared/" --include '*.json' --include 'cert.pem' >/dev/null \
            && say_ok "tunnel keys copied"
    else
        copy_over "$SRC_HOME/.cloudflared/$uuid.json" "$DST_HOME/.cloudflared/$uuid.json" >/dev/null \
            && say_ok "key for '$TUNNEL_NAME' copied  ${C_FAINT}($uuid)${C_OFF}" \
            || say_err "Could not copy the key for $TUNNEL_NAME"
    fi

    on_target "chmod 600 '$DST_HOME/.cloudflared/cert.pem' 2>/dev/null; chmod 400 '$DST_HOME'/.cloudflared/*.json 2>/dev/null"
    say_info "Keys locked so only that account can read them."
}

# 9. THE NGINX DOOR POLICY -----------------------------------------------------
# nginx is the doorman on port 80 that the tunnel hands visitors to. Its
# settings mention the project folder by name, so if the other computer keeps
# the project somewhere else we rewrite those paths as we go.
clone_step_nginx() {
    clone_wants nginx || return 0
    ui_eyebrow "THE NGINX DOOR POLICY"

    local conf
    conf="$(on_source "cat '$NGINX_SITE_SRC' 2>/dev/null || sudo -n cat '$NGINX_SITE_SRC' 2>/dev/null")"

    if [ -z "$conf" ]; then
        say_warn "No nginx settings found at $NGINX_SITE_SRC on $(source_name)."
        return 1
    fi

    # Swap this computer's project path for the other computer's.
    conf="${conf//$SRC_PROJECT/$DST_PROJECT}"

    if printf '%s\n' "$conf" | on_target "cat > /tmp/lyn-nginx-site" \
       && on_target "
            sudo -n cp /tmp/lyn-nginx-site '$NGINX_SITE_SRC' 2>/dev/null &&
            sudo -n ln -sfn '$NGINX_SITE_SRC' /etc/nginx/sites-enabled/presspoint &&
            sudo -n rm -f /etc/nginx/sites-enabled/default &&
            sudo -n nginx -t 2>/dev/null &&
            sudo -n systemctl reload nginx"
    then
        say_ok "nginx settings installed and reloaded"
        [ "$SRC_PROJECT" != "$DST_PROJECT" ] && say_info "paths rewritten: $SRC_PROJECT -> $DST_PROJECT"
    else
        say_warn "Could not install the nginx settings (it needs sudo over there)."
        say_info "The file is waiting at /tmp/lyn-nginx-site on that computer."
        say_info "Finish it by hand:"
        say_info "    sudo cp /tmp/lyn-nginx-site $NGINX_SITE_SRC"
        say_info "    sudo ln -sfn $NGINX_SITE_SRC /etc/nginx/sites-enabled/presspoint"
        say_info "    sudo nginx -t && sudo systemctl reload nginx"
    fi
    on_target "rm -f /tmp/lyn-nginx-site" 2>/dev/null
}

# --- THE FINAL CHECK ----------------------------------------------------------
# Copying files is not the same as the website working. This looks at the other
# computer the way the website will, and reports anything still missing - so you
# find out now, at the keyboard, rather than tomorrow from a blank page.
clone_verify() {
    ui_eyebrow "CHECKING THE OTHER COMPUTER"

    local problems=0
    check_there() {
        local label="$1" test_cmd="$2"
        if on_target "$test_cmd" >/dev/null 2>&1; then
            say_ok "$label"
        else
            say_err "$label"
            problems=$((problems + 1))
        fi
    }

    check_there "the project folder is there"      "test -d '$DST_PROJECT'"
    check_there "the Python toolbox works"         "'$DST_PROJECT/venv/bin/python' -c 'import masonite'"
    check_there "the toolbox is Python 3.11"       "'$DST_PROJECT/venv/bin/python' -V 2>&1 | grep -q 'Python 3.11'"
    check_there "gunicorn is installed"            "test -x '$DST_PROJECT/venv/bin/gunicorn'"
    check_there "the settings file is there"       "test -f '$DST_PROJECT/.env'"
    check_there "error pages are switched off"     "grep -q '^APP_DEBUG=False' '$DST_PROJECT/.env'"
    check_there "the built CSS is there"           "test -d '$DST_PROJECT/storage/compiled/css'"
    check_there "the control desk is there"        "test -x '$DST_LYN/lyn.sh'"
    check_there "the Cloudflare certificate"       "test -f '$DST_HOME/.cloudflared/cert.pem'"
    check_there "cloudflared is installed"         "command -v cloudflared"
    check_there "nginx is running"                 "systemctl is-active nginx"
    check_there "the media folder is there"        "test -d '$MEDIA_DIR'"

    # Can the website actually reach its database over there? This is the check
    # that catches a wrong password, which nothing else would notice.
    check_there "the database answers" \
        "cd '$DST_PROJECT' && ./venv/bin/python -c \"
import pymysql
e={}
for line in open('.env'):
    line=line.strip()
    if line and not line.startswith('#') and '=' in line:
        k,v=line.split('=',1); e[k]=v
pymysql.connect(host=e['DB_HOST'],user=e['DB_USERNAME'],password=e['DB_PASSWORD'],database=e['DB_DATABASE'],port=int(e['DB_PORT'])).close()\""

    printf '\n'
    if [ "$problems" -eq 0 ]; then
        say_ok "Everything the website needs is in place."
    else
        say_warn "$problems thing(s) above still need attention."
        say_info "Fix those, then run option 3 again - it only copies what changed."
    fi
    return 0
}

# --- OPTION 3 ITSELF ----------------------------------------------------------
clone_to_peer() {
    local direction="$1"
    CLONE_DIRECTION="$direction"

    ask_peer_address || return 1

    ui_eyebrow "CONNECTING"
    say_info "Looking for $(peer_target) ..."

    if ! peer_reachable; then
        say_err "Cannot reach $(peer_target) on port $PEER_PORT."
        printf '\n'
        say_info "Things to check, in order:"
        say_info "  1. Is the other computer switched on and on the same network?"
        say_info "  2. Does it have SSH?      sudo apt install openssh-server"
        say_info "  3. Can you log in without a password?"
        say_info "         ssh-copy-id -p $PEER_PORT $(peer_target)"
        say_info "     (this script never asks for passwords, on purpose)"
        return 1
    fi
    say_ok "Connected to $(peer_target)"

    resolve_paths
    check_if_target_is_live

    # Make sure the other end really is the computer we think it is, and that
    # the setup we are about to copy FROM actually exists.
    if ! on_source "test -f '$SRC_PROJECT/.env'"; then
        say_err "No website found at $SRC_PROJECT on $(source_name)."
        say_info "Nothing to copy from. Check the folder setting at the top of this script."
        return 1
    fi

    clone_checklist || return 1

    # --- The last word before anything is changed ---------------------------
    clear
    ui_header
    ui_rule
    ui_eyebrow "ABOUT TO COPY"

    printf '   %sfrom%s  %s   %s%s%s\n' "$C_MUTED" "$C_OFF" "$(source_name)" "$C_FAINT" "$SRC_PROJECT" "$C_OFF"
    printf '   %sto%s    %s   %s%s%s\n' "$C_MUTED" "$C_OFF" "$(target_name)" "$C_FAINT" "$DST_PROJECT" "$C_OFF"
    printf '\n'

    local i
    for i in "${!CLONE_KEYS[@]}"; do
        [ "${CLONE_ON[$i]}" = "1" ] && printf '   %s%s%s %s\n' "$C_LIVE" "$G_OK" "$C_OFF" "${CLONE_LABELS[$i]}"
    done

    printf '\n'
    if [ "$TARGET_IS_LIVE" = "1" ] && clone_wants database; then
        ui_rule
        say_warn "$(target_name) is ON AIR and its database WILL BE REPLACED."
        say_warn "Articles written over there will be gone. There is no undo."
        printf '\n   %stype the word  replace  to go ahead:%s ' "$C_BOLD" "$C_OFF"
        local typed; read -r typed
        if [ "$typed" != "replace" ]; then
            say_info "Nothing was changed."
            return 1
        fi
    else
        printf '   %spress y to start, any other key to go back%s ' "$C_FAINT" "$C_OFF"
        local key; read -rn 1 -s key; printf '\n'
        case "$key" in
            y|Y) ;;
            *) say_info "Nothing was changed."; return 1 ;;
        esac
    fi

    # --- Do it ---------------------------------------------------------------
    clear
    ui_header
    ui_rule

    clone_step_tools
    clone_step_lyn
    clone_step_code
    clone_step_assets
    clone_step_env
    clone_step_database
    clone_step_media
    clone_step_tunnel
    clone_step_nginx

    printf '\n'
    ui_rule
    clone_verify

    # --- What to do next -----------------------------------------------------
    printf '\n'
    ui_rule
    ui_eyebrow "WHAT HAPPENS NOW"

    if [ "$CLONE_DIRECTION" = "send" ]; then
        say_info "Go to $(target_name), open a terminal, and run:"
        printf '\n      %scd %s && ./lyn.sh%s\n\n' "$C_BOLD" "$DST_LYN" "$C_OFF"
        say_info "then press 1. The website comes up there."
    else
        say_info "This computer is ready. Press 1 on the menu to bring the"
        say_info "website up here."
    fi

    printf '\n'
    say_warn "Only ONE computer may run the tunnel at a time."
    say_info "Cloudflare treats a second one as another way in to the same"
    say_info "address, and sends visitors to whichever answers first - so half"
    say_info "of them would land on the wrong machine. Press 2 on the computer"
    say_info "that is finishing before you press 1 on the one taking over."
    printf '\n'
}

# The little menu that asks which way round we are copying.
clone_menu() {
    local key

    while true; do
        clear
        ui_header
        ui_rule
        ui_eyebrow "COPY TO THE OTHER COMPUTER"

        printf '   %sThis makes a second computer an exact working copy of the%s\n' "$C_FAINT" "$C_OFF"
        printf '   %sfirst, so the website runs there on the first try.%s\n' "$C_FAINT" "$C_OFF"
        printf '\n'
        ui_rule
        ui_eyebrow "WHICH WAY?"

        ui_key "1" "send"    "this computer's setup goes to the other one"
        ui_key "2" "receive" "this computer is set up from the other one"
        ui_key "b" "back"    "return to the main menu"

        if [ -n "$PEER_HOST" ]; then
            printf '\n   %sother computer: %s%s\n' "$C_FAINT" "$(peer_target)" "$C_OFF"
        fi

        printf '\n   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
        read -rn 1 -s key || return 0
        printf '\n'

        case "$key" in
            1) clear; clone_to_peer "send"
               printf '   %spress any key to go back%s ' "$C_FAINT" "$C_OFF"
               read -rn 1 -s; return 0 ;;
            2) clear; clone_to_peer "receive"
               printf '   %spress any key to go back%s ' "$C_FAINT" "$C_OFF"
               read -rn 1 -s; return 0 ;;
            b|B) return 0 ;;
        esac
    done
}

# =============================================================================
#  SECTION 11 — THE MAIN LOOP (this is where the script actually begins)
# =============================================================================
main() {
    # "clear" wipes the screen so we start on a clean page.
    clear

    # Check the toolbox once, at the very start.
    check_tools
    printf '   %spress any key to open the control desk%s ' "$C_FAINT" "$C_OFF"
    read -rn 1 -s
    clear

    # This loop runs forever until the user presses Q.
    while true; do
        show_menu

        # THE MAGIC LINE. Read exactly ONE key press:
        #   -r  don't do anything clever with backslashes
        #   -n1 stop after a single character - no Enter needed
        #   -s  don't echo the key to the screen (keeps the display tidy)
        # If "read" fails, it means there is no keyboard to read from any more
        # (for example the script is being fed from a file that ran out). We
        # leave quietly instead of spinning around this loop forever.
        if ! read -rn 1 -s key; then
            printf '\n%s   No keyboard input left - closing the menu.%s\n\n' "$C_ACCENT" "$C_OFF"
            exit 0
        fi
        printf '%s\n' "$key"

        case "$key" in
            1)
                clear
                start_stack
                printf '   %spress any key to go back%s ' "$C_FAINT" "$C_OFF"
                read -rn 1 -s
                clear
                ;;
            2)
                clear
                stop_stack
                printf '   %spress any key to go back%s ' "$C_FAINT" "$C_OFF"
                read -rn 1 -s
                clear
                ;;
            3)
                # The clone has its own little menu, which asks which way round
                # we are copying before anything happens.
                clone_menu
                clear
                ;;
            4)
                clear
                show_live_log
                clear
                ;;
            q|Q)
                # Note we do NOT stop anything here. Quitting the menu just
                # closes the menu; the website keeps running happily without it.
                printf '\n   %sclosed the desk. anything running stays running.%s\n\n' "$C_FAINT" "$C_OFF"
                exit 0
                ;;
            *)
                printf '\n'
                say_warn "That key does nothing. Please press 1, 2, 3, 4, or Q."
                sleep 1.5
                clear
                ;;
        esac
    done
}

# =============================================================================
#  A HIDDEN DOOR: THE WATCHMAN RE-ENTERS ITSELF
# =============================================================================
# The watchman (Section 9C) needs to be its own independent, detachable
# program, for exactly the same reason npm/gunicorn/cloudflared are started
# with setsid: it has to keep running after you close the menu. Since the
# watchman IS this script - just running one function forever instead of the
# menu - we simply run this same file again with a secret flag that skips
# straight to monitor_loop. start_monitor (Section 9C) is what does this.
if [ "${1:-}" = "--monitor-loop-internal" ]; then
    monitor_loop
    exit 0
fi

# Off we go.
main "$@"
