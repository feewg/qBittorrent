#!/bin/sh
# Entrypoint script compatible with linuxserver/qbittorrent
# Supports: PUID, PGID, TZ, WEBUI_PORT, TORRENTING_PORT, UMASK

set -e

# ============================
# Configure user/group (PUID/PGID)
# Matching linuxserver baseimage init-adduser behavior
# ============================
PUID=${PUID:-911}
PGID=${PGID:-911}

# Get current IDs of abc user
CURRENT_UID=$(id -u abc)
CURRENT_GID=$(id -g abc)

# linuxserver does: temporarily change home to /root, modify ids, then change back
# This avoids issues with home directory ownership
USERHOME=$(grep abc /etc/passwd | cut -d ":" -f6)
usermod -d "/root" abc

if [ "${CURRENT_GID}" != "${PGID}" ]; then
    groupmod -o -g "${PGID}" abc
fi

if [ "${CURRENT_UID}" != "${PUID}" ]; then
    usermod -o -u "${PUID}" abc
fi

usermod -d "${USERHOME}" abc

# ============================
# Configure timezone
# ============================
if [ -n "${TZ}" ]; then
    if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
        cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
    fi
fi

# ============================
# Configure umask
# ============================
if [ -n "${UMASK}" ]; then
    umask "${UMASK}"
fi

# ============================
# Set up qBittorrent config
# Matching linuxserver init-qbittorrent-config behavior
# ============================
mkdir -p /config/qBittorrent

# Copy default config if not present (first run)
if [ ! -f /config/qBittorrent/qBittorrent.conf ]; then
    if [ -f /defaults/qBittorrent.conf ]; then
        cp /defaults/qBittorrent.conf /config/qBittorrent/qBittorrent.conf
    fi
fi

# Set ownership (matching linuxserver behavior)
chown abc:abc /app 2>/dev/null || true
chown abc:abc /config
chown abc:abc /defaults 2>/dev/null || true

# Only chown /downloads mount point (not recursively, matching linuxserver)
if grep -qe ' /downloads ' /proc/mounts 2>/dev/null; then
    chown abc:abc /downloads 2>/dev/null || true
fi

chown -R abc:abc /config/qBittorrent

# ============================
# Print user info (matching linuxserver output)
# ============================
echo "
-------------------------------------
GID/UID
-------------------------------------
User UID: $(id -u abc)
User GID: $(id -g abc)
-------------------------------------
"

# ============================
# Start qbittorrent-nox
# ============================
WEBUI_PORT=${WEBUI_PORT:-8080}

QBT_ARGS="--webui-port=${WEBUI_PORT}"
if [ -n "${TORRENTING_PORT}" ]; then
    QBT_ARGS="${QBT_ARGS} --torrenting-port=${TORRENTING_PORT}"
fi

echo "Starting qBittorrent-nox --webui-port=${WEBUI_PORT}${TORRENTING_PORT:+ --torrenting-port=${TORRENTING_PORT}}"

exec su-exec abc qbittorrent-nox ${QBT_ARGS}
