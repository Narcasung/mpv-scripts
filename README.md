# auto4k.lua

Script to remember Anime4k (https://github.com/bloc97/Anime4K) status on file or folder basis by generating and reading a log file in mpv config's folder.

Comes with a folder or file mode. Folder mode will silently enable Anime4k to the saved mode for all the files in the folder. File mode does so on a per file basis.
Web videos will only work in file mode.
If a file has both a file and a folder config saved, the file config will take precedence.

Once an unrecognized file loads, a prompt will ask whether to activate Anime4k for the folder/file.
Choosing yes will activate the default Anime4k mode (default: A) and save the choice for the whole folder/file.
Choosing no will disable Anime4k and save the choice for the whole folder/file.
If you want to change your choice, use `k` (default) to bring up the prompt again.
From there you can also press the `delete` key to wipe the current folder/file info from the log.

## install

Just drop auto4k.lua in the `MPV/scripts` folder.

### changes to make in input.conf

For the script to work correctly, you need to override the Anime4k input commands with these custom ones:

```
Ctrl+1 script-binding auto4k-A
Ctrl+2 script-binding auto4k-B
Ctrl+3 script-binding auto4k-C
Ctrl+7 script-binding auto4k-clear
```
and
```
k script-binding display-auto4k
```

to display the prompt manually.
You can of course change the keybind to whatever you want to prevent conflict with the rest of your inputs.

### options

Comes with configurable options:

```ini
# log file path, default in mpv config's root folder
log_path=~~home/auto4k.log
# anime4k shaders path. if installed correctly in MPV/shaders/, don't touch anything
shader_path=~~/shaders/
# displays the prompt on an unrecognized file or folder
auto_run=yes
# whether to display a simple yes/no prompt on unrecognized file/folder, or a more detailed prompt with all modes
prompt_yes_no=yes
# the default mode that will be activated if you choose yes. A, B, or C
default_yes_mode=A
# what mode(s) of the script is activated. "folder", "file", or "both"
script_mode=both
# whether the script starts in folder mode or file mode
default_folder_mode=yes
font_size=100
max_log_lines=1000
```

Put in auto4k.conf in `MPV/script-opts`. A sample file is available.

# recent.lua

Fork from https://github.com/hacel/recent.
Removed manual save and number selection feature.
Added youtube playlist support and log culling feature.
Changed the overlay appearance to look like Blackbox.
The source script changed a lot since I made this, maybe I'll update it in the future.

# (WIP) help.lua

Displays a list of mpv's commands and their associated keybinds. Doesn't work for now, don't download.