local api = vim.api

api.nvim_create_user_command("System", function(opts)
  require("system.commands").system(opts)
end, {
  nargs = "+",
  desc = "Run a system command asynchonously",
  complete = function(arglead, cmdline, cursorpos)
    return require("system.commands").complete(arglead, cmdline, cursorpos)
  end
})

api.nvim_create_user_command("SystemInput", function(opts)
  require("system.commands").system_input(opts)
end, {
  nargs = "*",
  desc = "Run a system command asynchonously (via input)",
  complete = function(arglead, cmdline, cursorpos)
    return require("system.commands").complete(arglead, cmdline, cursorpos, true)
  end
})

local function create_terminal_hls()
  for i, color in ipairs {
    "SystemBlack",
    "SystemRed",
    "SystemGreen",
    "SystemYellow",
    "SystemBlue",
    "SystemMagenta",
    "SystemCyan",
    "SystemWhite",
    "SystemBrightBlack",
    "SystemBrightRed",
    "SystemBrightGreen",
    "SystemBrightYellow",
    "SystemBrightBlue",
    "SystemBrightMagenta",
    "SystemBrightCyan",
    "SystemBrightWhite",
  } do
    local fg = vim.g["terminal_color_" .. (i - 1)]
    local ctermfg
    if fg == nil then ctermfg = i - 1 end
    api.nvim_set_hl(0, color, { fg = fg, ctermfg = ctermfg, default = true })
    api.nvim_set_hl(0, color .. "Bold", { fg = fg, ctermfg = ctermfg, bold = true, default = true })
  end
end

local augroup = api.nvim_create_augroup("system.nvim-autocmds", { clear = true })

create_terminal_hls()
api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = create_terminal_hls })

local wipe_stale_buffers = vim.schedule_wrap(function()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local buf_name = api.nvim_buf_get_name(buf)
    if buf_name:match("^system://") then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
end)
api.nvim_create_autocmd("SessionLoadPost", { group = augroup, callback = wipe_stale_buffers })
