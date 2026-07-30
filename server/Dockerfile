FROM rust:1.97-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends libchromaprint-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN cargo build --locked --release -p aro-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libchromaprint1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /var/lib/aro aro \
    && mkdir -p /var/lib/aro /etc/aro \
    && chown -R aro:aro /var/lib/aro
COPY --from=builder /src/target/release/aro-server /usr/local/bin/
USER aro
EXPOSE 4848/tcp
VOLUME ["/var/lib/aro"]
ENTRYPOINT ["aro-server"]
CMD ["--config", "/etc/aro/aro.toml", "serve"]
