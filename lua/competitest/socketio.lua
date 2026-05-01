---@class (exact) competitest.SocketIOClient
---@field host string hostname or IP of the cph-ng router
---@field port integer port of the cph-ng router
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
		host = opts.host or "localhost",
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

---Build the base polling URL for Engine.IO
---@private
---@return string
function Client:_polling_url()
	return string.format("http://%s:%d%s/?EIO=4&transport=polling&type=vscode", self.host, self.port, self.path)
end

---Perform the Socket.IO handshake via HTTP polling
---@return string? error # nil on success, error message on failure
function Client:connect()
	if self.connected then
		return nil
	end

	local url = self:_polling_url()
	local body, headers, err = self:_http_get(url, 5000)
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
	local url = self:_polling_url()
	local _, _, err = self:_http_post(url, payload)
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

	local url = self:_polling_url()
	local body, _, err = self:_http_get(url, self.ping_interval + self.ping_timeout)
	if err then
		return "poll failed: " .. err
	end
	if not body or body == "" then
		return nil -- no data, normal for long polling
	end

	-- Parse the response body which may contain multiple packets
	self:_parse_packets(body)

	return nil
end

---Parse Engine.IO/Socket.IO packets from a polling response
---@private
---@param body string raw response body
function Client:_parse_packets(body)
	local pos = 1
	while pos <= #body do
		-- Each packet may be length-prefixed: <length>0<json> or plain: 0<json>
		local len = body:match("^(%d+):", pos)
		-- Only treat as length-prefixed if next char after colon is a digit (packet type)
		if len and body:sub(pos + #len + 1, pos + #len + 1):match("^%d") then
			local packet_len = tonumber(len)
			local packet = body:sub(pos + #len + 1, pos + #len + packet_len)
			self:_handle_packet(packet)
			pos = pos + #len + 1 + packet_len
		else
			-- Single packet, consume rest of body
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
		-- Engine.IO MESSAGE
		local socket_type = packet:sub(2, 2)
		if socket_type == "2" then
			-- Socket.IO EVENT: 42["event", data]
			local json_str = packet:sub(3)
			local ok, decoded = pcall(vim.json.decode, json_str)
			if ok and type(decoded) == "table" and #decoded >= 1 then
				local event = decoded[1]
				local data = decoded[2]
				self:_dispatch_event(event, data)
			end
		elseif socket_type == "0" then
			-- Socket.IO CONNECT response (with auth token etc), just store
		elseif socket_type == "1" then
			-- Socket.IO DISCONNECT from server
			self.connected = false
		end
	elseif engine_type == "3" then
		-- Engine.IO PONG (we don't expect these, but ignore silently)
	end
end

---Dispatch a received event to any registered waiters
---@private
---@param event string
---@param data any
function Client:_dispatch_event(event, data)
	table.insert(self.pending_events, { event = event, data = data })

	-- Wake up any waiters for this event
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

	-- Set up a waiter and poll in a loop
	local result_data = nil
	local result_err = nil
	local done = false
	local deadline = vim.uv.now() + timeout_ms

	self.waiters[event] = self.waiters[event] or {}
	table.insert(self.waiters[event], function(data)
		result_data = data
		done = true
	end)

	while not done and vim.uv.now() < deadline do
		local remaining = deadline - vim.uv.now()
		if remaining <= 0 then
			break
		end

		-- Use a shorter poll timeout so we can check our deadline
		local poll_timeout = math.min(remaining, 3000)

		local url = self:_polling_url()
		local body, _, err = self:_http_get(url, poll_timeout)
		if err then
			result_err = "poll error while waiting for '" .. event .. "': " .. err
			break
		end

		if body and body ~= "" then
			self:_parse_packets(body)
		end

		-- Check if our callback was invoked during parse
		if done then
			break
		end
	end

	-- Clean up waiter if we timed out
	if not done and self.waiters[event] then
		local waiters = self.waiters[event]
		-- Remove the first callback entry (cannot reliably match by identity)
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

	-- Send Engine.IO MESSAGE (4) + Socket.IO DISCONNECT (1) = "41"
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
	local url = self:_polling_url()
	self:_http_post(url, data)
end

---Perform an HTTP GET request using curl
---@private
---@param url string the URL to GET
---@param timeout_ms integer? timeout in milliseconds (default 5000)
---@return string? body response body
---@return string? headers response headers
---@return string? error error message on failure
function Client:_http_get(url, timeout_ms)
	timeout_ms = timeout_ms or 5000
	local timeout_s = math.ceil(timeout_ms / 1000)

	local cmd = { "curl", "--silent", "--show-error", "--max-time", tostring(timeout_s), "--include" }

	if self.cookies then
		table.insert(cmd, "--cookie")
		table.insert(cmd, self.cookies)
	end

	table.insert(cmd, url)

	local result = vim.fn.system(cmd)
	local exit_code = vim.v.shell_error

	if exit_code ~= 0 then
		return nil, nil, "curl GET failed (exit " .. exit_code .. "): " .. (result or "")
	end

	-- Split headers and body (separated by \r\n\r\n)
	local headers_end = result:find("\r\n\r\n", 1, true)
	if not headers_end then
		-- Try \n\n as fallback
		headers_end = result:find("\n\n", 1, true)
		if headers_end then
			local headers = result:sub(1, headers_end - 1)
			local body = result:sub(headers_end + 2)
			return body, headers, nil
		end
		-- No separator found, treat entire response as body
		return result, nil, nil
	end

	local headers = result:sub(1, headers_end - 1)
	local body = result:sub(headers_end + 4)
	return body, headers, nil
end

---Perform an HTTP POST request using curl
---@private
---@param url string the URL to POST to
---@param data string the request body
---@return string? body response body
---@return string? headers response headers
---@return string? error error message on failure
function Client:_http_post(url, data)
	local cmd = { "curl", "--silent", "--show-error", "--max-time", "10", "--include", "--request", "POST" }

	if self.cookies then
		table.insert(cmd, "--cookie")
		table.insert(cmd, self.cookies)
	end

	table.insert(cmd, "--header")
	table.insert(cmd, "Content-Type: text/plain;charset=UTF-8")
	table.insert(cmd, "--data")
	table.insert(cmd, data)
	table.insert(cmd, url)

	local result = vim.fn.system(cmd)
	local exit_code = vim.v.shell_error

	if exit_code ~= 0 then
		return nil, nil, "curl POST failed (exit " .. exit_code .. "): " .. (result or "")
	end

	-- Split headers and body
	local headers_end = result:find("\r\n\r\n", 1, true)
	if not headers_end then
		headers_end = result:find("\n\n", 1, true)
		if headers_end then
			local headers = result:sub(1, headers_end - 1)
			local body = result:sub(headers_end + 2)
			return body, headers, nil
		end
		return result, nil, nil
	end

	local headers = result:sub(1, headers_end - 1)
	local body = result:sub(headers_end + 4)
	return body, headers, nil
end

return Client
