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

RunManager.start()
StoreService.start()

print("[Frostline] Server bootstrap complete")
