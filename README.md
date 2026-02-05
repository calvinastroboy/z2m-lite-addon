# Z2M Lite - Home Assistant Add-on

A simplified, mobile-first Zigbee2MQTT management panel.

## Installation

1. In Home Assistant, go to **Settings → Add-ons → Add-on Store**
2. Click the **⋮** menu → **Repositories**
3. Add: `https://github.com/calvinastroboy/z2m-lite-hacs`
4. Find **Z2M Lite** in the store and install
5. Start the add-on — it auto-discovers your Z2M installation
6. Click **Open Web UI** or find it in the sidebar

## Features

- 📱 Mobile-first dark theme UI
- 🔍 **Auto-discovery** — finds your Z2M addon automatically, zero config
- 💡 Device control — toggle, brightness, color temperature
- 🔌 Multi-gang switch support (per-channel control)
- 👥 Group management — create groups, add/remove devices
- 🏠 Room organization
- ✏️ Device rename
- 🔗 WebSocket proxy — browser only needs to reach HA, not Z2M directly
- 🌐 Ingress support — opens right inside HA sidebar

## Screenshots

| Home | Device Detail | Groups |
|------|--------------|--------|
| Device grid with live status | Control panel + device info | Group with member management |

## Architecture

```
Browser → HA Ingress → Z2M Lite (nginx) → /z2m-ws → Zigbee2MQTT WebSocket
```

The add-on runs nginx which:
1. Serves the React frontend
2. Proxies WebSocket connections to Z2M
3. Auto-discovers Z2M via HA Supervisor API

No direct browser access to Z2M needed!
