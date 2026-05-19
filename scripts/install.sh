#!/usr/bin/env bash
set -euo pipefail

BACKEND_REPO="thearrogantdev/smirrorBackend"
FRONTEND_REPO="thearrogantdev/smirrorFrontend"

BRANCH="main"
INSTALLER_PATH="scripts/smirror-installer"
# Assuming the installer script lives in your Backend repo, adjust if needed
INSTALLER_URL="https://raw.githubusercontent.com/${BACKEND_REPO}/${BRANCH}/${INSTALLER_PATH}"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

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

echo "==> Creating smirror user"
id -u smirror &>/dev/null || useradd -r -m -s /usr/sbin/nologin smirror
usermod -aG video,input,render,audio,tty,gpio smirror

echo "==> Creating directories"
mkdir -p /opt/smirror/bin /opt/smirror/versions
mkdir -p /var/lib/smirror/frontend/versions /var/lib/smirror/db
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
ProtectSystem=strict
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
  echo "Unsupported arch $ARCH"; exit 1
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
  echo "❌ No backend manifest ($JSON_FILE) found in latest release. Aborting."
  rm -rf "$TMP"
  exit 1
fi

VER=$(jq -r '.version' "$TMP/update.json")
ZIP_URL=$(jq -r '.url' "$TMP/update.json")
EXPECTED_SHA=$(jq -r '.sha256' "$TMP/update.json")

echo "✅ Found Backend version $VER"
curl -L "$ZIP_URL" -o "$TMP/backend.zip"

ACTUAL_SHA=$(sha256sum "$TMP/backend.zip" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "ERROR: Backend SHA256 checksum mismatch! Aborting."
    rm -rf "$TMP"
    exit 1
fi

STAGE="/var/cache/smirror/downloads/backend-$VER"
mkdir -p "$STAGE"
unzip -q "$TMP/backend.zip" -d "$STAGE"
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
  echo "⚠️ No frontend manifest ($UI_JSON_FILE) found. Skipping frontend install."
else
  UI_VER=$(jq -r '.version' "$TMP_UI/update-ui.json")
  UI_ZIP_URL=$(jq -r '.url' "$TMP_UI/update-ui.json")
  UI_EXPECTED_SHA=$(jq -r '.sha256' "$TMP_UI/update-ui.json")

  echo "✅ Found Frontend version $UI_VER"
  curl -L "$UI_ZIP_URL" -o "$TMP_UI/frontend.zip"

  UI_ACTUAL_SHA=$(sha256sum "$TMP_UI/frontend.zip" | awk '{print $1}')
  if [[ "$UI_ACTUAL_SHA" != "$UI_EXPECTED_SHA" ]]; then
      echo "ERROR: Frontend SHA256 checksum mismatch! Aborting."
      rm -rf "$TMP_UI"
      exit 1
  fi

  echo "==> Extracting Frontend to /var/lib/smirror/frontend/versions/$UI_VER"
  UI_DST="/var/lib/smirror/frontend/versions/$UI_VER"
  mkdir -p "$UI_DST"
  unzip -q "$TMP_UI/frontend.zip" -d "$UI_DST"

  # Ensure proper ownership so the backend can read it
  chown -R smirror:smirror "/var/lib/smirror/frontend"

  echo "==> Linking Frontend..."
  # Atomically update the current symlink for the frontend
  ln -sfn "versions/$UI_VER" "/var/lib/smirror/frontend/current"
fi
rm -rf "$TMP_UI"


echo "=================================================="
echo "==> 3. Starting SMirror Service"
echo "=================================================="
systemctl start smirror
systemctl status smirror --no-pager