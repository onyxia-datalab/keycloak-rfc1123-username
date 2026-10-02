# Implementation progress

## 2026-09-23 — Contract and provider scaffold

Completed:

- Defined a single-JAR compatibility strategy for Keycloak 24.x through 26.x, using Keycloak 24.0.5 as the compile baseline and Java 17 bytecode.
- Compared the protocol-mapper SPI used by the scaffold in Keycloak 24.0.5 and 26.7.4.
- Defined source-field priority, ASCII normalization, empty-input fallback, collision suffixes, and the 63-character limit.
- Defined realm-scoped uniqueness, immutable user identity, concurrency requirements, non-reuse after deletion, and existing-Onyxia migration behavior.
- Created the Maven project with pinned build plugins, provided Keycloak dependencies, reproducible timestamps, and an unversioned release JAR name.
- Added the `RFC1123 Username` mapper scaffold with the configurable `username-rfc1123` default claim and Keycloak's standard token inclusion controls.
- Registered the mapper through the Keycloak service-provider descriptor.

Verification:

- Built and inspected the JAR successfully with the Keycloak 24.0.5 baseline.
- Compiled the same sources successfully against Keycloak 25.0.6 and 26.7.4 to detect source-level SPI drift.
- Confirmed Java 17 bytecode (`major version 61`).
- Confirmed that two clean baseline builds produce the same SHA-256 digest: `571630fe98913ce4143212a030c3634ac0da72212c10d1f5fac46e684a1b0142`.
- Confirmed that the JAR contains the mapper and service metadata without bundled Keycloak classes.
- Full same-JAR runtime testing across supported Keycloak releases belongs to the integration-test phase.

Next:

- Implement and unit-test the independent RFC1123 normalizer and collision-candidate generator.
- Design and implement the durable allocation store and its database migration.

## 2026-09-23 — Identifier generation and durable allocation

Completed:

- Implemented dependency-free NFKD normalization, ASCII conversion, separator cleanup, RFC1123 validation, and the 63-character limit.
- Added username, first/last-name, and stable fingerprint fallback handling.
- Implemented deterministic candidates using the readable base followed by `-2`, `-3`, and later numeric suffixes, with suffix-aware truncation.
- Implemented an allocator that returns an existing user assignment and retries unavailable candidates.
- Added the `RFC1123_USERNAME_ASSIGNMENT` JPA entity keyed by immutable realm and user IDs.
- Added database uniqueness constraints for `(REALM_ID, USER_ID)` and `(REALM_ID, IDENTIFIER)`.
- Added a Keycloak JPA entity provider and registered its Liquibase changelog.
- Implemented each allocation attempt in a fresh Keycloak-managed transaction so a failed uniqueness constraint can be rolled back before retrying.
- Added an append-only migration policy and explicit initial rollback behavior to the design contract.

Verification:

- Added 10 unit tests covering accents, punctuation, whitespace, non-Latin fallbacks, empty values, long values, suffix truncation, stable reassignment, realm isolation, collision handling, concurrent allocation, and database constraint-error recognition.
- The test suite passes when compiled against Keycloak 24.0.5, 25.0.6, and 26.7.4.
- Two clean baseline builds produced the same JAR SHA-256 digest: `bd0ee1b982283a99efd6da6d4b657b1375b3504d1589204b3e1c6a4e1f6456f4`.
- Installed the baseline-built JAR unchanged into clean Keycloak 24.0.5 and 26.7.4 distributions.
- Confirmed at both ends of the supported range that `kc.sh build` discovers both providers, server startup applies `META-INF/rfc1123-username-changelog.xml`, and Keycloak starts successfully.
- A shared-database, multi-node concurrency test remains in the integration-test phase; database uniqueness constraints are the cross-node synchronization mechanism.
- Keycloak labels both the protocol-mapper and JPA entity-provider SPIs internal. Compatibility therefore remains test-backed rather than guaranteed by Keycloak's public API policy.

Next:

- Wire the allocator into token transformation and map the resulting string to the configured claim.
- Add full Keycloak integration tests, including multi-node allocation against a shared database.

## 2026-09-29 — Mapper wiring and boundary-version integration tests

Completed:

- Connected token transformation to the persistent allocator using the authenticated realm and immutable Keycloak user ID.
- Mapped the allocated identifier through Keycloak's standard configurable string-claim helper.
- Added failure logging that records realm and user IDs without logging usernames, names, email addresses, credentials, or tokens.
- Added a reusable real-server integration script that installs the baseline-built JAR, creates an `onyxia` client, configures `onyxia-username`, obtains tokens, restarts Keycloak, and cleans up its isolated test environment after success.
- Added explicit test-client audience configuration for the stricter introspection validation in recent Keycloak releases.

Verification:

- The unchanged baseline JAR passes the full integration scenario on Keycloak 24.0.5 and 26.7.4.
- Access tokens, ID tokens, UserInfo responses, introspection responses, lightweight access tokens, and service-account tokens contain the configured claim.
- Refreshing a token retains the same identifier.
- Changing the user's username retains the original assignment.
- Restarting Keycloak retains the original assignment.
- Two users whose names normalize to the same base receive `alice-martin` and `alice-martin-2`.
- Deleting the first user and recreating it with a new Keycloak user ID does not reuse the reserved identifier; the recreated user receives `alice-martin-3`.

Remaining after this milestone:

- Verify impersonated sessions and document unsupported session types.
- Run a concurrent allocation test with multiple Keycloak nodes sharing one external database.
- Exercise realm isolation, upgrade, backup/restore, and existing-assignment migration scenarios.
- Add CI, security/dependency checks, release automation, provenance or SBOM output, and the final v1.0.0 artifact.
- Validate the Kubernetes initContainer and exact Admin Console wording, then finish the deployment documentation.

## 2026-09-29 — Impersonation, realm isolation, and multi-node concurrency

Completed:

- Extended the real-server suite with an administrative impersonation flow. It creates an impersonated browser session, completes an authorization-code exchange, and checks the mapper claim in the resulting access token.
- Added a second realm with the same readable username and verified that each realm can independently allocate `alice-martin`.
- Documented that normal, impersonated, and service-account user sessions are supported. A custom flow with no user session, user, or realm is rejected because it cannot provide a stable identity.
- Added `scripts/multi-node-integration-test.sh`, which starts PostgreSQL and two isolated Keycloak processes sharing that database.
- The multi-node suite sends eight colliding password-grant requests simultaneously, alternating between the two nodes, and then routes every user through the opposite node to verify assignment stability.

Verification:

- The updated impersonation and realm-isolation suite passes on Keycloak 24.0.5 and 26.7.4 with the same baseline-built provider JAR.
- The PostgreSQL multi-node suite passes on Keycloak 24.0.5 and 26.7.4.
- Concurrent users receive exactly one value each from the complete candidate sequence `race-user`, `race-user-2`, through `race-user-8`; no identifier is duplicated.
- Each assignment remains unchanged when the next token is issued by the other Keycloak node.

Remaining after this milestone:

- Test upgrades, database backup and restore, and import of assignments for an existing Onyxia deployment.
- Run the real-server suites on Keycloak 25.x and automate all supported-version checks in CI.
- Add dependency and security checks, release automation, checksums, and provenance or SBOM output.
- Validate the Kubernetes initContainer and Admin Console wording before publishing `v1.0.0`.

## 2026-09-29 — CI, full supported-version runtime matrix, and SBOM

Completed:

- Added a CI build job that checks shell syntax and Java formatting, runs the unit tests, builds against the Keycloak 24.0.5 baseline, and verifies Java 17 bytecode and required provider metadata.
- Made the CI compatibility matrix consume one uploaded, checksummed provider JAR instead of rebuilding for each Keycloak release.
- Added real-server and PostgreSQL multi-node jobs for Keycloak 24.0.5, 25.0.6, and 26.7.4.
- Added CodeQL analysis, pull-request dependency review, and weekly Dependabot checks for Maven and GitHub Actions dependencies.
- Added reproducible CycloneDX 1.6 JSON SBOM generation to the Maven package lifecycle.
- Added a reusable artifact verifier that rejects the wrong bytecode level, missing service descriptors or changelog metadata, and bundled Keycloak classes.
- Added distinct management ports for multi-node Keycloak 25 and 26 tests and a mapper-free cache warm-up that avoids a Keycloak 25 cold-cache race without preallocating identifiers.

Verification:

- `mvn spotless:check clean verify` passes all 10 tests and produces `target/keycloak-rfc1123-username.cdx.json` with 66 components.
- `scripts/verify-artifact.sh` confirms Java class-file version 61 and the expected provider contents.
- Two clean builds produce identical JAR and SBOM SHA-256 digests.
- The unchanged baseline JAR passes the full real-server suite on Keycloak 24.0.5, 25.0.6, and 26.7.4.
- The same JAR passes concurrent PostgreSQL allocation through two Keycloak nodes on all three supported versions.
- The workflow and Dependabot files pass YAML parsing and `actionlint`; their hosted GitHub execution remains to be observed after the changes are pushed.

Remaining after this milestone:

- Test Keycloak upgrades, database backup and restore, and import of assignments for an existing Onyxia deployment.
- Add release automation, provenance attestation, and the final `v1.0.0` artifact and checksum.
- Validate the Kubernetes initContainer and exact Admin Console wording before removing the README status warning.

## 2026-10-02 — Existing-assignment import, upgrades, and backup/restore

Implemented:

- Added a PostgreSQL CSV importer for existing assignments. It validates RFC1123 syntax, realm/user existence, duplicate input, and conflicts with stored assignments in one transaction.
- Made identical imports idempotent so a safely repeated deployment step does not create or replace assignments.
- Added a data-lifecycle integration suite that starts without the mapper enabled, proves an invalid import rolls back completely, imports a legacy Onyxia identifier, then enables the mapper and verifies the imported value is emitted.
- Extended that suite to upgrade the same database from Keycloak 24.0.5 to 26.7.4 and to restore a pre-upgrade PostgreSQL dump into a fresh database before starting Keycloak 26.7.4.
- Added a dedicated CI job for the data-lifecycle suite and documented the operator workflow.

Verification:

- All existing 10 unit tests pass.
- Every shell script passes `bash -n`; the worktree passes `git diff --check`.
- The Docker-backed suite passes from Keycloak 24.0.5 to 26.7.4 against PostgreSQL 16.
- An invalid two-row import leaves zero assignments, a valid import creates one assignment, and rerunning the same import creates no additional row.
- Both the imported identifier and a normally allocated identifier remain unchanged after the Keycloak upgrade and after restoring the pre-upgrade database backup.

Next:

- Add release automation, checksums, and provenance attestation.
- Validate the Kubernetes initContainer and Admin Console wording.

## 2026-10-02 — Release automation

Implemented:

- Switched the Maven project to a CI-friendly `revision` property, defaulting development builds to `1.0.0-SNAPSHOT` while allowing a tag build to inject `1.0.0`.
- Added a tag-triggered release workflow that accepts strict `vMAJOR.MINOR.PATCH` tags, runs the full Maven verification, and verifies the provider artifact.
- The workflow publishes the unversioned provider JAR expected by the deployment documentation, its SHA-256 checksum, the CycloneDX JSON SBOM, and its checksum.
- Added GitHub artifact attestations for the JAR and SBOM and documented checksum and provenance verification.

Verification:

- Two clean `1.0.0` builds produced identical JAR SHA-256 digests (`d3c0658d95ffa4017c7c01d1ace84419020f53e442b21306db2575f56401ddda`) and identical SBOM digests (`0cd9c4a3de1cb11ba39727f2e31fe949ba773e442524e359e60c69f5bb66f987`).
- The release JAR manifest reports `Implementation-Version: 1.0.0`, retains Java 17 bytecode, and passes the artifact verifier.
- All workflow files parse as YAML, all shell scripts pass `bash -n`, and the worktree passes `git diff --check`.

Next:

- Observe the release workflow's hosted execution when a release tag is pushed.
- Validate the Kubernetes initContainer.
- Publish `v1.0.0`, confirm the documented URLs, and only then remove the README status warning.

## 2026-10-02 — Kubernetes deployment validation

Implemented:

- Added an isolated Kind-based deployment suite with a temporary kubeconfig so it cannot mutate any configured external cluster.
- The suite serves test artifacts inside the cluster, runs the documented curl initContainer with the same shared `emptyDir` and `subPath`, and runs `kc.sh build` in the Keycloak 26.7.4 container.
- Pinned the Kind node image by digest and added a CI job that installs a checksummed Kind v0.33.0 binary before running the suite.

Verification:

- The suite passed locally using Kind v0.33.0, Kubernetes 1.35.0, and Keycloak 26.7.4 after network connectivity was restored.
- The initContainer downloaded both JARs into the shared `emptyDir`; the Keycloak container observed both files through the documented `subPath` mount.
- `kc.sh build` completed successfully and discovered both the protocol-mapper and JPA entity-provider implementations.
- The isolated Kind cluster was deleted automatically, and the configured external kubectl endpoint was never used.

Next:

- Observe the same Kubernetes suite in GitHub Actions after the changes are pushed.

## 2026-10-02 — Admin Console labels

Completed:

- Read the mapper's actual configuration-property metadata and resolved its localization keys from the English Keycloak Admin UI bundles for 24.0.5, 25.0.6, and 26.7.4.
- Confirmed that all three supported versions use the same labels: **Token Claim Name**, **Add to ID token**, **Add to access token**, **Add to lightweight access token**, **Add to userinfo**, and **Add to token introspection**.
- Updated the README to use those exact labels and removed the inaccurate instruction to select a separate String value; this mapper always emits a string and does not expose a JSON-type field.

## 2026-10-02 — Initial hosted CI run

Completed:

- Opened pull request #1 from `feat/rfc1123-username-v1` at commit `225c2f0`.
- Both full CI runs passed, including the supported-version matrix, PostgreSQL concurrency, data lifecycle, and Kubernetes deployment jobs.
- CodeQL passed without findings.
- Dependency review correctly identified five known advisories on `keycloak-server-spi-private:24.0.5`, the `provided` compile baseline that is not bundled in the provider JAR.
- Added advisory-specific exceptions for those five baseline findings. This avoids weakening the severity threshold globally: any new advisory or vulnerable packaged dependency will continue to fail dependency review.

Next:

- Confirm the updated Security workflow is green, merge pull request #1, and create the `v1.0.0` tag.
