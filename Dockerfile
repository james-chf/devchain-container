FROM ubuntu:jammy-20221101 AS ubuntu

FROM ubuntu AS base

# https://github.com/docker/buildx/issues/510#issuecomment-763663610
ARG TARGETPLATFORM
ENV TARGETPLATFORM=${TARGETPLATFORM:-linux/amd64}

RUN apt-get update && \
    apt-get install -y \
    build-essential \
    clang-tools-14 \
    curl \
    git \
    libssl-dev \
    pkg-config && \
    rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1000 builder && \
    useradd -r -m -u 1000 -g builder builder
RUN mkdir /usr/local/src/namada && chown -R builder:builder /usr/local/src/namada

USER builder

ENV RUSTFLAGS="-C strip=symbols"

ARG RUSTUP_TOOLCHAIN="nightly-2022-11-03"
ENV RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN}
ENV CARGO_UNSTABLE_SPARSE_REGISTRY="true"

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain $RUSTUP_TOOLCHAIN
ENV PATH="/home/builder/.cargo/bin:${PATH}"
RUN cargo install cargo-chef --locked

RUN git clone --depth=1 https://github.com/anoma/namada.git /usr/local/src/namada
WORKDIR /usr/local/src/namada

# BASE_POINT should be an ancestor of REF that shares the same toolchain
ARG BASE_POINT=v0.11.0
RUN git fetch --tags
RUN git fetch --depth=1 origin $BASE_POINT && git checkout $BASE_POINT
# actual nightly toolchain specified in repo is needed for running rustfmt in build.rs
# can be removed once https://github.com/anoma/namada/issues/40 is done
RUN rustup toolchain install "$(cat rust-nightly-version)"

RUN cargo fetch
RUN cargo chef prepare
ARG NAMADA_BASE_FFLAGS="default"
RUN cargo chef cook \
    --no-default-features \
    --features "$NAMADA_BASE_FFLAGS"
RUN git reset --hard

FROM base AS ref
ARG REF=v0.11.0
RUN git fetch --depth=1 origin $REF && git checkout $REF
# actual nightly toolchain specified in repo is needed for running rustfmt in build.rs
# can be removed once https://github.com/anoma/namada/issues/40 is done
RUN rustup toolchain install "$(cat rust-nightly-version)"

FROM ref as builder
RUN cargo fetch
RUN cargo chef prepare
ARG NAMADA_REF_FFLAGS="default"
RUN cargo chef cook \
    --no-default-features \
    --features "$NAMADA_REF_FFLAGS"
RUN git reset --hard
RUN cargo build \
    --no-default-features \
    --features "$NAMADA_REF_FFLAGS" \
    --package namada_apps \
    --bin namada
RUN cargo build \
    --no-default-features \
    --features "$NAMADA_REF_FFLAGS" \
    --package namada_apps \
    --bin namadaw
RUN cargo build \
    --no-default-features \
    --features "$NAMADA_REF_FFLAGS" \
    --package namada_apps \
    --bin namadac
RUN cargo build \
    --no-default-features \
    --features "$NAMADA_REF_FFLAGS" \
    --package namada_apps \
    --bin namadan

FROM ref AS tendermint-downloader
ARG TENDERMINT_ARM64_URL="https://github.com/heliaxdev/tendermint/releases/download/v0.1.4-abciplus/tendermint_0.1.4-abciplus_linux_arm64.tar.gz"
ARG TENDERMINT_AMD64_URL="https://github.com/heliaxdev/tendermint/releases/download/v0.1.4-abciplus/tendermint_0.1.4-abciplus_linux_amd64.tar.gz"
COPY --chmod=0755 download_tendermint.sh /usr/local/bin
RUN download_tendermint.sh

FROM ref AS wasm-builder
RUN rustup target add wasm32-unknown-unknown
RUN make -C wasm/wasm_source

FROM ubuntu
RUN apt-get update && \
    apt-get install -y \
    ca-certificates \
    curl \
    python3 \
    python3-pip \
    sudo && \
    apt-get clean

RUN pip3 install --no-cache-dir \
    toml==0.10.2 \
    toml-cli==0.3.1 \
    updog==1.4

# disable validator Ethereum bridge functionality by default
ENV NAMADA_LEDGER__ETHEREUM_BRIDGE__MODE='Off'
# ensure Tendermint RPC is exposed from within the container to the outside world
ENV NAMADA_LEDGER__TENDERMINT__RPC_ADDRESS='0.0.0.0:26657'

COPY --from=tendermint-downloader --chmod=500 /tmp/tendermint /usr/local/bin
COPY --from=builder /usr/local/src/namada/target/debug/namada /usr/local/bin
COPY --from=builder /usr/local/src/namada/target/debug/namadaw /usr/local/bin
COPY --from=builder /usr/local/src/namada/target/debug/namadac /usr/local/bin
COPY --from=builder /usr/local/src/namada/target/debug/namadan /usr/local/bin

WORKDIR /srv
COPY --from=wasm-builder /usr/local/src/namada/wasm/checksums.py wasm/checksums.py
COPY --from=wasm-builder /usr/local/src/namada/wasm/*.wasm wasm/

# download MASP params
RUN mkdir masp && \
    curl -o masp/masp-spend.params -sLO https://github.com/anoma/masp/blob/ef0ef75e81696ff4428db775c654fbec1b39c21f/masp-spend.params?raw=true && \
    curl -o masp/masp-output.params -sLO https://github.com/anoma/masp/blob/ef0ef75e81696ff4428db775c654fbec1b39c21f/masp-output.params?raw=true && \
    curl -o masp/masp-convert.params -sLO https://github.com/anoma/masp/blob/ef0ef75e81696ff4428db775c654fbec1b39c21f/masp-convert.params?raw=true
ENV NAMADA_MASP_PARAMS_DIR='/srv/masp'

ENV ALIAS="validator-dev"
RUN namadac utils init-genesis-validator \
    --alias $ALIAS \
    --net-address 127.0.0.1:26656 \
    --commission-rate 0.1 \
    --max-commission-rate-change 0.1 \
    --unsafe-dont-encrypt

COPY --chmod=0755 add_validator_shard.py /usr/local/bin

COPY network-config.toml .
ENV NAMADA_NETWORK_CONFIG_PATH="network-config-processed.toml"
RUN add_validator_shard.py .namada/pre-genesis/$ALIAS/validator.toml network-config.toml > $NAMADA_NETWORK_CONFIG_PATH

ENV NAMADA_CHAIN_PREFIX="dev"
ENV TM_LOG_LEVEL=info
ENV NAMADA_LOG=info
EXPOSE 8123 26656 26657
COPY init_chain.sh .
COPY run.sh .
CMD ["./run.sh"]