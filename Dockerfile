# Multi-stage Dockerfile for qBittorrent-nox
# Builds qbittorrent-nox from source with libtorrent-rasterbar
# Reference: .github/workflows/ci_ubuntu.yaml

# ============================================================
# Build stage: compile qBittorrent-nox with all dependencies
# ============================================================
FROM ubuntu:24.04 AS builder

ARG LIBTORRENT_VERSION=2.0.11
ARG BOOST_MAJOR=1
ARG BOOST_MINOR=77
ARG BOOST_PATCH=0
ARG QT_VERSION=6.6.3
ARG CMAKE_BUILD_TYPE=RelWithDebInfo

ENV DEBIAN_FRONTEND=noninteractive
ENV BOOST_PATH=/opt/boost
ENV LIBTORRENT_PATH=/tmp/libtorrent

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ninja-build \
    git \
    curl \
    ca-certificates \
    libssl-dev \
    zlib1g-dev \
    pkg-config \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Boost (headers only), matching CI approach
RUN BOOST_VERSION="${BOOST_MAJOR}.${BOOST_MINOR}.${BOOST_PATCH}" \
    && boost_underscore="${BOOST_MAJOR}_${BOOST_MINOR}_${BOOST_PATCH}" \
    && boost_url="https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${boost_underscore}.tar.gz" \
    && boost_url2="https://sourceforge.net/projects/boost/files/boost/${BOOST_VERSION}/boost_${boost_underscore}.tar.gz" \
    && set +e \
    && curl -L -o /tmp/boost.tar.gz "$boost_url" \
    && tar -xf /tmp/boost.tar.gz -C /tmp; _exitCode=$? \
    && if [ "$_exitCode" -ne 0 ]; then \
        curl -L -o /tmp/boost.tar.gz "$boost_url2" \
        && tar -xf /tmp/boost.tar.gz -C /tmp; \
    fi \
    && mv "/tmp/boost_${boost_underscore}" "${BOOST_PATH}" \
    && cd "${BOOST_PATH}" \
    && ./bootstrap.sh \
    && ./b2 stage --stagedir=./ --with-headers \
    && rm -f /tmp/boost.tar.gz

# Install Qt6 via aqtinstall (same backend as jurplel/install-qt-action used in CI)
ENV QT_PATH=/opt/Qt
RUN python3 -m venv /tmp/aqt-venv \
    && . /tmp/aqt-venv/bin/activate \
    && pip install aqtinstall \
    && aqt install-qt linux desktop "${QT_VERSION}" -O "${QT_PATH}" \
        -m qtimageformats \
        --archives qtbase qtdeclarative qtsvg qttools icu \
    && deactivate \
    && rm -rf /tmp/aqt-venv

ENV Qt6_DIR="${QT_PATH}/${QT_VERSION}/gcc_64"
ENV PATH="${Qt6_DIR}/bin:${PATH}"

# Build and install libtorrent (static), matching CI approach
RUN git clone \
    --branch "v${LIBTORRENT_VERSION}" \
    --depth 1 \
    --recurse-submodules \
    https://github.com/arvidn/libtorrent.git \
    "${LIBTORRENT_PATH}" \
    && cd "${LIBTORRENT_PATH}" \
    && CXXFLAGS="-D_FORTIFY_SOURCE=3 -D_GLIBCXX_ASSERTIONS" \
    cmake -B build -G "Ninja" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DCMAKE_CXX_STANDARD=20 \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DBOOST_ROOT="${BOOST_PATH}/lib/cmake" \
        -Ddeprecated-functions=OFF \
    && cmake --build build \
    && cmake --install build \
    && rm -rf "${LIBTORRENT_PATH}"

# Build qBittorrent-nox (GUI=OFF), matching CI approach
COPY . /src/qbittorrent
WORKDIR /src/qbittorrent

RUN CXXFLAGS="-D_FORTIFY_SOURCE=3 -D_GLIBCXX_ASSERTIONS -DQT_FORCE_ASSERTS" \
    cmake -B build -G "Ninja" \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DBOOST_ROOT="${BOOST_PATH}/lib/cmake" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DGUI=OFF \
        -DWEBUI=ON \
        -DSTACKTRACE=OFF \
        -DTESTING=OFF \
        -DVERBOSE_CONFIGURE=ON \
    && cmake --build build --target qbt_update_translations \
    && cmake --build build \
    && DESTDIR=/tmp/install cmake --install build

# ============================================================
# Runtime stage: minimal image with qbittorrent-nox binary + Qt runtime
# ============================================================
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3t64 \
    zlib1g \
    ca-certificates \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Copy Qt runtime libraries from builder
COPY --from=builder /opt/Qt/6.6.3/gcc_64/lib/ /usr/lib/qt6/lib/
COPY --from=builder /opt/Qt/6.6.3/gcc_64/plugins/ /usr/lib/qt6/plugins/

# Set Qt environment
ENV QT_PLUGIN_PATH=/usr/lib/qt6/plugins
ENV LD_LIBRARY_PATH=/usr/lib/qt6/lib
ENV QPA_PLATFORM=offscreen

# Copy the built qbittorrent-nox
COPY --from=builder /tmp/install/usr/bin/qbittorrent-nox /usr/bin/qbittorrent-nox

# Verify the binary works
RUN qbittorrent-nox -v

# Create a non-root user
RUN groupadd -g 1000 qbtuser \
    && useradd -u 1000 -g qbtuser -m -s /bin/bash qbtuser

# Create default directories
RUN mkdir -p /home/qbtuser/.config/qBittorrent \
    && mkdir -p /downloads \
    && chown -R qbtuser:qbtuser /home/qbtuser /downloads

# Accept legal notice so WebUI works immediately
RUN printf '[LegalNotice]\nAccepted=true\n' > /home/qbtuser/.config/qBittorrent/qBittorrent.conf \
    && chown qbtuser:qbtuser /home/qbtuser/.config/qBittorrent/qBittorrent.conf

VOLUME ["/downloads", "/home/qbtuser/.config/qBittorrent"]

USER qbtuser

# WebUI default port
EXPOSE 8080

# BitTorrent listening port
EXPOSE 6881 6881/udp

ENTRYPOINT ["tini", "--"]
CMD ["qbittorrent-nox", "--webui-port=8080"]
