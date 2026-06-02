# Caddy Reverse Proxy — VPS Deployment

A self-contained setup for running multiple Docker services behind a Caddy reverse proxy with automatic HTTPS on Ubuntu.

Run **`setup_v2.sh`** on a **fresh Ubuntu VPS** (24.04 or newer; 24.04 LTS recommended) where only **root** exists over SSH.

## Services included

| Service | URL pattern | Auth |
|---------|-------------|------|
| Uptime Kuma | `https://kuma.<APPS_DOMAIN>` | Caddy basic auth **and** Kuma login |
| Dozzle | `https://dozzle.<APPS_DOMAIN>` | Caddy basic auth |
| Dockge | `https://dockge.<APPS_DOMAIN>` | Caddy basic auth |

Example: if `APPS_DOMAIN=apps.example.com`, use `https://kuma.apps.example.com`.

## Fresh VPS installation (only `root` exists)

Use this flow for a new server. After `setup_v2.sh`, **do not use root over SSH** — use the deploy user (or whatever you set as `NEW_USER` in `setup.env`).

| Step | Run as | What to do |
|------|--------|------------|
| **1** | **root** | SSH in: `ssh root@your-vps-ip` |
| **2** | **root** | Clone the repo (git is installed in the next step if missing — see note below) |
| **3** | **root** | Create and edit `setup.env` (see [Configuration](#configuration-setupenv)) |
| **4** | **root** | Run `bash setup_v2.sh` — hardening, Docker, stacks, `deploy` user |
| **5** | **deploy** | In a **new terminal**, test SSH: `ssh -p 2222 deploy@your-vps-ip` (use your `SSH_PORT` / `NEW_USER`) |
| **6** | **deploy** | Start all stacks with `docker compose` (no root; user is in the `docker` group) |
| **7** | **deploy** | Open HTTPS URLs in a browser and finish Uptime Kuma setup |

### Step 1–3 as root (clone and `setup.env`)

On a minimal Ubuntu image you may not have `git` yet. Either install it once:

```bash
apt-get update && apt-get install -y git
```

or run `setup_v2.sh` only **after** cloning — the script’s first step installs `git`, `nano`, `vim`, `curl`, and `gettext-base` (needed for `envsubst` when rendering the Caddyfile).

**Recommended order** (clone first, then run setup). Clone under **`/opt/caddy_reverse`**, not `/root/...`: after setup, the repo is owned by `deploy`, but `/root` stays mode `700`, so `deploy` cannot `cd` into a path under `/root`.

```bash
ssh root@your-vps-ip

# If git is missing on the image:
apt-get update && apt-get install -y git

git clone <this-repo-url> /opt/caddy_reverse
cd /opt/caddy_reverse

cp setup.env.example setup.env
nano setup.env    # or vim; or edit locally and scp (see below)
```

Fill in at least: `APPS_DOMAIN`, `ACME_EMAIL`, `SSH_PUBLIC_KEYS`, and optionally `CADDY_BASIC_AUTH_HASH` (see below).

Alternative: edit `setup.env` on your laptop and copy it to the server:

```bash
scp -P 22 setup.env root@your-vps-ip:/opt/caddy_reverse/setup.env
```

### Step 4 as root (`setup_v2.sh`)

Still on the **root** session, from the repo directory:

```bash
cd /opt/caddy_reverse
bash setup_v2.sh
```

Do **not** use `sudo` if you are already root. The script:

- Installs packages (`git`, `nano`, `vim`, `docker`, `gettext-base`, hardening tools, …)
- Creates user **`deploy`** (or `NEW_USER`) with your SSH key
- Disables root SSH and password login
- Renders `/opt/stacks` from templates
- Gives **`deploy`** ownership of the cloned repo (for `git pull` later)

If `CADDY_BASIC_AUTH_HASH` is empty, the script prompts for a password **after** Docker is installed.

**Keep this root session open** until step 5 succeeds.

### Step 5 as deploy (verify SSH)

On your **local machine**, open a second terminal:

```bash
ssh -p 2222 deploy@your-vps-ip
```

Use the port and username from `setup.env`. Only when this works, close the root session.

### Step 6 as deploy (start containers)

On the **deploy** session (not root):

```bash
cd /opt/stacks/caddy && docker compose up -d
cd /opt/stacks/uptime-kuma && docker compose up -d
cd /opt/stacks/dozzle && docker compose up -d
cd /opt/stacks/dockge && docker compose up -d

docker ps
```

`deploy` has passwordless `sudo` for admin tasks (e.g. `sudo update-stacks`). Routine Docker commands do **not** need `sudo`.

### Step 7 — browser

Visit `https://kuma.<APPS_DOMAIN>`, `https://dozzle.<APPS_DOMAIN>`, `https://dockge.<APPS_DOMAIN>`. Use your Caddy basic auth user/password, then create the Uptime Kuma admin account.

---

## Who runs what (after initial setup)

| Task | User |
|------|------|
| `docker compose up/down`, `docker ps`, `docker logs` | **deploy** (docker group) |
| `git pull` in `/opt/caddy_reverse` | **deploy** (owns the repo after `setup_v2.sh`) |
| `sudo update-stacks` / `sudo bash scripts/install-stacks.sh` | **deploy** (writes `/opt/stacks`; needs sudo) |
| `setup_v2.sh` again | **root** only via provider console (root SSH is disabled) |

## Security model

This stack is designed for a **single-operator homelab VPS**, not multi-tenant hosting.

- **Caddy** is the only service bound to ports 80/443. Backends use Docker `expose`, not host `ports`.
- **Caddy basic auth** protects the edge for Kuma, Dozzle, and Dockge (one shared username/password in `setup.env`).
- **Uptime Kuma** still has its own admin login after the Caddy gate — two layers at the edge.
- **Dozzle** and **Dockge** mount `docker.sock`. Anyone who passes Caddy basic auth can control containers on the host. Treat the basic auth password like a root password.
- **Do not** publish real `setup.env`, bcrypt hashes, or SSH private keys. They stay on the server only (see `.gitignore`).

## Configuration (`setup.env`)

Secrets and host-specific values live in **`setup.env`** (gitignored), not in the scripts:

```bash
cp setup.env.example setup.env
nano setup.env
```

| Variable | When | Purpose |
|----------|------|---------|
| `APPS_DOMAIN` | Before `setup_v2.sh`; again on `update-stacks` | Base domain for apps, e.g. `apps.example.com` (wildcard `*.APPS_DOMAIN` → VPS) |
| `ACME_EMAIL` | Before `setup_v2.sh`; again on `update-stacks` | Let's Encrypt contact email |
| `CADDY_BASIC_AUTH_USER` | Before `setup_v2.sh`; again on `update-stacks` | Shared Caddy basic auth username |
| `SSH_PUBLIC_KEYS` | Before `setup_v2.sh` only | Public keys for `NEW_USER` (`~/.ssh/authorized_keys`); root SSH is disabled after setup |
| `NEW_USER`, `SSH_PORT`, `TIMEZONE` | Before `setup_v2.sh` only | Hardening options |
| `CADDY_BASIC_AUTH_HASH` | Optional before; prompted after Docker if empty; again on `update-stacks` | Shared Caddy basic auth password (bcrypt) |

Generate a bcrypt hash (on the VPS after Docker is installed, or on any machine with Docker):

```bash
docker run --rm caddy caddy hash-password
```

Paste the hash into `setup.env` **in single quotes** (bcrypt hashes contain `$`):

```bash
CADDY_BASIC_AUTH_HASH='$2a$14$...'
```

Or leave it empty — `setup_v2.sh` / `install-stacks.sh` will prompt after Docker is installed.

## Templates and updates

Committed templates are rendered on the server; generated files are not in git:

| In git | Generated on server |
|--------|---------------------|
| `stacks/caddy/Caddyfile.example` | `/opt/stacks/caddy/Caddyfile` |
| `stacks/dockge/.env.example` | `/opt/stacks/dockge/.env` (first install only) |

**As deploy**, after `git pull`:

```bash
cd /opt/caddy_reverse
git pull
sudo update-stacks
cd /opt/stacks/caddy && docker compose restart
```

## Prerequisites

1. **Ubuntu VPS 24.04 or newer** with **root** SSH (or provider console) for the initial `setup_v2.sh` run
2. **`setup.env`** filled from `setup.env.example` before `setup_v2.sh`
3. **Wildcard DNS** `*.<APPS_DOMAIN>` → your VPS public IP (e.g. `*.apps.example.com → 203.0.113.42`)
4. **Ports 80 and 443** open to the internet; after `setup_v2.sh`, allow `SSH_PORT` (default `2222`) in any cloud firewall

## Adding a new service

Stack folder name becomes the subdomain: `/opt/stacks/myapp` → `https://myapp.<APPS_DOMAIN>`.

### Bundled apps (in git)

Add a folder under `stacks/<name>/` with `compose.yml` and optional `caddy.env`, then commit and run `sudo update-stacks` on the server.

### Manual apps (server only)

1. Create the stack folder:

   ```bash
   deploy-app myapp
   # Edit /opt/stacks/myapp/compose.yml (image, container_name, expose port, caddy_net)
   cp /opt/stacks/_template/caddy.env.example /opt/stacks/myapp/caddy.env   # if missing
   ```

2. Regenerate Caddy and restart the proxy:

   ```bash
   sudo update-stacks
   cd /opt/stacks/caddy && docker compose restart
   ```

3. Start the app: `deploy-app myapp`

Wildcard DNS `*.<APPS_DOMAIN>` already covers new subdomains.

### `caddy.env` (optional per stack)

| Variable | Default | Purpose |
|----------|---------|---------|
| `SUBDOMAIN` | folder name | Hostname prefix (e.g. `kuma` for folder `uptime-kuma`) |
| `PORT` | first `expose` port in `compose.yml` | Backend port for `reverse_proxy` |
| `UPSTREAM` | `container_name` or folder name | Docker hostname on `caddy_net` |
| `BASIC_AUTH` | `true` | Set to `false` to skip Caddy basic auth |
| `COMMENT` | auto | Comment in the generated Caddyfile |

Site blocks are generated by `scripts/generate-caddyfile.sh` (via `install-stacks.sh`). Do not add vhosts to `Caddyfile.example` by hand.

## File structure

## File structure

```
caddy_reverse/
├── LICENSE
├── README.md
├── setup.env.example      ← copy to setup.env (not committed)
├── setup_v2.sh            ← run as root on a fresh VPS
├── lib/
│   ├── common.sh
│   └── setup-env.sh
├── scripts/
│   ├── install-stacks.sh       ← sudo; copy stacks + render Caddyfile
│   └── generate-caddyfile.sh   ← build site blocks from /opt/stacks/*
└── stacks/
    ├── caddy/
    │   ├── compose.yml
    │   └── Caddyfile.example
    ├── _template/
    │   └── caddy.env.example
    ├── uptime-kuma/
    │   ├── compose.yml
    │   └── caddy.env
    ├── dozzle/
    └── dockge/
        └── .env.example
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `command not found: git` before setup | `apt-get update && apt-get install -y git` as root, then clone |
| `command not found: nano` | Run `setup_v2.sh` (installs nano) or use `vim` / edit locally and `scp` |
| `envsubst: command not found` | `apt-get install -y gettext-base` (included in `setup_v2.sh`) |
| `502 Bad Gateway` | Backend not running — `docker ps`, `docker logs <name>`. |
| TLS errors | DNS and port 80 reachable — `docker logs caddy`. |
| Caddy won't start | Caddyfile syntax — `docker logs caddy`; `sudo update-stacks`. |
| Prompt for password on every install | Save `CADDY_BASIC_AUTH_HASH='...'` in `setup.env`. |
| Locked out after `setup_v2.sh` | Provider console; restore SSH from `.bak.*` or remove `sshd_config.d/99-hardened.conf`. |
| `SSH_PORT` closed, port 22 filtered (Ubuntu 24.04) | `sshd_config` can say `Port 2222` while `ssh.socket` still listens on 22 — on the server: `systemctl restart ssh.socket ssh` (current `setup_v2.sh` configures the socket automatically). |
| `cd /root/caddy_reverse: Permission denied` as deploy | `/root` is not traversable by non-root — use `/opt/caddy_reverse` (see README) or on the server: `sudo mv /root/caddy_reverse /opt/caddy_reverse && sudo chown -R deploy:deploy /opt/caddy_reverse`, then fix `update-stacks` path if needed. |
| `permission denied` on docker | Use **deploy** (created by `setup_v2.sh`; in the `docker` group). |

## License

MIT — see [LICENSE](LICENSE).
