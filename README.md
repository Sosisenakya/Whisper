# Whisper
<p align="center">
  <a href="https://www.google.com/search?q=LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License" /></a>
  <a href="#"><img src="https://img.shields.io/badge/📦_Wally-yourname%2Fwhisper-00b4ab?style=flat-square" alt="Wally" /></a>
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


Installation
Using Wally
Add Whisper to your wally.toml:

Ini, TOML
[dependencies]
Whisper = "yourname/whisper@1.0.0"
Then run:

Bash
wally install
Manual Installation
Download the latest release.

Place the Whisper module script inside game.ServerScriptService (or ReplicatedStorage.Packages if using a shared directory).

Require it in your server scripts.

Quick Start
Basic Pub/Sub
Whisper acts as a drop-in replacement for standard cross-server messaging, but with built-in batching.

Cuplikan kode
--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local Whisper = require(ServerScriptService.Whisper)

-- 1. Listen for incoming messages
local connection = Whisper.Listen("GlobalChat", function(message, timeSent)
    print(string.format("[%s]: %s", message.data.Sender, message.data.Text))
end)

-- 2. Queue a message to be sent
Whisper.Queue("GlobalChat", {
    Sender = "Player1",
    Text = "Hello from another server!"
}, "Medium")
Using Priority
When your server is under heavy load, Whisper ensures critical data skips the line.

Cuplikan kode
-- This will be batched and sent whenever space is available
Whisper.Queue("PlayerMetrics", {Id = 123, Playtime = 500}, "Low")

-- This jumps to the front of the queue and is sent in the very next batch
Whisper.Queue("ServerShutdown", {Reason = "Update"}, "High")
API Reference
Whisper.Queue(topic: string, data: any, priority: Priority?)
Adds a message to the outbound queue.

topic: The MessagingService topic.

data: A JSON-serializable table or value. Must be under ~950 bytes after middleware processing.

priority: "High", "Medium", or "Low" (Defaults to "Medium").

Whisper.Listen(topic: string, callback: function): RBXScriptConnection
Subscribes to a topic. The callback provides the processed Message<T> and the timeSent timestamp.

Returns: A standard RBXScriptConnection that can be disconnected.

Whisper.Unlisten(topic: string): boolean
Disconnects the active listener for a specific topic.

Whisper.Dequeue(topic: string): Message<T>?
Manually removes and returns the highest-priority, oldest message currently sitting in the local queue for a specific topic.

Whisper.Use(direction: "In" | "Out", fn: function)
Registers a global middleware hook that processes data before it is encoded (Out) or before it is sent to a listener (In).

Advanced Features
The Middleware Pipeline
Whisper allows you to transform data globally without changing your core game logic. This is incredibly useful for Data Minification to squeeze more data into the 1KB limit.

Cuplikan kode
local Whisper = require(ServerScriptService.Whisper)

-- OUTBOUND: Shrink the keys before it goes over the network
Whisper.Use("Out", function(topic, data)
    if topic == "PlayerUpdate" then
        return {
            p = data.Position,
            h = data.Health
        }
    end
    return data
end)

-- INBOUND: Expand the keys back so your scripts see the full names
Whisper.Use("In", function(topic, data)
    if topic == "PlayerUpdate" then
        return {
            Position = data.p,
            Health = data.h
        }
    end
    return data
end)

-- Your game logic remains clean and readable!
Whisper.Queue("PlayerUpdate", { Position = Vector3.new(0, 10, 0), Health = 100 })
Performance Tips
Keep Data Small: Even though Whisper batches messages, Roblox has a hard limit of 1KB per PublishAsync call. Use Middleware to compress large strings or remove unnecessary keys.

Understand the Cooldown: Whisper calculates a dynamic send rate based on your active player count to prevent rate-limit throttling. Messages are not "instant" but are highly reliable.

Use "Low" Priority for Analytics: Background data like player metrics or heatmaps should always use "Low" priority so they don't block critical cross-server events like Matchmaking.
