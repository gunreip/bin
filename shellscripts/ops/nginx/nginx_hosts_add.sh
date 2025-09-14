#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail
DOMAIN="${1:-tafel-wesseling.local}"
IP="${2:-127.0.0.1}"

LINE="${IP} ${DOMAIN}"

if ! grep -qE "[[:space:]]${DOMAIN}(\s|$)" /etc/hosts; then
  echo "Füge ${LINE} zu /etc/hosts hinzu ..."
  echo "${LINE}" | sudo tee -a /etc/hosts >/dev/null
else
  echo "${DOMAIN} ist bereits in /etc/hosts eingetragen."
fi
echo "Done."
