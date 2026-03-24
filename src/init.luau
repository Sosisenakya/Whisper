--!strict
local Whisper = {}

--------------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------------
Whisper._mockPublishAsync = nil
Whisper._ignoreCooldown = nil

--------------------------------------------------------------------------------
-- TYPE DEFINITIONS
--------------------------------------------------------------------------------
export type Priority = "High" | "Medium" | "Low" | string

-- What the MessagingService will give in .Listen
export type Message<T> = {
	id: string,
	topic: string,
	data: T,
}

export type TopicObject<T> = {
	Name: string, -- (Topic Name)
	
	--Start listening to that topic
	Listen: (self: TopicObject<T>, callback: (message: Message<T>, timeSent: number) -> ()) -> RBXScriptConnection,
	-- Stop listening to that message being sent
	Unlisten: (self: TopicObject<T>) -> boolean,
	
	Queue: (self: TopicObject<T>, data: T, priority: Priority?) -> (), -- Queue message to X topic
	
	DropNext: (self: TopicObject<T>) -> (), -- Remove the last message you queue on X topic
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
	RegisterTopic: (topicName: string) -> TopicObject<T>, -- Add a new topic
	RegisterPriority: (name: string, weight: number) -> string, -- Add a new priority (weight must be distinct)
	RegisterHook: (direction: MiddlewareDirection, fn: MiddlewareFn) -> (), -- Add data processor (e.g. serializer)

	-- Testing purposes
	_mockPublishAsync: ((topic: string, payload: any) -> ())?, -- Replace PublishAsync
	_ignoreCooldown: boolean?, -- Disable scaling cooldown, extremely unsafe
}

export type MiddlewareDirection = "In" | "Out"
export type MiddlewareFn = (topic: string, data: any) -> any

-- This never gets sent over the network!
type QueueItem = {
	message: Message<any>,
	priority: Priority,
	retries: number,
	
	processAt: number,
	createdAt: number,
	
	size: number,
	
	Next: QueueItem?,
	Prev: QueueItem?, 
}

local Queue = {
	Head = nil :: QueueItem?,
	Tail = nil :: QueueItem?,
	
	Count = 0
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
local MAX_AMOUNT_BATCHED = 40 -- (max amount of data that is batched)
-- I put 40 here because when data is empty, it can only batch to 40

local RETRY_COOLDOWN = 3

-- Generate a prefix once when the server starts
-- Using os.time() % 46655 gives us a 3-character unique ID for this session
local SESSION_PREFIX: string

local AGING_FACTOR = 0.2 -- Gain X weight per second (sort biased stuff)

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

local registeredTopics: {string} = {}
local registeredPriorities: {[Priority]: number} = {
	High = 3,
	Medium = 2,
	Low = 1,
}

local weightToName: {[number]: Priority} = {} -- reversed version of registeredPriorities table 
-- (Required for O(1)) to check if there is already a similar weight to the arg
for n, w in registeredPriorities do weightToName[w] = n end

--------------------------------------------------------------------------------
-- PRIVATE FUNCTIONS
--------------------------------------------------------------------------------
local function toBase36(n: number): string
	local charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	local result = ""
	repeat
		local rem = n % 36
		result = string.sub(charset, rem + 1, rem + 1)..result
		n = math.floor(n / 36)
	until n <= 0
	return result
end

local function getShortId(): string
	messageIdCounter += 1
	if not SESSION_PREFIX then SESSION_PREFIX = toBase36(os.time() % 46656) end
	return `{SESSION_PREFIX}-{toBase36(messageIdCounter)}`
end

local function getCooldown(): number
	if Whisper and Whisper._ignoreCooldown then return 0 end
	local playerCount = #Players:GetPlayers()
	local maxRequestsPerMin = 50 + (5 * playerCount)
	
	return 60 / maxRequestsPerMin
end

local function sortQueueTable(sortTable: {QueueItem}, now: number): ()
	table_sort(sortTable, function(a: QueueItem, b: QueueItem): boolean
		local ageA = now - a.createdAt
		local ageB = now - b.createdAt

		-- Squaring the age (age^2) makes older messages gain priority EXPONENTIALLY
		local scoreA = (registeredPriorities[a.priority] or 1) + (ageA * ageA * AGING_FACTOR)
		local scoreB = (registeredPriorities[b.priority] or 1) + (ageB * ageB * AGING_FACTOR)

		if math.abs(scoreA - scoreB) > 0.001 then 
			return scoreA > scoreB 
		end

		return a.processAt < b.processAt
	end)
end
local function trackDuplicate(id: string): ()
	if messageCache[id] then return end
	
	local oldestId = messageHistory[historyIndex]
	if oldestId ~= "" then messageCache[oldestId] = nil end
	
	messageHistory[historyIndex] = id
	messageCache[id] = true
	historyIndex = (historyIndex % MAX_CACHE_SIZE) + 1
end

local function createMessage<T>(topic: string, data: T, priority: Priority?, dataSize: number): QueueItem
	local id = getShortId()
	local message: Message<T> = {
		id = id,
		topic = topic,
		data = data
	}
	
	-- Rough estimation for the data size (overestimate)
	-- 5 bytes for ["" , ]
	-- {id, data}
	
	-- topic is not included in this case, (topic will be grouped in batches)
	local totalSize = 5 + #id + dataSize + 5
	local currentTime = os_clock()
	
	local queueItem: QueueItem = {
		message = message,
		priority = priority or "Medium",
		retries = 0,
		processAt = currentTime,
		createdAt = currentTime,
		size = totalSize,
	}

	return queueItem
end


local function publishBatch(topic: string, batchItems: {QueueItem}): boolean
	local payload = {}
	for _, item in batchItems do
		table_insert(payload, {item.message.id, item.message.data})
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

	for _, item in batchItems do
		item.retries += 1
		if item.retries <= MAX_ATTEMPTS then
			item.processAt = os_clock() + RETRY_COOLDOWN
			item.Next = nil 
			-- Put it back at the tail to let others try
			if Queue.Tail then
				item.Prev = Queue.Tail;
				(Queue.Tail :: QueueItem).Next = item
			else
				item.Prev = nil
				Queue.Head = item
			end
			Queue.Tail = item
			Queue.Count += 1
		else 
			warn(`Reached max retries. Dropping message id '{item.message.id}'`)
		end
	end

	return false
end	

local function removeNode(item: QueueItem)
	if item.Prev then
		item.Prev.Next = item.Next
	else
		Queue.Head = item.Next
	end

	if item.Next then
		item.Next.Prev = item.Prev
	else
		Queue.Tail = item.Prev
	end

	item.Next = nil
	item.Prev = nil
	Queue.Count -= 1
end

-- Ignore cooldown should be true on BindToClose, because we are desperately trying to send message asap
-- (We don't care about rate limit)
local function getNextBatch(ignoreCooldown: boolean?): (string?, {QueueItem}?)
	if Queue.Count == 0 or not Queue.Head then return nil, nil end

	local now = os_clock()
	local sortTable: {QueueItem} = {}
	local current = Queue.Head
	
	while current do
		table_insert(sortTable, current)
		current = (current :: QueueItem).Next
	end

	sortQueueTable(sortTable, now)

	local targetItem: QueueItem? = nil
	for _, item in sortTable do
		-- In BindToClose, we don't care about processAt, we send everything
		-- If targetItem is nil (meaning nothing is 'ready' yet), we just take the top sorted item
		if not ignoreCooldown and item.processAt > now then continue end
		targetItem = item
		break
	end

	if not targetItem then return nil, nil end

	local targetTopic = (targetItem :: QueueItem).message.topic
	local batch: {QueueItem} = {}
	
	-- Base JSON array size '[]' is 2 bytes
	-- Only batch if it's the exact same topic and it's ready to send
	local currentSize = 2 
	
	for _, item in sortTable do
		if #batch >= MAX_AMOUNT_BATCHED then break end
		if item.message.topic ~= targetTopic then continue end
		if not ignoreCooldown and item.processAt > now then continue end

		local overhead = #batch > 0 and 1 or 0 -- comma overhead in JSON is 1 byte [... , ... , ...]
		if (currentSize + item.size + overhead) > MAX_DATA_SENT then continue end

		currentSize += (item.size + overhead)
		table_insert(batch, item)
		removeNode(item) 
	end

	return targetTopic, batch
end

local function processQueue(): ()
	if isProcessing or Queue.Count == 0 then return end
	isProcessing = true

	task.spawn(function()
		while Queue.Count > 0 do
			local topic, batch = getNextBatch()

			if topic and batch then
				publishBatch(topic, batch)
				task.wait(getCooldown())
			else
				-- If nothing is 'ready' yet, wait for the soonest item
				if not Queue.Head then break end
				-- Sometimes sub os.clock() can be negative (just incase)
				task.wait(math.max(0.03, (Queue.Head:: QueueItem).processAt - os_clock()))
			end
		end
		isProcessing = false
	end)
end

--------------------------------------------------------------------------------
-- Class Implementation
--------------------------------------------------------------------------------

local TopicClass = {}
TopicClass.__index = TopicClass

function TopicClass:Listen<T>(callback: (message: Message<T>, timeSent: number) -> ()): RBXScriptConnection
	local topic = (self :: {Name: string}).Name
	
	if messageSubscribeConn[topic] then
		error(`Already listened to {topic}`, 2)
	end

	local connection: RBXScriptConnection

	local success, result = pcall(function()
		connection = MessagingService:SubscribeAsync(topic, function(incoming: {Data: {any}, Sent: number})
			for _, rawMsg in incoming.Data do
				-- rawMsg struct = {id, data}
				if messageCache[rawMsg[1]] then continue end
				trackDuplicate(rawMsg[1])

				local processedData = rawMsg[2]
				for _, hook: MiddlewareFn in inboundMiddlewares do
					processedData = hook(topic, processedData)
				end

				local finalMsg: Message<any> = {
					id = rawMsg[1],
					topic = topic, 
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

function TopicClass:Unlisten(): boolean
	local topic = (self :: {Name: string}).Name
	
	if not messageSubscribeConn[topic] then
		error(`Cannot find connection with topic "{topic}"`, 2)
		return false
	end

	messageSubscribeConn[topic]:Disconnect()
	messageSubscribeConn[topic] = nil

	return true
end

function TopicClass:Queue<T>(data: T, priority: Priority?)
	local topic = (self :: {Name: string}).Name
	
	if typeof(topic) ~= "string" then
		error(`Topic must be a string, got: {typeof(topic)}`, 2)
	end

	if priority ~= nil and not registeredPriorities[priority] then
		error(`Invalid priority level: "{priority}". Expected: Low, Medium, or High`, 2)
	end

	local processedData: T = data
	for _, hook: MiddlewareFn in outboundMiddlewares do
		processedData = hook(topic, processedData)
	end

	local encodedSize: number = #HttpService:JSONEncode(processedData)
	if encodedSize > MAX_DATA_SENT then
		error(`Data for topic {topic} exceeds the limit of {MAX_DATA_SENT} bytes`, 2)
	end

	local newItem = createMessage(topic, processedData, priority, encodedSize)

	if Queue.Tail then
		newItem.Prev = Queue.Tail
		Queue.Tail.Next = newItem
	else
		Queue.Head = newItem
		newItem.Prev = nil
	end
	Queue.Tail = newItem
	Queue.Count += 1

	task.defer(processQueue)
end

function TopicClass:DropNext(): ()
	-- Do newest -> oldest (until we find message with X topic)
	local topic = (self :: {Name: string}).Name
	local curr = Queue.Tail

	while curr do
		if curr.message.topic == topic then
			removeNode(curr)
			return
		end
		curr = curr.Prev
	end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------
function Whisper.RegisterTopic<T>(topicName: string): TopicObject<T>
	if typeof(topicName) ~= "string" then
		error(`Topic must be a string, got: {typeof(topicName)}`, 2)
	end
	if topicName == "" then error("Topic cannot be empty", 2) end
	
	if table.find(registeredTopics, topicName) then 
		error(`Topic {topicName} already exists!`, 2) 
	end
	table.insert(registeredTopics, topicName)

	local self = setmetatable({}, TopicClass)
	self.Name = topicName

	return self :: TopicObject<T>
end

function Whisper.RegisterPriority(priorityName: string, weight: number): string
	if registeredPriorities[priorityName] then 
		error(`Priority Name '{priorityName}' already exists!`, 2) 
	end

	local existingName = weightToName[weight] 
	if existingName then
		error(`Priority Weight '{weight}' is already assigned to '{existingName}'!`, 2)
	end

	registeredPriorities[priorityName] = weight
	weightToName[weight] = priorityName

	return priorityName
end

function Whisper.RegisterHook(direction: MiddlewareDirection, fn: (topic: string, data: any) -> any)
	if direction == "Out" then
		table_insert(outboundMiddlewares, fn)
	else
		table_insert(inboundMiddlewares, fn)
	end
end

--------------------------------------------------------------------------------
-- SHUTDOWN HANDLER
--------------------------------------------------------------------------------

-- This will essentially force send everything before the server closes
game:BindToClose(function()
	-- No task.wait() or cooldowns here just fire as fast as MessagingService allows
	while Queue.Count > 0 do
		local topic, batchItems = getNextBatch(true) -- ignoreCooldown = true
		if (not topic) or (not batchItems) or (#batchItems == 0) then break end
		
		local payload = {}
		for _, item in batchItems do
			table_insert(payload, {item.message.id, item.message.data})
		end
		
		local success = pcall(function()
			MessagingService:PublishAsync(topic, payload)
		end)

		if not success then break end
	end
end)

return Whisper :: WhisperAPI<any>
