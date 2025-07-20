local o = {
    -- log file path, default in mpv config's root folder
    log_path = "~~home/auto4k.log",
    -- anime4k shaders path. if installed correctly in MPV/shaders/, don't touch anything
    shader_path = "~~/shaders/",
    -- displays the prompt on an unrecognized file
    auto_run = true,
    -- whether to display a simple yes/no prompt on unrecognized file, or a more detailed prompt with all modes
    prompt_yes_no = true,
    -- the default mode that will be activated if you choose yes. A, B, or C
    default_yes_mode = "A",
    -- whether the choices will be in playlist scope by default or not 
    default_playlist = true,
    -- include A+A, B+B, C+A modes
    include_secondary_modes = true,
    font_size = 100,
    max_log_lines = 1000
}
(require "mp.options").read_options(o)
local msg = require("mp.msg")
local utils = require("mp.utils")

o.log_path = mp.command_native({"expand-path", o.log_path})

-- states
local is_file_loaded = false
local cur_file = ""
local cur_mode = ""
local is_playlist_scope = o.default_playlist
local playlist = nil
local is_prompt_drawn = false

function log_mode(line)
    return line:match("%s:::%s(.+)$")
end

function get_shader_cmd(mode)
    local shader_header = "no-osd change-list glsl-shaders set \""
    local clamp = o.shader_path .. "Anime4K_Clamp_Highlights.glsl"
    local rcnns_vl = o.shader_path .. "Anime4K_Restore_CNN_Soft_VL.glsl"
    local rcnn_vl = o.shader_path .. "Anime4K_Restore_CNN_VL.glsl"
    local rcnns_m = o.shader_path .. "Anime4K_Restore_CNN_Soft_M.glsl"
    local rcnn_m = o.shader_path .. "Anime4K_Restore_CNN_M.glsl"
    local ucnn_x2_vl = o.shader_path .. "Anime4K_Upscale_CNN_x2_VL.glsl"
    local ucnn_x2_m = o.shader_path .. "Anime4K_Upscale_CNN_x2_M.glsl"
    local adp_x2 = o.shader_path .. "Anime4K_AutoDownscalePre_x2.glsl"
    local adp_x4 = o.shader_path .. "Anime4K_AutoDownscalePre_x4.glsl"
    local udcnn_x2_vl = o.shader_path .. "Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"

    local presets = {
        A = shader_header .. table.concat({clamp, rcnn_vl, ucnn_x2_vl, adp_x2, adp_x4, ucnn_x2_m}, ";") .. "\"",
        B = shader_header .. table.concat({clamp, rcnns_vl, ucnn_x2_vl, adp_x2, adp_x4, ucnn_x2_m}, ";") .. "\"",
        C = shader_header .. table.concat({clamp, udcnn_x2_vl, adp_x2, adp_x4, ucnn_x2_m}, ";") .. "\"",
        ["A+A"] = shader_header .. table.concat({clamp, rcnn_vl, ucnn_x2_vl, rcnn_m, adp_x2, adp_x4, ucnn_x2_m}, ";") ..
            "\"",
        ["B+B"] = shader_header .. table.concat({clamp, rcnns_vl, ucnn_x2_vl, adp_x2, adp_x4, rcnns_m, ucnn_x2_m}, ";") ..
            "\"",
        ["C+A"] = shader_header .. table.concat({clamp, udcnn_x2_vl, adp_x2, adp_x4, rcnn_m, ucnn_x2_m}, ";") .. "\"",
        disabled = "no-osd change-list glsl-shaders clr \"\""
    }

    return presets[mode] or presets["disabled"]
end

-- Escapes magic characters in Lua patterns
function escape(str)
    return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

function hide()
    mp.remove_key_binding("auto4k-UP")
    mp.remove_key_binding("auto4k-DOWN")
    mp.remove_key_binding("auto4k-ENTER")
    mp.remove_key_binding("auto4k-LEFT")
    mp.remove_key_binding("auto4k-RIGHT")
    mp.remove_key_binding("auto4k-ESC")
    mp.remove_key_binding("auto4k-DEL")
    mp.set_osd_ass(0, 0, "")
    is_prompt_drawn = false
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
        if line:find(v, 1, true) then
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
    local playlist_scope = p.playlist_scope or false

    if not cur_file then
        return
    end

    -- remove duplicates
    local content = read_log(function(line)
        if (playlist_scope and match_in_playlist(line)) or line:find(cur_file, 1, true) then
            return nil
        else
            return line
        end
    end)
    f = io.open(o.log_path, "w+")
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

function is_whole_playlist(log_line)
    if playlist then
        for i, v in ipairs(playlist) do
            if v ~= cur_file then
                local f = io.open(o.log_path, "r")
                if not f then
                    return false
                end

                local match_found = false
                for line in f:lines() do
                    if line:find(v, 1, true) and log_mode(log_line) == log_mode(line) then
                        match_found = true
                        break
                    end
                end

                f:close()

                if not match_found then
                    return false
                end
            end
        end
        msg.info("Found whole playlist in log")
        return true
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
        if line:match(escape(file) .. "%s+:::") then
            result = line
            msg.info("Found existing file in log")
            break
        end
    end

    f:close()
    return result
end

-- mode = "A" | "B" | "C" | "disabled" | "unset": passing unset with no_write = false deletes entry from log
-- p = {
-- [no_write] = boolean: don't write change to log
-- [no_osd] = boolean: don't display message on change
-- }                
function enable_mode(mode, p)
    p = p or {}
    local no_write = p.no_write or false
    local no_osd = p.no_osd or false

    -- set shaders
    if mode ~= cur_mode then
        mp.command(get_shader_cmd(mode))
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
            mp.osd_message("Anime4K: " .. mode)
        else
            local msg
            if mode == "disabled" then
                msg = string.format("Anime4k disabled for this %s", is_playlist_scope and "playlist" or "file")
            elseif mode == "unset" then
                msg = string.format("Anime4k disabled and log cleared for this %s",
                    is_playlist_scope and "playlist" or "file")
            else
                msg = string.format("Anime4k enabled in %s mode for this %s", mode,
                    is_playlist_scope and "playlist" or "file")
            end
            mp.osd_message(msg)
        end
    end
end

function draw_prompt(cursor, choices)
    local white = "{\\1c&HFFFFFF}"
    local grey = "{\\1c&H808080}"
    local yellow = "{\\1c&H66FFFF}"
    local red = "{\\1c&0000FF}"
    local green = "{\\1c&00FF00}"
    local lightblue = "{\\1c&HFFFF00}"
    local normal_font = string.format("{\\fscx%f}{\\fscy%f}", o.font_size, o.font_size)
    local small_font = string.format("{\\fscx%f}{\\fscy%f}", o.font_size * 0.75, o.font_size * 0.75)
    local prompt = cur_mode == "unset" and "\\NUse Anime4K?" or "\\NChange Anime4k mode?"
    local mode =
        string.format("\\NEditing " .. lightblue .. "[%s]" .. white, is_playlist_scope and "Playlist" or "File")
    local switch_mode = string.format(grey .. "\\N%s for %s scope", is_playlist_scope and "→" or "←",
        is_playlist_scope and "file" or "playlist")
    local osd_text = normal_font .. prompt .. "\\N"

    for i, v in ipairs(choices) do
        local selected = (v.mode ~= "unset" and cur_mode == v.mode)
        local current = selected and "=" or ""
        local current_color = v.mode == "disabled" and yellow or v.mode == "unset" and red or green
        if (cursor == i) then
            osd_text = osd_text .. "\\N" .. yellow .. "> " .. current .. v.text .. current .. white
        else
            osd_text = osd_text .. "\\N" .. (selected and current_color or "") .. current .. v.text .. current ..
                           (selected and white or "")
        end
    end

    osd_text = osd_text .. "\\N" .. mode
    if playlist then
        osd_text = osd_text .. small_font .. switch_mode
    end

    -- Remove OSD messages if exist
    mp.osd_message(" ", 0.1)
    mp.set_osd_ass(0, 0, osd_text)
end

function clear_log()
    if find_log_line(cur_file) then
        enable_mode("unset")
    end
end

function select(cursor, choices)
    local choice = choices[cursor].text

    local mode = ""
    if choice == "Yes" then
        mode = o.default_yes_mode
    elseif choice == "No" or choice == "Disable" then
        mode = "Disabled"
    else
        mode = choice
    end

    enable_mode(mode)
end

function change_scope(cursor, choices, pl_scope)
    if is_playlist_scope ~= pl_scope then
        is_playlist_scope = pl_scope
        draw_prompt(cursor, choices)
    end
end

function change_choice(cursor, choices, dir)
    local new_cursor
    if (cursor + dir > #choices) then
        new_cursor = 1
    elseif cursor + dir <= 0 then
        new_cursor = #choices
    else
        new_cursor = cursor + dir
    end
    draw_prompt(new_cursor, choices)
    return new_cursor
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

    if mode == "unset" and o.prompt_yes_no then
        base = {"Yes", "No"}
    else
        base = mode ~= "unset" and {"[Clear Log]", "Mode A", "Mode B", "Mode C"} or {"Mode A", "Mode B", "Mode C"}

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

function display_prompt()
    if is_prompt_drawn then
        hide()
        return
    end

    local choices = get_choices(cur_mode)
    local cursor = 1
    if cur_mode ~= "unset" then
        for i, v in ipairs(choices) do
            if v.mode == cur_mode then
                cursor = i
            end
        end
    end

    draw_prompt(cursor, choices)
    is_prompt_drawn = true

    mp.add_forced_key_binding("UP", "auto4k-UP", function()
        cursor = change_choice(cursor, choices, -1)
    end, {
        repeatable = true
    })
    mp.add_forced_key_binding("DOWN", "auto4k-DOWN", function()
        cursor = change_choice(cursor, choices, 1)
    end, {
        repeatable = true
    })
    if playlist then
        mp.add_forced_key_binding("LEFT", "auto4k-LEFT", function()
            change_scope(cursor, choices, true)
        end)
        mp.add_forced_key_binding("RIGHT", "auto4k-RIGHT", function()
            change_scope(cursor, choices, false)
        end)
    end
    mp.add_forced_key_binding("ENTER", "auto4k-ENTER", function()
        enable_mode(choices[cursor].mode)
        hide()
    end)
    mp.add_forced_key_binding("ESC", "auto4k-ESC", function()
        hide()
    end)
    mp.add_forced_key_binding("DEL", "auto4k-DEL", function()
        clear_log()
        hide()
    end)
end

function init()
    cur_file = mp.get_property("path")

    enable_mode("unset", {
        no_write = true,
        no_osd = true
    })

    local log_line = find_log_line(cur_file)

    if log_line then
        is_playlist_scope = is_whole_playlist(log_line)
        enable_mode(log_mode(log_line), {
            no_write = true,
            no_osd = true
        })
        if cur_mode ~= "disabled" then
            msg.info("Enabling Anime4k in " .. cur_mode .. " mode for this file")
        end
    elseif o.auto_run then
        msg.info("No log data found. Running prompt")
        mp.add_timeout(1, display_prompt)
    end
end

-- display prompt after playback-restart event, since the file loaded osd message fires after it
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
    end
end)
mp.add_key_binding(nil, "display-auto4k", display_prompt)
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
