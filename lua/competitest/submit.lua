local utils = require("competitest.utils")
local config = require("competitest.config")
local M = {}

local DEFAULT_PORT = 27121

---Find the stored problem URL for a buffer
---Checks for `.problem.json` in the testcases directory, then falls back to
---scanning for an `@url` metadata comment in the source file (single-file mode).
---@param bufnr integer buffer number
---@return string? # URL string, or `nil` if not found
function M.find_problem_url(bufnr)
	local bufcfg = config.get_buffer_config(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		return nil
	end

	-- Resolve testcases directory the same way testcases.lua does
	local evaluated_dir = utils.eval_string(filepath, bufcfg.testcases_directory)
	if not evaluated_dir then
		evaluated_dir = bufcfg.testcases_directory
	end
	local file_directory = vim.fn.fnamemodify(filepath, ":p:h")
	local tcdir = file_directory .. "/" .. evaluated_dir .. "/"

	-- 1. Check for .problem.json in the testcases directory
	local problem_json_path = tcdir .. ".problem.json"
	if utils.does_file_exist(problem_json_path) then
		local content = utils.load_file_as_string(problem_json_path)
		if content then
			local ok, data = pcall(vim.json.decode, content)
			if ok and type(data) == "table" and data.url then
				return data.url
			end
		end
	end

	-- 2. Check for @url metadata comment in the source file (single-file / cph-ng style)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for _, line in ipairs(lines) do
		-- Match patterns like: // @url https://codeforces.com/... or # @url https://...
		local url = line:match("@url%s+(https?://%S+)")
		if url then
			return url
		end
	end

	return nil
end

---Submit a solution to the cph-ng router via Socket.IO
---@param opts { url: string, source_code: string, port?: integer }
---@return boolean success whether the submission was accepted
---@return string? error error message on failure
function M.submit(opts)
	local SocketIO = require("competitest.socketio")
	local port = opts.port or DEFAULT_PORT

	local client = SocketIO.new({ port = port })

	local err = client:connect()
	if err then
		client:close()
		return false, "failed to connect to cph-ng router on port " .. port .. ": " .. err
	end

	-- Emit submit event
	err = client:emit("submit", {
		url = opts.url,
		sourceCode = opts.source_code,
	})
	if err then
		client:close()
		return false, "failed to emit submit event: " .. err
	end

	-- Wait for the server's acknowledgement
	-- cph-ng may respond with either "submitDone" or "submitResult"
	local data, wait_err = client:wait_for("submitDone", 30000)
	if wait_err then
		-- Try alternate event name
		data, wait_err = client:wait_for("submitResult", 30000)
		if wait_err then
			client:close()
			return false, "timed out waiting for submission response: " .. wait_err
		end
	end

	client:close()

	-- Check response for errors
	if data and type(data) == "table" and data.error then
		return false, "submission rejected: " .. tostring(data.error)
	end

	return true, nil
end

---Handle the `:CompetiTest submit` command
---Reads the current buffer, resolves the problem URL, and submits via cph-ng
function M.submit_current_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	config.load_buffer_config(bufnr)

	local url = M.find_problem_url(bufnr)
	if not url then
		utils.notify("submit: no problem URL found. Ensure a `.problem.json` exists in the testcases directory or an `@url` comment is present in the source file.")
		return
	end

	-- Read source code from buffer lines
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local source_code = table.concat(lines, "\n")

	utils.notify("submitting to " .. url .. " ...", "INFO")

	local bufcfg = config.get_buffer_config(bufnr)
	local success, err = M.submit({
		url = url,
		source_code = source_code,
		port = bufcfg.companion_port,
	})

	if success then
		utils.notify("solution submitted successfully!", "INFO")
	else
		utils.notify("submit failed: " .. (err or "unknown error"))
	end
end

return M
