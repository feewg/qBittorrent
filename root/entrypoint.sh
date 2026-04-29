#!/bin/sh
# Entrypoint script compatible with linuxserver/qbittorrent environment variables
# Supports: PUID, PGID, TZ, WEBUI_PORT, TORRENTING_PORT, UMASK

set -e

# ============================
# Configure timezone
# ============================
if [ -n "${TZ}" ]; then
    # On Alpine, configure timezone
    if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
        cp "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
    fi
fi

# ============================
# Configure user/group (PUID/PGID)
# ============================
PUID=${PUID:-1000}
PGID=${PGID:-1000}

# Get current IDs of qbtUser
CURRENT_UID=$(id -u qbtUser)
CURRENT_GID=$(id -g qbtUser)

# Update group ID if needed
if [ "${CURRENT_GID}" != "${PGID}" ]; then
    groupmod -o -g "${PGID}" qbtUser
fi

# Update user ID if needed
if [ "${CURRENT_UID}" != "${PUID}" ]; then
    usermod -o -u "${PUID}" qbtUser
fi

# ============================
# Configure umask
# ============================
if [ -n "${UMASK}" ]; then
    umask "${UMASK}"
fi

# ============================
# Set up default config
# ============================
QBT_CONFIG_DIR="/config/qBittorrent"
QBT_CONFIG_FILE="${QBT_CONFIG_DIR}/qBittorrent.conf"

# Create config directories
mkdir -p "${QBT_CONFIG_DIR}"
mkdir -p /downloads

# Copy default config if not present (first run)
if [ ! -f "${QBT_CONFIG_FILE}" ]; then
    if [ -f "/defaults/qBittorrent.conf" ]; then
        cp /defaults/qBittorrent.conf "${QBT_CONFIG_FILE}"
    fi
fi

# Update WebUI port in config if WEBUI_PORT is set
if [ -n "${WEBUI_PORT}" ]; then
    if [ -f "${QBT_CONFIG_FILE}" ]; then
        sed -i "s|^WebUI\\\\Port=.*|WebUI\\\\Port=${WEBUI_PORT}|" "${QBT_CONFIG_FILE}" 2>/dev/null || true
    fi
fi

# Update torrenting port in config if TORRENTING_PORT is set
if [ -n "${TORRENTING_PORT}" ]; then
    if [ -f "${QBT_CONFIG_FILE}" ]; then
        sed -i "s|^Connection\\\\PortRangeMin=.*|Connection\\\\PortRangeMin=${TORRENTING_PORT}|" "${QBT_CONFIG_FILE}" 2>/dev/null || true
    fi
fi

# ============================
# Fix permissions
# ============================
# Ensure qbtUser owns config and downloads
chown -R qbtUser:qbtUser /config
chown -R qbtUser:qbtUser /downloads 2>/dev/null || true

# ============================
# Determine WebUI port
# ============================
WEBUI_PORT=${WEBUI_PORT:-8080}

# Build qbittorrent-nox command arguments
QBT_ARGS="--webui-port=${WEBUI_PORT}"

if [ -n "${TORRENTING_PORT}" ]; then
    QBT_ARGS="${QBT_ARGS} --torrenting-port=${TORRENTING_PORT}"
fi

# ============================
# Start qbittorrent-nox
# ============================
echo "Starting qBittorrent-nox with PUID=${PUID}, PGID=${PGID}, WEBUI_PORT=${WEBUI_PORT}"
echo "Config: ${QBT_CONFIG_FILE}"

exec doas -u qbtUser qbittorrent-nox ${QBT_ARGS}
