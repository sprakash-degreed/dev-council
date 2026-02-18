#!/usr/bin/env bash
# Council — Installer
# Works on macOS and Linux
# Usage:
#   Local:  ./install.sh
#   Remote: curl -fsSL https://raw.githubusercontent.com/council-dev/council/main/install.sh | bash
set -euo pipefail

# --- Config ---
REPO_URL="https://github.com/council-dev/council.git"
INSTALL_DIR="${COUNCIL_INSTALL_DIR:-$HOME/.council/src}"
BIN_DIR="${COUNCIL_BIN_DIR:-$HOME/.local/bin}"
VERSION="${COUNCIL_VERSION:-main}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[info]${RESET} $*"; }
success() { echo -e "${GREEN}[ok]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET} $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; }

# --- Platform detection ---
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        *)      error "Unsupported OS: $OS"; exit 1 ;;
    esac

    info "Platform: $PLATFORM ($ARCH)"
}

# --- Dependency checks ---
check_deps() {
    local missing=0

    echo ""
    echo -e "${BOLD}Checking dependencies${RESET}"

    # Required: bash 4+
    local bash_version="${BASH_VERSINFO[0]}"
    if [[ "$bash_version" -ge 4 ]]; then
        echo -e "  ${GREEN}✓${RESET} bash $BASH_VERSION"
    else
        echo -e "  ${RED}✗${RESET} bash $BASH_VERSION (need 4+)"
        if [[ "$PLATFORM" == "macos" ]]; then
            warn "macOS ships bash 3. Install bash 4+ via: brew install bash"
        fi
        missing=1
    fi

    # Required: jq
    if command -v jq &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} jq $(jq --version 2>/dev/null || echo '')"
    else
        echo -e "  ${RED}✗${RESET} jq (required)"
        if [[ "$PLATFORM" == "macos" ]]; then
            warn "Install jq: brew install jq"
        else
            warn "Install jq: sudo apt install jq  OR  sudo dnf install jq"
        fi
        missing=1
    fi

    # Required: git (for install)
    if command -v git &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} git"
    else
        echo -e "  ${RED}✗${RESET} git (required for install)"
        missing=1
    fi

    # Optional: gum
    if command -v gum &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} gum (enhanced UI)"
    else
        echo -e "  ${DIM}○${RESET} gum ${DIM}(optional — brew install gum)${RESET}"
    fi

    # Agents (at least one needed)
    echo ""
    echo -e "${BOLD}Checking agents${RESET}"
    local agents_found=0
    for agent in claude codex gemini ollama; do
        if command -v "$agent" &>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} $agent"
            agents_found=$((agents_found + 1))
        else
            echo -e "  ${DIM}○${RESET} $agent ${DIM}(not installed)${RESET}"
        fi
    done

    if [[ $agents_found -eq 0 ]]; then
        warn "No agents found. Install at least one: claude, codex, gemini, or ollama"
    fi

    echo ""

    if [[ $missing -eq 1 ]]; then
        error "Missing required dependencies. Install them and re-run."
        exit 1
    fi
}

# --- Install ---
install_council() {
    local is_local=0

    # Check if we're running from within the council repo already
    if [[ -f "$(dirname "${BASH_SOURCE[0]}")/council" && -d "$(dirname "${BASH_SOURCE[0]}")/lib" ]]; then
        is_local=1
        local source_dir
        source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        info "Installing from local source: $source_dir"
    fi

    # Create bin directory
    mkdir -p "$BIN_DIR"

    if [[ $is_local -eq 1 ]]; then
        # Local install: symlink directly to the repo
        INSTALL_DIR="$source_dir"
        info "Linking from: $INSTALL_DIR"
    else
        # Remote install: clone the repo
        if [[ -d "$INSTALL_DIR/.git" ]]; then
            info "Updating existing installation..."
            git -C "$INSTALL_DIR" fetch --quiet
            git -C "$INSTALL_DIR" checkout "$VERSION" --quiet 2>/dev/null || \
                git -C "$INSTALL_DIR" pull --quiet
        else
            info "Cloning council..."
            rm -rf "$INSTALL_DIR"
            mkdir -p "$(dirname "$INSTALL_DIR")"
            git clone --quiet --depth 1 -b "$VERSION" "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || \
                git clone --quiet --depth 1 "$REPO_URL" "$INSTALL_DIR"
        fi
    fi

    # Make council executable
    chmod +x "$INSTALL_DIR/council"

    # Create symlink in bin dir
    ln -sf "$INSTALL_DIR/council" "$BIN_DIR/council"
    success "Linked: $BIN_DIR/council → $INSTALL_DIR/council"

    # Check if BIN_DIR is in PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
        echo ""
        warn "$BIN_DIR is not in your PATH"
        echo ""
        echo "  Add it to your shell profile:"
        echo ""

        local shell_name
        shell_name="$(basename "${SHELL:-bash}")"
        local rc_file
        case "$shell_name" in
            zsh)  rc_file="$HOME/.zshrc" ;;
            bash)
                if [[ "$PLATFORM" == "macos" ]]; then
                    rc_file="$HOME/.bash_profile"
                else
                    rc_file="$HOME/.bashrc"
                fi
                ;;
            fish) rc_file="$HOME/.config/fish/config.fish" ;;
            *)    rc_file="$HOME/.profile" ;;
        esac

        if [[ "$shell_name" == "fish" ]]; then
            echo -e "  ${BOLD}fish_add_path $BIN_DIR${RESET}"
        else
            echo -e "  ${BOLD}echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> $rc_file${RESET}"
        fi
        echo ""
        echo "  Then restart your shell or run:"
        echo -e "  ${BOLD}export PATH=\"$BIN_DIR:\$PATH\"${RESET}"
    fi
}

# --- Verify ---
verify_install() {
    echo ""
    if command -v council &>/dev/null || [[ -x "$BIN_DIR/council" ]]; then
        local ver
        ver="$("$BIN_DIR/council" version 2>/dev/null || echo "unknown")"
        success "Installed: $ver"
        echo ""
        echo -e "${BOLD}Getting started:${RESET}"
        echo "  cd your-project"
        echo "  council dev"
        echo ""
        echo -e "${DIM}Run 'council help' for all commands${RESET}"
    else
        error "Installation failed — council not found in PATH"
        exit 1
    fi
}

# --- Uninstall ---
uninstall_council() {
    echo ""
    echo -e "${BOLD}Uninstalling council${RESET}"

    if [[ -L "$BIN_DIR/council" ]]; then
        rm -f "$BIN_DIR/council"
        success "Removed: $BIN_DIR/council"
    elif [[ -f "$BIN_DIR/council" ]]; then
        rm -f "$BIN_DIR/council"
        success "Removed: $BIN_DIR/council"
    else
        warn "council not found in $BIN_DIR"
    fi

    if [[ -d "$INSTALL_DIR" && "$INSTALL_DIR" == *".council/src"* ]]; then
        rm -rf "$INSTALL_DIR"
        success "Removed: $INSTALL_DIR"
    else
        info "Source directory preserved: $INSTALL_DIR"
    fi

    echo ""
    success "Council uninstalled"
}

# --- Main ---
main() {
    echo ""
    echo -e "${BOLD}Council Installer${RESET}"
    echo ""

    local action="${1:-install}"

    case "$action" in
        install)
            detect_platform
            check_deps
            install_council
            verify_install
            ;;
        uninstall|remove)
            uninstall_council
            ;;
        check)
            detect_platform
            check_deps
            ;;
        *)
            echo "Usage: install.sh [install|uninstall|check]"
            echo ""
            echo "Environment variables:"
            echo "  COUNCIL_INSTALL_DIR  Source location (default: ~/.council/src)"
            echo "  COUNCIL_BIN_DIR     Binary location (default: ~/.local/bin)"
            echo "  COUNCIL_VERSION     Git ref to install (default: main)"
            exit 1
            ;;
    esac
}

main "$@"
