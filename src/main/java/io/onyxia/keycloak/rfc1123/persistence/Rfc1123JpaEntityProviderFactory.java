package io.onyxia.keycloak.rfc1123.persistence;

import org.keycloak.Config;
import org.keycloak.connections.jpa.entityprovider.JpaEntityProvider;
import org.keycloak.connections.jpa.entityprovider.JpaEntityProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public final class Rfc1123JpaEntityProviderFactory implements JpaEntityProviderFactory {

  public static final String PROVIDER_ID = "rfc1123-username";

  @Override
  public JpaEntityProvider create(KeycloakSession session) {
    return new Rfc1123JpaEntityProvider();
  }

  @Override
  public void init(Config.Scope config) {}

  @Override
  public void postInit(KeycloakSessionFactory factory) {}

  @Override
  public void close() {}

  @Override
  public String getId() {
    return PROVIDER_ID;
  }
}
