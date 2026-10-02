# Implementation roadmap

## 1. Define the contract

- [x] Choose the supported Keycloak and Java versions for the first release.
- [x] Confirm which user fields form the readable base, in priority order (for example `username`, then first and last name, then a neutral fallback).
- [x] Define normalization precisely: Unicode transliteration, lowercase conversion, invalid-character replacement, repeated-hyphen removal, and leading/trailing-hyphen removal.
- [x] Define the collision format (`name`, `name-2`, `name-3`, ...), including truncation so the final value never exceeds 63 characters.
- [x] Define fallback behavior when normalization produces an empty value.
- [x] Confirm uniqueness scope (one Keycloak realm) and whether deleted identifiers may ever be reused.
- [x] Decide how existing Onyxia usernames will be imported before enabling allocation in an existing realm.

## 2. Bootstrap the extension

- [x] Create the Maven project and pin compatible Keycloak SPI dependencies.
- [x] Configure a reproducible JAR build and keep Keycloak dependencies out of the packaged artifact when the server already provides them.
- [x] Add the protocol-mapper implementation and factory.
- [x] Register the mapper through `META-INF/services/org.keycloak.protocol.ProtocolMapper`.
- [x] Expose it in the Admin Console as **RFC1123 Username**.
- [x] Add mapper configuration for the token claim name, with `username-rfc1123` as the default.
- [x] Reuse Keycloak's standard switches for access token, ID token, UserInfo, and token introspection where supported.

## 3. Implement identifier generation

- [x] Implement the RFC1123 normalization function as a small, independent component.
- [x] Enforce the DNS-label rules: lowercase letters, digits, and hyphens only; alphanumeric first and last characters; maximum length of 63.
- [x] Reserve enough characters for a collision suffix before truncating the readable base.
- [x] Implement readable, deterministic collision candidates.
- [x] Cover accented characters, non-Latin names, punctuation, whitespace, very long names, and empty inputs.

## 4. Implement durable, concurrent allocation

- [x] Store each assignment using the immutable Keycloak user ID and realm ID, independently of the configured output claim name.
- [x] Add a persistence model with unique constraints for `(realm_id, user_id)` and `(realm_id, identifier)`.
- [x] Integrate the persistence model with Keycloak's JPA entity-provider extension mechanism for the selected Keycloak versions.
- [x] Allocate inside a transaction and retry with the next suffix when the identifier uniqueness constraint reports a collision.
- [x] Ensure concurrent requests handled by different Keycloak nodes cannot allocate the same identifier.
- [x] Return the existing assignment when the same user is processed again.
- [x] Ensure that profile changes, logout, token refresh, restarts, and mapper claim-name changes do not change the assignment key.
- [x] Define database migration and rollback behavior for future extension versions.

## 5. Map the claim

- [x] Resolve the authenticated Keycloak user while transforming the token.
- [x] Fetch or allocate the user's identifier.
- [x] Write it as a string to the configured claim path.
- [x] Verify behavior for access tokens, ID tokens, UserInfo responses, lightweight tokens, and service accounts.
- [x] Verify impersonation behavior and document any unsupported session types.
- [x] Add useful error messages and logs without exposing sensitive profile data.

## 6. Test the behavior

- [x] Unit-test normalization and length handling with a broad table of inputs and expected outputs.
- [x] Unit-test suffixing at digit-boundary changes such as `-9` to `-10`.
- [x] Integration-test mapper discovery and configuration in a real Keycloak instance.
- [x] Verify that a token contains the configured claim and that all requested token types behave consistently.
- [x] Verify stability across repeated logins, profile updates, token refreshes, and Keycloak restarts.
- [x] Create colliding users and verify readable, unique suffixes.
- [x] Run concurrent allocation tests against a shared database with multiple Keycloak instances.
- [x] Test realm isolation.
- [x] Test deletion and recreation behavior.
- [x] Test upgrades.
- [x] Test backup and restore.
- [x] Test existing-user migration.

## 7. Package and automate

- [x] Add formatting, compilation, test, and dependency/security checks to CI.
- [x] Build and test the extension against every supported Keycloak version.
- [x] Produce a versioned JAR named `keycloak-rfc1123-username.jar`.
- [x] Add release automation that publishes the JAR and its checksum to a GitHub release.
- [x] Generate provenance or a software bill of materials if required by the deployment environment.
- [x] Confirm the published `v1.0.0` URL used in the README.

## 8. Validate the deployment documentation

- [x] Test installation by copying the JAR to `/opt/keycloak/providers` and running `kc.sh build`.
- [x] Test the Kubernetes initContainer and shared provider volume from the README.
- [x] Document the persistent database requirement separately from the temporary provider-JAR volume.
- [x] Capture the exact Admin Console labels for the supported Keycloak version and update the README if they differ.
- [x] Configure the mapper on a test `onyxia` client with the claim name `onyxia-username`.
- [x] Obtain test Onyxia tokens and verify that `onyxia-username` is a valid RFC1123 identifier.
- [x] Remove the README status warning only after the implementation, release artifact, and documented deployment have been verified.

## Definition of done for v1.0.0

- [x] The same realm and Keycloak user ID always resolve to the same identifier.
- [x] No two users in a realm can receive the same identifier, including under concurrent requests from multiple Keycloak nodes.
- [x] Every emitted value is a valid RFC1123 DNS label of at most 63 characters.
- [x] Collisions retain a readable base and receive predictable numeric suffixes.
- [x] The mapper can target a configurable string claim in the selected token types.
- [x] The extension is covered by unit and integration tests and works on every documented Keycloak version.
- [x] A reproducible `v1.0.0` release and checksum are available at the URL documented in the README.
- [x] The mapper is validated on a test Onyxia client with the `onyxia-username` claim.
