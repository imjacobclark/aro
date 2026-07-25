FROM rust:1.97-bookworm AS builder
WORKDIR /src
COPY . .
RUN cargo build --locked --release -p sonora-server

FROM debian:bookworm-slim
RUN useradd --system --home /var/lib/sonora sonora \
    && mkdir -p /var/lib/sonora /etc/sonora \
    && chown -R sonora:sonora /var/lib/sonora
COPY --from=builder /src/target/release/sonora-server /usr/local/bin/
USER sonora
EXPOSE 4848/tcp
VOLUME ["/var/lib/sonora"]
ENTRYPOINT ["sonora-server"]
CMD ["--config", "/etc/sonora/sonora.toml", "serve"]
