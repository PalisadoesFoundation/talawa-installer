##############################################################################
# Talawa development shell — `nix-shell` (legacy Nix, not a flake)
#
# QUICK START
#   nix-shell            # enters shell, auto-starts all services
#   cd talawa-api  && pnpm run start_development_server
#   cd talawa-admin && pnpm run serve
#
# WHAT THIS SHELL PROVIDES
#   • Node.js 24, pnpm, git, redis, minio, curl
#   • A PostgreSQL instance managed by nixpkgs (not Schematic)
#   • Auto-initialises the database cluster on first run
#   • Auto-starts PostgreSQL, Redis, and MinIO as background daemons
#   • Writes .env files for both talawa-api and talawa-admin if absent
#
# ── SCHEMATIC NOTE ──────────────────────────────────────────────────────────
#
# Schematic is a separate Nix *flake* (`nix develop`) and cannot be embedded
# inside this `nix-shell` invocation — they are fundamentally different
# mechanisms and run in isolated Nix evaluation contexts.
#
# Two options:
#
#   Option A — use this shell's built-in PostgreSQL (default, no extra steps)
#     Just run `nix-shell` as usual.  A self-contained PostgreSQL cluster is
#     created under .local/pg/ inside this repository root.
#
#   Option B — use a Schematic-managed PostgreSQL instead
#     1. Initialise your Schematic server once (outside this shell):
#          cd schematic-master
#          nix develop --command bash -c 'scm upgrade srv/<your-server-dir> -n'
#          cd ..
#     2. Start that PostgreSQL instance (outside this shell):
#          cd schematic-master
#          nix develop --command bash -c 'scm start srv/<your-server-dir>'
#          cd ..
#     3. Edit the `pg*` variables below to match the port/user/password/dbname
#        that Schematic assigned to your cluster.
#     4. Run `nix-shell` — the shellHook will detect PostgreSQL already
#        listening on pgPort and skip its own startup entirely.
#
##############################################################################

{ pkgs ? import <nixpkgs> {} }:

let
  # ── PostgreSQL configuration ───────────────────────────────────────────────
  # Change these values to match your Schematic cluster (Option B above),
  # or leave them as-is for the built-in nixpkgs PostgreSQL (Option A).
  pgPort     = "55303";
  pgUser     = "root";
  pgPassword = "P9awGuzEajcnd9Kzhz";
  pgDatabase = "talawa";

  # ── Redis configuration ────────────────────────────────────────────────────
  redisPort = "6379";

  # ── MinIO configuration ────────────────────────────────────────────────────
  minioPort        = "9000";
  minioConsolePort = "9001";
  minioUser        = "talawa";
  minioPassword    = "password";

  # ── API configuration ──────────────────────────────────────────────────────
  apiPort     = "4000";
  adminPort   = "4321";
  apiBaseUrl  = "http://127.0.0.1:${apiPort}";
  frontendUrl = "http://localhost:${adminPort}";
in

pkgs.mkShell {
  name = "talawa-dev-shell";

  buildInputs = with pkgs; [
    nodejs_24        # ≥24.x required by admin; 24.12.0 required by API
    pnpm             # version enforced via packageManager field in each package.json
    git
    redis
    minio
    curl             # used for MinIO health check
    postgresql       # nixpkgs PostgreSQL — only used if Option A (see above)
    python3          # required for pre-commit hooks (translation checks, CSS checks)
    python3Packages.pip
    python3Packages.virtualenv
  ];

  shellHook = ''
    # ── pnpm global bin on PATH ────────────────────────────────────────────────
    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"

    TALAWA_ROOT="$(pwd)"

    # ── Data / log directories ─────────────────────────────────────────────────
    mkdir -p \
      "$TALAWA_ROOT/.local/redis-data" \
      "$TALAWA_ROOT/.local/minio-data" \
      "$TALAWA_ROOT/.local/pg/data"

    # ── PostgreSQL ─────────────────────────────────────────────────────────────
    # If PostgreSQL is already accepting connections on ${pgPort} (e.g. a
    # Schematic-managed cluster you started externally per Option B), skip
    # everything below and use it as-is.

    if pg_isready -q -h 127.0.0.1 -p ${pgPort} 2>/dev/null; then
      echo "→ PostgreSQL already running on port ${pgPort} — skipping built-in startup."
    else
      PG_DATA="$TALAWA_ROOT/.local/pg/data"
      PG_LOG="$TALAWA_ROOT/.local/pg.log"

      # Initialise the cluster on first run
      if [ ! -f "$PG_DATA/PG_VERSION" ]; then
        echo "→ Initialising PostgreSQL cluster in $PG_DATA..."
        initdb -D "$PG_DATA" --username="${pgUser}" --pwfile=<(echo "${pgPassword}") -A md5 \
          > "$TALAWA_ROOT/.local/pg-initdb.log" 2>&1
        # Allow TCP connections
        echo "host all all 127.0.0.1/32 md5" >> "$PG_DATA/pg_hba.conf"
        echo "listen_addresses = '127.0.0.1'" >> "$PG_DATA/postgresql.conf"
        echo "port = ${pgPort}" >> "$PG_DATA/postgresql.conf"
        echo "unix_socket_directories = '$PG_DATA'" >> "$PG_DATA/postgresql.conf"
      fi

      # Start the cluster
      if ! pg_ctl status -D "$PG_DATA" > /dev/null 2>&1; then
        echo "→ Starting PostgreSQL..."
        pg_ctl start -D "$PG_DATA" -l "$PG_LOG" -w -s
      fi

      # Verify PostgreSQL is accepting connections
      if ! pg_isready -q -h 127.0.0.1 -p ${pgPort}; then
        echo "FATAL: PostgreSQL failed to start. See $PG_LOG" >&2
        exit 1
      fi

      # Create the application database on first run
      if ! PGPASSWORD="${pgPassword}" psql -h 127.0.0.1 -p ${pgPort} -U "${pgUser}" -lqt \
            2>/dev/null \
          | cut -d '|' -f1 | grep -qw "${pgDatabase}"; then
        echo "→ Creating database '${pgDatabase}'..."
        PGPASSWORD="${pgPassword}" createdb \
          -h 127.0.0.1 -p ${pgPort} -U "${pgUser}" "${pgDatabase}"
      fi
    fi

    # ── Redis ──────────────────────────────────────────────────────────────────
    if ! redis-cli -p ${redisPort} ping > /dev/null 2>&1; then
      echo "→ Starting Redis..."
      redis-server --port ${redisPort} --daemonize yes \
        --dir "$TALAWA_ROOT/.local/redis-data" \
        --pidfile "$TALAWA_ROOT/.local/redis.pid" \
        --logfile "$TALAWA_ROOT/.local/redis.log"
    fi

    # ── MinIO ──────────────────────────────────────────────────────────────────
    if ! curl -sf "http://127.0.0.1:${minioPort}/minio/health/live" > /dev/null 2>&1; then
      echo "→ Starting MinIO..."
      MINIO_ROOT_USER=${minioUser} MINIO_ROOT_PASSWORD=${minioPassword} \
        minio server "$TALAWA_ROOT/.local/minio-data" \
          --address ':${minioPort}' \
          --console-address ':${minioConsolePort}' \
          > "$TALAWA_ROOT/.local/minio.log" 2>&1 &
      echo $! > "$TALAWA_ROOT/.local/minio.pid"
      # Wait until MinIO is accepting connections (up to ~5 s)
      for i in 1 2 3 4 5; do
        sleep 1
        curl -sf "http://127.0.0.1:${minioPort}/minio/health/live" > /dev/null 2>&1 && break
      done
    fi

    # ── talawa-api/.env ────────────────────────────────────────────────────────
    if [ ! -f "$TALAWA_ROOT/talawa-api/.env" ]; then
      echo "→ Writing talawa-api/.env..."
      cat > "$TALAWA_ROOT/talawa-api/.env" << APIENV
API_ENABLE_EMAIL_QUEUE=false
API_ADMINISTRATOR_USER_EMAIL_ADDRESS=administrator@example.com
API_ADMINISTRATOR_USER_NAME=administrator
API_ADMINISTRATOR_USER_PASSWORD=Password1!
API_BASE_URL=${apiBaseUrl}
API_COMMUNITY_FACEBOOK_URL=https://facebook.com
API_COMMUNITY_GITHUB_URL=https://github.com
API_COMMUNITY_INACTIVITY_TIMEOUT_DURATION=900
API_COMMUNITY_INSTAGRAM_URL=https://instagram.com
API_COMMUNITY_LINKEDIN_URL=https://linkedin.com
API_COMMUNITY_NAME=talawa
API_COMMUNITY_REDDIT_URL=https://reddit.com
API_COMMUNITY_SLACK_URL=https://slack.com
API_COMMUNITY_WEBSITE_URL=https://docs.talawa.com
API_COMMUNITY_X_URL=https://x.com
API_COMMUNITY_YOUTUBE_URL=https://youtube.com
API_HOST=0.0.0.0
API_IS_APPLY_DRIZZLE_MIGRATIONS=true
API_IS_GRAPHIQL=true
API_IS_PINO_PRETTY=true
API_JWT_EXPIRES_IN=900000
API_REFRESH_TOKEN_EXPIRES_IN=604800000
API_JWT_SECRET=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2
API_COOKIE_SECRET=b4896453be722d5ca94058a73f52b31c75980b485fa6d74d91f417a8059d8731
API_LOG_LEVEL=info
API_MINIO_ACCESS_KEY=${minioUser}
API_MINIO_END_POINT=127.0.0.1
API_MINIO_PORT=${minioPort}
API_MINIO_SECRET_KEY=${minioPassword}
API_MINIO_USE_SSL=false
API_MINIO_PUBLIC_BASE_URL=http://localhost:${minioPort}
API_PORT=${apiPort}
API_POSTGRES_DATABASE=${pgDatabase}
API_POSTGRES_HOST=127.0.0.1
API_POSTGRES_PASSWORD=${pgPassword}
API_POSTGRES_PORT=${pgPort}
API_POSTGRES_SSL_MODE=false
API_POSTGRES_USER=${pgUser}
API_REDIS_HOST=127.0.0.1
API_REDIS_PORT=${redisPort}
API_GRAPHQL_SCALAR_FIELD_COST=0
API_GRAPHQL_SCALAR_RESOLVER_FIELD_COST=1
API_GRAPHQL_OBJECT_FIELD_COST=1
API_GRAPHQL_LIST_FIELD_COST=1
API_GRAPHQL_NON_PAGINATED_LIST_FIELD_COST=5
API_GRAPHQL_MUTATION_BASE_COST=10
API_GRAPHQL_SUBSCRIPTION_BASE_COST=15
API_RATE_LIMIT_BUCKET_CAPACITY=10000
API_RATE_LIMIT_REFILL_RATE=100
API_OTEL_ENABLED=false
API_FRONTEND_URL=${frontendUrl}
API_EMAIL_PROVIDER=mailpit
API_SMTP_HOST=127.0.0.1
API_SMTP_PORT=1025
API_SMTP_FROM_EMAIL=test@talawa.local
API_SMTP_FROM_NAME=Talawa
MINIO_ROOT_USER=${minioUser}
MINIO_ROOT_PASSWORD=${minioPassword}
APIENV
    fi

    # ── talawa-admin/.env ──────────────────────────────────────────────────────
    if [ ! -f "$TALAWA_ROOT/talawa-admin/.env" ]; then
      echo "→ Writing talawa-admin/.env..."
      cat > "$TALAWA_ROOT/talawa-admin/.env" << ADMINENV
PORT=${adminPort}
REACT_APP_TALAWA_URL=${apiBaseUrl}/graphql
REACT_APP_USE_RECAPTCHA=
REACT_APP_RECAPTCHA_SITE_KEY=
ALLOW_LOGS=
ADMINENV
    fi

    # ── Summary ────────────────────────────────────────────────────────────────
    echo ""
    echo "Talawa development environment ready"
    echo "  PostgreSQL  localhost:${pgPort}  (user: ${pgUser}, db: ${pgDatabase})"
    echo "  Redis       localhost:${redisPort}"
    echo "  MinIO       localhost:${minioPort}   (console: http://localhost:${minioConsolePort}, user: ${minioUser})"
    echo ""
    echo "  Start API:    cd talawa-api && pnpm run start_development_server"
    echo "  Start Admin:  cd talawa-admin && pnpm run serve"
    echo ""
    echo "  Login:  administrator@example.com / Password1!"
    echo ""
  '';
}
