# Linux host (systemd user service)

Runs `zcode --web` on a Linux machine as a `systemd --user` service, published on your tailnet with
`tailscale serve` so the iOS app can use it as a host (alongside or instead of a Mac). Everything lives in
`$HOME`: no sudo, no system changes; only `tailscale serve` touches anything outside.

SteamOS (Steam Deck / Steam Machine) is used as the worked example below: its root filesystem is immutable,
which is the most constrained case. On a regular distribution, install a compiler toolchain
(`base-devel` / `build-essential`) and you can skip the distrobox fallback.

Placeholders: `<user>@<linux-host>` (SSH target), `https://<linux-host>.<tailnet>.ts.net` (tailnet URL),
`<workspace>` (the server's default workspace on the host, `$HOME` unless you set `ZCODE_WORKSPACE`).

## Prerequisites

- SSH access to the host (Tailscale SSH works well): `ssh <user>@<linux-host>`.
- `git`, `curl`, `python3`, `zsh`. SteamOS already ships them, plus `systemd-inhibit`, `distrobox` and
  `podman`. Node, mise and pnpm are not needed up front (mise installs them); `gcc`/`make` are needed to build
  native modules (see "Distrobox fallback" if you can't install them).
- `systemctl --user` working, with lingering enabled so user services start at boot and survive logout:
  `loginctl show-user "$USER" -p Linger` should print `Linger=yes` (otherwise `sudo loginctl enable-linger <user>`).
- Tailscale running on the host, with your user allowed to run `tailscale serve` (`tailscale set --operator=<user>`).
  On SteamOS the CLI is often `/opt/tailscale/tailscale`, which is not in the `PATH` of a non-interactive SSH
  session; `install-service.sh` looks there first (override with `TS_BIN`).
- If the host already publishes other routes with `tailscale serve`, they are preserved: the install script uses
  `tailscale serve --set-path /`, which adds the route without touching existing ones. Never run
  `tailscale serve reset`, and never use `funnel` (the server must stay tailnet-only).

## Installation

```sh
# 1. Copy the host scripts to a dedicated directory
rsync -a --delete host/ <user>@<linux-host>:~/zcode-host/

# 2. SteamOS: install mise in ~/.local/bin (official installer) and print the tools' state
ssh <user>@<linux-host> 'zsh ~/zcode-host/linux/bootstrap-steamos.sh'

# 3. Build ZCode (several minutes; see "Distrobox fallback" if it fails), detached from the SSH session
ssh <user>@<linux-host> 'mkdir -p ~/.local/state/zcode-web'
ssh <user>@<linux-host> 'systemd-run --user --unit=zcode-install --collect \
  --property=StandardOutput=append:$HOME/.local/state/zcode-web/install.log \
  --property=StandardError=append:$HOME/.local/state/zcode-web/install.log \
  /usr/bin/env PATH=$HOME/.local/bin:/usr/bin:/bin /bin/zsh $HOME/zcode-host/install-zcode.sh v3.15.1 --activate'
ssh <user>@<linux-host> 'tail ~/.local/state/zcode-web/install.log'   # wait for "ZCode 3.15.1 activated."

# 4. systemd --user service + `tailscale serve` on "/" (existing routes kept)
ssh <user>@<linux-host> 'ZCODE_WORKSPACE=<workspace> zsh ~/zcode-host/linux/install-service.sh'
```

Long jobs over SSH: use `systemd-run --user` as above. A `nohup … &` started from an `ssh` command is easily
killed when the session closes (for instance `mkdir && nohup … &` backgrounds the whole chain, which then dies
with the session). `$HOME` is expanded by the remote shell, inside the single quotes.

`ZCODE_WORKSPACE` is optional (default `$HOME`); it is written into the unit as
`Environment="ZCODE_WORKSPACE=…"`. Rerun `install-service.sh` to change it.

## State

- Runtime: `~/.local/share/zcode-web/current` (versions under `…/versions/`, Node from mise).
- Service: `systemctl --user status zcode-web` (unit `~/.config/systemd/user/zcode-web.service`).
- Logs: `~/.local/state/zcode-web/zcode-web.log` (token redacted by `sed`); build log in
  `~/.local/state/zcode-web/install.log`.
- Token: `~/.config/zcode-web/token` (mode 600, directory 700). Anyone with it has shell-level access to the
  machine through ZCode: never print it in shared places. To get it onto the iPhone from a Mac:
  `ssh <user>@<linux-host> 'cat ~/.config/zcode-web/token' | pbcopy`, then Universal Clipboard.
- Tailnet URL: `https://<linux-host>.<tailnet>.ts.net` (root `/` → `127.0.0.1:3030`).
- Keep-awake: `systemd-inhibit --list` shows `zcode-web` (`sleep:idle`, `block`) while the server runs.
- ZCode data: `~/.zcode`, shared with a desktop ZCode on the same account if there is one (GLM account and
  providers are reused).

## Distrobox fallback (compiler required)

`pnpm install` compiles native modules (`node-pty`, `cpu-features`) with node-gyp: without `make`/`gcc` on the
host it fails ("not found: make"). On an immutable root, run the build in an Arch container instead. It shares
`$HOME`, so the output lands in the same place, and the resulting binaries run as is on the host (same kernel):

```sh
ssh <user>@<linux-host> 'distrobox create --name zcode-build --image docker.io/library/archlinux:latest --yes'
ssh <user>@<linux-host> 'distrobox enter zcode-build -- sudo pacman -Sy --needed --noconfirm base-devel git zsh curl python'
# then step 3 with: distrobox enter zcode-build -- env PATH=$HOME/.local/bin:$PATH zsh ~/zcode-host/install-zcode.sh …
```

## Updating ZCode

`host/update-zcode.sh` is macOS-only (its contract check needs Swift), but the same procedure works by hand:
build the new version without activating it, switch, check from a Mac, roll back if needed. The service is only
down for a few seconds during the switch.

```sh
# 1. Build the new tag without --activate: the service keeps running on the old version.
ssh <user>@<linux-host> 'systemd-run --user --unit=zcode-update --collect \
  --property=StandardOutput=append:$HOME/.local/state/zcode-web/install.log \
  --property=StandardError=append:$HOME/.local/state/zcode-web/install.log \
  /usr/bin/env PATH=$HOME/.local/bin:/usr/bin:/bin /bin/zsh $HOME/zcode-host/install-zcode.sh v3.15.2'
ssh <user>@<linux-host> 'tail ~/.local/state/zcode-web/install.log'   # wait for "installed (not activated)"

# 2. Switch + restart (use the version actually built above).
ssh <user>@<linux-host> 'ln -sfn ~/.local/share/zcode-web/versions/3.15.2 ~/.local/share/zcode-web/current \
  && systemctl --user restart zcode-web'

# 3. Contract check from the Mac, in this repository (one GLM prompt).
ZCODE_TOKEN="$(ssh <user>@<linux-host> 'cat ~/.config/zcode-web/token')" \
  swift run --package-path Packages/ZCodeKit zcode-probe check \
  --url https://<linux-host>.<tailnet>.ts.net --workspace <workspace>

# 4. Roll back if the check fails (use the previous version).
ssh <user>@<linux-host> 'ln -sfn ~/.local/share/zcode-web/versions/3.15.1 ~/.local/share/zcode-web/current \
  && systemctl --user restart zcode-web'
```

Then check in the app that switching between hosts still works. Old versions stay in
`~/.local/share/zcode-web/versions/` as rollback material; delete them by hand when disk space gets tight.

Never rerun `install-zcode.sh` on the version **in service** without `ZCODE_INSTALL_DIR`: it empties and refills
`versions/<version>`, the directory `current` points to.

### Same version, fixed staging (re-stage without rebuilding)

When only `stage-zcode.mjs` changed and `~/src/ZCode` is already built at the right tag
(`git -C ~/src/ZCode describe --tags`), re-staging into a new directory is enough:

```sh
rsync -a --delete host/ <user>@<linux-host>:~/zcode-host/
ssh <user>@<linux-host> 'D=~/.local/share/zcode-web/versions/3.15.1+r$(date +%Y%m%d%H%M%S); cd ~/src/ZCode \
  && env PATH=$HOME/.local/bin:/usr/bin:/bin mise exec -- node ~/zcode-host/stage-zcode.mjs ~/src/ZCode "$D" && echo "$D"'
# No prompt needed: the bundled skill must be found ("Skill not found" otherwise), from any directory.
ssh <user>@<linux-host> 'N=$(cd ~/src/ZCode && env PATH=$HOME/.local/bin:/usr/bin:/bin mise which node); cd /tmp && "$N" \
  ~/.local/share/zcode-web/versions/3.15.1+r<timestamp>/agent/zcode.cjs skills inspect dynamic-workflows | head -3'
# Switch (step 2 above with this directory), then roll back to versions/3.15.1 if needed.
```

Switching restarts the service, which **cancels a turn in progress**: first make sure no session is working
(`~/.zcode/cli/log/zcode-<date>.jsonl`, last `core.runtime` lines). The protocol's skill catalogue does not list
bundled skills, and the "Bundled skill pack unavailable" warning (same log) only appears on a session's first turn.

## Troubleshooting

- `fetch-pack: unexpected disconnect while reading sideband packet` while cloning: HTTP/2 is being cut by the
  network; `install-zcode.sh` already forces `git -c http.version=HTTP/1.1`.
- A mangled `refs/tags/v3.15…`: zsh's `:r` modifier ate the refspec; variable references in zsh scripts go in
  braces (`${TAG}`).
- zsh `print` refusing a string that starts with `-`: use `print -- "…"`.
- Server not answering: `systemctl --user is-active zcode-web`, then the log above. Rerunning the installation has
  no side effects (token kept, a single `/` route).
- Node not found: `run-zcode-web.sh` uses `ZCODE_NODE`, else the newest `~/.local/share/mise/installs/node/24.x.y`,
  else `node` from `PATH`. Set `Environment="ZCODE_NODE=…"` in the unit if Node lives elsewhere.
- Probe from the Mac (token via environment variable, never as an argument):
  `ZCODE_TOKEN="$(ssh <user>@<linux-host> 'cat ~/.config/zcode-web/token')" swift run --package-path
  Packages/ZCodeKit zcode-probe info --url https://<linux-host>.<tailnet>.ts.net`.
  The `Probe/*.json` scenarios substitute `${HOME}` with the **local** HOME: replace it with the host's
  `<workspace>` to target the Linux host.
