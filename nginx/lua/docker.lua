--[[
    docker.lua - Docker socket client for container discovery

    Discovers containers via Docker socket and extracts routing configuration
    from container labels:
    - compass: The hostname for this container (e.g., "app.local")
    - compass.reverse_proxy: Upstream configuration (e.g., "{{upstreams 80}}")
]]

local http = require "resty.http"
local cjson = require "cjson.safe"

local _M = {}

-- Configuration (loaded at runtime from config.lua)
local function get_config()
    return require("config")
end

-- Parse the compass.reverse_proxy label to extract port
-- Format: "{{upstreams PORT}}" or just "PORT"
local function parse_upstream_port(reverse_proxy_label)
    if not reverse_proxy_label then
        return 80  -- default port
    end

    -- Try to extract port from {{upstreams PORT}} format
    local port = reverse_proxy_label:match("{{%s*upstreams%s+(%d+)%s*}}")
    if port then
        return tonumber(port)
    end

    -- Try plain number
    local plain_port = reverse_proxy_label:match("^%s*(%d+)%s*$")
    if plain_port then
        return tonumber(plain_port)
    end

    return 80  -- default
end

-- Query Docker socket for containers with compass labels
function _M.list_compass_containers()
    local config = get_config()
    local network = config.compass_network or "mesh"

    local httpc = http.new()
    httpc:set_timeout(5000)

    -- Connect to Docker socket
    local ok, err = httpc:connect("unix:/var/run/docker.sock")
    if not ok then
        ngx.log(ngx.ERR, "compass: failed to connect to Docker socket: ", err)
        return nil, err
    end

    -- Build filter for containers with compass label on the specified network
    local filters = cjson.encode({
        label = {"compass"},
        network = {network}
    })

    -- URL encode the filters
    local encoded_filters = ngx.escape_uri(filters)

    local res, err = httpc:request({
        method = "GET",
        path = "/containers/json?filters=" .. encoded_filters,
        headers = {
            ["Host"] = "localhost",
            ["Content-Type"] = "application/json"
        }
    })

    if not res then
        ngx.log(ngx.ERR, "compass: failed to query Docker API: ", err)
        httpc:close()
        return nil, err
    end

    local body = res:read_body()
    httpc:close()

    if res.status ~= 200 then
        ngx.log(ngx.ERR, "compass: Docker API returned status ", res.status, ": ", body)
        return nil, "Docker API error: " .. res.status
    end

    local containers, decode_err = cjson.decode(body)
    if not containers then
        ngx.log(ngx.ERR, "compass: failed to decode Docker response: ", decode_err)
        return nil, decode_err
    end

    -- Process containers and extract routing info
    local result = {}
    for _, container in ipairs(containers) do
        local labels = container.Labels or {}
        local hostname = labels["compass"]

        if hostname and hostname ~= "" then
            -- Get container IP from network settings
            local networks = container.NetworkSettings and container.NetworkSettings.Networks or {}
            local network_info = networks[network]
            local ip = network_info and network_info.IPAddress

            if ip and ip ~= "" then
                local port = parse_upstream_port(labels["compass.reverse_proxy"])
                local name = container.Names and container.Names[1] or container.Id
                -- Remove leading slash from container name
                if name:sub(1, 1) == "/" then
                    name = name:sub(2)
                end

                table.insert(result, {
                    id = container.Id,
                    name = name,
                    hostname = hostname,
                    ip = ip,
                    port = port,
                    labels = labels
                })

                ngx.log(ngx.INFO, "compass: discovered container ", name,
                    " -> ", hostname, " (", ip, ":", port, ")")
            else
                ngx.log(ngx.WARN, "compass: container ", container.Id,
                    " has compass label but no IP in network '", network, "'")
            end
        end
    end

    return result, nil
end

-- Docker event watcher - monitors container start/stop/die events
function _M.start_event_watcher()
    local config = get_config()
    local network = config.compass_network or "mesh"

    local function watch_events()
        local httpc = http.new()
        -- Set a long timeout for streaming
        httpc:set_timeout(0)  -- No timeout for streaming

        local ok, err = httpc:connect("unix:/var/run/docker.sock")
        if not ok then
            ngx.log(ngx.ERR, "compass: event watcher failed to connect: ", err)
            return false, err
        end

        -- Build filter for container events we care about
        local filters = cjson.encode({
            type = {"container"},
            event = {"start", "stop", "die", "destroy"}
        })
        local encoded_filters = ngx.escape_uri(filters)

        local res, err = httpc:request({
            method = "GET",
            path = "/events?filters=" .. encoded_filters,
            headers = {
                ["Host"] = "localhost"
            }
        })

        if not res then
            ngx.log(ngx.ERR, "compass: event watcher request failed: ", err)
            httpc:close()
            return false, err
        end

        ngx.log(ngx.INFO, "compass: Docker event stream connected")

        -- Read events from the stream
        local reader = res.body_reader
        if not reader then
            ngx.log(ngx.ERR, "compass: no body reader for event stream")
            httpc:close()
            return false, "no body reader"
        end

        while true do
            local chunk, err = reader()
            if not chunk then
                if err then
                    ngx.log(ngx.WARN, "compass: event stream error: ", err)
                end
                break
            end

            -- Parse the event
            local event = cjson.decode(chunk)
            if event then
                local action = event.Action or event.status
                local actor = event.Actor or {}
                local attributes = actor.Attributes or {}
                local container_name = attributes.name or actor.ID

                ngx.log(ngx.INFO, "compass: Docker event - ", action,
                    " container: ", container_name)

                -- Check if this container has compass label or is on our network
                -- We trigger regeneration for any container event on our network
                -- to keep configs in sync
                local config_generator = require "config_generator"
                config_generator.schedule_regeneration()
            end
        end

        httpc:close()
        return true, nil
    end

    -- Wrapper function for ngx.timer that handles reconnection
    local function event_watcher_loop(premature)
        if premature then
            return
        end

        local ok, err = watch_events()
        if not ok then
            ngx.log(ngx.WARN, "compass: event watcher disconnected, reconnecting in 5s: ", err)
        else
            ngx.log(ngx.INFO, "compass: event watcher stream ended, reconnecting in 1s")
        end

        -- Reconnect after a delay
        local delay = ok and 1 or 5
        local ok, err = ngx.timer.at(delay, event_watcher_loop)
        if not ok then
            ngx.log(ngx.ERR, "compass: failed to schedule event watcher reconnect: ", err)
        end
    end

    -- Start the event watcher loop
    local ok, err = ngx.timer.at(0, event_watcher_loop)
    if not ok then
        ngx.log(ngx.ERR, "compass: failed to start event watcher: ", err)
        return false, err
    end

    return true, nil
end

return _M
