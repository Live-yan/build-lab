#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.18.1}"
NODE_RED_VERSION="${NODE_RED_VERSION:-5.0.1}"
MODBUS_VERSION="${MODBUS_VERSION:-5.60.1}"
OPCUA_VERSION="${OPCUA_VERSION:-0.2.354}"
KAFKAJS_VERSION="${KAFKAJS_VERSION:-2.2.4}"

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

# Keep Kafka support pure JavaScript on the ARM64 package. The previous
# @oriolrius/node-red-contrib-kafka dependency pulled lz4@0.6.5, which invokes
# node-gyp and old NAN/V8 bindings that are not compatible with Node.js 24.
# KafkaJS itself is JavaScript-only, so we bundle it and ship a tiny Node-RED
# wrapper providing broker, producer and consumer nodes.
cat > "${PACKAGE_DIR}/data/package.json" <<EOF
{
  "name": "node-red-offline-userdir",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "kafkajs": "${KAFKAJS_VERSION}",
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

KAFKA_NODE_DIR="${PACKAGE_DIR}/data/node_modules/node-red-contrib-kafkajs-portable"
mkdir -p "${KAFKA_NODE_DIR}"

cat > "${KAFKA_NODE_DIR}/package.json" <<EOF
{
  "name": "node-red-contrib-kafkajs-portable",
  "version": "1.0.0",
  "private": true,
  "description": "Portable KafkaJS producer/consumer nodes bundled for the offline Node-RED package",
  "main": "kafka.js",
  "node-red": {
    "nodes": {
      "kafkajs-portable": "kafka.js"
    }
  },
  "dependencies": {
    "kafkajs": "${KAFKAJS_VERSION}"
  }
}
EOF

cat > "${KAFKA_NODE_DIR}/kafka.js" <<'EOF'
"use strict";

module.exports = function (RED) {
    const { Kafka, logLevel } = require("kafkajs");

    function parseBrokers(value) {
        return String(value || "")
            .split(",")
            .map((item) => item.trim())
            .filter(Boolean);
    }

    function createKafka(configNode) {
        const options = {
            clientId: configNode.clientId || "node-red-offline",
            brokers: parseBrokers(configNode.brokers),
            logLevel: logLevel.NOTHING
        };

        if (configNode.ssl) {
            options.ssl = true;
        }

        if (configNode.username) {
            options.sasl = {
                mechanism: configNode.saslMechanism || "plain",
                username: configNode.username,
                password: configNode.password || ""
            };
        }

        return new Kafka(options);
    }

    function KafkaBrokerNode(config) {
        RED.nodes.createNode(this, config);
        this.name = config.name;
        this.brokers = config.brokers;
        this.clientId = config.clientId;
        this.ssl = Boolean(config.ssl);
        this.saslMechanism = config.saslMechanism;
        this.username = this.credentials && this.credentials.username;
        this.password = this.credentials && this.credentials.password;
    }

    RED.nodes.registerType("kafkajs-broker", KafkaBrokerNode, {
        credentials: {
            username: { type: "text" },
            password: { type: "password" }
        }
    });

    function KafkaProducerNode(config) {
        RED.nodes.createNode(this, config);
        const node = this;
        const broker = RED.nodes.getNode(config.broker);
        let producer = null;
        let connecting = null;

        async function ensureProducer() {
            if (producer) return producer;
            if (!broker) throw new Error("Kafka broker configuration is missing");
            if (!parseBrokers(broker.brokers).length) throw new Error("Kafka broker list is empty");

            if (!connecting) {
                node.status({ fill: "yellow", shape: "ring", text: "connecting" });
                connecting = (async () => {
                    const kafka = createKafka(broker);
                    const p = kafka.producer();
                    await p.connect();
                    producer = p;
                    node.status({ fill: "green", shape: "dot", text: "connected" });
                    return p;
                })().finally(() => {
                    connecting = null;
                });
            }
            return connecting;
        }

        node.on("input", async (msg, send, done) => {
            send = send || node.send.bind(node);
            try {
                const p = await ensureProducer();
                const topic = msg.topic || config.topic;
                if (!topic) throw new Error("Kafka topic is required (node topic or msg.topic)");

                const payload = Buffer.isBuffer(msg.payload)
                    ? msg.payload
                    : (typeof msg.payload === "string" ? msg.payload : JSON.stringify(msg.payload));

                const message = { value: payload };
                const key = msg.key !== undefined ? msg.key : config.key;
                if (key !== undefined && key !== "") {
                    message.key = Buffer.isBuffer(key) ? key : String(key);
                }

                const result = await p.send({ topic, messages: [message] });
                msg.kafka = { topic, result };
                send(msg);
                if (done) done();
            } catch (err) {
                node.status({ fill: "red", shape: "ring", text: "error" });
                if (done) done(err); else node.error(err, msg);
            }
        });

        node.on("close", async (removed, done) => {
            try {
                if (producer) await producer.disconnect();
            } catch (err) {
                node.warn(err.message || err);
            }
            if (done) done();
        });
    }

    RED.nodes.registerType("kafkajs-producer", KafkaProducerNode);

    function KafkaConsumerNode(config) {
        RED.nodes.createNode(this, config);
        const node = this;
        const broker = RED.nodes.getNode(config.broker);
        let consumer = null;
        let closing = false;

        async function start() {
            if (!broker) throw new Error("Kafka broker configuration is missing");
            if (!parseBrokers(broker.brokers).length) throw new Error("Kafka broker list is empty");
            if (!config.topic) throw new Error("Kafka consumer topic is required");
            if (!config.groupId) throw new Error("Kafka consumer groupId is required");

            node.status({ fill: "yellow", shape: "ring", text: "connecting" });
            const kafka = createKafka(broker);
            consumer = kafka.consumer({ groupId: config.groupId });
            await consumer.connect();
            await consumer.subscribe({ topic: config.topic, fromBeginning: Boolean(config.fromBeginning) });
            await consumer.run({
                eachMessage: async ({ topic, partition, message }) => {
                    if (closing) return;
                    const value = message.value ? message.value.toString("utf8") : "";
                    const out = {
                        topic,
                        partition,
                        offset: message.offset,
                        timestamp: message.timestamp,
                        key: message.key ? message.key.toString("utf8") : undefined,
                        payload: value,
                        kafka: {
                            headers: message.headers || {},
                            attributes: message.attributes,
                            size: message.size
                        }
                    };
                    node.send(out);
                }
            });
            node.status({ fill: "green", shape: "dot", text: "consuming" });
        }

        start().catch((err) => {
            node.status({ fill: "red", shape: "ring", text: "disconnected" });
            node.error(err);
        });

        node.on("close", async (removed, done) => {
            closing = true;
            try {
                if (consumer) await consumer.disconnect();
            } catch (err) {
                node.warn(err.message || err);
            }
            if (done) done();
        });
    }

    RED.nodes.registerType("kafkajs-consumer", KafkaConsumerNode);
};
EOF

cat > "${KAFKA_NODE_DIR}/kafka.html" <<'EOF'
<script type="text/javascript">
RED.nodes.registerType('kafkajs-broker', {
    category: 'config',
    defaults: {
        name: { value: '' },
        brokers: { value: '127.0.0.1:9092', required: true },
        clientId: { value: 'node-red-offline', required: true },
        ssl: { value: false },
        saslMechanism: { value: 'plain' }
    },
    credentials: {
        username: { type: 'text' },
        password: { type: 'password' }
    },
    label: function () { return this.name || this.brokers || 'Kafka broker'; }
});

RED.nodes.registerType('kafkajs-producer', {
    category: 'network',
    color: '#f3d45a',
    defaults: {
        name: { value: '' },
        broker: { value: '', type: 'kafkajs-broker', required: true },
        topic: { value: '' },
        key: { value: '' }
    },
    inputs: 1,
    outputs: 1,
    icon: 'bridge.svg',
    label: function () { return this.name || 'Kafka producer'; }
});

RED.nodes.registerType('kafkajs-consumer', {
    category: 'network',
    color: '#f3d45a',
    defaults: {
        name: { value: '' },
        broker: { value: '', type: 'kafkajs-broker', required: true },
        topic: { value: '', required: true },
        groupId: { value: 'node-red-offline', required: true },
        fromBeginning: { value: false }
    },
    inputs: 0,
    outputs: 1,
    icon: 'bridge.svg',
    label: function () { return this.name || 'Kafka consumer'; }
});
</script>

<script type="text/html" data-template-name="kafkajs-broker">
    <div class="form-row"><label for="node-config-input-name">Name</label><input type="text" id="node-config-input-name"></div>
    <div class="form-row"><label for="node-config-input-brokers">Brokers</label><input type="text" id="node-config-input-brokers" placeholder="10.0.0.1:9092,10.0.0.2:9092"></div>
    <div class="form-row"><label for="node-config-input-clientId">Client ID</label><input type="text" id="node-config-input-clientId"></div>
    <div class="form-row"><label for="node-config-input-ssl">SSL</label><input type="checkbox" id="node-config-input-ssl" style="width:auto"></div>
    <div class="form-row"><label for="node-config-input-saslMechanism">SASL</label><select id="node-config-input-saslMechanism"><option value="plain">PLAIN</option><option value="scram-sha-256">SCRAM-SHA-256</option><option value="scram-sha-512">SCRAM-SHA-512</option></select></div>
    <div class="form-row"><label for="node-config-input-username">Username</label><input type="text" id="node-config-input-username"></div>
    <div class="form-row"><label for="node-config-input-password">Password</label><input type="password" id="node-config-input-password"></div>
</script>

<script type="text/html" data-template-name="kafkajs-producer">
    <div class="form-row"><label for="node-input-name">Name</label><input type="text" id="node-input-name"></div>
    <div class="form-row"><label for="node-input-broker">Broker</label><input type="text" id="node-input-broker"></div>
    <div class="form-row"><label for="node-input-topic">Topic</label><input type="text" id="node-input-topic" placeholder="or msg.topic"></div>
    <div class="form-row"><label for="node-input-key">Key</label><input type="text" id="node-input-key" placeholder="or msg.key"></div>
</script>

<script type="text/html" data-template-name="kafkajs-consumer">
    <div class="form-row"><label for="node-input-name">Name</label><input type="text" id="node-input-name"></div>
    <div class="form-row"><label for="node-input-broker">Broker</label><input type="text" id="node-input-broker"></div>
    <div class="form-row"><label for="node-input-topic">Topic</label><input type="text" id="node-input-topic"></div>
    <div class="form-row"><label for="node-input-groupId">Group ID</label><input type="text" id="node-input-groupId"></div>
    <div class="form-row"><label for="node-input-fromBeginning">From beginning</label><input type="checkbox" id="node-input-fromBeginning" style="width:auto"></div>
</script>

<script type="text/html" data-help-name="kafkajs-producer"><p>Send <code>msg.payload</code> to Kafka. Topic may come from the node or <code>msg.topic</code>; key may come from the node or <code>msg.key</code>.</p></script>
<script type="text/html" data-help-name="kafkajs-consumer"><p>Consumes Kafka records and outputs UTF-8 data in <code>msg.payload</code>, plus topic, partition, offset, timestamp and key.</p></script>
EOF

# npm installed KafkaJS at the userDir root. Make it visible to the bundled custom
# node without installing or compiling anything else.
ln -s ../kafkajs "${KAFKA_NODE_DIR}/node_modules-kafkajs-placeholder" 2>/dev/null || true

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
"${ROOT_DIR}/runtime/bin/node" -e "require('${ROOT_DIR}/data/node_modules/kafkajs'); console.log('KafkaJS: PASS')"
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
  Kafka engine: KafkaJS ${KAFKAJS_VERSION}
  Kafka Node-RED nodes: node-red-contrib-kafkajs-portable 1.0.0

Built-in Node-RED nodes also provide MQTT, HTTP, TCP, UDP and WebSocket support.

Run:
  chmod +x start-node-red.sh check-environment.sh
  ./check-environment.sh
  ./start-node-red.sh

Open from a browser:
  http://<server-ip>:1880

Kafka palette nodes:
  - Kafka producer
  - Kafka consumer
  Add a Kafka broker config and enter brokers such as 192.168.1.10:9092.

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
KafkaJS: ${KAFKAJS_VERSION}
node-red-contrib-kafkajs-portable: 1.0.0
EOF

chmod +x "${PACKAGE_DIR}/start-node-red.sh" "${PACKAGE_DIR}/check-environment.sh"
rm -rf "${WORK_DIR}"

echo "Linux ARM64 Node-RED offline package prepared at: ${PACKAGE_DIR}"
