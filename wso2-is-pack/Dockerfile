FROM eclipse-temurin:21-jdk-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV JAVA_HOME=/opt/java/openjdk

RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# WSO2 IS version. Must be 7.3.0 or newer. Download the pack from
#   https://wso2.com/identity-server/  (or https://github.com/wso2/product-is/releases)
# and place wso2is-<version>.zip inside this folder (wso2-is-pack/).
# To use a newer version, change ONLY this value — nothing else below.
ARG WSO2IS_VERSION=7.3.0

# Build context is ./wso2-is-pack (see docker-compose.yml), so COPY paths are
# relative to that folder — keeps the ~400 MB IS zip out of the Python services'
# build contexts.
COPY wso2is-${WSO2IS_VERSION}.zip /tmp/wso2is.zip
RUN unzip -q /tmp/wso2is.zip -d /opt \
    && rm -f /tmp/wso2is.zip \
    && mv /opt/wso2is-${WSO2IS_VERSION} /opt/wso2is

WORKDIR /opt/wso2is

# ── UAEPass federated authenticator connector ──────────────────────────────
# Deploy the UAEPass OIDC authenticator into dropins so IS loads it at boot,
# the branded error page into the authentication endpoint, and the UAEPass
# logo into both the login-UI theme and the Console connection-logo dirs.
COPY org.wso2.carbon.identity.authenticator.uaepass-1.1.6.jar \
     /opt/wso2is/repository/components/dropins/
COPY uaePassError.jsp \
     /opt/wso2is/repository/deployment/server/webapps/authenticationendpoint/uaePassError.jsp
COPY uaepass-logo.png \
     /opt/wso2is/repository/deployment/server/webapps/authenticationendpoint/libs/themes/default/assets/images/identity-providers/uaepass-logo.png
COPY uaepass-logo.png \
     /opt/wso2is/repository/deployment/server/webapps/console/resources/connections/assets/images/logos/uaepass-logo.png

COPY custom-entrypoint.sh /opt/custom-entrypoint.sh
RUN chmod +x /opt/custom-entrypoint.sh

EXPOSE 9443 9763

ENTRYPOINT ["/opt/custom-entrypoint.sh"]
