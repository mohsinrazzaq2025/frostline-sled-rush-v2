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

type CourseSelectionServiceApi = {
	start: (RemoteEvent, any) -> (boolean, string),
	destroy: () -> (),
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

local frostTrailWorldBuilder: FrostTrailWorldBuilderApi? = nil
local frostTrailRequireSucceeded, requiredFrostTrailBuilder = pcall(function(): any
	return require(script.Parent.Services.FrostTrailWorldBuilder)
end)
if frostTrailRequireSucceeded then
	local candidate: any = requiredFrostTrailBuilder
	if type(candidate) == "table" and type(candidate.build) == "function" then
		frostTrailWorldBuilder = candidate :: FrostTrailWorldBuilderApi
	else
		warn("[Frostline][FrostTrail] World builder has an invalid API")
	end
else
	warn(
		string.format(
			"[Frostline][FrostTrail] World builder failed to load reason=%s",
			tostring(requiredFrostTrailBuilder)
		)
	)
end

if frostTrailWorldBuilder then
	local builder = frostTrailWorldBuilder
	local buildSucceeded, buildResult = pcall(builder.build)
	if not buildSucceeded then
		warn(string.format("[Frostline][FrostTrail] World build failed reason=%s", tostring(buildResult)))
	elseif typeof(buildResult) ~= "Instance"
		or not buildResult:IsA("Model")
		or buildResult.Name ~= "FrostTrailWorld"
		or buildResult.Parent ~= workspace
	then
		warn("[Frostline][FrostTrail] World builder returned an invalid model")
	else
		local builtWorld = buildResult :: Model
		local basePartCount = builtWorld:GetAttribute("BasePartCount")
		local verifiedPartCount = 0
		for _, descendant in ipairs(builtWorld:GetDescendants()) do
			if descendant:IsA("BasePart") then
				verifiedPartCount += 1
			end
		end
		if basePartCount ~= 628 or verifiedPartCount ~= 628
		then
			warn("[Frostline][FrostTrail] World model does not contain the validated 628 parts")
		else
			print(string.format("[Frostline] Frost Trail selectable world generated (%d parts)", basePartCount))
		end
	end
end

local courseSelectionService: CourseSelectionServiceApi? = nil
local selectorLoadSucceeded, selectorOrError = pcall(function(): any
	return require(script.Parent.Services.CourseSelectionService)
end)
if selectorLoadSucceeded then
	local candidate: any = selectorOrError
	if type(candidate) == "table"
		and type(candidate.start) == "function"
		and type(candidate.destroy) == "function"
	then
		courseSelectionService = candidate :: CourseSelectionServiceApi
	else
		warn("[Frostline][FrostTrail] Course selection service has an invalid API")
	end
else
	warn("[Frostline][FrostTrail] Course selection service failed to load")
end

RunManager.start(courseSelectionService)
StoreService.start()

print("[Frostline] Server bootstrap complete")
