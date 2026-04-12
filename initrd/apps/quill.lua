-- quill.lua — code editor
local W, H = 480, 360
local win = wm.open("quill", 40, 20, W, H)
if not win then return nil end

local CW, CH = 8, 8

-- layout constants
local TAB_H  = CH + 1        -- tab bar + separator
local STAT_H = CH + 2        -- separator + status line
local CODE_H = H - TAB_H - STAT_H
local ROWS   = math.floor(CODE_H / CH)
local LN_W   = 4 * CW        -- " 99 " line number column
local CODE_W = W - LN_W

-- colors
local C_BG     = 1
local C_LINEBG = 2
local C_FG     = 7
local C_DIM    = 8
local C_CURLN  = 15
local C_KW     = 5
local C_STR    = 14
local C_CMT    = 8
local C_NUM    = 13
local C_SYM    = 9
local C_ERR    = 12
local C_INFO   = 16
local C_HINT   = 10

-- ── Syntax highlighting ───────────────────────────────────────────────────────
local KW = {}
for _, k in ipairs({
  "and","break","do","else","elseif","end","false","for","function",
  "goto","if","in","local","nil","not","or","repeat","return","then",
  "true","until","while"
}) do KW[k] = true end

local function colorize(line)
  local segs = {}
  local i = 1
  local n = #line
  while i <= n do
    local ch = line:sub(i, i)
    if line:sub(i, i+1) == "--" then          -- comment: rest of line
      segs[#segs+1] = {line:sub(i), C_CMT}
      break
    elseif ch == '"' or ch == "'" then         -- string literal
      local j = i + 1
      while j <= n do
        local c2 = line:sub(j, j)
        if c2 == "\\" then j = j + 2
        elseif c2 == ch then break
        else j = j + 1 end
      end
      segs[#segs+1] = {line:sub(i, math.min(j, n)), C_STR}
      i = j + 1
    elseif ch:match("[%a_]") then              -- identifier / keyword
      local j = i
      while j <= n and line:sub(j,j):match("[%w_]") do j = j+1 end
      local word = line:sub(i, j-1)
      segs[#segs+1] = {word, KW[word] and C_KW or C_FG}
      i = j
    elseif ch:match("%d") then                 -- number
      local j = i
      while j <= n and line:sub(j,j):match("[%w%.]") do j = j+1 end
      segs[#segs+1] = {line:sub(i, j-1), C_NUM}
      i = j
    else                                       -- symbol / punctuation
      segs[#segs+1] = {ch, C_SYM}
      i = i + 1
    end
  end
  return segs
end

-- ── Tab-complete API list ─────────────────────────────────────────────────────
local API = {
  "gfx.cls","gfx.rect","gfx.print","gfx.pset","gfx.pget","gfx.line",
  "fs.read","fs.write","fs.list","fs.mkdir","fs.delete","fs.exists",
  "wm.open","wm.close","wm.focus","wm.unfocus","wm.rect","wm.move",
  "wm.resize","wm.raise","wm.minimize","wm.is_minimized","wm.set_focused",
  "wm.present","wm.draw_cursor","wm.z",
  "mouse.x","mouse.y","mouse.btn",
  "input.getchar","input.key_down",
  "pit_ticks","app_launch","sys_ps","sys_kill","files_open_path",
  "math.floor","math.ceil","math.max","math.min","math.sin","math.cos",
  "math.abs","math.sqrt","math.random","math.pi","math.huge","math.fmod",
  "string.format","string.sub","string.len","string.match","string.gmatch",
  "string.rep","string.upper","string.lower","string.byte","string.char",
  "string.find","string.gsub","string.reverse",
  "table.insert","table.remove","table.sort","table.concat",
  "tostring","tonumber","type","pairs","ipairs","next",
  "pcall","xpcall","load","error","assert","select","unpack",
}

local function api_complete(prefix)
  if prefix == "" then return nil end
  local m = {}
  for _, name in ipairs(API) do
    if name:sub(1, #prefix) == prefix then m[#m+1] = name end
  end
  return #m > 0 and m or nil
end

-- ── Buffer ────────────────────────────────────────────────────────────────────
local INDENT_AFTER = {["then"]=true,["do"]=true,["else"]=true,
                      ["elseif"]=true,["function"]=true,["repeat"]=true}

local function buf_new(filename, content)
  local lines = {}
  if content and #content > 0 then
    for ln in (content.."\n"):gmatch("([^\n]*)\n") do
      lines[#lines+1] = ln
    end
  end
  if #lines == 0 then lines[1] = "" end
  return { filename=filename or "untitled", lines=lines,
           cx=1, cy=1, scroll=0, modified=false, err_line=nil }
end

local function buf_content(b)
  return table.concat(b.lines, "\n")
end

local function buf_clamp(b)
  b.cy = math.max(1, math.min(b.cy, #b.lines))
  b.cx = math.max(1, math.min(b.cx, #b.lines[b.cy] + 1))
  if b.cy - 1 < b.scroll then b.scroll = b.cy - 1 end
  if b.cy - 1 >= b.scroll + ROWS then b.scroll = b.cy - ROWS end
  b.scroll = math.max(0, b.scroll)
end

-- ── Tabs ──────────────────────────────────────────────────────────────────────
local tabs    = {}
local tab_idx = 1

local function tab_open(path)
  for i, b in ipairs(tabs) do
    if b.filename == path then tab_idx = i; return end
  end
  if #tabs >= 8 then return end
  local content = path and fs.read(path) or nil
  tabs[#tabs+1] = buf_new(path, content or "")
  tab_idx = #tabs
end

local function tab_close(i)
  table.remove(tabs, i)
  if #tabs == 0 then tabs[1] = buf_new(nil, "") end
  tab_idx = math.min(tab_idx, #tabs)
end

-- initial tab
if quill_open_file then
  tab_open(quill_open_file); quill_open_file = nil
else
  tab_open(nil)
end

-- ── Command mode ──────────────────────────────────────────────────────────────
local cmd_mode = false
local cmd_buf  = ""
local cmd_msg  = ""

local function buf_save(b, path)
  path = path or b.filename
  if not path or path == "untitled" then
    cmd_msg = "no filename — use :w <path>"; return false
  end
  if not path:match("%.%w+$") then path = path..".lua" end
  if fs.write(path, buf_content(b)) then
    b.filename = path; b.modified = false
    cmd_msg = "saved "..path; return true
  end
  cmd_msg = "write failed"; return false
end

local function buf_run(b)
  local fn, err = load(buf_content(b), b.filename)
  if not fn then
    local ln = err:match(":(%d+):")
    b.err_line = ln and tonumber(ln) or nil
    cmd_msg = (err:match("[^\n]+") or err):sub(1, W//CW - 1)
    return
  end
  b.err_line = nil
  local ok, res = pcall(fn)
  if not ok then
    local ln = tostring(res):match(":(%d+):")
    b.err_line = ln and tonumber(ln) or nil
    cmd_msg = (tostring(res):match("[^\n]+") or tostring(res)):sub(1, W//CW - 1)
  else
    cmd_msg = "ok" .. (type(res)=="table" and " (app launched)" or "")
  end
end

local function exec_cmd(line)
  line = line:match("^%s*(.-)%s*$")
  local b = tabs[tab_idx]
  if     line == "w"              then buf_save(b)
  elseif line:sub(1,2) == "w "   then buf_save(b, line:sub(3))
  elseif line == "r"              then buf_run(b)
  elseif line == "q"              then tab_close(tab_idx)
  elseif line == "wq"             then if buf_save(b) then tab_close(tab_idx) end
  elseif line:sub(1,2) == "o "   then tab_open(line:sub(3))
  elseif line == "n"              then tab_open(nil)
  elseif line == "help"           then tab_open("/docs/quill.txt")
  else   cmd_msg = "?: w  w <f>  r  q  wq  o <f>  n  help"
  end
end

-- ── Tab-complete state ────────────────────────────────────────────────────────
local tc_matches = nil
local tc_idx     = 0
local tc_prefix  = ""
local tc_pre     = ""

local function tc_reset()
  tc_matches = nil; tc_idx = 0; tc_prefix = ""; tc_pre = ""
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  local b = tabs[tab_idx]

  if cmd_mode then
    if     c == "\n"   then exec_cmd(cmd_buf); cmd_mode = false; cmd_buf = ""
    elseif c == "\x1b" then cmd_mode = false; cmd_buf = ""
    elseif c == "\b"   then
      if #cmd_buf > 0 then cmd_buf = cmd_buf:sub(1,-2)
      else cmd_mode = false end
    elseif c >= " " then cmd_buf = cmd_buf..c
    end
    return
  end

  if c == "\x1b" then cmd_mode = true; cmd_buf = ""; tc_reset(); return end

  local line = b.lines[b.cy]

  -- Tab: indent or complete
  if c == "\t" then
    local before = line:sub(1, b.cx - 1)
    local word   = before:match("[%w_%.]+$") or ""
    if word ~= "" then
      if tc_matches and tc_prefix == word then
        tc_idx = tc_idx % #tc_matches + 1
        local m   = tc_matches[tc_idx]
        local rest = line:sub(b.cx)
        b.lines[b.cy] = tc_pre..m..rest
        b.cx = #tc_pre + #m + 1
        b.modified = true
      else
        local pre     = before:sub(1, #before - #word)
        local matches = api_complete(word)
        if matches and #matches == 1 then
          local rest = line:sub(b.cx)
          b.lines[b.cy] = pre..matches[1]..rest
          b.cx = #pre + #matches[1] + 1
          b.modified = true; tc_reset()
        elseif matches then
          tc_matches = matches; tc_idx = 0; tc_prefix = word; tc_pre = pre
          cmd_msg = table.concat(matches, "  "):sub(1, W//CW - 1)
        else
          b.lines[b.cy] = before.."  "..line:sub(b.cx)
          b.cx = b.cx + 2; b.modified = true; tc_reset()
        end
      end
    else
      b.lines[b.cy] = before.."  "..line:sub(b.cx)
      b.cx = b.cx + 2; b.modified = true; tc_reset()
    end
    return
  end

  tc_reset()

  if     c == "\x01" then b.cy = b.cy - 1
  elseif c == "\x02" then b.cy = b.cy + 1
  elseif c == "\x03" then
    if b.cx > 1 then b.cx = b.cx - 1
    elseif b.cy > 1 then b.cy = b.cy-1; b.cx = #b.lines[b.cy]+1 end
  elseif c == "\x04" then
    if b.cx <= #line then b.cx = b.cx + 1
    elseif b.cy < #b.lines then b.cy = b.cy+1; b.cx = 1 end
  elseif c == "\x05" then b.cx = 1          -- home
  elseif c == "\x06" then b.cx = #b.lines[b.cy]+1  -- end
  elseif c == "\x0b" then                   -- page up
    b.cy = math.max(1, b.cy - ROWS)
    b.scroll = math.max(0, b.scroll - ROWS)
  elseif c == "\x0c" then                   -- page down
    b.cy = math.min(#b.lines, b.cy + ROWS)
    b.scroll = b.scroll + ROWS

  elseif c == "\n" then
    local before = line:sub(1, b.cx-1)
    local after  = line:sub(b.cx)
    local indent = before:match("^(%s*)") or ""
    local last_w = before:match("([%a_]+)%s*$")
    if last_w and INDENT_AFTER[last_w] then indent = indent.."  " end
    b.lines[b.cy] = before
    table.insert(b.lines, b.cy+1, indent..after)
    b.cy = b.cy+1; b.cx = #indent+1; b.modified = true

  elseif c == "\b" then
    if b.cx > 1 then
      b.lines[b.cy] = line:sub(1,b.cx-2)..line:sub(b.cx)
      b.cx = b.cx-1; b.modified = true
    elseif b.cy > 1 then
      local prev = b.lines[b.cy-1]
      b.cx = #prev+1
      b.lines[b.cy-1] = prev..line
      table.remove(b.lines, b.cy)
      b.cy = b.cy-1; b.modified = true
    end

  elseif c == "\x7f" then
    if b.cx <= #line then
      b.lines[b.cy] = line:sub(1,b.cx-1)..line:sub(b.cx+1)
      b.modified = true
    elseif b.cy < #b.lines then
      b.lines[b.cy] = line..b.lines[b.cy+1]
      table.remove(b.lines, b.cy+1)
      b.modified = true
    end

  elseif c >= " " then
    b.lines[b.cy] = line:sub(1,b.cx-1)..c..line:sub(b.cx)
    b.cx = b.cx+1; b.modified = true
  end

  buf_clamp(b)
end

-- ── Mouse (tab clicks) ────────────────────────────────────────────────────────
local prev_btn = false
local TAB_W    = math.floor(W / 8)   -- max 8 tabs, equal width

local function update()
  local mx, my = mouse.x(), mouse.y()
  local btn    = mouse.btn(0)
  if btn and not prev_btn then
    local wx, wy = wm.rect(win)
    local lx, ly = mx - wx, my - wy
    if ly >= 0 and ly < CH then
      local i = math.floor(lx / TAB_W) + 1
      if i >= 1 and i <= #tabs then tab_idx = i end
    end
  end
  prev_btn = btn
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(C_BG)
  local b      = tabs[tab_idx]
  local blink  = (math.floor(pit_ticks()/20) % 2) == 0

  -- tab bar
  for i, t in ipairs(tabs) do
    local tx  = (i-1) * TAB_W
    local act = (i == tab_idx)
    gfx.rect(tx, 0, TAB_W-1, CH, act and 3 or 2)
    local lbl = (t.filename:match("[^/]+$") or t.filename)
    if t.modified then lbl = lbl.."*" end
    lbl = lbl:sub(1, TAB_W//CW - 1)
    gfx.print(lbl, tx+2, 0, act and 7 or C_DIM)
  end
  gfx.rect(0, CH, W, 1, C_SYM)

  -- code lines
  for row = 0, ROWS-1 do
    local li = b.scroll + row + 1
    if li > #b.lines then break end
    local y    = TAB_H + row * CH
    local line = b.lines[li]
    local is_cur = (li == b.cy)
    local is_err = (li == b.err_line)

    if is_err then
      gfx.rect(0, y, W, CH, C_ERR)
    elseif is_cur then
      gfx.rect(LN_W, y, CODE_W, CH, C_LINEBG)
    end

    -- line number
    gfx.print(string.format("%3d ", li), 0, y,
      is_err and 7 or (is_cur and C_CURLN or C_DIM))

    -- syntax-colored code
    local x = LN_W
    for _, seg in ipairs(colorize(line)) do
      if x >= W then break end
      local avail = (W - x) // CW
      local txt   = #seg[1] <= avail and seg[1] or seg[1]:sub(1, avail)
      gfx.print(txt, x, y, seg[2])
      x = x + #txt * CW
    end

    -- cursor
    if is_cur and blink then
      local cx_px = LN_W + (b.cx-1)*CW
      if cx_px < W then gfx.rect(cx_px, y, 2, CH-1, C_FG) end
    end
  end

  -- status bar
  gfx.rect(0, H-STAT_H, W, 1, C_SYM)
  if cmd_mode then
    gfx.print(":"..cmd_buf.."_", 0, H-CH, C_CURLN)
  else
    local pos = string.format("L%d C%d  %s",
      b.cy, b.cx, b.modified and "[+]" or "")
    local msg = cmd_msg ~= "" and cmd_msg or pos
    local mc  = cmd_msg ~= "" and (b.err_line and C_ERR or C_INFO) or C_DIM
    gfx.print(msg:sub(1, (W - 22*CW)//CW), 0, H-CH, mc)
    gfx.print("ESC :w :r :o :q TAB", W-19*CW, H-CH, C_HINT)
  end

  wm.unfocus()
end

return { draw=draw, update=update, input=on_input, win=win, name="quill" }
