package io.onyxia.keycloak.rfc1123;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class Rfc1123IdentifierTest {

  @Test
  void normalizesAccentsPunctuationAndWhitespace() {
    assertEquals(
        "jose-dupont-test-example-com",
        Rfc1123Identifier.normalizeBase("  JOSÉ.Dupont+test@example.com  "));
    assertEquals("alice-martin", Rfc1123Identifier.normalizeBase("Alice -- Martin"));
  }

  @Test
  void fallsBackToNamesAndThenAStableFingerprint() {
    assertEquals(
        "alice-martin", Rfc1123Identifier.baseFor("李雷", "Alice", "Martin", "realm", "user"));

    String first = Rfc1123Identifier.baseFor("李雷", "Иван", "Иванов", "realm", "user");
    String second = Rfc1123Identifier.baseFor(null, null, null, "realm", "user");
    assertTrue(first.matches("user-[0-9a-f]{12}"));
    assertEquals(first, second);
  }

  @Test
  void truncatesLongValuesAndReservesSpaceForSuffixes() {
    String base = Rfc1123Identifier.normalizeBase("a".repeat(80));
    assertEquals(63, base.length());
    assertEquals(63, Rfc1123Identifier.candidate(base, 2).length());
    assertTrue(Rfc1123Identifier.candidate(base, 2).endsWith("-2"));
    assertEquals(63, Rfc1123Identifier.candidate(base, 9).length());
    assertTrue(Rfc1123Identifier.candidate(base, 9).endsWith("-9"));
    assertEquals(63, Rfc1123Identifier.candidate(base, 10).length());
    assertTrue(Rfc1123Identifier.candidate(base, 10).endsWith("-10"));
  }

  @Test
  void removesAHyphenExposedBySuffixTruncation() {
    String base = "a".repeat(60) + "-bc";
    String candidate = Rfc1123Identifier.candidate(base, 2);
    assertFalse(candidate.contains("--"));
    assertTrue(candidate.endsWith("-2"));
    assertTrue(Rfc1123Identifier.isValid(candidate));
  }

  @Test
  void validatesDnsLabels() {
    assertTrue(Rfc1123Identifier.isValid("alice-martin-2"));
    assertFalse(Rfc1123Identifier.isValid("Alice"));
    assertFalse(Rfc1123Identifier.isValid("-alice"));
    assertFalse(Rfc1123Identifier.isValid("alice-"));
    assertFalse(Rfc1123Identifier.isValid("a".repeat(64)));
  }
}
