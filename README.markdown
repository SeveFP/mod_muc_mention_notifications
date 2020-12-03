## Requirements

This module currently depends on mod_muc_markers, so review the requirements for that module.

# Configuring

## Enabling

``` {.lua}
Component "rooms.example.net" "muc"
modules_enabled = {
    "muc_room_mention_notifications";
    "muc_markers";
    "muc_mam";
}
```

## Settings

|Name |Description |Default |
|-----|------------|--------|
|muc_mentions_max_subscribers| Maximum number of active subscriptions allowed | 1024 |

# Usage
Clients can start receiving room mention notifications by sending a presence stanza including `<mentions>` element to the MUC service:
```
<presence to="chat.example.org" id="dwZ3vL">
  <mentions xmlns="urn:xmpp:rmn:0"/>
</presence>
```


# Compatibility

Requires Prosody trunk (2020-04-15+).
