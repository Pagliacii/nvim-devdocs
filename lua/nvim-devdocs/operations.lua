local M = {}

local job = require("plenary.job")
local curl = require("plenary.curl")
local path = require("plenary.path")

local list = require("nvim-devdocs.list")
local notify = require("nvim-devdocs.notify")
local plugin_config = require("nvim-devdocs.config").get()
local build_docs = require("nvim-devdocs.build")

local devdocs_site_url = "https://devdocs.io"
local devdocs_cdn_url = "https://documents.devdocs.io"
local docs_dir = path:new(plugin_config.dir_path, "docs")
local lock_path = path:new(plugin_config.dir_path, "docs-lock.json")
local registery_path = path:new(plugin_config.dir_path, "registery.json")
local index_path = path:new(plugin_config.dir_path, "index.json")

M.fetch = function()
  notify.log("Fetching DevDocs registery...")

  curl.get(devdocs_site_url .. "/docs.json", {
    headers = {
      ["User-agent"] = "chrome",
    },
    callback = function(response)
      local dir_path = path:new(plugin_config.dir_path)
      local file_path = path:new(plugin_config.dir_path, "registery.json")

      if not dir_path:exists() then dir_path:mkdir() end

      file_path:write(response.body, "w", 438)

      notify.log("DevDocs registery has been written to the disk")
    end,
    on_error = function(error)
      notify.log_err("nvim-devdocs: Error when fetching registery, exit code: " .. error.exit)
    end,
  })
end

M.install = function(entry, verbose, is_update)
  if not registery_path:exists() then
    if verbose then notify.log_err("DevDocs registery not found, please run :DevdocsFetch") end
    return
  end

  local alias = entry.slug:gsub("~", "-")
  local installed = list.get_installed_alias()
  local is_installed = vim.tbl_contains(installed, alias)

  if not is_update and is_installed then
    if verbose then notify.log("Documentation for " .. alias .. " is already installed") end
  else
    local ui = vim.api.nvim_list_uis()

    if ui[1] and entry.db_size > 10000000 then
      local input = vim.fn.input({
        prompt = "Building large docs can freeze neovim, continue? y/n ",
      })

      if input ~= "y" then return end
    end

    local callback = function(index)
      local doc_url = string.format("%s/%s/db.json?%s", devdocs_cdn_url, entry.slug, entry.mtime)

      notify.log("Downloading " .. alias .. " documentation...")
      curl.get(doc_url, {
        callback = vim.schedule_wrap(function(response)
          local docs = vim.fn.json_decode(response.body)
          build_docs(entry, index, docs)
        end),
        on_error = function(error)
          notify.log_err(
            "nvim-devdocs[" .. alias .. "]: Error during download, exit code: " .. error.exit
          )
        end,
      })
    end

    local index_url = string.format("%s/%s/index.json?%s", devdocs_cdn_url, entry.slug, entry.mtime)

    notify.log("Fetching " .. alias .. " documentation entries...")
    curl.get(index_url, {
      callback = vim.schedule_wrap(function(response)
        local index = vim.fn.json_decode(response.body)
        callback(index)
      end),
      on_error = function(error)
        notify.log_err(
          "nvim-devdocs[" .. alias .. "]: Error during download, exit code: " .. error.exit
        )
      end,
    })
  end
end

M.install_args = function(args, verbose, is_update)
  if not registery_path:exists() then
    if verbose then notify.log_err("DevDocs registery not found, please run :DevdocsFetch") end
    return
  end

  local updatable = list.get_updatable()
  local content = registery_path:read()
  local parsed = vim.fn.json_decode(content)

  for _, arg in ipairs(args) do
    local slug = arg:gsub("-", "~")
    local data = {}

    for _, entry in ipairs(parsed) do
      if entry.slug == slug then
        data = entry
        break
      end
    end

    if vim.tbl_isempty(data) then
      notify.log_err("No documentation available for " .. arg)
    else
      if is_update and not vim.tbl_contains(updatable, arg) then
        notify.log(arg .. " documentation is already up to date")
      else
        M.install(data, verbose, is_update)
      end
    end
  end
end

M.uninstall = function(alias)
  local installed = list.get_installed_alias()

  if not vim.tbl_contains(installed, alias) then
    notify.log(alias .. " documentation is already uninstalled")
  else
    local index = vim.fn.json_decode(index_path:read())
    local lockfile = vim.fn.json_decode(lock_path:read())
    local doc_path = path:new(docs_dir, alias)

    index[alias] = nil
    lockfile[alias] = nil

    index_path:write(vim.fn.json_encode(index), "w")
    lock_path:write(vim.fn.json_encode(lockfile), "w")
    doc_path:rm({ recursive = true })

    notify.log(alias .. " documentation has been uninstalled")
  end
end

M.get_entries = function(alias)
  local installed = list.get_installed_alias()
  local is_installed = vim.tbl_contains(installed, alias)

  if not index_path:exists() or not is_installed then return end

  local index_parsed = vim.fn.json_decode(index_path:read())
  local entries = index_parsed[alias].entries

  for key, _ in ipairs(entries) do
    entries[key].alias = alias
  end

  return entries
end

M.get_all_entries = function()
  if not index_path:exists() then return {} end

  local entries = {}
  local index_parsed = vim.fn.json_decode(index_path:read())

  for alias, index in pairs(index_parsed) do
    for _, doc_entry in ipairs(index.entries) do
      local entry = {
        name = string.format("[%s] %s", alias, doc_entry.name),
        alias = alias,
        path = doc_entry.path,
        link = doc_entry.link,
      }
      table.insert(entries, entry)
    end
  end

  return entries
end

M.open = function(entry, bufnr, pattern, float)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

  if not float then
    vim.api.nvim_set_current_buf(bufnr)
  else
    local ui = vim.api.nvim_list_uis()[1]
    local row = (ui.height - plugin_config.float_win.height) * 0.5
    local col = (ui.width - plugin_config.float_win.width) * 0.5
    local float_opts = plugin_config.float_win

    if not plugin_config.row then float_opts.row = row end
    if not plugin_config.col then float_opts.col = col end

    local win = vim.api.nvim_open_win(bufnr, true, float_opts)

    vim.wo[win].wrap = plugin_config.wrap
    vim.wo[win].linebreak = plugin_config.wrap
    vim.wo[win].nu = false
    vim.wo[win].relativenumber = false
  end

  vim.fn.search(pattern)

  local ignore = vim.tbl_contains(plugin_config.cmd_ignore, entry.alias)
  if plugin_config.previewer_cmd and not ignore then
    vim.bo[bufnr].ft = "glow"

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local chan = vim.api.nvim_open_term(bufnr, {})
    local previewer = job:new({
      command = plugin_config.previewer_cmd,
      args = plugin_config.cmd_args,
      on_stdout = vim.schedule_wrap(function(_, data)
        local output_lines = vim.split(data, "\n", {})
        for _, line in ipairs(output_lines) do
          vim.api.nvim_chan_send(chan, line .. "\r\n")
        end
      end),
      on_exit = vim.schedule_wrap(function()
        if pattern then
          local formatted_pattern = pattern:gsub("`", "")
          vim.defer_fn(function() vim.fn.search(formatted_pattern) end, 500)
        end
      end),
      writer = table.concat(lines, "\n"),
    })
    previewer:start()
  else
    vim.bo[bufnr].ft = "markdown"
  end

  local slug = entry.alias:gsub("-", "~")
  local keymaps = plugin_config.mappings
  local set_buf_keymap = function(key, action, description)
    vim.keymap.set("n", key, action, { buffer = bufnr, desc = description })
  end

  if type(keymaps.open_in_browser) == "string" and keymaps.open_in_browser ~= "" then
    set_buf_keymap(
      keymaps.open_in_browser,
      function() vim.ui.open("https://devdocs.io/" .. slug .. "/" .. entry.link) end,
      "Open in the browser"
    )
  end

  plugin_config.after_open(bufnr)
end

return M
