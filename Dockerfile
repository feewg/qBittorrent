# Multi-stage Dockerfile for qBittorrent-nox
# Build from source, runtime compatible with linuxserver/qbittorrent
# Supports: PUID, PGID, TZ, WEBUI_PORT, TORRENTING_PORT, UMASK

# ============================================================
# Base image: runtime dependencies
# ============================================================
FROM alpine:latest AS base

RUN \
  apk --no-cache --update-cache upgrade

# Runtime dependencies (matching linuxserver/qbittorrent + baseimage)
RUN \
  apk --no-cache add \
    7zip \
    bash \
    ca-certificates \
    catatonit \
    coreutils \
    curl \
    findutils \
    grep \
    icu-libs \
    jq \
    netcat-openbsd \
    p7zip \
    procps-ng \
    python3 \
    qt6-qtbase \
    qt6-qtbase-sqlite \
    shadow \
    su-exec \
    tini \
    tzdata \
    unzip \
    zlib

# Create abc user matching linuxserver baseimage defaults
# abc user: UID=911, GID=911, home=/config
RUN \
  groupmod -g 1000 users && \
  useradd -u 911 -U -d /config -s /bin/false abc && \
  usermod -G users abc && \
  mkdir -p \
    /app \
    /config \
    /defaults

# ============================================================
# Builder image: compile qBittorrent-nox
# ============================================================
FROM base AS builder

ARG BOOST_VERSION_MAJOR="1"
ARG BOOST_VERSION_MINOR="86"
ARG BOOST_VERSION_PATCH="0"
ARG LIBBT_VERSION="v2.0.11"
ARG LIBBT_CMAKE_FLAGS=""

# Build dependencies
RUN \
  apk add \
    cmake \
    g++ \
    git \
    make \
    ninja \
    openssl-dev \
    qt6-qtbase-dev \
    qt6-qtbase-private-dev \
    qt6-qttools-dev \
    zlib-dev

# Compiler/linker hardening flags
ENV CFLAGS="-pipe -fstack-clash-protection -fstack-protector-strong -fno-plt -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -D_GLIBCXX_ASSERTIONS" \
    CXXFLAGS="-pipe -fstack-clash-protection -fstack-protector-strong -fno-plt -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -D_GLIBCXX_ASSERTIONS" \
    LDFLAGS="-gz -Wl,-O1,--as-needed,--sort-common,-z,now,-z,pack-relative-relocs,-z,relro"

# Build and install Boost (headers only)
RUN \
  wget -O boost.tar.gz "https://archives.boost.io/release/${BOOST_VERSION_MAJOR}.${BOOST_VERSION_MINOR}.${BOOST_VERSION_PATCH}/source/boost_${BOOST_VERSION_MAJOR}_${BOOST_VERSION_MINOR}_${BOOST_VERSION_PATCH}.tar.gz" && \
  tar -xf boost.tar.gz && \
  mv boost_* boost && \
  cd boost && \
  ./bootstrap.sh && \
  ./b2 stage --stagedir=./ --with-headers

# Build and install libtorrent (static)
RUN \
  git clone \
    --branch "${LIBBT_VERSION}" \
    --depth 1 \
    --recurse-submodules \
    https://github.com/arvidn/libtorrent.git && \
  cd libtorrent && \
  cmake \
    -B build \
    -G Ninja \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DBOOST_ROOT=/boost/lib/cmake \
    -Ddeprecated-functions=OFF \
    ${LIBBT_CMAKE_FLAGS} && \
  cmake --build build -j "$(nproc)" && \
  cmake --install build

# Build and install qBittorrent-nox from local source
COPY . /src/qbittorrent
WORKDIR /src/qbittorrent

RUN \
  cmake \
    -B build \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DBOOST_ROOT=/boost/lib/cmake \
    -DGUI=OFF && \
  cmake --build build -j "$(nproc)" && \
  cmake --install build

# Verify binary dependencies
RUN \
  ldd /usr/bin/qbittorrent-nox | sort -f

# Record compile-time Software Bill of Materials
RUN \
  printf "Software Bill of Materials for building qbittorrent-nox\n\n" > /sbom.txt && \
  echo "boost ${BOOST_VERSION_MAJOR}.${BOOST_VERSION_MINOR}.${BOOST_VERSION_PATCH}" >> /sbom.txt && \
  cd /libtorrent && \
  echo "libtorrent-rasterbar git $(git rev-parse HEAD)" >> /sbom.txt && \
  echo "qBittorrent local source build" >> /sbom.txt && \
  echo >> /sbom.txt && \
  apk list -I | sort >> /sbom.txt && \
  cat /sbom.txt

# ============================================================
# Runtime image (linuxserver/qbittorrent compatible)
# ============================================================
FROM base

# Environment settings (matching linuxserver/qbittorrent)
ENV HOME="/config" \
    XDG_CONFIG_HOME="/config" \
    XDG_DATA_HOME="/config"

# Copy binary and SBOM from builder
COPY --from=builder /usr/bin/qbittorrent-nox /usr/bin/qbittorrent-nox
COPY --from=builder /sbom.txt /sbom.txt

# Copy default config and entrypoint
COPY root/ /

# Set entrypoint permissions
RUN chmod +x /entrypoint.sh

VOLUME ["/config", "/downloads"]

# WebUI default port
EXPOSE 8080

# BitTorrent listening port
EXPOSE 6881 6881/udp

ENTRYPOINT ["/sbin/tini", "-g", "--", "/entrypoint.sh"]
