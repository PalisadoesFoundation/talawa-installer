# Talawa Installer — Bug Report

Issues discovered during a full test run of `./install.sh` with option 3
(Admin + API + Mobile) and option 1 (emulated Android device) on Linux x86_64,
Nix 2.31.3.

---

## Critical — Installation fails to produce a working environment

### BUG-1: PostgreSQL fails to start (missing Unix socket directory)

**File:** `default.nix`, lines 112–126 (shellHook)

**Symptom:**
```
pg_ctl: could not start server
```
```
FATAL: could not create lock file "/run/postgresql/.s.PGSQL.55303.lock": No such file or directory
```

**Root cause:**
`initdb` and `pg_ctl` default to creating a Unix-domain socket in
`/run/postgresql/`, which does not exist (or is not writable) for regular
users. The shellHook configures `listen_addresses` and `port` in
`postgresql.conf` but never sets `unix_socket_directories`.

**Impact:** PostgreSQL never starts, so the database cannot be created,
migrations cannot run, and the API cannot connect. This is the single
biggest blocker — everything downstream depends on it.

**Proposed fix (default.nix, inside the `initdb` block around line 119):**
```diff
  echo "listen_addresses = '127.0.0.1'" >> "$PG_DATA/postgresql.conf"
  echo "port = ${pgPort}" >> "$PG_DATA/postgresql.conf"
+ echo "unix_socket_directories = '$PG_DATA'" >> "$PG_DATA/postgresql.conf"
```

---

### BUG-2: Database creation fails (cascading from BUG-1)

**File:** `default.nix`, lines 129–136

**Symptom:**
```
createdb: error: connection to server at "127.0.0.1", port 55303 failed: Connection refused
```

**Root cause:** PostgreSQL is not running (BUG-1).

**Resolution:** Fixing BUG-1 resolves this.

---

### BUG-3: Database migrations fail (cascading from BUG-1)

**File:** `install.sh`, line 248 (`pnpm run apply_drizzle_migrations`)

**Symptom:**
```
DrizzleQueryError: Failed query: CREATE SCHEMA IF NOT EXISTS "drizzle"
  cause: Error: connect ECONNREFUSED 127.0.0.1:55303
```

**Root cause:** PostgreSQL is not running (BUG-1).

**Resolution:** Fixing BUG-1 resolves this.

---

### BUG-4: Schematic server template uses a nonexistent `lib.database` function

**File:** `install.sh`, lines 186–195

**Symptom:**
```
error: attribute 'database' missing
  at .../srv/talawa/default.nix:3:1
```

**Root cause:**
The installer generates `srv/talawa/default.nix` containing:
```nix
lib.database {
  name = "talawa";
  ...
}
```
But the Schematic repository's `lib` does not expose a `database` attribute.
The template was likely written against a different version of Schematic or
uses an incorrect API.

**Impact:** `scm upgrade srv/talawa -n` fails. The installer catches the
error and falls back to the built-in PostgreSQL, which also fails (BUG-1).
If BUG-1 is fixed this becomes non-blocking, but the Schematic integration
is dead code until the template is corrected.

**Proposed fix:** Inspect the actual Schematic API (look at existing example
servers in `schematic-master/srv/`) and update the generated `default.nix`
to match the real interface. Alternatively, remove the Schematic code path
entirely if it is not needed and rely solely on the built-in PostgreSQL.

---

## Bugs — Incorrect behavior

### BUG-5: Login credentials shown at the end do not match the `.env` file

**Files:** `install.sh` line 420, `default.nix` line 171

**Symptom:**
The final summary printed by the installer says:
```
Login credentials (API):
  Email:    administrator@example.com
  Password: password
```
But the generated `talawa-api/.env` contains:
```
API_ADMINISTRATOR_USER_PASSWORD=Password1!
```

**Impact:** Users who follow the on-screen instructions will fail to log in.

**Proposed fix (install.sh, line 420):**
```diff
- echo "    Password: password"
+ echo "    Password: Password1!"
```

---

### BUG-6: Script exits 0 and prints "Installation Complete!" despite critical failures

**File:** `install.sh`, line 14 (`set -euo pipefail`) and lines 237–263

**Root cause:**
- PostgreSQL startup failure occurs inside a nix-shell `shellHook`, which
  does not propagate its exit status to the calling process.
- The migration failure is masked by
  `pnpm run apply_drizzle_migrations || echo 'Migration warning: ...'`.

**Impact:** The user sees a success message and has no idea the database is
broken until they try to start the API.

**Proposed fix:**
1. In the `shellHook`, add explicit health checks after starting PostgreSQL
   and fail loudly:
   ```bash
   if ! pg_isready -q -h 127.0.0.1 -p ${pgPort}; then
     echo "FATAL: PostgreSQL failed to start. See $PG_LOG" >&2
     exit 1
   fi
   ```
2. In `install.sh`, do not swallow the migration exit code:
   ```diff
   - pnpm run apply_drizzle_migrations || echo 'Migration warning: check output above'
   + pnpm run apply_drizzle_migrations
   ```
   Or at minimum, capture and propagate the failure to the top-level script.

---

### BUG-7: `psql` database-existence check uses `--no-password` with `md5` auth

**File:** `default.nix`, lines 129–132

**Code:**
```bash
psql -h 127.0.0.1 -p ${pgPort} -U "${pgUser}" -lqt --no-password ...
```

**Root cause:** `initdb` is invoked with `-A md5`, so all TCP connections
require a password. But the `psql` check uses `--no-password`, which tells
psql to never prompt for (or send) a password. The check will always fail
even when PostgreSQL is running.

**Proposed fix:**
```diff
- if ! psql -h 127.0.0.1 -p ${pgPort} -U "${pgUser}" -lqt \
-       --no-password \
+ if ! PGPASSWORD="${pgPassword}" psql -h 127.0.0.1 -p ${pgPort} -U "${pgUser}" -lqt \
```

---

### BUG-8: Flutter version display shows raw JSON instead of a version string

**File:** `flake.nix`, line 96

**Code:**
```bash
echo "  Flutter:     $(flutter --version --machine 2>/dev/null | head -1 || echo 'available')"
```

**Symptom:** The shell banner prints:
```
Flutter:     {
```
because `--machine` outputs JSON and `head -1` grabs only the opening brace.

**Proposed fix:**
```diff
- echo "  Flutter:     $(flutter --version --machine 2>/dev/null | head -1 || echo 'available')"
+ echo "  Flutter:     $(flutter --version 2>/dev/null | head -1 || echo 'available')"
```

---

## Warnings — Non-critical

### WARN-1: Schematic git URL triggers a redirect

**File:** `install.sh`, line 23

```
REPO_SCHEMATIC="https://gitlab.com/deltaex/schematic"
```
Git prints: `warning: redirecting to https://gitlab.com/deltaex/schematic.git/`

**Fix:** Append `.git` to the URL.

---

### WARN-2: Node.js version mismatch

Nix provides Node.js v24.13.0; `talawa-api` wants exactly `24.12.0`:
```
WARN  Unsupported engine: wanted: {"node":"24.12.0"} (current: {"node":"v24.13.0"})
```
Consider pinning `nodejs_24` to a specific nixpkgs commit that provides
24.12.0, or relaxing the engine constraint in `talawa-api/package.json`.

---

### WARN-3: pnpm build scripts skipped for several packages

```
Ignored build scripts: @swc/core, esbuild (×3), lefthook, protobufjs
Run "pnpm approve-builds" to pick which dependencies should be allowed to run scripts.
```
These packages may not function correctly at runtime until their build
scripts are approved and executed.

---

## Summary table

| ID     | Severity | Component         | One-line summary                                      |
|--------|----------|-------------------|-------------------------------------------------------|
| BUG-1  | Critical | `default.nix`     | PostgreSQL can't start — no unix_socket_directories    |
| BUG-2  | Critical | `default.nix`     | `createdb` fails (cascading from BUG-1)               |
| BUG-3  | Critical | `install.sh`      | Drizzle migrations fail (cascading from BUG-1)        |
| BUG-4  | Critical | `install.sh`      | Schematic template uses nonexistent `lib.database`    |
| BUG-5  | Bug      | `install.sh`      | Displayed password doesn't match `.env` password      |
| BUG-6  | Bug      | `install.sh`      | Script reports success despite critical failures      |
| BUG-7  | Bug      | `default.nix`     | `psql` check will fail under md5 auth                 |
| BUG-8  | Bug      | `flake.nix`       | Flutter version shows `{` instead of version string   |
| WARN-1 | Warning  | `install.sh`      | Schematic repo URL causes git redirect warning        |
| WARN-2 | Warning  | `default.nix`     | Node.js version mismatch (24.13 vs required 24.12)    |
| WARN-3 | Warning  | `install.sh`      | pnpm build scripts skipped for several packages       |
