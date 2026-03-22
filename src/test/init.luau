--!strict

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Whisper = require(ServerScriptService.Whisper)

type Player = {
	userId: number,
	username: string,
	level: number,
	ready: boolean,
}

type Lobby = {
	lobbyId: string,
	host: {
		userId: number,
		username: string,
		rank: number,
	},
	players: {Player},
	settings: {
		map: string,
		mode: string,
		maxPlayers: number,
		private: boolean,
	},
	state: string,
	timestamp: number,
}

local mockPublishCount = 0
local rng = Random.new()

local function MockPublishAsync(_topic: string, _payload: any): ()
	mockPublishCount += 1
end

local function createLobby(i: number): Lobby
	return {
		lobbyId = `Lobby_{i}`,
		host = {
			userId = 123456 + i,
			username = `Host_{i}`,
			rank = rng:NextInteger(1, 100)
		},
		players = {
			{
				userId = 111 + i,
				username = `PlayerA_{i}`,
				level = rng:NextInteger(1, 50),
				ready = true
			},
			{
				userId = 222 + i,
				username = `PlayerB_{i}`,
				level = rng:NextInteger(1, 50),
				ready = false
			}
		},
		settings = {
			map = `Arena_{i % 5}`,
			mode = "Deathmatch",
			maxPlayers = 8,
			private = false
		},
		state = "Waiting",
		timestamp = os.time()
	}
end

local function runBenchmark()
	print("Start")

	local MESSAGE_COUNT = 1000
	mockPublishCount = 0

	local whisperAny = Whisper :: any
	whisperAny._mockPublishAsync = MockPublishAsync
	whisperAny._ignoreCooldown = true 

	print(`Queueing {MESSAGE_COUNT} messages...`)
	local queueStart = os.clock()

	for i = 1, MESSAGE_COUNT do
		Whisper.Queue("LobbyUpdate", createLobby(i), "Medium")
	end

	local queueTime = os.clock() - queueStart
	print(`Queue time: {string.format("%.4f", queueTime)}s `)

	local processStart = os.clock()

	while true do
		local remaining = Whisper.Dequeue()
		if not remaining or remaining == 0 then
			break
		end
		RunService.Heartbeat:Wait()
	end

	local processTime = os.clock() - processStart
	print(`Processed in: {string.format("%.4f", processTime)}s`)
	print(`Mock network calls made: {mockPublishCount}`)

	if mockPublishCount > 0 then
		local itemsPerBatch = math.floor(MESSAGE_COUNT / mockPublishCount)
		print(`Averaged ~{itemsPerBatch} items per batch send!`)
	end

	print("----------------------------------")
end

task.delay(1, runBenchmark)