# Automounter for awesome wm

## Usage

- Left click - mount
- Right click - unmount

## Configuration

rc.lua:

    udisks = require("udisks")
    udisks.filemanager = "konqueror"
    ...
    right_layout:add(udisks.widget)


theme.lua:

    theme.removable_default_mounted   = themes_dir .. "/icons/removable_default_mounted.png"
    theme.removable_default_unmounted = themes_dir .. "/icons/removable_default_unmounted.png"
    theme.removable_usb_mounted       = themes_dir .. "/icons/removable_usb_mounted.png"
    theme.removable_usb_unmounted     = themes_dir .. "/icons/removable_usb_unmounted.png"

Icons are in
[this repository](https://github.com/mireq/awesome-config)

## Screenshot

![Screenshot](https://raw.github.com/wiki/mireq/awesome-udisks2-mount/automount.gif)
