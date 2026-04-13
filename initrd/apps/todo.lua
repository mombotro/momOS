-- todo.lua — nested todo list with autosave and heading sidebar
local WIN_W, WIN_H = 500, 340
local win = wm.open("todo", 60, 40, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8

-- ── Layout ────────────────────────────────────────────────────────────────────
local SIDEBAR_W   = 110   -- sidebar width when visible
local TB_H        = CH + 4
local SB_H        = CH + 4
local SAVE_DELAY  = 120   -- frames (~2 sec at 60fps)

local sidebar_open = true
local function editor_x() return sidebar_open and SIDEBAR_W or 0 end
local function editor_w() return WIN_W - editor_x() end

-- ── File ──────────────────────────────────────────────────────────────────────
local FILEPATH = "/home/todo.txt"

-- ── Text buffer ───────────────────────────────────────────────────────────────
local lines    = { "" }
local cur_row  = 1     -- 1-based line index
local cur_col  = 1     -- 1-based byte offset
local scroll   = 0     -- first visible line (0-based)
local save_tick = nil  -- pit_ticks() deadline for autosave
local modified = false

local function rows_visible()
  return math.floor((WIN_H - TB_H - SB_H) / CH)
end

local function cols_visible()
  return math.floor(editor_w() / CW) - 1
end

-- ── Load / save ───────────────────────────────────────────────────────────────
local function load_file()
  local data = fs.read(FILEPATH)
  if data then
    lines = {}
    for ln in (data.."\n"):gmatch("([^\n]*)\n") do
      lines[#lines+1] = ln
    end
    if #lines == 0 then lines = {""} end
  end
  modified = false; save_tick = nil
end

local function save_file()
  if not fs.exists("/home") then fs.mkdir("/home") end
  fs.write(FILEPATH, table.concat(lines, "\n"))
  modified = false; save_tick = nil
end

local function mark_dirty()
  modified = true
  save_tick = sys.ticks() + SAVE_DELAY
end

-- ── Sidebar headings ──────────────────────────────────────────────────────────
local sidebar_scroll = 0

local function get_headings()
  local h = {}
  for i, ln in ipairs(lines) do
    if ln:match("^#") then
      local depth = 0
      for c in ln:gmatch("^#+") do depth = #c end
      local text = ln:match("^#+%s*(.-)%s*$") or ""
      h[#h+1] = { row=i, depth=depth, text=text }
    end
  end
  return h
end

-- ── Cursor helpers ────────────────────────────────────────────────────────────
local function clamp_col()
  cur_col = math.max(1, math.min(cur_col, #lines[cur_row] + 1))
end

local function scroll_to_cursor()
  local rv = rows_visible()
  if cur_row - 1 < scroll then scroll = cur_row - 1 end
  if cur_row - 1 >= scroll + rv then scroll = cur_row - rv end
  scroll = math.max(0, scroll)
end

-- ── Text editing ──────────────────────────────────────────────────────────────
local function insert_char(c)
  local ln = lines[cur_row]
  lines[cur_row] = ln:sub(1, cur_col-1) .. c .. ln:sub(cur_col)
  cur_col = cur_col + 1
  mark_dirty()
end

local function delete_back()
  if cur_col > 1 then
    local ln = lines[cur_row]
    lines[cur_row] = ln:sub(1, cur_col-2) .. ln:sub(cur_col)
    cur_col = cur_col - 1
  elseif cur_row > 1 then
    local above = lines[cur_row-1]
    cur_col = #above + 1
    lines[cur_row-1] = above .. lines[cur_row]
    table.remove(lines, cur_row)
    cur_row = cur_row - 1
  end
  mark_dirty()
end

local function delete_forward()
  local ln = lines[cur_row]
  if cur_col <= #ln then
    lines[cur_row] = ln:sub(1, cur_col-1) .. ln:sub(cur_col+1)
  elseif cur_row < #lines then
    lines[cur_row] = ln .. lines[cur_row+1]
    table.remove(lines, cur_row+1)
  end
  mark_dirty()
end

-- Get leading spaces (indent) of a line
local function get_indent(ln)
  return ln:match("^(%s*)") or ""
end

-- Get list prefix: "- " if present after indent
local function get_list_prefix(ln)
  return ln:match("^%s*(-%s)") and true or false
end

local function new_line()
  local ln   = lines[cur_row]
  local ind  = get_indent(ln)
  local rest = ln:sub(cur_col)
  local pre  = ln:sub(1, cur_col-1)
  -- carry over list prefix for "- " lines
  local next_prefix = ""
  if get_list_prefix(ln) then
    next_prefix = ind .. "- "
  end
  lines[cur_row] = pre
  table.insert(lines, cur_row+1, next_prefix .. rest)
  cur_row = cur_row + 1
  cur_col = #next_prefix + 1
  mark_dirty()
end

local function indent_line()
  local ln  = lines[cur_row]
  if get_list_prefix(ln) then
    lines[cur_row] = "  " .. ln
    cur_col = cur_col + 2
    mark_dirty()
  end
end

local function dedent_line()
  local ln = lines[cur_row]
  if ln:sub(1,2) == "  " then
    lines[cur_row] = ln:sub(3)
    cur_col = math.max(1, cur_col - 2)
    mark_dirty()
  end
end

-- ── Color coding ──────────────────────────────────────────────────────────────
local function line_color(ln)
  if ln:match("^#%s") or ln:match("^##%s") or ln:match("^###") then
    local depth = 0; for _ in ln:gmatch("^#+") do depth = depth + 1 end
    if depth == 1 then return 15 end   -- bright white
    if depth == 2 then return 14 end   -- yellow
    return 12                          -- cyan
  end
  if ln:match("^%s*-%s") then return 7 end    -- normal
  if ln:match("^%s*%[x%]") then return 8 end  -- done item (dim)
  return 7
end

local function line_indent_col(ln)
  local indent = get_indent(ln)
  return #indent * CW
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw_sidebar(headings)
  gfx.rect(0, TB_H, SIDEBAR_W, WIN_H - TB_H - SB_H, 2)
  gfx.rect(SIDEBAR_W-1, TB_H, 1, WIN_H - TB_H - SB_H, 9)
  gfx.print("HEADINGS", 2, TB_H + 2, 8)
  gfx.rect(0, TB_H + CH + 2, SIDEBAR_W, 1, 9)

  local y0    = TB_H + CH + 4
  local rows  = math.floor((WIN_H - TB_H - SB_H - CH - 4) / CH)
  local max_s = math.max(0, #headings - rows)
  sidebar_scroll = math.min(sidebar_scroll, max_s)

  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)
  local lx, ly = mx - wx, my - wy

  for i = sidebar_scroll + 1, math.min(#headings, sidebar_scroll + rows) do
    local h  = headings[i]
    local y  = y0 + (i - sidebar_scroll - 1) * CH
    local xi = (h.depth - 1) * 4 + 2
    local is_cur = (h.row == cur_row)
    local hover  = (lx >= 0 and lx < SIDEBAR_W and ly >= y and ly < y + CH)
    if is_cur then gfx.rect(0, y, SIDEBAR_W-1, CH, 3) end
    if hover and not is_cur then gfx.rect(0, y, SIDEBAR_W-1, CH, 1) end
    local txt = h.text
    local max_chars = (SIDEBAR_W - xi - 4) // CW
    if #txt > max_chars then txt = txt:sub(1, max_chars-1) .. "~" end
    gfx.print(txt, xi, y, is_cur and 15 or (h.depth == 1 and 14 or 7))
  end
end

local function draw_editor()
  local ex   = editor_x()
  local ew   = editor_w()
  local row_h = CH
  local rv   = rows_visible()

  gfx.rect(ex, TB_H, ew, WIN_H - TB_H - SB_H, 0)

  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)

  for i = 0, rv - 1 do
    local r  = scroll + i + 1
    if r > #lines then break end
    local ln = lines[r]
    local y  = TB_H + i * row_h
    local is_cur = (r == cur_row)
    if is_cur then gfx.rect(ex, y, ew, row_h, 1) end

    local col = line_color(ln)

    -- draw text (clip to width)
    local max_c = math.floor(ew / CW) - 1
    local disp  = #ln > max_c and ln:sub(1, max_c) or ln
    gfx.print(disp, ex + 2, y, col)

    -- cursor
    if is_cur then
      local cx = ex + 2 + (cur_col - 1) * CW
      gfx.rect(cx, y, 1, CH, 15)
    end
  end
end

local function draw()
  wm.focus(win)
  gfx.cls(0)

  -- toolbar
  gfx.rect(0, 0, WIN_W, TB_H, 2)
  local title = "todo"
  if modified then title = "*" .. title end
  gfx.print(title, 2, 2, 7)
  local sb_lbl = sidebar_open and "[< hide]" or "[> show]"
  gfx.print(sb_lbl, WIN_W - #sb_lbl*CW - 4, 2, 8)
  gfx.print("Ctrl+S save", WIN_W//2 - 44, 2, 8)

  local headings = get_headings()
  if sidebar_open then draw_sidebar(headings) end
  draw_editor()

  -- status bar
  local sy = WIN_H - SB_H
  gfx.rect(0, sy, WIN_W, SB_H, 2)
  gfx.rect(0, sy, WIN_W, 1, 9)
  local info = string.format("L%d C%d  %d lines", cur_row, cur_col, #lines)
  if save_tick then info = info .. "  [autosave pending]" end
  gfx.print(info, 2, sy + 2, 8)

  wm.unfocus()
end

-- ── Update ────────────────────────────────────────────────────────────────────
local prev_btn0   = false
local prev_sbtn0  = false  -- sidebar click

local function update()
  -- autosave debounce
  if save_tick and sys.ticks() >= save_tick then
    save_file()
  end

  scroll_to_cursor()

  -- mouse click in editor: position cursor
  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)
  local lx, ly = mx - wx, my - wy
  local btn0   = mouse.btn(0)

  if btn0 and not prev_btn0 then
    local ex = editor_x()
    -- sidebar click: jump to heading
    if sidebar_open and lx >= 0 and lx < SIDEBAR_W then
      local y0   = TB_H + CH + 4
      local rows = math.floor((WIN_H - TB_H - SB_H - CH - 4) / CH)
      local idx  = math.floor((ly - y0) / CH) + sidebar_scroll + 1
      local headings = get_headings()
      if idx >= 1 and idx <= #headings then
        cur_row = headings[idx].row
        clamp_col()
        scroll_to_cursor()
      end
    elseif lx >= ex and ly >= TB_H and ly < WIN_H - SB_H then
      -- click in editor
      local r = scroll + math.floor((ly - TB_H) / CH) + 1
      r = math.max(1, math.min(#lines, r))
      local c = math.floor((lx - ex - 2) / CW) + 1
      c = math.max(1, math.min(#lines[r] + 1, c))
      cur_row = r; cur_col = c
    end
    -- toggle sidebar button
    local sb_lbl = sidebar_open and "[< hide]" or "[> show]"
    local btn_x = WIN_W - #sb_lbl*CW - 4
    if ly >= 0 and ly < TB_H and lx >= btn_x then
      sidebar_open = not sidebar_open
    end
  end
  prev_btn0 = btn0
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local ctrl = false

local function on_input(c)
  -- Ctrl+S
  if c == "\x13" then save_file(); return end
  -- Ctrl+\ = toggle sidebar (backslash = \x1c, safe key)
  if c == "\x1c" then sidebar_open = not sidebar_open; return end

  -- navigation
  if c == "\x01" then  -- up
    if cur_row > 1 then cur_row = cur_row - 1; clamp_col() end; return
  end
  if c == "\x02" then  -- down
    if cur_row < #lines then cur_row = cur_row + 1; clamp_col() end; return
  end
  if c == "\x03" then  -- left
    if cur_col > 1 then cur_col = cur_col - 1
    elseif cur_row > 1 then cur_row = cur_row - 1; cur_col = #lines[cur_row] + 1 end; return
  end
  if c == "\x04" then  -- right
    if cur_col <= #lines[cur_row] then cur_col = cur_col + 1
    elseif cur_row < #lines then cur_row = cur_row + 1; cur_col = 1 end; return
  end

  -- home / end (sent as Ctrl+A / Ctrl+E by some terminals)
  if c == "\x05" then cur_col = #lines[cur_row] + 1; return end  -- Ctrl+E end
  if c == "\x1b[H" or c == "\x00" then cur_col = 1; return end   -- home

  -- Tab = indent, Shift+Tab = dedent
  if c == "\t" then indent_line(); return end
  if c == "\x19" then dedent_line(); return end  -- Shift+Tab (\x19 = NAK)

  -- Enter
  if c == "\n" or c == "\r" then new_line(); return end

  -- Backspace
  if c == "\b" or c == "\x7f" then delete_back(); return end

  -- Delete (sent as escape sequence or \x7f in some configs)
  -- printable
  if c >= " " and #c == 1 then insert_char(c); return end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
load_file()

return { draw=draw, update=update, input=on_input, win=win, name="todo" }
