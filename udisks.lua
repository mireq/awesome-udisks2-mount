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


local function mount_device(device)
	if not device.Mounted then
		ret, err = system_bus:call_sync(
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
			nil
		);

		if err then
			naughty.notify({
				preset = naughty.config.presets.critical,
				text = tostring(err),
			});
		else
			device.Mounted = tostring(ret.value[1]);
		end
	end

	if module.filemanager == nil then
	else
		awful.util.spawn_with_shell(module.filemanager .. ' ' .. device.Mounted);
	end
end


local function unmount_device(device)
	if device.Mounted then
		ret, err = system_bus:call_sync(
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
			nil
		);

		if err then
			naughty.notify({
				preset = naughty.config.presets.critical,
				text = tostring(err),
			});
		end
	end
end


local function parse_block_devices(conn, res, callback)
	local ret, err = system_bus:call_finish(res);
	local xml = ret.value[1];
	local waiting_for = 0;
	for device in string.gmatch(xml, 'name="([^"]*)"') do
		devices[device] = {};
		waiting_for = waiting_for + 1;
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
			if err == nil then
				for device_name, _ in pairs(devices) do
					local device = '/org/freedesktop/UDisks2/block_devices/' .. device_name;
					if value[device] and value[device]['org.freedesktop.UDisks2.Filesystem'] then
						devices[device_name] = {}
						local device_data = {
							OK = true,
							Drive = value[device]['org.freedesktop.UDisks2.Block']['Drive'],
							Device = device_name,
						}
						system_bus:call(
							'org.freedesktop.UDisks2',
							device_data.Drive,
							'org.freedesktop.DBus.Properties',
							'GetAll',
							GLib.Variant.new_tuple({
								GLib.Variant('s', 'org.freedesktop.UDisks2.Drive')
							}, 1),
							nil,
							Gio.DBusConnectionFlags.NONE,
							-1,
							nil,
							function(conn, res)
								local ret, err = system_bus:call_finish(res);
								if err == nil then
									local value = ret.value[1];
									device_data.ConnectionBus = value.ConnectionBus;
									device_data.Removable = value.Removable;
									device_data.Name = '';
									if not isempty(value.Vendor) then
										device_data.Name = value.Vendor .. ' ';
									end
									if not isempty(value.Model) then
										device_data.Name = device_data.Name .. value.Model;
									end

									system_bus:call(
										'org.freedesktop.UDisks2',
										device,
										'org.freedesktop.DBus.Properties',
										'GetAll',
										GLib.Variant.new_tuple({
											GLib.Variant('s', 'org.freedesktop.UDisks2.Filesystem')
										}, 1),
										nil,
										Gio.DBusConnectionFlags.NONE,
										-1,
										nil,
										function(conn, res)
											local ret, err = system_bus:call_finish(res);
											if err == nil then
												local value = ret.value[1];
												if value.MountPoints[1] == nil then
													device_data.Mounted = false;
												else
													device_data.Mounted = tostring(value.MountPoints[1]);
												end
												devices[device_name] = device_data;
											else
												print(err);
											end

											waiting_for = waiting_for - 1;
											if waiting_for == 0 then
												callback(devices);
											end
										end
									);


								else
									print(err);
									waiting_for = waiting_for - 1;
									if waiting_for == 0 then
										callback(devices);
									end
								end
							end
						)
					else
						devices[device_name] = nil;
						waiting_for = waiting_for - 1;
						if waiting_for == 0 then
							callback(devices);
						end
					end
				end
			else
				print(err)
				callback(devices);
			end
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
		if data.Removable then
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
