#!/usr/bin/env bash
# Run on the DEPLOY server. Detects this host's public IP and passes it to compose.
# Usage: ARTIFACT_USER=myuser ARTIFACT_PASSWORD=secret ./up.sh        (override: SERVER_NAME=artifacts.example.com ./up.sh)
set -euo pipefail

detect_ip() {
    local ip url
    # Cloud metadata first (AWS IMDSv2, then Oracle), then public echo services
    local token
    token="$(curl -fsS --max-time 2 -X PUT http://169.254.169.254/latest/api/token \
             -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
    if [ -n "$token" ]; then
        ip="$(curl -fsS --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
              http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    for url in https://api.ipify.org https://checkip.amazonaws.com https://ifconfig.me/ip; do
        ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

if [ -z "${SERVER_NAME:-}" ]; then
    SERVER_NAME="$(detect_ip || true)"
fi
export SERVER_NAME="${SERVER_NAME:-}"
echo "SERVER_NAME=${SERVER_NAME:-<auto-detect in container>}"

docker compose up -d "$@"
