local o = {
    -- log file path, default in mpv config's root folder
    log_path = "~~home/auto4k.log",
    -- anime4k shaders path. if installed correctly in MPV/shaders/, don't touch anything
    shader_path = "~~/shaders/",
    -- displays the prompt on an unrecognized file or folder
    auto_run = true,
    -- whether to display a simple yes/no prompt on unrecognized file/folder, or a more detailed prompt with all modes
    prompt_yes_no = true,
    -- the default mode that will be activated if you choose yes. A, B, or C
    default_yes_mode = "A",
    -- what mode(s) of the script is activated. "folder", "file", or "both"
    script_mode = "both",
    -- whether the script starts in folder mode or file mode
    default_folder_mode = true,
    font_size = 100,
    max_log_lines = 1000
}
(require "mp.options").read_options(o)
local msg = require("mp.msg")
local utils = require("mp.utils")

o.log_path = mp.command_native({"expand-path", o.log_path})

local file_loaded = false
local cur_folder = ""
local cur_file = ""
local cur_mode = ""
local is_remote = false
local is_folder_mode = o.script_mode == "folder" and true or o.script_mode == "file" and false or o.default_folder_mode
local can_swap_mode = o.script_mode == "both"
local is_prompt_drawn = false
local choices = {"Yes", "No"}

function prepend_shader_path(shader)
    return o.shader_path .. shader
end

function log_mode(line)
    return line:match("%s:::%s([%a%s]+)$")
end

function get_shader_cmd(mode)
    local shader_header = "no-osd change-list glsl-shaders set \""

    local presets = {
        ["Mode A"] = shader_header ..
            table.concat(
                {prepend_shader_path("Anime4K_Clamp_Highlights.glsl"),
                 prepend_shader_path("Anime4K_Restore_CNN_VL.glsl"),
                 prepend_shader_path("Anime4K_Upscale_CNN_x2_VL.glsl"),
                 prepend_shader_path("Anime4K_AutoDownscalePre_x2.glsl"),
                 prepend_shader_path("Anime4K_AutoDownscalePre_x4.glsl"),
                 prepend_shader_path("Anime4K_Upscale_CNN_x2_M.glsl")}, ";") .. "\"",
        ["Mode B"] = shader_header .. table.concat({prepend_shader_path("Anime4K_Clamp_Highlights.glsl"),
                                                    prepend_shader_path("Anime4K_Restore_CNN_Soft_VL.glsl"),
                                                    prepend_shader_path("Anime4K_Upscale_CNN_x2_VL.glsl"),
                                                    prepend_shader_path("Anime4K_AutoDownscalePre_x2.glsl"),
                                                    prepend_shader_path("Anime4K_AutoDownscalePre_x4.glsl"),
                                                    prepend_shader_path("Anime4K_Upscale_CNN_x2_M.glsl")}, ";") .. "\"",
        ["Mode C"] = shader_header .. table.concat({prepend_shader_path("Anime4K_Clamp_Highlights.glsl"),
                                                    prepend_shader_path("Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
                                                    prepend_shader_path("Anime4K_AutoDownscalePre_x2.glsl"),
                                                    prepend_shader_path("Anime4K_AutoDownscalePre_x4.glsl"),
                                                    prepend_shader_path("Anime4K_Upscale_CNN_x2_M.glsl")}, ";") .. "\"",
        Disabled = "no-osd change-list glsl-shaders clr \"\""
    }

    return presets[mode] or presets["Disabled"]
end

-- Escapes magic characters in Lua patterns
function escape(str)
    return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

function hide()
    mp.remove_key_binding("auto4k-UP")
    mp.remove_key_binding("auto4k-DOWN")
    mp.remove_key_binding("auto4k-LEFT")
    mp.remove_key_binding("auto4k-RIGHT")
    mp.remove_key_binding("auto4k-ENTER")
    mp.remove_key_binding("auto4k-ESC")
    mp.remove_key_binding("auto4k-DEL")
    mp.set_osd_ass(0, 0, "")
    is_prompt_drawn = false
end

function get_current_paths()
    local full_path = mp.get_property("path")
    local folder_path, _ = utils.split_path(full_path)
    folder_path = folder_path:gsub("\\$", "")
    return folder_path, full_path
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

function write_log(mode, delete)
    if not cur_folder or not cur_file then
        return
    end
    local content = read_log(function(line)
        -- remove duplicates
        if (is_folder_mode and line:match("^%[Folder%]%s+" .. escape(cur_folder) .. "%s+:::")) or
            (not is_folder_mode and line:match("^%[File%]%s+" .. escape(cur_file) .. "%s+:::")) then
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
        f:write(("[%s] %s ::: %s\n"):format(is_folder_mode and "Folder" or "File",
            is_folder_mode and cur_folder or cur_file, mode))
    end
    f:close()
end

function find_log_line(folder, file)
    if not folder and not file then
        return nil
    end
    local f = io.open(o.log_path, "r")
    if not f then
        return
    end

    local result = nil
    local folder_mode = nil

    for line in f:lines() do
        if file and line:match("^%[File%]%s+" .. escape(file) .. "%s+:::") then
            folder_mode = false
            result = line
            msg.info("Found existing file in log")
            break
        elseif folder and line:match("^%[Folder%]%s+" .. escape(folder) .. "%s+:::") then
            folder_mode = true
            result = line
            msg.info("Found existing folder in log")
        end
    end
    f:close()
    return result, folder_mode
end

-- mode = "A" | "B" | "C" | "Disabled" | "Unset" : passing Unset with no_write = false deletes entry from log
-- p = {
-- [no_write] = boolean : don't write change to log
-- [no_osd] = boolean : don't display message on change
-- }                
function enable_mode(mode, p)
    p = p or {}
    local no_write = p.no_write or false
    local no_osd = p.no_osd or false

    local config = {
        ["Mode A"] = {
            choices = {"Mode B", "Mode C", "Disable"},
            label = "Mode A (1080p)"
        },
        ["Mode B"] = {
            choices = {"Mode A", "Mode C", "Disable"},
            label = "Mode B (720p)"
        },
        ["Mode C"] = {
            choices = {"Mode A", "Mode B", "Disable"},
            label = "Mode C (480p)"
        },
        Disabled = {
            choices = {"Mode A", "Mode B", "Mode C"},
            label = "GLSL shaders cleared",
            disabled = true
        },
        Unset = {
            choices = o.prompt_yes_no and {"Yes", "No"} or {"Mode A", "Mode B", "Mode C", "Disable"},
            label = "GLSL shaders cleared",
            unset = true
        }
    }

    local m = config[mode]
    if not m then
        return
    end

    -- set shaders
    if mode ~= cur_mode then
        mp.command(get_shader_cmd(mode))
        cur_mode = mode
    end

    -- set prompt choices
    choices = m.choices

    -- write to log
    if not no_write then
        write_log(mode, mode == "Unset")
    end

    -- display message
    if not no_osd then
        if no_write then
            mp.osd_message("Anime4K: " .. m.label)
        else
            local msg
            if m.disabled then
                msg = ("Anime4k disabled for this " .. (is_folder_mode and "folder" or "file"))
            elseif m.unset then
                msg = ("Anime4k disabled and log cleared for this " .. (is_folder_mode and "folder" or "file"))
            else
                msg = string.format("Anime4k enabled in %s mode for this %s", mode,
                    is_folder_mode and "folder" or "file")
            end
            mp.osd_message(msg)
        end
    end
end

function draw_prompt(cursor)
    local header = string.format("{\\fscx%s}{\\fscy%s}Current %s : {\\1c&H%s}%s{\\1c&HFFFFFF}", o.font_size,
        o.font_size, is_folder_mode and "folder" or "file",
        cur_mode == "Disabled" and "66FFFF" or cur_mode == "Unset" and "0000FF" or "00FF00", cur_mode)
    local prompt = cur_mode == "Unset" and
                       string.format("\\NUse Anime4K for this %s?", is_folder_mode and "folder" or "file") or
                       string.format("\\NChange Anime4k mode for this %s?", is_folder_mode and "folder" or "file")
    local other_mode = string.format(
        "\\N{\\fscx%s}{\\fscy%s}{\\1c&H808080}Press %s for %s mode{\\fscx%s}{\\fscy%s}{\\1c&HFFFFFF}",
        o.font_size * 3 / 4, o.font_size * 3 / 4, is_folder_mode and "→" or "←",
        is_folder_mode and "file" or "folder", o.font_size, o.font_size)

    local osd_text = header .. prompt .. (can_swap_mode and other_mode or "")

    for i, v in ipairs(choices) do
        if (cursor == i) then
            osd_text = osd_text .. "\\N{\\1c&H66FFFF}> " .. v .. "{\\1c&HFFFFFF}"
        else
            osd_text = osd_text .. "\\N" .. v
        end
    end

    -- Remove OSD messages if exist
    mp.osd_message(" ", 0.1)
    mp.set_osd_ass(0, 0, osd_text)
end

function change_folder_mode(new_mode, redraw)
    if new_mode == is_folder_mode and not can_swap_mode then
        return
    end

    local log_line
    if new_mode then
        log_line = find_log_line(cur_folder, nil)
    else
        log_line = find_log_line(nil, cur_file)
    end

    enable_mode(log_line and log_mode(log_line) or "Unset", {
        no_write = true,
        no_osd = true
    })

    is_folder_mode = new_mode

    if redraw then
        draw_prompt(1)
    end
    return 1
end

function delete_from_log()
    local log_line, _ = find_log_line(cur_folder, cur_file)
    if log_line then
        enable_mode("Unset")
        if can_swap_mode then
            change_folder_mode(o.default_folder_mode)
        end
    end
end

function select(cursor)
    local choice = choices[cursor]

    if choice == "Yes" then
        enable_mode("Mode " .. o.default_yes_mode)
    elseif choice == "No" or choice == "Disable" then
        enable_mode("Disabled")
    else
        enable_mode(choice)
    end

    hide()
end

function change_choice(cursor, dir)
    local new_cursor
    if (cursor + dir > #choices) then
        new_cursor = 1
    elseif cursor + dir <= 0 then
        new_cursor = #choices
    else
        new_cursor = cursor + dir
    end
    draw_prompt(new_cursor)
    return new_cursor
end

function display_prompt()
    if is_prompt_drawn then
        hide()
        return
    end

    local cursor = 1

    draw_prompt(cursor)
    is_prompt_drawn = true

    mp.add_forced_key_binding("UP", "auto4k-UP", function()
        cursor = change_choice(cursor, -1)
    end, {
        repeatable = true
    })
    mp.add_forced_key_binding("DOWN", "auto4k-DOWN", function()
        cursor = change_choice(cursor, 1)
    end, {
        repeatable = true
    })
    if can_swap_mode then
        mp.add_forced_key_binding("LEFT", "auto4k-LEFT", function()
            cursor = change_folder_mode(true, true)
        end)
        mp.add_forced_key_binding("RIGHT", "auto4k-RIGHT", function()
            cursor = change_folder_mode(false, true)
        end)
    end
    mp.add_forced_key_binding("ENTER", "auto4k-ENTER", function()
        select(cursor)
    end)
    mp.add_forced_key_binding("ESC", "auto4k-ESC", function()
        hide()
    end)
    mp.add_forced_key_binding("DEL", "auto4k-DEL", function()
        hide()
        delete_from_log()
    end)
end

function init()
    cur_folder, cur_file = get_current_paths()
    is_remote = cur_file:match("^https?://")
    if is_remote then
        can_swap_mode = false
    end

    enable_mode("Unset", {
        no_write = true,
        no_osd = true
    })

    local log_line, folder_mode = find_log_line(cur_folder, cur_file)

    if log_line then
        enable_mode(log_mode(log_line), {
            no_write = true,
            no_osd = true
        })
        is_folder_mode = is_remote and false or folder_mode
        if cur_mode ~= "Disabled" then
            msg.info("Enabling Anime4k in " .. cur_mode .. " for " .. (is_folder_mode and "this folder" or "this file"))
        end
    elseif o.auto_run then
        msg.info("No log data found. Running prompt")
        if is_remote then
            is_folder_mode = false
        end
        mp.add_timeout(1, display_prompt)
    end
end

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
    enable_mode("Mode A")
end)
mp.add_key_binding(nil, "auto4k-B", function()
    enable_mode("Mode B")
end)
mp.add_key_binding(nil, "auto4k-C", function()
    enable_mode("Mode C")
end)
mp.add_key_binding(nil, "auto4k-clear", function()
    enable_mode("Disabled")
end)
