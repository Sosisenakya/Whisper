--!strict
local Whispers = require(path.to.Whispers)

Whispers.Topics.GlobalChat:Listen(function(message, timeSent)
	print(`Received chat from {message.data.Speaker}: {message.data.Message}`)
	print(`Message ID: {message.id} | Sent at: {timeSent}`)
end)

Whispers.Topics.GlobalChat:Queue({Speaker = "P1", Message = "Low priority"}, "Low")
Whispers.Topics.GlobalChat:Queue({Speaker = "P2", Message = "Realtime priority"}, Whispers.Priorities.Realtime)
-- You can type the string for priority or Whispers.Priorities. (Intellisense supported)
Whispers.Topics.GlobalChat:Queue({Speaker = "P3", Message = "Critical priority"}, Whispers.Priorities.Critical)
Whispers.Topics.GlobalChat:Queue({Speaker = "P3", Message = "Background priority"}, "Background")
Whispers.Topics.GlobalChat:Queue({Speaker = "P2", Message = "Med priority"}, "Medium")
