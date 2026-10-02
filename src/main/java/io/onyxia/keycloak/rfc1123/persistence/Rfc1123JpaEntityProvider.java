package io.onyxia.keycloak.rfc1123.persistence;

import java.util.Collections;
import java.util.List;
import org.keycloak.connections.jpa.entityprovider.JpaEntityProvider;

public final class Rfc1123JpaEntityProvider implements JpaEntityProvider {

  static final String CHANGELOG_LOCATION = "META-INF/rfc1123-username-changelog.xml";

  @Override
  public List<Class<?>> getEntities() {
    return Collections.singletonList(UsernameAssignmentEntity.class);
  }

  @Override
  public String getChangelogLocation() {
    return CHANGELOG_LOCATION;
  }

  @Override
  public String getFactoryId() {
    return Rfc1123JpaEntityProviderFactory.PROVIDER_ID;
  }

  @Override
  public void close() {}
}
