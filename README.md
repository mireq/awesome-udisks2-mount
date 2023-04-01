# Automounter for awesome wm

## Install

Clone repository to `~/.config/awesome`

## Configure

Add following code to rc.lua to initialize mounter:

    local udisks_mount = require("awesome-udisks2-mount.udisks")
    udisks_mount.start_monitor()

Now it's possible to add widget to taskbar. Following snippet belongs to
`request::desktop_decoration` signal handling. Example is verbose to demonstrate
customization ability. In most cases there is no need to define custom `filter` or
`widget_template.

    local filemanager = 'nautilus'

    local function on_mount(path, err)
        if err then
            naughty.notify({
                preset = naughty.config.presets.critical,
                text = tostring(err),
            })
        else
            if path ~= nil and filemanager ~= nil then
                awful.spawn({filemanager, path})
            end
        end
    end

    local function on_unmount(path, err)
        if err then
            naughty.notify({
                preset = naughty.config.presets.critical,
                text = tostring(err),
            })
        end
    end

    s.udisks_mount = udisks_mount({
        screen = s,
        stylesheet = 'svg { color: ' .. beautiful.fg_normal .. '; }',
        filter = function(dev) return dev['Drive'] ~= nil and dev['Drive']['Removable'] and dev['HasFilesystem']; end,
        widget_template = {
            id = 'background_role',
            widget = wibox.container.background,
            {
                id = 'icon_margin_role',
                widget = wibox.container.margin,
                {
                    id = 'icon_role',
                    widget = wibox.widget.imagebox,
                },
            },
            update_common = function(self, device, index, objects)
                local icon = self:get_children_by_id('icon_role')[1]
                if icon ~= nil then
                    local opacity = beautiful.udisks_opacity
                    if device['Mounted']  then
                        opacity = beautiful.udisks_opacity_mounted
                    end
                    if opacity == nil then
                        opacity = 1
                    end
                    icon:set_opacity(opacity)
                end
            end,
            create_callback = function(self, device, index, objects)
                local icon = self:get_children_by_id('icon_role')[1]
                self.update_common(self, device, index, objects)
                self.tooltip = awful.tooltip({ objects = { self } })
                self.tooltip:set_text(udisks_mount.get_name(device))
                icon.stylesheet = 'svg { color: ' .. beautiful.fg_normal .. '; }'
            end,
            update_callback = function(self, device, index, objects)
                self.update_common(self, device, index, objects)
                self.tooltip:set_text(udisks_mount.get_name(device))
            end,
        },
        buttons = gears.table.join(
            awful.button({ }, 1, function(dev)
                udisks_mount.mount(dev, function(path, dev, err)
                    on_mount(path, err)
                end)
            end),
            awful.button({ }, 3, function(dev)
                local menu = {}
                local open_label = "Open"
                if not dev['Mounted'] then
                    open_label = "Mount"
                end
                table.insert(menu, {open_label, function()
                    dev.menu = nil
                    udisks_mount.mount(dev, function(path, dev, err)
                        on_mount(path, err)
                    end)
                end})
                if dev['Drive']['Ejectable'] then
                    table.insert(menu, {"Eject", function()
                        dev.menu = nil
                        udisks_mount.unmount_and_eject(dev, function(path, dev, err)
                            on_unmount(path, err)
                        end)
                    end})
                end
                if dev['Mounted'] then
                    table.insert(menu, {"Unmount", function()
                        dev.menu = nil
                        udisks_mount.unmount(dev, function(path, dev, err)
                            on_unmount(path, err)
                        end)
                    end})
                end

                if dev.menu ~= nil then
                    dev.menu:hide()
                    dev.menu = nil
                else
                    dev.menu = awful.menu(menu)
                    dev.menu:show()
                end
            end)
        )
    })

Minimal useable configuration:

    s.udisks_mount = udisks_mount({
        screen = s,
        buttons = gears.table.join(
            -- mount on left click and open file manager
            awful.button({ }, 1, function(dev)
                udisks_mount.mount(dev, function(path, dev, err)
                    if path ~= nil then
                        awful.spawn({'nautilus', path})
                    end
                end)
            end),
            -- unmount on right click
            awful.button({ }, 3, udisks_mount.unmount_and_eject)
        )
    })

## Theme

Icons are configurable using theme file. To change icons create theme entry with
this structure:

    udisks_(storage type)[_mounted]

Storage type is something like `'optical'`, `'thumb'`, `'usb'` or `'storage'` as
fallback.

    theme.udisks_storage = themes_dir .. "/icons/storage.svg"
    theme.udisks_thumb = themes_dir .. "/icons/thumb.svg"
    theme.udisks_usb = themes_dir .. "/icons/thumb.svg"

There is support for unmounted drive opacity:

    theme.udisks_opacity = 0.5
    theme.udisks_opacity_mounted = 1.0

or background:

    theme.udisks_bg = '#0000ff'
    theme.udisks_bg_mounted = '#ff0000'

## Device manager API

Current drives and devices are available using
`udisks_mount.device_manager.(drives|block_devices)`.

Change monitoring is supported using signals:

    udisks_mount.device_manager:connect_signal('drive_created', function(self, d) print("device_created " .. d.new.Model); end)
    udisks_mount.device_manager:connect_signal('drive_removed', function(self, d) print("device_removed " .. d.old.Model); end)
    udisks_mount.device_manager:connect_signal('drive_changed', function(self, d) print("device_changed " .. d.new.Model); end)
    udisks_mount.device_manager:connect_signal('block_device_created', function(self, d) print("device_created " .. udisks_mount.get_name(d.new)); end)
    udisks_mount.device_manager:connect_signal('block_device_removed', function(self, d) print("device_removed " .. udisks_mount.get_name(d.old)); end)
    udisks_mount.device_manager:connect_signal('block_device_changed', function(self, d) print("device_changed " .. udisks_mount.get_name(d.new)); end)

## Screenshot

![Screenshot](https://raw.github.com/wiki/mireq/awesome-udisks2-mount/automount.gif?v=2023-04-01)
