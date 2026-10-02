#!/usr/bin/env bash

set -euo pipefail

keycloak_version=${1:?Usage: integration-test.sh KEYCLOAK_VERSION [PROVIDER_JAR]}
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provider_jar=${2:-"$repository_root/target/keycloak-rfc1123-username.jar"}
test_port=${KEYCLOAK_TEST_PORT:-19090}
base_url="http://127.0.0.1:${test_port}"
realm_name=rfc1123-integration
isolated_realm_name=rfc1123-isolated
admin_username=rfc1123-admin
admin_password=rfc1123-admin-password
client_secret=rfc1123-client-secret
server_pid=
stage=initialization

if [[ ! -f "$provider_jar" ]]; then
    printf 'Provider JAR does not exist: %s\n' "$provider_jar" >&2
    exit 1
fi

provider_jar=$(cd "$(dirname "$provider_jar")" && pwd)/$(basename "$provider_jar")
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/keycloak-rfc1123-test.XXXXXX")
server_log="$test_directory/keycloak.log"

cleanup() {
    local exit_status=$?
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if (( exit_status == 0 )); then
        case "$test_directory" in
            "${TMPDIR:-/tmp}"/keycloak-rfc1123-test.*) rm -rf -- "$test_directory" ;;
        esac
    else
        printf 'Integration stage failed: %s\n' "$stage" >&2
        printf 'Preserved failed integration environment: %s\n' "$test_directory" >&2
        tail -200 "$server_log" >&2 || true
    fi
}
trap cleanup EXIT

fail() {
    printf 'Integration test failed: %s\n' "$1" >&2
    printf '%s\n' '--- Keycloak log ---' >&2
    tail -200 "$server_log" >&2 || true
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
        if curl -fsS "$base_url/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
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

password_tokens() {
    local client_id=$1
    local username=$2
    local realm=${3:-$realm_name}
    curl -sS --fail-with-body \
        -u "$client_id:$client_secret" \
        -d grant_type=password \
        -d scope=openid \
        --data-urlencode "username=$username" \
        --data-urlencode password=password \
        "$base_url/realms/$realm/protocol/openid-connect/token"
}

maven_repository=${MAVEN_REPOSITORY_LOCAL:-"$HOME/.m2/repository"}
distribution="$maven_repository/org/keycloak/keycloak-quarkus-dist/$keycloak_version/keycloak-quarkus-dist-$keycloak_version.zip"
if [[ ! -f "$distribution" ]]; then
    mvn -q dependency:get -Dartifact="org.keycloak:keycloak-quarkus-dist:$keycloak_version:zip"
fi

unzip -q "$distribution" -d "$test_directory"
keycloak_home="$test_directory/keycloak-$keycloak_version"
cp "$provider_jar" "$keycloak_home/providers/keycloak-rfc1123-username.jar"

stage='Keycloak build and startup'
"$keycloak_home/bin/kc.sh" build >>"$server_log" 2>&1
start_server

cat >"$test_directory/realm.json" <<EOF
{
  "realm": "$realm_name",
  "enabled": true,
  "editUsernameAllowed": true,
  "clients": [
    {
      "clientId": "onyxia",
      "name": "Onyxia",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "$client_secret",
      "standardFlowEnabled": true,
      "redirectUris": ["http://127.0.0.1:17777/*"],
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": true,
      "protocolMappers": [
        {
          "name": "RFC1123 Username",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-rfc1123-username-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "onyxia-username",
            "access.token.claim": "true",
            "id.token.claim": "true",
            "userinfo.token.claim": "true",
            "introspection.token.claim": "true",
            "lightweight.claim": "true"
          }
        },
        {
          "name": "Onyxia audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": {
            "included.client.audience": "onyxia",
            "access.token.claim": "true",
            "id.token.claim": "false",
            "introspection.token.claim": "true"
          }
        }
      ]
    },
    {
      "clientId": "onyxia-lightweight",
      "name": "Onyxia lightweight token test",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "$client_secret",
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "attributes": {
        "client.use.lightweight.access.token.enabled": "true"
      },
      "protocolMappers": [
        {
          "name": "RFC1123 Username",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-rfc1123-username-mapper",
          "consentRequired": false,
          "config": {
            "claim.name": "onyxia-username",
            "access.token.claim": "true",
            "id.token.claim": "true",
            "userinfo.token.claim": "true",
            "introspection.token.claim": "true",
            "lightweight.claim": "true"
          }
        }
      ]
    }
  ],
  "users": [
    {
      "username": "Alice.Martin",
      "firstName": "Alice",
      "lastName": "Martin",
      "email": "alice.martin@example.test",
      "emailVerified": true,
      "enabled": true,
      "credentials": [{"type": "password", "value": "password", "temporary": false}]
    },
    {
      "username": "Alice-Martin",
      "firstName": "Alice",
      "lastName": "Martin",
      "email": "alice.collision@example.test",
      "emailVerified": true,
      "enabled": true,
      "credentials": [{"type": "password", "value": "password", "temporary": false}]
    }
  ]
}
EOF

stage='realm creation'
admin_access_token=$(admin_token)
curl -fsS -o /dev/null \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "@$test_directory/realm.json" \
    "$base_url/admin/realms"

jq --arg realm "$isolated_realm_name" '
  .realm = $realm
  | .users = [.users[0]]
  | .users[0].email = "alice.isolated@example.test"
' "$test_directory/realm.json" >"$test_directory/isolated-realm.json"
curl -fsS -o /dev/null \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "@$test_directory/isolated-realm.json" \
    "$base_url/admin/realms"

stage='access and ID token claims'
alice_tokens=$(password_tokens onyxia Alice.Martin)
alice_access_token=$(jq -er .access_token <<<"$alice_tokens")
alice_id_token=$(jq -er .id_token <<<"$alice_tokens")
assert_equals alice-martin "$(jwt_claim "$alice_access_token" onyxia-username)" "access token claim"
assert_equals alice-martin "$(jwt_claim "$alice_id_token" onyxia-username)" "ID token claim"

stage='refresh-token stability'
alice_refresh_token=$(jq -er .refresh_token <<<"$alice_tokens")
refreshed_tokens=$(curl -sS --fail-with-body \
    -u "onyxia:$client_secret" \
    -d grant_type=refresh_token \
    --data-urlencode "refresh_token=$alice_refresh_token" \
    "$base_url/realms/$realm_name/protocol/openid-connect/token")
refreshed_access_token=$(jq -er .access_token <<<"$refreshed_tokens")
assert_equals alice-martin \
    "$(jwt_claim "$refreshed_access_token" onyxia-username)" \
    "refresh-token stability"

stage='UserInfo claim'
userinfo_claim=$(curl -fsS \
    -H "Authorization: Bearer $alice_access_token" \
    "$base_url/realms/$realm_name/protocol/openid-connect/userinfo" \
    | jq -er '."onyxia-username"')
assert_equals alice-martin "$userinfo_claim" "UserInfo claim"

stage='introspection claim'
introspection_claim=$(curl -fsS \
    -u "onyxia:$client_secret" \
    -d "token=$alice_access_token" \
    "$base_url/realms/$realm_name/protocol/openid-connect/token/introspect" \
    | jq -er '."onyxia-username"')
assert_equals alice-martin "$introspection_claim" "introspection claim"

stage='collision allocation'
collision_tokens=$(password_tokens onyxia Alice-Martin)
collision_access_token=$(jq -er .access_token <<<"$collision_tokens")
assert_equals alice-martin-2 "$(jwt_claim "$collision_access_token" onyxia-username)" "collision suffix"

stage='realm-isolated allocation'
isolated_tokens=$(password_tokens onyxia Alice.Martin "$isolated_realm_name")
isolated_access_token=$(jq -er .access_token <<<"$isolated_tokens")
assert_equals alice-martin \
    "$(jwt_claim "$isolated_access_token" onyxia-username)" \
    "realm-isolated allocation"

stage='lightweight token claim'
lightweight_tokens=$(password_tokens onyxia-lightweight Alice.Martin)
lightweight_access_token=$(jq -er .access_token <<<"$lightweight_tokens")
assert_equals alice-martin "$(jwt_claim "$lightweight_access_token" onyxia-username)" "lightweight access token claim"

stage='service-account claim'
service_account_tokens=$(curl -sS --fail-with-body \
    -u "onyxia:$client_secret" \
    -d grant_type=client_credentials \
    "$base_url/realms/$realm_name/protocol/openid-connect/token")
service_account_access_token=$(jq -er .access_token <<<"$service_account_tokens")
assert_equals service-account-onyxia \
    "$(jwt_claim "$service_account_access_token" onyxia-username)" \
    "service-account claim"

stage='profile-change stability'
admin_access_token=$(admin_token)
alice_user=$(curl -fsS -G \
    -H "Authorization: Bearer $admin_access_token" \
    --data-urlencode username=Alice.Martin \
    --data exact=true \
    "$base_url/admin/realms/$realm_name/users" | jq -er '.[0]')
alice_user_id=$(jq -er .id <<<"$alice_user")

stage='impersonated session claim'
impersonation_cookie_jar="$test_directory/impersonation.cookies"
curl -sS --fail-with-body -o "$test_directory/impersonation.json" \
    -c "$impersonation_cookie_jar" \
    -X POST \
    -H "Authorization: Bearer $admin_access_token" \
    "$base_url/admin/realms/$realm_name/users/$alice_user_id/impersonation"

impersonation_redirect_uri=http://127.0.0.1:17777/callback
curl -sS -o /dev/null -D "$test_directory/impersonation-auth.headers" \
    -b "$impersonation_cookie_jar" \
    -G \
    --data-urlencode client_id=onyxia \
    --data-urlencode response_type=code \
    --data-urlencode scope=openid \
    --data-urlencode "redirect_uri=$impersonation_redirect_uri" \
    "$base_url/realms/$realm_name/protocol/openid-connect/auth"
impersonation_location=$(awk '
    BEGIN { IGNORECASE = 1 }
    /^Location:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        sub(/\r$/, "")
        print
    }
' "$test_directory/impersonation-auth.headers" | tail -1)
impersonation_code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$impersonation_location")
if [[ -z "$impersonation_code" ]]; then
    fail "impersonated authorization did not return a code (location: $impersonation_location)"
fi
impersonated_tokens=$(curl -sS --fail-with-body \
    -u "onyxia:$client_secret" \
    -d grant_type=authorization_code \
    --data-urlencode "code=$impersonation_code" \
    --data-urlencode "redirect_uri=$impersonation_redirect_uri" \
    "$base_url/realms/$realm_name/protocol/openid-connect/token")
impersonated_access_token=$(jq -er .access_token <<<"$impersonated_tokens")
assert_equals alice-martin \
    "$(jwt_claim "$impersonated_access_token" onyxia-username)" \
    "impersonated session claim"

stage='profile-change stability'
updated_alice=$(jq '.username = "Alice.Changed"' <<<"$alice_user")
curl -fsS -o /dev/null -X PUT \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "$updated_alice" \
    "$base_url/admin/realms/$realm_name/users/$alice_user_id"

changed_tokens=$(password_tokens onyxia Alice.Changed)
changed_access_token=$(jq -er .access_token <<<"$changed_tokens")
assert_equals alice-martin "$(jwt_claim "$changed_access_token" onyxia-username)" "profile-change stability"

stage='restart stability'
stop_server
start_server

restarted_tokens=$(password_tokens onyxia Alice.Changed)
restarted_access_token=$(jq -er .access_token <<<"$restarted_tokens")
assert_equals alice-martin "$(jwt_claim "$restarted_access_token" onyxia-username)" "restart stability"

stage='deleted identifier reservation'
admin_access_token=$(admin_token)
curl -fsS -o /dev/null -X DELETE \
    -H "Authorization: Bearer $admin_access_token" \
    "$base_url/admin/realms/$realm_name/users/$alice_user_id"

cat >"$test_directory/recreated-user.json" <<'EOF'
{
  "username": "Alice.Martin",
  "firstName": "Alice",
  "lastName": "Martin",
  "email": "alice.recreated@example.test",
  "emailVerified": true,
  "enabled": true,
  "credentials": [{"type": "password", "value": "password", "temporary": false}]
}
EOF
curl -fsS -o /dev/null \
    -H "Authorization: Bearer $admin_access_token" \
    -H 'Content-Type: application/json' \
    --data-binary "@$test_directory/recreated-user.json" \
    "$base_url/admin/realms/$realm_name/users"

recreated_tokens=$(password_tokens onyxia Alice.Martin)
recreated_access_token=$(jq -er .access_token <<<"$recreated_tokens")
assert_equals alice-martin-3 "$(jwt_claim "$recreated_access_token" onyxia-username)" "deleted identifier reservation"

stage='complete'
printf 'Keycloak %s integration test passed.\n' "$keycloak_version"
