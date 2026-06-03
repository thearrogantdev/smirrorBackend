#!/usr/bin/env bash
set -euo pipefail

BACKEND_REPO="thearrogantdev/smirrorBackend"
FRONTEND_REPO="thearrogantdev/smirrorFrontend"
WEBAPP_REPO="thearrogantdev/smirrorApp"

BRANCH="main"
INSTALLER_PATH="scripts/smirror-installer"
INSTALLER_URL="https://raw.githubusercontent.com/${BACKEND_REPO}/${BRANCH}/${INSTALLER_PATH}"

# ==============================================================================
# DYNAMIC UNICODE/EMOJI DETECTION
# ==============================================================================
USE_EMOJI=false

# Check if stdout is a TTY (terminal) AND if the locale supports UTF-8
if [[ -t 1 ]]; then
    if [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]] || \
       [[ "${LANG:-}" == *".UTF-8"* ]] || \
       [[ "${LC_ALL:-}" == *".UTF-8"* ]]; then
        USE_EMOJI=true
    fi
fi

# Define status indicators based on terminal capabilities
if $USE_EMOJI; then
    STATUS_OK="✅"
    STATUS_ERR="❌"
    STATUS_WARN="⚠️ "
else
    STATUS_OK="[  OK  ]"
    STATUS_ERR="[ ERROR ]"
    STATUS_WARN="[WARNING]"
fi
# ==============================================================================

if [[ $EUID -ne 0 ]]; then echo "$STATUS_ERR Run with sudo"; exit 1; fi

echo "==> Installing dependencies"
apt-get update
apt-get install -y eatmydata
eatmydata apt-get install -y curl jq unzip rsync \
  libdrm2 libgbm1 libegl1 libgles2 libgl1-mesa-dri \
  libinput10 libxkbcommon0 libudev1 libsystemd0 libasound2 \
  libglib2.0-0 libpixman-1-0 fontconfig \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad \
  gstreamer1.0-libav gstreamer1.0-alsa

echo "==> Flushing write cache to SD card..."
sync

echo "=================================================="
echo "==> Building and Installing pigpio Daemon from Source"
echo "=================================================="
TMP_PIGPIO=$(mktemp -d)

# Download the v79 archive
curl -fsSL "https://github.com/joan2937/pigpio/archive/refs/tags/v79.tar.gz" -o "$TMP_PIGPIO/pigpio.tar.gz"
tar -xf "$TMP_PIGPIO/pigpio.tar.gz" -C "$TMP_PIGPIO" --strip-components=1

cd "$TMP_PIGPIO"

# CRITICAL FIX: Delete the Python setup.py lines from the Makefile
# so we don't crash on Python 3.12+ (we only need the C++ binaries!)
sed -i '/setup.py/d' Makefile

# Compile and Install the C++ binaries
make -j$(nproc)
make install

# Manually copy the systemd service file to the correct directory
cp util/pigpiod.service /etc/systemd/system/

# Fix the executable path inside the service file (from /usr/bin to /usr/local/bin)
sed -i 's|/usr/bin/pigpiod|/usr/local/bin/pigpiod|g' /etc/systemd/system/pigpiod.service

# Reload systemd and start the daemon
systemctl daemon-reload
systemctl enable pigpiod
systemctl start pigpiod

# Clean up the temp folder
rm -rf "$TMP_PIGPIO"

echo "==> Creating smirror user"
id -u smirror &>/dev/null || useradd -r -m -s /usr/sbin/nologin smirror
# allow the smirror user to communicate with all kinds of hardware. You can change the WANTED_GROUPS when you already
# know what services you exactly need
echo "==> Granting hardware group permissions..."
WANTED_GROUPS=("video" "input" "render" "audio" "tty" "gpio" "i2c" "spi" "dialout" "bluetooth" "netdev" "plugdev")
for g in "${WANTED_GROUPS[@]}"; do
    if getent group "$g" >/dev/null 2>&1; then
        usermod -aG "$g" smirror
    fi
done

echo "==> Creating directories"
mkdir -p /opt/smirror/bin /opt/smirror/versions
mkdir -p /var/lib/smirror/frontend/versions /var/lib/smirror/webapp/versions /var/lib/smirror/db
mkdir -p /var/cache/smirror/downloads
chown root:root /opt/smirror; chmod 755 /opt/smirror /opt/smirror/bin
chown -R smirror:smirror /var/lib/smirror /var/cache/smirror

echo "==> Installing privileged installer"
curl -fsSL "$INSTALLER_URL" -o /opt/smirror/bin/smirror-installer
chown root:root /opt/smirror/bin/smirror-installer
chmod 755 /opt/smirror/bin/smirror-installer

cat >/etc/sudoers.d/smirror-installer <<'EOF'
smirror ALL=(root) NOPASSWD: /opt/smirror/bin/smirror-installer *
EOF
chmod 440 /etc/sudoers.d/smirror-installer

echo "==> Creating systemd service"
cat >/etc/systemd/system/smirror.service <<'EOF'
[Unit]
Description=SMirror Smart Mirror Service
After=network-online.target
Wants=network-online.target
[Service]
User=smirror
Group=smirror
WorkingDirectory=/var/lib/smirror
ExecStart=/opt/smirror/current/bin/smirror
Restart=always
RestartSec=3
ReadWritePaths=/var/lib/smirror /var/cache/smirror
#Will set to strict when the current folder structer is battle-proven and we can set all the rules
#ProtectSystem=strict
ProtectSystem=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable smirror.service

[[ -L /opt/smirror/current ]] || ln -sfn versions /opt/smirror/current

echo "=================================================="
echo "==> Detecting Hardware and Target Architecture"
echo "=================================================="
ARCH=$(uname -m)
ARCH_SUFFIX=""
UI_ARCH_SUFFIX=""

if [[ "$ARCH" == "aarch64" ]]; then
  if [[ -f /sys/firmware/devicetree/base/model ]]; then
    MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
    echo "Detected device: $MODEL"

    if [[ "$MODEL" == *"Raspberry Pi 5"* ]]; then
      ARCH_SUFFIX="aarch64-pi5"
      UI_ARCH_SUFFIX="aarch64-pi4" # Fallback to Pi4 UI since Pi5 UI doesn't exist yet
    elif [[ "$MODEL" == *"Raspberry Pi 4"* ]] || [[ "$MODEL" == *"Raspberry Pi 400"* ]] || [[ "$MODEL" == *"Compute Module 4"* ]]; then
      ARCH_SUFFIX="aarch64-pi4"
      UI_ARCH_SUFFIX="aarch64-pi4"
    else
      ARCH_SUFFIX="aarch64"
      UI_ARCH_SUFFIX="aarch64-generic"
    fi
  else
    ARCH_SUFFIX="aarch64"
    UI_ARCH_SUFFIX="aarch64-generic"
  fi
else
  echo "$STATUS_ERR Unsupported arch $ARCH"; exit 1
fi

echo "Backend architecture suffix: $ARCH_SUFFIX"
echo "Frontend architecture suffix: $UI_ARCH_SUFFIX"


echo "=================================================="
echo "==> 1. Installing Backend"
echo "=================================================="
JSON_FILE="update-back-${ARCH_SUFFIX}.json"
MANIFEST_URL="https://github.com/${BACKEND_REPO}/releases/latest/download/${JSON_FILE}"
TMP=$(mktemp -d)

if ! curl -sSfL "$MANIFEST_URL" -o "$TMP/update.json"; then
  echo "$STATUS_ERR No backend manifest ($JSON_FILE) found in latest release. Aborting."
  rm -rf "$TMP"
  exit 1
fi

VER=$(jq -r '.version' "$TMP/update.json")
ZIP_URL=$(jq -r '.url' "$TMP/update.json")
EXPECTED_SHA=$(jq -r '.sha256' "$TMP/update.json")

echo "$STATUS_OK Found Backend version $VER"
curl -fSL "$ZIP_URL" -o "$TMP/backend.zip"

ACTUAL_SHA=$(sha256sum "$TMP/backend.zip" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "$STATUS_ERR Backend SHA256 checksum mismatch! Aborting."
    rm -rf "$TMP"
    exit 1
fi

STAGE="/var/cache/smirror/downloads/backend-$VER"
rm -rf "$STAGE"
mkdir -p "$STAGE"
unzip (q) -o "$TMP/backend.zip" -d "$STAGE"
chown -R smirror:smirror "$STAGE"

DEFAULT_CFG="$STAGE/bin/config.default.toml"
mkdir -p /etc/smirror
chown root:smirror /etc/smirror
chmod 775 /etc/smirror

if [[ ! -f /etc/smirror/config.toml && -f "$DEFAULT_CFG" ]]; then
  cp "$DEFAULT_CFG" /etc/smirror/config.toml
  chown root:smirror /etc/smirror/config.toml
  chmod 660 /etc/smirror/config.toml
  echo "Seeded /etc/smirror/config.toml from version $VER"
fi

# Run the installer script to link the backend into /opt/smirror
/opt/smirror/bin/smirror-installer "$STAGE" "$VER"
rm -rf "$TMP"


echo "=================================================="
echo "==> 2. Installing Frontend"
echo "=================================================="
UI_JSON_FILE="update-ui-${UI_ARCH_SUFFIX}.json"
UI_MANIFEST_URL="https://github.com/${FRONTEND_REPO}/releases/latest/download/${UI_JSON_FILE}"
TMP_UI=$(mktemp -d)

if ! curl -sSfL "$UI_MANIFEST_URL" -o "$TMP_UI/update-ui.json"; then
  echo "$STATUS_WARN No frontend manifest ($UI_JSON_FILE) found. Skipping frontend install."
else
  UI_VER=$(jq -r '.version' "$TMP_UI/update-ui.json")
  UI_ZIP_URL=$(jq -r '.url' "$TMP_UI/update-ui.json")
  UI_EXPECTED_SHA=$(jq -r '.sha256' "$TMP_UI/update-ui.json")

  echo "$STATUS_OK Found Frontend version $UI_VER"
  curl -fSL "$UI_ZIP_URL" -o "$TMP_UI/frontend.zip"

  UI_ACTUAL_SHA=$(sha256sum "$TMP_UI/frontend.zip" | awk '{print $1}')
  if [[ "$UI_ACTUAL_SHA" != "$UI_EXPECTED_SHA" ]]; then
      echo "$STATUS_ERR Frontend SHA256 checksum mismatch! Aborting."
      rm -rf "$TMP_UI"
      exit 1
  fi

  echo "==> Extracting Frontend to /var/lib/smirror/frontend/versions/$UI_VER"
  UI_DST="/var/lib/smirror/frontend/versions/$UI_VER"
  rm -rf "$UI_DST"
  mkdir -p "$UI_DST"
  unzip -q -o "$TMP_UI/frontend.zip" -d "$UI_DST"

  # Ensure proper ownership so the backend can read it
  chown -R smirror:smirror "/var/lib/smirror/frontend"

  echo "==> Linking Frontend..."
  # Atomically update the current symlink for the frontend
  ln -sfn "versions/$UI_VER" "/var/lib/smirror/frontend/current"
fi
rm -rf "$TMP_UI"


echo "=================================================="
echo "==> 3. Installing Webapp"
echo "=================================================="
WEB_JSON_FILE="update-app-web.json"
WEB_MANIFEST_URL="https://github.com/${WEBAPP_REPO}/releases/latest/download/${WEB_JSON_FILE}"
TMP_WEB=$(mktemp -d)

if ! curl -sSfL "$WEB_MANIFEST_URL" -o "$TMP_WEB/update-web.json"; then
  echo "$STATUS_WARN No webapp manifest ($WEB_JSON_FILE) found. Skipping webapp install."
else
  WEB_VER=$(jq -r '.version' "$TMP_WEB/update-web.json")
  WEB_ZIP_URL=$(jq -r '.url' "$TMP_WEB/update-web.json")
  WEB_EXPECTED_SHA=$(jq -r '.sha256' "$TMP_WEB/update-web.json")

  echo "$STATUS_OK Found Webapp version $WEB_VER"
  curl -fSL "$WEB_ZIP_URL" -o "$TMP_WEB/webapp.zip"

  WEB_ACTUAL_SHA=$(sha256sum "$TMP_WEB/webapp.zip" | awk '{print $1}')
  if [[ "$WEB_ACTUAL_SHA" != "$WEB_EXPECTED_SHA" ]]; then
      echo "$STATUS_ERR Webapp SHA256 checksum mismatch! Aborting."
      rm -rf "$TMP_WEB"
      exit 1
  fi

  echo "==> Extracting Webapp to /var/lib/smirror/webapp/versions/$WEB_VER"
  WEB_DST="/var/lib/smirror/webapp/versions/$WEB_VER"
  rm -rf "$WEB_DST"
  mkdir -p "$WEB_DST"
  unzip -q -o "$TMP_WEB/webapp.zip" -d "$WEB_DST"

  # Ensure proper ownership so the backend can serve it
  chown -R smirror:smirror "/var/lib/smirror/webapp"

  echo "==> Linking Webapp (live)..."
  # Atomically update the "live" symlink for the webapp
  ln -sfn "versions/$WEB_VER" "/var/lib/smirror/webapp/live"
  chown -h smirror:smirror "/var/lib/smirror/webapp/live"
fi
rm -rf "$TMP_WEB"


echo "=================================================="
echo "==> 4. Starting SMirror Service"
echo "=================================================="
systemctl start smirror
systemctl status smirror --no-pager