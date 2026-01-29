#!/bin/sh
set -e

echo "Starting mesh-router-compass v${BUILD_VERSION:-dev}"

# Set defaults
export COMPASS_NETWORK="${COMPASS_NETWORK:-mesh}"
export COMPASS_HTTP_PORT="${COMPASS_HTTP_PORT:-80}"

echo "  COMPASS_NETWORK: ${COMPASS_NETWORK}"
echo "  COMPASS_HTTP_PORT: ${COMPASS_HTTP_PORT}"

# Check Docker socket
if [ ! -S /var/run/docker.sock ]; then
    echo "WARNING: Docker socket not found at /var/run/docker.sock"
    echo "         Container discovery will not work without Docker socket mount."
    echo "         Use: -v /var/run/docker.sock:/var/run/docker.sock"
else
    # Make Docker socket readable by nginx worker (nobody)
    chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

# Generate Lua config from template
echo "Generating Lua config..."
envsubst '${COMPASS_NETWORK} ${COMPASS_HTTP_PORT}' \
    < /etc/nginx/lua/config.lua.template \
    > /usr/local/openresty/lualib/config.lua

echo "Config generated:"
cat /usr/local/openresty/lualib/config.lua

# Create required directories
mkdir -p /etc/nginx/conf.d/compass
# Make compass config dir writable by nginx worker (nobody)
chmod 777 /etc/nginx/conf.d/compass
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log
touch /var/log/nginx/error.log
# Make nginx logs directory writable for worker process reload
chmod 777 /usr/local/openresty/nginx/logs

# Test nginx configuration
echo "Testing nginx configuration..."
if ! openresty -t; then
    echo "ERROR: nginx configuration test failed"
    exit 1
fi

echo "Configuration test passed, starting OpenResty..."

# Start OpenResty (nginx) in foreground
exec openresty -g 'daemon off;'
