# Whisper
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="#"><img src="https://img.shields.io/badge/📦_Wally-sosisenakya%2Fwhisper-00b4ab?style=flat-square" alt="Wally" /></a>
  <a href="#"><img src="https://img.shields.io/badge/📖_Docs-GitHub_Pages-8b5cf6?style=flat-square" alt="Documentation" /></a>
</p>

<p align="center">
<strong>A high-performance, reliable cross-server messaging library for Roblox</strong>
</p>

Whisper is a powerful wrapper for Roblox's MessagingService designed to maximize your cross-server rate limits while ensuring reliable data delivery. It automatically batches small messages, sorts them by priority, prevents duplicate processing, and features a robust middleware pipeline for on-the-fly data transformation.

## Features
- **3 Priority Queuing Modes**
  - High
  - Medium
  - Low
    
- **Automated Batching**: Safely bundles multiple messages into a single 1KB payload to bypass strict MessagingService rate limits

- **Middleware Pipeline**: Inject custom logic (In or Out) to automatically compress, encrypt, or filter data across all your topics

- **Security**: Auto-retry system for failed network calls as well as duplicate prevention (using id)

- **Safe Shutdown**: Native BindToClose integration guarantees pending queues are flushed before the server dies

- **Zero Dependencies**: Standalone library with no external requirements


## Installation
### Using Wally
Add Whisper to your `wally.toml`:

```toml
[dependencies]
Whisper = "sosisenakya/whisper@0.0.1"
```

Then run:

```bash
wally install
```

### Manual Installation

1. Download the latest release
2. Place the `Whisper` folder in your `ServerScriptService.Packages`
3. Require it in your scripts

## Quick Start
```luau
--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local Whisper = require(ServerScriptService.Packages.Whisper)

-- Listen for incoming messages
local connection = Whisper.Listen("GlobalChat", function(message, timeSent)
    print(string.format("[%s]: %s", message.data.Sender, message.data.Text))
end)

-- Queue a message to be sent
Whisper.Queue("GlobalChat", {
    Text = "Hello from another server!"
}, "Medium")
```
Using Priority
When your server is under heavy load, Whisper ensures critical data skips the line.

```luau
-- This will be batched and sent whenever space is available
Whisper.Queue("PlayerMetrics", {Id = 123, Playtime = 500}, "Low")

-- This jumps to the front of the queue and is sent in the very next batch
Whisper.Queue("ServerShutdown", {Reason = "Update"}, "High")
```
To make this as easy as possible for you to copy-paste into your project, I have formatted the README.md documentation inside a code block. You can copy the entire block below and paste it directly into a README.md file in your repository or a StringValue in Roblox Studio.

Markdown
# Whisper Messaging Service

A high-performance, buffered, and batched wrapper for Roblox's `MessagingService`. Designed for modular game architectures, Whisper handles rate-limiting, priority queuing, and duplicate prevention automatically.

---

## API Reference

### Global Configuration

#### `Whisper.Use(direction: MiddlewareDirection, fn: MiddlewareFn)`
Registers a middleware function to intercept and transform data.
- **Parameters:**
    - `direction`: `"In"` (for received messages) or `"Out"` (for queued messages)
    - `fn`: A middleware function `(topic: string, data: any) -> any`

---

### Outbound Messaging (Queueing)

#### `Whisper.Queue(topic: string, data: T, priority: Priority?)`
Adds a message to the internal outbound queue. Messages are automatically sorted by priority and batched by topic to stay within Roblox's 1KB limit.
- **Parameters:**
    - `topic`: The `MessagingService` topic string
    - `data`: The JSON-serializable payload (Max **920 bytes**)
    - `priority` (optional): `"High"`, `"Medium"`, or `"Low"` (Defaults to `"Medium"`)

#### `Whisper.Dequeue(): Message<T>?`
Removes and returns the absolute first message (highest priority/oldest) from the queue.

#### `Whisper.DequeueTopic(topic: string): Message<T>?`
Searches the queue for the first message matching the specified `topic`, removes it, and returns it.

---

### Inbound Messaging (Listening)

#### `Whisper.Listen(topic: string, callback: (message: Message<T>, timeSent: number) -> ()): RBXScriptConnection`
Subscribes to a topic. Automatically handles de-batching of incoming arrays and filters out duplicate message IDs.
- **Parameters:**
    - `topic`: The topic to subscribe to
    - `callback`: Function triggered on message receipt
        - `message`: Table containing `id`, `topic`, and `data`
        - `timeSent`: Unix timestamp provided by Roblox
- **Returns:** An `RBXScriptConnection` used to stop listening.

#### `Whisper.Unlisten(topic: string): boolean`
Disconnects the listener for a specific topic.
- **Returns:** `true` if a connection was successfully disconnected, `false` otherwise.

---

### Internal / Testing Hooks

#### `Whisper._mockPublish` (Property)
A function `(topic: string, payload: any) -> ()` that overrides the real `MessagingService:PublishAsync`. Use this for unit testing or benchmarks.

#### `Whisper._ignoreCooldown` (Property)
A boolean. If set to `true`, the module will bypass the calculated `task.wait()` based on player count, allowing for instant queue processing in test environments.

---

### Type Definitions (Luau)

```lua
export type Priority = "Low" | "Medium" | "High"

export type Message<T> = {
	id: string,
	topic: string,
	data: T,
}

export type MiddlewareDirection = "In" | "Out"
export type MiddlewareFn = (topic: string, data: any) -> any
