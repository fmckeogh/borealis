# Included for reference and testing that targeting ARM64 / MUSL is not entirely broken, as it is not tested in CI

FROM rust:alpine AS builder
WORKDIR /tmp/build

ENV RUSTFLAGS="-D warnings"

# print some version information
RUN rustc -V
RUN cargo -V
RUN uname -a

# add rustfmt component
RUN rustup component add rustfmt

# install packages
RUN apk update && apk add opam alpine-sdk zlib-dev xz m4 z3 gmp-dev

# setup OCaml
RUN opam init --disable-sandboxing --bare -y
RUN opam switch create 4.11.2+musl+static+flambda

# install sail
RUN eval `opam env` && opam install --assume-depexts -y sail=0.15 gmp

# fetch crates index
RUN cd /tmp && cargo init --lib empty && cd empty && cargo add itoa && cargo build

# build and document rust dependencies by creating empty crates
RUN cargo init --lib borealis && \
    cargo init --lib sail && \
    cargo init --lib common && \
    cargo init --lib decoder_harness
COPY Cargo.lock .
COPY Cargo.toml .
COPY borealis/Cargo.toml borealis/
COPY sail/Cargo.toml sail/
COPY common/Cargo.toml common/
COPY decoder_harness/Cargo.toml decoder_harness/
RUN eval `opam env` && \
    cargo build --release --workspace --all-targets && \
    cargo test --release --workspace --no-run && \
    cargo doc --release --workspace

# copy full source
COPY . .
RUN touch borealis/src/lib.rs sail/src/lib.rs common/src/lib.rs decoder_harness/src/lib.rs

# check formatting
RUN cargo fmt --all -- --check

# build and run tests
RUN eval `opam env` && cargo test --release --no-fail-fast

# build borealis
RUN eval `opam env` && cargo build --release --all-targets

# build docs
RUN eval `opam env` && cargo doc --release
RUN echo '<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0; URL=/borealis/borealis" /></head></html>' > target/doc/index.html

# run E2E test
FROM builder as borealis_genc
RUN mkdir target/genc
RUN cargo r --release -- --force --log trace -i testdata/sail-arm/arm-v8.5-a/model/sail.json genc -o target/genc

FROM ghcr.io/fmckeogh/gensim:latest as gensim
WORKDIR /tmp/build
COPY --from=borealis_genc /tmp/build/target/genc .
RUN /gensim/gensim --verbose -a main.genc -t output -s captive_decoder,captive_cpu,captive_jitv2,captive_disasm -o captive_decoder.GenerateDotGraph=1,captive_decoder.OptimisationEnabled=1,captive_decoder.OptimisationMinPrefixLength=8,captive_decoder.OptimisationMinPrefixMembers=4,captive_decoder.InlineHints=1

FROM builder as harness
COPY --from=gensim /tmp/build/output/arm64-decode.cpp decoder_harness/include
COPY --from=gensim /tmp/build/output/arm64-decode.h decoder_harness/include
COPY --from=gensim /tmp/build/output/arm64-disasm.cpp decoder_harness/include
COPY --from=gensim /tmp/build/output/arm64-disasm.h decoder_harness/include
RUN cd decoder_harness && cargo build --release --all-targets
RUN cd decoder_harness && cargo test --release --no-fail-fast

# prepare final image
FROM scratch
COPY --from=harness /tmp/build/target/doc /doc
COPY --from=harness /tmp/build/target/release/borealis .
ENTRYPOINT [ "./borealis", "--force", "--log", "trace", "-i", "model/sail.json", "genc", "-o", "target" ]
