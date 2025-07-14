local o = {
    -- What bind brings up help
    bind = "h",
    -- Max number of lines to display according to player height
    max_lines = 36,
    -- Max number of character for one line of bind
    max_char = 80,
    -- Number of columns
    max_columns = 4,
    -- Font scale
    font_scale = 80,
    title_font_scale = 75,
    -- Font colors
    font_color = "HFFFFFF",
    title_font_color = "H808080",
    font_bind_color = "H66FFFF"
}
(require "mp.options").read_options(o)
local msg = require("mp.msg")
local help_displayed = false

function display_overlay()
    local binds = mp.get_property_native("input-bindings")
    local osd_text = string.format("{\\fscx%f}{\\fscy%f}{\\1c&%s}[Help]\\N\\N{\\fscx%f}{\\fscy%f}", o.title_font_scale, o.title_font_scale, o.title_font_color, o.font_scale, o.font_scale)
    local text_right = false
    local added_text = ""
    local text_pos = 1
    local key, cmd
    
    -- debug
    -- msg.warn("bind : "..binds[35]["key"])
    -- msg.warn("command : "..binds[35]["cmd"])
    
    for i=1, o.max_lines*o.max_columns do
        -- skip if unbinded
        if binds[i]["cmd"] ~= "ignore" then
            -- debug
            msg.warn("\nKey : "..binds[i]["key"])
            msg.warn("Command : "..binds[i]["cmd"])
            -- msg.warn(binds[i]["comment"])
            
            -- decide what to display
            key = binds[i]["key"]
            cmd = binds[i]["cmd"]
            
            -- format what will be added to the overlay
            added_text = string.format("{\\1c&%s}"..key.."{\\1c&%s} . . . "..cmd, o.font_bind_color, o.font_color)
            
            -- choose how to append the text to the overlay
            if #added_text <= o.max_char then
                if text_pos < o.max_columns then
                    local spacing = ""
                    
                    for ii = 1, (o.max_char - #added_text)*1.8 do
                        spacing = spacing.." "
                    end
                    
                    msg.warn("string length : "..#added_text)
                    msg.warn("spacing : "..#spacing)
                    
                    osd_text = osd_text..added_text..spacing
                    text_pos = text_pos + 1
                else
                    osd_text = osd_text..added_text.."\\N"
                    text_pos = 1
                end
            end
        end
    end
    
    mp.osd_message(" ", 0.1)
    mp.set_osd_ass(0, 0, osd_text)
end

function bind()
    mp.add_forced_key_binding("ESC", "help-ESC", toggle_help)
    mp.add_forced_key_binding("ENTER", "help-ENTER", toggle_help)
end

function unbind()
    mp.remove_key_binding("help-ESC")
    mp.remove_key_binding("help-ENTER")
end

function toggle_help()
    -- hide if displayed
    if help_displayed then
        mp.set_osd_ass(0, 0, "")
        unbind()
        help_displayed = false
        return
    end
    
    display_overlay()
    bind()
    help_displayed = true
end

mp.add_key_binding(o.bind, "toggle-help", toggle_help)
