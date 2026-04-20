-- installer.lua
-- Fullscreen momOS installer. Launched via boot_mode=install cmdline.
-- Controls: arrow keys navigate, Enter/Y/N confirm.

local W, H = SCREEN_W, SCREEN_H

-- Colors (palette indices)
local BG    = 11   -- black
local FG    = 7    -- white
local HI    = 4    -- red/pink highlight
local DIM   = 8    -- gray
local OK    = 16   -- green

local state    = "welcome"
local drives   = {}
local sel      = 1
local errmsg   = nil
local progress = nil

-- ── Key debouncing ────────────────────────────────────────────────────────────
local key_last = {}
local function key_pressed(name)
    local t = sys.ticks()
    if input.key_down(name) then
        if not key_last[name] or t - key_last[name] > 15 then
            key_last[name] = t
            return true
        end
    else
        key_last[name] = nil
    end
    return false
end

-- ── Text helpers ──────────────────────────────────────────────────────────────
local function center_x(text, font_w)
    font_w = font_w or 8
    return math.floor((W - #text * font_w) / 2)
end

local function draw_centered(text, y, col)
    gfx.print(text, center_x(text), y, col or FG)
end

-- ── Drive info string ─────────────────────────────────────────────────────────
local function drive_label(d)
    return string.format("Drive %d  %4d MB  %s", d.index, d.size_mb, d.model)
end

-- ── Install steps (called once per frame when state == "install") ─────────────
local install_step  = 0
local install_drive = nil

local function do_install()
    local d = install_drive

    -- Step 0: announce and move to step 1
    if install_step == 0 then
        progress = "Partitioning drive " .. d.index .. "..."
        install_step = 1
        return
    end

    -- Step 1: write 2-partition MBR (FAT12 + LFS)
    if install_step == 1 then
        local disk_secs = d.size_mb * 2048
        local lfs_start = 18432
        local lfs_size  = disk_secs - lfs_start
        local ok, err = sys.disk_write_mbr2(d.index, 2048, 16384, lfs_start, lfs_size)
        if not ok then
            state = "error"; errmsg = "Partition failed: " .. (err or "?"); return
        end
        progress = "Formatting boot partition..."
        install_step = 2
        return
    end

    -- Step 2: format FAT12 at LBA 2048
    if install_step == 2 then
        local ok, err = sys.fat_format(d.index, 2048)
        if not ok then
            state = "error"; errmsg = "FAT format failed: " .. (err or "?"); return
        end
        progress = "Copying kernel..."
        install_step = 3
        return
    end

    -- Step 3: write kernel.bin to FAT partition
    if install_step == 3 then
        local kdata = fs.read("/sys/boot/kernel.bin")
        if not kdata then
            state = "error"; errmsg = "Missing /sys/boot/kernel.bin"; return
        end
        local ok, err = sys.fat_write(d.index, 2048, "kernel.bin", kdata)
        if not ok then
            state = "error"; errmsg = "kernel.bin write failed: " .. (err or "?"); return
        end
        progress = "Copying initrd..."
        install_step = 4
        return
    end

    -- Step 4: write live initrd.lfs to FAT partition
    if install_step == 4 then
        local ok, err = sys.fat_write_vfs(d.index, 2048, "initrd.lfs")
        if not ok then
            state = "error"; errmsg = "initrd.lfs write failed: " .. (err or "?"); return
        end
        progress = "Installing bootloader..."
        install_step = 5
        return
    end

    -- Step 5: write core.img to LBA 1–N
    if install_step == 5 then
        local core = fs.read("/sys/boot/core.img")
        if not core then
            state = "error"; errmsg = "Missing /sys/boot/core.img — run make grub-blobs"; return
        end
        local lba = 1
        for off = 1, #core, 512 do
            local chunk = core:sub(off, off + 511)
            local ok2, err2 = sys.disk_write_raw(d.index, lba, chunk)
            if not ok2 then
                state = "error"
                errmsg = "core.img write failed at LBA " .. lba .. ": " .. (err2 or "?")
                return
            end
            lba = lba + 1
        end
        progress = "Writing MBR boot code..."
        install_step = 6
        return
    end

    -- Step 6: write mbr.bin boot code to LBA 0 (bytes 0–445, preserves partition table)
    if install_step == 6 then
        local mbr_code = fs.read("/sys/boot/mbr.bin")
        if not mbr_code then
            state = "error"; errmsg = "Missing /sys/boot/mbr.bin — run make grub-blobs"; return
        end
        local ok, err = sys.disk_write_raw(d.index, 0, mbr_code)
        if not ok then
            state = "error"; errmsg = "MBR write failed: " .. (err or "?"); return
        end
        progress = "Saving user data to disk..."
        install_step = 7
        return
    end

    -- Step 7: persist user data to LFS partition 2
    if install_step == 7 then
        local ok, err = sys.save()
        if not ok then
            state = "error"; errmsg = "Save failed: " .. (err or "?"); return
        end
        progress = nil
        state    = "done"
        return
    end
end

-- ── Update ────────────────────────────────────────────────────────────────────
function _update()
    local ch = input.getchar()

    if state == "welcome" then
        if ch == "\r" or ch == "\n" or input.key_down("enter") then
            drives = sys.disk_scan()
            if #drives == 0 then
                state  = "error"
                errmsg = "No ATA drives detected. Boot on real hardware."
            else
                sel   = 1
                state = "select"
            end
        end

    elseif state == "select" then
        if key_pressed("up")   then sel = math.max(1, sel - 1) end
        if key_pressed("down") then sel = math.min(#drives, sel + 1) end
        if ch == "\r" or ch == "\n" then state = "confirm" end

    elseif state == "confirm" then
        if ch == "y" or ch == "Y" then
            install_drive = drives[sel]
            install_step  = 0
            state = "install"
        elseif ch == "n" or ch == "N" then
            state = "select"
        end

    elseif state == "install" then
        do_install()

    elseif state == "done" then
        if ch == "\r" or ch == "\n" then sys.reboot() end

    elseif state == "error" then
        if ch == "r" or ch == "R" then
            errmsg       = nil
            install_step = 0
            state        = "install"
        elseif ch == "q" or ch == "Q" then
            sys.reboot()
        end
    end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
function _draw()
    gfx.cls(BG)

    -- Header bar
    gfx.rect(0, 0, W, 20, 2)
    draw_centered("momOS Installer", 6, FG)

    local mid = math.floor(H / 2)

    if state == "welcome" then
        draw_centered("Welcome to momOS", mid - 30, FG)
        draw_centered("This will install momOS onto a hard drive.", mid - 14, DIM)
        draw_centered("All data on the selected drive will be erased.", mid, HI)
        draw_centered("[ Press ENTER to begin ]", mid + 24, OK)

    elseif state == "select" then
        draw_centered("Select a drive to install onto:", mid - 50, FG)
        for i, d in ipairs(drives) do
            local y   = mid - 20 + (i - 1) * 18
            local lbl = drive_label(d)
            local x   = center_x(lbl)
            if i == sel then
                gfx.rect(x - 4, y - 2, #lbl * 8 + 8, 14, FG)
                gfx.print(lbl, x, y, BG)
            else
                gfx.print(lbl, x, y, DIM)
            end
        end
        draw_centered("UP/DOWN to navigate  ENTER to select", mid + 60, DIM)

    elseif state == "confirm" then
        local lbl = drive_label(drives[sel])
        draw_centered("WARNING", mid - 40, HI)
        draw_centered("This will erase all data on:", mid - 20, FG)
        draw_centered(lbl, mid, HI)
        draw_centered("Continue?  Y = Yes    N = No", mid + 30, DIM)

    elseif state == "install" then
        draw_centered("Installing...", mid - 20, FG)
        if progress then draw_centered(progress, mid + 4, DIM) end

    elseif state == "done" then
        draw_centered("Installation complete!", mid - 20, OK)
        draw_centered("Remove install media and press ENTER to reboot.", mid + 4, DIM)

    elseif state == "error" then
        draw_centered("Installation failed.", mid - 20, HI)
        if errmsg then draw_centered(errmsg, mid + 4, DIM) end
        draw_centered("Press R to retry  or  Q to reboot.", mid + 24, DIM)
    end
end
