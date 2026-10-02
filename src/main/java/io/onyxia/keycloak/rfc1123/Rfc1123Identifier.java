package io.onyxia.keycloak.rfc1123;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.Normalizer;
import java.util.Locale;
import java.util.Objects;
import java.util.regex.Pattern;

/** Generates RFC1123 DNS-label identifiers from Keycloak profile fields. */
public final class Rfc1123Identifier {

  public static final int MAX_LENGTH = 63;

  private static final int FALLBACK_FINGERPRINT_LENGTH = 12;
  private static final Pattern VALID_IDENTIFIER =
      Pattern.compile("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?");

  private Rfc1123Identifier() {}

  /**
   * Selects and normalizes the readable base for a user.
   *
   * <p>The username is preferred. First and last name are used only when the username has no ASCII
   * representation. A stable fingerprint is the final fallback.
   */
  public static String baseFor(
      String username, String firstName, String lastName, String realmId, String userId) {
    Objects.requireNonNull(realmId, "realmId");
    Objects.requireNonNull(userId, "userId");

    String base = normalizeBase(username);
    if (!base.isEmpty()) {
      return base;
    }

    base = normalizeBase(joinNames(firstName, lastName));
    if (!base.isEmpty()) {
      return base;
    }

    return "user-" + fingerprint(realmId, userId);
  }

  /**
   * Normalizes an input without inventing a fallback. An unusable input returns an empty string.
   */
  public static String normalizeBase(String input) {
    if (input == null || input.isBlank()) {
      return "";
    }

    String decomposed = Normalizer.normalize(input, Normalizer.Form.NFKD);
    StringBuilder result = new StringBuilder(Math.min(decomposed.length(), MAX_LENGTH));
    boolean previousWasSeparator = false;

    for (int offset = 0; offset < decomposed.length(); ) {
      int codePoint = decomposed.codePointAt(offset);
      offset += Character.charCount(codePoint);

      int type = Character.getType(codePoint);
      if (type == Character.NON_SPACING_MARK
          || type == Character.COMBINING_SPACING_MARK
          || type == Character.ENCLOSING_MARK) {
        continue;
      }

      if (isAsciiLetterOrDigit(codePoint)) {
        if (result.length() == MAX_LENGTH) {
          break;
        }
        result.appendCodePoint(Character.toLowerCase(codePoint));
        previousWasSeparator = false;
      } else if (result.length() > 0 && !previousWasSeparator) {
        if (result.length() == MAX_LENGTH) {
          break;
        }
        result.append('-');
        previousWasSeparator = true;
      }
    }

    trimTrailingHyphens(result);
    return result.toString().toLowerCase(Locale.ROOT);
  }

  /** Returns the first candidate for occurrence 1, then readable numeric suffixes from 2 onward. */
  public static String candidate(String normalizedBase, int occurrence) {
    if (occurrence < 1) {
      throw new IllegalArgumentException("occurrence must be at least 1");
    }

    String base = normalizeBase(normalizedBase);
    if (base.isEmpty()) {
      throw new IllegalArgumentException("normalizedBase must contain an ASCII letter or digit");
    }

    if (occurrence == 1) {
      return base;
    }

    String suffix = "-" + occurrence;
    int maximumBaseLength = MAX_LENGTH - suffix.length();
    if (maximumBaseLength < 1) {
      throw new IllegalArgumentException("occurrence suffix exceeds the RFC1123 length limit");
    }

    StringBuilder shortened =
        new StringBuilder(base.substring(0, Math.min(base.length(), maximumBaseLength)));
    trimTrailingHyphens(shortened);
    if (shortened.length() == 0) {
      throw new IllegalArgumentException("normalizedBase cannot be shortened safely");
    }

    return shortened + suffix;
  }

  public static boolean isValid(String identifier) {
    return identifier != null
        && identifier.length() <= MAX_LENGTH
        && VALID_IDENTIFIER.matcher(identifier).matches();
  }

  private static boolean isAsciiLetterOrDigit(int codePoint) {
    return codePoint >= 'a' && codePoint <= 'z'
        || codePoint >= 'A' && codePoint <= 'Z'
        || codePoint >= '0' && codePoint <= '9';
  }

  private static String joinNames(String firstName, String lastName) {
    String first = firstName == null ? "" : firstName.strip();
    String last = lastName == null ? "" : lastName.strip();
    return first + (first.isEmpty() || last.isEmpty() ? "" : "-") + last;
  }

  private static String fingerprint(String realmId, String userId) {
    try {
      MessageDigest digest = MessageDigest.getInstance("SHA-256");
      byte[] hash = digest.digest((realmId + '\0' + userId).getBytes(StandardCharsets.UTF_8));
      StringBuilder value = new StringBuilder(FALLBACK_FINGERPRINT_LENGTH);
      for (int index = 0; index < FALLBACK_FINGERPRINT_LENGTH / 2; index++) {
        value.append(Character.forDigit((hash[index] >>> 4) & 0xf, 16));
        value.append(Character.forDigit(hash[index] & 0xf, 16));
      }
      return value.toString();
    } catch (NoSuchAlgorithmException exception) {
      throw new IllegalStateException(
          "SHA-256 is required by every supported Java runtime", exception);
    }
  }

  private static void trimTrailingHyphens(StringBuilder value) {
    while (value.length() > 0 && value.charAt(value.length() - 1) == '-') {
      value.setLength(value.length() - 1);
    }
  }
}
