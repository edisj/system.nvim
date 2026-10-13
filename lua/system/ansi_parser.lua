local Parser = setmetatable({}, { __call = function(self, ...) return self.new(...) end })
Parser.__index = Parser

local FG_COLOR = {
  ["30"] = "SystemBlack",
  ["31"] = "SystemRed",
  ["32"] = "SystemGreen",
  ["33"] = "SystemYellow",
  ["34"] = "SystemBlue",
  ["35"] = "SystemMagenta",
  ["36"] = "SystemCyan",
  ["37"] = "SystemWhite",
  ["90"] = "SystemBrightBlack",
  ["91"] = "SystemBrightRed",
  ["92"] = "SystemBrightGreen",
  ["93"] = "SystemBrightYellow",
  ["94"] = "SystemBrightBlue",
  ["95"] = "SystemBrightMagenta",
  ["96"] = "SystemBrightCyan",
  ["97"] = "SystemBrightWhite",
}

local VALID_COLORS = { "0", "1", "2", "3", "4", "5", "6", "7" }

-- pseudo enum for state values
local NORMAL      = 1
local BEGIN_ESC   = 2
local IN_ESC      = 3
local BEGIN_COLOR = 4
local IN_COLOR    = 5
local DISCARD     = 6

function Parser.new(data)
  local self = setmetatable({}, Parser)
  self.data = data
  self.state = NORMAL
  self.chunks = {}
  self.current_text = ""
  self.current_hl = nil
  self.color_prefix = nil
  return self
end

function Parser:consume()
  if self.current_text ~= "" then
    local hl = self.current_hl and self.current_hl .. (self.bold and "Bold" or "") or nil
    table.insert(self.chunks, { self.current_text, hl })
  end
  self.current_text = ""
  self.current_hl = nil
end

function Parser:discard()
  self.state = DISCARD
  self.color_prefix = nil
end

function Parser:parse(data)
  if data ~= nil then self.data = data end
  if not self.data then return end
  self.chunks = {}

  if self.state == NORMAL and not self.data:find("\27", 1, true) then
    self.current_text = self.current_text .. self.data
    self:consume()
    return self.chunks
  end

  local chars = vim.split(self.data, "")
  for _, c in ipairs(chars) do

    if self.state == NORMAL then
      if c == "\27" then
        self:consume()
        self.state = BEGIN_ESC
      else
        self.current_text = self.current_text .. c
      end

    elseif self.state == BEGIN_ESC then
      if c == "[" then
        self.state = IN_ESC
      else
        self.state = NORMAL
        -- return nil, "EXPECTED ["
      end

    elseif self.state == IN_ESC then
      if c == "0" then
        self.bold = false
        self.current_hl = nil
      elseif c == "1" then
        self.bold = true
      elseif c == "3" or c == "9" then
        self.color_prefix = c
        self.state = BEGIN_COLOR
      elseif c == ";" then
        -- no-op
      elseif c == "m" then
        self.state = NORMAL
      else
        -- return nil, "ERROR??"
        self:discard()
      end

    elseif self.state == BEGIN_COLOR then
      if vim.tbl_contains(VALID_COLORS, c) then
        -- local colorcode = chars[i-1] .. c
        -- self.current_hl = FG_COLOR[colorcode]
        local colorcode = self.color_prefix .. c
        self.current_hl = FG_COLOR[colorcode]
        self.state = IN_COLOR
      else
        self:discard()
        -- return nil, "EXPECTED 0..7"
      end

    elseif self.state == IN_COLOR then
      if c == "m" then
        self.state = NORMAL
      elseif c == ";" then
        -- no-op
      else
        self:discard()
        -- return nil, "ERROR???"
      end

    elseif self.state == DISCARD then
      if c:match("[@-~]") then
        self.state = NORMAL
      end

    end

  end

  self:consume()
  return self.chunks
end

return Parser
