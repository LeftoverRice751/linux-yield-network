```
█    ████ █  █ █  █ █  █    █  █ ████ ████ █    ███
█     ██  ██ █ █  █  ██     █  █  ██  █    █    █  █
█     ██  █ ██ █  █  ██      ██   ██  ███  █    █  █
█     ██  █  █ █  █  ██      ██   ██  █    █    █  █
████ ████ █  █ ████ █  █     ██  ████ ████ ████ ███

█  █ ████ ████ █  █ ████ ███  █  █
██ █ █     ██  █  █ █  █ █  █ █ █
█ ██ ███   ██  █ ██ █  █ ███  ██
█  █ █     ██  ████ █  █ █ █  █ █
█  █ ████  ██  █  █ ████ █  █ █  █
```

# linux-yield-network

**A broadcast desk for the PressPoint website.** Four programs, three keys, one screen.

PressPoint isn't one program. It's four that all have to be running at once, in the
right order, or the site is dark:

```
npm  →  gunicorn  →  nginx  →  cloudflared
build     engine     doorman    the internet
```

Remembering that at 2am is nobody's idea of a good time. So: press `1`.

```
./lyn.sh
```

---

## The desk

```
   ●━━━━━━━━━━━●━━━━━━━━━━━○
   build       engine      on air
   pid 117668  pid 117669  stopped

   ○ offline  the public cannot reach the site

   ─────────────────────────────────────────

   ▌ CONTROLS

    1   start    bring the website online
    2   stop     take it offline and tidy up
    3   clone    copy this whole setup to another computer
    q   quit     leave this menu, keep the site running
```

A filled dot is running. A hollow dot is stopped. The line between two dots only
lights up when both ends are alive — so you don't just see *that* something is
off, you see **where the chain breaks**. Everything to the right of the break is
the part the public can't reach.

Quitting the desk doesn't stop the site. `q` closes the menu and walks away;
whatever was running stays running.

---

## `3` — cloning to a second computer

The split:

| | |
|---|---|
| **this computer** | where you *write* the website |
| **the other computer** | where the website *lives*, for the public |

Option 3 makes the second machine an exact working copy of the first, so when
somebody sits down at it and presses `1`, the site comes up **first try** —
instead of after an afternoon of chasing missing pieces.

It works in both directions:

- **send** — push this computer's setup to the other one
- **receive** — pull the other computer's setup onto this one

*Receive is usually easier: sit at the machine that will face the internet, pull
everything to it, and let it configure itself.*

### The nine things

Copy only the code and you get a folder full of Python that cannot start. All
nine of these have to land:

| # | what | why you'd miss it |
|---|------|-------------------|
| 1 | **Programs** | nginx, MySQL, Python 3.11, cloudflared, Nextcloud |
| 2 | **This control desk** | `lyn.sh` itself — otherwise there's no `1` to press |
| 3 | **The website's code** | the project, minus everything that must be rebuilt |
| 4 | **Built CSS & JavaScript** | compiled here with Node 18; that machine never needs npm |
| 5 | **Settings & passwords** | `.env`, streamed straight across, never saved to a file |
| 6 | **The database** | every article, member and archive record |
| 7 | **The media folder** | archive PDFs, videos, branding images |
| 8 | **Tunnel keys** | `~/.cloudflared` — without these the tunnel simply won't open |
| 9 | **The nginx door policy** | the site config, with paths rewritten to fit |

Tick any of them off before it starts. It only copies what actually changed, so
running it again is fast and safe.

When it's finished it **checks its own work** and tells you what's still missing —
so you find out now, at the keyboard, instead of tomorrow from a blank page.

---

## Guardrails

This thing touches a live website. It's built like it knows that.

**It never mirrors.** No `--delete`, ever. Once the other machine is the live
one it holds uploads this one has never seen — mirroring would quietly destroy
every archive PDF an editor added over there.

**It forces `APP_DEBUG=False`.** A dev `.env` copied verbatim is exactly how
stack traces end up visible to the public.

**It won't clobber a live database by accident.** If the far machine is already
on air, the database is switched **off** in the list by default. You can turn it
back on — you just have to type the word `replace` to prove you meant it. It
takes a safety dump first regardless.

**It rebuilds the Python toolbox instead of copying it.** A virtualenv has its
own location written inside it; a copied one is broken on arrival.

**It builds assets here, not there.** The server never needs npm, nvm or node.

**It sets the copy to build once, not watch forever.** Nobody is editing files on
the server — a watcher there would just burn CPU until the heat death of the
universe.

**It refuses to overwrite itself.** On a *receive*, the incoming `lyn.sh` lands
as `lyn.sh.new`. Bash reads a script as it runs it, so replacing the file
underneath a running process makes it execute whatever fragment lands at that
byte offset. Not today.

---

## One tunnel at a time ⚠

Cloudflare treats a second machine running the same tunnel as **another way in to
the same address**, and routes visitors to whichever answers first. Run both and
roughly half your traffic lands on the wrong computer — silently, looking like
"the site is being weird" rather than a misconfiguration.

> Press `2` on the machine that's finishing **before** you press `1` on the one
> taking over.

And mind which tunnel. There are three on this account and they are **not**
interchangeable:

| tunnel | reality |
|---|---|
| `Presspoint-Server` | runs at boot — but the web address does **not** point at it |
| `kadiwa` | something else entirely |
| `presspoint-tunnel` | ← the one `presspoint-gears.me` is actually wired to |

Start the wrong one and the browser shows **Error 1033**, because Cloudflare is
holding the door open for a tunnel that never turned up — *even though* another
tunnel is running perfectly. That's what makes it so maddening to debug.

Option 3 looks the right tunnel up **by name**, so it copies keys that actually
work.

---

## Getting set up

On the other computer:

```bash
sudo apt install -y openssh-server
```

On this one, so it can log in without a password:

```bash
ssh-copy-id <username>@<the-other-computer>
```

That's it — option 3 installs the rest. `lyn` never prompts for an SSH password,
on purpose: it would rather fail with an explanation than leave a hidden prompt
hanging in the middle of a copy.

> **Smoothest first run:** give that account password-free `sudo`. Without it,
> step 1 prints the commands to run by hand and carries on rather than stalling.

### Requirements

`bash` · `ssh` · `rsync` · `mysqldump` · Ubuntu 24.04 on both ends

---

## Tweaking

Everything you might reasonably want to change lives in **one settings box** at
the top of `lyn.sh`, and every setting is marked `TWEAK THIS` with a note on when
you'd want to. Project folder, worker count, tunnel name, the other computer's
address — all of it. You shouldn't need to read past Section 2.

---

## How it's built

One file. No dependencies, no framework, no install step. ~1,900 lines of bash
that are mostly *comments*, written for somebody who does not know Linux and
should not have to.

Send and receive move the same bytes between the same two machines — only the
initiating end differs — so the copy is written **once**, in terms of `on_source`
and `on_target`, and the direction decides which is which. Two copies of that
logic would drift apart the first time either was fixed.

```
Section 1   the settings box        ← the part you're allowed to change
Section 2   helpers
Section 3   preflight — do we have the tools?
Section 4   use the right Node
Section 5   option 1: start
Section 6   option 2: stop
Section 7   the live status board
Section 8   the menu
Section 9   talking to the other computer
Section 10  option 3: clone
Section 11  the main loop
```

---

<sub>**LYN** · linux-yield-network · PressPoint broadcast control</sub>
