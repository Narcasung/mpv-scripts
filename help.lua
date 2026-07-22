local o = {
    -- What bind brings up help
    bind = "h",
    -- Number of entries listed per column, the column header sitting on top
    max_lines = 27,
    -- Max number of character for one line of bind
    max_char = 50,
    -- Number of columns
    max_columns = 3,
    -- Font scale
    font_scale = 100,
    title_font_scale = 75,
    search_font_scale = 75,
    -- Font colors
    font_color = "HFFFFFF",
    title_font_color = "H808080",
    font_bind_color = "H66FFFF",
    cursor_font_color = "H00FF00",
    script_font_color = "HAAAAFF",
    -- Margins, in canvas units (see CANVAS_H below)
    margin_x = 20,
    margin_y = 20,
    -- Gap kept between two columns, in canvas units
    column_gap = 30
}
(require "mp.options").read_options(o)
local msg = require("mp.msg")

--the overlay is laid out on a virtual canvas 720 units tall, which is the unit
--osd-font-size is already defined in ("size in scaled pixels at a window height
--of 720"), so the layout keeps the same proportions at any window size
local CANVAS_H = 720
--rough line height of the OSD font, as a multiple of the font size, used to
--leave room for the title above the columns
local LINE_SPACING = 1.4
--minimum blank room left between a key and its command, in characters. the two
--are drawn as separate flush-left/flush-right blocks, so this is only a
--budgeting hint to keep a long command from running into its key
local MIN_GAP_CHARS = 3

--broadcast on open so the other list scripts (track-list.lua, recent.lua,
--auto4k.lua through scroll-list.lua, and Blackbox.js) close their own list,
--since they all share OSD overlay id 0 and their keybinds would otherwise
--fight each other
local CLOSE_OTHERS_MESSAGE = 'mpv-scripts-close-other-lists'
local SCRIPT_NAME = mp.get_script_name()

--shared property so unrelated scripts (e.g. modernx.lua's idle screen) can
--tell whether any of these lists is currently on screen and yield to it.
--holds the owning script's name rather than a plain boolean so a delayed
--cross-script close can't clobber a different list that has since opened
local LIST_OPEN_PROPERTY = 'user-data/mpv-scripts/list-open'

--➤ (Dingbats) isn't in the OSD font (Poppins), so without an explicit \fn it
--falls back to whatever font Windows picks for the glyph. forcing Segoe UI
--Symbol keeps it consistent with the other scripts' cursor, and scaling it down
--a notch keeps its visual weight in line with the surrounding text
local SYMBOL_FONT = "Segoe UI Symbol"
local CURSOR = string.format("{\\fn%s\\fscx%f\\fscy%f}➤{\\fn\\fscx%f\\fscy%f}\\h",
    SYMBOL_FONT, o.font_scale * 0.75, o.font_scale * 0.75, o.font_scale, o.font_scale)
--the same glyph made invisible: same font, same width, so it holds the indent
--on rows the cursor isn't on and every command keeps one shared left edge
local BLANK_CURSOR = "{\\alpha&HFF&}" .. CURSOR .. "{\\alpha&H00&}"

local help_displayed = false
--selection is a flat index into the displayed entries; the grid is filled
--column-major, so moving by 1 walks down a column and moving by a full column
--height jumps sideways. the layout figures are refreshed on every build
local state = {
    selected = 1,
    -- current search text, and the entries left once it has been applied
    query = "",
    visible = {},
    -- leftmost column currently on screen, 1-based
    first_col = 1,
    total = 0,
    total_cols = 1,
    -- filled in by the layout: entries making up each column, and the column
    -- and position within it that each entry landed on
    columns = {},
    entry_col = {},
    entry_pos = {},
    entries = nil
}

--LuaJIT has no utf8 library, so count characters by skipping continuation
--bytes (0x80-0xBF), which never start a character
local function utf8_len(str)
    local n = 0
    for i = 1, #str do
        local b = str:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end

local function utf8_sub(str, len)
    local chars, i = 0, 1
    while i <= #str do
        if chars >= len then return str:sub(1, i - 1) end
        local b = str:byte(i)
        i = i + (b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4)
        chars = chars + 1
    end
    return str
end

--same technique as mangle_ass() in mpv's osd_libass.c: keep backslashes literal
--by following them with a word joiner, and stop '{' from opening an override
--block. '}' needs no escaping, it prints literally when orphaned.
--without this, a bind like `c show_text ${chapter-list}` eats the rest of the
--overlay, since libass parses its '{' as the start of a tag block
local function ass_escape(str)
    return (str:gsub("\\", "\\\226\129\160"):gsub("{", "\\{"))
end

local function capitalize(str)
    return (str:gsub("^%l", string.upper))
end

--script bindings come through as "script-binding stats/display-stats", and mpv
--hands the ones it registers itself over with an input prefix attached too, as
--in "nonscalable script-binding ...". neither says anything worth a third of
--the line here, so both lead-ins collapse to the same "Script"
local function shorten_cmd(cmd)
    local rest = cmd:match("^nonscalable%s+script%-binding%s+(.+)$")
        or cmd:match("^script%-binding%s+(.+)$")
    if rest then return "Script " .. rest, true end

    --a script message has no binding handle to point at, so input.conf has to
    --fire it through "script-message-to <script> <message>". folded into the
    --same shape as the bindings above, script and message joined by a slash
    local script, message = cmd:match("^script%-message%-to%s+(%S+)%s+(.+)$")
    if script then return "Script " .. script .. "/" .. message, true end

    return cmd, false
end

local function truncate(str, max)
    if utf8_len(str) <= max then return str end
    return utf8_sub(str, math.max(1, max - 1)) .. "…"
end

--packs an entry's keys into as few lines as it takes. every line gets the same
--width, since the command is repeated down the left of all of them, and a
--trailing comma marks that the list carries on below
local function wrap_keys(keys, budget)
    local lines, current = {}, nil
    budget = math.max(4, budget)

    for _, key in ipairs(keys) do
        if not current then
            current = truncate(key, budget)
        elseif utf8_len(current) + 2 + utf8_len(key) <= budget then
            current = current .. ", " .. key
        else
            lines[#lines + 1] = current .. ","
            current = truncate(key, budget)
        end
    end

    if current then lines[#lines + 1] = current end
    return lines
end

--between two bindings still competing for the same key: higher priority wins,
--then a strong binding over a weak one (is_weak means user bindings take
--precedence over it), then whichever mpv listed last
local function outranks(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    if a.is_weak ~= b.is_weak then return a.is_weak < b.is_weak end
    return a.index > b.index
end

--mpv gives every binding a priority and documents a negative one as "inactive
--and will not be triggered by input", which is how a shadowed binding is
--marked, so dropping those leaves only what a key press actually runs: an
--input.conf entry survives, the builtin default it overrides doesn't.
--mpv also warns the value "is dynamic and can change around at runtime", hence
--re-reading it on each open instead of holding onto it across them
local function collect_binds()
    local binds = mp.get_property_native("input-bindings")
    local entries, winner = {}, {}
    if not binds then return entries end

    for i, bind in ipairs(binds) do
        -- skip if unbinded or shadowed by another binding
        if bind.key and bind.cmd and bind.cmd ~= "ignore" and (bind.priority or 0) >= 0 then
            local cmd, is_script = shorten_cmd(bind.cmd)
            local entry = {
                key = bind.key,
                cmd = capitalize(cmd),
                -- kept verbatim so the entry can still be run as written
                raw = bind.cmd,
                is_script = is_script,
                priority = bind.priority or 0,
                is_weak = bind.is_weak and 1 or 0,
                index = i
            }
            local held = winner[bind.key]

            if not held then
                entries[#entries + 1] = entry
                winner[bind.key] = entry
            elseif outranks(entry, held) then
                -- overwritten in place so the list keeps mpv's ordering
                held.cmd, held.raw, held.is_script, held.priority, held.is_weak, held.index =
                    entry.cmd, entry.raw, entry.is_script, entry.priority, entry.is_weak, entry.index
            end
        end
    end

    --several keys often run the very same command, so they're folded into one
    --entry listing all of them rather than a screenful of identical lines
    local groups, by_cmd = {}, {}
    for _, entry in ipairs(entries) do
        local group = by_cmd[entry.cmd]
        if not group then
            group = {
                cmd = entry.cmd,
                raw = entry.raw,
                is_script = entry.is_script,
                keys = {}
            }
            by_cmd[entry.cmd] = group
            groups[#groups + 1] = group
        end
        group.keys[#group.keys + 1] = entry.key
    end

    --sorted by command so related bindings end up next to each other (every
    --"Add volume" in a row), and each entry's own keys sorted between them
    for _, group in ipairs(groups) do table.sort(group.keys) end
    table.sort(groups, function(a, b)
        local cmd_a, cmd_b = a.cmd:lower(), b.cmd:lower()
        if cmd_a ~= cmd_b then return cmd_a < cmd_b end
        return a.keys[1] < b.keys[1]
    end)
    return groups
end

local function canvas_size()
    local w, h = mp.get_osd_size()
    if not w or not h or w <= 0 or h <= 0 then
        return CANVAS_H * 16 / 9, CANVAS_H
    end
    return CANVAS_H * w / h, CANVAS_H
end

local function build_ass()
    --collected once per open and reused for every redraw. the list has to be
    --read before this script's own menu keys are bound: once UP/DOWN/LEFT/RIGHT
    --are held forced, mpv marks the real bindings behind them inactive and the
    --dedupe above drops them, so re-reading on a cursor move would make the
    --arrow keys vanish from the list the moment you used them
    local entries = state.entries
    if not entries then
        entries = collect_binds()
        state.entries = entries
    end
    --the search matches what's actually on screen: the command as displayed and
    --each of the entry's keys. matched as plain text rather than as a lua
    --pattern, so typing a "-" or a "+" searches for that character
    local query = state.query
    local visible = entries
    if query ~= "" then
        local needle = query:lower()
        visible = {}
        for _, entry in ipairs(entries) do
            local hit = entry.cmd:lower():find(needle, 1, true) ~= nil
            if not hit then
                for _, key in ipairs(entry.keys) do
                    if key:lower():find(needle, 1, true) then
                        hit = true
                        break
                    end
                end
            end
            if hit then visible[#visible + 1] = entry end
        end
    end
    state.visible = visible
    entries = visible

    local res_x, res_y = canvas_size()
    local osd_size = mp.get_property_number("osd-font-size", 22)

    local title_size = osd_size * (o.title_font_scale / 100)
    local search_size = osd_size * (o.search_font_scale / 100)
    -- the search line sits under the title, and the columns start below it. the
    -- room it takes is reserved whether or not a search is running, so the list
    -- can't jump down a row the moment one starts
    local search_y = o.margin_y + title_size * LINE_SPACING
    local body_y = search_y + search_size * LINE_SPACING

    local lines_per_col = math.max(1, o.max_lines)
    local col_w = (res_x - o.margin_x * 2) / o.max_columns
    local total = #entries
    local room = math.max(8, o.max_char)
    -- ceiling on what a single key may claim, so one long key name can't eat
    -- the command's whole line
    local max_reserve = math.floor(room / 3)

    --laid out before anything is placed, because an entry whose keys wrap runs
    --taller than one line and that height is what the packing below works off
    local rows = {}
    for i, entry in ipairs(entries) do
        --the keys spill onto lines of their own when they run out of room, so
        --the command only has to leave space for the first of them rather than
        --surrendering a fixed share of the line
        local reserve = math.min(utf8_len(entry.keys[1] or ""), max_reserve)
        local cmd = truncate(entry.cmd, math.max(8, room - MIN_GAP_CHARS - reserve))
        local key_lines = wrap_keys(entry.keys, room - utf8_len(cmd) - MIN_GAP_CHARS)
        rows[i] = {
            cmd = cmd,
            is_script = entry.is_script,
            keys = key_lines,
            height = #key_lines
        }
    end

    --entries are packed into columns by height and never split across two, so
    --a column holds however many happen to fit rather than a fixed count
    local columns, entry_col, entry_pos = {}, {}, {}
    local current, used = {}, 0
    for i, row in ipairs(rows) do
        if used > 0 and used + row.height > lines_per_col then
            columns[#columns + 1] = current
            current, used = {}, 0
        end
        current[#current + 1] = i
        entry_col[i] = #columns + 1
        entry_pos[i] = #current
        used = used + row.height
    end
    if #current > 0 then columns[#columns + 1] = current end
    local total_cols = math.max(1, #columns)

    -- the movement keys work off these, and the binding list can change under
    -- us between two opens, so they're refreshed here rather than cached
    state.total = total
    state.total_cols = total_cols
    state.columns = columns
    state.entry_col = entry_col
    state.entry_pos = entry_pos
    state.selected = math.max(1, math.min(state.selected, math.max(total, 1)))

    --max_columns is a window onto the full set of columns rather than the whole
    --list: it slides just far enough to keep the cursor's column inside it, so
    --walking off the right edge shifts everything one column left
    local sel_col = entry_col[state.selected] or 1
    local first_col = state.first_col
    if sel_col < first_col then first_col = sel_col end
    if sel_col > first_col + o.max_columns - 1 then
        first_col = sel_col - o.max_columns + 1
    end
    -- never scroll past the point where the last column sits at the right edge
    first_col = math.max(1, math.min(first_col, math.max(1, total_cols - o.max_columns + 1)))
    state.first_col = first_col

    local events = {
        string.format("{\\an7\\q2\\pos(%.1f,%.1f)}{\\fscx%f\\fscy%f}{\\1c&%s&}[Help] %d/%d",
            o.margin_x, o.margin_y, o.title_font_scale, o.title_font_scale,
            o.title_font_color, state.selected, total)
    }

    if query ~= "" then
        events[#events + 1] = string.format(
            "{\\an7\\q2\\pos(%.1f,%.1f)}{\\fscx%f\\fscy%f}{\\1c&%s&}Search: " ..
                "{\\1c&%s&}%s{\\1c&%s&}\\h\\h\\hPress ESC to clear",
            o.margin_x, search_y,
            o.search_font_scale, o.search_font_scale,
            o.title_font_color, o.font_color, ass_escape(query), o.title_font_color)
    end

    if total == 0 then
        events[#events + 1] = string.format(
            "{\\an7\\q2\\pos(%.1f,%.1f)}{\\fscx%f\\fscy%f}{\\1c&%s&}No match",
            o.margin_x, body_y, o.font_scale, o.font_scale, o.title_font_color)
    end

    for slot = 0, o.max_columns - 1 do
        local col = first_col + slot
        local column = columns[col]
        if not column then break end

        --the column's number heads both blocks, at the entry font scale so the
        --two keep matching line heights and stay row-aligned. it's numbered
        --against the whole list, not the window, so it tracks the scrolling.
        --indented like a command so the column keeps one left edge
        local keys = {"\\h"}
        local cmds = {
            "{\\1c&" .. o.title_font_color .. "&}" .. BLANK_CURSOR ..
                col .. "/" .. total_cols
        }

        for _, idx in ipairs(column) do
            local row = rows[idx]
            local cmd = row.cmd
            local selected = (idx == state.selected)

            local arrow = selected and CURSOR or BLANK_CURSOR
            --colour is re-stated per line because tags carry over across \N
            local base = selected and o.cursor_font_color or o.font_color
            local text = ass_escape(cmd)

            --only the "Script" word carries the script colour, the name after
            --it reads as a normal command. the cursor outranks it entirely,
            --otherwise the cursor would vanish on a script line. the match can
            --fail if truncation ate into the word, which just leaves it plain
            if not selected and row.is_script then
                local head, tail = cmd:match("^(Script)%s(.*)$")
                if head then
                    text = "{\\1c&" .. o.script_font_color .. "&}" .. head ..
                        "{\\1c&" .. o.font_color .. "&}\\h" .. ass_escape(tail)
                end
            end

            --the command is repeated opposite every row of wrapped keys, which
            --also keeps the two blocks on the same line count so they stay in
            --step. only the first row carries the cursor
            cmds[#cmds + 1] = "{\\1c&" .. base .. "&}" .. arrow .. text
            for _ = 2, row.height do
                cmds[#cmds + 1] = "{\\1c&" .. base .. "&}" .. BLANK_CURSOR .. text
            end
            for _, key_line in ipairs(row.keys) do
                keys[#keys + 1] = ass_escape(key_line)
            end
        end

        --a column is justified by drawing it as two blocks instead of one:
        --commands flush left (\an7) and keys flush right (\an9) against the
        --column's right edge, so both edges line up without measuring any text.
        --filling the middle with spaces instead can't work, the OSD font is
        --proportional so no amount of spaces lines two rows up.
        --each block is its own ASS event, since osd_libass.c starts a new event
        --on every newline, and that's what lets each one carry its own \pos
        if #keys > 0 then
            -- placed by its slot in the window, not by its index in the list
            local left = o.margin_x + slot * col_w
            local right = left + col_w - o.column_gap

            events[#events + 1] = string.format("{\\an7\\q2\\pos(%.1f,%.1f)}{\\fscx%f\\fscy%f}{\\1c&%s&}%s",
                left, body_y, o.font_scale, o.font_scale,
                o.font_color, table.concat(cmds, "\\N"))
            events[#events + 1] = string.format("{\\an9\\q2\\pos(%.1f,%.1f)}{\\fscx%f\\fscy%f}{\\1c&%s&}%s",
                right, body_y, o.font_scale, o.font_scale,
                o.font_bind_color, table.concat(keys, "\\N"))
        end
    end

    return table.concat(events, "\n"), res_x, res_y
end

local function display_overlay()
    local ok, data, res_x, res_y = pcall(build_ass)
    if not ok then
        msg.error("couldn't build the help overlay: " .. tostring(data))
        mp.osd_message("[Help] couldn't build the list, see the log")
        return false
    end

    mp.set_osd_ass(res_x, res_y, data)
    return true
end

--moves the cursor down/up the column, flowing into the next/previous one at
--the ends so there's no dead end to get stuck on. running off the last visible
--column scrolls the window, which build_ass works out from the new selection
local function move_row(delta)
    if state.total < 1 then return end

    local target = state.selected + delta
    -- past either end, carry on round to the other one
    if target < 1 then target = state.total
    elseif target > state.total then target = 1 end

    state.selected = target
    display_overlay()
end

--jumps a whole column sideways, landing on the entry sitting at the same place
--down the column. columns hold varying numbers of entries now that one can run
--several rows tall, so a shorter column settles on its last entry
local function move_column(delta)
    local count = #state.columns
    if count < 1 then return end

    local col = (state.entry_col[state.selected] or 1) + delta
    -- past either edge, carry on round to the column at the other end
    if col < 1 then col = count
    elseif col > count then col = 1 end

    local target = state.columns[col]
    if not target then return end

    state.selected = target[math.min(state.entry_pos[state.selected] or 1, #target)]
    display_overlay()
end

--every change to the search re-filters the list, so the cursor and the column
--window start over rather than pointing at whatever used to sit there
local function set_query(query)
    if query == state.query then return end

    state.query = query
    state.selected = 1
    state.first_col = 1
    display_overlay()
end

--ANY_UNICODE catches every key that produces text, which saves binding the
--whole keyboard one key at a time. the complex form is what carries key_text,
--and the event filter keeps a single press from typing twice
local function type_query(event)
    if type(event) ~= "table" or not event.key_text then return end
    if event.event ~= "down" and event.event ~= "repeat" and event.event ~= "press" then
        return
    end

    set_query(state.query .. event.key_text)
end

local function backspace()
    if state.query == "" then return end
    set_query(utf8_sub(state.query, utf8_len(state.query) - 1))
end

-- declared up here so the keybinds can reach it before hide_help exists
local run_selected

local KEYBINDS = {
    {"UP", "help-up", function() move_row(-1) end, {repeatable = true}},
    {"DOWN", "help-down", function() move_row(1) end, {repeatable = true}},
    {"LEFT", "help-left", function() move_column(-1) end, {repeatable = true}},
    {"RIGHT", "help-right", function() move_column(1) end, {repeatable = true}},
    {"BS", "help-backspace", function() backspace() end, {repeatable = true}},
    {"ANY_UNICODE", "help-search", type_query, {complex = true, repeatable = true}},
    -- a first press drops the search, a second one closes the list
    {"ESC", "help-ESC", function()
        if state.query ~= "" then set_query("") else toggle_help() end
    end, {}},
    {"ENTER", "help-ENTER", function() run_selected() end, {}}
}

local function bind()
    for _, v in ipairs(KEYBINDS) do
        mp.add_forced_key_binding(v[1], v[2], v[3], v[4])
    end
end

local function unbind()
    for _, v in ipairs(KEYBINDS) do
        mp.remove_key_binding(v[2])
    end
end

local function hide_help()
    if not help_displayed then return end
    help_displayed = false
    state.entries = nil
    state.visible = {}
    unbind()
    --only clear the property if we're still its recorded owner
    if mp.get_property_native(LIST_OPEN_PROPERTY) == SCRIPT_NAME then
        mp.set_property_native(LIST_OPEN_PROPERTY, false)
    end
    mp.set_osd_ass(0, 0, "")
end

--runs whatever the cursor is on, as the key bound to it would have. the list
--goes away first: the command is free to print to the OSD or open a list of
--its own, and this script's forced keybinds have to be off the way by then
run_selected = function()
    -- indexed against what's on screen, which the search may have narrowed
    local entry = state.visible and state.visible[state.selected]
    hide_help()
    if not entry or not entry.raw then return end

    -- passed as written, prefixes and all, for mpv to parse the way it would
    -- have off a real key press
    local ok, err = mp.command(entry.raw)
    if not ok then
        msg.error('couldn\'t run "' .. entry.raw .. '": ' .. tostring(err))
        mp.osd_message("[Help] couldn't run that command, see the log")
    end
end

local function show_help()
    mp.commandv('script-message', CLOSE_OTHERS_MESSAGE, SCRIPT_NAME)
    -- clears any OSD message sitting on top of the list (osd-playing-msg etc.)
    mp.osd_message(" ", 0.1)
    -- the list is rebuilt from scratch on every open, so the cursor and the
    -- column window start over
    state.selected = 1
    state.first_col = 1
    state.query = ""
    state.entries = nil
    -- drawn before bind() on purpose, see the note in build_ass
    if not display_overlay() then return end
    if not help_displayed then bind() end
    help_displayed = true
    -- claimed after the broadcast above, so the lists closing by it can't
    -- clear the property back out from under us
    mp.set_property_native(LIST_OPEN_PROPERTY, SCRIPT_NAME)
end

function toggle_help()
    if help_displayed then hide_help() else show_help() end
end

--closes this list when another script's list opens; sender name check stops
--the script from closing its own list off its own broadcast
mp.register_script_message(CLOSE_OTHERS_MESSAGE, function(sender)
    if sender ~= SCRIPT_NAME then hide_help() end
end)

--the layout is built against the current aspect ratio, so it has to be redone
--when the window is resized while the list is up
mp.observe_property("osd-dimensions", "native", function()
    if help_displayed then display_overlay() end
end)

mp.add_key_binding(o.bind, "toggle-help", toggle_help)
