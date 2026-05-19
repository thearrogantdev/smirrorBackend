#!/usr/bin/env bash
set -euo pipefail

REPO="thearrogantdev/smirrorBackend/"
BRANCH="main"
INSTALLER_PATH="scripts/smirror-installer"
INSTALLER_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${INSTALLER_PATH}"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

echo "==> Installing backend utilities"
apt-get install -y curl jq unzip rsync

echo "==> Installing flutter-pi graphics & input runtime"
apt-get install -y libdrm2 libgbm1 libegl1 libgles2 libgl1-mesa-dri \
  libinput10 libxkbcommon0 libudev1 libsystemd0 libasound2 \
  libglib2.0-0 libpixman-1-0 fontconfig

echo "==> Installing flutter-pi media plugins (GStreamer)"
apt-get install -y gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad gstreamer1.0-libav \
  gstreamer1.0-alsa

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
[[ -L /var/lib/smirror/frontend/current ]] || ln -sfn versions /var/lib/smirror/frontend/current

echo "==> Detecting Hardware and Target Architecture"
ARCH=$(uname -m)
ARCH_SUFFIX=""

if [[ "$ARCH" == "aarch64" ]]; then
  if [[ -f /sys/firmware/devicetree/base/model ]]; then
    MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
    echo "Detected device: $MODEL"

    if [[ "$MODEL" == *"Raspberry Pi 5"* ]]; then
      ARCH_SUFFIX="aarch64-pi5"
    elif [[ "$MODEL" == *"Raspberry Pi 4"* ]] || [[ "$MODEL" == *"Raspberry Pi 400"* ]] || [[ "$MODEL" == *"Compute Module 4"* ]]; then
      ARCH_SUFFIX="aarch64-pi4"
    else
      ARCH_SUFFIX="aarch64"
    fi
  else
    ARCH_SUFFIX="aarch64"
  fi
elif [[ "$ARCH" == "armv7l" ]]; then
  ARCH_SUFFIX="armhf"
else
  echo "Unsupported arch $ARCH"; exit 1
fi

echo "Target architecture suffix: $ARCH_SUFFIX"

echo "==> Fetching Update Manifest (JSON)"
JSON_FILE="smirror-back-${ARCH_SUFFIX}.json"
GITHUB_RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")

# Get the URL for the JSON manifest from the latest GitHub release
MANIFEST_URL=$(echo "$GITHUB_RELEASE_JSON" | jq -r ".assets[] | select(.name == \"$JSON_FILE\") | .browser_download_url")

if [[ -z "$MANIFEST_URL" || "$MANIFEST_URL" == "null" ]]; then
  echo "No update manifest ($JSON_FILE) found in latest release. Skipping."
  exit 0
fi

echo "==> Curl JSON: $MANIFEST_URL"
TMP=$(mktemp -d)
curl -fsSL "$MANIFEST_URL" -o "$TMP/update.json"

# Parse information from the downloaded JSON
VER=$(jq -r '.version' "$TMP/update.json")
ZIP_URL=$(jq -r '.url' "$TMP/update.json")
EXPECTED_SHA=$(jq -r '.sha256' "$TMP/update.json")

echo "Found version $VER."
echo "==> Downloading ZIP from: $ZIP_URL"
curl -L "$ZIP_URL" -o "$TMP/backend.zip"

echo "==> Verifying SHA256 checksum..."
ACTUAL_SHA=$(sha256sum "$TMP/backend.zip" | awk '{print $1}')

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "ERROR: SHA256 checksum mismatch!"
    echo "  Expected: $EXPECTED_SHA"
    echo "  Actual:   $ACTUAL_SHA"
    echo "Aborting installation to prevent corrupted or tampered files from running."
    rm -rf "$TMP"
    exit 1
fi

echo "Checksum verified successfully."

echo "==> Extracting package"
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

echo "==> Running the installer"
# Run the installer as root (it will stop/start the service if needed)
/opt/smirror/bin/smirror-installer "$STAGE" "$VER"

rm -rf "$TMP"

echo "==> Starting service"
systemctl start smirror
systemctl status smirror --no-pager