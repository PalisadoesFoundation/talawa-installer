# Talawa Installer

A single interactive script that sets up a complete Talawa development environment from scratch. It handles Nix verification, repository cloning, database provisioning (via Schematic), service startup, dependency installation, and environment configuration so you can go from a bare machine to running servers in one pass.

## Goals

- **One command to get started.** A new contributor should be able to run `./install.sh` and end up with a working Talawa stack without reading multiple READMEs or running dozens of manual steps.
- **Flexible component selection.** Not everyone needs every piece. The installer lets you choose Admin + API, Mobile + API, or all three.
- **Self-contained.** All Nix files needed for installation (`default.nix`, `flake.nix`, `flake.lock`) are bundled inside this folder. No external Nix configuration is required.
- **Respect previous state.** If repositories or Schematic files already exist, the installer asks before overwriting them.

## Prerequisites

- **macOS or Linux**
- **Git**
- **Nix** — the installer checks for this first and tells you how to install it if it's missing

## Usage

```bash
cd Talawa-Installer
./install.sh
```

## What the installer does

### 1. Nix check

Verifies that `nix` is on your PATH. If not, it prints the install command and exits:

```
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon
```

### 2. Component selection

Prompts you to choose what to install:

1. **Talawa-Admin + Talawa-API** — web admin portal and backend
2. **Talawa-Mobile + Talawa-API** — Flutter mobile app and backend
3. **All three**

The API is always included because both frontends depend on it.

### 3. Repository check

For each selected component, the installer looks for the corresponding repository in the parent directory (`talawa-api/`, `talawa-admin/`, `talawa/`). If a repo is missing, it offers to `git clone` it from the Palisadoes Foundation GitHub.

### 4. Schematic + database setup (API/Admin path)

[Schematic](https://gitlab.com/deltaex/schematic) is a Nix-based PostgreSQL manager used to provision the database.

- If `schematic-master/` already exists, the installer asks whether to keep it or re-clone.
- It looks for an existing server definition under `schematic-master/srv/`. If one is found, it runs `scm upgrade` and `scm start` via `nix develop` to bring the database up.
- If no server exists, it creates a new one and starts it.

### 5. Services and environment (API/Admin path)

The installer enters the root `default.nix` via `nix-shell`, which:

- Starts **PostgreSQL** (or detects the Schematic-managed instance already running)
- Starts **Redis** and **MinIO** as background daemons
- Writes `.env` files for `talawa-api/` and `talawa-admin/` if they don't already exist
- Runs `pnpm install` in both packages
- Applies Drizzle database migrations for the API

### 6. Mobile setup

If Talawa-Mobile was selected, the installer asks whether you want to develop with:

1. **An Android emulator** — downloads the full SDK with system images (~10 GB) via `nix develop`
2. **A physical device** — uses `nix develop .#physical` for a leaner SDK (~6 GB)

Either path sets up Flutter, the Android SDK, and Java, then runs `flutter pub get` in the mobile repo.

### 7. Auto-starting the development servers

Once dependencies are installed, the installer drops you directly into an interactive `nix-shell` with the dev servers already running in the background:

- **Talawa-API** is started with `pnpm run start_development_server` — output streamed to `.local/api.log`
- **Talawa-Admin** is started with `pnpm run serve` — output streamed to `.local/admin.log`

You stay in the shell so you can tail the logs, run `pnpm` commands, or interact with the database directly. The installer's shell summary shows the URLs:

```
API:    http://127.0.0.1:4000    (log: .local/api.log)
Admin:  http://localhost:4321     (log: .local/admin.log)
```

To watch the servers as they come up:

```bash
tail -f .local/api.log
tail -f .local/admin.log
```

#### Mobile in a separate terminal

The mobile environment uses a different Nix flake (for Flutter + Android SDK), so it can't share the same shell. If you selected mobile, open a second terminal and run:

```bash
cd Talawa-Installer
nix develop                  # or: nix develop .#physical
cd talawa && flutter run
```

#### Re-entering later

The autostart only fires once (on the initial install). On subsequent runs, just enter `nix-shell` from the installer directory — PostgreSQL, Redis, and MinIO will come back up, but the API and Admin dev servers are left to you:

```bash
cd Talawa-Installer
nix-shell
# then in separate terminals:
cd talawa-api && pnpm run start_development_server
cd talawa-admin && pnpm run serve
```

## Default credentials

After installation, the API is pre-configured with:

| Field    | Value                          |
|----------|--------------------------------|
| Email    | `administrator@example.com`    |
| Password | `password`                     |

## Project layout

```
Talawa-Installer/            # Everything needed to install Talawa
  install.sh                 # Interactive installer script
  default.nix                # Nix shell — starts PG, Redis, MinIO
  flake.nix                  # Flutter + Android SDK environments
  flake.lock                 # Pinned flake dependencies
  README.md                  # This file

  # Cloned into this directory during installation:
  talawa-api/                # GraphQL API backend
  talawa-admin/              # React web admin portal
  talawa/                    # Flutter mobile app
  schematic-master/          # Schematic PostgreSQL manager
```
