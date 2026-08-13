#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.18.1}"
NODE_RED_VERSION="${NODE_RED_VERSION:-5.0.1}"
MODBUS_VERSION="${MODBUS_VERSION:-5.60.1}"
OPCUA_VERSION="${OPCUA_VERSION:-0.2.354}"
KAFKA_VERSION="${KAFKA_VERSION:-6.1.1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist-node-red-linux-arm64"
PACKAGE_NAME="NodeRED-Kylin-V10SP3-ARM64"
PACKAGE_DIR="${DIST_DIR}/${PACKAGE_NAME}"
WORK_DIR="${DIST_DIR}/.work"

rm -rf "${DIST_DIR}"
mkdir -p "${PACKAGE_DIR}/runtime" "${PACKAGE_DIR}/app" "${PACKAGE_DIR}/data" "${PACKAGE_DIR}/logs" "${WORK_DIR}"

NODE_ARCHIVE="node-v${NODE_VERSION}-linux-arm64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"
SHASUM_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"

curl -fL --retry 5 --retry-delay 2 "${NODE_URL}" -o "${WORK_DIR}/${NODE_ARCHIVE}"
curl -fL --retry 5 --retry-delay 2 "${SHASUM_URL}" -o "${WORK_DIR}/SHASUMS256.txt"
(
  cd "${WORK_DIR}"
  grep " ${NODE_ARCHIVE}$" SHASUMS256.txt > SHASUMS256.node.txt
  sha256sum -c SHASUMS256.node.txt
)

tar -xJf "${WORK_DIR}/${NODE_ARCHIVE}" -C "${PACKAGE_DIR}/runtime" --strip-components=1
export PATH="${PACKAGE_DIR}/runtime/bin:${PATH}"

node --version
npm --version

# Node.js 24's headers request -std=gnu++20 for native addons. AlmaLinux 8's
# GCC 8 uses the older spelling -std=gnu++2a for the same draft language mode.
# Keep the GCC 8 / glibc 2.28 ABI baseline and translate only that flag instead
# of compiling the addon with a newer distro/toolchain that could require newer
# GLIBC/GLIBCXX symbols on the offline Kylin target.
if command -v g++ >/dev/null 2>&1; then
  GCC_MAJOR="$(g++ -dumpfullversion -dumpversion | cut -d. -f1)"
  if [[ "${GCC_MAJOR}" =~ ^[0-9]+$ ]] && (( GCC_MAJOR < 10 )); then
    CXX_WRAPPER="${WORK_DIR}/gxx-node24-compat"
    cat > "${CXX_WRAPPER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  if [[ "${arg}" == "-std=gnu++20" ]]; then
    arg="-std=gnu++2a"
  fi
  args+=("${arg}")
done
exec /usr/bin/g++ "${args[@]}"
EOF
    chmod +x "${CXX_WRAPPER}"
    export CXX="${CXX_WRAPPER}"
    echo "Using GCC ${GCC_MAJOR} compatibility wrapper for Node.js 24 native addons: ${CXX}"
  fi
fi

cat > "${PACKAGE_DIR}/app/package.json" <<EOF
{
  "name": "node-red-offline-runtime",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "node-red": "${NODE_RED_VERSION}"
  }
}
EOF

(
  cd "${PACKAGE_DIR}/app"
  npm install --omit=dev --no-audit --no-fund
  npm ls --depth=0
)

cat > "${PACKAGE_DIR}/data/package.json" <<EOF
{
  "name": "node-red-offline-userdir",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "@oriolrius/node-red-contrib-kafka": "${KAFKA_VERSION}",
    "node-red-contrib-modbus": "${MODBUS_VERSION}",
    "node-red-contrib-opcua": "${OPCUA_VERSION}"
  }
}
EOF

(
  cd "${PACKAGE_DIR}/data"
  npm install --omit=dev --no-audit --no-fund
  npm ls --depth=0
)

cat > "${PACKAGE_DIR}/data/settings.js" <<'EOF'
const settings = {
    uiHost: process.env.NODE_RED_HOST || "0.0.0.0",
    uiPort: Number(process.env.NODE_RED_PORT || 1880),
    flowFile: "flows.json",
    flowFilePretty: true,
    logging: {
        console: {
            level: process.env.NODE_RED_LOG_LEVEL || "info",
            metrics: false,
            audit: false
        }
    },
    editorTheme: {
        projects: { enabled: false }
    }
};

if (process.env.NODE_RED_CREDENTIAL_SECRET) {
    settings.credentialSecret = process.env.NODE_RED_CREDENTIAL_SECRET;
}

module.exports = settings;
EOF

printf '[]\n' > "${PACKAGE_DIR}/data/flows.json"

cat > "${PACKAGE_DIR}/start-node-red.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${ROOT_DIR}/runtime/bin:${PATH}"
exec "${ROOT_DIR}/runtime/bin/node" \
  "${ROOT_DIR}/app/node_modules/node-red/red.js" \
  --userDir "${ROOT_DIR}/data" "$@"
EOF

cat > "${PACKAGE_DIR}/check-environment.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(uname -m)"
if [[ "${ARCH}" != "aarch64" ]]; then
  echo "ERROR: This package requires aarch64/ARM64. Current architecture: ${ARCH}" >&2
  exit 1
fi
GLIBC_LINE="$(ldd --version 2>&1 | sed -n '1p')"
GLIBC_VERSION="$(printf '%s\n' "${GLIBC_LINE}" | grep -oE '[0-9]+\.[0-9]+' | tail -n 1)"
if [[ -z "${GLIBC_VERSION}" ]]; then
  echo "ERROR: Could not determine glibc version." >&2
  exit 1
fi
if [[ "$(printf '%s\n' '2.28' "${GLIBC_VERSION}" | sort -V | sed -n '1p')" != "2.28" ]]; then
  echo "ERROR: glibc ${GLIBC_VERSION} is older than required baseline 2.28." >&2
  exit 1
fi
"${ROOT_DIR}/runtime/bin/node" --version
"${ROOT_DIR}/runtime/bin/npm" --version
echo "Architecture: ${ARCH}"
echo "glibc: ${GLIBC_VERSION}"
echo "Environment check: PASS"
EOF

cat > "${PACKAGE_DIR}/README-OFFLINE.txt" <<EOF
Node-RED Offline Portable Package - Kylin V10 SP3 ARM64
=======================================================

Target:
  - Linux ARM64 / aarch64
  - Galaxy Kylin Advanced Server V10 SP3
  - glibc 2.28 or newer
  - No Internet required at runtime

Bundled versions:
  Node.js: ${NODE_VERSION}
  Node-RED: ${NODE_RED_VERSION}
  Modbus: node-red-contrib-modbus ${MODBUS_VERSION}
  OPC UA: node-red-contrib-opcua ${OPCUA_VERSION}
  Kafka: @oriolrius/node-red-contrib-kafka ${KAFKA_VERSION}

Built-in Node-RED nodes also provide MQTT, HTTP, TCP, UDP and WebSocket support.

Run:
  chmod +x start-node-red.sh check-environment.sh
  ./check-environment.sh
  ./start-node-red.sh

Open from a browser:
  http://<server-ip>:1880

Optional environment variables:
  NODE_RED_HOST=0.0.0.0
  NODE_RED_PORT=1880
  NODE_RED_LOG_LEVEL=info
  NODE_RED_CREDENTIAL_SECRET=<your-secret>

All npm dependencies and Node.js are already included. Do NOT run npm install on the offline target.

Security note:
  The portable package intentionally does not ship a fixed default administrator password.
  Node-RED's editor therefore has no admin authentication by default. On a production network,
  restrict TCP/1880 with the host firewall and configure Node-RED adminAuth before exposing it
  to untrusted users or networks.
EOF

cat > "${PACKAGE_DIR}/VERSION.txt" <<EOF
Package: NodeRED-Kylin-V10SP3-ARM64
Build architecture: aarch64
Node.js: ${NODE_VERSION}
Node-RED: ${NODE_RED_VERSION}
node-red-contrib-modbus: ${MODBUS_VERSION}
node-red-contrib-opcua: ${OPCUA_VERSION}
@oriolrius/node-red-contrib-kafka: ${KAFKA_VERSION}
EOF

chmod +x "${PACKAGE_DIR}/start-node-red.sh" "${PACKAGE_DIR}/check-environment.sh"
rm -rf "${WORK_DIR}"

echo "Linux ARM64 Node-RED offline package prepared at: ${PACKAGE_DIR}"
