local luv = vim.uv and vim.uv or vim.loop
local utils = require("competitest.utils")
local M = {}

local ROUTER_REPO = "HuaLiMao-AQ/competitest.nvim"
local ROUTER_VERSION = "v1.0.0"

---Determine the binary filename for the current platform
---@return string? binary_name
---@return string? error if platform is unsupported
function M._binary_name()
	local sysname = luv.os_uname().sysname
	local machine = luv.os_uname().machine

	local go_os
	if sysname == "Linux" then
		go_os = "linux"
	elseif sysname == "Darwin" then
		go_os = "darwin"
	elseif sysname == "Windows_NT" then
		go_os = "windows"
	else
		return nil, "unsupported OS: " .. sysname
	end

	local go_arch
	if machine == "x86_64" or machine == "amd64" then
		go_arch = "amd64"
	elseif machine == "arm64" or machine == "aarch64" then
		go_arch = "arm64"
	else
		return nil, "unsupported architecture: " .. machine
	end

	local suffix = go_os == "windows" and ".exe" or ""
	return "competitest-router-" .. go_os .. "-" .. go_arch .. suffix, nil
end

---Get the local path where the binary is stored
---@return string? path
function M._binary_path()
	local data_dir = vim.fn.stdpath("data") .. "/competitest"
	utils.create_directory(data_dir)
	local name, err = M._binary_name()
	if err then
		return nil
	end
	return data_dir .. "/" .. name
end

---Check if the binary exists locally and is executable
---@return boolean
function M.is_installed()
	local path = M._binary_path()
	if not path or not utils.does_file_exist(path) then
		return false
	end
	-- On Unix, verify execute permission
	if luv.os_uname().sysname ~= "Windows_NT" then
		local stat = luv.fs_stat(path)
		if stat then
			local mode = stat.mode % 512 -- extract permission bits (lower 9 bits)
			-- Check owner execute bit (0100 = 64)
			if mode % 128 < 64 then
				return false
			end
		end
	end
	return true
end

---Download the binary from GitHub releases
---@return string? error nil on success
function M.download()
	local dest = M._binary_path()
	if not dest then
		return "cannot determine binary path"
	end

	local name = M._binary_name()
	if not name then
		return "cannot determine binary name"
	end

	local url = string.format(
		"https://github.com/%s/releases/download/%s/%s",
		ROUTER_REPO,
		ROUTER_VERSION,
		name
	)

	-- Try curl first, then wget
	local downloaders = {
		{ "curl", { "curl", "-fsSL", "-o", dest, url } },
		{ "wget", { "wget", "-q", "-O", dest, url } },
	}

	local downloaded = false
	for _, dl in ipairs(downloaders) do
		local tool = dl[1]
		local cmd = dl[2]
		-- Check if tool is available
		if vim.fn.executable(tool) == 1 then
			local result = vim.fn.system(cmd)
			if vim.v.shell_error == 0 then
				downloaded = true
				break
			else
				utils.notify("router download failed with " .. tool .. ": " .. (result or ""), "WARN")
			end
		end
	end

	if not downloaded then
		return "neither curl nor wget available. Install one or download the router binary manually from:\n"
			.. url
			.. "\nand place it at: " .. dest
	end

	-- Make executable on Unix
	if luv.os_uname().sysname ~= "Windows_NT" then
		luv.fs_chmod(dest, 493) -- 0755
	end

	return nil
end

---Ensure the binary is available (download if needed)
---@return string? error nil if ready
function M.ensure_installed()
	if M.is_installed() then
		return nil
	end
	utils.notify("downloading cph-ng router binary...", "INFO")
	return M.download()
end

---@type uv.uv_process_t?
M._handle = nil

---Start the router process
---@param port integer
---@return string? error nil on success
function M.start(port)
	if M._handle then
		return nil
	end

	local router_path = require("competitest.config").current_setup.cph_ng_router_path
	if not router_path then
		local err = M.ensure_installed()
		if err then
			return err
		end
		router_path = M._binary_path()
	end

	if not router_path or not utils.does_file_exist(router_path) then
		return "router binary not found at: " .. tostring(router_path)
	end

	-- Ensure execute permission before spawning
	if luv.os_uname().sysname ~= "Windows_NT" then
		luv.fs_chmod(router_path, 493) -- 0755
	end

	local handle, pid = luv.spawn(router_path, {
		args = { "--port", tostring(port) },
		stdio = { nil, nil, nil },
	}, function(code, signal)
		M._handle = nil
	end)

	if not handle then
		return "failed to start router: " .. (pid or "unknown error")
	end

	M._handle = handle

	-- Auto-kill router when Neovim exits
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("CompetiTestRouterCleanup", { clear = true }),
		callback = function()
			M.stop()
		end,
	})

	return nil
end

---Stop the router process
function M.stop()
	if M._handle then
		M._handle:kill("sigterm")
		M._handle = nil
	end
end

return M
