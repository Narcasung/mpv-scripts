local o = {
    -- Automatically save to log, otherwise only saves when requested
    -- you need to bind a save key if you disable it
    auto_save = true,
    save_bind = "",
    -- When automatically saving, skip entries with playback positions
    -- past this value, in percent. 100 saves all, around 95 is
    -- good for skipping videos that have reached final credits.
    auto_save_skip_past = 100,
    -- Display only the latest file from each directory
    hide_same_dir = false,
    -- Runs automatically when --idle
    auto_run_idle = true,
    -- Write watch later for current file when switching
    write_watch_later = true,
    -- Display menu bind
    display_bind = "`",
    -- Middle click: Select; Right click: Exit;
    -- Scroll wheel: Up/Down
    mouse_controls = true,
    -- Reads from config directory or an absolute path
    log_path = "history.log",
    -- Date format in the log (see lua date formatting)
    date_format = "%d/%m/%y %X",
    -- Show file paths instead of media-title
    show_paths = false,
    -- slice long filenames, and how many chars to show
    slice_longfilenames = false,
    slice_longfilenames_amount = 100,
    -- Split paths to only show the file or show the full path
    split_paths = true,
    -- Font settings
    font_scale = 50,
    border_size = 0.7,
    -- Highlight color in BGR hexadecimal
    hi_color = "H46CFFF",
    -- Number of lines to display in the list, adjust to your mpv height
    num_entries = 10,
    -- Cull old entries from log if it gets too big
    max_log_lines = 10000
}

(require "mp.options").read_options(o)
local utils = require("mp.utils")
o.log_path = utils.join_path(mp.find_config_file("."), o.log_path)

--➤ (Dingbats) isn't in the OSD font (Poppins), so without an explicit \fn it
--falls back to whatever font Windows picks for the glyph. Forcing Segoe UI
--Symbol keeps that consistent, and scaling it down a notch keeps its visual
--weight in line with the surrounding text. Same fix as track-list.lua/auto4k.lua.
local SYMBOL_FONT = "Segoe UI Symbol"
local function marker(glyph)
    local small = o.font_scale * 0.75
    return string.format([[{\fn%s\fscx%f\fscy%f}%s{\fn\fscx%f\fscy%f}]],
        SYMBOL_FONT, small, small, glyph, o.font_scale, o.font_scale)
end

--adding the source directory to the package path and loading the module
--resolved relative to this script's own location so it works regardless of ~~ (config-dir)
local script_dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])")
package.path = script_dir .. "../script-modules/?.lua;" .. package.path
local list = require "scroll-list"

local cur_title, cur_path

-- variables for custom playlist detection
local playlist_url = ""
local playlist_first_entry = ""
local playlist_given = false

function esc_string(str)
    return str:gsub("([%p])", "%%%1")
end

function is_protocol(path)
    return type(path) == 'string' and path:match('^%a[%a%d-_]+://') ~= nil
end

function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            path = mp.command_native({"normalize-path", path})
        else
            local directory = mp.get_property("working-directory", "")
            path = utils.join_path(directory, path:gsub('^%.[\\/]', ''))
            if is_windows then
                path = path:gsub("\\", "/")
            end
        end
        return path
    end

    normalize_path = false

    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "normalize-path" then
            normalize_path = true
            break
        end
    end
    return normalize(path)
end

-- from http://lua-users.org/wiki/LuaUnicode
local UTF8_PATTERN = '[%z\1-\127\194-\244][\128-\191]*'

-- return a substring based on utf8 characters
-- like string.sub, but negative index is not supported
local function utf8_sub(s, i, j)
    local t = {}
    local idx = 1
    for match in s:gmatch(UTF8_PATTERN) do
        if j and idx > j then
            break
        end
        if idx >= i then
            t[#t + 1] = match
        end
        idx = idx + 1
    end
    return table.concat(t)
end

function split_ext(filename)
    local idx = filename:match(".+()%.%w+$")
    if idx then
        filename = filename:sub(1, idx - 1)
    end
    return filename
end

function strip_title(str)
    if o.slice_longfilenames and str:len() > o.slice_longfilenames_amount + 5 then
        str = utf8_sub(str, 1, o.slice_longfilenames_amount) .. "..."
    end
    return str
end

function get_ext(path)
    if is_protocol(path) then
        return path:match("^(%a[%w.+-]-)://"):upper()
    else
        return path:match(".+%.(%w+)$"):upper()
    end
end

function get_dir(path)
    if is_protocol(path) then
        return path
    end
    local dir, filename = utils.split_path(path)
    return dir
end

function get_filename(item)
    if is_protocol(item.path) then
        return item.title
    end
    local dir, filename = utils.split_path(item.path)
    return filename
end

function get_path()
    local path
    -- if playlist detected, add playlist url instead of video url
    if playlist_url ~= "" then
        path = playlist_url
    else
        path = mp.get_property("path")
    end
    local title = mp.get_property("media-title"):gsub("\"", "")
    if not path then
        return
    end
    if is_protocol(path) then
        return title, path
    else
        local path = normalize(path)
        return title, path
    end
end

function read_log(func)
    local f = io.open(o.log_path, "r")
    if not f then
        return
    end
    local list = {}
    for line in f:lines() do
        if not line:match("^%s*$") then
            table.insert(list, (func(line)))
        end
    end
    f:close()
    return list
end

function read_log_table()
    return read_log(function(line)
        local d, t, p
        d, t, p = line:match("^%[(.-) .-\"(.-)\" | (.*)$")
        return {
            date = d,
            title = t,
            path = p
        }
    end)
end

function table_reverse(table)
    local reversed_table = {}
    for i = 1, #table do
        reversed_table[#table - i + 1] = table[i]
    end
    return reversed_table
end

function hide_same_dir(content)
    local lists = {}
    local dir_cache = {}
    for i = 1, #content do
        local dirname = get_dir(content[#content - i + 1].path)
        if not dir_cache[dirname] then
            table.insert(lists, content[#content - i + 1])
        end
        if dirname ~= "." then
            dir_cache[dirname] = true
        end
    end
    return table_reverse(lists)
end

local dyn_menu = {
    ready = false,
    type = 'submenu',
    submenu = {}
}

function update_dyn_menu_items()
    local menu = {}
    local lists = read_log_table()
    if not lists or not lists[1] then
        return
    end
    if o.hide_same_dir then
        lists = hide_same_dir(lists)
    end
    local length
    if #lists > o.num_entries then
        length = o.num_entries
    else
        length = #lists
    end
    for i = 1, length do
        menu[#menu + 1] = {
            title = string.format('%s\t%s',
                o.show_paths and strip_title(split_ext(get_filename(lists[#lists - i + 1]))) or
                    strip_title(split_ext(lists[#lists - i + 1].title)), get_ext(lists[#lists - i + 1].path)),
            cmd = string.format("loadfile '%s'", lists[#lists - i + 1].path)
        }
    end
    dyn_menu.submenu = menu
    mp.commandv('script-message-to', 'dyn_menu', 'update', 'recent', utils.format_json(dyn_menu))
end

-- Write path to log on file end
-- removing duplicates along the way
function write_log(delete)
    if not cur_path or
        (cur_path:match("bd://") or cur_path:match("dvd://") or cur_path:match("dvb://") or cur_path:match("cdda://")) then
        return
    end
    local content = read_log(function(line)
        -- only delete entry if both name and path match (playlist custom module necessary)
        if line:find(esc_string(cur_path)) then
            return nil
        else
            return line
        end
    end)
    local f = io.open(o.log_path, "w+")
    if content then
        -- culls log if it gets too big
        local start = math.max(1, #content - (o.max_log_lines - 1))
        for i = start, #content do
            f:write(("%s\n"):format(content[i]))
        end
    end
    if not delete then
        f:write(("[%s] \"%s\" | %s\n"):format(os.date(o.date_format), cur_title, cur_path))
    end
    f:close()
    if dyn_menu.ready then
        update_dyn_menu_items()
    end
end

--list ass style
list.indent = [[]]
list.wrap = false
list.num_entries = o.num_entries
-- trailing \N reproduces the blank line the original had between the
-- header and the first entry (format_header only adds one newline itself)
list.header = [[[Recent]\N]]
list.header_style = string.format([[{\fscx%f}{\fscy%f}{\bord%f}{\1c&H808080}]],
    o.font_scale * 3 / 4, o.font_scale * 3 / 4, o.border_size * 3 / 4)
-- explicit color reset per row: without it, grey (from the header) or the
-- highlight color (from a cursor row) leaks into every row that follows
list.list_style = string.format([[{\1c&HFFFFFF}{\fscx%f}{\fscy%f}{\bord%f}]], o.font_scale, o.font_scale, o.border_size)
-- reuses scroll-list.lua's shared wrapper_color (same yellow track-list.lua
-- uses for its "N item(s) above/remaining" text) instead of picking its own
list.wrapper_style = string.format([[{\c%s}{\fscx%f}{\fscy%f}{\bord%f}]], list.wrapper_color,
    o.font_scale * 3 / 4, o.font_scale * 3 / 4, o.border_size * 3 / 4)
local hi_style = string.format([[{\1c&H%s}]], o.hi_color)
list.cursor_style = hi_style
list.selected_style = hi_style
list.cursor = marker("➤") .. [[\h]]

-- builds the scroll-list items from a read_log_table() result (oldest first),
-- newest first to match how the list has always been displayed
local function build_list_items(entries)
    local reversed = table_reverse(entries)
    local items = {}
    for i, entry in ipairs(reversed) do
        local p
        if o.show_paths then
            if o.split_paths or is_protocol(entry.path) then
                p = get_filename(entry)
            else
                p = entry.path or ""
            end
        else
            p = entry.title or entry.path or ""
        end
        p = p:gsub("\\", "\\\239\187\191"):gsub("{", "\\{"):gsub("^ ", "\\h")
        items[i] = {
            path = entry.path,
            title = entry.title,
            date = entry.date,
            ass = string.format("(%s) %s", entry.date, strip_title(p))
        }
    end
    return items
end

-- Open the recent submenu for uosc
function open_menu(lists)
    local menu = {
        type = 'recent_menu',
        title = 'Recent',
        items = {{
            title = 'Nothing here',
            value = 'ignore'
        }}
    }
    local length
    if #lists > o.num_entries then
        length = o.num_entries
    else
        length = #lists
    end
    for i = 1, length do
        menu.items[i] = {
            title = o.show_paths and strip_title(split_ext(get_filename(lists[#lists - i + 1]))) or
                strip_title(split_ext(lists[#lists - i + 1].title)),
            hint = get_ext(lists[#lists - i + 1].path),
            value = {"loadfile", lists[#lists - i + 1].path, "replace"}
        }
    end
    local json = utils.format_json(menu)
    mp.commandv('script-message-to', 'uosc', 'open-menu', json)
end

-- play last played file
function play_last()
    local lists = read_log_table()
    if not lists or not lists[1] then
        return
    end
    mp.commandv("loadfile", lists[#lists].path, "replace")
end

local function load_by_index(idx)
    local item = list.list[idx]
    list:close()
    if not item then
        return
    end
    if o.write_watch_later then
        mp.command("write-watch-later-config")
    end
    mp.commandv("loadfile", item.path, "replace")
end

local function load_selected()
    load_by_index(list.selected)
end

-- jumps to the nth currently visible row (1-indexed), matching the numeric keybinds
local function load_visible_row(n)
    load_by_index((list.window_start or 1) + (n - 1))
end

local function delete_selected()
    local item = list.list[list.selected]
    if not item then
        return
    end

    local playing_path, playing_title = cur_path, cur_title
    cur_path, cur_title = item.path, item.title
    write_log(true)
    print("Deleted \"" .. cur_path .. "\"")
    cur_path, cur_title = playing_path, playing_title

    local entries = read_log_table()
    if not entries or not entries[1] then
        list:close()
        return
    end
    if o.hide_same_dir then
        entries = hide_same_dir(entries)
    end
    list.list = build_list_items(entries)
    if list.selected > #list.list then
        list.selected = #list.list
    end
    list:update()
end

list.keybinds = {
    {'UP', 'scroll_up', function() list:scroll_up() end, {repeatable = true}},
    {'DOWN', 'scroll_down', function() list:scroll_down() end, {repeatable = true}},
    {'ENTER', 'load_entry', function() load_selected() end, {}},
    {'DEL', 'delete_entry', function() delete_selected() end, {repeatable = true}},
    {'ESC', 'close_list', function() list:close() end, {}}
}
if o.mouse_controls then
    table.insert(list.keybinds, {'WHEEL_UP', 'wheel_up', function() list:scroll_up() end, {}})
    table.insert(list.keybinds, {'WHEEL_DOWN', 'wheel_down', function() list:scroll_down() end, {}})
    table.insert(list.keybinds, {'MBTN_MID', 'mid_click', function() load_selected() end, {}})
    table.insert(list.keybinds, {'MBTN_RIGHT', 'right_click', function() list:close() end, {}})
end
for i = 1, 9 do
    table.insert(list.keybinds, {tostring(i), 'jump_' .. i, function() load_visible_row(i) end, {}})
end
table.insert(list.keybinds, {'0', 'jump_10', function() load_visible_row(10) end, {}})

-- Display list and add keybinds
function display_list()
    if not list.hidden then
        list:close()
        return
    end

    local entries = read_log_table()
    if not entries or not entries[1] then
        mp.osd_message("Log empty")
        return
    end
    if o.hide_same_dir then
        entries = hide_same_dir(entries)
    end
    if uosc_available then
        open_menu(entries)
        return
    end

    list.list = build_list_items(entries)
    list.selected = 1
    list:update()
    list:open()
end

-- remember if a youtube playlist has been passed
function catch_playlist(property, value)
    if value ~= nil then
        if (value:match("playlist%?list=") ~= nil) then
            playlist_url = value
            playlist_given = true
        else
            if (playlist_given == true) then
                -- var for comparing playlist
                playlist_first_entry = mp.get_property("playlist/0/filename")
                playlist_given = false
                return
            end
            if mp.get_property_number("playlist-count") > 1 and mp.get_property("playlist/0/filename") ==
                playlist_first_entry then
                return
            end
            playlist_url = ""
            playlist_first_entry = ""
        end
    end
end

local function run_idle()
    mp.observe_property("idle-active", "bool", function(_, v)
        if o.auto_run_idle and v and not uosc_available then
            display_list()
        end
    end)
end

-- for custom playlist detection
mp.observe_property("path", "string", catch_playlist)

-- mpv-menu-plugin integration
mp.register_script_message('menu-ready', function()
    dyn_menu.ready = true
    update_dyn_menu_items()
end)

-- check if uosc is running
mp.register_script_message('uosc-version', function(version)
    uosc_available = true
end)
mp.commandv('script-message-to', 'uosc', 'get-version', mp.get_script_name())

mp.observe_property("display-hidpi-scale", "native", function(_, scale)
    if scale then
        display_scale = scale
        run_idle()
    end
end)

mp.register_event("file-loaded", function()
    list:close()
    cur_title, cur_path = get_path()
end)

-- Using hook, as at the "end-file" event the playback position info is already unset.
mp.add_hook("on_unload", 9, function()
    if not o.auto_save then
        return
    end
    local pos = mp.get_property("percent-pos")
    if not pos then
        return
    end
    if tonumber(pos) <= o.auto_save_skip_past then
        write_log(false)
    else
        write_log(true)
    end
end)

mp.add_key_binding(o.display_bind, "display-recent", display_list)
mp.add_key_binding(o.save_bind, "recent-save", function()
    write_log(false)
    mp.osd_message("Saved entry to log")
end)
mp.add_key_binding(nil, "play-last", play_last)
