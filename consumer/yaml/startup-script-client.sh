#!/bin/bash
# =============================================================================
# GCE startup script
#   1. Installs network tools (apache2-utils, mtr, iperf3, tcpdump)
#   2. Installs the NGFW CA cert (from Secret Manager) into the system trust store
#   3. Installs uv + Python + google-genai and the Gemini CLI chatbox
#
# The Gemini API key is NOT provisioned here. After boot, SSH in and run:
#     gemini-chat --set-key      (or just `gemini-chat`; it prompts on first run)
#
# Metadata keys:
#   gemini-chat-py   Contents of gemini_chat.py (--metadata-from-file)   [required*]
#   gemini-chat-url  Alternative source: gs://... or https://...          [required*]
#   gemini-model     Default model (optional, default gemini-3.8-flash)
#
# Logs: /var/log/startup-bootstrap.log
#       sudo journalctl -u google-startup-scripts.service
# =============================================================================
set -euo pipefail

LOG=/var/log/startup-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo "[INFO] === Bootstrap started $(date -Is) ==="

retry() {  # retry <cmd...> - network may not be ready right at boot
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge 5 ] && { echo "[ERROR] Failed after $n attempts: $*"; return 1; }
    echo "[WARN] Retry $n: $*"; sleep $((n * 5))
  done
}

MD_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
md() { curl -sf -H "Metadata-Flavor: Google" "$MD_URL/$1" || true; }

# -----------------------------------------------------------------------------
# 1. Network tools
# -----------------------------------------------------------------------------
if [ -f /etc/debian_version ]; then
  export DEBIAN_FRONTEND=noninteractive
  retry apt-get update -y
  retry apt-get install -y apache2-utils mtr iperf3 tcpdump curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  retry dnf install -y httpd-tools mtr iperf3 tcpdump curl ca-certificates
fi

# -----------------------------------------------------------------------------
# 2. NGFW CA certificate
# -----------------------------------------------------------------------------
SECRET_NAME="ngfw-ca"   # <-- replace with your Secret Manager secret name
CERT_FILE="ngfw-ca.crt"
TMP_CERT="/tmp/${CERT_FILE}"

echo "[INFO] Fetching CA cert from Secret Manager..."
# Requires VM service account role: roles/secretmanager.secretAccessor
retry gcloud secrets versions access latest --secret="${SECRET_NAME}" > "${TMP_CERT}"

if [ -f /etc/debian_version ]; then
  echo "[INFO] Detected Debian/Ubuntu"
  cp "${TMP_CERT}" "/usr/local/share/ca-certificates/${CERT_FILE}"
  update-ca-certificates
  CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
  echo "[INFO] Detected RHEL/CentOS/Fedora"
  cp "${TMP_CERT}" "/etc/pki/ca-trust/source/anchors/${CERT_FILE}"
  update-ca-trust extract
  CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt
else
  echo "[WARN] Unknown distro, installing cert in /etc/ssl/certs manually"
  mkdir -p /etc/ssl/certs
  cp "${TMP_CERT}" "/etc/ssl/certs/${CERT_FILE}"
  CA_BUNDLE="/etc/ssl/certs/${CERT_FILE}"
fi
rm -f "${TMP_CERT}"
echo "[INFO] System trust chain updated (bundle: ${CA_BUNDLE})"

# uv and Python (httpx/certifi) ship their own CA lists and would NOT trust the
# NGFW CA. Point them at the system bundle.
export SSL_CERT_FILE="${CA_BUNDLE}"
export UV_NATIVE_TLS=1

# -----------------------------------------------------------------------------
# 3. Gemini CLI chatbox
# -----------------------------------------------------------------------------
APP_DIR=/opt/gemini-chat
VENV="$APP_DIR/.venv"
SCRIPT="$APP_DIR/gemini_chat.py"
export UV_PYTHON_INSTALL_DIR="$APP_DIR/python"
export UV_CACHE_DIR="$APP_DIR/.uv-cache"
mkdir -p "$APP_DIR"

# 3a. uv
if ! command -v uv >/dev/null 2>&1; then
  echo "[INFO] Installing uv..."
  retry bash -c 'curl -LsSf https://astral.sh/uv/install.sh | \
    env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh'
fi
echo "[INFO] $(uv --version)"

# 3b. gemini_chat.py
TMP=$(mktemp)
SRC_URL=$(md gemini-chat-url)
if [ -n "$(md gemini-chat-py)" ]; then
  echo "[INFO] Fetching gemini_chat.py from metadata"
  md gemini-chat-py > "$TMP"
elif [[ "$SRC_URL" == gs://* ]]; then
  echo "[INFO] Fetching gemini_chat.py from $SRC_URL"
  retry gcloud storage cp "$SRC_URL" "$TMP"
elif [ -n "$SRC_URL" ]; then
  echo "[INFO] Fetching gemini_chat.py from $SRC_URL"
  retry curl -LsSf "$SRC_URL" -o "$TMP"
fi
if [ -s "$TMP" ]; then
  install -m 0755 "$TMP" "$SCRIPT"
elif [ ! -f "$SCRIPT" ]; then
  echo "[ERROR] No gemini_chat.py source (set metadata 'gemini-chat-py' or 'gemini-chat-url')"
  exit 1
fi
rm -f "$TMP"

# 3c. Python + google-genai
if [ ! -x "$VENV/bin/python" ]; then
  echo "[INFO] Creating venv (Python 3.12)..."
  retry uv venv --python 3.12 --python-preference only-managed "$VENV"
fi
echo "[INFO] Installing/upgrading google-genai..."
retry uv pip install --python "$VENV/bin/python" --upgrade google-genai
chmod -R a+rX "$APP_DIR"

# 3d. Default model from metadata (optional)
GEMINI_MODEL_MD=$(md gemini-model)
echo "GEMINI_MODEL_DEFAULT=\"${GEMINI_MODEL_MD:-gemini-3.8-flash}\"" > "$APP_DIR/defaults.env"
echo "CA_BUNDLE=\"${CA_BUNDLE}\"" >> "$APP_DIR/defaults.env"
chmod 0644 "$APP_DIR/defaults.env"

# 3e. Wrapper command: prompts for and stores the API key per user
cat > /usr/local/bin/gemini-chat <<'WRAPPER'
#!/usr/bin/env bash
# gemini-chat - wrapper for /opt/gemini-chat/gemini_chat.py
#   gemini-chat              start chat (prompts for API key on first run)
#   gemini-chat --set-key    enter / replace your Gemini API key
#   gemini-chat --clear-key  delete your stored API key
set -euo pipefail
APP_DIR=/opt/gemini-chat
PY="$APP_DIR/.venv/bin/python"
KEY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/gemini-chat/api_key"
# shellcheck disable=SC1091
. "$APP_DIR/defaults.env"

set_key() {
  local key
  mkdir -p "$(dirname "$KEY_FILE")"; chmod 700 "$(dirname "$KEY_FILE")"
  read -rsp "Enter Gemini API key (input hidden): " key; echo
  [ -z "$key" ] && { echo "No key entered." >&2; exit 1; }
  ( umask 077; printf '%s' "$key" > "$KEY_FILE" )
  echo "Saved to $KEY_FILE (mode 600)."
}

case "${1:-}" in
  --set-key)   set_key; exit 0 ;;
  --clear-key) rm -f "$KEY_FILE"; echo "Key removed."; exit 0 ;;
esac

if [ -z "${GEMINI_API_KEY:-}" ]; then
  if [ ! -s "$KEY_FILE" ]; then
    echo "No Gemini API key found for user '$USER'."
    set_key
  fi
  GEMINI_API_KEY="$(cat "$KEY_FILE")"
  export GEMINI_API_KEY
fi

export GEMINI_MODEL="${GEMINI_MODEL:-$GEMINI_MODEL_DEFAULT}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$CA_BUNDLE}"   # trust the NGFW CA
exec "$PY" "$APP_DIR/gemini_chat.py" "$@"
WRAPPER
chmod 0755 /usr/local/bin/gemini-chat

echo "[INFO] Verifying..."
"$VENV/bin/python" --version
SSL_CERT_FILE="$CA_BUNDLE" "$VENV/bin/python" -c "import google.genai as g; print('google-genai', g.__version__)"

echo "[INFO] === Bootstrap finished $(date -Is) ==="
echo "[INFO] SSH in and run: gemini-chat --set-key   then   gemini-chat"
