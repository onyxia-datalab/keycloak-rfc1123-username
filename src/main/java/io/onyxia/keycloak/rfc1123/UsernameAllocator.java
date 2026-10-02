package io.onyxia.keycloak.rfc1123;

import java.util.Objects;

/** Coordinates deterministic collision candidates with an atomic persistent assignment attempt. */
public final class UsernameAllocator {

  static final int MAX_CANDIDATES = 100_000;

  private final AssignmentAttempt assignmentAttempt;

  public UsernameAllocator(AssignmentAttempt assignmentAttempt) {
    this.assignmentAttempt = Objects.requireNonNull(assignmentAttempt, "assignmentAttempt");
  }

  public String allocate(
      String realmId, String userId, String username, String firstName, String lastName) {
    Objects.requireNonNull(realmId, "realmId");
    Objects.requireNonNull(userId, "userId");

    String base = Rfc1123Identifier.baseFor(username, firstName, lastName, realmId, userId);
    for (int occurrence = 1; occurrence <= MAX_CANDIDATES; occurrence++) {
      String candidate = Rfc1123Identifier.candidate(base, occurrence);
      try {
        return assignmentAttempt.assign(realmId, userId, candidate);
      } catch (CandidateUnavailableException ignored) {
        // The next transaction first checks whether a concurrent request assigned this user.
      }
    }

    throw new IllegalStateException(
        "Unable to allocate an RFC1123 username after " + MAX_CANDIDATES + " candidates");
  }

  @FunctionalInterface
  public interface AssignmentAttempt {
    /**
     * Returns an existing assignment or atomically persists and returns {@code candidate}.
     *
     * @throws CandidateUnavailableException when a concurrent assignment owns the candidate
     */
    String assign(String realmId, String userId, String candidate)
        throws CandidateUnavailableException;
  }

  public static final class CandidateUnavailableException extends RuntimeException {
    public CandidateUnavailableException(Throwable cause) {
      super(cause);
    }
  }
}
