#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

OS2_SOURCE_URL="${OS2_SOURCE_URL:-http://localhost:29200}"
OS3_SOURCE_URL="${OS3_SOURCE_URL:-http://localhost:39200}"
DESTINATION_URL="${DESTINATION_URL:-http://localhost:49200}"

OS2_ADMIN="${OS2_ADMIN:-admin:Admin2Pass123!}"
OS3_ADMIN="${OS3_ADMIN:-admin:N7!qL2#vR9@x}"
DESTINATION_ADMIN="${DESTINATION_ADMIN:-admin:Q4@zM8!pT6#k}"
CCS_USER="${CCS_USER:-ccs-user}"
CCS_PASSWORD="${CCS_PASSWORD:-CcsUser123!}"

curl() {
  command curl -sS -w '\n' "$@"
}

cleanup() {
  if [[ "${KEEP_CONTAINERS:-0}" != "1" ]]; then
    docker compose down -v
  fi
}
trap cleanup EXIT

docker compose up -d

for endpoint in "$OS2_SOURCE_URL" "$OS3_SOURCE_URL" "$DESTINATION_URL"; do
  case "$endpoint" in
    "$OS2_SOURCE_URL") admin="$OS2_ADMIN" ;;
    "$OS3_SOURCE_URL") admin="$OS3_ADMIN" ;;
    *) admin="$DESTINATION_ADMIN" ;;
  esac
  echo "Waiting for $endpoint to become healthy..."
  for ((attempt = 1; attempt <= 120; attempt++)); do
    if [[ "$(command curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' -u "$admin" "$endpoint/" 2>/dev/null)" == "200" ]]; then
      echo "$endpoint is healthy."
      break
    fi
    echo "  attempt $attempt/120 - retrying in 2s..."
    sleep 2
  done
  if (( attempt > 120 )); then
    echo "Timed out waiting for $endpoint" >&2
    docker compose logs --tail 40 >&2
    exit 1
  fi
done

printf '\nSetup remote cluster connection:\n'
curl -sS -u "$OS2_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS2_SOURCE_URL/_cluster/settings" \
  -d '{"persistent":{"cluster.remote.os2-destination.seeds":["os2-destination:9300"]}}'

curl -sS -u "$OS3_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS3_SOURCE_URL/_cluster/settings" \
  -d '{"persistent":{"cluster.remote.os2-destination.seeds":["os2-destination:9300"]}}'

printf '\nSetup security config:\n'
curl -sS -u "$OS2_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS2_SOURCE_URL/_plugins/_security/api/internalusers/$CCS_USER" \
    -d '{"password":"'"$CCS_PASSWORD"'","backend_roles":[],"attributes":{}}'

curl -sS -u "$OS3_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS3_SOURCE_URL/_plugins/_security/api/internalusers/$CCS_USER" \
    -d '{"password":"'"$CCS_PASSWORD"'","backend_roles":[],"attributes":{}}'

curl -sS -u "$OS2_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS2_SOURCE_URL/_plugins/_security/api/roles/ccs_source_read" \
  -d '{"cluster_permissions":[],"index_permissions":[{"index_patterns":["*"],"allowed_actions":["read"]}],"tenant_permissions":[]}'

curl -sS -u "$OS3_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS3_SOURCE_URL/_plugins/_security/api/roles/ccs_source_read" \
  -d '{"cluster_permissions":[],"index_permissions":[{"index_patterns":["*"],"allowed_actions":["read"]}],"tenant_permissions":[]}'

curl -sS -u "$OS2_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS2_SOURCE_URL/_plugins/_security/api/rolesmapping/ccs_source_read" \
  -d '{"users":["'$CCS_USER'"],"backend_roles":[]}'

curl -sS -u "$OS3_ADMIN" -H 'Content-Type: application/json' -X PUT "$OS3_SOURCE_URL/_plugins/_security/api/rolesmapping/ccs_source_read" \
  -d '{"users":["'$CCS_USER'"],"backend_roles":[]}'

curl -sS -u "$DESTINATION_ADMIN" -H 'Content-Type: application/json' -X PUT "$DESTINATION_URL/_plugins/_security/api/roles/ccs_source_read" \
  -d '{"cluster_permissions":[],"index_permissions":[{"index_patterns":["remote-data"],"allowed_actions":["read"]}],"tenant_permissions":[]}'

curl -sS -u "$DESTINATION_ADMIN" -H 'Content-Type: application/json' -X PUT "$DESTINATION_URL/_plugins/_security/api/rolesmapping/ccs_source_read" \
  -d '{"users":[],"backend_roles":["ccs_source_read"]}'

printf '\nSetup dummy data:\n'
curl -sS -u "$DESTINATION_ADMIN" -H 'Content-Type: application/json' -X PUT "$DESTINATION_URL/remote-data" \
  -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}'

curl -sS -u "$DESTINATION_ADMIN" -H 'Content-Type: application/json' -X PUT "$DESTINATION_URL/remote-data/_doc/known" \
  -d '{"name":"known"}'

curl -sS -u "$DESTINATION_ADMIN" -X POST "$DESTINATION_URL/remote-data/_refresh"

printf '\nVerify remote connection:\n'
curl -sS -u "$OS2_ADMIN" "$OS2_SOURCE_URL/_remote/info"

curl -sS -u "$OS3_ADMIN" "$OS3_SOURCE_URL/_remote/info"

printf '\nOS2 -> OS2 source search (expected 200):\n'
curl -sS -u "$CCS_USER:$CCS_PASSWORD" \
  "$OS2_SOURCE_URL/os2-destination:remote-data/_search"

printf '\nOS3 -> OS3 source search (expected 403):\n'
curl -sS -u "$CCS_USER:$CCS_PASSWORD" \
  "$OS3_SOURCE_URL/os2-destination:remote-data/_search"

printf '\nSetup rolesmapping on OS3:\n'
curl -sS -u "$DESTINATION_ADMIN" -H 'Content-Type: application/json' -X PUT \
  "$DESTINATION_URL/_plugins/_security/api/rolesmapping/ccs_source_read" \
  -d '{"users":["'$CCS_USER'"],"backend_roles":[]}'

curl -sS -u "$DESTINATION_ADMIN" -X DELETE "$DESTINATION_URL/_plugins/_security/api/cache"

printf '\nOS3 -> OS3 source search after destination mapping (expected 200):\n'
curl -sS -u "$CCS_USER:$CCS_PASSWORD" \
  "$OS3_SOURCE_URL/os2-destination:remote-data/_search"