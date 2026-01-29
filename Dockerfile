# mesh-router-compass
# Reverse proxy with Docker container discovery via labels

FROM openresty/openresty:alpine

# Install minimal dependencies
RUN apk add --no-cache \
    gettext \
    curl \
    ca-certificates

# Install lua-resty-http library
COPY ./lua-resty-http/* /usr/local/openresty/lualib/resty/

# Copy nginx configuration to OpenResty location
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy default server configuration
COPY nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf

# Copy Lua scripts to both locations
# - /etc/nginx/lua for config template processing
# - /usr/local/openresty/lualib for require() to find them
COPY nginx/lua/docker.lua /usr/local/openresty/lualib/docker.lua
COPY nginx/lua/config_generator.lua /usr/local/openresty/lualib/config_generator.lua
COPY nginx/lua/config.lua.template /etc/nginx/lua/config.lua.template

# Copy static files
COPY html/404.html /etc/nginx/html/404.html

# Copy entrypoint
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create directories for generated configs and logs
RUN mkdir -p /etc/nginx/conf.d/compass && \
    mkdir -p /tmp/nginx/client_temp && \
    chmod 700 /tmp/nginx/client_temp && \
    mkdir -p /var/log/nginx

# Build version argument
ARG BUILD_VERSION=dev
ENV BUILD_VERSION=${BUILD_VERSION}

# Expose HTTP port
EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
