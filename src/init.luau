--!strict
local Whisper = {}

Whisper._mockPublishAsync = nil
Whisper._ignoreCooldown = nil

--------------------------------------------------------------------------------
-- TYPE DEFINITIONS
--------------------------------------------------------------------------------
export type Priority = "Low" | "Medium" | "High"

-- What the MessagingService will give in SubscribeAsync
export type Message<T> = {
	id: string,
	topic: string,
	data: T,
}

export type Batch<T> = {
	messages: {Message<T>},
	size: number
}

export type Response<T> = {
	Data: Message<T>,
	Sent: number
}

export type WhisperAPI<T> = {
	Use: (direction: MiddlewareDirection, fn: MiddlewareFn) -> (),
	
	Queue: (topic: string, data: T, priority: Priority?) -> (),
	Dequeue: () -> Message<T>?,
	DequeueTopic: (topic: string) -> Message<T>?,
	
	Listen: (topic: string, callback: (message: Message<T>, timeSent: number) -> ()) -> RBXScriptConnection,
	Unlisten: (topic: string) -> boolean,
	
	-- Benchmarking purposes
	_mockPublishAsync: ((topic: string, payload: any) -> ())?,
	_ignoreCooldown: boolean?,
}

export type MiddlewareDirection = "In" | "Out"
export type MiddlewareFn = (topic: string, data: any) -> any

-- This never gets sent over the network!
type QueueItem = {
	message: Message<any>,
	priority: Priority,
	retries: number,
	processAt: number,
	size: number, -- (in bytes)
}

--------------------------------------------------------------------------------
-- FASTCALLS
--------------------------------------------------------------------------------
local os_clock = os.clock

local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort

--------------------------------------------------------------------------------
-- SERVICES AND CONSTANTS
--------------------------------------------------------------------------------
local Players = game:GetService("Players")

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")

local MAX_ATTEMPTS = 3
local MAX_DATA_SENT = 950 -- (In byte, roblox's max is 1 KB)
local MAX_CACHE_SIZE = 1000 -- the amount of "id" it will remember before forgetting one to prevent duplicate

local RETRY_COOLDOWN = 3

local PRIORITY_WEIGHTS: {[Priority]: number} = {
	High = 3,
	Medium = 2,
	Low = 1,
}

local SERVER_PREFIX = string.sub(HttpService:GenerateGUID(false), 1, 4)

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------
local messageQueue: {QueueItem} = {}
local messageSubscribeConn: {[string]: RBXScriptConnection} = {}
local messageCache: {[string]: boolean} = {}
local messageHistory = table.create(MAX_CACHE_SIZE, "") :: {string}

local historyIndex = 1

local isProcessing = false
local queueNeedsSort = false
local sleepThread: thread? = nil

local outboundMiddlewares: {MiddlewareFn} = {}
local inboundMiddlewares: {MiddlewareFn} = {}

local messageIdCounter: number = 0

--------------------------------------------------------------------------------
-- PRIVATE FUNCTIONS
--------------------------------------------------------------------------------

local function getShortId(): string
	messageIdCounter += 1
	return string.format("%s-%x", SERVER_PREFIX, messageIdCounter) 
end

local function getCooldown(): number
	if Whisper and Whisper._ignoreCooldown then return 0 end
	local playerCount = #Players:GetPlayers()
	local maxRequestsPerMin = 60 + (10 * playerCount)
	
	return 60 / maxRequestsPerMin
end

-- Get highest priority and oldest sent
local function sortQueueTable(): ()
	if not queueNeedsSort then return end
	table_sort(messageQueue, function(a: QueueItem, b: QueueItem): boolean
		if a.priority ~= b.priority then
			return PRIORITY_WEIGHTS[a.priority] > PRIORITY_WEIGHTS[b.priority]
		end
		return a.processAt < b.processAt
	end)
	queueNeedsSort = false
end

local function trackDuplicate(id: string)
	local oldestId = messageHistory[historyIndex]
	if oldestId ~= "" then messageCache[oldestId] = nil end
	
	messageHistory[historyIndex] = id
	messageCache[id] = true
	historyIndex = (historyIndex % MAX_CACHE_SIZE) + 1
end

local function createMessage<T>(topic: string, data: T, priority: Priority?, dataSize: number): QueueItem
	local message: Message<T> = {
		id = getShortId(),
		topic = topic,
		data = data
	}
	
	-- Rough estimation for the data size
	-- 30 bytes is a safe buffer for JSON structure {"id":"xxxx-x","topic":"...","data":}
	local totalSize = 30 + #topic + dataSize
	
	local queueItem: QueueItem = {
		message = message,
		priority = priority or "Medium",
		retries = 0,
		processAt = os_clock(),
		size = totalSize,
	}

	return queueItem
end


local function publishBatch(topic: string, batchItems: {QueueItem}): boolean
	local payload = {}
	for _, item in batchItems do
		table_insert(payload, item.message)
	end

	local success, result = pcall(function()
		local mock = Whisper._mockPublishAsync
		if mock then
			mock(topic, payload)
		else
			MessagingService:PublishAsync(topic, payload)
		end
		return true
	end)

	if success then return true end

	warn(`Failed to send batch on topic '{topic}': {result}.`)

	local needsResort = false
	for _, item in batchItems do
		item.retries += 1
		if item.retries <= MAX_ATTEMPTS then
			item.processAt = os_clock() + RETRY_COOLDOWN
			table_insert(messageQueue, item)
			needsResort = true
		else 
			warn(`Reached max retries. Dropping message id '{item.message.id}'`, 2)
		end
	end

	if needsResort then
		sortQueueTable()
	end

	return false
end	

local function processQueue(): ()
	if isProcessing then return end
	isProcessing = true
	
	if sleepThread then
		task.cancel(sleepThread)
		sleepThread = nil
	end

	task.spawn(function()
		while #messageQueue > 0 do
			sortQueueTable()
			
			local currentTime = os_clock()
			local currentItem: QueueItem = messageQueue[1]

			if currentItem.processAt > currentTime then
				isProcessing = false
			
				sleepThread = task.delay(currentItem.processAt - currentTime, function()
					sleepThread = nil
					processQueue()
				end)

				return
			end
			
			local targetTopic = currentItem.message.topic
			local batchedItems: {QueueItem} = {}

			-- Base JSON array size '[]' is 2 bytes
			-- Only batch if it's the exact same topic and it's ready to send
			local currentBatchSize: number = 2 
			local itemsToRemoveCount: number = 0

			for i = 1, #messageQueue do
				local item: QueueItem = messageQueue[i]
				
				if item.message.topic ~= targetTopic or item.processAt > currentTime then
					break 
				end
				
				local commaOverhead = (#batchedItems > 0) and 1 or 0

				if (currentBatchSize + item.size + commaOverhead) <= MAX_DATA_SENT then
					table_insert(batchedItems, item)
					currentBatchSize += (item.size + commaOverhead)
					itemsToRemoveCount = i
				else 
					break
				end
				
				if #batchedItems >= 100 then break end
			end
			
			if itemsToRemoveCount > 0 then
				for _ = 1, itemsToRemoveCount do
					table_remove(messageQueue, 1)
				end
			end

			if #batchedItems > 0 then
				publishBatch(targetTopic, batchedItems)
				task.wait(getCooldown()) 
			end
		end

		isProcessing = false
	end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function Whisper.Use(direction: MiddlewareDirection, fn: (topic: string, data: any) -> any)
	if direction == "Out" then
		table_insert(outboundMiddlewares, fn)
	else
		table_insert(inboundMiddlewares, fn)
	end
end

function Whisper.Queue<T>(topic: string, data: T, priority: Priority?): ()
	if typeof(topic) ~= "string" then
		error(`Topic must be a string, got: {typeof(topic)}`, 2)
	end
	
	if priority ~= nil and not PRIORITY_WEIGHTS[priority] then
		error(`Invalid priority level: "{priority}". Expected: Low, Medium, or High`, 2)
	end
	
	local processedData: T = data
	for _, hook: MiddlewareFn in outboundMiddlewares do
		processedData = hook(topic, processedData)
	end
	
	local encodedSize: number = #HttpService:JSONEncode(processedData)
	if encodedSize > MAX_DATA_SENT then
		error(`Data for topic {topic} exceeds the limit of {MAX_DATA_SENT} bytes`)
	end
	
	local queueItem: QueueItem = createMessage(topic, processedData, priority, encodedSize)
	
	table_insert(messageQueue, queueItem)
	processQueue()
end

function Whisper.Dequeue<T>(): Message<T>?
	if #messageQueue == 0 then
		return nil
	end

	local item = table_remove(messageQueue, 1) :: QueueItem
	return item.message :: Message<T> 
end

function Whisper.DequeueTopic<T>(topic: string): Message<T>?
	for i, item in messageQueue do
		if item.message.topic == topic then
			table_remove(messageQueue, i)
			return item.message :: Message<T>
		end
	end
	return nil
end

function Whisper.Listen<T>(topic: string, callback: (message: Message<T>, timeSent: number) -> ()): RBXScriptConnection
	if typeof(topic) ~= "string" then
		error(`Topic must be a string, got: {typeof(topic)}`, 2)
	end
	if topic == "" then error("Topic cannot be empty", 2) end
	
	if messageSubscribeConn[topic] then
		error(`Already listened to {topic}`, 2)
	end
	
	local connection: RBXScriptConnection

	local success, result = pcall(function()
		connection = MessagingService:SubscribeAsync(topic, function(incoming: {Data: {Message<T>}, Sent: number})
			for _, msg in incoming.Data do
				trackDuplicate(msg.id)
				
				local processedData = msg.data
				for _, hook: MiddlewareFn in inboundMiddlewares do
					processedData = hook(msg.topic, processedData)
				end
				
				local finalMsg = {
					id = msg.id,
					topic = msg.topic,
					data = processedData
				}
				
				callback(finalMsg, incoming.Sent)
			end
		end)
		messageSubscribeConn[topic] = connection
		return connection
	end)

	if not success then
		error(`Failed to subscribe to topic '{topic}': {result}`, 2)
	end

	return connection
end

function Whisper.Unlisten<T>(topic: string): boolean
	if not messageSubscribeConn[topic] then
		error(`Cannot find connection with topic "{topic}"`, 2)
		return false
	end
	
	messageSubscribeConn[topic]:Disconnect()
	messageSubscribeConn[topic] = nil
	
	return true
end

--------------------------------------------------------------------------------
-- SHUTDOWN HANDLER
--------------------------------------------------------------------------------

-- This will essentially force send everything before the server closes
game:BindToClose(function()
	if #messageQueue == 0 then return end
	isProcessing = true 

	while #messageQueue > 0 do
		local currentItem = messageQueue[1]
		local targetTopic = currentItem.message.topic
		local batchedItems = {}
		local size = 2

		for i = #messageQueue, 1, -1 do
			local item = messageQueue[i]
			if item.message.topic == targetTopic then
				if (size + item.size) <= MAX_DATA_SENT then
					table_insert(batchedItems, table_remove(messageQueue, i))
				end
			end
		end

		if #batchedItems > 0 then
			-- pcall is required because we don't want retries
			local payload = {}
			for _, item in batchedItems do
				table_insert(payload, item.message)
			end
			pcall(function()
				MessagingService:PublishAsync(targetTopic, payload)
			end)
		end
	end
end)

return Whisper :: WhisperAPI<any>
