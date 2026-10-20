# clients-vps-init

Shared **FASTPANEL** VPS bootstrap for EgyptDev client Laravel apps (queue workers via Supervisord). Works on Ubuntu and Debian.

Repository: [github.com/EgyptDevRu/clients-vps-init](https://github.com/EgyptDevRu/clients-vps-init).

| Script | Who runs it | When |
|--------|-------------|------|
| `init.sh` | **root** | Once per VPS, and again to update |
| `activate-worker.sh --all` | **root** cron | Every 5 minutes; project scan every 30 minutes |

---

## Install / update

As **root** (or with `sudo`) on the server:

```bash
wget -qO- https://raw.githubusercontent.com/EgyptDevRu/clients-vps-init/main/init.sh | sudo bash
```

Debian servers often have no `sudo`; there, log in as root and drop it (`... | bash`). Without `wget`, use `curl -fsSL <same URL> | bash`.

This clones the repo into `/opt/EgyptDevRu/clients-vps-init` (or runs `git pull` if it is already there) and then runs the checkout's `init.sh`. Run the same command again to update.

`init.sh` will:

1. Install and enable **Supervisord** and **cron**
2. Make `/etc/supervisor/conf.d` and the Supervisord control socket **root-only**
3. Install `activate-worker.sh` to `/usr/local/bin/activate-worker.sh`
4. Add a **root** crontab entry (every 5 minutes): `/usr/local/bin/activate-worker.sh --all`
5. Run it once: move old user-written configs out of `conf.d` (see Upgrading), scan projects, apply
6. Restart Supervisord

---

## Security model

Supervisord runs as root, so whoever can write its configs or use its socket controls the server. Therefore:

- Site users **never** write to `/etc/supervisor/conf.d` and cannot use `supervisorctl`.
- Users edit their own files in `~/supervisor/*.conf`. Root reads them **as that user** (no access to anything the user could not read) and renders `/etc/supervisor/conf.d/worker-<user>.conf`.
- Only `[program:NAME]` sections and these settings are accepted: `command`, `directory` (inside the home directory), `numprocs` (1-8), `numprocs_start`, `priority`, `autostart`, `autorestart`, `startsecs`, `startretries`, `exitcodes`, `stopsignal`, `stopwaitsecs` (max 3600), `stopasgroup`, `killasgroup`, `environment`, `umask`.
- Always set by the server: `user=<owner>`, the program name `worker-<user>-NAME`, `process_name`, and logging. Supervisor writes logs to `/var/log/supervisor/users/<user>/` (root-owned, readable by the user), never into user-controlled folders.
- Per user: at most 20 programs and 16 processes. `%` expansions and indented continuation lines are rejected.
- A rejected file never affects other users. While any of a user's files is rejected, that user's last good config stays active.

---

## How it runs

**Every 5 minutes** the cron reads each user's `~/supervisor/*.conf`, validates them and re-renders `conf.d`. Only if `conf.d` changed does it run `supervisorctl reread` and `supervisorctl update`, once.

**Every 30 minutes** it also scans projects, as each site user (UID 1000-59999) via `setpriv`. This switches the UID without a PAM login session, so no `systemd --user` is started:

1. Resolves PHP (`$HOME/bin/php`, then `/opt/php85|84|83/bin/php`) and finds every `artisan` under `~/www` (max depth 4).
2. Creates `~/supervisor/<project>.conf` when no file references that project yet.
3. Removes files in `~/supervisor` whose project (`artisan`) no longer exists.

Configs of deleted accounts are removed on the next 5-minute run. Server-side events are logged to syslog with the tag `activate-worker` (`journalctl -t activate-worker`).

Default worker (`numprocs=2`):

```text
queue:work --queue=telegram,default --sleep=3 --tries=3 --max-time=3600
```

---

## Editing worker configs (site users)

Your configs are in `~/supervisor/`. Generated ones start with a marker line:

```text
; managed-by=activate-worker sha256=...
```

While the file is unchanged, the script may regenerate it (for example when the PHP path changes). As soon as you change anything, the file is yours.

| You do | Result |
|--------|--------|
| Edit the file | Kept as-is, never rewritten. Applied within 5 minutes. |
| Rename the file | Kept. No new config is created, because a file referencing the project's `artisan` already exists. |
| Empty the file (or leave only comments) | Workers stop within 5 minutes. The config is never filled again. Delete the empty file to re-enable. |
| Delete the file | Workers stop within 5 minutes. A fresh default config is created within 30 minutes (reset to default). |
| Set `autostart=false` | Workers stay off, your settings are kept. |
| Add your own `[program:NAME]` | Loaded as `worker-<user>-NAME` if it passes validation. |
| Remove the project | Its files (generated or edited) are removed on the next scan. |

Where to look:

- Worker output: `/var/log/supervisor/users/<user>/worker-<user>-NAME.log`
- Why a file was rejected or a setting ignored: `/var/log/supervisor/users/<user>/activate-worker.log`

---

## Upgrading from the old version

Old versions let users write straight into `conf.d`. On the first run after updating, every file in `conf.d` not owned by root is handled:

- Unedited old auto-generated configs are deleted; a new default is created in `~/supervisor/`.
- Edited ones are moved to `~/supervisor/migrated-<name>` (owned by the user), then validated like any other file.
- Symlinks are deleted.

Root-owned files in `conf.d` (your own admin configs) are left alone.

---

## Verify

```bash
supervisorctl status
```

You should see `RUNNING` programs named like `worker-SITE_USER-PROJECT:worker-SITE_USER-PROJECT_00`.

Force a full scan now instead of waiting:

```bash
sudo rm -f /var/lib/activate-worker/last-scan
sudo /usr/local/bin/activate-worker.sh --all
```
