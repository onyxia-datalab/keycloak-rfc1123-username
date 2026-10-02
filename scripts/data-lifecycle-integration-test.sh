#!/usr/bin/env bash

set -euo pipefail

old_keycloak_version=${1:?Usage: data-lifecycle-integration-test.sh OLD_KEYCLOAK_VERSION NEW_KEYCLOAK_VERSION [PROVIDER_JAR]}
new_keycloak_version=${2:?Usage: data-lifecycle-integration-test.sh OLD_KEYCLOAK_VERSION NEW_KEYCLOAK_VERSION [PROVIDER_JAR]}
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provider_jar=${3:-"$repository_root/target/keycloak-rfc1123-username.jar"}
test_port=${KEYCLOAK_LIFECYCLE_TEST_PORT:-19093}
base_url="http://127.0.0.1:${test_port}"
realm_name=rfc1123-lifecycle
admin_username=rfc1123-admin
admin_password=rfc1123-admin-password
client_secret=rfc1123-client-secret
postgres_password=rfc1123-postgres-password
postgres_container=
server_pid=
stage=initialization

if [[ ! -f "$provider_jar" ]]; then
    printf 'Provider JAR does not exist: %s\n' "$provider_jar" >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    printf '%s\n' 'Docker is required for the data-lifecycle integration test.' >&2
    exit 1
fi

provider_jar=$(cd "$(dirname "$provider_jar")" && pwd)/$(basename "$provider_jar")
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/keycloak-rfc1123-lifecycle.XXXXXX")
server_log="$test_directory/keycloak.log"

cleanup() {
    local exit_status=$?
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$postgres_container" ]]; then
        docker rm -f "$postgres_container" >/dev/null 2>&1 || true
    fi
    if (( exit_status == 0 )); then
        case "$test_directory" in
            "${TMPDIR:-/tmp}"/keycloak-rfc1123-lifecycle.*) rm -rf -- "$test_directory" ;;
        esac
    else
        printf 'Integration stage failed: %s\n' "$stage" >&2
        printf 'Preserved failed integration environment: %s\n' "$test_directory" >&2
        printf '%s\n' '--- Keycloak log ---' >&2
        tail -200 "$server_log" >&2 || true
    fi
}
trap cleanup EXIT

fail() {
    printf 'Data-lifecycle integration test failed: %s\n' "$1" >&2
    exit 1
}

assert_equals() {
    local expected=$1
    local actual=$2
    local description=$3
    if [[ "$expected" != "$actual" ]]; then
        fail "$description: expected '$expected', got '$actual'"
    fi
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
    local attempt
    for attempt in $(seq 1 120); do
        if curl -fsS "$base_url/realms/master/.well-known/openid-configuration" \
                >/dev/null 2>&1; then
            return
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            fail "Keycloak exited before becoming available"
        fi
        sleep 1
    done
    fail "Keycloak did not become available within 120 seconds"
}

start_server() {
    local keycloak_home=$1
    local database_name=$2
    KC_DB=postgres \
    KC_DB_URL="jdbc:postgresql://127.0.0.1:$postgres_port/$database_name" \
    KC_DB_USERNAME=keycloak \
    KC_DB_PASSWORD="$postgres_password" \
    KC_CACHE=local \
    KEYCLOAK_ADMIN="$admin_username" \
    KEYCLOAK_ADMIN_PASSWORD="$admin_password" \
    KC_BOOTSTRAP_ADMIN_USERNAME="$admin_username" \
    KC_BOOTSTRAP_ADMIN_PASSWORD="$admin_password" \
        "$keycloak_home/bin/kc.sh" start-dev --http-port="$test_port" >>"$server_log" 2>&1 &
    server_pid=$!
    wait_for_server
}

stop_server() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid"
        wait "$server_pid" || true
    fi
    server_pid=
}

admin_token() {
    curl -sS --fail-with-body \
        -d grant_type=password \
        -d client_id=admin-cli \
        --data-urlencode "username=$admin_username" \
        --data-urlencode "password=$admin_password" \
        "$base_url/realms/master/protocol/openid-connect/token" \
        | jq -er .access_token
}

password_token() {
    local username=$1
    curl -sS --fail-with-body \
        -u "onyxia:$client_secret" \
        -d grant_type=password \
        -d scope=openid \
        --data-urlencode "username=$username" \
        --data-urlencode password=password \
        "$base_url/realms/$realm_name/protocol/openid-connect/token" \
        | jq -er .access_token
}

find_user_id() {
    local access_token=$1
    local username=$2
    curl -fsS -G \
        -H "Authorization: Bearer $access_token" \
        --data-urlencode "username=$username" \
        --data exact=true \
        "$base_url/admin/realms/$realm_name/users" \
        | jq -er '.[0].id'
}

assignment_count() {
    local database_name=$1
    docker exec -e PGPASSWORD="$postgres_password" "$postgres_container" \
        psql -X -A -t -U keycloak -d "$database_name" \
        -c 'SELECT COUNT(*) FROM RFC1123_USERNAME_ASSIGNMENT'
}

run_import() {
    local input_file=$1
    docker run --rm \
        --network "container:$postgres_container" \
        -e PGPASSWORD="$postgres_password" \
        -v "$repository_root/scripts/import-assignments-postgresql.sh:/work/importer.sh:ro" \
        -v "$input_file:/work/import.csv:ro" \
        postgres:16-alpine \
        sh /work/importer.sh /work/import.csv -X -h 127.0.0.1 -U keycloak -d keycloak
}

prepare_distribution() {
    local version=$1
    local distribution
    local destination="$test_directory/keycloak-$version"
    local maven_repository=${MAVEN_REPOSITORY_LOCAL:-"$HOME/.m2/repository"}
    distribution="$maven_repository/org/keycloak/keycloak-quarkus-dist/$version/keycloak-quarkus-dist-$version.zip"
    if [[ ! -f "$distribution" ]]; then
        mvn -q dependency:get -Dartifact="org.keycloak:keycloak-quarkus-dist:$version:zip"
    fi
    unzip -q "$distribution" -d "$test_directory"
    cp "$provider_jar" "$destination/providers/keycloak-rfc1123-username.jar"
    KC_DB=postgres "$destination/bin/kc.sh" build >>"$server_log" 2>&1
}

stage='PostgreSQL startup'
postgres_container="keycloak-rfc1123-lifecycle-$$"
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
prepare_distribution "$old_keycloak_version"
prepare_distribution "$new_keycloak_version"
old_keycloak_home="$test_directory/keycloak-$old_keycloak_version"
new_keycloak_home="$test_directory/keycloak-$new_keycloak_version"

stage="Keycloak $old_keycloak_version startup"
start_server "$old_keycloak_home" keycloak

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
      "directAccessGrantsEnabled": true
    }
  ],
  "users": [
    {
      "username": "Legacy.User",
      "firstName": "Legacy",
      "lastName": "User",
      "email": "legacy.user@example.test",
      "emailVerified": true,
      "enabled": true,
      "credentials": [{"type": "password", "value": "password", "temporary": false}]
    },
    {
      "username": "Upgrade.User",
      "firstName": "Upgrade",
      "lastName": "User",
      "email": "upgrade.user@example.test",
      "emailVerified": true,
      "enabled": true,
      "credentials": [{"type": "password", "value": "password", "temporary": false}]
    }
  ]
}
EOF

stage='realm creation before mapper enablement'
admin_access_token=$(admin_token)
curl -fsS -o /dev/null \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "@$test_directory/realm.json" \
    "$base_url/admin/realms"
realm_id=$(curl -fsS \
    -H "Authorization: Bearer $admin_access_token" \
    "$base_url/admin/realms/$realm_name" | jq -er .id)
legacy_user_id=$(find_user_id "$admin_access_token" Legacy.User)
upgrade_user_id=$(find_user_id "$admin_access_token" Upgrade.User)

cat >"$test_directory/invalid-import.csv" <<EOF
realm_id,user_id,identifier
$realm_id,$legacy_user_id,existing-onyxia-user
$realm_id,$upgrade_user_id,INVALID_IDENTIFIER
EOF

stage='transactional import validation'
if run_import "$test_directory/invalid-import.csv" >"$test_directory/invalid-import.log" 2>&1; then
    fail 'invalid assignment import unexpectedly succeeded'
fi
assert_equals 0 "$(assignment_count keycloak)" 'failed import rollback'

cat >"$test_directory/valid-import.csv" <<EOF
realm_id,user_id,identifier
$realm_id,$legacy_user_id,existing-onyxia-user
EOF
run_import "$test_directory/valid-import.csv"
run_import "$test_directory/valid-import.csv"
assert_equals 1 "$(assignment_count keycloak)" 'idempotent existing-assignment import'

stage='mapper enablement after import'
client_uuid=$(curl -fsS -G \
    -H "Authorization: Bearer $admin_access_token" \
    --data-urlencode clientId=onyxia \
    "$base_url/admin/realms/$realm_name/clients" | jq -er '.[0].id')
cat >"$test_directory/mapper.json" <<'EOF'
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
EOF
curl -fsS -o /dev/null \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "@$test_directory/mapper.json" \
    "$base_url/admin/realms/$realm_name/clients/$client_uuid/protocol-mappers/models"

stage='assignment verification before upgrade'
legacy_access_token=$(password_token Legacy.User)
upgrade_access_token=$(password_token Upgrade.User)
assert_equals existing-onyxia-user \
    "$(jwt_claim "$legacy_access_token" onyxia-username)" \
    'imported assignment after mapper enablement'
assert_equals upgrade-user \
    "$(jwt_claim "$upgrade_access_token" onyxia-username)" \
    'ordinary pre-upgrade allocation'
assert_equals 2 "$(assignment_count keycloak)" 'assignment count before backup'

stage='database backup'
stop_server
docker exec -e PGPASSWORD="$postgres_password" "$postgres_container" \
    pg_dump -U keycloak -d keycloak -Fc >"$test_directory/keycloak.dump"

stage="upgrade from Keycloak $old_keycloak_version to $new_keycloak_version"
start_server "$new_keycloak_home" keycloak
legacy_access_token=$(password_token Legacy.User)
upgrade_access_token=$(password_token Upgrade.User)
assert_equals existing-onyxia-user \
    "$(jwt_claim "$legacy_access_token" onyxia-username)" \
    'imported assignment after Keycloak upgrade'
assert_equals upgrade-user \
    "$(jwt_claim "$upgrade_access_token" onyxia-username)" \
    'allocated assignment after Keycloak upgrade'
stop_server

stage='database restore'
docker exec -e PGPASSWORD="$postgres_password" "$postgres_container" \
    createdb -U keycloak keycloak_restored
docker exec -i -e PGPASSWORD="$postgres_password" "$postgres_container" \
    pg_restore -U keycloak -d keycloak_restored --no-owner --no-privileges \
    <"$test_directory/keycloak.dump"
assert_equals 2 "$(assignment_count keycloak_restored)" 'restored assignment count'

stage="Keycloak $new_keycloak_version startup on restored database"
start_server "$new_keycloak_home" keycloak_restored
legacy_access_token=$(password_token Legacy.User)
upgrade_access_token=$(password_token Upgrade.User)
assert_equals existing-onyxia-user \
    "$(jwt_claim "$legacy_access_token" onyxia-username)" \
    'imported assignment after database restore'
assert_equals upgrade-user \
    "$(jwt_claim "$upgrade_access_token" onyxia-username)" \
    'allocated assignment after database restore'

stage=complete
printf 'Keycloak %s to %s data-lifecycle integration test passed.\n' \
    "$old_keycloak_version" "$new_keycloak_version"
