local fn = vim.fn
local ts = vim.treesitter

local internal = {}

local M = {}

---Implementation for `:System` user command.
---@param opts vim.api.keyset.create_user_command.command_args
function M.system(opts)
  local kwargs, args = internal.parse_args(opts.args:gsub("%s+", " "))
  local cmds = internal.parse_input(args)
  require("system").system_with(kwargs, cmds)
end

---Implementation for `:SystemInput` user command.
---@param opts vim.api.keyset.create_user_command.command_args
function M.system_input(opts)
  local kwargs, args = internal.parse_args(opts.args:gsub("%s+", " "))
  if not args:match("^%s*$") then
    return vim.notify("SystemInput: unexpected argument: " .. args, vim.log.levels.ERROR)
  end
  M.input(kwargs)
end

local last_cmd = { input = nil, pos = nil, target = nil }

---Read input and run as a system command.
---@opts system.InputOpts
function M.input(opts)
  opts = opts or {}
  local target = opts.target or opts.repeat_last and last_cmd.target or nil
  local pos = opts.pos or opts.repeat_last and last_cmd.pos or nil
  local icon = ({
    left = "  ",
    right = "  ",
    top = "  ",
    bot = "  ",
    current = " · ",
    float = "  ",
  })[pos] or ""
  local prompt = ("%sSystem command: "):format(icon)

  vim.cmd("echohl Question")
  local ok, input = pcall(fn.input, {
    prompt = prompt,
    completion = "customlist,v:lua.require'system.commands'.customlist",
    default = opts.repeat_last and last_cmd.input or nil,
    cancelreturn = vim.NIL,
  })
  vim.cmd("echohl None")
  if not ok or input == vim.NIL or vim.trim(input) == "" then return end

  last_cmd = { input = input, pos = pos, target = target }
  require("system").system_with({ pos = pos, target = target }, internal.parse_input(input))
end


---@param arglead string the word currently being typed
---@param cmdline string the whole command line
---@param cursorpos integer where the cursor is in cmdline
---@param kwargs_only boolean true for :SystemInput
function M.complete(arglead, cmdline, cursorpos, kwargs_only)
  local cmdline_args = cmdline:match("System%a*!?%s*(.*)$") or cmdline
  local arglead_complement = cmdline_args:sub(1, #cmdline_args - #arglead)
  local kwargs, args = internal.parse_args(arglead_complement)

  local remaining_kwargs = internal.get_valid_kwargs()
  for k in pairs(kwargs) do
    remaining_kwargs[k] = nil
  end

  local k, equal, v = arglead:match("^([^=]+)(=?)(.*)$")
  local candidates

  if equal == "=" then
    local values = remaining_kwargs[k]
    if type(values) == "function" then values = values(v) end
    candidates = vim
      .iter(values or {})
      :filter(function(val) return vim.startswith(val, v) end)
      :map(function(val) return k .. "=" .. val end)
      :totable()
  elseif not args or args:match("^%s*$") then
    candidates = vim
      .iter(remaining_kwargs)
      :filter(function(kwarg) return vim.startswith(kwarg, k or "") end)
      :map(function(kwarg) return kwarg .. "=" end)
      :totable()
  end
  if #candidates > 0 then return candidates end

  if kwargs_only then return {} end
  local cwd = kwargs.cwd and fn.isdirectory(kwargs.cwd) == 1 and kwargs.cwd or nil
  return M.customlist(arglead, args, cursorpos - (#cmdline - #args), cwd)
end

local function merge(lead, abbr)
  if not lead then return "" end
  for k = math.min(#lead, #abbr), 1, -1 do
    if lead:sub(-k) == abbr:sub(1, k) then
      return lead:sub(1, #lead - k) .. abbr
    end
  end
  return lead .. abbr
end

local HAS_FISH = vim.fn.executable("fish") == 1
local cache = {}

function M.customlist(arglead, cmdline, _, cwd)
  local key = cmdline .. "\0" .. (cwd or "")
  if cache[key] then return cache[key] end

  if not HAS_FISH then
    local candidates = vim.fn.getcompletion(cmdline, "shellcmdline")
    cache[key] = candidates
    return candidates
  end

  local cmd = { "fish", "-c", "complete -C " .. vim.fn.shellescape(cmdline) }
  local result = vim.system(cmd, { cwd = cwd }):wait()
  if result.code ~= 0 then return end

  local items = vim.split(result.stdout, "\n")
  local candidates = {}
  for _, item in ipairs(items) do
    local abbr, menu = unpack(vim.split(item, "\t"))
    if abbr and abbr ~= "" then
      candidates[#candidates + 1 ] = { word = merge(arglead, abbr), abbr = abbr, menu = menu }
    end
  end
  cache[key] = candidates
  return candidates
end

---Parses something like `"x=a b=y some text"` and returns:
---```lua
---  kwargs = { x = 'a', b = 'y' }
---  args = 'some text'
---```
---
---@param args string
---@return table<string, string>
---@return string
function internal.parse_args(args)
  local kwargs = {}
  while true do
    local k, v, tail = args:match("^%s*(%w+)=(%S+)%s*(.*)$")
    if not k then break end
    if not (k and internal.get_valid_kwargs()[k]) then break end
    kwargs[k] = v
    args = tail
  end
  if kwargs.cwd then
    local ok, expanded = pcall(fn.expandcmd, kwargs.cwd)
    kwargs.cwd = ok and expanded or kwargs.cwd
  end
  return kwargs, args
end

---@param input string
---@return string[]
function internal.parse_input(input)
  input = vim.trim(input)
  if internal.needs_shell(input) then
    return { vim.g.system_shell or vim.o.shell or "bash", "-c", internal.expand(input) }
  end
  local cmd = {}
  for _, word in ipairs(vim.split(input, " ", { trimempty = true })) do
    cmd[#cmd + 1] = internal.expand(word)
  end
  return cmd
end

local SHELL_NODES = [[
[(pipeline) (list) (redirected_statement) (file_redirect) (heredoc_redirect)
 (command_substitution) (process_substitution) (simple_expansion) (expansion)
 (arithmetic_expansion) (string) (raw_string) (concatenation) (subshell)
 (compound_statement) (variable_assignment) (function_definition) (test_command)
 (negated_command) (ERROR)] @shell
]]

---Whether input needs to be shell'd out or not.
---@param input string
---@return boolean
function internal.needs_shell(input)
  -- any input with special characters *, ?, [, \ is shell'd out
  if input:find("[%*%?%[\\]") then return true end

  -- NOTE: This function was generated with Claude Opus 5.
  -- I haven't fully tested it, but the idea is that if an input contains special
  -- shell behaviors like piping, &&, ||, etc., it should be shell'd out, so
  -- the command is prefixed with "bash -c". Another idea is to fully implement
  -- a parser to build some sort of AST that can be used to build the chain of system(...)
  -- commands, but that seems unnecessary since the shell is already a perfectly good tool
  -- for parsing shell commands...
  local shell_query = ts.query.parse("bash", SHELL_NODES)
  local root = ts.get_string_parser(input, "bash"):parse()[1]:root()
  if root:has_error() then return true end
  for _ in shell_query:iter_captures(root, input) do return true end
  local statements = 0
  for child in root:iter_children() do
    if child:named() then statements = statements + 1 end
  end
  return statements ~= 1
end

---Expand special vim chars like %
---@param input string
---@return string
function internal.expand(input)
  -- NOTE: important to double up \ characters first because expand() consumes one.
  local ok, expanded = pcall(fn.expandcmd, (input:gsub("\\", "\\\\")))
  return ok and expanded or input
end

---@return { target: string[], pos: string[], cwd: string[] }
function internal.get_valid_kwargs()
  return {
    target = vim.tbl_keys(require("system.targets")),
    pos = { "left", "right", "top", "bot", "float", "current" },
    cwd = function(value) return fn.getcompletion(value, "dir") end,
  }
end

---@class system.InputOpts
---@field target? string
---@field pos? string
---@field repeat_last? boolean

return M
