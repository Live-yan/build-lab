#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec java -Dfile.encoding=UTF-8 -cp "$DIR/dahua-download-example.jar:$DIR/lib/*" DahuaDownloadExample "$@"
