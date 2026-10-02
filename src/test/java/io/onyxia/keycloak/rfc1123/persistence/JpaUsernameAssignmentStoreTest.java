package io.onyxia.keycloak.rfc1123.persistence;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.sql.SQLException;
import org.junit.jupiter.api.Test;
import org.keycloak.models.ModelDuplicateException;

class JpaUsernameAssignmentStoreTest {

  @Test
  void recognizesPortableIntegrityConstraintSqlStates() {
    RuntimeException wrapped = new RuntimeException(new SQLException("duplicate", "23505"));
    assertTrue(JpaUsernameAssignmentStore.isConstraintViolation(wrapped));
    assertTrue(JpaUsernameAssignmentStore.isConstraintViolation(new ModelDuplicateException()));
  }

  @Test
  void doesNotHideUnrelatedDatabaseFailures() {
    RuntimeException wrapped =
        new RuntimeException(new SQLException("connection unavailable", "08001"));
    assertFalse(JpaUsernameAssignmentStore.isConstraintViolation(wrapped));
  }
}
