#!/usr/bin/env bash
###############################################################################
# Talawa Installer
#
# Simplifies the installation process for the different Talawa components.
# Supports installing any combination of:
#   - Talawa-Admin (React web admin portal)
#   - Talawa-API   (GraphQL API backend)
#   - Talawa-Mobile (Flutter mobile app)
#
# Prerequisites: Nix package manager
###############################################################################

set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$INSTALLER_DIR")"

# Repository URLs
REPO_API="https://github.com/PalisadoesFoundation/talawa-api"
REPO_ADMIN="https://github.com/PalisadoesFoundation/talawa-admin"
REPO_MOBILE="https://github.com/PalisadoesFoundation/talawa"
REPO_SCHEMATIC="https://gitlab.com/deltaex/schematic.git"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}$*${NC}\n"; }

###############################################################################
# 1. Check for Nix
###############################################################################
check_nix() {
  header "Checking for Nix..."

  if command -v nix &>/dev/null; then
    success "Nix is installed: $(nix --version)"
  else
    error "Nix is not installed on this machine."
    echo ""
    echo "Please install Nix by running the following command in your terminal:"
    echo ""
    echo -e "  ${BOLD}sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --no-daemon${NC}"
    echo ""
    echo "After installing Nix, restart your terminal and re-run this installer."
    exit 1
  fi
}

###############################################################################
# 2. Prompt for installation option
###############################################################################
prompt_option() {
  header "What would you like to install?"

  echo "  1) Talawa-Admin and Talawa-API"
  echo "  2) Talawa-Mobile and Talawa-API"
  echo "  3) Talawa-Admin, Talawa-API, and Talawa-Mobile"
  echo ""

  while true; do
    read -rp "Enter your choice [1/2/3]: " CHOICE
    case "$CHOICE" in
      1) INSTALL_ADMIN=true;  INSTALL_API=true;  INSTALL_MOBILE=false; break ;;
      2) INSTALL_ADMIN=false; INSTALL_API=true;  INSTALL_MOBILE=true;  break ;;
      3) INSTALL_ADMIN=true;  INSTALL_API=true;  INSTALL_MOBILE=true;  break ;;
      *) warn "Invalid choice. Please enter 1, 2, or 3." ;;
    esac
  done
}

###############################################################################
# 3. Ensure repositories are cloned
###############################################################################
ensure_repo() {
  local name="$1"
  local url="$2"
  local dir="$3"

  if [ -d "$dir" ] && [ -d "$dir/.git" ]; then
    success "$name already cloned at $dir"
  elif [ -d "$dir" ] && [ ! -d "$dir/.git" ]; then
    # Directory exists but is not a git repo — could be a plain copy
    warn "$name directory exists at $dir but is not a git repository."
    read -rp "  Continue using it anyway? [y/N]: " USE_EXISTING
    if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
      error "Please remove or rename $dir and re-run the installer."
      exit 1
    fi
  else
    echo ""
    info "$name is not found in the installer directory."
    echo "  Please clone it by running:"
    echo ""
    echo -e "  ${BOLD}git clone $url $dir${NC}"
    echo ""
    read -rp "  Would you like me to clone it now? [Y/n]: " DO_CLONE
    if [[ "$DO_CLONE" =~ ^[Nn]$ ]]; then
      error "Cannot proceed without $name. Please clone it and re-run."
      exit 1
    fi
    info "Cloning $name..."
    git clone "$url" "$dir"
    success "$name cloned successfully."
  fi
}

check_repos() {
  header "Checking required repositories..."

  if [ "$INSTALL_API" = true ]; then
    ensure_repo "Talawa-API" "$REPO_API" "$INSTALLER_DIR/talawa-api"
  fi
  if [ "$INSTALL_ADMIN" = true ]; then
    ensure_repo "Talawa-Admin" "$REPO_ADMIN" "$INSTALLER_DIR/talawa-admin"
  fi
  if [ "$INSTALL_MOBILE" = true ]; then
    ensure_repo "Talawa-Mobile" "$REPO_MOBILE" "$INSTALLER_DIR/talawa"
  fi
}

###############################################################################
# 4. Schematic setup (for PostgreSQL)
###############################################################################
setup_schematic() {
  header "Setting up Schematic (PostgreSQL manager)..."

  local SCHEMATIC_DIR="$INSTALLER_DIR/schematic-master"

  if [ -d "$SCHEMATIC_DIR" ]; then
    success "Schematic directory found at $SCHEMATIC_DIR"
    echo ""
    read -rp "  Schematic files already exist. Keep them from the previous run? [Y/n]: " KEEP_SCHEMATIC
    if [[ "$KEEP_SCHEMATIC" =~ ^[Nn]$ ]]; then
      warn "Removing existing schematic-master directory..."
      rm -rf "$SCHEMATIC_DIR"
      info "Cloning Schematic..."
      git clone "$REPO_SCHEMATIC" "$SCHEMATIC_DIR"
      success "Schematic cloned fresh."
    else
      success "Keeping existing Schematic files."
    fi
  else
    info "Cloning Schematic..."
    git clone "$REPO_SCHEMATIC" "$SCHEMATIC_DIR"
    success "Schematic cloned."
  fi

  # Initialize Schematic and start the database
  info "Initializing Schematic PostgreSQL environment..."
  info "Running 'nix develop' in schematic-master to set up the database..."

  # Look specifically for a Talawa server definition — ignore any bundled
  # example/demo servers that ship with the Schematic repository (e.g. world-*).
  local TALAWA_SRV="$SCHEMATIC_DIR/srv/talawa"

  if [ -d "$TALAWA_SRV" ] && [ -f "$TALAWA_SRV/default.nix" ]; then
    info "Found existing Talawa server definition at srv/talawa"

    # Upgrade and start the server
    info "Upgrading and starting Schematic server 'talawa'..."
    (
      cd "$SCHEMATIC_DIR"
      nix develop --command bash -c "scm upgrade srv/talawa -n" 2>&1 || {
        warn "Schematic upgrade returned non-zero; continuing anyway..."
      }
      nix develop --command bash -c "scm start srv/talawa" 2>&1 || {
        warn "Schematic start returned non-zero; the DB may already be running."
      }
    )
  else
    # Create a new Schematic server for Talawa
    info "No Talawa server definition found. Creating srv/talawa..."
    (
      cd "$SCHEMATIC_DIR"
      mkdir -p srv/talawa
      cat > srv/talawa/default.nix << 'SRVNIX'
stdargs @ { scm, pkgs, ... }:

scm.database rec {
    guid = "D0TALAWA00DBGUID";
    name = "talawa";
    server = scm.server rec {
        postgresql = pkgs.postgresql_18;
        guid = "S0TALAWA00SRVGID";
        name = "talawa";
        dbname = "talawa";
        port = "55303";
        user = "root";
        password = "P9awGuzEajcnd9Kzhz";
    };
    dependencies = [];
}
SRVNIX
      info "Upgrading Schematic server 'talawa'..."
      nix develop --command bash -c "scm upgrade srv/talawa -n" 2>&1 || {
        warn "Schematic upgrade had issues; will fall back to built-in PostgreSQL."
      }
      info "Starting Schematic server 'talawa'..."
      nix develop --command bash -c "scm start srv/talawa" 2>&1 || {
        warn "Schematic start had issues; will fall back to built-in PostgreSQL."
      }
    )
  fi

  success "Schematic database setup complete."
}

###############################################################################
# 5. Set up Talawa-API and Talawa-Admin via nix-shell (default.nix)
###############################################################################
setup_api_and_admin() {
  header "Setting up Talawa-API and Talawa-Admin..."

  # First, handle Schematic for the database
  setup_schematic

  # Now run the main default.nix which starts PostgreSQL (or uses Schematic's),
  # Redis, MinIO, and writes .env files
  info "Entering Nix shell to start all services (PostgreSQL, Redis, MinIO)..."
  info "This will also generate .env files for talawa-api and talawa-admin if they don't exist."
  echo ""

  local DEFAULT_NIX="$INSTALLER_DIR/default.nix"
  if [ ! -f "$DEFAULT_NIX" ]; then
    error "default.nix not found at $DEFAULT_NIX"
    error "Cannot set up the development environment without it."
    exit 1
  fi

  # Run the nix-shell using the installer's own default.nix from the installer
  # directory where the repos are cloned.
  (
    cd "$INSTALLER_DIR"
    nix-shell "$DEFAULT_NIX" --run "
      echo ''
      echo '--- Installing dependencies ---'
      echo ''

      # Install API dependencies
      if [ -d talawa-api ]; then
        echo '=> Installing talawa-api dependencies...'
        cd talawa-api
        pnpm install
        echo '=> Running database migrations...'
        pnpm run apply_drizzle_migrations
        cd ..
        echo ''
      fi

      # Install Admin dependencies
      if [ -d talawa-admin ]; then
        echo '=> Installing talawa-admin dependencies...'
        cd talawa-admin
        pnpm install
        cd ..
        echo ''
      fi

      echo '--- Setup complete ---'
    "
  )

  success "Talawa-API and Talawa-Admin dependencies installed."
}

###############################################################################
# 6. Set up Talawa-Mobile
###############################################################################
setup_mobile() {
  header "Setting up Talawa-Mobile..."

  # The flake.nix and flake.lock for the mobile environment live inside this
  # installer directory — no external android-emulator/ folder needed.
  local FLAKE_DIR="$INSTALLER_DIR"

  if [ ! -f "$FLAKE_DIR/flake.nix" ]; then
    error "flake.nix not found at $FLAKE_DIR"
    error "Cannot set up the mobile environment without it."
    exit 1
  fi

  echo "  How would you like to do mobile development?"
  echo ""
  echo "  1) With an Android emulator (downloads ~10 GB of SDK + system images)"
  echo "  2) With a physical device (leaner SDK, ~6 GB)"
  echo ""

  local MOBILE_MODE
  while true; do
    read -rp "  Enter your choice [1/2]: " MOBILE_CHOICE
    case "$MOBILE_CHOICE" in
      1) MOBILE_MODE="default"; break ;;
      2) MOBILE_MODE="physical"; break ;;
      *) warn "Invalid choice. Please enter 1 or 2." ;;
    esac
  done

  info "Setting up Flutter + Android SDK environment ($MOBILE_MODE mode)..."
  echo ""
  info "This may take a while on first run as Nix downloads the Android SDK..."
  echo ""

  (
    cd "$FLAKE_DIR"

    if [ "$MOBILE_MODE" = "default" ]; then
      # Full emulator setup
      nix develop --command bash -c "
        echo ''
        echo '--- Mobile environment ready ---'
        echo ''

        # Install Flutter dependencies for the mobile app
        if [ -d '$INSTALLER_DIR/talawa' ]; then
          echo '=> Installing Talawa mobile dependencies...'
          cd '$INSTALLER_DIR/talawa'
          flutter pub get
          echo ''
        fi

        echo 'To create an AVD (first time only):'
        echo '  avdmanager create avd --name phone --package \"system-images;android-35;google_apis;\$(uname -m | sed s/arm64/arm64-v8a/ | sed s/x86_64/x86_64/)\"'
        echo ''
        echo 'To launch the emulator:'
        echo '  emulator -avd phone -skin 720x1280 -noaudio -no-snapshot-load -no-snapshot'
        echo ''
        echo 'To run the app:'
        echo '  cd $INSTALLER_DIR/talawa && flutter run'
        echo ''
      "
    else
      # Physical device setup
      nix develop .#physical --command bash -c "
        echo ''
        echo '--- Mobile environment ready (physical device mode) ---'
        echo ''

        # Install Flutter dependencies for the mobile app
        if [ -d '$INSTALLER_DIR/talawa' ]; then
          echo '=> Installing Talawa mobile dependencies...'
          cd '$INSTALLER_DIR/talawa'
          flutter pub get
          echo ''
        fi

        echo 'Connect your device via USB and enable USB debugging.'
        echo 'Verify with: adb devices'
        echo ''
        echo 'To run the app:'
        echo '  cd $INSTALLER_DIR/talawa && flutter run'
        echo ''
      "
    fi
  )

  success "Talawa-Mobile dependencies installed."

  # Save mobile mode so main() can launch the right flake shell
  MOBILE_FLAKE_DIR="$FLAKE_DIR"
  MOBILE_FLAKE_MODE="$MOBILE_MODE"
}

###############################################################################
# Main
###############################################################################
main() {
  echo ""
  echo -e "${BOLD}====================================${NC}"
  echo -e "${BOLD}   Talawa Installer${NC}"
  echo -e "${BOLD}====================================${NC}"
  echo ""

  # Step 1: Check Nix
  check_nix

  # Step 2: Prompt for what to install
  prompt_option

  # Step 3: Check repositories
  check_repos

  # Step 4 & 5: Set up API/Admin if selected
  if [ "$INSTALL_API" = true ] && { [ "$INSTALL_ADMIN" = true ] || [ "$INSTALL_MOBILE" = true ]; }; then
    setup_api_and_admin
  fi

  # Step 6: Set up Mobile if selected
  if [ "$INSTALL_MOBILE" = true ]; then
    setup_mobile
  fi

  # ── Write autostart marker so the shellHook starts dev servers ───────────
  header "Installation Complete!"
  echo "  Installed components:"
  [ "$INSTALL_API" = true ]    && echo -e "    ${GREEN}+${NC} Talawa-API"
  [ "$INSTALL_ADMIN" = true ]  && echo -e "    ${GREEN}+${NC} Talawa-Admin"
  [ "$INSTALL_MOBILE" = true ] && echo -e "    ${GREEN}+${NC} Talawa-Mobile"
  echo ""
  echo "  Login credentials (API):"
  echo "    Email:    administrator@example.com"
  echo "    Password: Password1!"
  echo ""

  mkdir -p "$INSTALLER_DIR/.local"

  if [ "$INSTALL_API" = true ] || [ "$INSTALL_ADMIN" = true ]; then
    # Write autostart marker for the nix-shell shellHook
    cat > "$INSTALLER_DIR/.local/autostart" << AUTOSTART
AUTOSTART_API=${INSTALL_API}
AUTOSTART_ADMIN=${INSTALL_ADMIN}
AUTOSTART

    if [ "$INSTALL_MOBILE" = true ]; then
      echo ""
      info "Mobile development uses a separate Nix flake environment."
      info "Open a new terminal and run:"
      echo ""
      if [ "${MOBILE_FLAKE_MODE:-default}" = "default" ]; then
        echo -e "  ${BOLD}cd $INSTALLER_DIR && nix develop${NC}"
      else
        echo -e "  ${BOLD}cd $INSTALLER_DIR && nix develop .#physical${NC}"
      fi
      echo -e "  ${BOLD}cd talawa && flutter run${NC}"
      echo ""
    fi

    success "Dropping you into the development shell..."
    echo ""

    # exec replaces this process with an interactive nix-shell — the shellHook
    # will start PG, Redis, MinIO, and (via the autostart marker) the API and
    # Admin dev servers automatically.
    cd "$INSTALLER_DIR"
    exec nix-shell "$INSTALLER_DIR/default.nix"
  elif [ "$INSTALL_MOBILE" = true ]; then
    # Mobile-only install — drop into the flake dev shell
    success "Dropping you into the mobile development shell..."
    echo ""
    cd "$INSTALLER_DIR"
    if [ "${MOBILE_FLAKE_MODE:-default}" = "default" ]; then
      exec nix develop
    else
      exec nix develop .#physical
    fi
  fi
}

main "$@"
