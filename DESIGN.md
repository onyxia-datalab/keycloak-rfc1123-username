# Design decisions

This document defines the v1 contract. Changes that could alter an identifier already assigned to a user require an explicit migration plan.

## Compatibility

The project publishes one provider JAR rather than a different artifact for every Keycloak version.

- The JAR is compiled as Java 17 bytecode against Keycloak 24.0.5, the oldest supported release.
- The supported range for v1 is Keycloak 24.x, 25.x, and 26.x on the Java versions supported by those Keycloak releases.
- CI must install the exact same built JAR into the latest patch release of every supported Keycloak minor line. Recompiling the source for each test target is insufficient.
- The implementation uses the smallest possible Keycloak SPI surface. Keycloak dependencies have `provided` scope and are not bundled in the JAR.
- A new Keycloak release is supported only after the compatibility suite passes. Keycloak server SPIs do not carry the same compatibility guarantee as its public APIs, so compatibility is demonstrated by tests rather than assumed.
- A Keycloak major release outside the stated range may require a new extension release, but it should not require parallel JAR variants unless an unavoidable binary incompatibility is found.

The same baseline-built JAR passes the real-server and PostgreSQL multi-node suites on Keycloak 24.0.5, 25.0.6, and 26.7.4. Java 17 bytecode runs on both Java 17 and Java 21, covering the runtime transition within this Keycloak range.

Persistence uses Keycloak's custom JPA entity-provider SPI. Keycloak documents this SPI as unsupported, so every newly supported Keycloak release must pass the same-JAR startup, schema migration, and allocation tests before the compatibility range is expanded.

## Identifier source and normalization

The readable base is selected once, when the identifier is allocated:

1. the Keycloak username;
2. `firstName-lastName` if no usable username is available;
3. `user-<fingerprint>`, where the fingerprint is a short lowercase hexadecimal digest of the immutable realm and user IDs.

Normalization uses these rules, in order:

1. apply Unicode NFKD normalization;
2. remove combining marks;
3. convert ASCII letters to lowercase;
4. replace every run of characters other than `a-z` and `0-9` with one hyphen;
5. remove leading and trailing hyphens;
6. use the fallback above if the result is empty;
7. truncate the base as required before appending a collision suffix.

This keeps the core artifact dependency-free. Names written entirely in scripts that cannot be reduced to ASCII use the stable fallback rather than an inconsistent transliteration library.

## Length and collisions

An identifier is one RFC1123 DNS label: it contains only lowercase ASCII letters, digits, and hyphens; starts and ends with a letter or digit; and is at most 63 characters long.

The first candidate is the normalized base. Subsequent candidates use numeric suffixes beginning at `-2`: `alice-martin`, `alice-martin-2`, `alice-martin-3`, and so on. Before each suffix is appended, the base is truncated to leave room for the complete suffix, and any trailing hyphen created by truncation is removed.

Candidate order is deterministic. Which colliding user wins the unsuffixed value may depend on transaction order, but once assigned, a user's value never changes.

## Identity, uniqueness, and lifetime

- An assignment belongs to the pair `(realm ID, user ID)`. The OIDC `sub` normally represents that user ID, but storage does not depend on a configurable claim.
- Identifiers are unique within one realm. Different realms may contain the same identifier.
- The persistence layer enforces unique constraints on both `(realm ID, user ID)` and `(realm ID, identifier)`.
- Each allocation attempt uses a fresh Keycloak-managed transaction. It first returns an existing assignment for the user, otherwise it inserts one candidate and flushes it before committing.
- A uniqueness conflict rolls that attempt back. The allocator starts a fresh transaction, checks for an assignment created by a competing request, and otherwise tries the next suffix. Database constraints therefore arbitrate concurrent requests across Keycloak nodes.
- Profile edits, logout, refresh, restart, mapper changes, and output claim-name changes never cause reallocation.
- Assignments are retained as reservations after a user is deleted. Recreating a user produces a new identity and cannot silently inherit the deleted user's identifier.

## Schema migrations

The extension owns an append-only Liquibase changelog, independently of Keycloak's schema version. Released changesets must never be edited; schema changes are added as new changesets and exercised against every supported database during integration testing.

The initial changeset creates `RFC1123_USERNAME_ASSIGNMENT` and has an explicit rollback that drops the table. That rollback is suitable only before real assignments exist. After production rollout, rollback means restoring a database backup or applying a tested forward migration that preserves the assignment rows. Removing the provider JAR does not remove its table or release reserved identifiers.

## Existing Onyxia deployments

Existing identifiers must be imported before the mapper is enabled. The migration input is a CSV containing realm ID, immutable Keycloak user ID, and existing identifier. The PostgreSQL importer validates every value against the RFC1123 and uniqueness rules, verifies that each Keycloak user belongs to the specified realm, performs the import transactionally, and fails without partial changes if any row is invalid, duplicated, or conflicts with a stored assignment. Repeating an identical import is safe and does not create new rows.

The mapper must not infer old assignments from mutable usernames during rollout. A deployment without existing stable identifiers can skip this import.

## Mapper configuration

The provider ID is `oidc-rfc1123-username-mapper` and its Admin Console display name is **RFC1123 Username**. The output claim is configurable and defaults to `username-rfc1123`. Its value is always a string.

The mapper uses Keycloak's standard switches for access tokens, ID tokens, UserInfo responses, lightweight access tokens, and token introspection. Onyxia configures the claim as `onyxia-username` on the `onyxia` client.

Normal user sessions, impersonated user sessions, and service-account user sessions are supported. Custom token flows that invoke the mapper without a `UserSessionModel`, user, or realm are unsupported because there is no stable Keycloak user identity to assign; the mapper fails with an explicit error instead of emitting an unstable value.
