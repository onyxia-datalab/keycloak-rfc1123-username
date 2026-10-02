package io.onyxia.keycloak.rfc1123.persistence;

import io.onyxia.keycloak.rfc1123.UsernameAllocator;
import jakarta.persistence.EntityManager;
import java.sql.SQLException;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.ModelDuplicateException;
import org.keycloak.models.utils.KeycloakModelUtils;

/** Performs every assignment attempt in an independent Keycloak-managed transaction. */
public final class JpaUsernameAssignmentStore implements UsernameAllocator.AssignmentAttempt {

  private final KeycloakSessionFactory sessionFactory;

  public JpaUsernameAssignmentStore(KeycloakSessionFactory sessionFactory) {
    this.sessionFactory = sessionFactory;
  }

  @Override
  public String assign(String realmId, String userId, String candidate) {
    try {
      return KeycloakModelUtils.runJobInTransactionWithResult(
          sessionFactory,
          session -> {
            JpaConnectionProvider connectionProvider =
                session.getProvider(JpaConnectionProvider.class);
            if (connectionProvider == null) {
              throw new IllegalStateException("Keycloak JPA connection provider is unavailable");
            }

            EntityManager entityManager = connectionProvider.getEntityManager();
            String existing = findExisting(entityManager, realmId, userId);
            if (existing != null) {
              return existing;
            }

            UsernameAssignmentEntity assignment =
                new UsernameAssignmentEntity(
                    UUID.randomUUID().toString(),
                    realmId,
                    userId,
                    candidate,
                    System.currentTimeMillis());
            entityManager.persist(assignment);
            entityManager.flush();
            return candidate;
          });
    } catch (RuntimeException failure) {
      if (isConstraintViolation(failure)) {
        throw new UsernameAllocator.CandidateUnavailableException(failure);
      }
      throw failure;
    }
  }

  private static String findExisting(EntityManager entityManager, String realmId, String userId) {
    List<String> matches =
        entityManager
            .createQuery(
                "select assignment.identifier "
                    + "from UsernameAssignmentEntity assignment "
                    + "where assignment.realmId = :realmId "
                    + "and assignment.userId = :userId",
                String.class)
            .setParameter("realmId", realmId)
            .setParameter("userId", userId)
            .setMaxResults(1)
            .getResultList();
    return matches.isEmpty() ? null : matches.get(0);
  }

  static boolean isConstraintViolation(Throwable failure) {
    Set<Throwable> visited = Collections.newSetFromMap(new IdentityHashMap<>());
    Throwable current = failure;
    while (current != null && visited.add(current)) {
      if (current instanceof ModelDuplicateException) {
        return true;
      }
      if (current instanceof SQLException sqlException) {
        String sqlState = sqlException.getSQLState();
        if (sqlState != null && sqlState.startsWith("23")) {
          return true;
        }
      }
      if ("org.hibernate.exception.ConstraintViolationException"
          .equals(current.getClass().getName())) {
        return true;
      }
      current = current.getCause();
    }
    return false;
  }
}
