# WSO2 Identity Server image for the srt-emp demo.
#
# Multi-stage: the `extractor` stage unzips the (~400 MB) IS pack; the final
# stage copies only the extracted tree via COPY --from, so the zip never lands
# in a layer of the shipped image (a single-stage `COPY zip` + `rm` still keeps
# the zip in the COPY layer). Build-only tooling (unzip) stays in the extractor;
# the runtime keeps only what the entrypoint/bootstrap need (curl, jq).
#
# Build context is ./wso2-is (see docker-compose.yml), so COPY paths are
# relative to that folder — this keeps the IS zip out of the Python services'
# build contexts. Layout within the context:
#   pack/        — the downloaded IS zip (gitignored)
#   uaepass/     — UAEPass connector JAR, error JSP, logo
#   entrypoint/  — container entrypoint script
#
# WSO2 IS version. Must be 7.3.0 or newer. Download the pack from
#   https://wso2.com/identity-server/  (or https://github.com/wso2/product-is/releases)
# and place wso2is-<version>.zip inside wso2-is/pack/.
# To use a newer version, change ONLY this value — nothing else below.
ARG WSO2IS_VERSION=7.3.0

# ── Stage 1: extract the IS pack ───────────────────────────────────────────
FROM eclipse-temurin:21-jdk-jammy AS extractor

ARG WSO2IS_VERSION
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*

COPY pack/wso2is-${WSO2IS_VERSION}.zip /tmp/wso2is.zip
RUN unzip -q /tmp/wso2is.zip -d /opt \
    && mv /opt/wso2is-${WSO2IS_VERSION} /opt/wso2is \
    && rm -f /tmp/wso2is.zip

# ── Stage 2: runtime image ─────────────────────────────────────────────────
FROM eclipse-temurin:21-jdk-jammy

ENV DEBIAN_FRONTEND=noninteractive
ENV JAVA_HOME=/opt/java/openjdk

# Runtime deps: curl (entrypoint readiness probe) + jq (bootstrap JSON parsing).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/*

# Bring in just the extracted IS tree — not the zip.
COPY --from=extractor /opt/wso2is /opt/wso2is

WORKDIR /opt/wso2is

# ── UAEPass federated authenticator connector ──────────────────────────────
# Deploy the UAEPass OIDC authenticator into dropins so IS loads it at boot,
# the branded error page into the authentication endpoint, and the UAEPass
# logo into both the login-UI theme and the Console connection-logo dirs.
COPY uaepass/org.wso2.carbon.identity.authenticator.uaepass-1.1.6.jar \
     /opt/wso2is/repository/components/dropins/
COPY uaepass/uaePassError.jsp \
     /opt/wso2is/repository/deployment/server/webapps/authenticationendpoint/uaePassError.jsp
COPY uaepass/uaepass-logo.png \
     /opt/wso2is/repository/deployment/server/webapps/authenticationendpoint/libs/themes/default/assets/images/identity-providers/uaepass-logo.png
COPY uaepass/uaepass-logo.png \
     /opt/wso2is/repository/deployment/server/webapps/console/resources/connections/assets/images/logos/uaepass-logo.png

COPY entrypoint/custom-entrypoint.sh /opt/custom-entrypoint.sh
RUN chmod +x /opt/custom-entrypoint.sh

EXPOSE 9443 9763

ENTRYPOINT ["/opt/custom-entrypoint.sh"]
