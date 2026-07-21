<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/fleet-dark-128.png">
    <img src="assets/fleet-light-128.png" alt="fleet" width="96" height="96">
  </picture>
</p>

# fleet

[![CI](https://github.com/anivk/fleet/actions/workflows/ci.yml/badge.svg)](https://github.com/anivk/fleet/actions/workflows/ci.yml)

Run a fleet of [Claude Code](https://claude.com/claude-code) agents in tmux — each in its own
workspace, attachable locally over SSH — and optionally drivable from claude.ai/code.

One tmux session, one pane per agent. Agents keep running when you detach; you can regroup them
into tiled dashboards, zoom one full-screen, restart a single agent in place, and resume prior
conversations on login — without ever disturbing the others.

```
┌─ grid-space ──────────────┐  ┌─ grid-agents ─────────────┐
│ my-nyc-space-1 │ space-2 │  │ my-nyc-agent-A │ agent-B │
│ ─────────────── │ ─────── │  │ ─────────────── │ ─────── │
│ my-nyc-space-3 │ space-4 │  │ my-nyc-agent-C │ agent-D │
└───────────────────────────┘  └───────────────────────────┘
```

## What it's for

Two tiers of agents:

- **Repo agents** (`space-1..N`) — each is a clone of the same repository, so agents work in
  parallel without colliding on git state.
- **General agents** (`agent-A..N`) — scratch workspaces launched with `--chrome` for a real
  browser, for tasks that aren't tied to one repo.

Each agent is a long-lived `claude` session named for its workspace. tmux is what lets you
attach, watch, and steer locally. **Remote Control is per-agent** — set `"remoteControl": true`
on an agent (or the general tier) in `fleet.json` to launch it with `--remote-control`, making
it drivable from claude.ai/code and the mobile app; by default agents run local-only.

## Install

fleet ships as a **single binary** (macOS + Linux, arm64 + amd64) — download it and run:

```sh
curl -fsSL https://raw.githubusercontent.com/anivk/fleet/main/get.sh | sh   # -> /usr/local/bin/fleet

fleet bootstrap     # provision this box: Tailscale + deps (git/jq/tmux) + claude   (servers)
fleet install       # wire config, tmux, Claude hooks, login-autostart
```

- **`get.sh`** grabs the right binary for your OS/arch from the latest GitHub release
  (override the dir with `FLEET_INSTALL_DIR`, the version with `FLEET_VERSION`).
- **`fleet bootstrap`** is the box-provisioner — it installs everything an agent host
  needs. On a laptop that only *watches* remotes (client mode) you can skip it.
- **`fleet install`** wires the rest. Then `claude login` (once, interactive) and you're set.

The binary embeds the whole runtime (launcher, tray, provisioner) and unpacks it to a
cache dir on first run — there's nothing else to clone.

**From source** (dev): `git clone` then `go build -o fleet .` (needs Go). Everything below
works the same whether you run the binary or `bin/fleet.sh` directly.

**No repos are configured out of the box** — the installer only wires up the
`fleet` command and leaves an empty roster at `~/.config/fleet/config`. Add repo
agents with `fleet setup`, which clones a GitHub repo N times into
`~/co/<repo>-1..N` and records it in the config:

```sh
fleet setup your-org/your-repo 4     # 4 clones of github.com/your-org/your-repo
```

The repo basename becomes the workspace prefix (`your-repo` → `your-repo-1..4`),
and the roster is saved to `~/.config/fleet/config`, so `fleet start` knows what to
launch. Re-run any time to change the repo or count (existing clones are left in
place).
SSH by default; for HTTPS: `FLEET_GIT_BASE=https://github.com/ fleet setup <owner>/<repo> N`.

Then create the general (scratch) workspaces:

```sh
for a in A B C D; do mkdir -p ~/co/agent-$a && git -C ~/co/agent-$a init; done
```

## Commands

| Command | What it does |
|---|---|
| `fleet setup <owner>/<repo> [count]` | Clone the repo `count` times (default 4) into `~/co/<repo>-N` and save the roster. Idempotent |
| `fleet start` | Launch every agent that isn't already running (idempotent). **Resumes** each agent's last conversation by default (`claude --continue`); `--fresh` for a cold start |
| `fleet up` | Same, but **resume** each agent's last conversation (used by login autostart) |
| `fleet status` / `fleet ls` | Overview: this machine's agents (alive / dead) **and** the remote machines. A bare `fleet` runs this — never launches by surprise |
| `fleet attach [name]` | Attach to the session; with a name, jump straight to that agent's pane |
| `fleet send <agent> <text>` | Type text into a running agent (then Enter) — drive it without attaching |
| `fleet broadcast <text>` | Send the same text to **every** running agent |
| `fleet log <agent> [lines]` | Print an agent's recent pane output (default 40 lines) |
| `fleet run [--repo <o/r>] <task>` | Ephemeral one-shot agent — run the task headless (`claude -p`) in a throwaway workspace, then tear down |
| `fleet doctor` | Health check: tools, `fleet.json`, hooks, tray, **auth** (`claude`/`codex` logged in?), and host reachability |
| `fleet grid` | Regroup the **live** panes into tiled dashboard windows (see below) |
| `fleet spread` | Reverse `grid` — one window per agent again |
| `fleet restart <name>` | Restart **one** agent in place (siblings untouched; revives dead panes). **Resumes** its last conversation (`claude --continue`); `--restart-fresh` for a clean start |
| `fleet respawn [host]` | Revive any **dead** agents and start any that aren't running (resuming conversations). Local, or on a remote host over Tailscale — a manual watchdog |
| `fleet hosts` | List remote machines; `fleet hosts add <short> [host]` / `fleet hosts rm <short>` edit `fleet.json` |
| `fleet config` | `path` / `edit` / `validate` the `fleet.json` config; `push [host] [--restart]` syncs it to your other machines |
| `fleet remote ls` | List the configured hosts and their reachability (a bare `fleet remote` does this too) |
| `fleet remote <host>` | Attach **another machine's** fleet over Tailscale SSH (see below) |
| `fleet remote-ssh <host> [cmd]` | A plain shell (or one command) on a remote — works even when its fleet isn't running (login, provisioning, debugging) |
| `fleet remote-install [--global] <host>` | Bootstrap fleet on a new machine over Tailscale SSH — install into `~/.fleet` (or `/opt/fleet` with `--global`, sudo) and run its installer |
| `fleet keys {forward\|setup\|check} [host]` | Let remote git use your keys — agent forwarding (A) + a durable per-host key (B); see [Remote git access](#remote-git-access-fleet-keys) |
| `fleet update [host]` | Pull the latest fleet (fast-forward only), re-run the installer, and **upgrade the agent CLIs** (`claude`/`codex`); `--no-clis` skips the CLI upgrade. With a host, updates **that machine** over Tailscale SSH |
| `fleet stop` | Kill the whole session (the only command that stops agents) |

`grid`, `spread`, and `restart` move or respawn only what they name — they never relaunch the
whole fleet. `stop`/`start`/`restart` are the only things that ever kill an agent process.

Names accept either form: `fleet restart space-3` or `fleet restart my-nyc-space-3`.

## Layouts

Agents launch as one window each. `fleet grid` gathers the running panes into tiled windows
(configured by `GRID_GROUPS`) so you can watch several at once — **without relaunching them**
(tmux `join-pane` re-parents the live panes; the Claude processes never restart). `fleet spread`
undoes it.

Inside a grid window:

- **`Ctrl-b z`** — zoom the focused pane full-screen (toggles back)
- **`Ctrl-b <arrow>`** or **click** — move between panes
- **`Ctrl-b <n>`** or click the bar — switch windows
- **`Ctrl-b Space`** — cycle tiled / even / main layouts

## Configuration (`fleet.json`)

Everything — the agent roster, remote hosts, this machine's mode and location — lives in one
file: **`~/.config/fleet/fleet.json`** (requires [`jq`](https://jqlang.github.io/jq/)). It's the
source of truth; `fleet setup`, `fleet hosts`, and the installer all read and write it.

```json
{
  "mode": "server",              // per-machine — never pushed
  "location": "nyc",             // per-machine — never pushed
  "general": { "count": 4, "chrome": true, "remoteControl": false },
  "agents": {
    "space-1": { "repo": "acme/app", "remoteControl": true, "model": "opus" },
    "space-2": { "repo": "acme/app", "permissionMode": "default" },
    "review-1": { "repo": "acme/app", "harness": "codex" },
    "personal-1": { "repo": "youruser/personal", "chrome": false }
  },
  "hosts": { "nyc": "my-nyc-box", "desktop": "studio-mac" },
  "install": { "deps": [], "clis": ["claude", "codex"] }
}
```

- **`general.count`** — N scratch agents (`agent-A..`), each an agent in an empty folder
  (`~/co/agent-A`, auto-created) that it owns and can clear.
- **`agents`** — named repo agents, each fully self-describing: its own **`repo`** (clone this
  repo into `~/co/<name>`), **`chrome`**, **`remoteControl`**. Mix repos freely — work and
  personal side by side. **An agent with no `repo` is just a scratch agent** (empty folder).
- Per-agent **`remoteControl`** / **`chrome`** / **`model`** / **`permissionMode`** / **`harness`**
  — no global switches; set them on the exact agents you want. Defaults: `permissionMode` =
  `bypassPermissions`, `harness` = `claude` with `model` = `opus` (Opus 4.8). A top-level
  `"model"`/`"permissionMode"`/`"harness"` sets a fleet-wide default; the `general` tier or an
  individual agent overrides it.
- **`harness`** picks the CLI that runs in the pane — `claude` (default) or `codex`. A codex
  agent launches `codex` directly (model defaults to `gpt-5-codex`; `bypassPermissions` maps to
  `--dangerously-bypass-approvals-and-sandbox`, anything else to `--full-auto`). `send`/`log`/
  `attach`/`restart`/`respawn` and the tray all still work; status/summaries fall back to
  pane-scraping (Codex has no Claude hooks).
- **`install`** provisions the box: `{ "deps": ["ripgrep"], "clis": ["claude", "codex"] }`. The
  installer ensures the system `deps` (in addition to the always-installed git/jq/tmux) and the
  agent `clis` (Claude via its official installer; Codex via npm — installing Node first if
  needed — else brew). `fleet update` also upgrades these CLIs (`--no-clis` to skip).

**Auth is separate and interactive** — the installer can't log you in headlessly. On a fresh
machine, once the CLIs are installed, run `claude login` and `codex login` (each opens a browser
/ device-code flow), or set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` in the shell. Do this once per
machine before `fleet start`; agents inherit the stored credentials.
- **`hosts`** — remote machines (`short → tailscale hostname`) for `fleet remote` and the tray.
  `fleet hosts scan [--add]` discovers them from your tailnet.

Edit it directly (`fleet config edit`) or via commands: `fleet setup <owner>/<repo> <count>`
clones and generates the agent entries; `fleet hosts add/rm` manages hosts. **`fleet config push
[host]`** ships this file to your other machines over Tailscale, merging so each keeps its own
`mode` and `location`. Agents are named **`<owner>-<location>-<name>`** (e.g. `my-nyc-space-1`).

A handful of env vars still override at runtime: `FLEET_OWNER`, `FLEET_LOCATION`, `FLEET_MODE`,
`FLEET_CO_DIR` (default `$HOME/co`), `FLEET_CLAUDE_BIN`, `FLEET_TMUX_SESSION`, `FLEET_GIT_BASE`
(`git@github.com:`; set `https://github.com/` for HTTPS). If `jq`/`fleet.json` are absent, fleet
falls back to the legacy per-file config so older installs keep working.

## Menubar tray

A native Go menubar app (`tray/`) gives you an at-a-glance view of the whole fleet
without attaching to anything: hosts (local + remote, reachability from
Tailscale), live sessions per host, alerts (e.g. a Claude Code permission
prompt waiting on you), and one-line summaries of what each agent is doing.
Clicking a session jumps straight to it (opens a terminal and attaches to its
tmux pane).

It works in **both client and server mode** — it's a monitor, not an agent
runner, so it's equally useful on the laptop you drive remote fleets from and
on a server that also runs local agents. On a **server**, the installer's
`install-hooks` step wires Claude Code hooks that report status/alerts/summaries
straight into the tray for local agents; a **client** machine shows remote hosts
(via `fleet hosts --json`, polled over Tailscale SSH) only — there's nothing
local to hook into.

```sh
fleet tray start     # launch the tray (needs tray/fleet-tray built — see below)
fleet tray status    # is it running?
fleet tray stop      # kill it
```

The tray is **opt-in to run** — nothing in `fleet start`/`fleet up`/the
installer launches it. If you want it every login, opt in explicitly:

```sh
fleet tray enable-autostart    # launchd (macOS) / XDG autostart (Linux) — separate
fleet tray disable-autostart   # from the agent autostart installed in server mode
```

**Requirements:**
- The **built `fleet-tray` binary** at `tray/fleet-tray`. `install.sh` builds it
  automatically when [Go](https://go.dev) is on `PATH`; otherwise build it by hand:
  `cd tray && go build -o fleet-tray .`
- [Tailscale](https://tailscale.com) to see and reach remote hosts (same requirement
  as `fleet remote`).

**Ubuntu note:** stock GNOME hides tray/AppIndicator icons. Install the
extension and the tray icon will show up:

```sh
sudo apt install gnome-shell-extension-appindicator
gnome-extensions enable ubuntu-appindicators@ubuntu.com
```

## Auto-start on login

`autostart/fleet.desktop` runs `fleet up` on graphical login, resuming each agent's last
conversation. It's an XDG autostart entry (not systemd) because browser agents need the desktop
environment (`DISPLAY`/`WAYLAND`) that a graphical login provides.

## Multi-user / shared setup

`fleet.sh` auto-namespaces by `$USER` and uses each user's own `~/co`, so a single shared copy
serves multiple users with full feature parity. Put the files on a shared path both users can
read (e.g. `/srv/claude/` with ACLs) and have each user's dotfiles source them:

```sh
# in each user's ~/.bashrc
. /srv/claude/shell/fleet.bashrc
# in each user's ~/.tmux.conf
source-file /srv/claude/tmux.conf
```

Edit once, both users get it. Credentials, clipboard history, and workspaces stay per-user.

## Files

```
bin/fleet.sh          the launcher (start/grid/spread/restart/attach/…)
shell/fleet.bashrc    the `fleet` command + tab-completion
tmux.conf             mouse, grid pane labels, keybindings, status bar
autostart/fleet.desktop  login auto-start (resume)
install.sh            wires the above into your dotfiles
```

## How agents are identified

Each pane is tagged with a tmux pane option (`@agent`), not the pane title — Claude Code
overwrites the title with its own status glyph, so title-based matching is unreliable. `grid`,
`spread`, `attach`, and `restart` all locate panes by this stable tag, which is why they work
identically whether the fleet is gridded or spread.

## Remote / multi-machine

`fleet` installs the same way on every machine (laptop, desktop, VM), so you can hop between
their fleets over your Tailscale network.

**Configure your machines** with `fleet hosts add` (or by editing
`~/.config/fleet/hosts` directly — one entry per line, `#` comments ignored). No
remote machines are configured by default; this box only knows itself until you
add them:

```sh
fleet hosts add nyc my-nyc-box     # alias 'nyc' -> tailscale host 'my-nyc-box'
fleet hosts add studio-mac         # no alias — listed by its hostname
fleet hosts rm nyc                 # remove one
fleet hosts                        # list them
```

Aliases are optional: an entry with no `short:` is shown by its bare hostname.
Bootstrap fleet on a brand-new machine over Tailscale in one step:

```sh
fleet remote-install nyc           # install into ~/.fleet on the remote + run its installer
```

`fleet remote-install [--copy] [--global] <host> [location]` gets the repo onto the
remote and runs `install.sh` in server mode; the remote's location tag defaults to
the host's short name. By default it installs **per-user into `~/.fleet`** (no sudo);
`--global` installs into **`/opt/fleet`** (a system path — `sudo` creates it, then
it's owned by you so updates stay sudo-free). Either way the path is recorded in
`~/.config/fleet/home`, so `remote`/`update`/`respawn` resolve through it. By default
it `git clone`s the origin on the remote (needs `git` + clone access there); if that
fails — or with `--copy` — it falls back to `rsync`ing this checkout over Tailscale,
so a machine with no GitHub access still works:

```sh
fleet remote-install nyc            # per-user ~/.fleet; git clone on the remote, else auto-copy
fleet remote-install --copy nyc     # skip git, rsync this checkout over Tailscale
fleet remote-install --global nyc   # system-wide /opt/fleet (sudo)
```

Then:

```sh
fleet remote ls         # list configured hosts + online/offline (from tailscale status)
fleet remote nyc        # tailscale-ssh into my-nyc-box and attach its fleet
fleet remote nyc        # ... my-nyc-vm
```

`fleet remote ls` (or a bare `fleet remote`) prints the short-name → Tailscale
hostname map with a reachability column read from `tailscale status` — a local
lookup, so it never blocks on the network. `fleet remote <host>` also accepts a
bare Tailscale hostname that isn't listed. The tray polls exactly these hosts too.

### Setting up a new machine

**Prereq:** the new box is on your tailnet with Tailscale SSH enabled (once, on
the box: `tailscale up --ssh`).

**From your laptop** — register, provision, and configure the box:

```sh
fleet hosts add nyc my-nyc-box     # 1. name it (alias 'nyc' -> tailscale host)
fleet keys forward on              # 2. so the install-time git clones run as you
fleet remote-install nyc           # 3. clone + install fleet (server mode) on nyc
fleet keys setup nyc               # 4. durable key so nyc's agents can push —
                                   #    add it to GitHub when prompted
fleet config push nyc              # 5. push your agent roster into nyc's config
```

**On the box** — hop on interactively for the logins and first start (an
interactive shell is where the `fleet` command and a login TTY are available):

```sh
fleet remote-ssh nyc               # 6. opens a shell on nyc; there, run:
  #   claude login                 #      log the CLIs in (device flow — approve
  #   codex login                  #      in your browser; API keys are the alternative)
  #   fleet doctor                 #      verify: tools, config, auth all green
  #   fleet start                  #      launch the fleet
  #   exit
```

**Back on your laptop** — watch it:

```sh
fleet remote nyc                   # 7. attach nyc's tmux session (the tray shows it too)
```

1. **Name it** — the only place the machine is registered; nothing is configured
   by default.
2. **Forward your keys** *(only if the box needs GitHub)* — fleet sends no keys by
   default, so the `git clone` in step 3 would otherwise fail (and fall back to
   `rsync`). `keys forward on` lets those clones authenticate as you. Skip for
   public repos or if you `--copy` instead.
3. **Install** — installs fleet into `~/.fleet` on nyc (or `/opt/fleet` with
   `--global`) and runs `install.sh` in
   **server** mode, provisioning `git`/`jq`/`tmux`, the CLIs, and any
   `install.deps`. `--copy` `rsync`s this checkout instead (for a box with no
   GitHub access at all).
4. **Give it its own key** — forwarding only lasts a session, so the autonomous
   agents need a durable credential to push. `keys setup` generates one on nyc and
   shows how to add it to GitHub (user key = broad, deploy key = one repo). Do this
   before the agents start, since `fleet start` clones each agent's repo.
5. **Push the roster** — merges your `agents`/`general`/`hosts` into nyc's
   `fleet.json`, preserving its per-machine `mode`/`location`. `--restart` relaunches
   immediately with the new config.
6. **Log in + start** — the installer can't authenticate headlessly; `claude login`
   / `codex login` open a device-code flow. `fleet doctor` flags anything still
   missing, then `fleet start` launches every agent. *(From the laptop you can also
   `fleet respawn nyc` to start a stopped fleet without attaching.)*
7. **Watch** — `fleet remote nyc` attaches its tmux; the [menubar
   tray](#menubar-tray) shows it too.

`fleet remote-ssh <host> [cmd]` drops you into a plain shell (or runs one
command) on a remote — unlike `fleet remote`, it doesn't need a running fleet, so
it's what you use to `claude login`, provision, or debug a box.

### Remote git access (`fleet keys`)

Agents on a remote commit and push, so the box needs GitHub access. Two
complementary mechanisms, neither of which copies your private key anywhere:

```sh
fleet keys forward on        # (A) ForwardAgent for your tailnet hosts in ~/.ssh/config
fleet keys setup nyc         # (B) generate a key ON nyc + show how to add it to GitHub
fleet keys check nyc         # verify: does nyc authenticate to GitHub?
fleet keys status            # is forwarding wired up locally?
```

- **`keys forward` (A)** forwards your local `ssh-agent` over the Tailscale SSH
  connection, so remote `git` authenticates as **you** — but only *during a
  session* (interactive `remote-ssh`, the `remote-install` clone). It manages a
  clearly-marked block in `~/.ssh/config` and leaves the rest of the file
  untouched. Test with `fleet remote-ssh nyc ssh-add -l`.
- **`keys setup` (B)** gives the box its **own** durable key (revocable per host)
  that the autonomous agents use to push — add it to GitHub once as a user key
  (broad access) or a repo deploy key (scoped). This is what a fleet of
  committing agents actually needs; forwarding alone can't cover them because the
  forwarded socket dies when your session ends.

**Which key gets used** with multiple keys: with forwarding, the remote offers
your agent's keys in agent order and GitHub picks the account the first
recognized key belongs to (the login user is always `git`) — so if your keys
live on the same GitHub account it doesn't matter, but keys on *different*
accounts mean the first-offered one wins. Pin a specific one with an
`IdentityFile`/`IdentitiesOnly` block for `github.com`, or just use a per-host
key (B), which is unambiguous — the box has exactly one.

## Updating

`fleet` keeps itself current from git:

```sh
fleet update            # fast-forward this machine's checkout + re-wire dotfiles
fleet update laptop     # do the same on another machine over Tailscale SSH
```

`fleet update` self-locates its own checkout, `git fetch`es, and **fast-forwards
only** — if you have local commits or a dirty tree it refuses rather than clobber
them. When something changed it re-runs the (idempotent) installer so new shell /
tmux / autostart wiring lands. Already-running agents keep the old launcher until
you `fleet restart <name>` (or `fleet stop && fleet start`).

Remote hop requires [Tailscale](https://tailscale.com) with SSH enabled
(`tailscale set --ssh`) on both ends, that you're authorized on the tailnet, and fleet installed
on the remote (the installer records the repo path in `~/.config/fleet/home` so the remote is
found regardless of its login shell).

## Requirements

**Core (every machine):**
- **tmux** 3.x
- **[Claude Code](https://claude.com/claude-code)** CLI on `PATH`
- **git** (for keeping this repo in sync across machines)
- **[jq](https://jqlang.github.io/jq/)** — reads/writes the `fleet.json` config (`brew install jq` / `apt install jq`)

**Per feature:**
- **`--chrome` browser agents** — a graphical session (`DISPLAY`/`WAYLAND` on Linux; the desktop on macOS)
- **`fleet remote`** — [Tailscale](https://tailscale.com) with SSH on both ends
- **Clipboard bridging** — the tmux config auto-selects the copy backend: `pbcopy` (macOS),
  `wl-copy` ([wl-clipboard](https://github.com/bugaevc/wl-clipboard), Linux/Wayland), or
  `gpaste-client` (GNOME). SSH copy-back works via OSC 52 with no extra tool.
- **Memory sync** (if used) — `inotify-tools` on Linux (`sudo apt install inotify-tools`) for the
  write-watcher; `fswatch` on macOS

## Install (macOS + Linux, bash + zsh)

`install.sh` detects your OS and login shell: it sources the `fleet` command into the right rc
file, points tmux at the bundled config, records the repo path, and installs a login auto-start
(XDG `.desktop` on Linux, a launchd agent on macOS). Re-runnable and idempotent.

Tag the machine's location at install time so its agents are named for where they run:

```sh
FLEET_LOCATION=laptop ./install.sh    # agents become my-laptop-* instead of my-nyc-*
```

### Client vs server mode

A machine installs in one of two modes (recorded in `~/.config/fleet/mode`):

- **`server`** (default) — a full node: runs its own local agents and installs a
  login autostart. Your desktops and VMs.
- **`client`** — attach-only: **never runs local agent sessions** and installs no
  autostart. `fleet start`/`fleet up` refuse here (override once with
  `FLEET_MODE=server fleet start`); `attach`, `remote`, `update`, and `status`
  all still work. Good for a laptop you only use to drive remote fleets.

```sh
FLEET_MODE=client FLEET_LOCATION=laptop ./install.sh   # attach-only laptop
./install.sh                                            # server (desktop / VM)
```

Switching an existing install to client mode also removes the autostart entry a
prior server install left behind. `fleet update` preserves the chosen mode.

## Development

CI (`.github/workflows/ci.yml`) runs the bash test suite (`tests/test_*.sh`) and the Go
tray's `vet` / `test` / `build` / `gofmt` on every push and PR.

Cutting a release tags `v*`, which triggers `.github/workflows/release.yml` to build the
`fleet-tray` binaries (Linux amd64/arm64, macOS arm64) and attach them to a GitHub release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```
