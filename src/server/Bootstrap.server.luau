--!strict

local WorldBuilder = require(script.Parent.Services.WorldBuilder)
local PlayerDataService = require(script.Parent.Services.PlayerDataService)
local RunManager = require(script.Parent.Services.RunManager)
local StoreService = require(script.Parent.Services.StoreService)

type LeaderboardServiceApi = {
	enqueueVerifiedBest: (userId: number, verifiedBestDistance: number) -> (),
	start: () -> (),
	destroy: () -> (),
}

type FrostTrailWorldBuilderApi = {
	build: () -> Model,
}

local leaderboardService: LeaderboardServiceApi? = nil
local requireSucceeded, requiredService = pcall(function(): any
	return require(script.Parent.Services.LeaderboardService)
end)
if requireSucceeded then
	local candidate: any = requiredService
	if type(candidate) == "table"
		and type(candidate.enqueueVerifiedBest) == "function"
		and type(candidate.start) == "function"
		and type(candidate.destroy) == "function"
	then
		leaderboardService = candidate :: LeaderboardServiceApi
	else
		warn("[Frostline][Leaderboard] Service module has an invalid API")
	end
else
	warn(string.format("[Frostline][Leaderboard] Service failed to load reason=%s", tostring(requiredService)))
end

local frostTrailWorldBuilder: FrostTrailWorldBuilderApi? = nil
local frostTrailRequireSucceeded, requiredFrostTrailBuilder = pcall(function(): any
	return require(script.Parent.Services.FrostTrailWorldBuilder)
end)
if frostTrailRequireSucceeded then
	local candidate: any = requiredFrostTrailBuilder
	if type(candidate) == "table" and type(candidate.build) == "function" then
		frostTrailWorldBuilder = candidate :: FrostTrailWorldBuilderApi
	else
		warn("[Frostline][FrostTrail] Static world builder has an invalid API")
	end
else
	warn(
		string.format(
			"[Frostline][FrostTrail] Static world builder failed to load reason=%s",
			tostring(requiredFrostTrailBuilder)
		)
	)
end

if leaderboardService then
	local service = leaderboardService
	local registrationSucceeded, observerRegistered = pcall(function(): boolean
		return PlayerDataService.registerVerifiedBestObserver(service.enqueueVerifiedBest)
	end)
	if not registrationSucceeded or not observerRegistered then
		warn(
			string.format(
				"[Frostline][Leaderboard] Verified-best observer registration failed reason=%s",
				tostring(observerRegistered)
			)
		)
		pcall(service.destroy)
		leaderboardService = nil
	end
end

PlayerDataService.start(function(player: Player)
	StoreService.handlePlayerRemoving(player)
	RunManager.handlePlayerRemoving(player)
end)
WorldBuilder.build()

if leaderboardService then
	local service = leaderboardService
	local startSucceeded, startFailureReason = pcall(service.start)
	if not startSucceeded then
		warn(
			string.format(
				"[Frostline][Leaderboard] Service failed to start reason=%s",
				tostring(startFailureReason)
			)
		)
		pcall(service.destroy)
		leaderboardService = nil
	end
end

RunManager.start()
StoreService.start()

if frostTrailWorldBuilder then
	local builder = frostTrailWorldBuilder
	local buildSucceeded, buildResult = pcall(builder.build)
	if not buildSucceeded then
		warn(string.format("[Frostline][FrostTrail] Static world build failed reason=%s", tostring(buildResult)))
	elseif typeof(buildResult) ~= "Instance"
		or not buildResult:IsA("Model")
		or buildResult.Name ~= "FrostTrailWorld"
		or buildResult.Parent ~= workspace
	then
		warn("[Frostline][FrostTrail] Static world builder returned an invalid model")
	else
		local builtWorld = buildResult :: Model
		local basePartCount = builtWorld:GetAttribute("BasePartCount")
		local verifiedPartCount = 0
		for _, descendant in ipairs(builtWorld:GetDescendants()) do
			if descendant:IsA("BasePart") then
				verifiedPartCount += 1
			end
		end
		if type(basePartCount) ~= "number"
			or basePartCount % 1 ~= 0
			or basePartCount <= 0
			or basePartCount ~= verifiedPartCount
		then
			warn("[Frostline][FrostTrail] Static world model has an invalid BasePartCount")
		else
			print(string.format("[Frostline] Frost Trail static world generated (%d parts)", basePartCount))
		end
	end
end

print("[Frostline] Server bootstrap complete")
