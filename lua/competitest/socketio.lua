local luv = vim.uv and vim.uv or vim.loop

---@class (exact) competitest.SocketIOClient
---@field host string
---@field port integer
---@field path string
---@field sid string?
---@field ping_interval integer
---@field ping_timeout integer
---@field connected boolean
---@field private cookies string?
local Client = {}
Client.__index = Client ---@diagnostic disable-line: inject-field

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
	}
	setmetatable(self, Client)
	return self
end

---Build the polling path with query parameters
---@private
function Client:_poll_path()
	local params = "EIO=4&transport=polling&type=vscode"
	if self.sid then
		params = params .. "&sid=" .. self.sid
	end
	return self.path .. "/?" .. params
end

---Async HTTP request via vim.uv TCP
---@private
---@param method string
---@param path_query string
---@param body string?
---@param timeout_ms integer
---@param callback fun(err: string?, body: string?, headers: string?)
function Client:_http_request(method, path_query, body, timeout_ms, callback)
	local tcp = luv.new_tcp()
	local timer = luv.new_timer()
	local done = false

	local function finish(err, resp_body, resp_headers)
		if done then return end
		done = true
		timer:stop()
		timer:close()
		if not tcp:is_closing() then
			tcp:close()
		end
		vim.schedule(function()
			callback(err, resp_body, resp_headers)
		end)
	end

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
			finish("connect failed: " .. connect_err)
			return
		end

		tcp:write(raw_request, function(write_err)
			if write_err then
				finish("write failed: " .. write_err)
				return
			end

			local chunks = {}
			tcp:read_start(function(read_err, chunk)
				if read_err then
					finish("read failed: " .. read_err)
					return
				end
				if chunk then
					table.insert(chunks, chunk)
				else
					-- EOF
					local raw = table.concat(chunks)
					local resp_body, resp_headers = Client._split_http_response(raw)
					finish(nil, resp_body, resp_headers)
				end
			end)
		end)
	end)

	timer:start(timeout_ms, 0, function()
		finish("request timed out after " .. timeout_ms .. "ms")
	end)
end

---Async Socket.IO handshake
---@param callback fun(err: string?)
function Client:connect(callback)
	if self.connected then
		callback(nil)
		return
	end

	self:_http_request("GET", self:_poll_path(), nil, 5000, function(err, body, headers)
		if err then
			callback("handshake GET failed: " .. err)
			return
		end
		if not body then
			callback("handshake GET returned empty response")
			return
		end

		-- Store cookies
		if headers then
			local set_cookie = headers:match("[Ss]et%-[Cc]ookie:%s*([^\r\n]+)")
			if set_cookie then
				self.cookies = set_cookie:match("^([^;]+)")
			end
		end

		-- Parse Engine.IO OPEN packet: 0{"sid":"...","pingInterval":...,"pingTimeout":...}
		local json_str = body:match("^0(.+)$")
		if not json_str then
			callback("unexpected handshake response: " .. body:sub(1, 200))
			return
		end

		local ok, data = pcall(vim.json.decode, json_str)
		if not ok then
			callback("failed to decode handshake JSON: " .. tostring(data))
			return
		end
		if not data.sid then
			callback("handshake response missing sid")
			return
		end

		self.sid = data.sid
		self.ping_interval = data.pingInterval or 25000
		self.ping_timeout = data.pingTimeout or 20000
		self.connected = true

		-- Send Socket.IO CONNECT packet
		self:_send_raw_async("40", function()
			-- Poll once for CONNECT acknowledgement
			self:_http_request("GET", self:_poll_path(), nil, 3000, function(poll_err, poll_body)
				if poll_err then
					self.connected = false
					callback("CONNECT ack failed: " .. poll_err)
					return
				end
				if poll_body and poll_body ~= "" then
					self:_parse_packets(poll_body)
				end
				if not self.connected then
					callback("server rejected CONNECT")
					return
				end
				callback(nil)
			end)
		end)
	end)
end

---Async emit a Socket.IO event
---@param event string
---@param data any?
---@param callback? fun(err: string?)
function Client:emit(event, data, callback)
	callback = callback or function() end
	if not self.connected then
		callback("not connected")
		return
	end

	local payload = "42" .. vim.json.encode({ event, data })
	self:_http_request("POST", self:_poll_path(), payload, 10000, function(err)
		if err then
			callback("emit failed: " .. err)
		else
			callback(nil)
		end
	end)
end

---Parse Engine.IO/Socket.IO packets from a polling response
---@private
---@param body string
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
---@param packet string
function Client:_handle_packet(packet)
	if not packet or packet == "" then return end

	local engine_type = packet:sub(1, 1)
	if engine_type == "2" then
		-- PING → PONG
		self:_send_raw_async("3")
	elseif engine_type == "4" then
		local socket_type = packet:sub(2, 2)
		if socket_type == "1" then
			self.connected = false
		end
	end
end

---Send a raw Engine.IO packet (async, fire-and-forget)
---@private
---@param data string
---@param callback? fun()
function Client:_send_raw_async(data, callback)
	if not self.connected then
		if callback then callback() end
		return
	end
	self:_http_request("POST", self:_poll_path(), data, 5000, function()
		if callback then callback() end
	end)
end

---Close the connection
function Client:close()
	if not self.connected then return end
	self:_send_raw_async("41")
	self.connected = false
	self.sid = nil
	self.cookies = nil
end

---Split a raw HTTP/1.1 response into headers and body
---@private
---@param raw string
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

return Client
