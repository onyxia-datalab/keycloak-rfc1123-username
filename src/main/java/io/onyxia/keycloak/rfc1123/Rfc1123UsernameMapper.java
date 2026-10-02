package io.onyxia.keycloak.rfc1123;

import io.onyxia.keycloak.rfc1123.persistence.JpaUsernameAssignmentStore;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.jboss.logging.Logger;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.IDToken;

/** Adds a stable RFC1123-compatible username to OpenID Connect tokens. */
public final class Rfc1123UsernameMapper extends AbstractOIDCProtocolMapper
    implements OIDCAccessTokenMapper,
        OIDCIDTokenMapper,
        UserInfoTokenMapper,
        TokenIntrospectionTokenMapper {

  public static final String PROVIDER_ID = "oidc-rfc1123-username-mapper";
  public static final String DEFAULT_CLAIM_NAME = "username-rfc1123";

  private static final Logger LOG = Logger.getLogger(Rfc1123UsernameMapper.class);
  private static final List<ProviderConfigProperty> CONFIG_PROPERTIES;

  static {
    List<ProviderConfigProperty> properties = new ArrayList<>();

    ProviderConfigProperty claimName = new ProviderConfigProperty();
    claimName.setName(OIDCAttributeMapperHelper.TOKEN_CLAIM_NAME);
    claimName.setLabel(OIDCAttributeMapperHelper.TOKEN_CLAIM_NAME_LABEL);
    claimName.setType(ProviderConfigProperty.STRING_TYPE);
    claimName.setDefaultValue(DEFAULT_CLAIM_NAME);
    claimName.setHelpText(OIDCAttributeMapperHelper.TOKEN_CLAIM_NAME_TOOLTIP);
    claimName.setRequired(true);
    properties.add(claimName);

    OIDCAttributeMapperHelper.addIncludeInTokensConfig(properties, Rfc1123UsernameMapper.class);

    CONFIG_PROPERTIES = Collections.unmodifiableList(properties);
  }

  @Override
  public String getId() {
    return PROVIDER_ID;
  }

  @Override
  public String getDisplayType() {
    return "RFC1123 Username";
  }

  @Override
  public String getDisplayCategory() {
    return TOKEN_MAPPER_CATEGORY;
  }

  @Override
  public String getHelpText() {
    return "Adds a stable, unique, human-readable RFC1123 username to a token claim.";
  }

  @Override
  public List<ProviderConfigProperty> getConfigProperties() {
    return CONFIG_PROPERTIES;
  }

  @Override
  protected void setClaim(
      IDToken token,
      ProtocolMapperModel mappingModel,
      UserSessionModel userSession,
      KeycloakSession keycloakSession,
      ClientSessionContext clientSessionContext) {
    if (userSession == null || userSession.getUser() == null || userSession.getRealm() == null) {
      throw new IllegalStateException(
          "RFC1123 username mapping requires a user session, user, and realm");
    }

    UserModel user = userSession.getUser();
    RealmModel realm = userSession.getRealm();

    try {
      UsernameAllocator allocator =
          new UsernameAllocator(
              new JpaUsernameAssignmentStore(keycloakSession.getKeycloakSessionFactory()));
      String identifier =
          allocator.allocate(
              realm.getId(),
              user.getId(),
              user.getUsername(),
              user.getFirstName(),
              user.getLastName());
      OIDCAttributeMapperHelper.mapClaim(token, mappingModel, identifier);
    } catch (RuntimeException failure) {
      LOG.errorf(
          failure,
          "Unable to allocate RFC1123 username for realm ID %s and user ID %s",
          realm.getId(),
          user.getId());
      throw failure;
    }
  }
}
