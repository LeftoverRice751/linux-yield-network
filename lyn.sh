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
PROJECT_DIR="/home/$USER/Downloads/presspoint"

# --- THE PYTHON "TOOLBOX" ----------------------------------------------------
# A virtual environment ("venv") is a private toolbox of Python programs that
# belongs to this project only, so it can't get mixed up with other projects.
# We have to "activate" it before running anything Python.
# TWEAK THIS only if your toolbox folder is named something other than "venv".
VENV_ACTIVATE="$PROJECT_DIR/venv/bin/activate"

# We call gunicorn by its FULL path from inside the toolbox. This matters:
# if we just typed "gunicorn" we might accidentally grab a different one that
# is installed elsewhere on the computer, and it would fail in a confusing way.
GUNICORN_BIN="$PROJECT_DIR/venv/bin/gunicorn"

# --- THE FRONT DOOR (the socket) ---------------------------------------------
# A "socket" is a special file that works like a doorway. gunicorn sits behind
# the doorway, and nginx knocks on it to hand over visitors.
# TWEAK THIS only if you also change the matching line inside nginx's config at
# /etc/nginx/sites-enabled/presspoint. The two names MUST match exactly, or
# nginx will knock on a door that nobody is standing behind.
SOCKET_NAME="presspoint.sock"
SOCKET_PATH="$PROJECT_DIR/$SOCKET_NAME"

# --- HOW MANY WORKERS? -------------------------------------------------------
# A "worker" is one helper that can serve one visitor at a time. Three workers
# means three visitors can be served at once; a fourth waits a moment in line.
# TWEAK THIS: more workers = handles more people at once, but uses more memory.
# A common rule of thumb is (number of CPU cores x 2) + 1. Three is fine here.
GUNICORN_WORKERS=3

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
TUNNEL_NAME="presspoint-tunnel"

# Where the tunnel should send visitors once they arrive. Port 80 is nginx,
# which then passes them along to gunicorn through the socket door.
# TWEAK THIS if nginx is ever moved to a different port, e.g. http://127.0.0.1:8080
TUNNEL_TARGET_URL="http://127.0.0.1:80"

# How the tunnel talks to Cloudflare. "http2" is the reliable choice here;
# the default ("quic") uses UDP, which some Wi-Fi and hotspot connections block.
# TWEAK THIS to "quic" only if you know your network allows UDP port 7844.
TUNNEL_PROTOCOL="http2"

# The public web address, used only for the friendly message at the end.
# TWEAK THIS if the domain changes.
PUBLIC_URL="https://presspoint-gears.me"

# --- THE NOTEBOOK AND THE DIARIES --------------------------------------------
# When we start a program, Linux gives it an ID number (a "PID"). We write those
# numbers into this notebook file so that later, option 2 knows exactly which
# programs to switch off. Without it we'd be guessing.
PID_FILE="/tmp/presspoint.pids"

# Programs like to talk while they work. We send all that chatter into these
# log files ("diaries") instead of the screen, so the menu stays clean. If
# something breaks, these are the first place to look.
LOG_NPM="/tmp/presspoint_npm.log"
LOG_GUNICORN="/tmp/presspoint_gunicorn.log"
LOG_TUNNEL="/tmp/presspoint_cloudflared.log"

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

    # --- Step 8: the happy summary ------------------------------------------
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

    # --- Step 4: tidy up the leftovers --------------------------------------
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
ui_key() {
    printf '   %s %s %s  %s%-6s%s %s%s%s\n' \
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
    ui_key "q" "quit"   "leave this menu, keep the site running"
    printf '\n   %spress a key%s\n' "$C_FAINT" "$C_OFF"
    printf '   %s%s%s ' "$C_ACCENT" "$G_PROMPT" "$C_OFF"
}

# =============================================================================
#  SECTION 9 — FUTURE: SEND THE CODE TO THE OTHER COMPUTER  (not built yet)
# =============================================================================
#  The plan is for this script to also copy the website's code from this computer
#  to the second one over the home network, using SSH (a secure remote connection)
#  and git (the tool that tracks code changes).
#
#  When we build it, it will become menu option [3] and will look roughly like:
#
#      PEER_HOST="192.168.1.50"      # the other computer's address
#      PEER_USER="leftoverrice"      # the username on that computer
#      PEER_PORT="22"                # the SSH door number
#      PEER_BRANCH="main"            # which version of the code to send
#
#      push_to_peer() {
#          # 1. make sure we can reach the other computer at all
#          # 2. push the code to it over SSH
#          # 3. ask it to rebuild and restart itself
#      }
#
#  Deliberately left as comments for now: this version of the script does nothing
#  at all over the network, and runs no git commands whatsoever.
# =============================================================================

# =============================================================================
#  SECTION 10 — THE MAIN LOOP (this is where the script actually begins)
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
            q|Q)
                # Note we do NOT stop anything here. Quitting the menu just
                # closes the menu; the website keeps running happily without it.
                printf '\n   %sclosed the desk. anything running stays running.%s\n\n' "$C_FAINT" "$C_OFF"
                exit 0
                ;;
            *)
                printf '\n'
                say_warn "That key does nothing. Please press 1, 2, or Q."
                sleep 1.5
                clear
                ;;
        esac
    done
}

# Off we go.
main "$@"
