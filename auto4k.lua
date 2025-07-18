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
    font_size = 100,
    max_log_lines = 1000
}
(require "mp.options").read_options(o)
local msg = require("mp.msg")
local utils = require("mp.utils")

o.log_path = mp.command_native({"expand-path", o.log_path})

-- states
local file_loaded = false
local cur_file = ""
local cur_mode = ""
local is_prompt_drawn = false

function prepend_shader_path(shader)
    return o.shader_path .. shader
end

function log_mode(line)
    return line:match("%s:::%s([%a%s]+)$")
end

function get_shader_cmd(mode)
    local shader_header = "no-osd change-list glsl-shaders set \""

    local presets = {
        A = shader_header ..
            table.concat(
                {prepend_shader_path("Anime4K_Clamp_Highlights.glsl"),
                 prepend_shader_path("Anime4K_Restore_CNN_VL.glsl"),
                 prepend_shader_path("Anime4K_Upscale_CNN_x2_VL.glsl"),
                 prepend_shader_path("Anime4K_AutoDownscalePre_x2.glsl"),
                 prepend_shader_path("Anime4K_AutoDownscalePre_x4.glsl"),
                 prepend_shader_path("Anime4K_Upscale_CNN_x2_M.glsl")}, ";") .. "\"",
        B = shader_header .. table.concat({prepend_shader_path("Anime4K_Clamp_Highlights.glsl"),
                                           prepend_shader_path("Anime4K_Restore_CNN_Soft_VL.glsl"),
                                           prepend_shader_path("Anime4K_Upscale_CNN_x2_VL.glsl"),
                                           prepend_shader_path("Anime4K_AutoDownscalePre_x2.glsl"),
                                           prepend_shader_path("Anime4K_AutoDownscalePre_x4.glsl"),
                                           prepend_shader_path("Anime4K_Upscale_CNN_x2_M.glsl")}, ";") .. "\"",
        C = shader_header .. table.concat({prepend_shader_path("Anime4K_Clamp_Highlights.glsl"),
                                           prepend_shader_path("Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
                                           prepend_shader_path("Anime4K_AutoDownscalePre_x2.glsl"),
                                           prepend_shader_path("Anime4K_AutoDownscalePre_x4.glsl"),
                                           prepend_shader_path("Anime4K_Upscale_CNN_x2_M.glsl")}, ";") .. "\"",
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

function match_in_playlist(line)
    local playlist = mp.get_property_native("playlist")

    for _, v in ipairs(playlist) do
        if line:find(v.filename, 1, true) then
            return true
        end
    end

    return false
end

function write_log(mode, p)
    p = p or {}
    local delete = p.delete or false
    local playlist = p.playlist or false

    if not cur_file then
        return
    end

    -- remove duplicates
    local content = read_log(function(line)
        if (playlist and match_in_playlist(line)) or line:find(cur_file, 1, true) then
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
        if playlist then
            local playlist = mp.get_property_native("playlist")

            for _, v in ipairs(playlist) do
                f:write(("%s ::: %s\n"):format(v.filename, mode))
            end
        else
            f:write(("%s ::: %s\n"):format(cur_file, mode))
        end
    end
    f:close()
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
        if file and line:match(escape(file) .. "%s+:::") then
            result = line
            msg.info("Found existing file in log")
            break
        end
    end
    f:close()
    return result
end

-- mode = "A" | "B" | "C" | "disabled" | "unset": passing Unset with no_write = false deletes entry from log
-- p = {
-- [playlist] = boolean: apply change to whole playlist
-- [no_write] = boolean: don't write change to log
-- [no_osd] = boolean: don't display message on change
-- }                
function enable_mode(mode, p)
    p = p or {}
    local no_write = p.no_write or false
    local no_osd = p.no_osd or false
    local playlist
    if p.playlist ~= nil then
        playlist = p.playlist
    else
        playlist = o.default_playlist
    end

    -- set shaders
    if mode ~= cur_mode then
        mp.command(get_shader_cmd(mode))
        cur_mode = mode
    end

    -- write to log
    if not no_write then
        write_log(mode, {
            delete = mode == "unset",
            playlist = playlist
        })
    end

    -- display message
    if not no_osd then
        if no_write then
            mp.osd_message("Anime4K: " .. mode)
        else
            local msg
            if mode == "disabled" then
                msg = string.format("Anime4k disabled for this %s", playlist and "playlist" or "file")
            elseif mode == "unset" then
                msg = string.format("Anime4k disabled and log cleared for this %s", playlist and "playlist" or "file")
            else
                msg = string.format("Anime4k enabled in %s mode for this %s", mode, playlist and "playlist" or "file")
            end
            mp.osd_message(msg)
        end
    end
end

function draw_prompt(cursor, choices)
    local normal_font = string.format("{\\fscx%f}{\\fscy%f}{\\1c&HFFFFFF}", o.font_size, o.font_size)
    local small_font = string.format("{\\fscx%f}{\\fscy%f}", o.font_size * 0.75, o.font_size * 0.75)
    local header = string.format("Current file: {\\1c&H%s}%s{\\1c&HFFFFFF}",
        cur_mode == "disabled" and "66FFFF" or cur_mode == "unset" and "0000FF" or "00FF00",
        cur_mode:gsub("^%l", string.upper))
    local prompt = cur_mode == "unset" and "\\NUse Anime4K?" or "\\NChange Anime4k mode?"
    local osd_text = normal_font .. header .. prompt .. "\\N"

    for i, v in ipairs(choices) do
        local suffix = string.format(small_font .. "\\h\\h[%s]", v.playlist and "Playlist" or "File")
        local switch_mode = string.format("{\\1c&H808080}\\h\\hPress %s for %s scope", v.playlist and "→" or "←",
            v.playlist and "file" or "playlist")
        if (cursor == i) then
            osd_text = osd_text .. "\\N{\\1c&H66FFFF}> " .. v.text .. suffix .. switch_mode .. normal_font
        else
            osd_text = osd_text .. "\\N" .. v.text .. suffix .. normal_font
        end
    end

    -- Remove OSD messages if exist
    mp.osd_message(" ", 0.1)
    mp.set_osd_ass(0, 0, osd_text)
end

function delete_from_log()
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

    enable_mode(mode, {
        playlist = choice.playlist
    })
end

function change_scope(cursor, choices, playlist)
    if choices[cursor].playlist ~= playlist then
        local new_choices = choices
        new_choices[cursor].playlist = playlist
        draw_prompt(cursor, new_choices)
        return new_choices
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
    local letter = value:match("^Mode ([ABC])$")
    if letter then
        return letter
    elseif v == "disable" or v == "no" then
        return "disabled"
    elseif v == "yes" then
        return o.default_yes_mode
    elseif v == "delete" then
        return "unset"
    else
        return v
    end
end

function get_choices(mode)
    local base
    if mode == "A" then
        base = {"Mode B", "Mode C", "Disable", "Delete"}
    elseif mode == "B" then
        base = {"Mode A", "Mode C", "Disable", "Delete"}
    elseif mode == "C" then
        base = {"Mode A", "Mode B", "Disable", "Delete"}
    elseif mode == "disabled" then
        base = {"Mode A", "Mode B", "Mode C", "Delete"}
    else
        base = o.default_yes_mode and {"Yes", "No"} or {"Mode A", "Mode B", "Mode C", "Disable"}
    end
    local choices = {}
    for i, v in ipairs(base) do
        table.insert(choices, {
            text = v,
            playlist = o.default_playlist,
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

    local cursor = 1
    local choices = get_choices(cur_mode)

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
    mp.add_forced_key_binding("LEFT", "auto4k-LEFT", function()
        if not choices[cursor].playlist then
            choices = change_scope(cursor, choices, true)
        end
    end)
    mp.add_forced_key_binding("RIGHT", "auto4k-RIGHT", function()
        if choices[cursor].playlist then
            choices = change_scope(cursor, choices, false)
        end
    end)
    mp.add_forced_key_binding("ENTER", "auto4k-ENTER", function()
        enable_mode(choices[cursor].mode, {
            playlist = choices[cursor].playlist
        })
        hide()
    end)
    mp.add_forced_key_binding("ESC", "auto4k-ESC", function()
        hide()
    end)
    mp.add_forced_key_binding("DEL", "auto4k-DEL", function()
        delete_from_log()
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
        enable_mode(log_mode(log_line), {
            no_write = true,
            no_osd = true
        })
        if cur_mode ~= "disabled" then
            msg.info("Enabling Anime4k in " .. cur_mode .. "mode for this file")
        end
    elseif o.auto_run then
        msg.info("No log data found. Running prompt")
        mp.add_timeout(1, display_prompt)
    end
end

-- display prompt after playback-restart event, since the file loaded osd message fires after it
-- store file loaded in a state so seeks don't trigger the callback
mp.register_event("playback-restart", function()
    if not file_loaded then
        init()
        file_loaded = true
    end
end)
mp.register_event("start-file", function()
    file_loaded = false
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
mp.add_key_binding(nil, "auto4k-clear", function()
    enable_mode("disabled")
end)
