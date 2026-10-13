local api = vim.api
local fn = vim.fn
local uv = vim.uv
local fs = vim.fs
local AnsiParser = require("system.ansi_parser")

---@type system.ConfigPartial
local DEFAULT_CONFIG = {
  target = "buf",
  pos = "bot",
  prompt = "> ",
  win_config = {
    left = { split = "left", win = -1 },
    right = { split = "right", win = -1 },
    top = function(ctx)
      local max_height = math.floor(0.5 * vim.o.lines)
      local height = math.min(max_height, api.nvim_buf_line_count(ctx.__target_buf))
      return { split = "above", win = -1, height = height }
    end,
    bot = function(ctx)
      local max_height = math.floor(0.5 * vim.o.lines)
      local height = math.min(max_height, api.nvim_buf_line_count(ctx.__target_buf))
      return { split = "below", win = -1, height = height }
    end,
    float = function(_)
      local width = math.floor(0.75 * vim.o.columns)
      local height = math.floor(0.75 * vim.o.lines)
      local row = math.floor(0.5 * (vim.o.lines - height))
      local col = math.floor(0.5 * (vim.o.columns - width))
      local win_cfg = { relative = "editor", row = row, col = col, width = width, height = height }
      return win_cfg
    end,
  },
  transform_qf_entry = function(ctx, entry)
    for filename, lnum, col in entry.text:gmatch("([^%s:]+):(%d+):?(%d*)") do
      local path = filename:sub(1,1) == "/" and filename or fs.joinpath(ctx.__cwd, filename)
      local stat = uv.fs_stat(path)
      if lnum and stat and stat.type == "file" then
        entry.filename = path
        entry.lnum = tonumber(lnum)
        entry.col = col ~= "" and tonumber(col) or 0
        entry.valid = entry.filename ~= nil
        return entry
      end
    end
  end,
}

local internal = {}

local M = { default_handlers = {} }

---@param ... system.Command | system.CommandSpec
---@return system.ContextObj?
function M.system(...)
  if select("#", ...) == 0 then return end
  return M._system({}, nil, ...)
end

---@param opts system.ConfigPartial
---@param ... system.Command | system.CommandSpec
---@return system.ContextObj?
function M.system_with(opts, ...)
  if select("#", ...) == 0 then return end
  return M._system({}, opts, ...)
end

---@param arg system.Command | system.CommandSpec
---@return system.CommandSpec
local function normalize_arg(arg)
  if type(arg) == "string" then return { cmd = vim.split(arg, " ") } end
  assert(type(arg) == "table")
  return vim.islist(arg) and { cmd = arg } or arg
end

---@param ctx system.ContextObj
---@param spec system.CommandSpec
---@return string[]
local function resolve_cmd(ctx, spec)
  local cmd = spec.cmd
  if type(cmd) == "function" then cmd = cmd(ctx) end
  return type(cmd) == "string" and vim.split(cmd, " ") or cmd
end

---@param opts? system.Config
---@param ... system.Command | system.CommandSpec
---@return system.ContextObj? ctx, string? err
function M._system(ctx, opts, ...)
  opts = opts or {}

  if ctx.__cmds == nil then
    ctx.__system_objs = {}
    ctx.__out = {}
    ctx.__err = {}
    ctx.__idx = 0
    ctx.__cmds = vim.iter({ ... }):map(normalize_arg):totable()
  end

  ctx.__idx = ctx.__idx + 1
  local spec = ctx.__cmds[ctx.__idx]
  if spec == nil then return end
  ctx.__cmd = resolve_cmd(ctx, spec)
  local cmd = ctx.__cmd

  local no_op_stub = function() end
  local handlers = vim.tbl_deep_extend("force", M.default_handlers, {
    stdin  = spec.stdin  == false and no_op_stub or spec.stdin,
    stdout = spec.stdout == false and no_op_stub or spec.stdout,
    stderr = spec.stderr == false and no_op_stub or spec.stderr,
    before = spec.before == false and no_op_stub or spec.before,
    after  = spec.after  == false and no_op_stub or spec.after,
    exit   = spec.exit   == false and no_op_stub or spec.exit,
  })

  if ctx.__config == nil then
    local prog = ctx.__cmd[1]
    local prog_config = require("system").configurations[prog]
    ctx.__config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, vim.g.system or {}, prog_config or {}, opts)
  end

  if ctx.__config.target == "loclist" and not ctx.__loclist_parent then
    ctx.__loclist_parent = api.nvim_get_current_win()
  end

  if not ctx.__cwd then
    ctx.__cwd = opts.cwd or fn.getcwd()
  end

  handlers.before(ctx)

  local on_exit = function(result)
    ctx.__end_time = uv.hrtime()
    ctx.__end_times = ctx.__end_times or {}
    ctx.__end_times[#ctx.__end_times + 1] = ctx.__end_time

    handlers.exit(ctx, result)
    handlers.after(ctx, result)
    if result.code == 0 and ctx.__idx < #ctx.__cmds then
      M._system(ctx, nil)
    end
  end

  ctx.__start_time = ctx.__start_time or uv.hrtime()
  ctx.__start_times = ctx.__start_times or {}
  ctx.__start_times[#ctx.__start_times + 1] = ctx.__start_time
  local ok, ret = pcall(vim.system, cmd, {
    cwd = ctx.__cwd,
    text = true,
    stdin = handlers.stdin(ctx),
    stdout = function(...) handlers.stdout(ctx, ...) end,
    stderr = function(...) handlers.stderr(ctx, ...) end,
  }, on_exit)
  if ok then
    ctx.__system_objs[ctx.__idx] = ret
    return ctx
  else
    local err = tostring(ret)
    internal.send_chunks_to_target(ctx, { { err, "DiagnosticError" } })
    return nil, err
  end
end

---@param ctx system.ContextObj
---@return string | string[] | boolean | nil
---@diagnostic disable-next-line: unused-local
function M.default_handlers.stdin(ctx)
  if ctx.__config.target == "prompt" then return true end
  return nil
end

---@param ctx system.ContextObj
---@param stream "stdout" | "stderr"
---@param data string
---@return system.Chunk[]
local function data_to_chunks(ctx, stream, data)
  if ctx.__parsers == nil then ctx.__parsers = {} end
  ctx.__parsers[stream] = ctx.__parsers[stream] or AnsiParser()
  data = data:gsub("\r\n", "\n")
  local chunks = ctx.__parsers[stream]:parse(data)
  return chunks or {{ data }}
end

---@param ctx system.ContextObj
---@param err string?
---@param data string?
function M.default_handlers.stdout(ctx, err, data)
  if err then return vim.schedule(function() vim.notify(err) end) end
  if data == nil then return end
  local chunks = data_to_chunks(ctx, "stdout", data)
  internal.send_chunks_to_target(ctx, chunks)
end

---@param ctx system.ContextObj
---@param err string?
---@param data string?
function M.default_handlers.stderr(ctx, err, data)
  if err then return vim.schedule(function() vim.notify(err) end) end
  if data == nil then return end
  local chunks = data_to_chunks(ctx, "stderr", data)
  internal.send_chunks_to_target(ctx, chunks)
end

---@param ctx system.ContextObj
---@param result vim.SystemCompleted
---@diagnostic disable-next-line: unused-local
function M.default_handlers.exit(ctx, result)
  if ctx.__config.target == "prompt" then
    vim.schedule(function()
      fn.prompt_setcallback(ctx.__target_buf, "")
      vim.bo[ctx.__target_buf].modifiable = false
    end)
  end
  return nil
end

---@param ctx system.ContextObj
function M.default_handlers.before(ctx)
  local chunks = {}
  if ctx.__idx == 1 then
    local timestamp = os.date("%a %d %H:%M:%S", uv.gettimeofday())
    local header = {
      { "System" },
      { "[", "@punctuation.bracket" },
      { "]", "@punctuation.bracket" },
      { " started at " },
      { timestamp, "Comment" },
    }
    vim.list_extend(chunks, header)
    for i = #ctx.__cmds, 1, -1 do
      local cmd = ctx.__cmds[i].cmd
      local prog = type(cmd) == "function" and "?"
                or type(cmd) == "string" and vim.split(cmd, " ")[1]
                or cmd[1]
      table.insert(chunks, 3, { prog, "Function" })
      if i > 1 then
        table.insert(chunks, 3, { " ➔ " })
      end
    end
    table.insert(chunks, { "\n" })
  end

  table.insert(chunks, { "\n" .. table.concat(ctx.__cmd, " ") .. "\n", "Comment" })
  internal.send_chunks_to_target(ctx, chunks)
end

---@param ctx system.ContextObj
---@param result vim.SystemCompleted
function M.default_handlers.after(ctx, result)
  if ctx.__idx ~= #ctx.__cmds and result.code == 0 then
    return
  end
  local elapsed_s = (ctx.__end_time - ctx.__start_time) / 1e9
  local time_formatted = elapsed_s < 1 and ("%.2fms"):format(elapsed_s * 1000) or ("%.2fs"):format(elapsed_s)
  local chunks =  { { "\n" } }
  vim.list_extend(chunks, {
    result.code == 0 and { "finished ", "DiagnosticOk" } or { "exited ", "DiagnosticError" },
    { ("in %s with code " ):format(time_formatted) },
    { tostring(result.code), "Number" },
  })
  internal.send_chunks_to_target(ctx, chunks)
end

---@param ctx system.ContextObj
---@param chunks system.Chunk[]
internal.send_chunks_to_target = vim.schedule_wrap(function(ctx, chunks)
  local target = require("system.targets")[ctx.__config.target]
  if not target.create_buf then return target.write(ctx, chunks) end

  ctx.__target_buf = ctx.__target_buf or target.create_buf(ctx)
  target.write(ctx, chunks)

  local winid = internal.open_target(ctx, ctx.__target_buf, target.open)
  if not winid then return end
  vim.wo[winid].statusline = ""
  if ctx.__config.pos ~= "float" then vim.wo[winid].winhl = "" end
end)

---@param ctx system.ContextObj
---@param bufnr integer
---@param open? fun(ctx: system.ContextObj): integer): integer?
---@return integer?
function internal.open_target(ctx, bufnr, open)
  if ctx.__target_win then
    if
      not api.nvim_win_is_valid(ctx.__target_win)
      or api.nvim_win_get_buf(ctx.__target_win) ~= bufnr
    then
      return nil
    end
    local win_cfg = ctx.__config.win_config[ctx.__config.pos]
    if type(win_cfg) == "function" then win_cfg = win_cfg(ctx) end
    if win_cfg then pcall(api.nvim_win_set_config, ctx.__target_win, win_cfg) end
    return ctx.__target_win
  end
  if ctx.__config.pos == "current" then
    local win = api.nvim_get_current_win()
    ctx.__target_win = pcall(api.nvim_win_set_buf, win, bufnr) and win or -1
  else
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == bufnr then
        ctx.__target_win = win
        break
      end
    end
    ctx.__target_win = ctx.__target_win or (open and open(ctx)) or -1
  end
  return api.nvim_win_is_valid(ctx.__target_win) and ctx.__target_win or nil
end

---@alias system.Command string | string[]

---@alias system.Chunk [string, integer|string?] A `[text, hl_group]` pair,
---where `text` is a string highlighted by the (optional) name or ID `hl_group`.

---@class system.CommandSpec
---@field cmd string[]
---@field stdin? fun()
---@field stdout? fun()
---@field stderr? fun()
---@field exit? fun()
---@field before? fun()
---@field after? fun()

---@class (exact) system.ConfigPartial: system.Config
---@field target? string Key into `M.targets`.
---@field pos? "left" | "right" | "top" | "bot" | "float" | "current"
---@field cwd? string
---@field win_config? table
---@field parse_item? fun(ctx: system.ContextObj, item: vim.quickfix.entry): vim.quickfix.entry?

---@class (exact) system.Config
---@field target string Key into `M.targets`.
---@field pos "left" | "right" | "top" | "bot" | "float" | "current"
---@field cwd string
---@field win_config table
---@field parse_item fun(ctx: system.ContextObj, item: vim.quickfix.entry): vim.quickfix.entry?

---@class system.ContextObj
---@field __cmd? string[] current command being executed, already resolved
---@field __cmds? system.CommandSpec[] list of all commands to be executed
---@field __idx? integer index of current command in sequence
---@field __config? system.Config settings for this run, resolved once
---@field __cwd? string
---@field __system_objs? table<integer, vim.SystemObj> one per command in the chain
---@field __out? string[] raw stdout accumulated per command
---@field __err? string[] raw stderr accumulated per command
---@field __parsers? table<string, table> ansi parser per stream, kept across chunks
---@field __target_buf? integer buffer holding the output, resolved once per run
---@field __target_win? integer window showing `__target_buf`, placed once; `-1` when placing failed
---@field __loclist_parent? integer window owning the location list
---@field __items? vim.quickfix.entry[] quickfix/loclist entries built so far
---@field __extmarks? system.targets.Extmark[] highlights for `__items`
---@field __lines? string[] buf target's accumulated lines
---@field __msgchunks? system.Chunk[] echo target's accumulated chunks
---@field __msgid? integer|string echo target's message id
---@field __start_time? integer vim.uv.hrtime when first command was executed
---@field __start_times? integer[] start time for each command
---@field __end_time? integer vim.uv.hrtime when current command exited
---@field __end_times? integer[] end time for each command
---@field [any] any arbitrary user data to be passed through callbacks

return M
