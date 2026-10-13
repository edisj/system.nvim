local M = {}

---@type table<string, system.Config>
M.configurations = {}

---@type table<string, system.targets.Target>
M.targets = require("system.targets")

---@param ... system.CommandSpec
---@return system.ContextObj? ctx, string? err
function M.system(...)
  return require("system.system").system(...)
end

---@param opts system.ConfigPartial
---@param ... system.CommandSpec
---@return system.ContextObj? ctx, string? err
function M.system_with(opts, ...)
  return require("system.system").system_with(opts, ...)
end

---@param opts system.InputOpts
function M.input(opts)
  require("system.commands").input(opts)
end

return M
