local cache = require "util.cache";
local jid = require "util.jid";
local st = require "util.stanza";
local datetime = require "util.datetime";

local muc_markers = module:depends("muc_markers");

local max_subscribers = module:get_option_number("muc_mention_notifications_max_subscribers", 1024);

local muc_affiliation_store = module:open_store("config", "map");
local muc_archive = module:open_store("muc_log", "archive");

local mention_notifications_xmlns = "urn:xmpp:rmn:0";
local reference_xmlns = "urn:xmpp:reference:0";
local forwarded_xmlns = "urn:xmpp:forward:0";
local deplay_xmlns = "urn:xmpp:delay";

-- subscriber_jid -> { [room_jid] = interested }
local subscribed_users = cache.new(max_subscribers, false);
-- room_jid -> { [user_bare_jid] = interested }
local interested_users = {};

-- Send a single notification for a room, updating data structures as needed
local function send_single_notification(user_bare_jid, room_jid, mention_stanza)
	local notification = st.message({ to = user_bare_jid, from = module.host })
		:tag("mentions", { xmlns = mention_notifications_xmlns })
		:tag("forwarded", {xmlns = forwarded_xmlns})
		:tag("delay", {xmlns = deplay_xmlns, stamp = datetime.datetime()}):up()
		:add_child(mention_stanza)
		:reset();
	module:log("debug", "Sending mention notification from %s to %s", room_jid, user_bare_jid);
	return module:send(notification);
end

local function get_mentions(stanza)
	local has_mentions = false
	local client_mentions = {}

	for element in stanza:childtags("reference", reference_xmlns) do
		if element.attr.type == "mention" then
			local user_bare_jid = element.attr.uri:match("^xmpp:(.+)$");
			if user_bare_jid then
				client_mentions[user_bare_jid] = user_bare_jid;
				has_mentions = true
			end
		end
	end

	return has_mentions, client_mentions
end

local function subscribe_room(user_bare_jid, room_jid)
	local interested_rooms = subscribed_users:get(user_bare_jid);
	if not interested_rooms then
		return nil, "not-subscribed";
	end
	module:log("debug", "Subscribed %s to %s", user_bare_jid, room_jid);
	interested_rooms[room_jid] = true;

	local interested_room_users = interested_users[room_jid];
	if not interested_room_users then
		interested_room_users = {};
		interested_users[room_jid] = interested_room_users;
	end
	interested_room_users[user_bare_jid] = true;
	return true;
end

local function unsubscribe_room(user_bare_jid, room_jid)
	local interested_rooms = subscribed_users:get(user_bare_jid);
	if not interested_rooms then
		return nil, "not-subscribed";
	end
	interested_rooms[room_jid] = nil;

	local interested_room_users = interested_users[room_jid];
	if not interested_room_users then
		return true;
	end
	interested_room_users[user_bare_jid] = nil;
	return true;
end

local function notify_interested_users(room_jid, client_mentions, mention_stanza)
	module:log("warn", "NOTIFYING FOR %s", room_jid)
	local interested_room_users = interested_users[room_jid];
	if not interested_room_users then
		module:log("debug", "Nobody interested in %s", room_jid);
		return;
	end
	for user_bare_jid in pairs(client_mentions) do
		if interested_room_users[user_bare_jid] then
			send_single_notification(user_bare_jid, room_jid, mention_stanza);
		end
	end
	return true;
end

local function unsubscribe_user_from_all_rooms(user_bare_jid)
	local interested_rooms = subscribed_users:get(user_bare_jid);
	if not interested_rooms then
		return nil, "not-subscribed";
	end
	for room_jid in pairs(interested_rooms) do
		unsubscribe_room(user_bare_jid, room_jid);
	end
	return true;
end

-- Returns a set of rooms that a user is interested in
local function get_interested_rooms(user_bare_jid)
	-- Use affiliation as an indication of interest, return
	-- all rooms a user is affiliated
	return muc_affiliation_store:get_all(jid.bare(user_bare_jid));
end

local function is_subscribed(user_bare_jid)
	return not not subscribed_users:get(user_bare_jid);
end

-- Subscribes to all rooms that the user has an interest in
-- Returns a set of room JIDs that have already had activity (thus no subscription)
local function subscribe_all_rooms(user_bare_jid)
	if is_subscribed(user_bare_jid) then
		return nil;
	end

	-- Send activity notifications for all relevant rooms
	local interested_rooms, err = get_interested_rooms(user_bare_jid);

	if not interested_rooms then
		if err then
			return nil, "internal-server-error";
		end
		interested_rooms = {};
	end

	if not subscribed_users:set(user_bare_jid, {}) then
		module:log("warn", "Subscriber limit (%d) reached, rejecting subscription from %s", max_subscribers, user_bare_jid);
		return nil, "resource-constraint";
	end

	for room_name in pairs(interested_rooms) do
		local room_jid = room_name.."@"..module.host;
		-- Subscribe to any future activity
		subscribe_room(user_bare_jid, room_jid);
	end
	return true;
end

module:hook("muc-occupant-joined", function(event)
	local room_jid, user_bare_jid = event.room.jid, jid.bare(event.stanza.attr.from);
	local ok, err = unsubscribe_room(user_bare_jid, room_jid);
	if ok then
		module:log("debug", "Unsubscribed " .. user_bare_jid .. " from " .. room_jid .. " Reason: muc-occupant-joined")
	end
end);

module:hook("muc-occupant-left", function(event)
	local room_jid, user_bare_jid = event.room.jid, jid.bare(event.stanza.attr.from);
	local ok, err = subscribe_room(user_bare_jid, room_jid);
	if ok then
		module:log("debug", "Subscribed " .. user_bare_jid .. " to " .. room_jid .. " Reason: muc-occupant-left")
	end
end);

module:hook("presence/host", function (event)
	local origin, stanza = event.origin, event.stanza;
	local user_bare_jid = jid.bare(event.stanza.attr.from);

	if stanza.attr.type == "unavailable" then -- User going offline
		unsubscribe_user_from_all_rooms(user_bare_jid);
		return true;
	end

	if not stanza:get_child("mentions", mention_notifications_xmlns) then
		return; -- Ignore, no <mentions/> tag
	end

	module:log("debug", "Subscription request from " .. user_bare_jid);
	local ok, err = subscribe_all_rooms(user_bare_jid);

	if not ok then
		return origin.send(st.error_reply(stanza, "wait", err));
	end
	return true;
end);

module:hook("muc-broadcast-message", function (event)
	local room, stanza = event.room, event.stanza;
	local body = stanza:get_child_text("body")
    if not body or #body < 1 then return; end
	local has_mentions, client_mentions = get_mentions(stanza)
	if not has_mentions then return; end

	-- Notify any users that need to be notified
	notify_interested_users(room.jid, client_mentions, stanza);
end, -1);
