FROM eclipse-temurin:17-jre-jammy

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    jq \
    dos2unix \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash meta

WORKDIR /opt/meta

RUN mkdir -p /opt/meta/conf /opt/meta/data \
    && chown -R meta:meta /opt/meta

COPY system.ini.default /opt/meta/system.ini.default
COPY entrypoint.sh /opt/meta/entrypoint.sh
RUN chmod +x /opt/meta/entrypoint.sh

EXPOSE 7189

ENTRYPOINT ["/opt/meta/entrypoint.sh"]
