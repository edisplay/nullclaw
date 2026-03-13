# Max Messenger Channel — Design Spec

**Date:** 2026-03-12
**Status:** Approved
**Scope:** Full-featured Max messenger channel for NullClaw

## Overview

Add support for the Max messenger (platform-api.max.ru) as a new channel in NullClaw. Max is a Russian messenger (formerly VK Teams) with a Telegram-like Bot API. The channel supports both long polling and webhook modes, text + media attachments, inline keyboards with callback handling, streaming via message editing, typing indicators, and deep links.

## Max Bot API Summary

- **Base URL:** `https://platform-api.max.ru`
- **Auth:** Header `Authorization: <token>`
- **Rate limit:** 30 RPS
- **Message limit:** 4000 characters
- **Text format:** Markdown and HTML (we use Markdown)
- **Updates:** Long polling via `GET /updates` (marker-based pagination), Webhook via `POST /subscriptions`
- **Attachment types:** image, video, audio, file, sticker, contact, share, location, inline_keyboard
- **Button types:** callback, link, request_contact, request_geo_location, open_app, message
- **Chat types:** DIALOG, CHAT, CHANNEL
- **Update types:** message_created, message_edited, message_removed, message_callback, bot_started, bot_stopped, bot_added, bot_removed, user_added, user_removed, chat_title_changed, dialog_removed, dialog_cleared

### Key Differences from Telegram Bot API

- Auth via header (not URL path)
- REST-style endpoints: `POST /messages`, `PUT /messages`, `DELETE /messages`
- Query params for IDs (`?chat_id=`, `?message_id=`)
- `marker` is a string (not numeric offset)
- 4000 char limit (vs 4096 Telegram)
- No forum topics (DIALOG/CHAT/CHANNEL only)
- Button `intent` field (POSITIVE/NEGATIVE/DEFAULT)
- Webhook verification via `X-Max-Bot-Api-Secret` header

## Architecture

### Approach

Single `MaxChannel` struct with internal mode switching (polling vs webhook). Same pattern as Slack's `mode: .socket / .http`.

### File Structure

```
src/channels/
  max.zig              # MaxChannel struct, VTable (all 9 methods), send/receive, streaming, interactions
  max_api.zig          # HTTP client for platform-api.max.ru
  max_ingress.zig      # Update JSON parsing -> ChannelMessage
```

### Integration Points (8 files to modify)

1. `build.zig` — `enable_channel_max` in ChannelSelection + parser + addOption
2. `src/config_types.zig` — MaxConfig, MaxInteractiveConfig, MaxListenerMode; ChannelsConfig.max + maxPrimary()
3. `src/channels/root.zig` — `pub const max = @import("max.zig");`
4. `src/channel_catalog.zig` — `.max` in ChannelId + known_channels entry
5. `src/channel_loop.zig` — `runMaxLoop()` for polling mode
6. `src/gateway.zig` — POST `/webhook/max` handler for webhook mode
7. `src/main.zig` — `runMaxChannel()` for standalone `nullclaw channel max`
8. `src/channel_manager.zig` — MaxChannel.initFromConfig() + registry registration

## Configuration

```zig
pub const MaxConfig = struct {
    account_id: []const u8 = "default",
    bot_token: []const u8,
    allow_from: []const []const u8 = &.{},
    group_allow_from: []const []const u8 = &.{},
    group_policy: []const u8 = "allowlist",
    proxy: ?[]const u8 = null,
    mode: MaxListenerMode = .polling,
    webhook_url: ?[]const u8 = null,
    webhook_secret: ?[]const u8 = null,
    interactive: MaxInteractiveConfig = .{},
    require_mention: bool = false,
    streaming: bool = true,
};

pub const MaxListenerMode = enum { polling, webhook };

pub const MaxInteractiveConfig = struct {
    enabled: bool = false,
    ttl_secs: u64 = 900,
    owner_only: bool = true,
};
```

## max_api.zig — HTTP Client

| Method | HTTP | Endpoint | Purpose |
|---|---|---|---|
| `getMe()` | GET | `/me` | Token verification, bot info |
| `sendMessage(chat_id, body)` | POST | `/messages?chat_id={id}` | Send message |
| `editMessage(message_id, body)` | PUT | `/messages?message_id={id}` | Edit (for streaming) |
| `deleteMessage(message_id)` | DELETE | `/messages?message_id={id}` | Delete message |
| `answerCallback(callback_id, answer)` | POST | `/answers?callback_id={id}` | Answer inline button click |
| `getUpdates(marker, types, timeout)` | GET | `/updates?marker=&timeout=&types=` | Long polling |
| `subscribe(url, types, secret)` | POST | `/subscriptions` | Set webhook |
| `unsubscribe(url)` | DELETE | `/subscriptions?url={url}` | Remove webhook |
| `sendAction(chat_id, action)` | POST | `/chats/{chat_id}/actions` | Typing indicator |
| `uploadFile(type, data)` | POST | `/uploads?type={type}` | File upload |

All HTTP via `http_util.curlPost/curlGet` with proxy support. Auth header on every request.

## max_ingress.zig — Inbound Processing

### Update Type Handling

| Update Type | Action |
|---|---|
| `message_created` | Create ChannelMessage, dispatch to agent |
| `message_callback` | Lookup pending interaction, submit choice to agent |
| `message_edited` | Ignore |
| `message_removed` | Ignore |
| `bot_started` | Deep link: `/start {payload}` or greeting |
| `bot_stopped` | Log only |
| `bot_added/removed` | Log only |
| Others | Ignore |

### ChannelMessage Mapping

- `id` = sender username or user_id
- `sender` = chat_id (reply target)
- `content` = text; attachments as `[IMAGE:url]`, `[DOCUMENT:url]` markers
- `channel` = `"max"`
- `message_id` = mid (i64 parsed from string)
- `first_name` = sender name
- `is_group` = chat_type != "DIALOG"

### Inbound Attachment Handling

- `image` → download, save temp file, `[IMAGE:path]`
- `video/audio/file` → corresponding markers
- `sticker` → `[IMAGE:url]`
- `contact` → text: `Contact: {name} {vcf_info}`
- `location` → text: `Location: {lat}, {lon}`
- `share` → append URL to text

## max.zig — MaxChannel

### Outbound Text

- Split at 4000 chars via `splitMessage()`, UTF-8 safe
- Format: `"markdown"` (native Max support, no HTML conversion needed)
- Continuation marker `⏬` on non-final chunks
- Fallback: remove `format` field on Markdown error

### Outbound Attachments

1. Upload: `POST /uploads?type={type}` → receive token
2. Send: `POST /messages` with `attachments: [{ "type": "image", "payload": { "token": "..." } }]`

Kind mapping: `.image`→`"image"`, `.document`→`"file"`, `.video`→`"video"`, `.audio`→`"audio"`, `.voice`→`"audio"`

### Streaming (sendEvent)

Max has no draft API — use `PUT /messages` (edit) instead:

1. First `.chunk`: `POST /messages` with accumulated text, store `mid`
2. Subsequent `.chunk`: `PUT /messages?message_id={mid}` with updated text
3. `.final`: final `PUT /messages` with complete text + attachments + keyboard
4. Rate limit: min 500ms between edits
5. Min delta: 100 chars between edits

```zig
const DraftState = struct {
    mid: ?[]const u8 = null,
    buffer: ArrayListUnmanaged(u8),
    last_edit_ms: i64 = 0,
};
```

### Interactive Choices (sendRich)

When payload has choices:
1. Build inline_keyboard attachment with callback buttons
2. Each button: `{ "type": "callback", "text": label, "payload": id, "intent": "default" }`
3. Register PendingInteraction with TTL
4. On `message_callback` → lookup, answerCallback(), send submit_text to agent

### Typing Indicator

- `POST /chats/{chat_id}/actions` with `{ "action": "typing_on" }`
- Repeat every 4s in dedicated thread (TypingTask pattern from Telegram)

### Webhook Mode

**Start:** `DELETE /subscriptions` then `POST /subscriptions { url, update_types, secret }`
**Stop:** `DELETE /subscriptions?url={url}`
**Gateway:** POST `/webhook/max` → verify `X-Max-Bot-Api-Secret` → parseUpdate() → processUpdate() → return 200

### Polling Mode

```
loop:
  GET /updates?marker={marker}&timeout=30&types=message_created,message_callback,bot_started,bot_stopped
  parse updates[]
  for each: processUpdate()
  update marker from response
  on error: exponential backoff 1s → 30s
```

## Testing

~60-75 tests total across 3 files:

**max_api.zig (~15-20):** URL building, auth header, response parsing (mid, bot_info, errors), NewMessageBody JSON construction, `builtin.is_test` guards.

**max_ingress.zig (~20-25):** Each update type parsing, sender/chat extraction, all attachment types, callback parsing, deep link payload, ChannelMessage mapping, edge cases.

**max.zig (~25-30):** allowlist checks, text splitting, attachment kind mapping, inline keyboard JSON, DraftState rate limiting, VTable correctness, processUpdate flows, healthCheck mock, webhook secret verification.

## Estimated Size

~2500-3000 lines across 3 new files, ~150 lines of modifications across 8 existing files.
