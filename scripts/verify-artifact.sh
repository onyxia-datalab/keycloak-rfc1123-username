#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provider_jar=${1:-"$repository_root/target/keycloak-rfc1123-username.jar"}
expected_major_version=61

if [[ ! -f "$provider_jar" ]]; then
    printf 'Provider JAR does not exist: %s\n' "$provider_jar" >&2
    exit 1
fi

major_version=$(javap -verbose \
    -classpath "$provider_jar" \
    io.onyxia.keycloak.rfc1123.Rfc1123UsernameMapper \
    | awk '/major version:/ { print $3; exit }')
if [[ "$major_version" != "$expected_major_version" ]]; then
    printf 'Expected Java 17 class-file version %s, got %s\n' \
        "$expected_major_version" "${major_version:-missing}" >&2
    exit 1
fi

jar_entries=$(jar tf "$provider_jar")
for required_entry in \
    META-INF/services/org.keycloak.protocol.ProtocolMapper \
    META-INF/services/org.keycloak.connections.jpa.entityprovider.JpaEntityProviderFactory \
    META-INF/rfc1123-username-changelog.xml; do
    if ! grep -Fxq "$required_entry" <<<"$jar_entries"; then
        printf 'Provider JAR is missing required entry: %s\n' "$required_entry" >&2
        exit 1
    fi
done

if grep -q '^org/keycloak/' <<<"$jar_entries"; then
    printf '%s\n' 'Provider JAR unexpectedly bundles Keycloak classes.' >&2
    exit 1
fi

printf 'Verified Java 17 provider artifact: %s\n' "$provider_jar"
