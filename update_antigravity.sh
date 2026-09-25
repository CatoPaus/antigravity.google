#!/usr/bin/env bash
#
# update_antigravity.sh - Check, verify, repair, and update Antigravity 2.0, Antigravity IDE, and agy CLI
# Portable across any Ubuntu/Debian installation.
#
set -euo pipefail

SCRIPT_VERSION="2.3.4"

# Resolve canonical script path to safely re-execute across shells, directories, and sudo
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

# 1. Terminal Color Support (respecting NO_COLOR and non-interactive pipes)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_GREEN="\033[0;32m"
  C_CYAN="\033[0;36m"
  C_YELLOW="\033[0;33m"
  C_RED="\033[0;31m"
  C_BLUE="\033[0;34m"
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_GREEN=""
  C_CYAN=""
  C_YELLOW=""
  C_RED=""
  C_BLUE=""
fi

# 2. Resolve User and Directories dynamically (safe under set -u and across diverse shells/cron)
ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || whoami)}}"
if [ -n "$ACTUAL_USER" ] && id "$ACTUAL_USER" >/dev/null 2>&1; then
  USER_HOME=$(getent passwd "$ACTUAL_USER" 2>/dev/null | head -n 1 | cut -d: -f6)
fi
if [ -z "${USER_HOME:-}" ] || [ ! -d "$USER_HOME" ]; then
  USER_HOME="${HOME:-/tmp}"
fi

DOWNLOAD_DIR="${USER_HOME}/Downloads"
if [ ! -d "$DOWNLOAD_DIR" ]; then
  mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || DOWNLOAD_DIR="/tmp/antigravity-downloads"
fi

# Locate Antigravity CLI (agy) binary across PATH and user directories
find_agy() {
  if command -v agy >/dev/null 2>&1; then
    command -v agy
  elif [ -x "$USER_HOME/.local/bin/agy" ]; then
    echo "$USER_HOME/.local/bin/agy"
  elif [ -x "/usr/local/bin/agy" ]; then
    echo "/usr/local/bin/agy"
  else
    echo ""
  fi
}
AGY_BIN="$(find_agy)"

HUB_DIR="/opt/Antigravity"
HUB_BACKUP_DIR="/opt/Antigravity.bak"
IDE_DIR="/opt/Antigravity-IDE"
IDE_BACKUP_DIR="/opt/Antigravity-IDE.bak"
# Display flags: Automatically choose native Wayland when available to prevent
# XWayland GPU render loops and continuous fan noise on Linux, while safely falling back to X11.
HUB_DISPLAY_FLAGS="--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations"

# 3. Check and Auto-Install Script Dependencies (curl, python3, tar, ca-certificates)
MISSING_TOOLS=()
for tool in curl python3 tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING_TOOLS+=("$tool")
  fi
done

if [ ! -d "/etc/ssl/certs" ]; then
  MISSING_TOOLS+=("ca-certificates")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  echo -e "${C_YELLOW}==> Missing required tools: ${MISSING_TOOLS[*]}${C_RESET}"
  if [ "$EUID" -eq 0 ]; then
    echo "==> Installing missing tools via apt-get..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y "${MISSING_TOOLS[@]}"
  else
    echo "==> Root privileges required to install dependencies: ${MISSING_TOOLS[*]}"
    echo "    Elevating with sudo..."
    exec sudo bash "$SCRIPT_PATH" --no-git "$@"
  fi
fi

# 4. Architecture Detection
MACHINE="$(uname -m)"
case "$MACHINE" in
  x86_64)
    ARCH="linux-x64"
    ;;
  aarch64|arm64)
    ARCH="linux-arm"
    ;;
  *)
    echo -e "${C_RED}Error: Unsupported architecture: $MACHINE${C_RESET}"
    exit 1
    ;;
esac

# Helper function to install icons across standard system and user icon themes
install_desktop_icon() {
  local app_id="$1"
  local source_icon="$2"
  
  if [ -f "$source_icon" ]; then
    echo "==> Installing desktop icon for $app_id..."
    
    # 1. Pixmaps
    mkdir -p /usr/share/pixmaps
    cp -f "$source_icon" "/usr/share/pixmaps/${app_id}.png"
    
    # 2. System Hicolor Theme
    mkdir -p /usr/share/icons/hicolor/512x512/apps
    cp -f "$source_icon" "/usr/share/icons/hicolor/512x512/apps/${app_id}.png"
    
    # 3. User Hicolor Theme
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      local user_icon_dir="$USER_HOME/.local/share/icons/hicolor/512x512/apps"
      mkdir -p "$user_icon_dir"
      cp -f "$source_icon" "$user_icon_dir/${app_id}.png"
      chown -R "$ACTUAL_USER:" "$USER_HOME/.local/share/icons" 2>/dev/null || true
    fi
  fi
}

# ============================================================
# VERIFICATION SUBSYSTEM (--verify / --doctor)
# ============================================================
run_verification() {
  local checks_passed=0
  local checks_failed=0
  local checks_warned=0

  pass() {
    local msg="$1"
    echo -e "    ${C_GREEN}[✓]${C_RESET} $msg"
    checks_passed=$((checks_passed + 1))
  }

  fail() {
    local msg="$1"
    echo -e "    ${C_RED}[✗]${C_RESET} $msg"
    checks_failed=$((checks_failed + 1))
  }

  warn() {
    local msg="$1"
    echo -e "    ${C_YELLOW}[⚠]${C_RESET} $msg"
    checks_warned=$((checks_warned + 1))
  }

  echo "============================================================"
  echo "        Antigravity Suite Installation Verification         "
  echo "============================================================"

  # 1. System & Runtime Environment
  echo ""
  echo -e "${C_BOLD}--> System & Runtime Environment:${C_RESET}"
  
  if [ "$ARCH" = "linux-x64" ] || [ "$ARCH" = "linux-arm" ]; then
    pass "Architecture: $MACHINE ($ARCH supported)"
  else
    fail "Architecture: $MACHINE is not supported by Antigravity"
  fi

  local missing_core=()
  for tool in curl python3 tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_core+=("$tool")
    fi
  done
  if [ ${#missing_core[@]} -eq 0 ]; then
    pass "Core utilities: curl, python3, tar present"
  else
    fail "Missing core utilities: ${missing_core[*]}"
  fi

  if [ -d "/etc/ssl/certs" ]; then
    pass "SSL certificates: /etc/ssl/certs present"
  else
    warn "SSL certificates: /etc/ssl/certs missing"
  fi

  local missing_libs=()
  if command -v ldconfig >/dev/null 2>&1; then
    local ld_cache
    ld_cache=$(ldconfig -p 2>/dev/null || true)
    grep -q 'libgtk-3\.so' <<< "$ld_cache" || missing_libs+=("libgtk-3")
    grep -q 'libnss3\.so' <<< "$ld_cache" || missing_libs+=("libnss3")
    grep -q 'libgbm\.so' <<< "$ld_cache" || missing_libs+=("libgbm")
    (grep -q 'libasound\.so' <<< "$ld_cache" || grep -q 'libasound2' <<< "$ld_cache") || missing_libs+=("libasound")
    grep -q 'libsecret-1\.so' <<< "$ld_cache" || missing_libs+=("libsecret-1")

    if [ ${#missing_libs[@]} -eq 0 ]; then
      pass "Desktop GUI libraries: libgtk-3, libnss3, libgbm, libasound, libsecret-1 present"
    else
      warn "Missing GUI libraries: ${missing_libs[*]} (run 'sudo apt install libgtk-3-0 libnss3 libgbm1 libsecret-1-0')"
    fi
  else
    warn "Cannot verify GUI libraries (ldconfig not available)"
  fi

  local path_ok=true
  if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    warn "/usr/local/bin is missing from current PATH"
    path_ok=false
  fi

  if [ -d "$USER_HOME/.local/bin" ]; then
    if [[ ":$PATH:" == *":$USER_HOME/.local/bin:"* ]] || [[ ":$PATH:" == *":~/.local/bin:"* ]]; then
      pass "PATH integration: system and user bin directories accessible in active shell"
    else
      local configured_in_rc=false
      for rc in "$USER_HOME/.bashrc" "$USER_HOME/.profile" "$USER_HOME/.zshrc"; do
        if [ -f "$rc" ] && grep -q '\.local/bin' "$rc" 2>/dev/null; then
          configured_in_rc=true
          break
        fi
      done

      if [ "$configured_in_rc" = true ]; then
        pass "PATH integration: ~/.local/bin configured in shell config (active on next terminal or: eval \"\$(update-antigravity env)\")"
      elif [ -x "/usr/local/bin/agy" ]; then
        pass "PATH integration: ~/.local/bin covered by /usr/local/bin system symlinks"
      else
        warn "$USER_HOME/.local/bin exists but is not in current PATH or shell configuration (run: update-antigravity --fix-path)"
        path_ok=false
      fi
    fi
  else
    if [ "$path_ok" = true ]; then
      pass "PATH integration: system bin directory accessible (/usr/local/bin)"
    fi
  fi

  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    pass "Display session: native Wayland ($WAYLAND_DISPLAY)"
  elif [ -n "${DISPLAY:-}" ]; then
    pass "Display session: X11 ($DISPLAY)"
  else
    warn "No active display session detected (headless or remote SSH)"
  fi

  # 2. Antigravity 2.0 (Desktop Hub)
  echo ""
  echo -e "${C_BOLD}--> Antigravity 2.0 (Desktop App):${C_RESET}"
  if [ ! -d "$HUB_DIR" ]; then
    warn "Antigravity 2.0 is not installed in $HUB_DIR"
  else
    pass "Installation directory: $HUB_DIR exists"

    if [ ! -f "$HUB_DIR/antigravity" ]; then
      fail "Executable binary missing: $HUB_DIR/antigravity does not exist!"
    elif [ ! -x "$HUB_DIR/antigravity" ]; then
      fail "Executable binary not executable: $HUB_DIR/antigravity (needs chmod +x)"
    elif ! head -c 4 "$HUB_DIR/antigravity" 2>/dev/null | grep -q 'ELF'; then
      fail "Executable binary corrupted: $HUB_DIR/antigravity is a script/text file, not an ELF binary!"
    else
      local bin_size
      bin_size=$(du -h "$HUB_DIR/antigravity" 2>/dev/null | cut -f1)
      pass "Executable binary: $HUB_DIR/antigravity (ELF 64-bit, size: $bin_size)"

      if command -v ldd >/dev/null 2>&1; then
        local missing_ldd
        missing_ldd=$(ldd "$HUB_DIR/antigravity" 2>&1 | grep "not found" || true)
        if [ -n "$missing_ldd" ]; then
          fail "Shared libraries missing for $HUB_DIR/antigravity:\n$missing_ldd"
        else
          pass "Shared library dependencies: all dynamic libraries resolved"
        fi
      fi
    fi

    if [ ! -f "$HUB_DIR/chrome-sandbox" ]; then
      fail "Sandbox helper missing: $HUB_DIR/chrome-sandbox not found!"
    else
      local sb_stat
      sb_stat=$(stat -c "%a %U:%G" "$HUB_DIR/chrome-sandbox" 2>/dev/null || true)
      if [[ "$sb_stat" == "4755 root:root"* ]]; then
        pass "SUID sandbox helper: $HUB_DIR/chrome-sandbox (mode 4755, root:root)"
      else
        fail "SUID sandbox helper incorrect permissions: $HUB_DIR/chrome-sandbox ($sb_stat, requires 4755 root:root)"
      fi
    fi

    if [ -f "$HUB_DIR/resources/app.asar" ]; then
      local asar_ver
      asar_ver=$(python3 -c "
import struct, json
try:
    with open('$HUB_DIR/resources/app.asar', 'rb') as f:
        magic, header_size, inner_size, json_len = struct.unpack('<4I', f.read(16))
        base_offset = 8 + header_size
        header = json.loads(f.read(json_len).decode('utf-8'))
        pkg_entry = header.get('files', {}).get('package.json', {})
        offset = int(pkg_entry.get('offset', 0))
        size = int(pkg_entry.get('size', 0))
        f.seek(base_offset + offset)
        pkg = json.loads(f.read(size).decode('utf-8'))
        print(pkg.get('version', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
      pass "Application package: $HUB_DIR/resources/app.asar (version: $asar_ver)"
    else
      fail "Application package missing: $HUB_DIR/resources/app.asar not found!"
    fi

    if [ -L "/usr/local/bin/antigravity" ]; then
      local link_target
      link_target=$(readlink -f "/usr/local/bin/antigravity" 2>/dev/null || true)
      if [ "$link_target" = "$HUB_DIR/antigravity" ]; then
        fail "/usr/local/bin/antigravity is a symlink directly to $HUB_DIR/antigravity! (Must be wrapper script)"
      else
        pass "/usr/local/bin/antigravity symlink valid ($link_target)"
      fi
    elif [ -f "/usr/local/bin/antigravity" ]; then
      if [ -x "/usr/local/bin/antigravity" ]; then
        pass "System launcher: /usr/local/bin/antigravity (wrapper script, executable)"
      else
        fail "System launcher /usr/local/bin/antigravity exists but is not executable"
      fi
    else
      warn "System launcher /usr/local/bin/antigravity missing"
    fi

    if [ -f "$USER_HOME/.local/bin/antigravity" ] && [ -x "$USER_HOME/.local/bin/antigravity" ]; then
      pass "User launcher: $USER_HOME/.local/bin/antigravity (executable)"
    fi

    if [ -f "/usr/share/applications/antigravity.desktop" ]; then
      local exec_target
      exec_target=$(grep -oP '^Exec=\K[^ ]+' "/usr/share/applications/antigravity.desktop" | head -n 1)
      if [ -f "$exec_target" ]; then
        pass "System desktop file: /usr/share/applications/antigravity.desktop (Exec=$exec_target)"
      else
        fail "Desktop file points to non-existent executable: Exec=$exec_target"
      fi
    else
      warn "System desktop file /usr/share/applications/antigravity.desktop missing"
    fi

    if [ -f "/usr/share/pixmaps/antigravity.png" ] && file "/usr/share/pixmaps/antigravity.png" | grep -q 'PNG'; then
      pass "System icon: /usr/share/pixmaps/antigravity.png (valid PNG)"
    elif [ -f "/usr/share/icons/hicolor/512x512/apps/antigravity.png" ]; then
      pass "System icon: /usr/share/icons/hicolor/512x512/apps/antigravity.png"
    else
      fail "Desktop icon missing in /usr/share/pixmaps/antigravity.png"
    fi
  fi

  # 3. Antigravity IDE
  echo ""
  echo -e "${C_BOLD}--> Antigravity IDE:${C_RESET}"
  if [ ! -d "$IDE_DIR" ]; then
    warn "Antigravity IDE is not installed in $IDE_DIR"
  else
    pass "Installation directory: $IDE_DIR exists"

    if [ ! -f "$IDE_DIR/antigravity-ide" ]; then
      fail "Executable binary missing: $IDE_DIR/antigravity-ide does not exist!"
    elif [ ! -x "$IDE_DIR/antigravity-ide" ]; then
      fail "Executable binary not executable: $IDE_DIR/antigravity-ide"
    elif ! head -c 4 "$IDE_DIR/antigravity-ide" 2>/dev/null | grep -q 'ELF'; then
      fail "Executable binary corrupted: $IDE_DIR/antigravity-ide is not an ELF binary!"
    else
      local ide_bin_size
      ide_bin_size=$(du -h "$IDE_DIR/antigravity-ide" 2>/dev/null | cut -f1)
      pass "Executable binary: $IDE_DIR/antigravity-ide (ELF 64-bit, size: $ide_bin_size)"

      if command -v ldd >/dev/null 2>&1; then
        local missing_ide_ldd
        missing_ide_ldd=$(ldd "$IDE_DIR/antigravity-ide" 2>&1 | grep "not found" || true)
        if [ -n "$missing_ide_ldd" ]; then
          fail "Shared libraries missing for $IDE_DIR/antigravity-ide:\n$missing_ide_ldd"
        else
          pass "Shared library dependencies: all dynamic libraries resolved"
        fi
      fi
    fi

    if [ -f "$IDE_DIR/chrome-sandbox" ]; then
      local ide_sb_stat
      ide_sb_stat=$(stat -c "%a %U:%G" "$IDE_DIR/chrome-sandbox" 2>/dev/null || true)
      if [[ "$ide_sb_stat" == "4755 root:root"* ]]; then
        pass "SUID sandbox helper: $IDE_DIR/chrome-sandbox (mode 4755, root:root)"
      else
        fail "SUID sandbox helper incorrect permissions: $IDE_DIR/chrome-sandbox ($ide_sb_stat, requires 4755 root:root)"
      fi
    else
      fail "Sandbox helper missing: $IDE_DIR/chrome-sandbox not found!"
    fi

    if [ -f "$IDE_DIR/resources/app/product.json" ]; then
      local ide_ver
      ide_ver=$(python3 -c "
import json
try:
    with open('$IDE_DIR/resources/app/product.json') as f:
        data = json.load(f)
        print(data.get('ideVersion', data.get('version', 'unknown')))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
      pass "Product manifest: $IDE_DIR/resources/app/product.json (version: $ide_ver)"
    else
      fail "Product manifest missing: $IDE_DIR/resources/app/product.json"
    fi

    if [ -L "/usr/local/bin/antigravity-ide" ]; then
      if [ -e "/usr/local/bin/antigravity-ide" ]; then
        pass "System launcher symlink: /usr/local/bin/antigravity-ide -> $(readlink -f /usr/local/bin/antigravity-ide)"
      else
        fail "System launcher symlink broken: /usr/local/bin/antigravity-ide points to non-existent target"
      fi
    elif [ -f "/usr/local/bin/antigravity-ide" ]; then
      pass "System launcher: /usr/local/bin/antigravity-ide"
    else
      warn "System launcher /usr/local/bin/antigravity-ide missing"
    fi

    if [ -f "/usr/share/applications/antigravity-ide.desktop" ]; then
      local ide_exec
      ide_exec=$(grep -oP '^Exec=\K[^ ]+' "/usr/share/applications/antigravity-ide.desktop" | head -n 1)
      if [ -f "$ide_exec" ]; then
        pass "System desktop file: /usr/share/applications/antigravity-ide.desktop (Exec=$ide_exec)"
      else
        fail "Desktop file points to non-existent executable: Exec=$ide_exec"
      fi
    else
      warn "System desktop file /usr/share/applications/antigravity-ide.desktop missing"
    fi

    if [ -f "/usr/share/pixmaps/antigravity-ide.png" ] && file "/usr/share/pixmaps/antigravity-ide.png" | grep -q 'PNG'; then
      pass "System icon: /usr/share/pixmaps/antigravity-ide.png (valid PNG)"
    elif [ -f "/usr/share/icons/hicolor/512x512/apps/antigravity-ide.png" ]; then
      pass "System icon: /usr/share/icons/hicolor/512x512/apps/antigravity-ide.png"
    else
      fail "Desktop icon missing in /usr/share/pixmaps/antigravity-ide.png"
    fi
  fi

  # 4. Antigravity CLI (agy)
  echo ""
  echo -e "${C_BOLD}--> Antigravity CLI (agy):${C_RESET}"
  if [ -n "$AGY_BIN" ] && [ -f "$AGY_BIN" ]; then
    if [ -x "$AGY_BIN" ]; then
      local agy_ver
      agy_ver=$("$AGY_BIN" --version 2>/dev/null || echo "error")
      if [ "$agy_ver" != "error" ]; then
        pass "Binary executable: $AGY_BIN (version: $agy_ver)"
      else
        fail "Binary $AGY_BIN failed to execute with --version"
      fi
    else
      fail "Binary found at $AGY_BIN but lacks executable permission (+x)"
    fi

    if command -v agy >/dev/null 2>&1; then
      pass "CLI accessibility: 'agy' command resolves in PATH"
    else
      warn "'agy' is installed at $AGY_BIN but directory is not in your current PATH"
      echo -e "       ${C_DIM}Run: eval \"\$(update-antigravity env)\" (or: update-antigravity --fix-path)${C_RESET}"
    fi

    local cli_cfg="$USER_HOME/.gemini/config/config.json"
    if [ -f "$cli_cfg" ]; then
      local unsandboxed_count=0
      unsandboxed_count=$(grep -c 'unsandboxed(' "$cli_cfg" 2>/dev/null || true)
      unsandboxed_count="${unsandboxed_count:-0}"
      if [ "$unsandboxed_count" -eq 0 ]; then
        pass "CLI configuration: clean (no deprecated permission rules in config.json)"
      else
        warn "CLI configuration: found $unsandboxed_count deprecated 'unsandboxed' rule(s) in config.json (run: update-antigravity --repair)"
      fi
    fi
  else
    warn "Antigravity CLI (agy) not installed (install via: curl -fsSL https://antigravity.google/cli/install.sh | bash)"
  fi

  # 5. User Permissions & Symlink Integrity
  echo ""
  echo -e "${C_BOLD}--> Permissions & Integrity:${C_RESET}"

  local root_owned=()
  for dir in "$USER_HOME/.local/share/applications" "$USER_HOME/.local/share/icons"; do
    if [ -d "$dir" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && root_owned+=("$f")
      done < <(find "$dir" -user root 2>/dev/null || true)
    fi
  done
  if [ ${#root_owned[@]} -eq 0 ]; then
    pass "User directory ownership: no root-owned files in ~/.local/share"
  else
    fail "Found ${#root_owned[@]} file(s) owned by root in ~/.local/share (run with --repair to fix)"
  fi

  local broken_links=()
  for ldir in "/usr/local/bin" "$USER_HOME/.local/bin"; do
    if [ -d "$ldir" ]; then
      for link in "$ldir"/antigravity* "$ldir"/update-antigravity; do
        if [ -L "$link" ] && [ ! -e "$link" ]; then
          broken_links+=("$link")
        fi
      done
    fi
  done
  if [ ${#broken_links[@]} -eq 0 ]; then
    pass "Symlink health: no broken or dangling Antigravity symlinks"
  else
    fail "Found broken symlink(s): ${broken_links[*]}"
  fi

  # 6. Updater Script & Git Synchronization
  echo ""
  echo -e "${C_BOLD}--> Updater Script & Git Synchronization:${C_RESET}"
  if [ -x "$SCRIPT_PATH" ]; then
    pass "Updater script: executable at $SCRIPT_PATH (v$SCRIPT_VERSION)"
  else
    fail "Updater script: not executable ($SCRIPT_PATH)"
  fi

  local repo_dir
  repo_dir="$(dirname "$SCRIPT_PATH")"
  if command -v git >/dev/null 2>&1 && git -c safe.directory="*" -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local branch git_hash remote_url
    branch=$(git -c safe.directory="*" -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    git_hash=$(git -c safe.directory="*" -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    remote_url=$(git -c safe.directory="*" -C "$repo_dir" remote get-url origin 2>/dev/null || echo "none")

    pass "Git repository: managed at $repo_dir (branch: $branch, commit: $git_hash)"
    if [ "$remote_url" != "none" ]; then
      pass "Git remote: configured ($remote_url)"
    else
      warn "Git remote: no 'origin' remote configured"
    fi

    if git -c safe.directory="*" -C "$repo_dir" diff --quiet 2>/dev/null && git -c safe.directory="*" -C "$repo_dir" diff --cached --quiet 2>/dev/null; then
      pass "Git working tree: clean (no uncommitted modifications)"
    else
      warn "Git working tree: contains local uncommitted modifications"
    fi
  else
    pass "Updater script: running in standalone mode (no Git repository)"
  fi

  # Final Result Summary
  echo ""
  echo "============================================================"
  if [ "$checks_failed" -eq 0 ] && [ "$checks_warned" -eq 0 ]; then
    echo -e "${C_GREEN}${C_BOLD}Verification Result: ALL $checks_passed CHECKS PASSED ✓${C_RESET}"
    echo "All Antigravity components are healthy and properly configured."
    echo "============================================================"
    return 0
  elif [ "$checks_failed" -eq 0 ]; then
    echo -e "${C_YELLOW}${C_BOLD}Verification Result: $checks_passed PASSED, $checks_warned WARNING(S)${C_RESET}"
    echo "No fatal errors found, but review the warnings above."
    echo "============================================================"
    return 0
  else
    echo -e "${C_RED}${C_BOLD}Verification Result: $checks_failed FAILED, $checks_warned WARNING(S), $checks_passed PASSED${C_RESET}"
    echo "Issues were detected that may prevent Antigravity from functioning correctly."
    echo ""
    echo "To automatically fix detected permissions, symlinks, and broken binaries:"
    echo "  update-antigravity --repair"
    echo "============================================================"
    return 1
  fi
}

# ============================================================
# REPAIR SUBSYSTEM (--repair / --fix)
# ============================================================
run_repair() {
  echo "============================================================"
  echo "             Antigravity Suite Auto-Repair                  "
  echo "============================================================"

  # 1. Require sudo elevation
  if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "==> Root privileges required to repair system files and permissions."
    echo "    Prompting for sudo..."
    exec sudo bash "$SCRIPT_PATH" --no-git --repair "$@"
  fi

  echo "==> [1/6] Fixing chrome-sandbox SUID permissions (mode 4755 root:root)..."
  if [ -f "$HUB_DIR/chrome-sandbox" ]; then
    chown root:root "$HUB_DIR/chrome-sandbox"
    chmod 4755 "$HUB_DIR/chrome-sandbox"
    echo "    ✓ Antigravity 2.0 sandbox repaired"
  fi
  if [ -f "$IDE_DIR/chrome-sandbox" ]; then
    chown root:root "$IDE_DIR/chrome-sandbox"
    chmod 4755 "$IDE_DIR/chrome-sandbox"
    echo "    ✓ Antigravity IDE sandbox repaired"
  fi

  echo "==> [2/6] Repairing launcher scripts and resolving bad symlinks..."
  # Recreate Hub wrapper safely
  rm -f /usr/local/bin/antigravity
  cat << LAUNCHER_HUB_EOF > /usr/local/bin/antigravity
#!/usr/bin/env bash
# Antigravity Launcher Wrapper
# Dynamically resolves Wayland/X11 environment and passes optimal flags
EXTRA_FLAGS=()
if [ -n "\${WAYLAND_DISPLAY:-}" ] || [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  EXTRA_FLAGS+=($HUB_DISPLAY_FLAGS)
fi
exec "$HUB_DIR/antigravity" "\${EXTRA_FLAGS[@]}" "\$@"
LAUNCHER_HUB_EOF
  chmod 755 /usr/local/bin/antigravity
  echo "    ✓ /usr/local/bin/antigravity wrapper restored"

  if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/bin" ]; then
    rm -f "$USER_HOME/.local/bin/antigravity"
    cp -f /usr/local/bin/antigravity "$USER_HOME/.local/bin/antigravity"
    chown "$ACTUAL_USER:" "$USER_HOME/.local/bin/antigravity" 2>/dev/null || true
    echo "    ✓ $USER_HOME/.local/bin/antigravity restored"
  fi

  # Recreate IDE symlinks safely
  if [ -f "$IDE_DIR/antigravity-ide" ]; then
    rm -f /usr/local/bin/antigravity-ide
    ln -sf "$IDE_DIR/antigravity-ide" /usr/local/bin/antigravity-ide
    if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/bin" ]; then
      rm -f "$USER_HOME/.local/bin/antigravity-ide"
      ln -sf "$IDE_DIR/antigravity-ide" "$USER_HOME/.local/bin/antigravity-ide"
      chown -h "$ACTUAL_USER:" "$USER_HOME/.local/bin/antigravity-ide" 2>/dev/null || true
    fi
    echo "    ✓ Antigravity IDE launcher links restored"
  fi

  # Recreate update-antigravity command
  ln -sf "$SCRIPT_PATH" /usr/local/bin/update-antigravity 2>/dev/null || true
  if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/bin" ]; then
    ln -sf "$SCRIPT_PATH" "$USER_HOME/.local/bin/update-antigravity" 2>/dev/null || true
    chown -h "$ACTUAL_USER:" "$USER_HOME/.local/bin/update-antigravity" 2>/dev/null || true
  fi
  echo "    ✓ update-antigravity command links restored"

  # Link agy CLI into /usr/local/bin if installed in user local bin
  local user_agy="$USER_HOME/.local/bin/agy"
  if [ -f "$user_agy" ] && [ -x "$user_agy" ]; then
    rm -f /usr/local/bin/agy
    ln -sf "$user_agy" /usr/local/bin/agy
    echo "    ✓ /usr/local/bin/agy launcher restored"
  fi

  # Ensure ~/.local/bin is in user's shell rc files
  if [ -n "${USER_HOME:-}" ] && [ "$ACTUAL_USER" != "root" ]; then
    for rc in "$USER_HOME/.bashrc" "$USER_HOME/.profile" "$USER_HOME/.zshrc"; do
      if [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
        echo "" >> "$rc"
        echo '# Antigravity CLI PATH' >> "$rc"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        chown "$ACTUAL_USER:" "$rc" 2>/dev/null || true
        echo "    ✓ Added ~/.local/bin to $(basename "$rc")"
      fi
    done
  fi

  echo "==> [3/6] Restoring desktop files and icons..."
  if [ -d "$HUB_DIR" ]; then
    cat << DESKTOP_HUB_EOF > /usr/share/applications/antigravity.desktop
[Desktop Entry]
Name=Antigravity
Comment=Antigravity - Agentic Desktop Application
Exec=$HUB_DIR/antigravity $HUB_DISPLAY_FLAGS %U
Icon=antigravity
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=Antigravity
MimeType=x-scheme-handler/antigravity;
Keywords=antigravity;ai;agent;gemini;code;ide;
DESKTOP_HUB_EOF
    if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/share/applications" ]; then
      cp -f /usr/share/applications/antigravity.desktop "$USER_HOME/.local/share/applications/antigravity.desktop"
      chown "$ACTUAL_USER:" "$USER_HOME/.local/share/applications/antigravity.desktop" 2>/dev/null || true
    fi
    # Re-extract icon if missing
    if [ ! -f "$HUB_DIR/antigravity.png" ] && [ -f "$HUB_DIR/resources/app.asar" ]; then
      python3 -c "
import struct, json
try:
    with open('$HUB_DIR/resources/app.asar', 'rb') as f:
        magic, header_size, inner_size, json_len = struct.unpack('<4I', f.read(16))
        base_offset = 8 + header_size
        header = json.loads(f.read(json_len).decode('utf-8'))
        entry = header.get('files', {}).get('icon.png', {})
        offset = int(entry.get('offset', 0))
        size = int(entry.get('size', 0))
        f.seek(base_offset + offset)
        data = f.read(size)
        with open('$HUB_DIR/antigravity.png', 'wb') as out:
            out.write(data)
except Exception:
    pass
" 2>/dev/null || true
    fi
    if [ -f "$HUB_DIR/antigravity.png" ]; then
      install_desktop_icon "antigravity" "$HUB_DIR/antigravity.png"
    fi
    echo "    ✓ Antigravity 2.0 desktop entry and icons restored"
  fi

  if [ -d "$IDE_DIR" ]; then
    cat << DESKTOP_IDE_EOF > /usr/share/applications/antigravity-ide.desktop
[Desktop Entry]
Name=Antigravity IDE
Comment=Antigravity IDE - AI-First Code Editor
Exec=$IDE_DIR/antigravity-ide %F
Icon=antigravity-ide
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=antigravity-ide
MimeType=text/plain;inode/directory;
Keywords=antigravity;ide;ai;agent;code;vscode;
DESKTOP_IDE_EOF
    if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/share/applications" ]; then
      cp -f /usr/share/applications/antigravity-ide.desktop "$USER_HOME/.local/share/applications/antigravity-ide.desktop"
      chown "$ACTUAL_USER:" "$USER_HOME/.local/share/applications/antigravity-ide.desktop" 2>/dev/null || true
    fi
    IDE_ICON_SOURCE="$IDE_DIR/resources/app/resources/linux/code.png"
    if [ -f "$IDE_ICON_SOURCE" ]; then
      install_desktop_icon "antigravity-ide" "$IDE_ICON_SOURCE"
    fi
    echo "    ✓ Antigravity IDE desktop entry and icons restored"
  fi

  echo "==> [4/6] Rebuilding desktop and icon caches..."
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications 2>/dev/null || true
    if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/share/applications" ]; then
      update-desktop-database "$USER_HOME/.local/share/applications" 2>/dev/null || true
    fi
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/share/icons/hicolor" ]; then
      gtk-update-icon-cache -f -t "$USER_HOME/.local/share/icons/hicolor" 2>/dev/null || true
    fi
  fi
  echo "    ✓ Desktop and icon caches refreshed"

  echo "==> [5/6] Restoring user directory ownership and cleaning configuration..."
  if [ -n "${USER_HOME:-}" ] && [ "$ACTUAL_USER" != "root" ]; then
    chown -R "$ACTUAL_USER:" "$USER_HOME/.local/share/icons" "$USER_HOME/.local/share/applications" 2>/dev/null || true
    [ -d "$USER_HOME/.local/bin" ] && chown "$ACTUAL_USER:" "$USER_HOME/.local/bin"/antigravity* 2>/dev/null || true
    echo "    ✓ User directory permissions normalized to $ACTUAL_USER"
  fi
  clean_legacy_permissions

  # Check if binaries are corrupted, and trigger reinstall if so
  echo "==> [6/6] Checking for corrupted binaries requiring full reinstall..."
  local needs_hub_reinstall=false
  local needs_ide_reinstall=false

  if [ -d "$HUB_DIR" ] && { [ ! -f "$HUB_DIR/antigravity" ] || ! head -c 4 "$HUB_DIR/antigravity" 2>/dev/null | grep -q 'ELF'; }; then
    needs_hub_reinstall=true
  fi
  if [ -d "$IDE_DIR" ] && { [ ! -f "$IDE_DIR/antigravity-ide" ] || ! head -c 4 "$IDE_DIR/antigravity-ide" 2>/dev/null | grep -q 'ELF'; }; then
    needs_ide_reinstall=true
  fi

  if [ "$needs_hub_reinstall" = true ] || [ "$needs_ide_reinstall" = true ]; then
    echo -e "${C_YELLOW}Corrupted binaries detected! Triggering full re-installation...${C_RESET}"
    FORCE=true
    # Will continue below to update/reinstall blocks
  else
    echo "    ✓ All binaries verified healthy."
    echo ""
    run_verification
    exit 0
  fi
}

# ============================================================
# PATH CONFIGURATION SUBSYSTEM (--fix-path)
# ============================================================
run_fix_path() {
  echo "============================================================"
  echo "          Antigravity User PATH Configuration               "
  echo "============================================================"

  local target_dir="$USER_HOME/.local/bin"
  mkdir -p "$target_dir" 2>/dev/null || true
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown "$ACTUAL_USER:" "$target_dir" 2>/dev/null || true
  fi

  # 1. Update shell configuration files
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  for rc in "$USER_HOME/.bashrc" "$USER_HOME/.profile" "$USER_HOME/.zshrc"; do
    if [ -f "$rc" ]; then
      if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
        echo "" >> "$rc"
        echo '# Antigravity CLI and User Tools PATH' >> "$rc"
        echo "$path_line" >> "$rc"
        if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
          chown "$ACTUAL_USER:" "$rc" 2>/dev/null || true
        fi
        echo -e "  ${C_GREEN}[✓]${C_RESET} Added ~/.local/bin to $(basename "$rc")"
      else
        echo -e "  ${C_GREEN}[✓]${C_RESET} ~/.local/bin is already configured in $(basename "$rc")"
      fi
    fi
  done

  # 2. If agy exists and root is available, ensure /usr/local/bin/agy symlink
  if [ -x "$USER_HOME/.local/bin/agy" ]; then
    if [ "$EUID" -eq 0 ]; then
      rm -f /usr/local/bin/agy
      ln -sf "$USER_HOME/.local/bin/agy" /usr/local/bin/agy
      echo -e "  ${C_GREEN}[✓]${C_RESET} Linked /usr/local/bin/agy system launcher"
    elif [ -w "/usr/local/bin" ]; then
      rm -f /usr/local/bin/agy
      ln -sf "$USER_HOME/.local/bin/agy" /usr/local/bin/agy 2>/dev/null || true
    fi
  fi

  echo ""
  echo "============================================================"
  echo -e "${C_GREEN}${C_BOLD}PATH configuration complete!${C_RESET}"
  echo ""
  echo "To apply changes to your current terminal window immediately:"
  echo -e "  ${C_CYAN}eval \"\$(update-antigravity env)\"${C_RESET}  (or: ${C_CYAN}source ~/.bashrc${C_RESET})"
  echo "============================================================"

  # If running in an interactive terminal, offer to launch a refreshed shell now
  if [ -t 0 ] && [ -t 1 ]; then
    echo ""
    read -r -p "Would you like to launch a refreshed shell now with the new PATH? [Y/n] " response || response=""
    case "$response" in
      [nN][oO]|[nN])
        echo "Continuing in current shell."
        ;;
      *)
        echo "Launching refreshed shell..."
        local user_shell="${SHELL:-/bin/bash}"
        exec "$user_shell"
        ;;
    esac
  fi
}

# ============================================================
# CLI PERMISSION SANITIZATION
# ============================================================
clean_legacy_permissions() {
  local cli_cfg="$USER_HOME/.gemini/config/config.json"
  if [ -f "$cli_cfg" ] && grep -q 'unsandboxed(' "$cli_cfg" 2>/dev/null; then
    local res
    res=$(python3 -c "
import json, shutil, os, sys
cfg_path = '$cli_cfg'
try:
    if os.path.exists(cfg_path):
        shutil.copyfile(cfg_path, cfg_path + '.bak')
        with open(cfg_path, 'r') as f:
            cfg = json.load(f)
        grants = cfg.get('userSettings', {}).get('globalPermissionGrants', {}).get('allow', [])
        cleaned = [g for g in grants if not g.startswith('unsandboxed(')]
        removed = len(grants) - len(cleaned)
        if removed > 0:
            cfg['userSettings']['globalPermissionGrants']['allow'] = cleaned
            with open(cfg_path, 'w') as f:
                json.dump(cfg, f, indent=2)
            print(f'{removed}')
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || echo "")

    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      chown "$ACTUAL_USER:" "$cli_cfg" "$cli_cfg.bak" 2>/dev/null || true
    fi

    if [ -n "$res" ] && [ "$res" -gt 0 ] 2>/dev/null; then
      echo "    ✓ Cleaned $res deprecated 'unsandboxed' rule(s) from ~/.gemini/config/config.json"
    fi
  fi
}

# ============================================================
# GIT REPOSITORY AUTO-SYNC
# ============================================================
sync_git_repo() {
  # 1. Skip if git sync is disabled by flag, environment variable, or already completed in parent process
  if [ "${NO_GIT:-false}" = true ] || [ "${ANTIGRAVITY_NO_GIT:-0}" = "1" ] || [ "${_ANTIGRAVITY_GIT_SYNCED:-0}" = "1" ]; then
    return 0
  fi

  # 2. Check if git is available
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi

  # 3. Resolve directory containing the canonical script
  local repo_dir
  repo_dir="$(dirname "$SCRIPT_PATH")"

  # 4. Check if directory is inside a Git working tree
  if ! git -c safe.directory="*" -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  # 5. Check if an origin remote exists
  if ! git -c safe.directory="*" -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    return 0
  fi

  # 6. Check for uncommitted local changes
  if ! git -c safe.directory="*" -C "$repo_dir" diff --quiet 2>/dev/null || ! git -c safe.directory="*" -C "$repo_dir" diff --cached --quiet 2>/dev/null; then
    echo -e "${C_DIM}==> Git: Uncommitted local modifications detected; skipping auto-update.${C_RESET}"
    return 0
  fi

  # 7. Identify tracking upstream branch
  local upstream
  upstream=$(git -c safe.directory="*" -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)
  if [ -z "$upstream" ]; then
    if git -c safe.directory="*" -C "$repo_dir" rev-parse --verify origin/main >/dev/null 2>&1; then
      upstream="origin/main"
    elif git -c safe.directory="*" -C "$repo_dir" rev-parse --verify origin/master >/dev/null 2>&1; then
      upstream="origin/master"
    else
      return 0
    fi
  fi

  echo "==> Checking for latest updater script from Git repository..."

  # 8. Fetch from origin with 5-second timeout and batch mode to prevent blocking
  local fetch_ok=false
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    if sudo -u "$ACTUAL_USER" GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o ConnectTimeout=5 -o BatchMode=yes" git -c safe.directory="*" -C "$repo_dir" fetch --quiet origin 2>/dev/null; then
      fetch_ok=true
    fi
  else
    if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o ConnectTimeout=5 -o BatchMode=yes" git -c safe.directory="*" -C "$repo_dir" fetch --quiet origin 2>/dev/null; then
      fetch_ok=true
    fi
  fi

  if [ "$fetch_ok" != true ]; then
    echo -e "${C_DIM}    Notice: Git remote unreachable (offline or SSH unavailable); continuing with local version.${C_RESET}"
    return 0
  fi

  # 9. Compare local HEAD with upstream
  local local_hash upstream_hash base_hash
  local_hash=$(git -c safe.directory="*" -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)
  upstream_hash=$(git -c safe.directory="*" -C "$repo_dir" rev-parse "$upstream" 2>/dev/null || true)

  if [ -z "$local_hash" ] || [ -z "$upstream_hash" ]; then
    return 0
  fi

  if [ "$local_hash" = "$upstream_hash" ]; then
    echo -e "    ${C_GREEN}✓ Updater script is up to date with Git (${local_hash:0:7}).${C_RESET}"
    return 0
  fi

  base_hash=$(git -c safe.directory="*" -C "$repo_dir" merge-base HEAD "$upstream" 2>/dev/null || true)

  if [ "$local_hash" = "$base_hash" ]; then
    # Upstream is ahead: fast-forward merge
    echo -e "==> ${C_CYAN}New version of updater script detected in Git! Pulling updates...${C_RESET}"
    local merge_ok=false
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      if sudo -u "$ACTUAL_USER" git -c safe.directory="*" -C "$repo_dir" merge --ff-only "$upstream" >/dev/null 2>&1; then
        merge_ok=true
      fi
    else
      if git -c safe.directory="*" -C "$repo_dir" merge --ff-only "$upstream" >/dev/null 2>&1; then
        merge_ok=true
      fi
    fi

    if [ "$merge_ok" = true ]; then
      local new_hash
      new_hash=$(git -c safe.directory="*" -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo "latest")
      echo -e "${C_GREEN}✓ Successfully updated updater script to Git commit $new_hash.${C_RESET}"
      echo "==> Re-executing with latest updater script..."
      echo ""
      export _ANTIGRAVITY_GIT_SYNCED=1
      exec bash "$SCRIPT_PATH" "$@"
    else
      echo -e "${C_YELLOW}    Warning: Fast-forward merge failed. Continuing with local version.${C_RESET}"
    fi
  elif [ "$upstream_hash" = "$base_hash" ]; then
    echo -e "${C_DIM}    Notice: Local repository is ahead of Git remote. Continuing.${C_RESET}"
  else
    echo -e "${C_DIM}    Notice: Local repository and Git remote have diverged. Continuing.${C_RESET}"
  fi
}

# 5. Parse Arguments
ORIGINAL_ARGS=("$@")
CHECK_ONLY=false
FORCE=false
PRUNE=false
VERIFY_ONLY=false
REPAIR_MODE=false
FIX_PATH_MODE=false
NO_GIT=false
TARGET_HUB=true
TARGET_IDE=true
TARGET_CLI=true

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--check)
      CHECK_ONLY=true
      shift
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -V|--verify|--doctor)
      VERIFY_ONLY=true
      shift
      ;;
    --repair|--fix)
      REPAIR_MODE=true
      shift
      ;;
    --fix-path)
      FIX_PATH_MODE=true
      shift
      ;;
    env)
      echo "export PATH=\"$USER_HOME/.local/bin:/usr/local/bin:\$PATH\""
      exit 0
      ;;
    -p|--prune|--clean)
      PRUNE=true
      shift
      ;;
    --no-git|--skip-git)
      NO_GIT=true
      shift
      ;;
    -v|--version)
      echo "update-antigravity version $SCRIPT_VERSION"
      exit 0
      ;;
    --hub|--only-hub)
      TARGET_HUB=true
      TARGET_IDE=false
      TARGET_CLI=false
      shift
      ;;
    --ide|--only-ide)
      TARGET_HUB=false
      TARGET_IDE=true
      TARGET_CLI=false
      shift
      ;;
    --cli|--only-cli)
      TARGET_HUB=false
      TARGET_IDE=false
      TARGET_CLI=true
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [OPTIONS]"
      echo ""
      echo "Checks, verifies, repairs, and updates Antigravity suite products on Ubuntu/Linux:"
      echo "  1. Antigravity 2.0 (Desktop App)"
      echo "  2. Antigravity IDE (VS Code-based AI editor)"
      echo "  3. Antigravity CLI (agy)"
      echo ""
      echo "Options:"
      echo "  -c, --check                Check for updates without installing"
      echo "  -f, --force                Reinstall the latest version even if already up to date"
      echo "  -V, --verify, --doctor     Verify health & integrity of current installations"
      echo "      --repair, --fix        Automatically repair permissions, symlinks, and broken files"
      echo "      --fix-path             Add ~/.local/bin to shell profiles and launch refreshed shell"
      echo "  -p, --prune, --clean       Delete outdated cached tarballs and backup folders"
      echo "      --no-git, --skip-git   Skip automatic Git repository synchronization"
      echo "  -v, --version              Show script version ($SCRIPT_VERSION)"
      echo "      --hub, --only-hub      Only check/update Antigravity 2.0"
      echo "      --ide, --only-ide      Only check/update Antigravity IDE"
      echo "      --cli, --only-cli      Only check/update Antigravity CLI"
      echo "  -h, --help                 Show this help message"
      echo ""
      echo "Helper Commands:"
      echo "  eval \"\$(update-antigravity env)\"   Instantly load Antigravity PATH in current terminal"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage."
      exit 1
      ;;
  esac
done

# Auto-sync updater script from Git repository before running any actions
sync_git_repo "${ORIGINAL_ARGS[@]}"

# If fix-path requested, run PATH configuration subsystem
if [ "$FIX_PATH_MODE" = true ]; then
  run_fix_path
  exit 0
fi

# If verify-only, run verification immediately (read-only, no root required)
if [ "$VERIFY_ONLY" = true ]; then
  run_verification
  exit $?
fi

# If repair requested, run repair subsystem
if [ "$REPAIR_MODE" = true ]; then
  run_repair
fi

# Prune operation
if [ "$PRUNE" = true ]; then
  echo "============================================================"
  echo "        Antigravity Suite Cache & Backup Cleanup            "
  echo "============================================================"
  PRUNED_COUNT=0
  for f in "$DOWNLOAD_DIR"/Antigravity-*.tar.gz "$DOWNLOAD_DIR"/Antigravity-IDE-*.tar.gz; do
    if [ -f "$f" ]; then
      echo "  Removing cached archive: $(basename "$f")"
      rm -f "$f"
      PRUNED_COUNT=$((PRUNED_COUNT + 1))
    fi
  done
  if [ -d "/opt/Antigravity.bak" ]; then
    if [ "$EUID" -eq 0 ]; then
      echo "  Removing backup directory: /opt/Antigravity.bak"
      rm -rf "/opt/Antigravity.bak"
      PRUNED_COUNT=$((PRUNED_COUNT + 1))
    else
      echo "  (Run with sudo to remove /opt/Antigravity.bak)"
    fi
  fi
  if [ -d "/opt/Antigravity-IDE.bak" ]; then
    if [ "$EUID" -eq 0 ]; then
      echo "  Removing backup directory: /opt/Antigravity-IDE.bak"
      rm -rf "/opt/Antigravity-IDE.bak"
      PRUNED_COUNT=$((PRUNED_COUNT + 1))
    else
      echo "  (Run with sudo to remove /opt/Antigravity-IDE.bak)"
    fi
  fi
  echo -e "${C_GREEN}✓ Prune completed ($PRUNED_COUNT items cleaned).${C_RESET}"
  exit 0
fi

# Helper: Check free disk space before downloads/extractions
check_disk_space() {
  local target_dir="$1"
  local required_mb="${2:-1024}" # Default 1GB
  if command -v df >/dev/null 2>&1 && [ -d "$target_dir" ]; then
    local avail_mb
    avail_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$required_mb" ]; then
      echo -e "${C_RED}Error: Insufficient disk space on ${target_dir} (${avail_mb}MB available, ${required_mb}MB required).${C_RESET}"
      exit 1
    fi
  fi
}

# Helper: Warn if applications are actively running in memory
check_running_processes() {
  local warned=false
  if pgrep -x "antigravity" >/dev/null 2>&1 || pgrep -f "^/opt/Antigravity/antigravity" >/dev/null 2>&1; then
    echo ""
    echo -e "${C_YELLOW}⚠️  Notice: Antigravity 2.0 is currently running.${C_RESET}"
    echo "    Please restart Antigravity 2.0 to load the newly updated version."
    warned=true
  fi

  if pgrep -x "antigravity-ide" >/dev/null 2>&1 || pgrep -f "^/opt/Antigravity-IDE/antigravity-ide" >/dev/null 2>&1; then
    echo ""
    echo -e "${C_YELLOW}⚠️  Notice: Antigravity IDE is currently running.${C_RESET}"
    echo "    Please restart Antigravity IDE to load the newly updated version."
    warned=true
  fi
}

# Helper: Safe atomic download with .part file and gzip validation
download_archive() {
  local url="$1"
  local dest="$2"
  local tmp_dest="${dest}.part.$$"
  
  rm -f "$tmp_dest"
  curl -fL --progress-bar -o "$tmp_dest" "$url"
  if [ ! -f "$tmp_dest" ]; then
    echo -e "${C_RED}Error: Download failed for $url${C_RESET}"
    exit 1
  fi
  
  if ! tar -tzf "$tmp_dest" >/dev/null 2>&1; then
    echo -e "${C_RED}Error: Downloaded archive is corrupt or incomplete.${C_RESET}"
    rm -f "$tmp_dest"
    exit 1
  fi
  
  mv "$tmp_dest" "$dest"
  chown "$ACTUAL_USER:" "$dest" 2>/dev/null || true
}

# Helper: Remove older version archives of the same product to save disk space
prune_old_archives() {
  local prefix="$1"
  local current_archive="$2"
  for f in "$DOWNLOAD_DIR"/${prefix}-*.tar.gz; do
    if [ -f "$f" ] && [ "$f" != "$current_archive" ]; then
      echo "  Reclaiming space: removing $(basename "$f")"
      rm -f "$f"
    fi
  done
}

echo "============================================================"
echo "          Antigravity Suite Version Checker / Updater        "
echo "============================================================"

NEEDS_UPDATE_HUB=false
NEEDS_UPDATE_IDE=false
NEEDS_UPDATE_CLI=false

# ============================================================
# PRODUCT 1: Antigravity 2.0 (Hub)
# ============================================================
HUB_INSTALLED="none"
HUB_LATEST="unknown"
HUB_URL=""

if [ "$TARGET_HUB" = true ]; then
  echo ""
  echo "--> [1/3] Checking Antigravity 2.0 (Desktop App)..."
  
  if [ -f "$HUB_DIR/resources/app.asar" ]; then
    HUB_INSTALLED=$(python3 -c "
import struct, json
try:
    with open('$HUB_DIR/resources/app.asar', 'rb') as f:
        magic, header_size, inner_size, json_len = struct.unpack('<4I', f.read(16))
        base_offset = 8 + header_size
        header = json.loads(f.read(json_len).decode('utf-8'))
        pkg_entry = header.get('files', {}).get('package.json', {})
        offset = int(pkg_entry.get('offset', 0))
        size = int(pkg_entry.get('size', 0))
        f.seek(base_offset + offset)
        pkg = json.loads(f.read(size).decode('utf-8'))
        print(pkg.get('version', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
  fi
  echo "    Installed: $HUB_INSTALLED"

  HUB_INFO=$(python3 -c "
import urllib.request, urllib.parse, re, gzip, sys

url = 'https://antigravity.google/download'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = resp.read()
        if resp.headers.get('Content-Encoding') == 'gzip':
            data = gzip.decompress(data)
        html = data.decode('utf-8', errors='ignore')

    pattern = rf'https://storage\.googleapis\.com/antigravity-public/antigravity-hub/(([0-9\.]+)-[0-9]+)/$ARCH/Antigravity\.tar\.gz'
    m = re.search(pattern, html)
    if m:
        download_url = urllib.parse.quote(m.group(0), safe=':/?#[]@!$&\'()*+,;=')
        print(f'{m.group(2)}|{download_url}')
        sys.exit(0)
except Exception:
    pass

sys.exit(1)
" 2>/dev/null || true)

  if [ -n "$HUB_INFO" ]; then
    IFS='|' read -r HUB_LATEST HUB_URL <<< "$HUB_INFO"
  else
    HUB_LATEST=$(curl -s --max-time 10 "https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/" | grep -oP 'Stable Version:\s*\K[0-9.]+' || echo "unknown")
  fi
  echo "    Latest:    $HUB_LATEST"

  HUB_CORRUPTED=false
  if [ -d "$HUB_DIR" ] && { [ ! -f "$HUB_DIR/antigravity" ] || ! head -c 4 "$HUB_DIR/antigravity" 2>/dev/null | grep -q 'ELF'; }; then
    HUB_CORRUPTED=true
  fi

  if [ "$HUB_CORRUPTED" = true ]; then
    NEEDS_UPDATE_HUB=true
    echo -e "    Status:    ${C_YELLOW}Corrupted binary detected! Repair required ($HUB_LATEST)${C_RESET}"
  elif [ "$HUB_INSTALLED" = "none" ] || [ "$HUB_INSTALLED" = "unknown" ]; then
    NEEDS_UPDATE_HUB=true
    echo -e "    Status:    ${C_CYAN}Not installed (Update available: $HUB_LATEST)${C_RESET}"
  elif [ "$HUB_INSTALLED" != "$HUB_LATEST" ]; then
    HIGHER_HUB=$(printf "%s\n%s\n" "$HUB_INSTALLED" "$HUB_LATEST" | sort -V | tail -n 1)
    if [ "$HIGHER_HUB" = "$HUB_LATEST" ] || [ "$FORCE" = true ]; then
      NEEDS_UPDATE_HUB=true
      echo -e "    Status:    ${C_CYAN}Update available ($HUB_INSTALLED -> $HUB_LATEST)${C_RESET}"
    else
      echo "    Status:    Installed version is newer than latest stable."
    fi
  else
    if [ "$FORCE" = true ]; then
      NEEDS_UPDATE_HUB=true
      echo "    Status:    Up to date, forcing reinstall (--force)"
    else
      echo -e "    Status:    ${C_GREEN}✓ Up to date ($HUB_INSTALLED)${C_RESET}"
    fi
  fi
fi

# ============================================================
# PRODUCT 2: Antigravity IDE
# ============================================================
IDE_INSTALLED="none"
IDE_LATEST="unknown"
IDE_URL=""
IDE_SHA256=""

if [ "$TARGET_IDE" = true ]; then
  echo ""
  echo "--> [2/3] Checking Antigravity IDE..."
  
  if [ -f "$IDE_DIR/resources/app/product.json" ]; then
    IDE_INSTALLED=$(python3 -c "
import json
try:
    with open('$IDE_DIR/resources/app/product.json') as f:
        data = json.load(f)
        print(data.get('ideVersion', data.get('version', 'unknown')))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
  fi
  echo "    Installed: $IDE_INSTALLED"

  # Query latest IDE version & URL via API (properly URL-encoding spaces)
  IDE_INFO=$(python3 -c "
import urllib.request, urllib.parse, json, re, sys

url = 'https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/api/update/$ARCH/stable/latest'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode('utf-8'))
        raw_url = data.get('url', '')
        m = re.search(r'/stable/([0-9\.]+)(?:-[0-9]+)?/', raw_url)
        version = m.group(1) if m else data.get('name', 'unknown')
        download_url = urllib.parse.quote(raw_url, safe=':/?#[]@!$&\'()*+,;=')
        sha256 = data.get('sha256hash', '')
        print(f'{version}|{download_url}|{sha256}')
        sys.exit(0)
except Exception:
    pass

sys.exit(1)
" 2>/dev/null || true)

  if [ -n "$IDE_INFO" ]; then
    IFS='|' read -r IDE_LATEST IDE_URL IDE_SHA256 <<< "$IDE_INFO"
  else
    IDE_LATEST=$(curl -s --max-time 10 "https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/" | grep -oP 'Stable Version:\s*\K[0-9.]+' || echo "unknown")
  fi
  echo "    Latest:    $IDE_LATEST"

  IDE_CORRUPTED=false
  if [ -d "$IDE_DIR" ] && { [ ! -f "$IDE_DIR/antigravity-ide" ] || ! head -c 4 "$IDE_DIR/antigravity-ide" 2>/dev/null | grep -q 'ELF'; }; then
    IDE_CORRUPTED=true
  fi

  if [ "$IDE_CORRUPTED" = true ]; then
    NEEDS_UPDATE_IDE=true
    echo -e "    Status:    ${C_YELLOW}Corrupted binary detected! Repair required ($IDE_LATEST)${C_RESET}"
  elif [ "$IDE_INSTALLED" = "none" ]; then
    NEEDS_UPDATE_IDE=true
    echo -e "    Status:    ${C_CYAN}Not installed (Available: $IDE_LATEST)${C_RESET}"
  elif [ "$IDE_INSTALLED" = "unknown" ]; then
    NEEDS_UPDATE_IDE=true
    echo -e "    Status:    ${C_YELLOW}Unknown version installed (Update available: $IDE_LATEST)${C_RESET}"
  elif [ "$IDE_INSTALLED" != "$IDE_LATEST" ]; then
    HIGHER_IDE=$(printf "%s\n%s\n" "$IDE_INSTALLED" "$IDE_LATEST" | sort -V | tail -n 1)
    if [ "$HIGHER_IDE" = "$IDE_LATEST" ] || [ "$FORCE" = true ]; then
      NEEDS_UPDATE_IDE=true
      echo -e "    Status:    ${C_CYAN}Update available ($IDE_INSTALLED -> $IDE_LATEST)${C_RESET}"
    else
      echo "    Status:    Installed version is newer than latest stable."
    fi
  else
    if [ "$FORCE" = true ]; then
      NEEDS_UPDATE_IDE=true
      echo "    Status:    Up to date, forcing reinstall (--force)"
    else
      echo -e "    Status:    ${C_GREEN}✓ Up to date ($IDE_INSTALLED)${C_RESET}"
    fi
  fi
fi

# ============================================================
# PRODUCT 3: Antigravity CLI (agy)
# ============================================================
CLI_INSTALLED="none"
CLI_LATEST="unknown"

if [ "$TARGET_CLI" = true ]; then
  echo ""
  echo "--> [3/3] Checking Antigravity CLI (agy)..."
  if [ -n "$AGY_BIN" ]; then
    CLI_INSTALLED=$("$AGY_BIN" --version 2>/dev/null || echo "unknown")
    echo "    Installed: $CLI_INSTALLED ($AGY_BIN)"
  else
    echo "    Installed: none"
  fi

  CLI_PLATFORM="linux_amd64"
  [ "$ARCH" = "linux-arm" ] && CLI_PLATFORM="linux_arm64"

  CLI_INFO=$(python3 -c "
import urllib.request, json, sys
url = 'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/$CLI_PLATFORM.json'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode('utf-8'))
        print(data.get('version', 'unknown'))
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || curl -s --max-time 10 "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/$CLI_PLATFORM.json" | grep -oP '"version":\s*"\K[0-9.]+' || echo "unknown")

  if [ -n "$CLI_INFO" ]; then
    CLI_LATEST="$CLI_INFO"
  fi
  echo "    Latest:    $CLI_LATEST"

  if [ "$CLI_INSTALLED" = "none" ]; then
    echo -e "    Status:    ${C_CYAN}Not installed (Available: $CLI_LATEST)${C_RESET}"
    echo "               Install via: curl -fsSL https://antigravity.google/cli/install.sh | bash"
  elif [ "$CLI_INSTALLED" = "unknown" ]; then
    NEEDS_UPDATE_CLI=true
    echo -e "    Status:    ${C_YELLOW}Unknown version installed (Update available: $CLI_LATEST)${C_RESET}"
  elif [ "$CLI_INSTALLED" != "$CLI_LATEST" ] && [ "$CLI_LATEST" != "unknown" ]; then
    HIGHER_CLI=$(printf "%s\n%s\n" "$CLI_INSTALLED" "$CLI_LATEST" | sort -V | tail -n 1)
    if [ "$HIGHER_CLI" = "$CLI_LATEST" ] || [ "$FORCE" = true ]; then
      NEEDS_UPDATE_CLI=true
      echo -e "    Status:    ${C_CYAN}Update available ($CLI_INSTALLED -> $CLI_LATEST)${C_RESET}"
    else
      echo "    Status:    Installed version is newer than latest stable."
    fi
  else
    if [ "$FORCE" = true ]; then
      NEEDS_UPDATE_CLI=true
      echo "    Status:    Up to date, forcing reinstall (--force)"
    else
      echo -e "    Status:    ${C_GREEN}✓ Up to date ($CLI_INSTALLED)${C_RESET}"
    fi
  fi
fi

echo ""
echo "============================================================"

# If check-only, exit here
if [ "$CHECK_ONLY" = true ]; then
  if [ "$NEEDS_UPDATE_HUB" = true ] || [ "$NEEDS_UPDATE_IDE" = true ] || [ "$NEEDS_UPDATE_CLI" = true ]; then
    echo -e "${C_CYAN}Updates are available! Run without --check to install.${C_RESET}"
    exit 10
  else
    echo -e "${C_GREEN}All selected Antigravity components are up to date.${C_RESET}"
    exit 0
  fi
fi

# Check if any desktop updates needed
if [ "$NEEDS_UPDATE_HUB" = false ] && [ "$NEEDS_UPDATE_IDE" = false ]; then
  echo -e "${C_GREEN}✓ All Antigravity desktop components are up to date.${C_RESET}"
  if [ "$TARGET_CLI" = true ] && [ -n "$AGY_BIN" ]; then
    if [ "$NEEDS_UPDATE_CLI" = true ] || [ "$FORCE" = true ]; then
      echo ""
      echo -e "${C_BOLD}==> Updating CLI (agy)...${C_RESET}"
      if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$ACTUAL_USER" "$AGY_BIN" update 2>/dev/null || su - "$ACTUAL_USER" -s /bin/bash -c "\"$AGY_BIN\" update" || true
      else
        "$AGY_BIN" update || true
      fi
    fi
  fi
  exit 0
fi

# Root elevation for system-wide installation to /opt
if [ "$EUID" -ne 0 ]; then
  echo ""
  echo "==> Root privileges required to install updates to /opt."
  echo "    Prompting for sudo..."
  exec sudo bash "$SCRIPT_PATH" --no-git "$@"
fi

# Check available disk space (at least 1GB in /opt and download dir)
check_disk_space "/opt" 1024
check_disk_space "$DOWNLOAD_DIR" 1024

# Check for Electron GUI runtime libraries (if running on minimal / server Ubuntu)
if command -v ldconfig >/dev/null 2>&1; then
  MISSING_GUI=()
  sys_ld_cache=$(ldconfig -p 2>/dev/null || true)
  grep -q 'libgtk-3\.so' <<< "$sys_ld_cache" || MISSING_GUI+=("libgtk-3-0")
  grep -q 'libnss3\.so' <<< "$sys_ld_cache" || MISSING_GUI+=("libnss3")
  grep -q 'libgbm\.so' <<< "$sys_ld_cache" || MISSING_GUI+=("libgbm1")

  if [ ${#MISSING_GUI[@]} -gt 0 ]; then
    echo "==> Detected missing desktop GUI runtime libraries: ${MISSING_GUI[*]}"
    echo "==> Installing desktop libraries via apt-get..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && (apt-get install -y libgtk-3-0 libnss3 libasound2t64 libgbm1 libsecret-1-0 xdg-utils 2>/dev/null || \
                          apt-get install -y libgtk-3-0 libnss3 libasound2 libgbm1 libsecret-1-0 xdg-utils 2>/dev/null || true)
  fi
fi

mkdir -p "$DOWNLOAD_DIR"
chown "$ACTUAL_USER:" "$DOWNLOAD_DIR" 2>/dev/null || true

# ------------------------------------------------------------
# Perform Antigravity 2.0 Update if needed
# ------------------------------------------------------------
if [ "$NEEDS_UPDATE_HUB" = true ]; then
  echo ""
  echo "============================================================"
  echo "  Installing Antigravity 2.0 ($HUB_LATEST)..."
  echo "============================================================"

  HUB_ARCHIVE="$DOWNLOAD_DIR/Antigravity-$HUB_LATEST.tar.gz"
  NEED_HUB_DOWNLOAD=true
  if [ -f "$HUB_ARCHIVE" ]; then
    if tar -tzf "$HUB_ARCHIVE" >/dev/null 2>&1; then
      echo "==> Using cached archive: $HUB_ARCHIVE"
      NEED_HUB_DOWNLOAD=false
    fi
  fi

  if [ "$NEED_HUB_DOWNLOAD" = true ]; then
    if [ -z "$HUB_URL" ]; then
      echo -e "${C_RED}Error: Could not resolve Antigravity 2.0 download URL.${C_RESET}"
      exit 1
    fi
    echo "==> Downloading Antigravity 2.0 ($HUB_LATEST)..."
    download_archive "$HUB_URL" "$HUB_ARCHIVE"
  fi

  echo "==> Backing up current installation..."
  rm -rf "$HUB_BACKUP_DIR"
  [ -d "$HUB_DIR" ] && mv "$HUB_DIR" "$HUB_BACKUP_DIR"

  EXTRACTED_HUB="/opt/Antigravity-x64"
  [ "$ARCH" = "linux-arm" ] && EXTRACTED_HUB="/opt/Antigravity-arm"
  rm -rf "$EXTRACTED_HUB"

  echo "==> Extracting $HUB_ARCHIVE to /opt..."
  if ! tar -xzf "$HUB_ARCHIVE" -C /opt; then
    echo -e "${C_RED}Error: Failed to extract $HUB_ARCHIVE.${C_RESET}"
    if [ -d "$HUB_BACKUP_DIR" ]; then
      echo "==> Restoring previous installation from backup..."
      rm -rf "$HUB_DIR"
      mv "$HUB_BACKUP_DIR" "$HUB_DIR"
      echo "    ✓ Rollback completed."
    fi
    exit 1
  fi

  if [ -d "$EXTRACTED_HUB" ]; then
    rm -rf "$HUB_DIR"
    mv "$EXTRACTED_HUB" "$HUB_DIR"
  fi

  echo "==> Setting permissions..."
  chown -R root:root "$HUB_DIR"
  chmod 4755 "$HUB_DIR/chrome-sandbox"

  # Extract 512x512 high-res icon from app.asar
  python3 -c "
import struct, json
try:
    with open('$HUB_DIR/resources/app.asar', 'rb') as f:
        magic, header_size, inner_size, json_len = struct.unpack('<4I', f.read(16))
        base_offset = 8 + header_size
        header = json.loads(f.read(json_len).decode('utf-8'))
        entry = header.get('files', {}).get('icon.png', {})
        offset = int(entry.get('offset', 0))
        size = int(entry.get('size', 0))
        f.seek(base_offset + offset)
        data = f.read(size)
        with open('$HUB_DIR/antigravity.png', 'wb') as out:
            out.write(data)
except Exception:
    pass
" 2>/dev/null || true

  # Install icons
  install_desktop_icon "antigravity" "$HUB_DIR/antigravity.png"

  # Launchers & Desktop file
  mkdir -p /usr/local/bin /usr/share/applications

  # Create portable system launcher wrapper for terminal execution
  # Explicitly remove pre-existing file or symlink to prevent writing through a symlink into $HUB_DIR/antigravity
  rm -f /usr/local/bin/antigravity
  cat << LAUNCHER_HUB_EOF > /usr/local/bin/antigravity
#!/usr/bin/env bash
# Antigravity Launcher Wrapper
# Dynamically resolves Wayland/X11 environment and passes optimal flags
EXTRA_FLAGS=()
if [ -n "\${WAYLAND_DISPLAY:-}" ] || [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  EXTRA_FLAGS+=($HUB_DISPLAY_FLAGS)
fi
exec "$HUB_DIR/antigravity" "\${EXTRA_FLAGS[@]}" "\$@"
LAUNCHER_HUB_EOF
  chmod 755 /usr/local/bin/antigravity

  cat << DESKTOP_HUB_EOF > /usr/share/applications/antigravity.desktop
[Desktop Entry]
Name=Antigravity
Comment=Antigravity - Agentic Desktop Application
Exec=$HUB_DIR/antigravity $HUB_DISPLAY_FLAGS %U
Icon=antigravity
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=Antigravity
MimeType=x-scheme-handler/antigravity;
Keywords=antigravity;ai;agent;gemini;code;ide;
DESKTOP_HUB_EOF

  # User-level launchers and desktop entries
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    mkdir -p "$USER_HOME/.local/bin" "$USER_HOME/.local/share/applications"
    rm -f "$USER_HOME/.local/bin/antigravity"
    cp -f /usr/local/bin/antigravity "$USER_HOME/.local/bin/antigravity"
    cp -f /usr/share/applications/antigravity.desktop "$USER_HOME/.local/share/applications/antigravity.desktop"
    chown "$ACTUAL_USER:" "$USER_HOME/.local/bin/antigravity" 2>/dev/null || true
    chown "$ACTUAL_USER:" "$USER_HOME/.local/share/applications/antigravity.desktop" 2>/dev/null || true
  fi

  # Reclaim disk space: prune older Antigravity Hub archives
  prune_old_archives "Antigravity" "$HUB_ARCHIVE"

  echo -e "${C_GREEN}✓ Antigravity 2.0 successfully updated to $HUB_LATEST!${C_RESET}"
fi

# ------------------------------------------------------------
# Perform Antigravity IDE Update if needed
# ------------------------------------------------------------
if [ "$NEEDS_UPDATE_IDE" = true ]; then
  echo ""
  echo "============================================================"
  echo "  Installing Antigravity IDE ($IDE_LATEST)..."
  echo "============================================================"

  IDE_ARCHIVE="$DOWNLOAD_DIR/Antigravity-IDE-$IDE_LATEST.tar.gz"
  NEED_IDE_DOWNLOAD=true
  if [ -f "$IDE_ARCHIVE" ]; then
    if tar -tzf "$IDE_ARCHIVE" >/dev/null 2>&1; then
      echo "==> Using cached archive: $IDE_ARCHIVE"
      NEED_IDE_DOWNLOAD=false
    fi
  fi

  if [ "$NEED_IDE_DOWNLOAD" = true ]; then
    if [ -z "$IDE_URL" ]; then
      echo -e "${C_RED}Error: Could not resolve Antigravity IDE download URL.${C_RESET}"
      exit 1
    fi
    echo "==> Downloading Antigravity IDE ($IDE_LATEST)..."
    download_archive "$IDE_URL" "$IDE_ARCHIVE"
  fi

  # Checksum verification (SHA-256)
  if [ -n "$IDE_SHA256" ] && command -v sha256sum >/dev/null 2>&1; then
    echo "==> Verifying archive checksum (SHA-256)..."
    if ! echo "$IDE_SHA256  $IDE_ARCHIVE" | sha256sum -c - >/dev/null 2>&1; then
      echo -e "${C_RED}Error: SHA-256 checksum verification failed for $IDE_ARCHIVE!${C_RESET}"
      echo "       The archive may be corrupted. Removing cached archive."
      rm -f "$IDE_ARCHIVE"
      exit 1
    fi
    echo "    ✓ Checksum verified"
  fi

  echo "==> Backing up current IDE installation..."
  rm -rf "$IDE_BACKUP_DIR"
  [ -d "$IDE_DIR" ] && mv "$IDE_DIR" "$IDE_BACKUP_DIR"

  rm -rf "/opt/Antigravity IDE"
  echo "==> Extracting $IDE_ARCHIVE to /opt..."
  if ! tar -xzf "$IDE_ARCHIVE" -C /opt; then
    echo -e "${C_RED}Error: Failed to extract $IDE_ARCHIVE.${C_RESET}"
    if [ -d "$IDE_BACKUP_DIR" ]; then
      echo "==> Restoring previous IDE installation from backup..."
      rm -rf "$IDE_DIR"
      mv "$IDE_BACKUP_DIR" "$IDE_DIR"
      echo "    ✓ Rollback completed."
    fi
    exit 1
  fi

  if [ -d "/opt/Antigravity IDE" ]; then
    rm -rf "$IDE_DIR"
    mv "/opt/Antigravity IDE" "$IDE_DIR"
  fi

  echo "==> Setting permissions..."
  chown -R root:root "$IDE_DIR"
  chmod 4755 "$IDE_DIR/chrome-sandbox"

  # Extract IDE Icon
  IDE_ICON_SOURCE="$IDE_DIR/resources/app/resources/linux/code.png"
  if [ -f "$IDE_ICON_SOURCE" ]; then
    cp -f "$IDE_ICON_SOURCE" "$IDE_DIR/antigravity-ide.png"
    install_desktop_icon "antigravity-ide" "$IDE_DIR/antigravity-ide.png"
  fi

  # Symlinks
  mkdir -p /usr/local/bin /usr/share/applications
  rm -f /usr/local/bin/antigravity-ide
  ln -sf "$IDE_DIR/antigravity-ide" /usr/local/bin/antigravity-ide
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    mkdir -p "$USER_HOME/.local/bin"
    rm -f "$USER_HOME/.local/bin/antigravity-ide"
    ln -sf "$IDE_DIR/antigravity-ide" "$USER_HOME/.local/bin/antigravity-ide"
    chown -h "$ACTUAL_USER:" "$USER_HOME/.local/bin/antigravity-ide" 2>/dev/null || true
  fi
  
  # Desktop Entry
  cat << DESKTOP_IDE_EOF > /usr/share/applications/antigravity-ide.desktop
[Desktop Entry]
Name=Antigravity IDE
Comment=Antigravity IDE - AI-First Code Editor
Exec=$IDE_DIR/antigravity-ide %F
Icon=antigravity-ide
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=antigravity-ide
MimeType=text/plain;inode/directory;
Keywords=antigravity;ide;ai;agent;code;vscode;
DESKTOP_IDE_EOF

  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    mkdir -p "$USER_HOME/.local/share/applications"
    cp -f /usr/share/applications/antigravity-ide.desktop "$USER_HOME/.local/share/applications/antigravity-ide.desktop"
    chown "$ACTUAL_USER:" "$USER_HOME/.local/share/applications/antigravity-ide.desktop" 2>/dev/null || true
  fi

  # Reclaim disk space: prune older Antigravity IDE archives
  prune_old_archives "Antigravity-IDE" "$IDE_ARCHIVE"

  echo -e "${C_GREEN}✓ Antigravity IDE successfully installed/updated to $IDE_LATEST!${C_RESET}"
  echo "  Run 'antigravity-ide' or launch from your application menu."
fi

# Refresh desktop and icon databases
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
  if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/share/applications" ]; then
    update-desktop-database "$USER_HOME/.local/share/applications" 2>/dev/null || true
  fi
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
  if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/share/icons/hicolor" ]; then
    gtk-update-icon-cache -f -t "$USER_HOME/.local/share/icons/hicolor" 2>/dev/null || true
  fi
fi

if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  chown -R "$ACTUAL_USER:" "$USER_HOME/.local/share/icons" "$USER_HOME/.local/share/applications" 2>/dev/null || true
fi

# ------------------------------------------------------------
# Perform CLI Update
# ------------------------------------------------------------
if [ "$TARGET_CLI" = true ]; then
  echo ""
  echo "============================================================"
  echo "  Checking Antigravity CLI (agy)..."
  echo "============================================================"
  if [ -n "$AGY_BIN" ]; then
    if [ "$NEEDS_UPDATE_CLI" = true ] || [ "$FORCE" = true ]; then
      echo -e "${C_BOLD}==> Updating CLI ($AGY_BIN)...${C_RESET}"
      if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$ACTUAL_USER" "$AGY_BIN" update 2>/dev/null || su - "$ACTUAL_USER" -s /bin/bash -c "\"$AGY_BIN\" update" || true
      else
        "$AGY_BIN" update || true
      fi
    else
      echo -e "${C_GREEN}✓ CLI (agy) is already up to date ($CLI_INSTALLED).${C_RESET}"
    fi
  else
    echo "Antigravity CLI (agy) is not installed."
    echo "To install the CLI, run: curl -fsSL https://antigravity.google/cli/install.sh | bash"
  fi
fi

# Ensure update-antigravity and agy commands are registered in PATH
if [ "$EUID" -eq 0 ] && [ -f "$SCRIPT_PATH" ]; then
  ln -sf "$SCRIPT_PATH" /usr/local/bin/update-antigravity 2>/dev/null || true
fi
if [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME/.local/bin" ] && [ -f "$SCRIPT_PATH" ]; then
  ln -sf "$SCRIPT_PATH" "$USER_HOME/.local/bin/update-antigravity" 2>/dev/null || true
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown -h "$ACTUAL_USER:" "$USER_HOME/.local/bin/update-antigravity" 2>/dev/null || true
  fi
fi

if [ "$EUID" -eq 0 ] && [ -x "$USER_HOME/.local/bin/agy" ]; then
  ln -sf "$USER_HOME/.local/bin/agy" /usr/local/bin/agy 2>/dev/null || true
fi

# Ensure ~/.local/bin is in shell rc files if missing from PATH
if [ -n "${USER_HOME:-}" ] && [ "$ACTUAL_USER" != "root" ] && [ -d "$USER_HOME/.local/bin" ]; then
  for rc in "$USER_HOME/.bashrc" "$USER_HOME/.profile" "$USER_HOME/.zshrc"; do
    if [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
      echo "" >> "$rc"
      echo '# Antigravity CLI PATH' >> "$rc"
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
      chown "$ACTUAL_USER:" "$rc" 2>/dev/null || true
    fi
  done
fi

# Clean deprecated permission rules in CLI configuration if present
clean_legacy_permissions

# Check and warn if apps are actively running
check_running_processes

echo ""
echo "============================================================"
echo -e "${C_GREEN}${C_BOLD}          All Antigravity components are up to date!         ${C_RESET}"
echo "============================================================"
