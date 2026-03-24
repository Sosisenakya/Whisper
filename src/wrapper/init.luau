--!strict
--[[
	WHISPER NETWORK WRAPPER
	
	HOW TO USE:
	Do NOT require the base Whisper module directly. Always require this Wrapper
	This will be where you store your topics (that are now object)
    , as well as custom priorities and middleware
	
	Example:
		Whispers.Topics.GlobalChat:Queue({Speaker = "Player1", Message = "Hello"}, "High")
]]

local Whisper = require(script.Parent)

-- You may skip this type definitions, if you don't use --!strict and don't care about intellisense
-- Here, you define exactly what data is allowed to pass through each topic

-- Example
export type GlobalChatData = {
	Speaker: string,
	Message: string,
}

-- Middleware hooks run automatically before sending (Out) and after receiving (In)
-- This is where we handle data serialization to save byte space

Whisper.RegisterHook("Out", function(topic: string, data: any)
	-- Example: If we had a serializer, we would compress the data here
	-- return Serializer.Compress(data)
	return data
end)

Whisper.RegisterHook("In", function(topic: string, data: any)
	-- Example: Decompress the data before the game logic reads it
	-- return Serializer.Decompress(data)
	return data
end)


return {
	-- Priorities define how messages are sorted in the queue.
	-- Higher weight = sent first.
	Priorities = {
		Critical = Whisper.RegisterPriority("Critical", 5),
		Realtime = Whisper.RegisterPriority("Realtime", 4),
		Background = Whisper.RegisterPriority("Background", 0),
	},

	-- Topics are the actual channels you will Listen to and Queue messages for.
	Topics = {
		GlobalChat = Whisper.RegisterTopic("GlobalChat") :: Whisper.TopicObject<GlobalChatData>,
	}
}