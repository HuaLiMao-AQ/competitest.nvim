local luv = vim.uv and vim.uv or vim.loop

---@class (exact) competitest.SocketIOClient
---@field host string hostname or IP of the router
---@field port integer port of the router
---@field path string Socket.IO path (e.g. "/ws")
---@field sid string? session ID received during handshake
---@field ping_interval integer interval in ms between server pings
---@field ping_timeout integer timeout in ms for server ping response
---@field connected boolean whether the client is connected
---@field private cookies string? cookies from handshake response (for session stickiness)
---@field private pending_events { event: string, data: any }[] events received but not yet consumed
---@field private waiters { [string]: fun(data: any)[] } callbacks waiting for specific events
local Client = {}
Client.__index = Client ---@diagnostic disable-line: inject-field

---Create a new Socket.IO HTTP polling client
---@param opts { host?: string, port?: integer, path?: string }
---@return competitest.SocketIOClient
function Client.new(opts)
	opts = opts or {}
	---@type competitest.SocketIOClient
	local self = {
		host = opts.host or "127.0.0.1",
		port = opts.port or 27121,
		path = opts.path or "/ws",
		sid = nil,
		ping_interval = 25000,
		ping_timeout = 20000,
		connected = false,
		cookies = nil,
		pending_events = {},
		waiters = {},
	}
	setmetatable(self, Client)
	return self
end

---Build the polling path with query parameters
---@private
---@return string
function Client:_poll_path()
	local params = "EIO=4&transport=polling&type=vscode"
	if self.sid then
		params = params .. "&sid=" .. self.sid
	end
	return self.path .. "/?" .. params
end

---Perform the Socket.IO handshake via HTTP polling
---@return string? error # nil on success, error message on failure
function Client:connect()
	if self.connected then
		return nil
	end

	local body, headers, err = self:_http_get(self:_poll_path(), 5000)
	if err then
		return "connect handshake GET failed: " .. err
	end
	if not body then
		return "connect handshake GET returned empty response"
	end

	-- Store cookies for session stickiness
	if headers then
		local set_cookie = headers:match("[Ss]et%-[Cc]ookie:%s*([^\r\n]+)")
		if set_cookie then
			self.cookies = set_cookie:match("^([^;]+)")
		end
	end

	-- Parse Engine.IO OPEN packet: 0{"sid":"...","pingInterval":...,"pingTimeout":...}
	local json_str = body:match("^0(.+)$")
	if not json_str then
		return "unexpected handshake response: " .. body:sub(1, 200)
	end

	local ok, data = pcall(vim.json.decode, json_str)
	if not ok then
		return "failed to decode handshake JSON: " .. tostring(data)
	end

	if not data.sid then
		return "handshake response missing sid"
	end

	self.sid = data.sid
	self.ping_interval = data.pingInterval or 25000
	self.ping_timeout = data.pingTimeout or 20000
	self.connected = true

	-- Send Socket.IO CONNECT packet (Engine.IO MESSAGE "4" + Socket.IO CONNECT "0")
	self:_send_raw("40")

	-- Wait for the server's CONNECT acknowledgement ("40" or "40{...}")
	local deadline = luv.now() + 5000
	while luv.now() < deadline do
		local remaining = deadline - luv.now()
		if remaining <= 0 then
			break
		end
		local poll_timeout = math.min(remaining, 1000)
		local poll_body, _, poll_err = self:_http_get(self:_poll_path(), poll_timeout)
		if poll_err then
			self.connected = false
			return "connect: failed waiting for CONNECT acknowledgement: " .. poll_err
		end
		if poll_body and poll_body ~= "" then
			self:_parse_packets(poll_body)
		end
		if not self.connected then
			return "connect: server rejected CONNECT"
		end
		break
	end

	return nil
end

---Send a Socket.IO event to the server
---@param event string the event name
---@param data any? data to send with the event (must be JSON-serializable)
---@return string? error # nil on success, error message on failure
function Client:emit(event, data)
	if not self.connected then
		return "not connected"
	end

	-- Engine.IO MESSAGE (4) + Socket.IO EVENT (2) = 42
	local payload = "42" .. vim.json.encode({ event, data })
	local _, _, err = self:_http_post(self:_poll_path(), payload)
	if err then
		return "emit failed: " .. err
	end

	return nil
end

---Poll the server for new messages
---@private
---@return string? error # nil on success, error message on failure
function Client:_poll()
	if not self.connected then
		return "not connected"
	end

	local body, _, err = self:_http_get(self:_poll_path(), self.ping_interval + self.ping_timeout)
	if err then
		return "poll failed: " .. err
	end
	if not body or body == "" then
		return nil
	end

	self:_parse_packets(body)
	return nil
end

---Parse Engine.IO/Socket.IO packets from a polling response
---@private
---@param body string raw response body
function Client:_parse_packets(body)
	local pos = 1
	while pos <= #body do
		local len = body:match("^(%d+):", pos)
		if len and body:sub(pos + #len + 1, pos + #len + 1):match("^%d") then
			local packet_len = tonumber(len)
			local packet = body:sub(pos + #len + 1, pos + #len + packet_len)
			self:_handle_packet(packet)
			pos = pos + #len + 1 + packet_len
		else
			self:_handle_packet(body:sub(pos))
			break
		end
	end
end

---Handle a single Engine.IO/Socket.IO packet
---@private
---@param packet string raw packet string
function Client:_handle_packet(packet)
	if not packet or packet == "" then
		return
	end

	local engine_type = packet:sub(1, 1)

	if engine_type == "2" then
		-- Engine.IO PING, respond with PONG ("3")
		self:_send_raw("3")
	elseif engine_type == "4" then
		local socket_type = packet:sub(2, 2)
		if socket_type == "2" then
			-- Socket.IO EVENT: 42["event", data]
			local json_str = packet:sub(3)
			local ok, decoded = pcall(vim.json.decode, json_str)
			if ok and type(decoded) == "table" and #decoded >= 1 then
				self:_dispatch_event(decoded[1], decoded[2])
			end
		elseif socket_type == "0" then
			-- Socket.IO CONNECT response
		elseif socket_type == "1" then
			-- Socket.IO DISCONNECT from server
			self.connected = false
		end
	elseif engine_type == "3" then
		-- Engine.IO PONG (ignore)
	end
end

---Dispatch a received event to any registered waiters
---@private
---@param event string
---@param data any
function Client:_dispatch_event(event, data)
	table.insert(self.pending_events, { event = event, data = data })

	local event_waiters = self.waiters[event]
	if event_waiters then
		for _, callback in ipairs(event_waiters) do
			callback(data)
		end
		self.waiters[event] = nil
	end
end

---Wait for a specific event with timeout
---@param event string the event name to wait for
---@param timeout_ms integer? timeout in milliseconds (default 10000)
---@return any? data the event data, or nil on timeout
---@return string? error nil on success, error message on timeout or failure
function Client:wait_for(event, timeout_ms)
	timeout_ms = timeout_ms or 10000

	-- Check already-pending events first
	for i, pending in ipairs(self.pending_events) do
		if pending.event == event then
			table.remove(self.pending_events, i)
			return pending.data, nil
		end
	end

	local result_data = nil
	local result_err = nil
	local done = false
	local deadline = luv.now() + timeout_ms

	self.waiters[event] = self.waiters[event] or {}
	table.insert(self.waiters[event], function(data)
		result_data = data
		done = true
	end)

	while not done and luv.now() < deadline do
		local remaining = deadline - luv.now()
		if remaining <= 0 then
			break
		end

		local poll_timeout = math.min(remaining, 3000)
		local body, _, err = self:_http_get(self:_poll_path(), poll_timeout)
		if err then
			result_err = "poll error while waiting for '" .. event .. "': " .. err
			break
		end

		if body and body ~= "" then
			self:_parse_packets(body)
		end

		if done then
			break
		end
	end

	if not done and self.waiters[event] then
		local waiters = self.waiters[event]
		table.remove(waiters, 1)
		if #waiters == 0 then
			self.waiters[event] = nil
		end
		return nil, result_err or string.format("timed out waiting for event '%s' after %dms", event, timeout_ms)
	end

	return result_data, result_err
end

---Close the Socket.IO connection
function Client:close()
	if not self.connected then
		return
	end

	self:_send_raw("41")
	self.connected = false
	self.sid = nil
	self.cookies = nil
	self.pending_events = {}
	self.waiters = {}
end

---Send a raw Engine.IO packet
---@private
---@param data string raw packet data
function Client:_send_raw(data)
	if not self.connected then
		return
	end
	self:_http_post(self:_poll_path(), data)
end

---Perform an HTTP request using vim.uv TCP (no curl dependency)
---@private
---@param method string "GET" or "POST"
---@param path_query string the path with query string (e.g. "/ws/?EIO=4&...")
---@param body string? request body for POST
---@param timeout_ms integer? timeout in milliseconds (default 5000)
---@return string? response_body
---@return string? response_headers
---@return string? error
function Client:_http_request(method, path_query, body, timeout_ms)
	timeout_ms = timeout_ms or 5000

	local tcp = luv.new_tcp()
	local timer = luv.new_timer()
	local done = false
	local result_body, result_headers, result_err

	-- Build raw HTTP/1.1 request
	local lines = {
		string.format("%s %s HTTP/1.1", method, path_query),
		"Host: " .. self.host .. ":" .. self.port,
		"Content-Type: text/plain;charset=UTF-8",
		"Connection: close",
	}
	if self.cookies then
		table.insert(lines, "Cookie: " .. self.cookies)
	end
	if body then
		table.insert(lines, "Content-Length: " .. #body)
	end
	table.insert(lines, "")
	table.insert(lines, "")
	local raw_request = table.concat(lines, "\r\n")
	if body then
		raw_request = raw_request .. body
	end

	tcp:connect(self.host, self.port, function(connect_err)
		if connect_err then
			result_err = "connect failed: " .. connect_err
			done = true
			return
		end

		tcp:write(raw_request, function(write_err)
			if write_err then
				result_err = "write failed: " .. write_err
				done = true
				return
			end

			local chunks = {}
			tcp:read_start(function(read_err, chunk)
				if read_err then
					result_err = "read failed: " .. read_err
					done = true
					return
				end
				if chunk then
					table.insert(chunks, chunk)
				else
					-- EOF
					local raw = table.concat(chunks)
					result_body, result_headers = Client._split_http_response(raw)
					done = true
				end
			end)
		end)
	end)

	-- Timeout timer
	timer:start(timeout_ms, 0, function()
		if not done then
			result_err = "request timed out after " .. timeout_ms .. "ms"
			done = true
		end
	end)

	-- Spin-wait: process event loop until done or deadline
	local deadline = luv.now() + timeout_ms + 100
	while not done and luv.now() < deadline do
		luv.run("once")
	end

	-- Cleanup
	timer:stop()
	timer:close()
	if not tcp:is_closing() then
		tcp:close()
	end

	return result_body, result_headers, result_err
end

---Split a raw HTTP/1.1 response into headers and body
---@private
---@param raw string raw HTTP response
---@return string? body
---@return string? headers
function Client._split_http_response(raw)
	local headers_end = raw:find("\r\n\r\n", 1, true)
	if not headers_end then
		headers_end = raw:find("\n\n", 1, true)
		if headers_end then
			return raw:sub(headers_end + 2), raw:sub(1, headers_end - 1)
		end
		return raw, nil
	end
	return raw:sub(headers_end + 4), raw:sub(1, headers_end - 1)
end

---HTTP GET
---@private
---@param path_query string
---@param timeout_ms integer?
---@return string? body
---@return string? headers
---@return string? error
function Client:_http_get(path_query, timeout_ms)
	return self:_http_request("GET", path_query, nil, timeout_ms)
end

---HTTP POST
---@private
---@param path_query string
---@param data string
---@return string? body
---@return string? headers
---@return string? error
function Client:_http_post(path_query, data)
	return self:_http_request("POST", path_query, data)
end

return Client
