# Patched RustDesk ID server (hbbs) for rd.emillis.net: upstream tag 1.1.16 + 0001-accounts-gate.patch.
# AGPL-3.0, like upstream. Build with ./build.sh (it pins the tag and records the upstream commit).
# PROFILE=fast skips LTO for quicker local iterations; the deployed image uses upstream's release profile.
FROM rust:1.90-bookworm AS build
ARG RD_SERVER_TAG=1.1.16
ARG RD_SERVER_COMMIT=73523b31cfd25d77dee862e6fc9f5e1fb5e485ef
ARG PROFILE=release
WORKDIR /src
RUN git clone --depth 1 --branch "$RD_SERVER_TAG" --recurse-submodules --shallow-submodules \
      https://github.com/rustdesk/rustdesk-server . \
 && test "$(git rev-parse HEAD)" = "$RD_SERVER_COMMIT"
COPY 0001-accounts-gate.patch /tmp/0001-accounts-gate.patch
RUN git apply /tmp/0001-accounts-gate.patch && git diff --stat
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target,id=rd-hbbs-target-${PROFILE} \
    if [ "$PROFILE" = fast ]; then export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16; fi \
 && cargo build --release --locked --bin hbbs \
 && cp target/release/hbbs /hbbs

FROM debian:bookworm-slim
COPY --from=build /hbbs /usr/bin/hbbs
LABEL org.opencontainers.image.title="emilli rustdesk hbbs" \
      org.opencontainers.image.source="https://github.com/rustdesk/rustdesk-server/tree/1.1.16 + deploy/rustdesk-accounts/hbbs/0001-accounts-gate.patch" \
      org.opencontainers.image.licenses="AGPL-3.0"
WORKDIR /root
ENV HOME=/root
