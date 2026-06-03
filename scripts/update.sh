#!/usr/bin/env bash
set -euo pipefail

BACKEND_REPO="thearrogantdev/smirrorBackend"
FRONTEND_REPO="thearrogantdev/smirrorFrontend"
WEBAPP_REPO="thearrogantdev/smirrorApp"

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
# Added ?t= timestamp cache-buster to bypass GitHub CDN caching
JSON_FILE="update-back-${ARCH_SUFFIX}.json"
MANIFEST_URL="https://github.com/${BACKEND_REPO}/releases/latest/download/${JSON_FILE}?t=$(date +%s)"
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
    # Added ?t= timestamp cache-buster to the ZIP URL too
    if ! curl -fSL "${ZIP_URL}?t=$(date +%s)" -o "$TMP/backend.zip"; then
        echo "$STATUS_ERR Failed to download the backend ZIP file from: $ZIP_URL"
        echo "Please verify that the ZIP asset is uploaded to your GitHub release!"
        rm -rf "$TMP"
        exit 1
    fi

    echo "==> Verifying SHA256 checksum..."
    ACTUAL_SHA=$(sha256sum "$TMP/backend.zip" | awk '{print $1}')
    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
        echo "$STATUS_ERR Backend SHA256 checksum mismatch! Aborting."
        echo "  Expected: $EXPECTED_SHA"
        echo "  Actual:   $ACTUAL_SHA"
        echo "  (This is often caused by GitHub CDN caching. Try again in a few minutes)."
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
# Added ?t= timestamp cache-buster to bypass GitHub CDN caching
UI_JSON_FILE="update-ui-${UI_ARCH_SUFFIX}.json"
UI_MANIFEST_URL="https://github.com/${FRONTEND_REPO}/releases/latest/download/${UI_JSON_FILE}?t=$(date +%s)"
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
    # Added ?t= timestamp cache-buster to the ZIP URL too
    if ! curl -fSL "${UI_ZIP_URL}?t=$(date +%s)" -o "$TMP_UI/frontend.zip"; then
        echo "$STATUS_ERR Failed to download the frontend ZIP file from: $UI_ZIP_URL"
        echo "Please verify that the ZIP asset is uploaded to your GitHub release!"
        rm -rf "$TMP_UI"
        exit 1
    fi

    echo "==> Verifying SHA256 checksum..."
    UI_ACTUAL_SHA=$(sha256sum "$TMP_UI/frontend.zip" | awk '{print $1}')
    if [[ "$UI_ACTUAL_SHA" != "$UI_EXPECTED_SHA" ]]; then
        echo "$STATUS_ERR Frontend SHA256 checksum mismatch! Aborting."
        echo "  Expected: $UI_EXPECTED_SHA"
        echo "  Actual:   $UI_ACTUAL_SHA"
        echo "  (This is often caused by GitHub CDN caching. Try again in a few minutes)."
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
echo "==> 3. Updating Webapp"
echo "=================================================="
# Added ?t= timestamp cache-buster to bypass GitHub CDN caching
WEB_JSON_FILE="update-app-web.json"
WEB_MANIFEST_URL="https://github.com/${WEBAPP_REPO}/releases/latest/download/${WEB_JSON_FILE}?t=$(date +%s)"
TMP_WEB=$(mktemp -d)

if ! curl -sSfL "$WEB_MANIFEST_URL" -o "$TMP_WEB/update-web.json"; then
  echo "$STATUS_WARN No webapp manifest ($WEB_JSON_FILE) found in latest release. Skipping webapp update."
else
  WEB_VER=$(jq -r '.version' "$TMP_WEB/update-web.json")
  WEB_ZIP_URL=$(jq -r '.url' "$TMP_WEB/update-web.json")
  WEB_EXPECTED_SHA=$(jq -r '.sha256' "$TMP_WEB/update-web.json")

  # VERSION GUARD: Only download if we don't have this version folder yet
  if [[ -d "/var/lib/smirror/webapp/versions/$WEB_VER" ]]; then
    echo "$STATUS_OK Webapp is already up to date (Version $WEB_VER is active)."
  else
    echo "==> Downloading Webapp version $WEB_VER..."
    # Added ?t= timestamp cache-buster to the ZIP URL too
    if ! curl -fSL "${WEB_ZIP_URL}?t=$(date +%s)" -o "$TMP_WEB/webapp.zip"; then
        echo "$STATUS_ERR Failed to download the webapp ZIP file from: $WEB_ZIP_URL"
        echo "Please verify that the ZIP asset is uploaded to your GitHub release!"
        rm -rf "$TMP_WEB"
        exit 1
    fi

    echo "==> Verifying SHA256 checksum..."
    WEB_ACTUAL_SHA=$(sha256sum "$TMP_WEB/webapp.zip" | awk '{print $1}')
    if [[ "$WEB_ACTUAL_SHA" != "$WEB_EXPECTED_SHA" ]]; then
        echo "$STATUS_ERR Webapp SHA256 checksum mismatch! Aborting."
        echo "  Expected: $WEB_EXPECTED_SHA"
        echo "  Actual:   $WEB_ACTUAL_SHA"
        echo "  (This is often caused by GitHub CDN caching. Try again in a few minutes)."
        rm -rf "$TMP_WEB"
        exit 1
    fi

    WEB_DST="/var/lib/smirror/webapp/versions/$WEB_VER"
    rm -rf "$WEB_DST" # Clean install directory
    mkdir -p "$WEB_DST"

    echo "==> Extracting Webapp..."
    unzip -q -o "$TMP_WEB/webapp.zip" -d "$WEB_DST"
    chown -R smirror:smirror "/var/lib/smirror/webapp"

    echo "==> Linking Webapp (live)..."
    ln -sfn "versions/$WEB_VER" "/var/lib/smirror/webapp/live"
    chown -h smirror:smirror "/var/lib/smirror/webapp/live"
    echo "$STATUS_OK Webapp updated to $WEB_VER"
  fi
fi
rm -rf "$TMP_WEB"


echo "=================================================="
echo "==> 4. Restarting SMirror Service"
echo "=================================================="
systemctl restart smirror
systemctl status smirror --no-pager