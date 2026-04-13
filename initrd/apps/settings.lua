-- settings.lua — momOS system settings
local WIN_W, WIN_H = 420, 280
local win = wm.open("settings", 80, 60, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8

-- ── Layout ────────────────────────────────────────────────────────────────────
local TB_H    = CH + 4
local SB_H    = CH + 4
local CAT_W   = 80
local BODY_X  = CAT_W + 1
local BODY_W  = WIN_W - CAT_W - 1
local BODY_Y  = TB_H
local BODY_H  = WIN_H - TB_H - SB_H

-- ── Colors ────────────────────────────────────────────────────────────────────
local C_BG     = 0
local C_PANEL  = 2
local C_FG     = 7
local C_DIM    = 8
local C_SEL    = 3
local C_BORDER = 9
local C_ACTIVE = 15
local C_WARN   = 4

-- ── Settings reference ────────────────────────────────────────────────────────
local cfg = _G.momos_settings  -- live reference; changes here affect main.lua too

local function save_settings()
  local parts = { "return {\n" }
  parts[#parts+1] = string.format("  clock_format = %q,\n", cfg.clock_format)
  parts[#parts+1] = string.format("  tz_offset    = %d,\n", cfg.tz_offset)
  parts[#parts+1] = string.format("  wallpaper    = %d,\n", cfg.wallpaper)
  parts[#parts+1] = string.format("  theme        = %q,\n", cfg.theme)
  if cfg.manual_time then
    local mt = cfg.manual_time
    parts[#parts+1] = string.format(
      "  manual_time  = {year=%d,month=%d,day=%d,hour=%d,min=%d,sec=%d},\n",
      mt.year, mt.month, mt.day, mt.hour, mt.min, mt.sec)
  end
  parts[#parts+1] = "}\n"
  fs.write("/sys/settings.lua", table.concat(parts))
end

-- ── Category list ─────────────────────────────────────────────────────────────
local categories = { "Clock", "Display", "Theme", "Audio", "System" }
local cur_cat = 1
local status = ""; local status_t = 0
local function set_status(s) status = s; status_t = 120 end

-- ── Swatch helpers ────────────────────────────────────────────────────────────
local function draw_swatch(x, y, w, h, idx, border)
  if border then gfx.rect(x-1, y-1, w+2, h+2, border) end
  gfx.rect(x, y, w, h, idx)
end

-- ── Spin-button helper ────────────────────────────────────────────────────────
-- draws [<] value [>] at (x,y), returns x after the widget
local function spin(x, y, val, fmt_str, col)
  gfx.rect(x, y, 14, CH+4, C_PANEL); gfx.print("<", x+3, y+2, C_FG); x = x+16
  local vs = string.format(fmt_str, val)
  gfx.print(vs, x, y+2, col or C_ACTIVE); x = x + #vs*CW + 2
  gfx.rect(x, y, 14, CH+4, C_PANEL); gfx.print(">", x+3, y+2, C_FG); x = x+16
  return x
end

-- ── Draw: Clock ───────────────────────────────────────────────────────────────
local function draw_clock()
  local x0, y = BODY_X + 8, BODY_Y + 8

  -- Format
  gfx.print("Format", x0, y, C_DIM); y = y + CH + 3
  local bg24 = cfg.clock_format == "24h" and C_SEL or C_PANEL
  local bg12 = cfg.clock_format == "12h" and C_SEL or C_PANEL
  gfx.rect(x0,    y, 36, CH+4, bg24); gfx.print("24h", x0+4,    y+2, cfg.clock_format=="24h" and C_ACTIVE or C_FG)
  gfx.rect(x0+42, y, 36, CH+4, bg12); gfx.print("12h", x0+46,   y+2, cfg.clock_format=="12h" and C_ACTIVE or C_FG)
  y = y + CH + 10

  -- Time source
  gfx.print("Source", x0, y, C_DIM); y = y + CH + 3
  local bgrtc = (not cfg.manual_time) and C_SEL or C_PANEL
  local bgman = cfg.manual_time       and C_SEL or C_PANEL
  gfx.rect(x0,    y, 36, CH+4, bgrtc); gfx.print("RTC",    x0+4,    y+2, (not cfg.manual_time) and C_ACTIVE or C_FG)
  gfx.rect(x0+42, y, 48, CH+4, bgman); gfx.print("Manual", x0+46,   y+2, cfg.manual_time       and C_ACTIVE or C_FG)
  y = y + CH + 10

  -- Timezone (only for RTC mode)
  if not cfg.manual_time then
    gfx.print("Timezone UTC", x0, y, C_DIM)
    local tx = x0 + 13*CW
    gfx.rect(tx, y, 14, CH+4, C_PANEL); gfx.print("<", tx+3, y+2, C_FG)
    local tzs = string.format("%+d", cfg.tz_offset)
    gfx.print(tzs, tx+16, y+2, C_ACTIVE)
    gfx.rect(tx+16+#tzs*CW+2, y, 14, CH+4, C_PANEL)
    gfx.print(">", tx+16+#tzs*CW+5, y+2, C_FG)
    y = y + CH + 10
  else
    -- Manual date/time editor
    local mt = cfg.manual_time
    gfx.print("Date", x0, y, C_DIM); y = y + CH + 3
    local cx = x0
    cx = spin(cx, y, mt.year,  "%04d"); gfx.print("-", cx, y+2, C_DIM); cx = cx+CW+2
    cx = spin(cx, y, mt.month, "%02d"); gfx.print("-", cx, y+2, C_DIM); cx = cx+CW+2
    cx = spin(cx, y, mt.day,   "%02d")
    y = y + CH + 10

    gfx.print("Time", x0, y, C_DIM); y = y + CH + 3
    cx = x0
    cx = spin(cx, y, mt.hour, "%02d"); gfx.print(":", cx, y+2, C_DIM); cx = cx+CW+2
    cx = spin(cx, y, mt.min,  "%02d"); gfx.print(":", cx, y+2, C_DIM); cx = cx+CW+2
    cx = spin(cx, y, mt.sec,  "%02d")
    y = y + CH + 8
  end

  -- Preview
  local ph, pm, ps, py, pmo, pd = (_G.clock_hms or function() return 0,0,0,0,0,0 end)()
  local pstr
  if cfg.clock_format == "12h" then
    local ap = ph >= 12 and "PM" or "AM"
    ph = ph % 12; if ph == 0 then ph = 12 end
    pstr = string.format("%d:%02d:%02d %s", ph, pm, ps, ap)
  else
    pstr = string.format("%02d:%02d:%02d", ph, pm, ps)
  end
  gfx.print("Now: "..pstr, x0, y, C_ACTIVE)
  if py and py > 0 then
    y = y + CH + 2
    gfx.print(string.format("     %04d-%02d-%02d", py, pmo, pd), x0, y, C_DIM)
  end
end

-- ── Draw: Display ─────────────────────────────────────────────────────────────
local function draw_display()
  local x, y = BODY_X + 8, BODY_Y + 10
  gfx.print("Wallpaper color", x, y, C_DIM); y = y + CH + 6
  -- 16 palette swatches in 2 rows
  for i = 0, 15 do
    local sx = x + (i % 8) * 18
    local sy = y + (i // 8) * 18
    local border = (i == cfg.wallpaper) and C_ACTIVE or nil
    draw_swatch(sx, sy, 14, 14, i, border)
  end
  y = y + 44

  gfx.print("Resolution", x, y, C_DIM)
  gfx.print(SCREEN_W.."x"..SCREEN_H, x + 80, y, C_ACTIVE)
  y = y + CH + 4
  gfx.print("(change via GRUB gfxmode — needs reflash)", x, y, C_DIM)
end

-- ── Theme names/labels ────────────────────────────────────────────────────────
local theme_list = {
  { id="dark",   label="Dark Navy"     },
  { id="green",  label="Green Terminal"},
  { id="amber",  label="Amber Terminal"},
  { id="light",  label="Light"         },
  { id="purple", label="Deep Purple"   },
}

-- ── Draw: Theme ───────────────────────────────────────────────────────────────
local function draw_theme()
  local x, y = BODY_X + 8, BODY_Y + 10
  gfx.print("Color theme", x, y, C_DIM); y = y + CH + 6
  for i, t in ipairs(theme_list) do
    local is_cur = (t.id == cfg.theme)
    local bg = is_cur and C_SEL or C_PANEL
    gfx.rect(x, y, BODY_W - 20, CH + 4, bg)
    -- preview swatches: first 8 UI colors
    local pal = _G.momos_themes[t.id]
    if pal then
      for j = 0, 7 do
        -- temporarily draw color swatches using theme RGB values
        -- We can't set_pal temporarily, so just show current palette entry
        -- Instead, show a label and the current active state
      end
    end
    gfx.print((is_cur and "> " or "  ")..t.label,
              x + 4, y + 2, is_cur and C_ACTIVE or C_FG)
    y = y + CH + 6
  end
  y = y + 4
  gfx.print("Theme applies immediately.", x, y, C_DIM)
end

-- ── Draw: Audio ───────────────────────────────────────────────────────────────
local function draw_audio()
  local x, y = BODY_X + 8, BODY_Y + 10
  local backend = sys.audio_info and sys.audio_info() or "unknown"
  gfx.print("Audio backend", x, y, C_DIM)
  gfx.print(backend, x + 104, y, C_ACTIVE)
  y = y + CH + 10
  -- test tone button
  gfx.rect(x, y, 80, CH+4, C_PANEL)
  gfx.print("Test tone", x+4, y+2, C_FG)
  y = y + CH + 14
  gfx.print("Channels: 4 software (22050 Hz, 8-bit mono)", x, y, C_DIM)
  y = y + CH + 4
  if backend == "none (PC speaker)" then
    gfx.print("PC speaker only — no melody tracker audio", x, y, C_WARN)
  end
end

-- ── Draw: System ──────────────────────────────────────────────────────────────
local function draw_system()
  local x, y = BODY_X + 8, BODY_Y + 10
  local function row(label, val)
    gfx.print(label, x, y, C_DIM)
    gfx.print(tostring(val), x + 96, y, C_ACTIVE)
    y = y + CH + 4
  end
  local free_b, total_b = sys.mem()
  local free_k  = math.floor(free_b  / 1024)
  local total_k = math.floor(total_b / 1024)
  row("Resolution",   SCREEN_W.."x"..SCREEN_H)
  row("Memory free",  free_k.." KB / "..total_k.." KB")
  row("Audio",        sys.audio_info and sys.audio_info() or "?")
  row("Disk",         sys.disk_ready and (sys.disk_ready() and "HDD ready" or "no disk") or "?")
  row("Time source",  cfg.manual_time and "Manual" or "RTC (hardware)")
  local rt = sys.time and sys.time()
  if rt then
    row("RTC date",   string.format("%04d-%02d-%02d", rt.year, rt.month, rt.day))
  end
  row("Kernel",       "momOS i686 / Lua 5.4")
end

-- ── Main draw ─────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(C_BG)

  -- toolbar
  gfx.rect(0, 0, WIN_W, TB_H, C_PANEL)
  gfx.print("Settings", 4, 2, C_FG)

  -- category sidebar
  gfx.rect(0, TB_H, CAT_W, WIN_H - TB_H, C_PANEL)
  gfx.rect(CAT_W, TB_H, 1, WIN_H - TB_H, C_BORDER)
  for i, name in ipairs(categories) do
    local cy = BODY_Y + (i-1) * (CH + 8) + 4
    local is_cur = (i == cur_cat)
    if is_cur then gfx.rect(0, cy - 2, CAT_W, CH + 4, C_SEL) end
    gfx.print(name, 4, cy, is_cur and C_ACTIVE or C_FG)
  end

  -- body panel
  gfx.rect(BODY_X, TB_H, BODY_W, BODY_H, C_BG)

  local cat = categories[cur_cat]
  if     cat == "Clock"   then draw_clock()
  elseif cat == "Display" then draw_display()
  elseif cat == "Theme"   then draw_theme()
  elseif cat == "Audio"   then draw_audio()
  elseif cat == "System"  then draw_system()
  end

  -- status bar
  local sy = WIN_H - SB_H
  gfx.rect(0, sy, WIN_W, SB_H, C_PANEL)
  gfx.rect(0, sy, WIN_W, 1, C_BORDER)
  if status_t > 0 then
    gfx.print(status, 4, sy + 2, C_DIM)
  else
    gfx.print("click to change  |  changes saved automatically", 4, sy + 2, C_DIM)
  end

  wm.unfocus()
end

-- ── Input helpers (hit testing) ───────────────────────────────────────────────
local prev_btn = false

local function hit(lx, ly, x, y, w, h)
  return lx >= x and lx < x+w and ly >= y and ly < y+h
end

-- clamp helper
local days_in = {31,28,31,30,31,30,31,31,30,31,30,31}
local function clamp_day(mt)
  local max = days_in[mt.month] or 30
  if mt.month == 2 and mt.year % 4 == 0 then max = 29 end
  mt.day = math.max(1, math.min(max, mt.day))
end

-- spin-widget hit test: returns -1 (left arrow), 1 (right arrow), or nil
-- x = left edge of [<], val_str = formatted value
local function spin_hit(lx, ly, x, y, val_str)
  local bh = CH + 4
  if ly < y or ly >= y + bh then return nil end
  if lx >= x and lx < x+14 then return -1 end
  local vx = x + 16 + #val_str*CW + 2
  if lx >= vx and lx < vx+14 then return 1 end
  return nil
end

local function handle_clock_click(lx, ly)
  local x0, y = BODY_X + 8, BODY_Y + 8
  -- Format row
  y = y + CH + 3
  if hit(lx, ly, x0, y, 36, CH+4) then
    cfg.clock_format = "24h"; save_settings(); set_status("saved"); return
  end
  if hit(lx, ly, x0+42, y, 36, CH+4) then
    cfg.clock_format = "12h"; save_settings(); set_status("saved"); return
  end
  y = y + CH + 10

  -- Source row
  y = y + CH + 3
  if hit(lx, ly, x0, y, 36, CH+4) then      -- RTC
    cfg.manual_time = nil; save_settings(); set_status("using RTC"); return
  end
  if hit(lx, ly, x0+42, y, 48, CH+4) then   -- Manual
    if not cfg.manual_time then
      -- seed with current RTC or zeros
      local rt = sys.time and sys.time() or {year=2000,month=1,day=1,hour=0,min=0,sec=0}
      cfg.manual_time = {year=rt.year,month=rt.month,day=rt.day,
                         hour=rt.hour,min=rt.min,sec=rt.sec}
      cfg.manual_pit0 = pit_ticks()
    end
    save_settings(); set_status("manual time active"); return
  end
  y = y + CH + 10

  if not cfg.manual_time then
    -- Timezone row
    local tx = x0 + 13*CW
    if hit(lx, ly, tx, y, 14, CH+4) then
      cfg.tz_offset = math.max(-12, cfg.tz_offset-1); save_settings(); set_status("saved")
    end
    local tzs = string.format("%+d", cfg.tz_offset)
    if hit(lx, ly, tx+16+#tzs*CW+2, y, 14, CH+4) then
      cfg.tz_offset = math.min(14, cfg.tz_offset+1); save_settings(); set_status("saved")
    end
  else
    local mt = cfg.manual_time
    -- Date row
    y = y + CH + 3
    local cx = x0
    -- year
    local d = spin_hit(lx, ly, cx, y, string.format("%04d", mt.year))
    if d then mt.year = math.max(2000, math.min(2099, mt.year+d)); clamp_day(mt)
             cfg.manual_pit0 = pit_ticks(); save_settings(); set_status("saved") end
    cx = cx + 14+2 + 4*CW+2 + 14 + CW+2
    -- month
    d = spin_hit(lx, ly, cx, y, string.format("%02d", mt.month))
    if d then mt.month = (mt.month-1+d)%12+1; clamp_day(mt)
             cfg.manual_pit0 = pit_ticks(); save_settings(); set_status("saved") end
    cx = cx + 14+2 + 2*CW+2 + 14 + CW+2
    -- day
    d = spin_hit(lx, ly, cx, y, string.format("%02d", mt.day))
    if d then
      local max = days_in[mt.month] or 30
      if mt.month==2 and mt.year%4==0 then max=29 end
      mt.day = math.max(1, math.min(max, mt.day+d))
      cfg.manual_pit0 = pit_ticks(); save_settings(); set_status("saved")
    end
    y = y + CH + 10

    -- Time row
    y = y + CH + 3
    cx = x0
    -- hour
    d = spin_hit(lx, ly, cx, y, string.format("%02d", mt.hour))
    if d then mt.hour = (mt.hour+d)%24; cfg.manual_pit0=pit_ticks(); save_settings(); set_status("saved") end
    cx = cx + 14+2 + 2*CW+2 + 14 + CW+2
    -- min
    d = spin_hit(lx, ly, cx, y, string.format("%02d", mt.min))
    if d then mt.min = (mt.min+d)%60; cfg.manual_pit0=pit_ticks(); save_settings(); set_status("saved") end
    cx = cx + 14+2 + 2*CW+2 + 14 + CW+2
    -- sec
    d = spin_hit(lx, ly, cx, y, string.format("%02d", mt.sec))
    if d then mt.sec = (mt.sec+d)%60; cfg.manual_pit0=pit_ticks(); save_settings(); set_status("saved") end
  end
end

local function handle_display_click(lx, ly)
  local x, y = BODY_X + 8, BODY_Y + 10
  y = y + CH + 6
  for i = 0, 15 do
    local sx = x + (i % 8) * 18
    local sy = y + (i // 8) * 18
    if hit(lx, ly, sx, sy, 14, 14) then
      cfg.wallpaper = i; save_settings(); set_status("saved")
    end
  end
end

local function handle_theme_click(lx, ly)
  local x, y = BODY_X + 8, BODY_Y + 10
  y = y + CH + 6
  for _, t in ipairs(theme_list) do
    if hit(lx, ly, x, y, BODY_W - 20, CH + 4) then
      _G.apply_theme(t.id)
      save_settings(); set_status("theme: "..t.label)
    end
    y = y + CH + 6
  end
end

local function handle_audio_click(lx, ly)
  local x, y = BODY_X + 8, BODY_Y + 10 + CH + 10
  if hit(lx, ly, x, y, 80, CH+4) and audio then
    audio.set(0, 0, 440, 180)  -- A4 square wave
    -- auto-stop after 30 frames handled by chirp's preview_timer pattern,
    -- but here we just set a short beep via a one-shot approach
  end
end

-- ── Update ────────────────────────────────────────────────────────────────────
local test_timer = 0

local function update()
  if status_t > 0 then status_t = status_t - 1 end
  if test_timer > 0 then
    test_timer = test_timer - 1
    if test_timer == 0 and audio then audio.stop(0) end
  end

  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)
  local lx, ly = mx - wx, my - wy
  local btn = mouse.btn(0)

  if btn and not prev_btn then
    -- category sidebar
    for i = 1, #categories do
      local cy = BODY_Y + (i-1) * (CH + 8) + 2
      if hit(lx, ly, 0, cy, CAT_W, CH + 8) then cur_cat = i end
    end
    -- body click
    if lx >= BODY_X then
      local cat = categories[cur_cat]
      if     cat == "Clock"   then handle_clock_click(lx, ly)
      elseif cat == "Display" then handle_display_click(lx, ly)
      elseif cat == "Theme"   then handle_theme_click(lx, ly)
      elseif cat == "Audio"   then
        handle_audio_click(lx, ly)
        test_timer = 30
      end
    end
  end
  prev_btn = btn
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  if c == "\x1b" then wm.close(win); return "quit" end
end

return { draw=draw, update=update, input=on_input, win=win, name="settings" }
