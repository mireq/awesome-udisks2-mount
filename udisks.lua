local capi = { dbus = dbus }
local lgi       = require 'lgi'
local Gio       = lgi.require 'Gio'
local GLib      = lgi.require 'GLib'
local wibox     = require("wibox")
local beautiful = require("beautiful")
local awful     = require("awful")
local naughty   = require("naughty")

local system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)

local devices = {}
local module = {};
local devices_layout = wibox.layout.fixed.horizontal()


local function isempty(s)
	return s == nil or s == ''
end


local function open_filemanger(device)
	if module.filemanager == nil then
	else
		awful.util.spawn_with_shell(module.filemanager .. ' "' .. device.Mounted .. '"');
	end
end


local function mount_device(device)
	if device.Mounted then
		open_filemanger(device);
	else
		ret, err = system_bus:call(
			'org.freedesktop.UDisks2',
			'/org/freedesktop/UDisks2/block_devices/' .. device.Device,
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
				local ret, err = system_bus:call_finish(res);
				if err then
					naughty.notify({
						preset = naughty.config.presets.critical,
						text = tostring(err),
					});
				else
					device.Mounted = tostring(ret.value[1]);
					open_filemanger(device);
				end
			end
		);
	end

end


local function unmount_device(device)
	if device.Mounted then
		ret, err = system_bus:call(
			'org.freedesktop.UDisks2',
			'/org/freedesktop/UDisks2/block_devices/' .. device.Device,
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
				local ret, err = system_bus:call_finish(res);
				if err then
					naughty.notify({
						preset = naughty.config.presets.critical,
						text = tostring(err),
					});
				end
			end
		);
	end
end


local function parse_block_devices(conn, res, callback)
	local ret, err = system_bus:call_finish(res);
	local xml = ret.value[1];

	if err then
		print(err);
		return;
	end

	for device in string.gmatch(xml, 'name="([^"]*)"') do
		devices[device] = {};
	end

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
			local ret, err = system_bus:call_finish(res);
			local value = ret.value[1];
			if err then
				print(err)
				callback(devices);
				return
			end

			for device_name, _ in pairs(devices) do
				local device_path = '/org/freedesktop/UDisks2/block_devices/' .. device_name;
				local device = value[device_path];
				if device and device['org.freedesktop.UDisks2.Filesystem'] and value[device['org.freedesktop.UDisks2.Block']['Drive']] then
					local mounted = device['org.freedesktop.UDisks2.Filesystem']['MountPoints'][1]
					local drive = value[device['org.freedesktop.UDisks2.Block']['Drive']]['org.freedesktop.UDisks2.Drive'];
					if mounted == nil then
						mounted = false
					else
						mounted = tostring(mounted)
					end
					devices[device_name] = {
						OK = true,
						Drive = device['org.freedesktop.UDisks2.Block'].Drive,
						Device = device_name,
						Mounted = mounted,
						Removable = drive.Removable,
						Name = '',
						ConnectionBus = drive.ConnectionBus,
					}
					if not isempty(drive.Vendor) then
						devices[device_name].Name = drive.Vendor .. ' ';
					end
					if not isempty(drive.Model) then
						devices[device_name].Name = devices[device_name].Name .. drive.Model;
					end
				else
					devices[device_name] = nil;
				end
			end
			callback(devices);
		end
	);
end


local function rescan_devices(callback)
	system_bus:call(
		'org.freedesktop.UDisks2',
		'/org/freedesktop/UDisks2/block_devices',
		'org.freedesktop.DBus.Introspectable',
		'Introspect',
		nil,
		nil,
		Gio.DBusConnectionFlags.NONE,
		-1,
		nil,
		function(conn, res)
			parse_block_devices(conn, res, callback);
		end
	);
end


local function scan_finished(devices)
	devices_layout:reset();
	for device, data in pairs(devices) do
		if data.Removable and data.OK then
			local bus_type = data.ConnectionBus;
			local status = 'unmounted';
			local icon_name = '';
			if data.Mounted then
				status = 'mounted';
			end
			if not bus_type then
				bus_type = 'default';
			end
			icon_name = 'removable_' .. bus_type .. '_' .. status;
			if beautiful[icon_name] == nil then
				bus_type = 'default'
				icon_name = 'removable_' .. bus_type .. '_' .. status;
			end

			deviceicon = wibox.widget.imagebox();
			deviceicon:set_image(beautiful[icon_name]);
			deviceicon:buttons(awful.util.table.join(
				awful.button({ }, 1, function () mount_device(data); end),
				awful.button({ }, 3, function () unmount_device(data); end)
			))

			devices_layout:add(deviceicon);

			local tooltip = awful.tooltip({ objects = { deviceicon } });
			tooltip:set_text(data.Name);
		end
	end
end


if capi.dbus then
	capi.dbus.add_match("system", "interface='org.freedesktop.DBus.ObjectManager', member='InterfacesAdded'")
	capi.dbus.add_match("system", "interface='org.freedesktop.DBus.ObjectManager', member='InterfacesRemoved'")
	capi.dbus.connect_signal("org.freedesktop.DBus.ObjectManager",
		function (data, text)
			if data.path == "/org/freedesktop/UDisks2" then
				rescan_devices(scan_finished);
			end
		end
	);
end

rescan_devices(scan_finished);

module.widget = devices_layout;
return module
