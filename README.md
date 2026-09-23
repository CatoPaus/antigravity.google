# Antigravity Suite Updater for Ubuntu / Linux

A portable, automated version checker and updater for the entire Google Antigravity developer suite on Ubuntu and Debian-based systems.

---

## Supported Products & Components

| Product | Type | Install Path | Command / Launcher | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Antigravity 2.0 (Hub)** | Desktop Agent Application | `/opt/Antigravity` | `antigravity` | Central desktop application for managing AI agents, project workspaces, workflows, and browser sessions. |
| **Antigravity IDE** | AI-First Code Editor | `/opt/Antigravity-IDE` | `antigravity-ide` | Advanced code editor based on VS Code with native Google Antigravity AI pair-programming and terminal integration. |
| **Antigravity CLI** | Terminal Agent Interface | `~/.local/bin/agy` | `agy` | Command-line interface (`agy`) for running agentic tasks, headless automation, shell interactions, and subagents. |

---

## Quick Start

### 1. Run the Updater
Run from anywhere in your terminal:

```bash
update-antigravity
```

*(Or run the script directly: `bash ~/Downloads/update_antigravity.sh`)*

* **Safe & Non-Destructive:** If all components are up to date, it confirms your current versions and exits without modifying anything or prompting for elevated privileges.
* **Automated Installation:** If an update or missing component is detected, it prompts for `sudo`, downloads the official release, creates an automatic backup of the existing installation, extracts the new version to `/opt`, restores permissions, and refreshes desktop launchers and icons.
* **User Context Preservation:** When updating the user-level CLI (`agy`), the script executes the update as the regular invoking user, preserving user configurations and permissions.

---

### 2. Check for Updates Only (No Changes)
To inspect installed vs. latest upstream versions without downloading, prompting for `sudo`, or installing anything:

```bash
update-antigravity --check
```

Example output:
```text
============================================================
          Antigravity Suite Version Checker / Updater        
============================================================

--> [1/3] Checking Antigravity 2.0 (Desktop App)...
    Installed: 2.14.0
    Latest:    2.14.0
    Status:    ✓ Up to date (2.14.0)

--> [2/3] Checking Antigravity IDE...
    Installed: 2.5.5
    Latest:    2.5.5
    Status:    ✓ Up to date (2.5.5)

--> [3/3] Checking Antigravity CLI (agy)...
    Installed: 1.2.5 (/home/old/.local/bin/agy)
    (Run without --check to auto-update CLI)

============================================================
All selected Antigravity components are up to date.
```

---

## Command-Line Options

| Option | Shorthand | Aliases | Description |
| :--- | :--- | :--- | :--- |
| `--check` | `-c` | | Inspect versions without downloading or modifying files. Exits with code `10` if updates are available, `0` if all are current. |
| `--verify` | `-V` | `--doctor` | Run comprehensive health and integrity checks on all installed components (binaries, sandbox, symlinks, libraries, permissions). |
| `--repair` | | `--fix` | Automatically repair corrupted binaries, incorrect sandbox permissions, broken symlinks, missing icons, and permission issues. |
| `--force` | `-f` | | Force re-download and reinstall even if already at the latest version (useful for repairing corrupted installations). |
| `--prune` | `-p` | `--clean` | Delete outdated cached tarballs from `~/Downloads` and remove `/opt/*.bak` folders. |
| `--version` | `-v` | | Display script version. |
| `--hub` | | `--only-hub` | Target only **Antigravity 2.0 (Hub)** desktop application. |
| `--ide` | | `--only-ide` | Target only **Antigravity IDE** code editor. |
| `--cli` | | `--only-cli` | Target only **Antigravity CLI (`agy`)**. |
| `--help` | `-h` | | Display help and usage information. |

### Usage Examples:
```bash
# Verify health and integrity of all installations across the system:
update-antigravity --verify
# Or using the alias:
update-antigravity --doctor

# Automatically repair detected issues (SUID sandbox, bad symlinks, permissions):
update-antigravity --repair

# Check if any updates are available across all components:
update-antigravity --check

# Target only the IDE (update if needed):
update-antigravity --ide
# Or using the alias:
update-antigravity --only-ide

# Target only the Desktop Hub (Antigravity 2.0):
update-antigravity --hub
# Or using the alias:
update-antigravity --only-hub

# Check only the CLI without modifying:
update-antigravity --check --only-cli

# Force repair/reinstallation of the IDE:
update-antigravity --force --only-ide

# Force re-download and clean reinstall of all desktop components:
update-antigravity --force
```

### Exit Codes (Automation & CI/CD):
* **`0`**: Success. All selected components are up to date, or update completed successfully.
* **`10`**: Updates available (returned only when running in `--check` / `-c` mode when desktop updates are pending).
* **`1`**: Error occurred (e.g., unsupported CPU architecture, missing network connectivity, or invalid options).

---

## Key Features & Architecture

1. **Smart Version Resolution & Binary Inspection:**
   * **Antigravity 2.0:** Parses the Electron `resources/app.asar` archive directly using binary header unpacking to read the true installed `package.json` version. Resolves upstream versions against the official Google Cloud storage release manifest.
   * **Antigravity IDE:** Reads `resources/app/product.json` to obtain `ideVersion`. Queries the official auto-updater API with proper URL-encoding and SHA256 metadata verification.
   * **Antigravity CLI:** Dynamically queries `agy --version`, checks against Google's official release manifests (`linux_amd64` / `linux_arm64`), and runs non-root self-updates via `agy update`.

2. **Self-Healing Dependencies:**
   * Automatically detects and installs base utility tools (`curl`, `python3`, `tar`, `ca-certificates`) via `apt-get` if missing on minimal Ubuntu systems.
   * Checks `ldconfig` for required Electron GUI runtime libraries (`libgtk-3-0`, `libnss3`, `libasound2` / `libasound2t64`, `libgbm1`, `libsecret-1-0`, `xdg-utils`) and installs them automatically on headless or minimal server environments.

3. **Automatic Architecture Detection:**
   * Dynamically resolves machine architecture via `uname -m`:
     * `x86_64` &rarr; `linux-x64` (Intel / AMD 64-bit)
     * `aarch64` / `arm64` &rarr; `linux-arm` (ARM 64-bit)
   * Fetches the matching official Google release binaries without manual user intervention.

4. **Archive Integrity & Smart Caching:**
   * Checks `~/Downloads/` (or `/tmp/antigravity-downloads`) before downloading. If a valid, non-corrupted archive for the target version already exists (`tar -tzf`), the script uses the cached file to save bandwidth and time.
   * Downloads are performed with `curl` progress reporting and file ownership is preserved for the real invoking user.

5. **High-Resolution Desktop Icons & Launcher Integration:**
   * **Antigravity 2.0:** Extracts the official 512x512 RGBA icon directly from `app.asar` without external dependencies.
   * **Antigravity IDE:** Bundles and installs the official high-resolution icon (`code.png`).
   * Registers icons into `/usr/share/pixmaps/`, `/usr/share/icons/hicolor/512x512/apps/`, and user-level icon directories (`~/.local/share/icons/`).
   * Configures standardized `.desktop` files in both `/usr/share/applications/` and `~/.local/share/applications/` with MIME associations, window class matching, and category tags.
   * Automatically triggers `update-desktop-database` and `gtk-update-icon-cache` for instant recognition in GNOME Dash and Ubuntu Dock.

6. **Ubuntu 24.04+ (Noble Numbat) AppArmor Sandbox Fix:**
   * Automatically sets `root:root` ownership and SUID permissions (`chmod 4755 .../chrome-sandbox`) on Electron sandbox binaries. This prevents startup failures caused by unprivileged user namespace restrictions in newer Linux kernels.

7. **Safe In-Place Backups:**
   * Before updating or replacing existing installations, the script moves current directories to backups (`/opt/Antigravity.bak` and `/opt/Antigravity-IDE.bak`), preventing downtime in the event of extraction issues.

8. **User and Privilege Isolation:**
   * Resolves the actual user via `SUDO_USER` and `getent passwd`.
   * CLI updates (`agy update`) and user desktop shortcuts are created with the appropriate non-root ownership, preventing root-owned files in user home directories.
   * Root elevation is deferred: checking versions (`--check`) requires zero elevated permissions.

---

## Deploying on Another Machine (Clean-Slate Ubuntu)

### What Files to Copy?
You only need to copy **one script**:
* `update_antigravity.sh` *(and optionally `README.md` for reference)*

> [!NOTE]
> You do **not** need to manually copy the installed application directories (`/opt/Antigravity`), desktop files, or icons. The script is completely self-sufficient: it auto-installs prerequisites, downloads matching architecture packages, extracts high-res icons, and registers desktop entries.

#### Optional: Pre-caching Archives for Offline / Low-Bandwidth Setup
If the target machine has slow, metered, or restricted internet, you can pre-copy downloaded tarballs into the user's `~/Downloads/` directory:
* `~/Downloads/Antigravity-<version>.tar.gz`
* `~/Downloads/Antigravity-IDE-<version>.tar.gz`

The script will automatically detect and verify these cached archives and skip downloading.

---

### Step-by-Step Setup on a New Machine

1. **Copy the script to the target machine:**
   ```bash
   scp ~/Downloads/update_antigravity.sh user@target-machine:~/
   ```

2. **Make it executable:**
   ```bash
   chmod +x ~/update_antigravity.sh
   ```

3. **Install Antigravity Suite:**
   ```bash
   ~/update_antigravity.sh
   ```
   *(The script will prompt for `sudo` when needed for installing to `/opt` and `/usr/share`.)*

4. **(Recommended) Add `update-antigravity` command to PATH:**
   ```bash
   mkdir -p ~/.local/bin
   ln -sf ~/Downloads/update_antigravity.sh ~/.local/bin/update-antigravity
   ```
   Ensure `~/.local/bin` is in your `$PATH` (standard on Ubuntu). You can now run `update-antigravity` from any directory.

---

## File System Reference

| Resource | Path |
| :--- | :--- |
| **Updater Script** | `~/Downloads/update_antigravity.sh` |
| **Updater Command Symlink** | `~/.local/bin/update-antigravity` |
| **Antigravity 2.0 (Hub) Dir** | `/opt/Antigravity` |
| **Antigravity IDE Dir** | `/opt/Antigravity-IDE` |
| **System Binaries** | `/usr/local/bin/antigravity`, `/usr/local/bin/antigravity-ide` |
| **User Binaries** | `~/.local/bin/antigravity`, `~/.local/bin/antigravity-ide`, `~/.local/bin/agy` |
| **System Desktop Launchers** | `/usr/share/applications/antigravity.desktop`, `/usr/share/applications/antigravity-ide.desktop` |
| **User Desktop Launchers** | `~/.local/share/applications/antigravity.desktop`, `~/.local/share/applications/antigravity-ide.desktop` |
| **System Icons** | `/usr/share/pixmaps/antigravity.png`, `/usr/share/pixmaps/antigravity-ide.png`, `/usr/share/icons/hicolor/512x512/apps/` |
| **User Icons** | `~/.local/share/icons/hicolor/512x512/apps/` |
| **Installation Backups** | `/opt/Antigravity.bak`, `/opt/Antigravity-IDE.bak` |
| **Download Cache** | `~/Downloads/` (fallback: `/tmp/antigravity-downloads`) |
