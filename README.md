# Whisper
<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://wally.run/package/sosisenakya/whisper"><img src="https://img.shields.io/badge/📦_Wally-sosisenakya/whisper-00b4ab?style=flat-square" alt="Wally"/></a>
</p>

<p align="center">
<strong>A high-performance, reliable cross-server messaging library for Roblox</strong>
</p>

Whisper is a powerful wrapper for Roblox's MessagingService designed to maximize your cross-server rate limits while ensuring reliable data delivery. It automatically batches small messages, sorts them by priority, prevents duplicate processing, and features a robust middleware pipeline for on-the-fly data transformation.

## Features
- **Priority Queuing**: Prioritize message with higher priority weight (you can add more with .RegisterPriority)
    
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
Whisper = "sosisenakya/whisper@1.0.0"
```

Then run:

```bash
wally install
```

### Manual Installation

1. Download the latest release
2. Place the `Whisper` folder in your `ServerScriptService.Packages`
3. Require Whisper.Whispers in your scripts

## Quick Start

The best way to use Whisper is through the `Whispers` wrapper. This provides full Type-Checking and keeps your network topics organized in one place.

```luau
--!strict
local Whispers = require(path.to.Whisper.Whispers)

-- 1. Listen for incoming messages
Whispers.Topics.GlobalChat:Listen(function(message, timeSent)
    print(`[{message.data.Speaker}]: {message.data.Message}`)
end)

-- 2. Queue a message to be sent
-- This uses the "Urgent" priority defined in the wrapper (you can customize it)
Whispers.Topics.GlobalChat:Queue({
    Speaker = "System",
    Message = "Server Restarting..."
}, "Critical") -- "Critical" is replacable with Whispers.Priorities.Critical (it has intellisense support)
```
---
## API Reference

### Global Configuration

#### `Whisper.RegisterTopic(topicName: string): TopicObject<T>`
Creates and returns a new `TopicObject`. All messaging for a specific channel must now be handled through this object to ensure strict typing
- **Parameters:**
    - `topicName`: The `MessagingService` topic string used for cross-server communication

#### `Whisper.RegisterPriority(name: string, weight: number): string`
Registers a custom priority level with a specific numerical weight. Higher weights are prioritized by the internal scheduler
- **Parameters:**
    - `name`: The unique priority string (e.g., `"Ultimate"`)
    - `weight`: A number representing importance. (Built-ins: `High=3`, `Medium=2`, `Low=1`)

#### `Whisper.RegisterHook(direction: MiddlewareDirection, fn: MiddlewareFn)`
Registers a middleware function to intercept and transform data (formerly `Use`)
- **Parameters:**
    - `direction`: `"In"` (for received messages) or `"Out"` (for queued messages)
    - `fn`: A function `(topic: string, data: any) -> any` that returns the transformed data

---

### Topic Object Methods

#### `Topic:Queue(data: T, priority: Priority?)`
Adds a message to the internal linked-list outbound queue for this specific topic
- **Parameters:**
    - `data`: The JSON-serializable payload (Max **950 bytes**)
    - `priority` (optional): `"High"`, `"Medium"`, `"Low"`, or a custom registered string. Defaults to `"Medium"`

#### `Topic:DropNext()`
Searches the queue from newest to oldest and removes the first message matching this topic. This is useful for "cancelling" a request (e.g., a player leaves a queue) before it is sent (formerly `Dequeue`)

#### `Topic:Listen(callback: (message: Message<T>, timeSent: number) -> ()): RBXScriptConnection`
Subscribes to the topic. This method automatically handles de-batching of incoming arrays, runs "In" middleware, and filters out duplicate message IDs
- **Returns:** An `RBXScriptConnection` used to stop listening

#### `Topic:Unlisten(): boolean`
Disconnects the listener specifically for this topic object and cleans up internal references
- **Returns:** `true` if a connection was successfully disconnected, `false` otherwise

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
