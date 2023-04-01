local base = require("wibox.widget.base")
local beautiful = require("beautiful")
local awful = require("awful")
local common = require("awful.widget.common")
local fixed = require("wibox.layout.fixed")
local gears = require("gears")
local gdebug = require("gears.debug")
local gtable = require("gears.table")
local timer = require("gears.timer")
local wibox = require("wibox")
local lgi = require("lgi")
local Gio = lgi.Gio
local GLib = lgi.GLib
local GObject = lgi.GObject

-- Connect so system DBus
local system_bus = nil

-- global device manager state
local signals = {}
local device_manager = gears.object()
device_manager.drives = {}
device_manager.block_devices = {}


local function script_dir()
	local str = debug.getinfo(2, "S").source:sub(2)
	return str:match("(.*/)")
end


local function object_changed(a, b)
	for key, value in pairs(a) do
		if value ~= b[key] and key ~= 'Drive' then
			return true
		end
		if a['Drive'] ~= nil and b['Drive'] ~= nil and object_changed(a['Drive'], b['Drive']) then
			return true
		end
	end
	return false
end

local function update_list(old, new, cb_create, cb_remove, cb_change)
	local to_remove = {}
	local to_check = {}
	for path, info in pairs(new) do
		if old[path] == nil then
			old[path] = info
			cb_create(path, info)
		else
			table.insert(to_check, path)
		end
	end
	for path, info in pairs(old) do
		if new[path] == nil then
			table.insert(to_remove, path)
		end
	end
	for _, path in ipairs(to_remove) do
		local instance = old[path]
		old[path] = nil
		cb_remove(path, instance)
	end
	for _, path in ipairs(to_check) do
		if object_changed(old[path], new[path]) then
			local instance = old[path]
			local old_instance = {}
			gtable.crush(old_instance, old[path], true)
			gtable.crush(old[path], new[path], true)
			cb_change(path, new[path], old_instance)
		end
	end
end

local function parse_devices(conn, res, callback)
	local ret, err = system_bus:call_finish(res)

	if err then
		print(err)
		return
	end

	local drives = {}
	local block_devices = {}

	local object_list = ret:get_child_value(0)
	for num = 0, #object_list-1 do
		local dev_info = object_list:get_child_value(num)
		local path = dev_info[1]
		local device_data = dev_info[2]

		local drive_data = device_data['org.freedesktop.UDisks2.Drive']
		local block_data = device_data['org.freedesktop.UDisks2.Block']
		local filesystem_data = device_data['org.freedesktop.UDisks2.Filesystem']

		if drive_data ~= nil then
			-- retrieve drive info object or create
			local drive_info = drives[path]
			if drive_info == nil then
				drive_info = {}
			end
			drive_info['path'] = path
			drives[path] = drive_info
			-- fill important properties
			for __, attribute in ipairs({'CanPowerOff', 'ConnectionBus', 'Id', 'Ejectable', 'Media', 'MediaAvailable', 'MediaRemovable', 'Model', 'Removable', 'Serial', 'Size', 'SortKey', 'Vendor'}) do
				drive_info[attribute] = drive_data[attribute]
			end
		end

		if block_data ~= nil then
			local block_info = {}
			local drive_path = block_data['Drive']
			if drive_path ~= '/' then
				-- get drive info or create (later fill in loop)
				local drive_info = drives[block_data['Drive']]
				if drive_info == nil then
					drive_info = {}
					drives[drive_path] = drive_info
				end
				block_info['Drive'] = drive_info
				block_info['path'] = path

				for __, attribute in ipairs({'HintAuto', 'HintIconName', 'HintIgnore', 'HintName', 'HintPartitionable', 'HintSymbolicIconName', 'HintSystem', 'Id', 'IdLabel', 'IdType', 'IdUUID', 'IdUsage', 'IdVersion', 'ReadOnly', 'Size'}) do
					block_info[attribute] = block_data[attribute]
				end
				block_info['HasFilesystem'] = filesystem_data ~= nil
				block_info['Mounted'] = false
				if filesystem_data ~= nil then
					block_info['Mounted'] = filesystem_data['MountPoints'][1]
					if block_info['Mounted'] == nil then
						block_info['Mounted'] = false
					end
				end

				block_devices[path] = block_info
			end
		end
	end

	local changed = false

	update_list(
		device_manager.drives,
		drives,
		function(path, new) -- on create
			device_manager:emit_signal('drive_created', {path = path, new = new})
			changed = true
		end,
		function(path, old) -- on remove
			device_manager:emit_signal('drive_removed', {path = path, old = old})
			changed = true
		end,
		function(path, new, old) -- on change
			device_manager:emit_signal('drive_changed', {path = path, new = new, old = old})
			changed = true
		end
	)
	update_list(
		device_manager.block_devices,
		block_devices,
		function(path, new) -- on create
			device_manager:emit_signal('block_device_created', {path = path, new = new})
			changed = true
		end,
		function(path, old) -- on remove
			device_manager:emit_signal('block_device_removed', {path = path, old = old})
			changed = true
		end,
		function(path, new, old) -- on change
			device_manager:emit_signal('block_device_changed', {path = path, new = new, old = old})
			changed = true
		end
	)

	if changed then
		device_manager:emit_signal('changed')
	end
end


local function rescan_devices()
	system_bus:call(
		'org.freedesktop.UDisks2',
		'/org/freedesktop/UDisks2',
		'org.freedesktop.DBus.ObjectManager',
		'GetManagedObjects',
		nil,
		nil,
		Gio.DBusConnectionFlags.NONE,
		-1,
		nil,
		function(conn, res)
			parse_devices(conn, res, callback)
		end
	)
end


local function register_listeners()
	rescan_devices()
	system_bus:signal_subscribe(
		'org.freedesktop.UDisks2',
		'org.freedesktop.DBus.ObjectManager',
		'InterfacesAdded',
		nil,
		nil,
		Gio.DBusSignalFlags.NONE,
		function(conn, sender, path, interface_name, signal_name, user_data)
			rescan_devices()
		end
	)
	system_bus:signal_subscribe(
		'org.freedesktop.UDisks2',
		'org.freedesktop.DBus.ObjectManager',
		'InterfacesRemoved',
		nil,
		nil,
		Gio.DBusSignalFlags.NONE,
		function(conn, sender, path, interface_name, signal_name, user_data)
			rescan_devices()
		end
	)
	system_bus:signal_subscribe(
		'org.freedesktop.UDisks2',
		'org.freedesktop.DBus.Properties',
		'PropertiesChanged',
		nil,
		nil,
		Gio.DBusSignalFlags.NONE,
		function(conn, sender, path, interface_name, signal_name, user_data)
			rescan_devices()
		end
	)
end


local udisks_mount_widget = { mt = {} }

local function get_screen(s)
	return s and screen[s]
end

local function default_template(w)
	return {
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
			self.tooltip:set_text(udisks_mount_widget.get_name(device))
			if w._private.stylesheet ~= nil and icon ~= nil then
				icon.stylesheet = w._private.stylesheet
			end
		end,
		update_callback = function(self, device, index, objects)
			self.update_common(self, device, index, objects)
			self.tooltip:set_text(udisks_mount_widget.get_name(device))
		end,
	}
end

local function widget_name(device, args, tb)
	local icon_name = device['Drive']['Media'] or 'storage'
	local suffix = ''
	local prefix = 'udisks_'
	local theme = beautiful.get()

	if not icon_name or icon_name == '' then
		icon_name = device['Drive']['ConnectionBus']
	end

	if device['Mounted'] then
		suffix = '_mounted'
	end

	local final_icon = theme[prefix .. 'storage']
	if theme[prefix .. icon_name] ~= nil then
		final_icon = theme[prefix .. icon_name]
	end
	if theme['udisks_storage' .. suffix] ~= nil then
		final_icon = theme['udisks_storage' .. suffix]
	end
	if theme[prefix .. icon_name .. suffix] ~= nil then
		final_icon = theme[prefix .. icon_name .. suffix]
	end

	local text = udisks_mount_widget.get_name(device)
	local bg_color = theme[prefix .. 'bg' .. suffix]
	local bg_image = theme[prefix .. 'image' .. suffix]

	if final_icon == nil then
		if icon_name == 'thumb' or device['Drive']['ConnectionBus'] == 'usb' then
			icon_name = 'thumb'
		else
			icon_name = 'storage'
		end
		final_icon = script_dir() .. '/icons/' .. icon_name .. '.svg'
	end

	return text, bg_color, bg_image, final_icon, {}
end

local function widget_update(s, self, buttons, filter, data, style, update_function, args)
	local function label(c, tb) return widget_name(c, style, tb) end
	local devices = {}
	for __, device in pairs(device_manager.block_devices) do
		if self._private.filter(device) then
			table.insert(devices, device)
		end
	end

	update_function(self._private.base_layout, buttons, label, data, devices, {
		widget_template = self._private.widget_template or default_template(self),
		create_callback = create_callback,
	})
end

function udisks_mount_widget:layout(_, width, height)
	if self._private.base_layout then
		return { base.place_widget_at(self._private.base_layout, 0, 0, width, height) }
	end
end

function udisks_mount_widget:fit(context, width, height)
	if not self._private.base_layout then
		return 0, 0
	end

	return base.fit_widget(self, context, self._private.base_layout, width, height)
end

udisks_mount_widget.filter = {}

function udisks_mount_widget.filter.removable(v)
	return v['Drive'] ~= nil and v['Drive']['Removable'] and v['HasFilesystem']
end

function udisks_mount_widget:set_base_layout(layout)
	self._private.base_layout = base.make_widget_from_value(
		layout or fixed.horizontal
	)

	assert(self._private.base_layout.is_widget)

	self._do_update()

	self:emit_signal("widget::layout_changed")
	self:emit_signal("widget::redraw_needed")
	self:emit_signal("property::base_layout", layout)
end

function udisks_mount_widget.mount(device, cb)
	if device['Mounted'] then
		if cb ~= nil then
			cb(device["Mounted"], device, nil)
		end
	else
		system_bus:call(
			'org.freedesktop.UDisks2',
			device['path'],
			'org.freedesktop.UDisks2.Filesystem',
			'Mount',
			GLib.Variant.new_tuple({
				GLib.Variant('a{sv}', {})
			}, 1),
			nil,
			Gio.DBusConnectionFlags.NONE,
			-1,
			nil,
			function(conn, res)
				local ret, err = system_bus:call_finish(res)
				local path = nil
				if not err then
					path = ret.value[1]
					device['Mounted'] = path
				end
				if cb ~= nil then
					cb(path, device, err)
				end
			end
		)
	end
end

function udisks_mount_widget.unmount(device, cb)
	if device['Mounted'] then
		local path = device['Mounted']
		system_bus:call(
			'org.freedesktop.UDisks2',
			device['path'],
			'org.freedesktop.UDisks2.Filesystem',
			'Unmount',
			GLib.Variant.new_tuple({
				GLib.Variant('a{sv}', {})
			}, 1),
			nil,
			Gio.DBusConnectionFlags.NONE,
			-1,
			nil,
			function(conn, res)
				local ret, err = system_bus:call_finish(res)
				if cb ~= nil then
					cb(path, device, err)
				end
			end
		)
	else
		if cb ~= nil then
			cb(nil, device, "Device not mounted")
		end
	end
end

function udisks_mount_widget.eject(device, cb)
	local path = device['Mounted']
	if device['Drive']['Ejectable'] then
		system_bus:call(
			'org.freedesktop.UDisks2',
			device['Drive']['path'],
			'org.freedesktop.UDisks2.Drive',
			'Eject',
			GLib.Variant.new_tuple({
				GLib.Variant('a{sv}', {})
			}, 1),
			nil,
			Gio.DBusConnectionFlags.NONE,
			-1,
			nil,
			function(conn, res)
				local ret, err = system_bus:call_finish(res)
				if cb ~= nil then
					cb(path, device, err)
				end
			end
		)
	else
		cb(path, device, "Device not ejectable")
	end
end

function udisks_mount_widget.unmount_and_eject(device, cb)
	udisks_mount_widget.unmount(device, function(path, device, err)
		local outer_path = path
		udisks_mount_widget.eject(device, function(path, device, err)
			cb(outer_path, device, err)
		end)
	end)
end

function udisks_mount_widget.get_name(device)
	local text = device['HintName']
	if not text or text == '' then
		if device['Drive'] ~= nil then
			text = device['Drive']['Serial']
		end
		if device['IdLabel'] and device['IdLabel'] ~= '' then
			text = text .. " " .. device['IdLabel']
		else
			text = text .. " " .. device['IdUUID']
		end
	end
	return text
end

local function new(args)
	local w = base.make_widget(nil, nil, {
		enable_properties = true,
	})

	local screen = get_screen(args.screen)
	local uf = args.update_function or common.list_update

	gtable.crush(w, udisks_mount_widget, true)
	gtable.crush(w._private, {
		style = args.style or {},
		stylesheet = args.stylesheet,
		buttons = args.buttons,
		update_function = args.update_function,
		widget_template = args.widget_template,
		filter = args.filter or udisks_mount_widget.filter.removable,
		screen = screen
	})

	w._private.pending_update = false

	local data = setmetatable({}, { __mode = 'k' })

	function w._do_update_now()
		widget_update(w._private.screen, w, w._private.buttons, w._private.filter, data, args.style, uf, args)
		w._private.pending_update = false
	end

	function w._do_update()
		if not w._private.pending_update then
			timer.delayed_call(w._do_update_now)
			w._private.pending_update = true
		end
	end

	function w._on_devices_changed()
		w._do_update()
	end

	w:set_base_layout()
	device_manager:weak_connect_signal('changed', w._on_devices_changed)

	gtable.crush(w, udisks_mount_widget, true)

	return w
end

function udisks_mount_widget.mt:__call(...)
	return new(...)
end


function udisks_mount_widget.start_monitor()
	Gio.bus_get(
		Gio.BusType.SYSTEM,
		Gio.Cancellable(),
		function (object, result)
			local connection, err = Gio.bus_get_finish(result)
			if err then
				print(tostring(err))
			else
				system_bus = connection
				register_listeners()
			end
		end
	)
end


udisks_mount_widget.device_manager = device_manager


return setmetatable(udisks_mount_widget, udisks_mount_widget.mt)
