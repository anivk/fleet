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

**No repos are configured out of the box.** A fresh install gives you 4 general
**scratch agents** (`agent-A..D` — empty `~/co/agent-*` workspaces, auto-created)
and an empty repo roster in `~/.config/fleet/fleet.json`. Add **repo agents** with
`fleet setup`, which clones a GitHub repo N times and records them in the config:

```sh
fleet setup your-org/your-repo 4     # 4 clones of github.com/your-org/your-repo
```

The repo basename becomes the workspace prefix (`your-repo` → `~/co/your-repo-1..4`),
saved to `fleet.json` so `fleet start` knows what to launch. Re-run any time to change
the repo or count (existing clones are left in place). SSH by default; for HTTPS:
`FLEET_GIT_BASE=https://github.com/ fleet setup <owner>/<repo> N`.

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
| `fleet boot {enable [--xvfb]\|disable}` | Start the fleet on **boot, before login** (Linux/systemd + linger); `--xvfb` adds a virtual display so `--chrome` agents run headless. See [Auto-start](#auto-start) |
| `fleet caffeinate [--prevent-screen-lock]` / `fleet decaffeinate` | Keep the machine awake so long jobs aren't cut off by sleep (macOS `caffeinate` / Linux `systemd-inhibit`); optionally hold off the screen lock |
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
  "hosts": { "nyc": "my-nyc-box", "desktop": "studio-mac" }
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

The tray is part of the `fleet` binary (`fleet tray run` runs it in-process — no
separate app to build). On macOS `fleet tray start` wraps it in a tiny `Fleet.app`
so it shows as "Fleet" with no Dock icon.

```sh
fleet tray start     # launch the tray
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
- The `fleet` binary (it carries the tray — nothing extra to build).
- [Tailscale](https://tailscale.com) to see and reach remote hosts (same requirement
  as `fleet remote`).

**Ubuntu note:** stock GNOME hides tray/AppIndicator icons. Install the
extension and the tray icon will show up:

```sh
sudo apt install gnome-shell-extension-appindicator
gnome-extensions enable ubuntu-appindicators@ubuntu.com
```

## Auto-start

Two mechanisms, depending on whether your agents need a browser:

- **Login autostart** (default in server mode) — `fleet install` drops an XDG autostart
  entry (Linux) / launchd agent (macOS) that runs `fleet up` on **graphical login**,
  resuming each agent's last conversation. This is the default because `--chrome`
  browser agents need the desktop environment (`DISPLAY`/`WAYLAND`) a login provides.
- **Boot service** (headless servers) — `fleet boot enable` installs a **systemd user
  service** and enables *linger*, so the fleet starts on **boot, before any login**.
  Add **`--xvfb`** to run a virtual X display so `--chrome` browser agents (Chrome +
  the Claude Code extension) work headless too — provision it first with
  `fleet bootstrap --with-xvfb`.

```sh
fleet boot enable          # start on boot, before login (Linux/systemd)
fleet boot enable --xvfb   # + a virtual display so --chrome agents run headless
fleet boot status          # enabled? lingering? active?
fleet boot disable         # remove the boot service
```

Under `--xvfb`, fleet runs `Xvfb :99` and sets `DISPLAY=:99` in the service, so a real
Chrome (with your extension profile) renders offscreen — not `--headless`, which
doesn't load extensions cleanly.

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
main.go, embed.go, extract.go   the Go binary — embeds + runs the bash launcher
internal/tray/                  the koala menubar tray (compiled into the binary)
bin/fleet.sh                    the launcher (start/grid/spread/restart/attach/…)
shell/fleet.bashrc              the `fleet` command + tab-completion (source installs)
tmux.conf                       mouse, grid pane labels, keybindings, status bar
bootstrap/bootstrap.sh          provision a box: Tailscale + deps + claude
install.sh                      wire fleet: config, tmux, hooks, autostart
get.sh                          curl installer — fetch the release binary
autostart/fleet.desktop         login auto-start (resume)
```

## How agents are identified

Each pane is tagged with a tmux pane option (`@agent`), not the pane title — Claude Code
overwrites the title with its own status glyph, so title-based matching is unreliable. `grid`,
`spread`, `attach`, and `restart` all locate panes by this stable tag, which is why they work
identically whether the fleet is gridded or spread.

## Remote / multi-machine

`fleet` installs the same way on every machine (laptop, desktop, VM), so you can hop between
their fleets over your Tailscale network.

**Configure your machines** with `fleet hosts add` (or `fleet config edit` — hosts
live in `fleet.json`'s `hosts` map). No remote machines are configured by default;
this box only knows itself until you add them:

```sh
fleet hosts add nyc my-nyc-box     # alias 'nyc' -> tailscale host 'my-nyc-box'
fleet hosts add studio-mac         # no alias — listed by its hostname
fleet hosts rm nyc                 # remove one
fleet hosts                        # list them
```

Aliases are optional: an entry with no `short:` is shown by its bare hostname.

The recommended way to set up a new box is the binary flow — `curl … get.sh | sh`
then `fleet bootstrap` + `fleet install` on the box (see [Setting up a new
machine](#setting-up-a-new-machine)). `fleet remote-install` is the **source-based**
alternative: it gets this repo onto the remote and runs `install.sh` (fleet wiring
only — the box must already be provisioned via `bootstrap`, since Tailscale is a
prerequisite for reaching it anyway):

```sh
fleet remote-install nyc           # source checkout into ~/.fleet + run install.sh
```

`fleet remote-install [--copy] [--global] <host> [location]` installs **per-user into
`~/.fleet`** by default (no sudo); `--global` uses **`/opt/fleet`** (`sudo` creates it,
then chowns it to you so updates stay sudo-free). It `git clone`s the origin on the
remote; if that fails — or with `--copy` — it `rsync`s this checkout over Tailscale,
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

Everything fleet does remotely goes **over Tailscale**, so the one thing that must
happen on the box first is Tailscale — you can't reach it otherwise. The rest is the
binary flow.

**Prereq — on the box:** get it on your tailnet (once). An auth key makes it
non-interactive (great for cloud-init):

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh                 # or --authkey=tskey-… for no browser
```

**Then, on the box:** install fleet and bring it up. `fleet bootstrap` needs `sudo`
for packages, so run it there (interactively):

```sh
curl -fsSL https://raw.githubusercontent.com/anivk/fleet/main/get.sh | sh   # the binary
fleet bootstrap        # deps (git/jq/tmux) + claude   (tailscale already up)
claude login           # once — device flow (or export ANTHROPIC_API_KEY)
fleet install          # wire config + hooks + autostart
fleet setup you/repo 4 # (optional) add repo agents; or `fleet config push` from your laptop
fleet start            # launch the agents      (fleet boot enable → start on boot)
```

**From your laptop — register + watch it:**

```sh
fleet hosts add <hostname>    # so `fleet remote` and the tray see it
fleet remote <hostname>       # attach its tmux (the tray shows it too)
```

Notes:
- **`fleet config push <host>`** ships your agent roster to the box (merging, so it
  keeps its own `mode`/`location`) instead of `fleet setup` on the box.
- **Repo agents need GitHub access on the box** to clone/push — see
  [Remote git access](#remote-git-access-fleet-keys) (`fleet keys`).
- **`fleet remote-ssh <host> [cmd]`** drops you into a plain shell on a remote (works
  even when its fleet isn't running) — handy for `claude login`, provisioning, debugging.
- Prefer to drive it all from the laptop? `fleet remote-install <host>` pushes the
  source + wires fleet (the box still needs `bootstrap` for deps/claude).

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

```sh
fleet update            # update this machine (see below); --no-clis skips the CLI upgrade
fleet update <host>     # do the same on another machine over Tailscale SSH
```

- **Binary install** — `fleet update` checks the latest release first: if you're already
  on it, it does nothing; otherwise it replaces the binary in place and upgrades
  `claude`/`codex`. `--force` re-downloads regardless; `fleet version` shows what you're on.
- **Source checkout** — `fleet update` `git fetch`es and **fast-forwards only** — a
  dirty tree or local commits make it refuse rather than clobber — then re-runs the
  installer to re-wire config/tmux/hooks.

Already-running agents keep the old launcher until you `fleet restart <name>` (or
`fleet stop && fleet start`). The remote hop requires [Tailscale](https://tailscale.com)
with SSH on both ends and `fleet` on the remote's PATH.

## Requirements

**Supported platforms: macOS and Ubuntu** — each as a **server** (runs agents) or a
**client** (attach-only). Any mix of the two works (a Mac laptop driving Ubuntu
servers, an Ubuntu desktop + Mac VMs, etc.); other OSes aren't supported.

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

## Client vs server mode

A machine installs in one of two modes (recorded in `fleet.json`). `fleet install`
reads `FLEET_MODE` / `FLEET_LOCATION` at install time:

- **`server`** (default) — a full node: runs its own local agents and installs a
  login autostart. Your desktops and VMs.
- **`client`** — attach-only: **never runs local agent sessions** and installs no
  autostart. `fleet start`/`fleet up` refuse here (override once with
  `FLEET_MODE=server fleet start`); `attach`, `remote`, `update`, and `status`
  all still work. Good for a laptop you only use to drive remote fleets.

```sh
FLEET_MODE=client FLEET_LOCATION=laptop fleet install   # attach-only laptop
fleet install                                           # server (desktop / VM)
```

Switching an existing install to client mode also removes the autostart entry a
prior server install left behind. `fleet update` preserves the chosen mode.

## Development

The launcher is bash (`bin/fleet.sh`), embedded into a Go binary (`main.go` +
`internal/tray/`) via `go:embed` and extracted to a cache dir at runtime. Build it with
`go build -o fleet .`.

CI (`.github/workflows/ci.yml`) runs the bash test suite (`tests/test_*.sh`) and the Go
`vet` / `test` / `build` / `gofmt` on every push and PR. Cutting a release tags `v*`,
which triggers `.github/workflows/release.yml` to build the `fleet` binaries
(`fleet-{linux,darwin}-{amd64,arm64}`) and attach them to a GitHub release; `get.sh`
downloads the right one.

```sh
git tag v0.1.0 && git push origin v0.1.0
```
