local o = {
    -- enables logging
    -- if disabled, shaders will default to the ones defined in mpv.conf on each launch and never remember changes
    -- the menu will still be able to detect which mode you're in and switch modes
    enable_logging = true,
    -- log file path, default in mpv config's root folder
    log_path = "~~home/auto4k.log",
    -- anime4k shaders path. if installed correctly in MPV/shaders/, don't touch anything
    shader_path = "~~/shaders/",
    -- auto displays the menu on an unrecognized file
    auto_run = true,
    -- draw a simple yes/no menu on unrecognized file, or all modes
    menu_yes_no = true,
    -- the mode that will be activated if you choose yes. A, B, C, A+A, B+B, or C+A
    default_yes_mode = "A",
    -- whether the choices will be in playlist scope by default or not
    default_playlist = true,
    -- include A+A, B+B, C+A modes in the choices
    include_secondary_modes = true,
    -- font size of the menu
    font_size = 100,
    -- cull oldest entries of the log if it goes beyond this number of lines
    max_log_lines = 1000
}
(require "mp.options").read_options(o)
local msg = require("mp.msg")
local utils = require("mp.utils")

o.log_path = mp.command_native({"expand-path", o.log_path})

--● / ○ (Geometric Shapes) and ➤ (Dingbats) aren't in the OSD font (Poppins), so
--without an explicit \fn they fall back to whatever font Windows picks for the
--glyph. Forcing Segoe UI Symbol keeps that consistent, and scaling them down a
--notch keeps their visual weight in line with the surrounding text.
local SYMBOL_FONT = "Segoe UI Symbol"
local function marker(glyph)
    local small = o.font_size * 0.75
    return string.format([[{\fn%s\fscx%f\fscy%f}%s{\fn\fscx%f\fscy%f}]],
        SYMBOL_FONT, small, small, glyph, o.font_size, o.font_size)
end

--adding the source directory to the package path and loading the module
--resolved relative to this script's own location so it works regardless of ~~ (config-dir)
local script_dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
package.path = script_dir .. "../script-modules/?.lua;" .. package.path
local list = require "scroll-list"

-- states
local is_file_loaded = false
local cur_file = ""
local cur_mode = ""
local is_playlist_scope = o.default_playlist
local playlist = nil

-- shaders names
local clamp = "Anime4K_Clamp_Highlights.glsl"
local rcnns_vl = "Anime4K_Restore_CNN_Soft_VL.glsl"
local rcnn_vl = "Anime4K_Restore_CNN_VL.glsl"
local rcnns_m = "Anime4K_Restore_CNN_Soft_M.glsl"
local rcnn_m = "Anime4K_Restore_CNN_M.glsl"
local ucnn_x2_vl = "Anime4K_Upscale_CNN_x2_VL.glsl"
local ucnn_x2_m = "Anime4K_Upscale_CNN_x2_M.glsl"
local adp_x2 = "Anime4K_AutoDownscalePre_x2.glsl"
local adp_x4 = "Anime4K_AutoDownscalePre_x4.glsl"
local udcnn_x2_vl = "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"

-- preset modes
local presets = {
    A = {clamp, rcnn_vl, ucnn_x2_vl, adp_x2, adp_x4, ucnn_x2_m},
    B = {clamp, rcnns_vl, ucnn_x2_vl, adp_x2, adp_x4, ucnn_x2_m},
    C = {clamp, udcnn_x2_vl, adp_x2, adp_x4, ucnn_x2_m},
    ["A+A"] = {clamp, rcnn_vl, ucnn_x2_vl, rcnn_m, adp_x2, adp_x4, ucnn_x2_m},
    ["B+B"] = {clamp, rcnns_vl, ucnn_x2_vl, adp_x2, adp_x4, rcnns_m, ucnn_x2_m},
    ["C+A"] = {clamp, udcnn_x2_vl, adp_x2, adp_x4, rcnn_m, ucnn_x2_m}
}

function log_mode(line)
    return line:match("%s:::%s(.+)$")
end

-- extracts the file path portion of a log line (everything before " ::: ")
-- used for exact-match lookups so one path can't false-positive match as a
-- substring of another (e.g. "S01E1.mkv" vs "S01E1.mkv.bak")
function log_path(line)
    return line:match("^(.-)%s:::%s")
end

function get_mode()
    local shaders = mp.get_property_native("glsl-shaders")
    if not shaders or #shaders < 1 then
        return "disabled"
    else
        for mode, list in pairs(presets) do
            if #shaders == #list then
                local match = true
                for i = 1, #list do
                    if shaders[i]:gsub(".*(Anime4K.*)", "%1") ~= list[i] then
                        match = false
                        break
                    end
                end
                if match then
                    return mode
                end
            end
        end
        return nil
    end
end

function get_shader(mode)
    local list = presets[mode]
    if not list then
        return "no-osd change-list glsl-shaders clr \"\""
    end

    local full_paths = {}
    for _, shader in ipairs(list) do
        table.insert(full_paths, o.shader_path .. shader)
    end

    return "no-osd change-list glsl-shaders set \"" .. table.concat(full_paths, ";") .. "\""
end

function get_playlist()
    local pl = mp.get_property_native("playlist")
    if #pl > 1 then
        local result = {}
        for i, v in ipairs(pl) do
            table.insert(result, v.filename)
        end
        return result
    else
        return nil
    end
end

function match_in_playlist(line)
    if not playlist then
        return false
    end

    for i, v in ipairs(playlist) do
        if log_path(line) == v then
            return true
        end
    end

    return false
end

function read_log(func)
    local f = io.open(o.log_path, "r")
    if not f then
        return
    end
    local list = {}
    for line in f:lines() do
        table.insert(list, (func(line)))
    end
    f:close()
    return list
end

function write_log(mode, p)
    p = p or {}
    local delete = p.delete or false
    -- playlist can still be nil here if this runs before the "playlist"
    -- property observer has fired once (e.g. right after file load), so
    -- fall back to file scope rather than indexing a nil playlist below
    local playlist_scope = (p.playlist_scope or false) and playlist ~= nil

    if not cur_file then
        return
    end

    -- remove duplicates
    local content = read_log(function(line)
        if (playlist_scope and match_in_playlist(line)) or log_path(line) == cur_file then
            return nil
        else
            return line
        end
    end)
    local f = io.open(o.log_path, "w+")
    if content then
        local start = math.max(1, #content - (o.max_log_lines - 1))
        for i = start, #content do
            f:write(("%s\n"):format(content[i]))
        end
    end

    if not delete then
        if playlist_scope then
            for i, v in ipairs(playlist) do
                f:write(("%s ::: %s\n"):format(v, mode))
            end
        else
            f:write(("%s ::: %s\n"):format(cur_file, mode))
        end
    end
    f:close()
end

function is_playlist_in_log(mode, log_line)
    if playlist then
        for i, v in ipairs(playlist) do
            if v ~= cur_file then
                local f = io.open(o.log_path, "r")
                if not f then
                    return false
                end

                local match_found = false
                for line in f:lines() do
                    if log_path(line) == v and
                        (mode == "some" or (mode == "every" and log_mode(log_line) == log_mode(line))) then
                        match_found = true
                        break
                    end
                end

                f:close()

                if mode == "some" and match_found then
                    msg.info("Found other playlist files in log")
                    return true
                elseif mode == "every" and not match_found then
                    msg.info("Didn't find whole playlist in log")
                    return false
                end
            end
        end
        if mode == "every" then
            msg.info("Found whole playlist in log")
            return true
        elseif mode == "some" then
            msg.info("Didn't find other playlist files in log")
            return false
        end
    else
        return false
    end
end

function find_log_line(file)
    if not file then
        return nil
    end
    local f = io.open(o.log_path, "r")
    if not f then
        return nil
    end

    local result = nil

    for line in f:lines() do
        if log_path(line) == file then
            result = line
            msg.info("Found existing file in log")
            break
        end
    end

    f:close()
    return result
end

-- mode = "A" | "B" | "C" | "A+A" | "B+B" | "C+A" | "disabled" | "unset": passing unset with no_write = false deletes entry from log
-- p = {
-- [no_write] = boolean: don't write change to log
-- [no_osd] = boolean: don't display message on change
-- }
function enable_mode(mode, p)
    p = p or {}
    local no_write = not o.enable_logging or p.no_write or false
    local no_osd = p.no_osd or false

    -- set shaders
    if mode ~= cur_mode then
        mp.command(get_shader(mode))
        cur_mode = mode
    end

    -- write to log
    if not no_write then
        write_log(mode, {
            delete = mode == "unset",
            playlist_scope = is_playlist_scope
        })
    end

    -- display message
    if not no_osd then
        if no_write then
            mp.osd_message("Anime4K Mode: " .. mode)
        else
            local msg
            if mode == "disabled" then
                msg = string.format("Anime4K disabled for this %s", is_playlist_scope and "playlist" or "file")
            elseif mode == "unset" then
                msg = string.format("Anime4K disabled and log cleared for this %s",
                    is_playlist_scope and "playlist" or "file")
            else
                msg = string.format("Anime4K enabled in %s mode for this %s", mode,
                    is_playlist_scope and "playlist" or "file")
            end
            mp.osd_message(msg)
        end
    end
end

-- ass colour constants used by the menu
local white = "{\\1c&HFFFFFF}"
local grey = "{\\1c&H808080}"
local yellow = "{\\1c&H66FFFF}"
local green = "{\\1c&H00FF00}"
local lightblue = "{\\1c&HFFFF00}"
local normal_font_style = string.format([[{\fscx%f}{\fscy%f}{\bord0.5}]], o.font_size, o.font_size)
local small_font_style = string.format([[{\fscx%f}{\fscy%f}{\bord0.375}]], o.font_size * 0.75, o.font_size * 0.75)

--list ass style: cursor position (➤) is independent from which mode is
--currently active (●/○), same distinction scroll-list.lua's active_marker
--support was added for
list.indent = [[]]
list.wrap = true
list.num_entries = 20
list.list_style = white .. normal_font_style
list.header_style = normal_font_style
list.cursor_style = yellow
list.selected_style = [[]]
list.cursor = marker("➤") .. [[\h]]
list.active_marker = marker("●") .. " "
list.inactive_marker = marker("○") .. " "

local function build_item(choice)
    local item = {mode = choice.mode, ass = choice.text}
    if choice.mode ~= "unset" then
        local is_active = (cur_mode == choice.mode)
        local current_color = choice.mode == "disabled" and yellow or green
        item.active = is_active
        item.style = is_active and current_color or ""
    else
        item.style = ""
    end
    return item
end

local function footer_text()
    -- reset color explicitly: the list's last row may have left cursor/active
    -- color active, and nothing after the loop resets it back to white
    local text = white
    if o.enable_logging then
        local mode_line = string.format("\\NEditing " .. lightblue .. "[%s]", is_playlist_scope and "Playlist" or "File")
        text = text .. "\\N" .. mode_line .. white
        if playlist then
            local switch_mode = string.format("\\N%s for %s scope", is_playlist_scope and "→" or "←",
                is_playlist_scope and "file" or "playlist")
            text = text .. small_font_style .. grey .. switch_mode
        end
    else
        text = text .. small_font_style .. grey .. "\\N\\NLogging disabled"
    end
    return text
end

local original_update_ass = list.update_ass
function list:update_ass()
    original_update_ass(self)
    self.ass.data = self.ass.data .. footer_text()
    mp.set_osd_ass(0, 0, self.ass.data)
end

local function change_scope(pl_scope)
    if is_playlist_scope ~= pl_scope then
        is_playlist_scope = pl_scope
        list:update()
    end
end

local original_list_open = list.open
local original_list_close = list.close

function list:open()
    original_list_open(self)
    if o.enable_logging and playlist then
        mp.add_forced_key_binding("LEFT", "auto4k-LEFT", function() change_scope(true) end)
        mp.add_forced_key_binding("RIGHT", "auto4k-RIGHT", function() change_scope(false) end)
    end
end

function list:close()
    mp.remove_key_binding("auto4k-LEFT")
    mp.remove_key_binding("auto4k-RIGHT")
    original_list_close(self)
end

function clear_log()
    if find_log_line(cur_file) then
        enable_mode("unset")
    end
end

function match_mode(value)
    local v = value:lower()
    local mode = value:match("^Mode (.+)$")
    if mode then
        return mode
    elseif v == "disable" or v == "no" then
        return "disabled"
    elseif v == "yes" then
        return o.default_yes_mode
    elseif v == "[clear log]" then
        return "unset"
    else
        return v
    end
end

function get_choices(mode)
    local base = {}

    if mode == "unset" and o.menu_yes_no then
        base = {"Yes", "No"}
    else
        if o.enable_logging and mode ~= "unset" then
            base = {"[Clear Log]"}
        end
        for i, v in ipairs({"Mode A", "Mode B", "Mode C"}) do
            table.insert(base, v)
        end
        if o.include_secondary_modes then
            for i, v in ipairs({"Mode A+A", "Mode B+B", "Mode C+A"}) do
                table.insert(base, v)
            end
        end

        table.insert(base, "Disabled")
    end

    local choices = {}
    for i, v in ipairs(base) do
        table.insert(choices, {
            text = v,
            mode = match_mode(v)
        })
    end
    return choices
end

list.keybinds = {
    {'UP', 'scroll_up', function() list:scroll_up() end, {repeatable = true}},
    {'DOWN', 'scroll_down', function() list:scroll_down() end, {repeatable = true}},
    {'ENTER', 'select_mode', function()
        local item = list.list[list.selected]
        enable_mode(item.mode)
        list:close()
    end, {}},
    {'DEL', 'clear_log', function()
        if o.enable_logging then
            clear_log()
        end
        list:close()
    end, {}},
    {'ESC', 'close_menu', function() list:close() end, {}}
}

local function open_menu()
    local choices = get_choices(cur_mode)
    local cursor = 1
    if cur_mode ~= "unset" then
        for i, v in ipairs(choices) do
            if v.mode == cur_mode then
                cursor = i
            end
        end
    end

    list.list = {}
    for i, v in ipairs(choices) do
        list.list[i] = build_item(v)
    end
    list.selected = cursor
    -- trailing \N reproduces the blank line the original had between the
    -- prompt and the first choice (format_header only adds one newline itself)
    list.header = (cur_mode == "unset" and [[\NUse Anime4K?]] or [[\NChange Anime4K mode?]]) .. [[\N]]

    list:update()
    list:open()
end

function display_menu()
    if not list.hidden then
        list:close()
        return
    end

    if mp.get_property_native("idle-active") then
        mp.osd_message("[Auto4k] No file loaded.")
        return
    end

    open_menu()
end

function init()
    cur_file = mp.get_property("path")

    if o.enable_logging then
        enable_mode("unset", {
            no_write = true,
            no_osd = true
        })

        local log_line = find_log_line(cur_file)

        if log_line then
            if is_playlist_in_log("every", log_line) then
                msg.info("Switching to playlist mode")
                is_playlist_scope = true
            else
                msg.info("Switching to file mode")
                is_playlist_scope = false
            end
            enable_mode(log_mode(log_line), {
                no_write = true,
                no_osd = true
            })
            msg.info("Putting Anime4K in " .. cur_mode .. " mode")
        elseif o.auto_run then
            msg.info("No log data found. Running prompt")
            if is_playlist_in_log("some") then
                msg.info("Switching to file mode")
                is_playlist_scope = false
            end
            mp.add_timeout(1, display_menu)
        end
    else
        cur_mode = get_mode()
        if o.auto_run then
            mp.add_timeout(1, display_menu)
        end
    end
end

-- display menu after playback-restart event, since the file loaded osd message fires after it
-- store file loaded in a state so seeks don't trigger the callback
mp.register_event("playback-restart", function()
    if not is_file_loaded then
        init()
        is_file_loaded = true
    end
end)
mp.register_event("start-file", function()
    is_file_loaded = false
end)
mp.observe_property("playlist", "native", function()
    playlist = get_playlist()
    if not playlist then
        is_playlist_scope = false
    else
        is_playlist_scope = o.default_playlist
    end
end)
mp.add_key_binding(nil, "display-auto4k", display_menu)
mp.add_key_binding(nil, "auto4k-A", function()
    enable_mode("A")
end)
mp.add_key_binding(nil, "auto4k-B", function()
    enable_mode("B")
end)
mp.add_key_binding(nil, "auto4k-C", function()
    enable_mode("C")
end)
mp.add_key_binding(nil, "auto4k-AA", function()
    enable_mode("A+A")
end)
mp.add_key_binding(nil, "auto4k-BB", function()
    enable_mode("B+B")
end)
mp.add_key_binding(nil, "auto4k-CA", function()
    enable_mode("C+A")
end)
mp.add_key_binding(nil, "auto4k-clear", function()
    enable_mode("disabled")
end)
