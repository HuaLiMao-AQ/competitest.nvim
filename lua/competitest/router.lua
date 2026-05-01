local luv = vim.uv and vim.uv or vim.loop
local utils = require("competitest.utils")
local M = {}

local ROUTER_REPO = "HuaLiMao-AQ/competitest.nvim"

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

---Fetch the latest release tag from GitHub API
---@return string? tag e.g. "v1.0.0"
---@return string? error
function M._fetch_latest_tag()
	local api_url = string.format("https://api.github.com/repos/%s/releases/latest", ROUTER_REPO)

	-- Try curl → wget → python3
	local fetchers = {
		{ "curl", { "curl", "-fsSL", api_url } },
		{ "wget", { "wget", "-qO-", api_url } },
	}

	for _, f in ipairs(fetchers) do
		if vim.fn.executable(f[1]) == 1 then
			local result = vim.fn.system(f[2])
			if vim.v.shell_error == 0 and result and result ~= "" then
				local ok, data = pcall(vim.json.decode, result)
				if ok and data and data.tag_name then
					return data.tag_name, nil
				end
			end
		end
	end

	-- Fallback: use git ls-remote to get latest tag
	if vim.fn.executable("git") == 1 then
		local result = vim.fn.system({ "git", "ls-remote", "--tags", "--sort=-v:refname",
			"https://github.com/" .. ROUTER_REPO, "v*" })
		if vim.v.shell_error == 0 and result and result ~= "" then
			-- First line is the latest tag, format: <sha>\trefs/tags/v1.0.0
			local tag = result:match("refs/tags/(v[%d%.]+)$")
			if tag then
				return tag, nil
			end
			-- May have ^{} suffix for annotated tags
			tag = result:match("refs/tags/(v[%d%.]+)%^{}")
			if tag then
				return tag, nil
			end
		end
	end

	return nil, "cannot determine latest release tag"
end

---Run a shell command, return stdout
---@param cmd string[]
---@return string? stdout
---@return integer exit_code
function M._run(cmd)
	local result = vim.fn.system(cmd)
	return result, vim.v.shell_error
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

	-- Fetch latest release tag
	local version, tag_err = M._fetch_latest_tag()
	if not version then
		return "failed to get latest release version: " .. (tag_err or "unknown")
	end

	local url = string.format(
		"https://github.com/%s/releases/download/%s/%s",
		ROUTER_REPO, version, name
	)

	local downloaded = false

	-- 1. curl
	if not downloaded and vim.fn.executable("curl") == 1 then
		local _, code = M._run({ "curl", "-fsSL", "-o", dest, url })
		if code == 0 then downloaded = true end
	end

	-- 2. wget
	if not downloaded and vim.fn.executable("wget") == 1 then
		local _, code = M._run({ "wget", "-q", "-O", dest, url })
		if code == 0 then downloaded = true end
	end

	-- 3. python3 / python
	for _, py in ipairs({ "python3", "python" }) do
		if not downloaded and vim.fn.executable(py) == 1 then
			local _, code = M._run({
				py, "-c",
				string.format("import urllib.request; urllib.request.urlretrieve(%q, %q)", url, dest),
			})
			if code == 0 then downloaded = true end
		end
	end

	if not downloaded then
		return "no download tool available (curl/wget/python3).\n"
			.. "Download manually from: " .. url .. "\nplace at: " .. dest
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
