-- momOS desktop

local TB_H  = 20   -- taskbar height at bottom
local WM_TH = 16   -- must match WM_TITLE_H in wm.h
local WM_B  = 1    -- must match WM_BORDER  in wm.h

-- ── Terminal output buffer ────────────────────────────────────────────────────
local COL_BG     = 0
local COL_FG     = 7
local COL_DIM    = 8
local COL_WARN   = 4
local COL_PROMPT = 15

local lines = {}
local unread_errors = 0
local function push(s, col)
  lines[#lines+1] = { text = s or "", col = col or COL_FG }
  if #lines > 200 then table.remove(lines, 1) end
  if col == COL_WARN then unread_errors = unread_errors + 1 end
end

-- ── App registry ──────────────────────────────────────────────────────────────
local app_list    = {}
local focused_app = nil   -- nil = terminal has focus (if open)

local function set_focus(app, win)
  focused_app = app
  if win then wm.raise(win); wm.set_focused(win) end
end

local function launch(path)
  local code = fs.read(path)
  if not code then push("launch: can't read "..path, COL_WARN); return end
  local fn, err = load(code, path)
  if not fn then push("launch: "..err, COL_WARN); return end
  local ok, app = pcall(fn)
  if not ok then push("launch: "..tostring(app), COL_WARN); return end
  if type(app) ~= "table" then return end
  local aname = app.name or "app"
  app._pid = (sys.proc_alloc and sys.proc_alloc(aname)) or -1
  if ipc and ipc.open then ipc.open(aname) end
  app_list[#app_list+1] = app
  set_focus(app, app.win)
end
app_launch = launch

-- ── sys table (spawn/kill/ps wired in from Lua side) ─────────────────────────
sys.spawn = launch
-- sys.kill and sys.ps filled in below after close_app is defined

-- ── Dropdown terminal ─────────────────────────────────────────────────────────
local CW, CH    = 8, 8
local TERM_H    = 200                       -- height when fully open (mutable)
local COLS      = math.floor(SCREEN_W / CW)
local term_y    = -TERM_H                   -- current top (< 0 = hidden)
local term_open = false
local term_prev_focus  = nil                -- app focused before terminal opened
local term_drag        = false              -- dragging the bottom edge
local term_drag_start_y = 0
local term_drag_start_h = 0
local TERM_MIN_H = 5 * CH
local TERM_MAX_H = SCREEN_H - TB_H - 20

local function term_is_visible() return term_y > -TERM_H end

local function term_toggle()
  if term_open then
    term_open = false
    -- restore previous focus
    if term_prev_focus then
      focused_app = term_prev_focus
      if focused_app and focused_app.win then
        wm.set_focused(focused_app.win)
      end
      term_prev_focus = nil
    end
  else
    term_open = true
    term_prev_focus = focused_app
    focused_app = nil   -- terminal gets keyboard focus
    unread_errors = 0
  end
end

-- sys_ps / sys_kill kept as globals for back-compat with terminal.lua
-- also wired into sys table below (after close_app is defined)
sys_ps = function()
  local r = {{name="console", pid=0}}
  for i, a in ipairs(app_list) do r[#r+1] = {name=(a.name or "app"), pid=i} end
  return r
end
sys_kill = function(name)
  for i = #app_list, 1, -1 do
    local a = app_list[i]
    if (a.name or "app") == name then close_app(a, a.win); return true end
  end
  return false
end
sys.ps   = sys_ps
sys.kill = sys_kill

-- ── Terminal commands ─────────────────────────────────────────────────────────
local input_line = ""
local cwd        = "/"
local history    = {}
local hist_idx   = 0

local write_mode = false
local write_file = nil
local write_buf  = {}

local function abspath(p)
  if p:sub(1,1) == "/" then return p end
  return cwd == "/" and "/"..p or cwd.."/"..p
end

local cmds = {}
cmds.help  = function(_) push("help ls cat cd run open write clear mkdir rm ps kill save load", COL_DIM) end
cmds.clear = function(_) lines = {} end

cmds.ls = function(args)
  local path = abspath(args[1] or cwd)
  local entries = fs.list(path)
  if not entries then push("ls: not found: "..path, COL_WARN); return end
  for _, e in ipairs(entries) do
    push((e.is_dir and "DIR  " or "FILE ")..e.name..(e.is_dir and "" or " "..e.size.."b"),
         e.is_dir and COL_PROMPT or COL_FG)
  end
end

cmds.cd = function(args)
  if not args[1] then cwd = "/"; return end
  local t = abspath(args[1])
  if not fs.list(t) then push("cd: not a directory: "..t, COL_WARN); return end
  cwd = t
end

cmds.cat = function(args)
  if not args[1] then push("usage: cat <file>", COL_DIM); return end
  local data = fs.read(abspath(args[1]))
  if not data then push("cat: not found: "..args[1], COL_WARN); return end
  for line in (data.."\n"):gmatch("([^\n]*)\n") do push(line) end
end

cmds.run = function(args)
  if not args[1] then push("usage: run <file>", COL_DIM); return end
  local code = fs.read(abspath(args[1]))
  if not code then push("run: not found: "..args[1], COL_WARN); return end
  local fn, err = load(code, args[1])
  if not fn then push("run: "..err, COL_WARN); return end
  local ok, result = pcall(fn)
  if not ok then push("run: "..tostring(result), COL_WARN)
  elseif type(result) == "table" then
    app_list[#app_list+1] = result
    set_focus(result, result.win)
  end
end

cmds.write = function(args)
  if not args[1] then push("usage: write <file>", COL_DIM); return end
  write_file = abspath(args[1]); write_buf = {}; write_mode = true
  push("-- "..write_file.." --", COL_DIM)
  push("-- type lines, '.' alone to save, ESC to cancel --", COL_DIM)
end

cmds.mkdir = function(args)
  if not args[1] then push("usage: mkdir <dir>", COL_DIM); return end
  if not fs.mkdir(abspath(args[1])) then push("mkdir: failed", COL_WARN) end
end

cmds.rm = function(args)
  if not args[1] then push("usage: rm <path>", COL_DIM); return end
  if not fs.delete(abspath(args[1])) then push("rm: failed", COL_WARN) end
end

cmds.ps = function(_)
  push("0 console", COL_FG)
  for i, a in ipairs(app_list) do push(i.." "..(a.name or "app"), COL_FG) end
end

cmds.kill = function(args)
  if not args[1] then push("usage: kill <name>", COL_DIM); return end
  local name = args[1]
  for i = #app_list, 1, -1 do
    local a = app_list[i]
    if (a.name or "app") == name then
      close_app(a, a.win); push("killed "..name, COL_DIM); return
    end
  end
  push("kill: not found: "..name, COL_WARN)
end

cmds.open = function(args)
  if not args[1] then push("usage: open <file>", COL_DIM); return end
  local path = abspath(args[1])
  if not fs.exists(path) then push("open: not found: "..path, COL_WARN); return end
  local ext = path:match("%.([^%.]+)$") or ""
  if ext == "mpi" then
    pixel_open_file = path; launch("/apps/pixel.lua")
  elseif ext == "msm" then
    _G.chirp_open_file = path; launch("/apps/chirp.lua")
  elseif ext == "mtm" then
    _G.terrain_open_file = path; launch("/apps/terrain.lua")
  elseif ext == "p8" then
    _G.p8_open_file = path; launch("/apps/p8.lua")
  elseif ext == "lua" then
    launch(path)
  else
    quill_open_file = path; launch("/apps/quill.lua")
  end
end

cmds.save = function(_)
  if not sys.save then push("save: not available", COL_WARN); return end
  local ok, err = sys.save()
  if ok then push("saved to disk", COL_DIM)
  else push("save failed: "..(err or "?"), COL_WARN) end
end

cmds.load = function(_)
  if not sys.load then push("load: not available", COL_WARN); return end
  local ok, err = sys.load()
  if ok then push("loaded from disk", COL_DIM)
  else push("load failed: "..(err or "?"), COL_WARN) end
end

local function exec(line)
  line = line:match("^%s*(.-)%s*$")
  if line == "" then return end
  if #history == 0 or history[#history] ~= line then
    history[#history+1] = line
    if #history > 100 then table.remove(history, 1) end
  end
  hist_idx = 0
  push("> "..line, COL_DIM)
  local parts = {}
  for w in line:gmatch("%S+") do parts[#parts+1] = w end
  local cmd = table.remove(parts, 1)
  if cmds[cmd] then
    cmds[cmd](parts)
  else
    local src = line:sub(1,1) == "=" and ("return "..line:sub(2)) or line
    local fn, lerr = load(src)
    if fn then
      local ok, val = pcall(fn)
      if ok then
        if val ~= nil then push(tostring(val), COL_FG) end
      else push(tostring(val), COL_WARN) end
    else
      push(cmd..": unknown command", COL_WARN)
    end
  end
end

-- Redirect print() to terminal
print = function(...)
  local t = {}
  for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end
  push(table.concat(t, "\t"), COL_FG)
end

-- dofile: load and run a VFS file, returning its result(s)
function dofile(path)
  local src = fs.read(path)
  if not src then error("dofile: cannot open '"..tostring(path).."'", 2) end
  local fn, err = load(src, "@"..path)
  if not fn then error("dofile: "..tostring(err), 2) end
  return fn()
end

push("momOS  ` to toggle console", COL_PROMPT)

-- ── Desktop icons ─────────────────────────────────────────────────────────────
local ICON_W, ICON_H  = 48, 48
local ICON_STRIDE     = 64          -- cell size (icon + label gap)
local ICON_MARGIN     = 8           -- left/top margin
local icons           = {}
local last_desk_scan  = -999

-- Compute grid x,y from sequential index (0-based).
-- Columns fill top-to-bottom, then wrap right.
local function icon_pos(idx)
  local rows = math.floor((SCREEN_H - TB_H - ICON_MARGIN) / ICON_STRIDE)
  if rows < 1 then rows = 1 end
  local col  = math.floor(idx / rows)
  local row  = idx % rows
  return ICON_MARGIN + col * (ICON_W + ICON_MARGIN + 8),
         ICON_MARGIN + row * ICON_STRIDE
end

local function refresh_desktop()
  icons = {}
  local function add(label, col, action)
    local ix, iy = icon_pos(#icons)
    icons[#icons+1] = { label=label, x=ix, y=iy, col=col, action=action }
  end
  add("terminal", 3,  function() launch("/apps/terminal.lua") end)
  add("files",    5,  function() launch("/apps/files.lua")    end)
  add("quill",    19, function() launch("/apps/quill.lua")    end)
  add("pixel",    14, function() launch("/apps/pixel.lua")    end)
  add("chirp",    12, function() launch("/apps/chirp.lua")    end)
  add("terrain",  11, function() launch("/apps/terrain.lua")  end)
  add("shelf",    6,  function() launch("/apps/shelf.lua")    end)
  add("snake",    16, function() launch("/apps/snake.lua")    end)
  add("bouncer",  4,  function() launch("/apps/bouncer.lua")  end)
  if fs.exists("/home/desktop") then
    local list = fs.list("/home/desktop")
    if list then
      table.sort(list, function(a,b) return a.name < b.name end)
      for _, e in ipairs(list) do
        local path  = "/home/desktop/"..e.name
        local label = e.is_dir and e.name or e.name:gsub("%.%w+$","")
        local act
        if e.is_dir then
          act = (function(p) return function() files_open_path=p; launch("/apps/files.lua") end end)(path)
        elseif e.name:match("%.lua$") then
          act = (function(p) return function() launch(p) end end)(path)
        elseif e.name:match("%.mpi$") then
          act = (function(p) return function() pixel_open_file=p; launch("/apps/pixel.lua") end end)(path)
        elseif e.name:match("%.msm$") then
          act = (function(p) return function() _G.chirp_open_file=p; launch("/apps/chirp.lua") end end)(path)
        elseif e.name:match("%.mtm$") then
          act = (function(p) return function() _G.terrain_open_file=p; launch("/apps/terrain.lua") end end)(path)
        elseif e.name:match("%.p8$") then
          act = (function(p) return function() _G.p8_open_file=p; launch("/apps/p8.lua") end end)(path)
        else
          act = (function(p) return function() quill_open_file=p; launch("/apps/quill.lua") end end)(path)
        end
        add(label, e.is_dir and 3 or 6, act)
      end
    end
  end
end
refresh_desktop()

local mouse_prev  = false
local mbtn1_prev  = false
local icon_flash  = {}

-- ── Close / maximize helpers ──────────────────────────────────────────────────
local win_saved = {}

local function close_app(app, win)
  for i, a in ipairs(app_list) do
    if a == app then table.remove(app_list, i); break end
  end
  if app._pid and app._pid >= 0 and sys.proc_free then sys.proc_free(app._pid) end
  local aname = app.name or "app"
  if ipc and ipc.close then ipc.close(aname) end
  win_saved[win] = nil
  wm.close(win)
  if focused_app == app then focused_app = nil end
end

local function toggle_maximize(win, app)
  if not win then return end
  local saved = win_saved[win]
  if saved then
    wm.resize(win, saved.w, saved.h)
    wm.move(win, saved.x, saved.y)
    win_saved[win] = nil
  else
    local wx, wy, ww, wh = wm.rect(win)
    win_saved[win] = {x=wx, y=wy, w=ww, h=wh}
    wm.resize(win, SCREEN_W - 2*WM_B, SCREEN_H - TB_H - WM_TH - 2*WM_B)
    wm.move(win, WM_B, WM_TH + WM_B)
  end
  set_focus(app, win)
end

-- ── Right-click context menu ──────────────────────────────────────────────────
local ctx_menu = nil

local function ctx_close() ctx_menu = nil end
local function ctx_open(x, y, items) ctx_menu = {x=x, y=y, items=items} end

local CTX_W, CTX_IH = 120, 12

local function ctx_hit(mx, my)
  if not ctx_menu then return nil end
  if mx < ctx_menu.x or mx >= ctx_menu.x + CTX_W then return nil end
  local i = math.floor((my - ctx_menu.y) / CTX_IH) + 1
  if i >= 1 and i <= #ctx_menu.items then
    if ctx_menu.items[i].label == "---" then return nil end
    return i
  end
end

local function ctx_click(mx, my)
  if not ctx_menu then return false end
  local i = ctx_hit(mx, my)
  if i then ctx_menu.items[i].action(); ctx_close(); return true end
  ctx_close(); return false
end

local function ctx_draw()
  if not ctx_menu then return end
  local x, y = ctx_menu.x, ctx_menu.y
  local h = #ctx_menu.items * CTX_IH + 2
  gfx.rect(x-1, y-1, CTX_W+2, h+2, 9)
  gfx.rect(x, y, CTX_W, h, 2)
  local mx, my = mouse.x(), mouse.y()
  for i, item in ipairs(ctx_menu.items) do
    local iy = y + (i-1)*CTX_IH + 1
    if item.label == "---" then
      gfx.rect(x+2, iy + CTX_IH//2, CTX_W-4, 1, 9)
    else
      if ctx_hit(mx, my) == i then gfx.rect(x, iy, CTX_W, CTX_IH, 3) end
      gfx.print(item.label, x+4, iy+2, 7)
    end
  end
end

local function desktop_ctx(mx, my)
  ctx_open(mx, my, {
    { label="New folder", action=function()
        if not fs.exists("/home") then fs.mkdir("/home") end
        if not fs.exists("/home/desktop") then fs.mkdir("/home/desktop") end
        local n = "/home/desktop/newfolder"; local i = 1
        while fs.exists(n..i) do i=i+1 end
        fs.mkdir(n..i)
    end },
    { label="Open terminal", action=function() launch("/apps/terminal.lua") end },
    { label="Open files",    action=function() launch("/apps/files.lua")    end },
    { label="---" },
    { label="Restart",  action=function() sys.reboot()   end },
    { label="Shut down", action=function() sys.shutdown() end },
  })
end

local function icon_at(mx, my)
  for _, ic in ipairs(icons) do
    if mx >= ic.x and mx < ic.x+ICON_W and my >= ic.y and my < ic.y+ICON_H+CH then
      return ic
    end
  end
end

-- ── Window hit detection ──────────────────────────────────────────────────────
local drag_win,   drag_ox,    drag_oy
local resize_win, resize_app, resize_edge
local resize_ox,  resize_oy,  resize_orig_w, resize_orig_h
local MIN_W, MIN_H = 80, 40

local function chrome_btn_hit(win, mx, my)
  local wx, wy, ww = wm.rect(win)
  local btn_r = wx + ww - 2
  local btn_y = wy - WM_TH - WM_B + (WM_TH - 10) // 2
  if my < btn_y or my >= btn_y + 10 then return nil end
  if mx >= btn_r - 12 and mx < btn_r      then return "close"   end
  if mx >= btn_r - 26 and mx < btn_r - 14 then return "restore" end
  if mx >= btn_r - 40 and mx < btn_r - 28 then return "minimize" end
  return nil
end

local function win_title_hit(win, mx, my)
  local wx, wy, ww = wm.rect(win)
  if chrome_btn_hit(win, mx, my) then return false end
  return mx >= wx-WM_B and mx < wx+ww+WM_B and my >= wy-WM_TH-WM_B and my < wy
end

local function win_any_hit(win, mx, my)
  local wx, wy, ww, wh = wm.rect(win)
  return mx >= wx-WM_B and mx < wx+ww+WM_B and my >= wy-WM_TH-WM_B and my < wy+wh+WM_B
end

local RESIZE_GRAB = 5
local function resize_zone(win, mx, my)
  local wx, wy, ww, wh = wm.rect(win)
  local on_r = mx >= wx+ww-1 and mx < wx+ww+RESIZE_GRAB
  local on_b = my >= wy+wh-1 and my < wy+wh+RESIZE_GRAB
  if on_r and on_b then return "corner" end
  if on_r then return "right" end
  if on_b then return "bottom" end
end

-- ── Taskbar ───────────────────────────────────────────────────────────────────
local BTN_W  = 80
local HOME_W = 24
local function taskbar_btn_x(i) return HOME_W + 8 + (i-1)*(BTN_W+4) end

local function build_all_wins()
  local all = {}
  for _, a in ipairs(app_list) do
    if a.win then all[#all+1] = {name=(a.name or "app"), win=a.win, app=a} end
  end
  table.sort(all, function(a, b) return wm.z(a.win) < wm.z(b.win) end)
  return all
end

local function taskbar_click(mx, my)
  local tb_y = SCREEN_H - TB_H
  if my < tb_y then return end
  if mx >= 4 and mx < 4+HOME_W then
    local all = build_all_wins()
    local any = false
    for _, e in ipairs(all) do if not wm.is_minimized(e.win) then any=true; break end end
    for _, e in ipairs(all) do wm.minimize(e.win, any) end
    if any then focused_app = nil end
    return
  end
  local all = build_all_wins()
  for i, entry in ipairs(all) do
    local bx = taskbar_btn_x(i)
    if mx >= bx and mx < bx+BTN_W then
      if wm.is_minimized(entry.win) then wm.minimize(entry.win, false) end
      set_focus(entry.app, entry.win)
      return
    end
  end
end

-- ── Main update ───────────────────────────────────────────────────────────────
function _update()
  -- refresh desktop icons ~every 2 seconds
  if pit_ticks() - last_desk_scan > 120 then
    refresh_desktop(); last_desk_scan = pit_ticks()
  end

  -- animate dropdown terminal
  local target_y = term_open and 0 or -TERM_H
  if term_y < target_y then term_y = math.min(term_y + 20, target_y)
  elseif term_y > target_y then term_y = math.max(term_y - 20, target_y) end

  local mx, my = mouse.x(), mouse.y()
  local mbtn   = mouse.btn(0)
  local mbtn1  = mouse.btn(1)

  for k, v in pairs(icon_flash) do
    icon_flash[k] = v - 1
    if icon_flash[k] <= 0 then icon_flash[k] = nil end
  end

  -- terminal bottom-edge drag
  local GRIP = 5   -- grab zone pixels above/below edge
  if term_is_visible() then
    local edge_y = term_y + TERM_H + 2   -- center of grip bar
    if mbtn and not mouse_prev and math.abs(my - edge_y) <= GRIP then
      term_drag = true
      term_drag_start_y = my
      term_drag_start_h = TERM_H
    end
  end
  if term_drag then
    if mbtn then
      TERM_H = math.max(TERM_MIN_H, math.min(TERM_MAX_H,
               term_drag_start_h + (my - term_drag_start_y)))
    else
      term_drag = false
    end
  end

  -- window drag / resize (only when terminal not blocking mouse)
  local term_blocks_mouse = term_is_visible() and my < term_y + TERM_H + GRIP
  if not term_blocks_mouse and not term_drag then
    if mbtn then
      if not drag_win and not resize_win then
        local all_wins = build_all_wins()
        for i = #all_wins, 1, -1 do
          local w = all_wins[i]
          if not wm.is_minimized(w.win) then
            local zone = resize_zone(w.win, mx, my)
            if zone then
              local wx, wy, ww, wh = wm.rect(w.win)
              resize_win=w.win; resize_app=w.app; resize_edge=zone
              resize_ox=mx; resize_oy=my; resize_orig_w=ww; resize_orig_h=wh
              set_focus(w.app, w.win); break
            end
          end
        end
        if not resize_win then
          for i = #all_wins, 1, -1 do
            local w = all_wins[i]
            if not wm.is_minimized(w.win) then
              local grab = win_title_hit(w.win, mx, my)
                        or (input.key_down("lalt") and win_any_hit(w.win, mx, my))
              if grab then
                local wx, wy = wm.rect(w.win)
                drag_win=w.win; drag_ox=mx-wx; drag_oy=my-wy
                set_focus(w.app, w.win); break
              end
            end
          end
        end
      end
      if resize_win then
        local dx, dy = mx-resize_ox, my-resize_oy
        local nw, nh = resize_orig_w, resize_orig_h
        if resize_edge=="right"  or resize_edge=="corner" then nw=math.max(MIN_W,nw+dx) end
        if resize_edge=="bottom" or resize_edge=="corner" then nh=math.max(MIN_H,nh+dy) end
        wm.resize(resize_win, nw, nh)
      end
      if drag_win then wm.move(drag_win, mx-drag_ox, my-drag_oy) end
    else
      drag_win=nil; resize_win=nil
    end

    -- left click
    if mbtn and not mouse_prev then
      taskbar_click(mx, my)
      if my < SCREEN_H - TB_H then
        if not drag_win then
          local all_wins = build_all_wins()
          local hit = false
          for i = #all_wins, 1, -1 do
            local w = all_wins[i]
            if not wm.is_minimized(w.win) and win_any_hit(w.win, mx, my) then
              local btn = chrome_btn_hit(w.win, mx, my)
              if btn == "close" then
                close_app(w.app, w.win)
              elseif btn == "minimize" then
                wm.minimize(w.win, true)
                if focused_app == w.app then focused_app = nil end
              elseif btn == "restore" then
                toggle_maximize(w.win, w.app)
              else
                set_focus(w.app, w.win)
              end
              hit = true; break
            end
          end
          if not hit then
            if ctx_menu then ctx_click(mx, my)
            else
              local ic = icon_at(mx, my)
              if ic then icon_flash[ic.label]=12; ic.action() end
            end
          end
        end
      end
    end

    -- right click
    if mbtn1 and not mbtn1_prev then
      local tb_y = SCREEN_H - TB_H
      if my >= tb_y then
        local all = build_all_wins()
        for i, entry in ipairs(all) do
          local bx = taskbar_btn_x(i)
          if mx >= bx and mx < bx+BTN_W then
            close_app(entry.app, entry.win); break
          end
        end
      else
        local all_wins = build_all_wins()
        local on_win = false
        for i = #all_wins, 1, -1 do
          local w = all_wins[i]
          if not wm.is_minimized(w.win) and win_any_hit(w.win, mx, my) then
            on_win=true; break
          end
        end
        if not on_win then desktop_ctx(mx, my) end
      end
    end
  end -- not term_blocks_mouse

  mouse_prev  = mbtn
  mbtn1_prev  = mbtn1

  -- keyboard
  local c = input.getchar()
  while c do
    if c == "`" or c == "~" then
      term_toggle()
    elseif c == "\x13" then  -- Ctrl+S: save VFS to disk
      local ok, err = sys.save()
      if ok then push("sys: saved to disk", COL_DIM)
      else push("sys: save failed: "..(err or "?"), COL_WARN) end
    elseif c == "\x0f" then   -- F4: close focused app (not terminal)
      if focused_app then close_app(focused_app, focused_app.win) end
    elseif focused_app and focused_app.input then
      focused_app.input(c)
    elseif not focused_app and term_open then
      -- terminal keyboard
      if write_mode then
        if c == "\x1b" then
          write_mode=false; write_file=nil; write_buf={}; input_line=""
          push("-- cancelled --", COL_DIM)
        elseif c == "\n" then
          if input_line == "." then
            local content = table.concat(write_buf, "\n")
            if #write_buf > 0 then content=content.."\n" end
            if fs.write(write_file, content) then
              push("-- saved ("..#content.." bytes) --", COL_DIM)
            else push("-- write failed --", COL_WARN) end
            write_mode=false; write_file=nil; write_buf={}
          else
            write_buf[#write_buf+1] = input_line
            push(input_line)
          end
          input_line=""
        elseif c == "\b" then
          if #input_line > 0 then input_line=input_line:sub(1,-2) end
        elseif c >= " " then input_line=input_line..c end
      else
        if c == "\n" then
          exec(input_line); input_line=""
        elseif c == "\b" then
          if #input_line > 0 then input_line=input_line:sub(1,-2) end
        elseif c == "\x01" then
          if #history > 0 then
            hist_idx=math.min(hist_idx+1, #history)
            input_line=history[#history-hist_idx+1]
          end
        elseif c == "\x02" then
          if hist_idx > 0 then
            hist_idx=hist_idx-1
            input_line=hist_idx==0 and "" or history[#history-hist_idx+1]
          end
        elseif c >= " " then
          if #input_line < COLS-4 then input_line=input_line..c end
        end
      end
    end
    c = input.getchar()
  end

  local i = 1
  while i <= #app_list do
    local a = app_list[i]
    if a.update then
      local pid, aname = a._pid or -1, a.name or "app"
      if pid >= 0 and sys.sched_begin then sys.sched_begin(pid, aname) end
      local ok, err = pcall(a.update)
      if pid >= 0 and sys.sched_end then sys.sched_end(pid) end
      if not ok then
        push("app "..aname..": "..tostring(err), COL_WARN)
        close_app(a, a.win)
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- dispatch IPC messages to apps that have a _msg handler
  if ipc and ipc.pending and ipc.recv then
    for _, a in ipairs(app_list) do
      if a._msg then
        local aname = a.name or "app"
        while ipc.pending(aname) do
          local from, data = ipc.recv(aname)
          if not from then break end
          local ok, err = pcall(a._msg, from, data)
          if not ok then push("ipc "..aname..": "..tostring(err), COL_WARN) end
        end
      end
    end
  end
end

-- ── Main draw ─────────────────────────────────────────────────────────────────
function _draw()
  gfx.cls(1)

  -- desktop icons
  local hx, hy = mouse.x(), mouse.y()
  for _, ic in ipairs(icons) do
    local hover    = hx>=ic.x and hx<ic.x+ICON_W and hy>=ic.y and hy<ic.y+ICON_H
    local flashing = icon_flash[ic.label] and icon_flash[ic.label]>0
    local bg_col   = flashing and 7 or (hover and ic.col+1 or ic.col)
    gfx.rect(ic.x, ic.y, ICON_W, ICON_H, bg_col)
    if hover or flashing then
      gfx.rect(ic.x,         ic.y,         ICON_W, 1, 7)
      gfx.rect(ic.x,         ic.y+ICON_H-1,ICON_W, 1, 7)
      gfx.rect(ic.x,         ic.y,         1, ICON_H, 7)
      gfx.rect(ic.x+ICON_W-1,ic.y,         1, ICON_H, 7)
    end
    gfx.rect(ic.x+ICON_W//2-1, ic.y+4,          3, ICON_H-8, flashing and 1 or 7)
    gfx.rect(ic.x+4,            ic.y+ICON_H//2-1,ICON_W-8, 3, flashing and 1 or 7)
    gfx.print(ic.label, ic.x, ic.y+ICON_H+2, 7)
  end

  -- app windows (no scheduler budget on draw — bounded by screen pixels)
  local i = 1
  while i <= #app_list do
    local a = app_list[i]
    if a.draw then
      local aname = a.name or "app"
      local ok, err = pcall(a.draw)
      if not ok then
        push("app "..aname..": "..tostring(err), COL_WARN)
        close_app(a, a.win)
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- composite
  wm.present()

  -- taskbar
  local tb_y = SCREEN_H - TB_H
  gfx.rect(0, tb_y, SCREEN_W, TB_H, 2)
  gfx.rect(0, tb_y, SCREEN_W, 1, 9)
  gfx.rect(4, tb_y+3, HOME_W, TB_H-5, 3)
  gfx.print("[]", 8, tb_y+6, 7)
  local all = build_all_wins()
  for i, entry in ipairs(all) do
    local bx = taskbar_btn_x(i)
    local is_f = (focused_app == entry.app)
    local is_m = wm.is_minimized(entry.win)
    gfx.rect(bx, tb_y+3, BTN_W, TB_H-5, is_f and 5 or (is_m and 2 or 3))
    local lbl = entry.name..(win_saved[entry.win] and " ^" or "")
    gfx.print(lbl, bx+4, tb_y+6, is_m and 8 or 7)
  end
  -- disk indicator (right of taskbar, left of clock)
  local disk_x = SCREEN_W - 80
  if sys.disk_ready and sys.disk_ready() then
    gfx.rect(disk_x, tb_y+4, 3*CW+2, TB_H-8, 16)
    gfx.print("HDD", disk_x+1, tb_y+6, 7)
  end

  if unread_errors > 0 then
    local flash = (math.floor(pit_ticks()/20) % 2) == 0
    local badge = "!"..unread_errors
    local bx = SCREEN_W - #badge*CW - 4
    if flash then gfx.rect(bx-2, tb_y+2, #badge*CW+3, TB_H-4, COL_WARN) end
    gfx.print(badge, bx, tb_y+6, flash and 7 or COL_WARN)
    local s = pit_ticks()//60
    local clock = string.format("%02d:%02d:%02d", (s//3600)%24, (s//60)%60, s%60)
    gfx.print(clock, bx - #clock*CW - 6, tb_y+6, 7)
  else
    local s = pit_ticks()//60
    local clock = string.format("%02d:%02d:%02d", (s//3600)%24, (s//60)%60, s%60)
    gfx.print(clock, SCREEN_W-#clock*8-4, tb_y+6, 7)
  end

  -- context menu
  ctx_draw()

  -- ── dropdown terminal ─────────────────────────────────────────────────────
  if term_is_visible() then
    local ty = term_y
    -- panel
    gfx.rect(0, ty, SCREEN_W, TERM_H, COL_BG)
    -- scanline tint (every other row slightly lighter — cheap look)
    -- bottom grip bar (below the text area)
    local grip_col = term_drag and 7 or 9
    gfx.rect(0, ty+TERM_H,   SCREEN_W, 4, grip_col)
    local mid = SCREEN_W // 2
    for i = -3, 3 do
      gfx.rect(mid + i*10, ty+TERM_H+1, 4, 2, term_drag and 1 or 7)
    end
    gfx.rect(0, ty+TERM_H+4, SCREEN_W, 1, 11)

    -- text rows
    local rows_vis = math.floor(TERM_H / CH) - 1   -- leave one row for prompt
    local start    = math.max(1, #lines - (rows_vis - 1))
    for i = start, #lines do
      local row_y = ty + (i - start) * CH
      if row_y >= ty and row_y < ty + TERM_H - CH then
        gfx.print(lines[i].text, 2, row_y, lines[i].col)
      end
    end

    -- prompt
    local py = ty + TERM_H - CH
    local prompt, prompt_col
    if write_mode then
      local fname = write_file and write_file:match("[^/]+$") or "?"
      prompt = "write:"..fname.."> "; prompt_col = COL_WARN
    else
      prompt = (cwd=="/" and "/" or cwd:match("[^/]+$").."/").."> "
      prompt_col = COL_PROMPT
    end
    gfx.print(prompt..input_line, 2, py, prompt_col)
    -- cursor blink (only when terminal has keyboard focus)
    if not focused_app and (math.floor(pit_ticks()/30) % 2) == 0 then
      gfx.rect(2 + (#prompt+#input_line)*CW, py, 2, CH-1, COL_FG)
    end
  end

  -- cursor always on top
  wm.draw_cursor()
end
