local api = vim.api
local fn = vim.fn

---@type table<string, system.targets.Target>
local M = {}

local internal = { ns = api.nvim_create_namespace("system.targets") }

M.buf = {
  create_buf = function(_)
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "system_output" then return buf end
    end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, "system://" .. buf .. "/output")
    api.nvim_set_option_value("filetype", "system_output", { buf = buf, scope = "local" })
    api.nvim_set_option_value("buftype", "nowrite", { buf = buf, scope = "local" })
    api.nvim_set_option_value("bufhidden", "hide", { buf = buf, scope = "local" })
    api.nvim_set_option_value("modifiable", false, { buf = buf, scope = "local" })
    return buf
  end,

  open = function(ctx)
    local win_cfg = ctx.__config.win_config[ctx.__config.pos]
    if type(win_cfg) == "function" then win_cfg = win_cfg(ctx) end
    return api.nvim_open_win(ctx.__target_buf, false, win_cfg)
  end,

  write = function(ctx, chunks)
    if ctx.__lines == nil then ctx.__lines = {} end

    local base = (#ctx.__lines > 0) and (#ctx.__lines - 1) or 0
    local lines, extmarks = internal.chunks_to_lines(chunks, base)

    local start
    if #ctx.__lines > 0 then
      ctx.__lines[#ctx.__lines] = ctx.__lines[#ctx.__lines] .. table.remove(lines, 1)
      start = #ctx.__lines - 1
    else
      start = 0
    end

    vim.list_extend(ctx.__lines, lines)
    vim.bo[ctx.__target_buf].modifiable = true
    api.nvim_buf_set_lines(ctx.__target_buf, start, -1, false, vim.list_slice(ctx.__lines, start + 1))
    vim.bo[ctx.__target_buf].modifiable = false

    for _, extmark in ipairs(extmarks) do
      local srow, scol = extmark.row, extmark.start_col
      local opts = { end_col = extmark.end_col, hl_group = extmark.hl_group }
      api.nvim_buf_set_extmark(ctx.__target_buf, internal.ns, srow, scol, opts)
    end
  end,
}

M.echo = {
  write = function(ctx, chunks)
    if ctx.__msgchunks == nil then ctx.__msgchunks = {} end
    vim.list_extend(ctx.__msgchunks, chunks)
    ctx.__msgid = api.nvim_echo(ctx.__msgchunks, false, { id = ctx.__msgid })
  end
}

M.quickfix = {
  create_buf = function(_)
    if fn.getqflist({ qfbufnr = 1 }).qfbufnr == 0 then
      vim._with({ noautocmd = true }, function()
        vim.cmd.copen()
        vim.cmd.close()
        return nil
      end)
    end
    return fn.getqflist({ qfbufnr = 1 }).qfbufnr
  end,

  open = function(_)
    local winid = fn.getqflist({ winid = 1 }).winid
    if winid == 0 then
      vim.cmd("silent copen")
      vim.cmd("wincmd p")
      winid = fn.getqflist({ winid = 1 }).winid
    end
    return winid
  end,

  write = function(ctx, chunks)
    local items = internal.chunks_to_items(ctx, chunks)
    ctx.__items = items
    local context = fn.getqflist({ context = 1 }).context
    -- NOTE: using __start_time as a unique id to tell if
    -- current quickfix/loclist is the result of current context
    local current_list_from_this_cmd = type(context) == "table" and context.__start_time == ctx.__start_time
    local action = current_list_from_this_cmd and "u" or " "
    local title = "System: " .. table.concat(vim.iter(ctx.__cmds):map(function(item) return item.cmd[1] end):totable(), " ➔ ")
    local what = {
      items = ctx.__items,
      context = { __start_time = ctx.__start_time },
      title = title,
      quickfixtextfunc = internal.get_quickfixtextfunc(ctx),
    }
    fn.setqflist({}, action, what)
  end,
}

M.prompt = {
  create_buf = function(ctx)
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, "system://" .. buf .. "/prompt")
    api.nvim_set_option_value("buftype", "prompt", { buf = buf, scope = "local" })
    api.nvim_set_option_value("bufhidden", "hide", { buf = buf, scope = "local" })
    fn.prompt_setprompt(buf, ctx.__config.prompt or "> ")
    fn.prompt_setcallback(buf, function(text)
      local obj = ctx.__system_objs[ctx.__idx]
      if obj then pcall(obj.write, obj, text .. "\n") end
    end)
    return buf
  end,

  open = function(ctx)
    local win_cfg = ctx.__config.win_cfg[ctx.__config.pos]
    if type(win_cfg) == "function" then win_cfg = win_cfg(ctx) end
    local winid = api.nvim_open_win(ctx.__target_buf, true, win_cfg)
    vim.cmd.startinsert()
    return winid
  end,

  write = function(ctx, chunks)
    vim.bo[ctx.__target_buf].modifiable = true
    for _, chunk in ipairs(chunks) do
      fn.prompt_appendbuf(ctx.__target_buf, vim.split(chunk[1], "\n"))
    end
    vim.bo[ctx.__target_buf].modifiable = false
  end,
}

function internal.chunks_to_lines(chunks, start)
  local lines, extmarks = {}, {}
  local start_col = 0
  local offset = start or 0
  local i = 1
  local add_extmark = function(scol, ecol, hl)
    extmarks[#extmarks + 1] = {
      row = i - 1 + offset,
      start_col = scol,
      end_col = ecol,
      hl_group = hl,
    }
  end
  for _, chunk in ipairs(chunks) do
    local text, hl = chunk[1], chunk[2]
    local lines_in_chunk = vim.split(text, "\n")
    -- local lines_in_chunk = text == "\n" and { "" } or vim.split(text, "\n")
    local text_before_newline = lines_in_chunk[1]
    lines[i] = (lines[i] or "") .. text_before_newline
    if hl ~= nil then add_extmark(start_col, start_col + #text_before_newline, hl) end
    start_col = start_col + #text_before_newline
    for j = 2, #lines_in_chunk do
      i = i + 1
      start_col = 0
      local line = lines_in_chunk[j]
      lines[i] = (lines[i] or "") .. line
      if hl ~= nil then add_extmark(start_col, start_col + #line, hl) end
      start_col = start_col + #line
    end
  end
  return lines, extmarks
end

---@param ctx system.ContextObj
---@param chunks system.Chunk[]): vim.quickfix.entry[]
function internal.chunks_to_items(ctx, chunks)
  local lines, extmarks = internal.chunks_to_lines(chunks)

  local items = ctx.__items or {}
  local should_append_previous_items = #items > 1
  local extmark_offset = should_append_previous_items and #items - 1 or 0
  ctx.__extmarks = ctx.__extmarks or {}
  for _, m in ipairs(extmarks) do
    m.row = m.row + extmark_offset
    ctx.__extmarks[#ctx.__extmarks + 1] = m
  end

  -- local parse_item = ctx.__config.parse_item
  local transform_qf_entry = ctx.__config.transform_qf_entry
  local new_items = vim
    .iter(lines)
    :map(function(line)
      if should_append_previous_items then
        local last_item = items[#items]
        last_item.text = last_item.text .. line
        if not last_item.valid then transform_qf_entry(ctx, last_item) end
        should_append_previous_items = false
      else
        local entry = { text = line }
        transform_qf_entry(ctx, entry)
        return entry
      end
    end)
    :totable()

  vim.list_extend(items, new_items)
  return items
end

---@param ctx system.ContextObj
---@return fun(info: table): string[]
function internal.get_quickfixtextfunc(ctx)
  return function(info)
    local qfbufnr
    if info.quickfix == 1 then
      qfbufnr = fn.getqflist({ id = info.id, qfbufnr = 1 }).qfbufnr
    else
      qfbufnr = fn.getloclist(info.winid, { id = info.id, qfbufnr = 1 }).qfbufnr
    end
    assert(qfbufnr, "can't be nil")

    local _lines = vim
      .iter(ctx.__items)
      :map(function(item) return (item.text ~= "" and item.text) or " " end)
      :totable()

    vim.schedule(function()
      api.nvim_buf_call(qfbufnr, function() vim.cmd("syntax clear") end)
      api.nvim_buf_clear_namespace(qfbufnr, internal.ns, 0, -1)
      for _, m in ipairs(ctx.__extmarks) do
        api.nvim_buf_set_extmark(qfbufnr, internal.ns, m.row, m.start_col, {
          end_col = m.end_col, hl_group = m.hl_group,
        })
      end
    end)

    return _lines
  end
end

---@class (exact) system.targets.Target
---@field create_buf? fun(ctx: system.ContextObj): integer
---@field open? fun(ctx: system.ContextObj): integer
---@field write fun(ctx: system.ContextObj, chunks: system.Chunk[])

---@class (exact) system.targets.Extmark
---@field row integer
---@field start_col integer
---@field end_col integer
---@field hl_group string

return M
