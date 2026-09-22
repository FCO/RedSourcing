FROM rakudo-star:2026.06-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential pkg-config \
        libssl-dev libsqlite3-dev libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/redsourcing
COPY META6.json ./
RUN zef install --/test --deps-only . \
    && zef install --/test DB::Pg App::Prove6
RUN zef install --/test --test-depends --deps-only .

COPY lib ./lib
COPY bin ./bin
COPY resources ./resources
COPY README.md ./README.md
RUN zef install --/test .

RUN mkdir -p /data /workspace
WORKDIR /workspace
RUN rm -rf /opt/redsourcing
EXPOSE 3000 3001
STOPSIGNAL SIGINT
ENTRYPOINT ["red-sourcing"]
CMD ["--help"]
