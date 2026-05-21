#!/usr/bin/env bash
set -euo pipefail

BACKEND_REPO="thearrogantdev/smirrorBackend"
FRONTEND_REPO="thearrogantdev/smirrorFrontend"

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

# Sanity check to make sure the environment has the basic tools
for tool in curl jq unzip rsync sha256sum; do
    if ! command -v "$tool" &> /dev/null; then
        echo "$STATUS_ERR Required tool '$tool' is not installed. Run install.sh first."
        exit 1
    fi
done

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
      UI_ARCH_SUFFIX="aarch64-pi4" # Fallback
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
echo "==> 1. Updating Backend"
echo "=================================================="
JSON_FILE="update-back-${ARCH_SUFFIX}.json"
MANIFEST_URL="https://github.com/${BACKEND_REPO}/releases/latest/download/${JSON_FILE}"
TMP=$(mktemp -d)

if ! curl -sSfL "$MANIFEST_URL" -o "$TMP/update.json"; then
  echo "$STATUS_WARN No backend manifest ($JSON_FILE) found in latest release. Skipping backend."
else
  VER=$(jq -r '.version' "$TMP/update.json")
  ZIP_URL=$(jq -r '.url' "$TMP/update.json")
  EXPECTED_SHA=$(jq -r '.sha256' "$TMP/update.json")

  # Only download if we don't have this version folder yet
  if [[ -d "/opt/smirror/versions/$VER" ]]; then
    echo "$STATUS_OK Backend is already up to date (Version $VER is active)."
  else
    echo "==> Downloading Backend version $VER..."
    curl -L "$ZIP_URL" -o "$TMP/backend.zip"

    echo "==> Verifying SHA256 checksum..."
    ACTUAL_SHA=$(sha256sum "$TMP/backend.zip" | awk '{print $1}')
    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
        echo "$STATUS_ERR Backend SHA256 checksum mismatch! Aborting."
        rm -rf "$TMP"
        exit 1
    fi

    STAGE="/var/cache/smirror/downloads/backend-$VER"
    rm -rf "$STAGE" # Clean install directory
    mkdir -p "$STAGE"

    echo "==> Extracting Backend..."
    unzip -q -o "$TMP/backend.zip" -d "$STAGE"
    chown -R smirror:smirror "$STAGE"

    echo "==> Applying Backend Update..."
    /opt/smirror/bin/smirror-installer "$STAGE" "$VER"
  fi
fi
rm -rf "$TMP"


echo "=================================================="
echo "==> 2. Updating Frontend"
echo "=================================================="
UI_JSON_FILE="update-ui-${UI_ARCH_SUFFIX}.json"
UI_MANIFEST_URL="https://github.com/${FRONTEND_REPO}/releases/latest/download/${UI_JSON_FILE}"
TMP_UI=$(mktemp -d)

if ! curl -sSfL "$UI_MANIFEST_URL" -o "$TMP_UI/update-ui.json"; then
  echo "$STATUS_WARN No frontend manifest ($UI_JSON_FILE) found in latest release. Skipping frontend."
else
  UI_VER=$(jq -r '.version' "$TMP_UI/update-ui.json")
  UI_ZIP_URL=$(jq -r '.url' "$TMP_UI/update-ui.json")
  UI_EXPECTED_SHA=$(jq -r '.sha256' "$TMP_UI/update-ui.json")

  # Only download if we don't have this version folder yet
  if [[ -d "/var/lib/smirror/frontend/versions/$UI_VER" ]]; then
    echo "$STATUS_OK Frontend is already up to date (Version $UI_VER is active)."
  else
    echo "==> Downloading Frontend version $UI_VER..."
    curl -L "$ZIP_URL" -o "$TMP_UI/frontend.zip"

    echo "==> Verifying SHA256 checksum..."
    UI_ACTUAL_SHA=$(sha256sum "$TMP_UI/frontend.zip" | awk '{print $1}')
    if [[ "$UI_ACTUAL_SHA" != "$UI_EXPECTED_SHA" ]]; then
        echo "$STATUS_ERR Frontend SHA256 checksum mismatch! Aborting."
        rm -rf "$TMP_UI"
        exit 1
    fi

    UI_DST="/var/lib/smirror/frontend/versions/$UI_VER"
    rm -rf "$UI_DST" # Clean install directory
    mkdir -p "$UI_DST"

    echo "==> Extracting Frontend..."
    unzip -q -o "$TMP_UI/frontend.zip" -d "$UI_DST"
    chown -R smirror:smirror "/var/lib/smirror/frontend"

    echo "==> Linking Frontend..."
    ln -sfn "versions/$UI_VER" "/var/lib/smirror/frontend/current"
    chown -h smirror:smirror "/var/lib/smirror/frontend/current"
    echo "$STATUS_OK Frontend updated to $UI_VER"
  fi
fi
rm -rf "$TMP_UI"


echo "=================================================="
echo "==> 3. Restarting SMirror Service"
echo "=================================================="
systemctl restart smirror
systemctl status smirror --no-pager