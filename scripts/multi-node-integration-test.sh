#!/usr/bin/env bash

set -euo pipefail

keycloak_version=${1:?Usage: multi-node-integration-test.sh KEYCLOAK_VERSION [PROVIDER_JAR]}
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provider_jar=${2:-"$repository_root/target/keycloak-rfc1123-username.jar"}
node_one_port=${KEYCLOAK_NODE_ONE_PORT:-19091}
node_two_port=${KEYCLOAK_NODE_TWO_PORT:-19092}
realm_name=rfc1123-multi-node
admin_username=rfc1123-admin
admin_password=rfc1123-admin-password
client_secret=rfc1123-client-secret
postgres_password=rfc1123-postgres-password
node_one_pid=
node_two_pid=
postgres_container=
stage=initialization

if [[ ! -f "$provider_jar" ]]; then
    printf 'Provider JAR does not exist: %s\n' "$provider_jar" >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    printf '%s\n' 'Docker is required for the PostgreSQL multi-node integration test.' >&2
    exit 1
fi

provider_jar=$(cd "$(dirname "$provider_jar")" && pwd)/$(basename "$provider_jar")
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/keycloak-rfc1123-multi-node.XXXXXX")
node_one_log="$test_directory/keycloak-node-1.log"
node_two_log="$test_directory/keycloak-node-2.log"

cleanup() {
    local exit_status=$?
    local pid
    for pid in "$node_one_pid" "$node_two_pid"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    if [[ -n "$postgres_container" ]]; then
        docker rm -f "$postgres_container" >/dev/null 2>&1 || true
    fi
    if (( exit_status == 0 )); then
        case "$test_directory" in
            "${TMPDIR:-/tmp}"/keycloak-rfc1123-multi-node.*) rm -rf -- "$test_directory" ;;
        esac
    else
        printf 'Integration stage failed: %s\n' "$stage" >&2
        printf 'Preserved failed integration environment: %s\n' "$test_directory" >&2
        printf '%s\n' '--- Keycloak node 1 log ---' >&2
        tail -120 "$node_one_log" >&2 || true
        printf '%s\n' '--- Keycloak node 2 log ---' >&2
        tail -120 "$node_two_log" >&2 || true
    fi
}
trap cleanup EXIT

fail() {
    printf 'Multi-node integration test failed: %s\n' "$1" >&2
    exit 1
}

jwt_claim() {
    local token=$1
    local claim=$2
    local payload
    local padding

    payload=$(printf '%s' "$token" | cut -d. -f2 | tr '_-' '/+')
    padding=$(( (4 - ${#payload} % 4) % 4 ))
    while (( padding > 0 )); do
        payload="${payload}="
        padding=$((padding - 1))
    done
    printf '%s' "$payload" | openssl base64 -d -A | jq -er --arg claim "$claim" '.[$claim]'
}

wait_for_server() {
    local port=$1
    local pid=$2
    local attempt
    for attempt in $(seq 1 120); do
        if curl -fsS "http://127.0.0.1:$port/realms/master/.well-known/openid-configuration" \
                >/dev/null 2>&1; then
            return
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            fail "Keycloak on port $port exited before becoming available"
        fi
        sleep 1
    done
    fail "Keycloak on port $port did not become available within 120 seconds"
}

start_node() {
    local port=$1
    local log_file=$2
    local pid_variable=$3
    local node_home=$4
    local management_port=$((port + 10000))
    KC_DB=postgres \
    KC_DB_URL="jdbc:postgresql://127.0.0.1:$postgres_port/keycloak" \
    KC_DB_USERNAME=keycloak \
    KC_DB_PASSWORD="$postgres_password" \
    KC_CACHE=local \
    KC_HTTP_MANAGEMENT_PORT="$management_port" \
    KEYCLOAK_ADMIN="$admin_username" \
    KEYCLOAK_ADMIN_PASSWORD="$admin_password" \
    KC_BOOTSTRAP_ADMIN_USERNAME="$admin_username" \
    KC_BOOTSTRAP_ADMIN_PASSWORD="$admin_password" \
        "$node_home/bin/kc.sh" start-dev --http-port="$port" >>"$log_file" 2>&1 &
    local started_pid=$!
    printf -v "$pid_variable" '%s' "$started_pid"
    wait_for_server "$port" "$started_pid"
}

admin_token() {
    curl -sS --fail-with-body \
        -d grant_type=password \
        -d client_id=admin-cli \
        --data-urlencode "username=$admin_username" \
        --data-urlencode "password=$admin_password" \
        "http://127.0.0.1:$node_one_port/realms/master/protocol/openid-connect/token" \
        | jq -er .access_token
}

password_tokens() {
    local port=$1
    local username=$2
    curl -sS --fail-with-body \
        -u "onyxia:$client_secret" \
        -d grant_type=password \
        -d scope=openid \
        --data-urlencode "username=$username" \
        --data-urlencode password=password \
        "http://127.0.0.1:$port/realms/$realm_name/protocol/openid-connect/token"
}

warmup_tokens() {
    local port=$1
    local username=$2
    curl -sS --fail-with-body \
        -u "warmup:$client_secret" \
        -d grant_type=password \
        --data-urlencode "username=$username" \
        --data-urlencode password=password \
        "http://127.0.0.1:$port/realms/$realm_name/protocol/openid-connect/token"
}

stage='PostgreSQL startup'
postgres_container="keycloak-rfc1123-postgres-$$"
docker run --detach --rm \
    --name "$postgres_container" \
    -e POSTGRES_DB=keycloak \
    -e POSTGRES_USER=keycloak \
    -e "POSTGRES_PASSWORD=$postgres_password" \
    -p 127.0.0.1::5432 \
    postgres:16-alpine >/dev/null
postgres_port=$(docker port "$postgres_container" 5432/tcp | awk -F: 'NR == 1 { print $NF }')
if [[ -z "$postgres_port" ]]; then
    fail 'could not determine the PostgreSQL host port'
fi
for attempt in $(seq 1 60); do
    if docker exec "$postgres_container" pg_isready -U keycloak -d keycloak >/dev/null 2>&1; then
        break
    fi
    if (( attempt == 60 )); then
        fail 'PostgreSQL did not become ready within 60 seconds'
    fi
    sleep 1
done

stage='Keycloak distribution preparation'
maven_repository=${MAVEN_REPOSITORY_LOCAL:-"$HOME/.m2/repository"}
distribution="$maven_repository/org/keycloak/keycloak-quarkus-dist/$keycloak_version/keycloak-quarkus-dist-$keycloak_version.zip"
if [[ ! -f "$distribution" ]]; then
    mvn -q dependency:get -Dartifact="org.keycloak:keycloak-quarkus-dist:$keycloak_version:zip"
fi
unzip -q "$distribution" -d "$test_directory"
keycloak_home="$test_directory/keycloak-$keycloak_version"
cp "$provider_jar" "$keycloak_home/providers/keycloak-rfc1123-username.jar"
KC_DB=postgres "$keycloak_home/bin/kc.sh" build >>"$node_one_log" 2>&1
node_one_home="$test_directory/keycloak-node-1"
node_two_home="$test_directory/keycloak-node-2"
cp -R "$keycloak_home" "$node_one_home"
cp -R "$keycloak_home" "$node_two_home"

stage='first Keycloak node startup'
start_node "$node_one_port" "$node_one_log" node_one_pid "$node_one_home"

cat >"$test_directory/realm.json" <<EOF
{
  "realm": "$realm_name",
  "enabled": true,
  "clients": [
    {
      "clientId": "onyxia",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "$client_secret",
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "protocolMappers": [
        {
          "name": "RFC1123 Username",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-rfc1123-username-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "onyxia-username",
            "access.token.claim": "true",
            "id.token.claim": "true"
          }
        }
      ]
    },
    {
      "clientId": "warmup",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "$client_secret",
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true
    }
  ],
  "users": [
    {"username": "Race.User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race_User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race+User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race@User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race..User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race__User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]},
    {"username": "Race++User", "enabled": true, "credentials": [{"type": "password", "value": "password", "temporary": false}]}
  ]
}
EOF
jq '
  .users |= (
    to_entries
    | map(
        .value
        + {
            firstName: "Race",
            lastName: "User",
            email: ("race" + (.key | tostring) + "@example.test"),
            emailVerified: true
          }
      )
  )
' "$test_directory/realm.json" >"$test_directory/realm-complete.json"
mv "$test_directory/realm-complete.json" "$test_directory/realm.json"

stage='realm creation'
admin_access_token=$(admin_token)
curl -fsS -o /dev/null \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "@$test_directory/realm.json" \
    "http://127.0.0.1:$node_one_port/admin/realms"

stage='second Keycloak node startup'
start_node "$node_two_port" "$node_two_log" node_two_pid "$node_two_home"

stage='node cache warm-up'
warmup_tokens "$node_one_port" Race.User >/dev/null
warmup_tokens "$node_two_port" Race.User >/dev/null

stage='concurrent cross-node allocation'
usernames=(
    'Race.User'
    'Race_User'
    'Race+User'
    'Race@User'
    'Race User'
    'Race..User'
    'Race__User'
    'Race++User'
)
request_pids=()
request_ports=()
gate="$test_directory/start-concurrent-requests"
for index in "${!usernames[@]}"; do
    if (( index % 2 == 0 )); then
        request_ports[$index]=$node_one_port
    else
        request_ports[$index]=$node_two_port
    fi
    (
        while [[ ! -e "$gate" ]]; do sleep 0.01; done
        password_tokens "${request_ports[$index]}" "${usernames[$index]}"
    ) >"$test_directory/token-$index.json" 2>"$test_directory/token-$index.err" &
    request_pids[$index]=$!
done
touch "$gate"

for index in "${!request_pids[@]}"; do
    if ! wait "${request_pids[$index]}"; then
        cat "$test_directory/token-$index.err" >&2 || true
        fail "token request failed for ${usernames[$index]} on port ${request_ports[$index]}"
    fi
done

: >"$test_directory/actual-identifiers.txt"
for index in "${!usernames[@]}"; do
    access_token=$(jq -er .access_token "$test_directory/token-$index.json")
    identifier=$(jwt_claim "$access_token" onyxia-username)
    printf '%s\n' "$identifier" >>"$test_directory/actual-identifiers.txt"
    printf '%s' "$identifier" >"$test_directory/identifier-$index.txt"
done
sort -o "$test_directory/actual-identifiers.txt" "$test_directory/actual-identifiers.txt"
{
    printf '%s\n' race-user
    for suffix in $(seq 2 "${#usernames[@]}"); do
        printf 'race-user-%s\n' "$suffix"
    done
} | sort >"$test_directory/expected-identifiers.txt"
if ! diff -u "$test_directory/expected-identifiers.txt" "$test_directory/actual-identifiers.txt"; then
    fail 'concurrent allocation did not produce the complete unique candidate sequence'
fi

stage='cross-node assignment stability'
for index in "${!usernames[@]}"; do
    if [[ "${request_ports[$index]}" == "$node_one_port" ]]; then
        opposite_port=$node_two_port
    else
        opposite_port=$node_one_port
    fi
    repeated_tokens=$(password_tokens "$opposite_port" "${usernames[$index]}")
    repeated_access_token=$(jq -er .access_token <<<"$repeated_tokens")
    repeated_identifier=$(jwt_claim "$repeated_access_token" onyxia-username)
    original_identifier=$(cat "$test_directory/identifier-$index.txt")
    if [[ "$original_identifier" != "$repeated_identifier" ]]; then
        fail "assignment changed across nodes for ${usernames[$index]}: $original_identifier to $repeated_identifier"
    fi
done

stage=complete
printf 'Keycloak %s multi-node PostgreSQL integration test passed.\n' "$keycloak_version"
