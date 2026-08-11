#!/usr/bin/env bash
set -euo pipefail

JAVA_VERSION="${JAVA_VERSION:-25}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${DIST_ROOT:-$REPO_ROOT/dist-linux-arm64}"
PACKAGE_DIR="$DIST_ROOT/KafbatUI-Kylin-ARM64"
TEMP_DIR="$DIST_ROOT/_tmp"

rm -rf "$DIST_ROOT"
mkdir -p "$PACKAGE_DIR/data/uploads" "$PACKAGE_DIR/logs" "$TEMP_DIR"

GITHUB_API_HEADERS=(-H "Accept: application/vnd.github+json" -H "User-Agent: kafbat-ui-offline-linux-arm64-builder" -H "X-GitHub-Api-Version: 2022-11-28")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  GITHUB_API_HEADERS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

echo "Resolving latest Kafbat UI release..."
RELEASE_JSON="$TEMP_DIR/kafbat-release.json"
curl -fsSL "${GITHUB_API_HEADERS[@]}" \
  "https://api.github.com/repos/kafbat/kafka-ui/releases/latest" \
  -o "$RELEASE_JSON"

mapfile -t KAFBAT_INFO < <(python3 - "$RELEASE_JSON" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding='utf-8') as f:
    release = json.load(f)
assets = release.get('assets', [])
jar = next((a for a in assets if re.match(r'^api-v.*\.jar$', a.get('name', ''))), None)
if jar is None:
    jar = next((a for a in assets if a.get('name', '').endswith('.jar')), None)
if jar is None:
    raise SystemExit('No executable JAR asset was found in latest Kafbat UI release')
print(release['tag_name'])
print(jar['name'])
print(jar['browser_download_url'])
print(jar.get('digest') or '')
PY
)

KAFBAT_VERSION="${KAFBAT_INFO[0]}"
KAFBAT_ASSET="${KAFBAT_INFO[1]}"
KAFBAT_URL="${KAFBAT_INFO[2]}"
KAFBAT_DIGEST="${KAFBAT_INFO[3]}"
KAFBAT_JAR="$PACKAGE_DIR/api.jar"

echo "Downloading Kafbat UI $KAFBAT_VERSION: $KAFBAT_ASSET"
curl -fL --retry 3 --retry-delay 2 "$KAFBAT_URL" -o "$KAFBAT_JAR"
KAFBAT_SHA256="$(sha256sum "$KAFBAT_JAR" | awk '{print $1}')"
if [[ "$KAFBAT_DIGEST" == sha256:* ]]; then
  EXPECTED="${KAFBAT_DIGEST#sha256:}"
  if [[ "${KAFBAT_SHA256,,}" != "${EXPECTED,,}" ]]; then
    echo "Kafbat UI JAR SHA256 mismatch: expected $EXPECTED, got $KAFBAT_SHA256" >&2
    exit 1
  fi
  echo "Kafbat UI JAR SHA256 verified."
fi

echo "Resolving Eclipse Temurin JRE $JAVA_VERSION for Linux aarch64..."
JRE_JSON="$TEMP_DIR/temurin.json"
curl -fsSL \
  -H "User-Agent: kafbat-ui-offline-linux-arm64-builder" \
  "https://api.adoptium.net/v3/assets/latest/$JAVA_VERSION/hotspot?architecture=aarch64&image_type=jre&os=linux" \
  -o "$JRE_JSON"

mapfile -t JRE_INFO < <(python3 - "$JRE_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
for item in data:
    package = item.get('binary', {}).get('package', {})
    if package.get('link'):
        print(package.get('name', ''))
        print(package['link'])
        print(package.get('checksum', ''))
        break
else:
    raise SystemExit('No Linux aarch64 JRE package was returned by Eclipse Adoptium')
PY
)

JRE_NAME="${JRE_INFO[0]}"
JRE_URL="${JRE_INFO[1]}"
JRE_EXPECTED_SHA256="${JRE_INFO[2]}"
JRE_ARCHIVE="$TEMP_DIR/jre.tar.gz"

echo "Downloading JRE: $JRE_NAME"
curl -fL --retry 3 --retry-delay 2 "$JRE_URL" -o "$JRE_ARCHIVE"
JRE_SHA256="$(sha256sum "$JRE_ARCHIVE" | awk '{print $1}')"
if [[ -n "$JRE_EXPECTED_SHA256" && "${JRE_SHA256,,}" != "${JRE_EXPECTED_SHA256,,}" ]]; then
  echo "JRE SHA256 mismatch: expected $JRE_EXPECTED_SHA256, got $JRE_SHA256" >&2
  exit 1
fi
if [[ -n "$JRE_EXPECTED_SHA256" ]]; then
  echo "JRE SHA256 verified."
fi

JRE_EXTRACT="$TEMP_DIR/jre-extracted"
mkdir -p "$JRE_EXTRACT"
tar -xzf "$JRE_ARCHIVE" -C "$JRE_EXTRACT"
JRE_ROOT="$(find "$JRE_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$JRE_ROOT" ]]; then
  echo "JRE archive did not contain an expected top-level directory." >&2
  exit 1
fi
mkdir -p "$PACKAGE_DIR/jre"
cp -a "$JRE_ROOT"/. "$PACKAGE_DIR/jre/"

if [[ ! -x "$PACKAGE_DIR/jre/bin/java" ]]; then
  echo "Packaged JRE is invalid: jre/bin/java was not found or is not executable." >&2
  exit 1
fi

cat > "$PACKAGE_DIR/run-foreground.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"
mkdir -p data/uploads logs
export DYNAMIC_CONFIG_ENABLED=true
export DYNAMIC_CONFIG_PATH="$BASE_DIR/data/dynamic_config.yaml"
export CONFIG_RELATED_UPLOADS_DIR="$BASE_DIR/data/uploads"
export SERVER_ADDRESS="0.0.0.0"
export SERVER_PORT="${SERVER_PORT:-8080}"
exec "$BASE_DIR/jre/bin/java" \
  --add-opens java.rmi/javax.rmi.ssl=ALL-UNNAMED \
  -jar "$BASE_DIR/api.jar"
EOF

cat > "$PACKAGE_DIR/start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"
mkdir -p data/uploads logs
PID_FILE="$BASE_DIR/kafbat-ui.pid"
LOG_FILE="$BASE_DIR/logs/kafbat-ui.log"

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "Kafbat UI is already running. PID=$PID"
    echo "Web UI: http://<server-ip>:8080"
    exit 0
  fi
  rm -f "$PID_FILE"
fi

nohup "$BASE_DIR/run-foreground.sh" >>"$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"
sleep 2

if ! kill -0 "$PID" 2>/dev/null; then
  echo "Kafbat UI failed to start. Last log lines:" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  rm -f "$PID_FILE"
  exit 1
fi

echo "Kafbat UI started. PID=$PID"
echo "Web UI: http://<server-ip>:8080"
echo "Log: $LOG_FILE"
echo "Configuration: $BASE_DIR/data/dynamic_config.yaml"
EOF

cat > "$PACKAGE_DIR/stop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$BASE_DIR/kafbat-ui.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "Kafbat UI is not running (PID file not found)."
  exit 0
fi

PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ -z "$PID" ]]; then
  rm -f "$PID_FILE"
  echo "Removed empty PID file."
  exit 0
fi

if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  for _ in {1..20}; do
    if ! kill -0 "$PID" 2>/dev/null; then
      rm -f "$PID_FILE"
      echo "Kafbat UI stopped."
      exit 0
    fi
    sleep 1
  done
  echo "Process did not stop gracefully; sending SIGKILL."
  kill -9 "$PID" 2>/dev/null || true
fi
rm -f "$PID_FILE"
echo "Kafbat UI stopped."
EOF

cat > "$PACKAGE_DIR/status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$BASE_DIR/kafbat-ui.pid"
if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "Kafbat UI is running. PID=$PID"
    echo "Web UI: http://<server-ip>:8080"
    exit 0
  fi
fi
echo "Kafbat UI is not running."
exit 1
EOF

chmod +x "$PACKAGE_DIR/run-foreground.sh" "$PACKAGE_DIR/start.sh" "$PACKAGE_DIR/stop.sh" "$PACKAGE_DIR/status.sh"

cat > "$PACKAGE_DIR/README.txt" <<EOF
Kafbat UI Offline Package - Kylin V10 SP3 / Linux ARM64
========================================================

Kafbat UI version: $KAFBAT_VERSION
Java runtime: Eclipse Temurin JRE $JAVA_VERSION, Linux aarch64 / HotSpot
Target: Galaxy Kylin Advanced Server OS V10 SP3 aarch64

Usage
-----
1. Copy the .tar.gz package to the offline Kylin ARM64 server.
2. Extract it with: tar -xzf kafbat-ui-offline-kylin-v10sp3-arm64.tar.gz
3. Enter the directory: cd KafbatUI-Kylin-ARM64
4. Start: ./start.sh
5. From a browser that can reach the server, open: http://SERVER_IP:8080
6. Add Kafka clusters in the Kafbat UI Configuration Wizard.

Commands
--------
./start.sh             Start in background
./stop.sh              Stop
./status.sh            Show process status
./run-foreground.sh    Run in foreground for troubleshooting

tail -f logs/kafbat-ui.log
                       Follow logs

Persistence
-----------
Cluster configuration is stored in:
  data/dynamic_config.yaml

Uploaded truststores/keystores are stored under:
  data/uploads

No Docker and no system-wide Java installation are required.
EOF

cat > "$PACKAGE_DIR/VERSION.txt" <<EOF
KAFBAT_UI_VERSION=$KAFBAT_VERSION
KAFBAT_UI_ASSET=$KAFBAT_ASSET
KAFBAT_UI_JAR_SHA256=$KAFBAT_SHA256
JAVA_DISTRIBUTION=Eclipse Temurin
JAVA_FEATURE_VERSION=$JAVA_VERSION
JAVA_PACKAGE=$JRE_NAME
JAVA_ARCHIVE_SHA256=$JRE_SHA256
TARGET_OS=Kylin V10 SP3 / compatible glibc Linux
TARGET_ARCH=aarch64
BUILD_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

rm -rf "$TEMP_DIR"

echo
echo "Offline ARM64 package prepared successfully:"
echo "  $PACKAGE_DIR"
echo "  Kafbat UI: $KAFBAT_VERSION"
echo "  JRE: $JRE_NAME"
