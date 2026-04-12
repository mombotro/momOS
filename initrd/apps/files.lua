-- files.lua — file manager
local W, H = 320, 240
local win = wm.open("files", 120, 60, W, H)
if not win then return nil end

local CW, CH = 8, 8
local ROWS = math.floor(H / CH) - 2

local cwd = (files_open_path and fs.exists(files_open_path)) and files_open_path or "/"
files_open_path = nil

local entries   = {}
local sel       = 1
local scroll    = 0
local status    = ""
local view_mode = "list"   -- "list" | "icon"
local clipboard = nil      -- {path, name, is_cut}

-- ── Icon view constants ───────────────────────────────────────────────────────
local IC_W    = 56
local IC_H    = 56
local IC_COLS = math.floor(W / IC_W)
local IC_ROWS = math.floor((H - 2*CH) / IC_H)

local function ext_col(e)
  if e.is_dir then return 3 end
  local ext = (e.name:match("%.([^%.]+)$") or ""):lower()
  if ext == "lua" then return 16 end
  if ext == "txt" or ext == "md" then return 7 end
  return 10
end

local function ext_tag(e)
  if e.is_dir then return "DIR" end
  return ((e.name:match("%.([^%.]+)$") or "???"):upper()):sub(1,3)
end

-- ── VFS helpers ───────────────────────────────────────────────────────────────
local function reload()
  entries = {}
  if cwd ~= "/" then entries[1] = {name="..", is_dir=true, size=0} end
  local list = fs.list(cwd)
  if list then
    local dirs, files = {}, {}
    for _, e in ipairs(list) do
      if e.is_dir then dirs[#dirs+1] = e else files[#files+1] = e end
    end
    table.sort(dirs,  function(a,b) return a.name < b.name end)
    table.sort(files, function(a,b) return a.name < b.name end)
    for _, e in ipairs(dirs)  do entries[#entries+1] = e end
    for _, e in ipairs(files) do entries[#entries+1] = e end
  end
  sel = 1; scroll = 0
end

local function fullpath(name)
  return cwd == "/" and "/"..name or cwd.."/"..name
end

local function open_selected()
  local e = entries[sel]
  if not e then return end
  if e.name == ".." then
    if cwd ~= "/" then cwd = cwd:match("^(.+)/[^/]+$") or "/"; reload() end
  elseif e.is_dir then
    cwd = fullpath(e.name); reload()
  else
    local path = fullpath(e.name)
    if path:match("%.lua$") then
      if app_launch then app_launch(path); status = "launched "..e.name
      else status = "no launcher" end
    elseif path:match("%.mpi$") then
      pixel_open_file = path
      if app_launch then app_launch("/apps/pixel.lua"); status = "opened in pixel"
      else status = "no launcher" end
    else
      quill_open_file = path
      if app_launch then app_launch("/apps/quill.lua"); status = "opened in quill"
      else status = "no launcher" end
    end
  end
end

reload()

-- ── Rename state ──────────────────────────────────────────────────────────────
local rename_mode = false
local rename_buf  = ""

local function do_rename()
  local e = entries[sel]
  if not e or e.name == ".." or rename_buf == "" or rename_buf == e.name then
    rename_mode = false; return
  end
  if e.is_dir then status = "can't rename dirs"; rename_mode = false; return end
  local src = fullpath(e.name)
  local dst = fullpath(rename_buf)
  local data = fs.read(src)
  if data and fs.write(dst, data) and fs.delete(src) then
    reload(); status = "renamed"
  else
    status = "rename failed"
  end
  rename_mode = false
end

-- ── Mouse hit detection ───────────────────────────────────────────────────────
local prev_btn       = false
local last_click_sel = 0
local last_click_t   = 0
local DCLICK         = 25

local function idx_from_mouse(mx, my)
  local wx, wy = wm.rect(win)
  local lx, ly = mx - wx, my - wy
  if view_mode == "list" then
    local i = math.floor((ly - CH) / CH)
    if i < 1 or i > ROWS then return nil end
    local idx = scroll + i
    return (idx >= 1 and idx <= #entries) and idx or nil
  else
    ly = ly - CH
    if lx < 0 or ly < 0 then return nil end
    local c = math.floor(lx / IC_W)
    local r = math.floor(ly / IC_H)
    if c < 0 or c >= IC_COLS then return nil end
    local idx = scroll + r * IC_COLS + c + 1
    return (idx >= 1 and idx <= #entries) and idx or nil
  end
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  if rename_mode then
    if     c == "\n"   then do_rename()
    elseif c == "\x1b" then rename_mode = false; status = "cancelled"
    elseif c == "\b"   then if #rename_buf > 0 then rename_buf = rename_buf:sub(1,-2) end
    elseif c >= " "    then rename_buf = rename_buf..c
    end
    return
  end

  -- view toggle
  if c == "\t" then
    view_mode = view_mode == "list" and "icon" or "list"
    scroll = 0; return
  end

  -- clipboard ops
  if c == "c" then
    local e = entries[sel]
    if e and e.name ~= ".." and not e.is_dir then
      clipboard = {path=fullpath(e.name), name=e.name, is_cut=false}
      status = "copied "..e.name
    end; return
  end
  if c == "x" then
    local e = entries[sel]
    if e and e.name ~= ".." and not e.is_dir then
      clipboard = {path=fullpath(e.name), name=e.name, is_cut=true}
      status = "cut "..e.name
    end; return
  end
  if c == "p" then
    if not clipboard then status = "nothing to paste"; return end
    local dst = fullpath(clipboard.name)
    if fs.exists(dst) then status = "already exists"; return end
    local data = fs.read(clipboard.path)
    if not data then status = "source gone"; clipboard = nil; return end
    if fs.write(dst, data) then
      if clipboard.is_cut then fs.delete(clipboard.path); clipboard = nil end
      reload(); status = "pasted"
    else
      status = "paste failed"
    end; return
  end

  -- edit: quill for text/lua, pixel for .mpi
  if c == "e" then
    local e = entries[sel]
    if e and not e.is_dir and e.name ~= ".." then
      local path = fullpath(e.name)
      if path:match("%.mpi$") then
        pixel_open_file = path
        if app_launch then app_launch("/apps/pixel.lua"); status = "edit: "..e.name end
      else
        quill_open_file = path
        if app_launch then app_launch("/apps/quill.lua"); status = "edit: "..e.name end
      end
    end
    return
  end

  -- rename
  if c == "r" then
    local e = entries[sel]
    if e and e.name ~= ".." then rename_mode = true; rename_buf = e.name end
    return
  end

  -- navigation
  if c == "\x01" then       -- up
    if sel > 1 then
      sel = sel - 1
      if view_mode == "list" then
        if sel < scroll + 1 then scroll = sel - 1 end
      else
        if sel <= scroll then scroll = math.max(0, scroll - IC_COLS) end
      end
    end
  elseif c == "\x02" then   -- down
    if sel < #entries then
      sel = sel + 1
      if view_mode == "list" then
        if sel > scroll + ROWS then scroll = sel - ROWS end
      else
        local vis = IC_ROWS * IC_COLS
        if sel > scroll + vis then scroll = scroll + IC_COLS end
      end
    end
  elseif c == "\n"   then open_selected()
  elseif c == "\b" or c == "\x03" then
    if cwd ~= "/" then cwd = cwd:match("^(.+)/[^/]+$") or "/"; reload() end
  elseif c == "\x7f" then
    local e = entries[sel]
    if e and e.name ~= ".." then
      if fs.delete(fullpath(e.name)) then reload() else status = "delete failed" end
    end
  end
end

-- ── Update ────────────────────────────────────────────────────────────────────
local function update()
  local mx, my = mouse.x(), mouse.y()
  local btn = mouse.btn(0)
  if btn and not prev_btn then
    local idx = idx_from_mouse(mx, my)
    if idx then
      local now = pit_ticks()
      if idx == last_click_sel and (now - last_click_t) < DCLICK then
        sel = idx; open_selected(); last_click_sel = 0
      else
        sel = idx; last_click_sel = idx; last_click_t = now
      end
    end
  end
  prev_btn = btn
end

-- ── Draw helpers ──────────────────────────────────────────────────────────────
local function is_clipped(e)
  return clipboard and not clipboard.is_cut and fullpath(e.name) == clipboard.path
end
local function is_cut(e)
  return clipboard and clipboard.is_cut and fullpath(e.name) == clipboard.path
end

local function draw_list()
  for i = 1, ROWS do
    local idx = scroll + i
    local e = entries[idx]
    if not e then break end
    local y = CH + i * CH
    local focused = (idx == sel)
    if focused then gfx.rect(0, y, W, CH, 3) end
    local col = is_cut(e) and 8 or is_clipped(e) and 15
             or (focused and 7 or (e.is_dir and 15 or 7))
    local tag = e.is_dir and "[D] " or "    "
    local label = tag..e.name
    if not e.is_dir then
      label = label..string.rep(" ", math.max(1, 28 - #label))..e.size.."b"
    end
    gfx.print(label, 2, y, col)
  end
end

local function draw_icons()
  local vis = IC_ROWS * IC_COLS
  for i = 1, vis do
    local idx = scroll + i
    local e = entries[idx]
    if not e then break end
    local c  = (i-1) % IC_COLS
    local r  = (i-1) // IC_COLS
    local x  = c * IC_W + 2
    local y  = CH + r * IC_H + 2
    local focused = (idx == sel)
    -- cell bg
    if focused then gfx.rect(x, y, IC_W-4, IC_H-2, 3) end
    -- icon box
    local ic = ext_col(e)
    local cut = is_cut(e)
    gfx.rect(x+4, y+2, IC_W-12, IC_H-CH-8, cut and 10 or ic)
    -- type tag inside icon
    local tag = ext_tag(e)
    local tx = x + 4 + (IC_W-12 - #tag*CW)//2
    local ty = y + 2 + (IC_H-CH-8)//2 - CH//2
    gfx.print(tag, tx, ty, focused and 1 or 7)
    -- filename below icon
    local lbl = e.name:sub(1, (IC_W-4)//CW)
    gfx.print(lbl, x, y + IC_H - CH - 2, focused and 7 or 8)
  end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(1)

  -- header: view indicator + path
  local indicator = view_mode == "icon" and "[i] " or "[l] "
  local header = indicator..cwd
  if #header > W//CW then header = "..."..header:sub(-(W//CW-3)) end
  gfx.print(header, 0, 0, 15)
  gfx.rect(0, CH, W, 1, 9)

  if view_mode == "list" then draw_list() else draw_icons() end

  -- footer
  gfx.rect(0, H-CH-2, W, 1, 9)
  local footer, fc
  if rename_mode then
    footer = "rename: "..rename_buf.."_"; fc = 15
  elseif clipboard then
    local op = clipboard.is_cut and "cut" or "copy"
    footer = "["..op.."] "..clipboard.name..(status~="" and "  "..status or ""); fc = 15
    status = ""
  elseif status ~= "" then
    footer = status; fc = 8; status = ""
  else
    footer = entries[sel] and entries[sel].name or ""; fc = 8
  end
  gfx.print(footer, 2, H-CH, fc)

  -- key hints in bottom-right
  local hints = "tab=view  c/x/p=copy/cut/paste  r=rename"
  -- too long to print fully, show short version
  gfx.print("tab e c x p r", W - 13*CW - 2, H-CH, 10)

  wm.unfocus()
end

return { draw=draw, update=update, input=on_input, win=win, name="files" }
