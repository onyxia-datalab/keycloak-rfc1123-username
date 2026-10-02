# keycloak-rfc1123-username

A Keycloak protocol mapper that generates a stable, unique, human-readable RFC1123-compliant identifier for each user and exposes it as a configurable OpenID Connect token claim.

Useful when applications need a readable username suitable for Kubernetes resource names, without depending on a mutable login name or email address.

The project produces one Java 17 provider JAR for Keycloak 24.x through 26.x. The compatibility suite currently tests the same baseline-built artifact on Keycloak 24.0.5, 25.0.6, and 26.7.4, including concurrent allocation by two Keycloak nodes sharing PostgreSQL.

## How it works

The mapper allocates an identifier when a user first needs one, persists the assignment against the Keycloak user's immutable ID (the usual OIDC `sub`), and reuses it for subsequent tokens.

- **RFC1123-compatible:** a single DNS label of at most 63 characters, using lowercase ASCII letters, digits, and hyphens, starting and ending with a letter or digit. Space must be reserved for any collision suffix.
- **Human-readable:** a readable base is derived from user information and normalized into an identifier.
- **Unique within a realm:** collisions receive predictable readable suffixes: `alice-martin`, `alice-martin-2`, `alice-martin-3`, and so on.
- **Stable:** the same Keycloak user always receives the same stored value, including after profile changes, logout, token refresh, or a server restart. Changing the output claim name does not allocate a new identifier.

Persistence is part of the contract: identifiers must not be recomputed on every login. Allocation must prevent duplicates even when multiple Keycloak instances handle concurrent requests. Stored assignments must survive upgrades and be preserved in backups and migrations. Deleting and recreating a user creates a new identity and does not guarantee the previous value.

The mapper adds a claim; it does not change the user's Keycloak username or replace `sub`.

## Install in Keycloak

Download the `v1.0.0` release artifact into the Keycloak `providers` directory:

```sh
curl -fSL \
  https://github.com/onyxia-datalab/keycloak-rfc1123-username/releases/download/v1.0.0/keycloak-rfc1123-username.jar \
  -o /opt/keycloak/providers/keycloak-rfc1123-username.jar

/opt/keycloak/bin/kc.sh build
```

The release also publishes `keycloak-rfc1123-username.jar.sha256` and a CycloneDX JSON SBOM. Verify a downloaded JAR with `sha256sum --check keycloak-rfc1123-username.jar.sha256`. GitHub CLI users can additionally verify its build provenance:

```sh
gh attestation verify keycloak-rfc1123-username.jar \
  --repo onyxia-datalab/keycloak-rfc1123-username
```

Restart Keycloak using your normal startup configuration. Adjust `/opt/keycloak` to your installation path and install the same provider version on every instance. For an optimized deployment, run the build after adding the JAR and before starting with `--optimized`; alternatively, bake the provider into your Keycloak image.

See Keycloak's [provider installation documentation](https://www.keycloak.org/server/configuration-provider).

### Kubernetes initContainer

This Pod-spec fragment preserves the Onyxia theme download and adds the mapper. Merge it into your deployment or adapt it to your Helm chart's values:

```yaml
initContainers:
  - name: realm-ext-provider
    image: curlimages/curl
    imagePullPolicy: IfNotPresent
    command:
      - sh
    args:
      - -c
      - |
        set -eu
        curl -L -f -S -o /extensions/theme-onyxia-web.jar https://github.com/InseeFrLab/onyxia/releases/download/v11.7.3/keycloak-theme.jar
        curl -L -f -S -o /extensions/rfc1123-username.jar https://github.com/onyxia-datalab/keycloak-rfc1123-username/releases/download/v1.0.0/keycloak-rfc1123-username.jar
    volumeMounts:
      - name: empty-dir
        mountPath: /extensions
        subPath: app-providers-dir

# Merge this mount into your existing Keycloak container.
containers:
  - name: keycloak
    # Keep your existing image, startup command, environment, and other settings.
    volumeMounts:
      - name: empty-dir
        mountPath: /opt/keycloak/providers
        subPath: app-providers-dir

volumes:
  - name: empty-dir
    emptyDir: {}
```

Both containers must mount the same volume and subpath. Ensure the volume is writable by the initContainer and readable by Keycloak, and adapt the provider path to your image. Mounting this directory hides any providers already baked into that image. Reuse an existing `empty-dir` volume if your chart already defines it.

The initContainer only downloads the JARs: Keycloak must still discover them during its build/startup process. An optimized startup needs a build after the downloads. The `emptyDir` holds provider binaries, **not persistent user-to-identifier assignments**.

## Configure the mapper

The mapper display name is **RFC1123 Username**, with `username-rfc1123` as the default claim name.

1. In the Keycloak Admin Console, select your realm and open **Clients → your client → Client scopes**.
2. Open the client's dedicated scope (typically `<client-id>-dedicated`), then **Mappers → Configure a new mapper**.
3. Select **RFC1123 Username** and give the mapper a descriptive name.
4. Set **Token Claim Name** to the claim your application expects.
5. Enable the switches your application needs: **Add to ID token**, **Add to access token**, **Add to lightweight access token**, **Add to userinfo**, and/or **Add to token introspection**. Save the mapper.

For multiple clients, a shared client scope can carry the mapper; assign it as a default scope, or request it explicitly if it is optional. See Keycloak's [client scope and protocol mapper documentation](https://www.keycloak.org/docs/latest/server_admin/).

Obtain a fresh token and check that the configured claim contains the identifier. Verify that repeat logins retain the same value and that users whose names normalize to the same base receive distinct values.

## Use with Onyxia

Add the mapper to the **`onyxia` client**, using its **`onyxia-dedicated`** client scope, and set **Token Claim Name** to **`onyxia-username`**. Include the claim in the ID token and access token; enable UserInfo inclusion if your integration uses it.

Example token payload (excerpt):

```json
{
  "sub": "8d948cf2-5537-4da9-9757-65d4953b632c",
  "preferred_username": "Alice.Martin",
  "onyxia-username": "alice-martin"
}
```

Configure Onyxia to read `onyxia-username` as its username claim. Keep `sub` as the underlying identity and use the generated claim wherever a readable RFC1123-compatible identifier is needed. When introducing the mapper to an existing deployment, preserve existing username assignments or plan their migration so users retain access to resources associated with their previous names.

### Import existing assignments on PostgreSQL

Import existing Onyxia identifiers before adding the mapper to any client. First install the provider and start Keycloak once so its assignment table exists. Prepare a CSV using the immutable Keycloak realm and user IDs (not realm names or usernames):

```csv
realm_id,user_id,identifier
8f72e68d-288d-4c45-a328-cba831c4b017,2d2bb574-2d20-4ce0-8ea2-47d8fa0ef8eb,alice-martin
```

Stop token traffic that could invoke the mapper, back up the database, and run the transactional importer with normal `psql` connection arguments or libpq environment variables:

```sh
PGPASSWORD='<database password>' \
  scripts/import-assignments-postgresql.sh assignments.csv \
  -h database.example.internal -U keycloak -d keycloak
```

The importer rejects invalid RFC1123 values, duplicate users or identifiers within a realm, unknown realm/user pairs, and conflicts with assignments already stored by the provider. Any invalid row rolls back the entire CSV. An identical import can be run again safely. Enable the mapper only after the import succeeds, then verify representative users before restoring normal traffic.

## Development

Build the provider, run the unit tests, generate the CycloneDX SBOM, and verify the JAR structure and Java 17 bytecode:

```sh
mvn spotless:check clean verify
scripts/verify-artifact.sh
```

Run the real-server suite for a supported Keycloak version:

```sh
scripts/integration-test.sh 26.7.4
```

The distributed allocation suite requires a running Docker daemon. It creates an ephemeral PostgreSQL container and two isolated Keycloak processes:

```sh
scripts/multi-node-integration-test.sh 26.7.4
```

The data-lifecycle suite validates a transactional existing-assignment import, an upgrade across the supported Keycloak range, and PostgreSQL backup/restore:

```sh
scripts/data-lifecycle-integration-test.sh 24.0.5 26.7.4
```

The Kubernetes deployment suite requires Docker, Kind, and kubectl. It reproduces the documented initContainer and shared `emptyDir`, then runs `kc.sh build` in the mounted Keycloak container:

```sh
scripts/kubernetes-integration-test.sh
```

The single-version integration scripts accept an optional provider-JAR path as their second argument; the data-lifecycle script accepts it as the third argument. CI builds the JAR once against Keycloak 24.0.5 and passes that unchanged artifact to every compatibility test.
