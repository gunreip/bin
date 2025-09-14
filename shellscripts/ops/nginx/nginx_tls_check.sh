#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail
DOMAIN="${1:-tafel-wesseling.local}"
PORT="${2:-443}"

echo "NGINX Status:"
systemctl is-active nginx && systemctl status nginx --no-pager | sed -n '1,10p' || true

echo
echo "Konfiguration prüfen:"
sudo nginx -t || exit 1

echo
echo "HTTP Check:"
curl -I "http://${DOMAIN}/" || true

echo
echo "HTTPS Check:"
curl -k -I "https://${DOMAIN}:${PORT}/" || true

echo
echo "Zertifikat anzeigen:"
echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${PORT}" 2>/dev/null | openssl x509 -noout -subject -issuer -dates || true

echo
echo "Fertig."
