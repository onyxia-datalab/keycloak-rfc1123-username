package io.onyxia.keycloak.rfc1123;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.Test;

class UsernameAllocatorTest {

  @Test
  void keepsAnExistingAssignmentAfterProfileChanges() {
    InMemoryAssignmentAttempt assignments = new InMemoryAssignmentAttempt();
    UsernameAllocator allocator = new UsernameAllocator(assignments);

    assertEquals("alice", allocator.allocate("realm", "user", "Alice", null, null));
    assertEquals("alice", allocator.allocate("realm", "user", "Bob", null, null));
  }

  @Test
  void appendsReadableSuffixesForCollisionsWithinARealm() {
    InMemoryAssignmentAttempt assignments = new InMemoryAssignmentAttempt();
    UsernameAllocator allocator = new UsernameAllocator(assignments);

    assertEquals("alice", allocator.allocate("realm", "user-1", "Alice", null, null));
    assertEquals("alice-2", allocator.allocate("realm", "user-2", "Alice", null, null));
    assertEquals("alice", allocator.allocate("another-realm", "user-3", "Alice", null, null));
  }

  @Test
  void allocatesUniqueValuesUnderConcurrentRequests() throws Exception {
    int userCount = 40;
    InMemoryAssignmentAttempt assignments = new InMemoryAssignmentAttempt();
    UsernameAllocator allocator = new UsernameAllocator(assignments);
    ExecutorService executor = Executors.newFixedThreadPool(8);
    CountDownLatch start = new CountDownLatch(1);
    List<Future<String>> futures = new ArrayList<>();

    try {
      for (int user = 0; user < userCount; user++) {
        String userId = "user-" + user;
        futures.add(
            executor.submit(
                () -> {
                  start.await();
                  return allocator.allocate("realm", userId, "Alice", null, null);
                }));
      }
      start.countDown();

      Set<String> identifiers = new HashSet<>();
      for (Future<String> future : futures) {
        identifiers.add(future.get());
      }

      assertEquals(userCount, identifiers.size());
      assertTrue(identifiers.contains("alice"));
      assertTrue(identifiers.contains("alice-40"));
      assertTrue(identifiers.stream().allMatch(Rfc1123Identifier::isValid));
    } finally {
      executor.shutdownNow();
    }
  }

  private static final class InMemoryAssignmentAttempt
      implements UsernameAllocator.AssignmentAttempt {

    private final Map<String, String> identifiersByUser = new HashMap<>();
    private final Set<String> assignedIdentifiers = new HashSet<>();

    @Override
    public synchronized String assign(String realmId, String userId, String candidate) {
      String userKey = realmId + '\0' + userId;
      String identifierKey = realmId + '\0' + candidate;

      String existing = identifiersByUser.get(userKey);
      if (existing != null) {
        return existing;
      }
      if (!assignedIdentifiers.add(identifierKey)) {
        throw new UsernameAllocator.CandidateUnavailableException(null);
      }

      identifiersByUser.put(userKey, candidate);
      return candidate;
    }
  }
}
