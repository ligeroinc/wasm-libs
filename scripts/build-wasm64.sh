#!/usr/bin/env bash
#
# Build all wasm-libs archives as 64-bit wasm (Emscripten MEMORY64).
#
# Run INSIDE the ligetron build container (ligetron/build-env-arm64:local or the
# x86 equivalent), which provides the pinned toolchain: emcc 4.0.21 + a native
# gcc for build-system codegen. Emscripten <-> lib versions are pinned to match
# the wasm32 v1.2.0 distribution.
#
#   docker run --rm -v <out>:/out ligetron/build-env-arm64:local \
#     bash /path/to/build-wasm64.sh /out
#
# Output: $PREFIX/{lib,include} containing wasm64 .a archives + headers + cmake
# configs, ABI-verified by the trailing check.
#
# NOTE ON RUNTIME: a -sMEMORY64=1 module emits a 64-bit *table* (table64). The
# node bundled with emsdk 4.0.21 (v22.16) cannot instantiate that encoding
# ("invalid table elements limits flags"); use a newer node or a browser
# (Chrome 138+) to actually run wasm64. This does not affect the archives.
set -euo pipefail

PREFIX="${1:-/opt/wasm-libs64}"        # install prefix (writable)
WORK="${WORK:-/tmp/w64}"
JOBS="$(nproc)"
M64="-sMEMORY64=1"

# Pinned versions — must match the wasm32 distribution these replace.
GMP_VERSION=6.3.0
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
WABT_VERSION=1.0.34
OPENSSL_BRANCH=openssl-3.5        # libcrypto/libssl 3.5.x
BOOST_VERSION=1.88.0
BOOST_SHA256=3621533e820dcab1e8012afd583c0c73cf0f77694952b81352bf38c1488f9cb4
BOOST_LIBS=serialization,iostreams,test
PROTOBUF_TAG=v21.12               # == C++ lib version 3.21.12 (pre-abseil)

source /opt/emsdk/emsdk_env.sh
mkdir -p "$WORK" "$PREFIX/lib" "$PREFIX/include"
cd "$WORK"

# ---- GMP (libgmp.a, libgmpxx.a) ----------------------------------------------
# --host=none => generic C, no asm. CC_FOR_BUILD must be the NATIVE compiler:
# GMP builds host-run codegen tools, and emconfigure otherwise mis-selects
# emsdk clang for them (fails on arm64). wasm64 => 64-bit mp_limb_t.
[ -f gmp-${GMP_VERSION}.tar.xz ] || wget -q "https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz"
echo "${GMP_SHA256}  gmp-${GMP_VERSION}.tar.xz" | sha256sum -c -
rm -rf gmp-${GMP_VERSION} && tar -xf gmp-${GMP_VERSION}.tar.xz
( cd gmp-${GMP_VERSION}
  emconfigure ./configure --disable-shared --enable-static --host=none --enable-cxx \
    --prefix="$PREFIX" CFLAGS="-O2 $M64" CXXFLAGS="-O2 $M64" CC_FOR_BUILD=/usr/bin/cc
  emmake make -j"$JOBS"
  emmake make install )

# ---- wabt (libwabt.a, libwasm-rt-impl.a) -------------------------------------
# Build the static-lib targets only; the EMSCRIPTEN libwabtjs target uses
# wasm2js (-s WASM=0) which cannot support MEMORY64. Install via cmake --install
# so the broken JS target is never built.
rm -rf wabt-src
git clone --depth 1 --branch ${WABT_VERSION} --recursive --shallow-submodules \
  https://github.com/WebAssembly/wabt wabt-src
( cd wabt-src && mkdir -p build && cd build
  emcmake cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_CXX_FLAGS="-O3 -DNDEBUG -flto $M64" -DCMAKE_C_FLAGS="-O3 -DNDEBUG -flto $M64" \
    -DBUILD_TESTS=OFF -DBUILD_TOOLS=OFF -DBUILD_LIBWASM=ON
  ninja -j"$JOBS" wabt wasm-rt-impl
  cmake --install . )

# ---- OpenSSL (libcrypto.a, libssl.a) -----------------------------------------
# no-asm; linux-generic32 kept from the wasm32 recipe (its 32-bit BN words are
# still correct under wasm64 — switching to linux-generic64 is a perf-only
# follow-up).
rm -rf openssl
git clone --depth 1 --branch ${OPENSSL_BRANCH} https://github.com/openssl/openssl.git
( cd openssl
  export CC=emcc CXX=em++ AR=emar RANLIB=emranlib NM=emnm LD=emcc
  export CFLAGS="-O3 $M64" CXXFLAGS="-O3 $M64" LDFLAGS="-O3 $M64"
  ./Configure no-threads no-shared no-dso no-engine no-tests no-asm \
    -O3 -flto -DNDEBUG $M64 --prefix="$PREFIX" --openssldir="$PREFIX" linux-generic32
  make build_generated
  make -j"$JOBS" libcrypto.a libssl.a
  make install_dev )

# ---- Boost (static libs from $BOOST_LIBS) ------------------------------------
[ -f boost_${BOOST_VERSION//./_}.tar.gz ] || \
  wget -q "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_VERSION//./_}.tar.gz"
echo "${BOOST_SHA256}  boost_${BOOST_VERSION//./_}.tar.gz" | sha256sum -c -
rm -rf boost_${BOOST_VERSION//./_} && tar -xzf boost_${BOOST_VERSION//./_}.tar.gz
( cd boost_${BOOST_VERSION//./_}
  export CC=emcc CXX=em++ AR=emar RANLIB=emranlib
  ./bootstrap.sh --prefix="$PREFIX" --with-libraries="$BOOST_LIBS"
  ./b2 install --prefix="$PREFIX" --layout=system toolset=emscripten variant=release \
    exception-handling=on exception-handling-method=js define=BOOST_LOG_USE_STD_REGEX=1 \
    cxxflags="-std=c++20 -O3 -DNDEBUG -mbulk-memory -sUSE_PTHREADS=1 -sUSE_ZLIB=1 $M64" \
    linkflags="-sUSE_ZLIB=1 -sUSE_PTHREADS=1 $M64 -O3" \
    link=static threading=multi -j"$JOBS" )

# ---- protobuf (libprotobuf.a, libprotobuf-lite.a) ----------------------------
# 21.12 is pre-abseil. protoc is NOT built (can't run wasm); ligetron uses the
# native protoc via -DProtobuf_PROTOC_EXECUTABLE.
rm -rf protobuf
git clone --depth 1 --branch ${PROTOBUF_TAG} https://github.com/protocolbuffers/protobuf.git
( cd protobuf && mkdir -p build && cd build
  emcmake cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_ABSL_PROVIDER=none \
    -DCMAKE_CXX_FLAGS="-O3 -DNDEBUG $M64" -DCMAKE_C_FLAGS="-O3 -DNDEBUG $M64"
  ninja -j"$JOBS" libprotobuf libprotobuf-lite
  cmake --install . )

# ---- ABI verification: every archive must be wasm64 --------------------------
# wasm-ld defaults to wasm32 and rejects wasm64 objects with a distinctive error.
echo "=== wasm64 ABI check ==="
WLD=/opt/emsdk/upstream/bin/wasm-ld
tmp="$(mktemp -d)"; cd "$tmp"; rc=0
for a in "$PREFIX"/lib/*.a; do
  obj=$(ar t "$a" | grep -m1 '\.o$') || continue
  ar p "$a" "$obj" > x.o
  if "$WLD" --no-entry --experimental-pic -shared x.o -o /dev/null 2>&1 \
       | grep -q "must specify -mwasm64"; then
    printf '  %-32s wasm64 OK\n' "$(basename "$a")"
  else
    printf '  %-32s NOT wasm64!\n' "$(basename "$a")"; rc=1
  fi
done
exit $rc
