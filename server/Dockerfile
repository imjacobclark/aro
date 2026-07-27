FROM rust:1.97-bookworm AS builder
WORKDIR /src
COPY . .
RUN cargo build --locked --release -p aro-server

FROM debian:bookworm-slim
RUN useradd --system --home /var/lib/aro aro \
    && mkdir -p /var/lib/aro /etc/aro \
    && chown -R aro:aro /var/lib/aro
COPY --from=builder /src/target/release/aro-server /usr/local/bin/
USER aro
EXPOSE 4848/tcp
VOLUME ["/var/lib/aro"]
ENTRYPOINT ["aro-server"]
CMD ["--config", "/etc/aro/aro.toml", "serve"]
