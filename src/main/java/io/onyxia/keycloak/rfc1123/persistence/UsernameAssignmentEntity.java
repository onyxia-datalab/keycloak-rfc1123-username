package io.onyxia.keycloak.rfc1123.persistence;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;

@Entity
@Table(
    name = "RFC1123_USERNAME_ASSIGNMENT",
    uniqueConstraints = {
      @UniqueConstraint(
          name = "UK_RFC1123_REALM_USER",
          columnNames = {"REALM_ID", "USER_ID"}),
      @UniqueConstraint(
          name = "UK_RFC1123_REALM_IDENTIFIER",
          columnNames = {"REALM_ID", "IDENTIFIER"})
    })
public class UsernameAssignmentEntity {

  @Id
  @Column(name = "ID", length = 36, nullable = false, updatable = false)
  private String id;

  @Column(name = "REALM_ID", length = 36, nullable = false, updatable = false)
  private String realmId;

  @Column(name = "USER_ID", length = 255, nullable = false, updatable = false)
  private String userId;

  @Column(name = "IDENTIFIER", length = 63, nullable = false, updatable = false)
  private String identifier;

  @Column(name = "CREATED_AT", nullable = false, updatable = false)
  private long createdAt;

  protected UsernameAssignmentEntity() {}

  public UsernameAssignmentEntity(
      String id, String realmId, String userId, String identifier, long createdAt) {
    this.id = id;
    this.realmId = realmId;
    this.userId = userId;
    this.identifier = identifier;
    this.createdAt = createdAt;
  }

  public String getId() {
    return id;
  }

  public String getRealmId() {
    return realmId;
  }

  public String getUserId() {
    return userId;
  }

  public String getIdentifier() {
    return identifier;
  }

  public long getCreatedAt() {
    return createdAt;
  }
}
