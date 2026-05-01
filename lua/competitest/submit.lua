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
		local url = line:match("@url%s+(https?://%S+)")
		if url then
			return url
		end
	end

	return nil
end

---Submit a solution to the cph-ng router via Socket.IO (async)
---@param opts { url: string, source_code: string, port?: integer }
---@param callback fun(success: boolean, err?: string)
function M.submit(opts, callback)
	local SocketIO = require("competitest.socketio")
	local port = opts.port or DEFAULT_PORT
	local client = SocketIO.new({ port = port })

	client:connect(function(err)
		if err then
			client:close()
			callback(false, "failed to connect to router on port " .. port .. ": " .. err)
			return
		end

		client:emit("submit", {
			url = opts.url,
			sourceCode = opts.source_code,
		}, function(emit_err)
			client:close()
			if emit_err then
				callback(false, "failed to emit submit: " .. emit_err)
			else
				callback(true)
			end
		end)
	end)
end

---Handle the `:CompetiTest submit` command (async, non-blocking)
function M.submit_current_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	config.load_buffer_config(bufnr)

	local url = M.find_problem_url(bufnr)
	if not url then
		utils.notify("submit: no problem URL found. Ensure a `.problem.json` exists in the testcases directory or an `@url` comment is present in the source file.")
		return
	end

	local bufcfg = config.get_buffer_config(bufnr)
	local port = bufcfg.cph_ng_port or DEFAULT_PORT

	-- Read source code from buffer lines
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local source_code = table.concat(lines, "\n")

	utils.notify("submitting to " .. url .. " ...", "INFO")

	local function do_submit()
		M.submit({
			url = url,
			source_code = source_code,
			port = port,
		}, function(success, err)
			vim.schedule(function()
				if success then
					utils.notify("solution submitted successfully!", "INFO")
				else
					utils.notify("submit failed: " .. (err or "unknown error"))
				end
			end)
		end)
	end

	-- Auto-start router if configured
	if bufcfg.cph_ng_auto_start_router ~= false then
		local router = require("competitest.router")
		local router_err = router.start(port)
		if router_err then
			utils.notify("submit: " .. router_err)
			return
		end
		-- Wait for router to bind to port, then submit
		vim.defer_fn(do_submit, 500)
	else
		do_submit()
	end
end

return M
