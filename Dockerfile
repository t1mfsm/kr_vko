FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        sqlite3 \
        openssl \
        xxd \
        procps \
        coreutils \
        findutils \
        gawk \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

RUN useradd -m app \
    && chown -R app:app /app \
    && chmod +x /app/*.sh /app/docker-entrypoint.sh

USER app

ENTRYPOINT ["/app/docker-entrypoint.sh"]
