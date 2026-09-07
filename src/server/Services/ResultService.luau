--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlayerDataTypes = require(ReplicatedStorage.Shared.PlayerDataTypes)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local RESULT = GameConfig.Result

type FrostRouteRuntime = {
	CoinRewardPerPickup: number,
	MaximumRouteCoins: number,
}

type FrostRouteContentConfig = {
	RuntimeEnabled: boolean,
	RuntimeVersion: number,
	Runtime: FrostRouteRuntime,
}

type CourseId = PlayerDataTypes.CourseId
type Outcome = ResultTypes.Outcome
type Payload = ResultTypes.Payload
type ServerFacts = ResultTypes.ServerFacts

type FinalizedRecord = {
	Payload: Payload,
}

type PlayerResultState = {
	FinalizedRuns: { [number]: FinalizedRecord },
	FinalizingRuns: { [number]: boolean },
}

local ResultService = {}

local playerResultState: { [Player]: PlayerResultState } = {}
local frostRouteContentConfig: FrostRouteContentConfig? = nil
local frostRouteContentLoadFailure: string? = nil

do
	local loaded, result = pcall(function()
		return require(script.Parent.FrostTrailRouteContentConfig)
	end)
	if loaded and typeof(result) == "table" then
		frostRouteContentConfig = result :: FrostRouteContentConfig
	else
		frostRouteContentLoadFailure = if loaded then "module returned a non-table value" else tostring(result)
	end
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function roundDistance(value: number): number
	return math.round(value * 10) / 10
end

local function isKnownOutcome(outcome: Outcome): boolean
	return outcome == ResultTypes.Outcomes.CleanLanding
		or outcome == ResultTypes.Outcomes.Crashed
		or outcome == ResultTypes.Outcomes.Stalled
end

local function validateRouteCoinCount(courseId: CourseId, value: any): (number?, string?)
	if typeof(value) ~= "number"
		or not isFiniteNumber(value)
		or value % 1 ~= 0
		or value < 0
	then
		return nil, "invalid route coin count"
	end

	local routeCoinsCollected = value :: number
	if courseId == "FrozenLakeV2" then
		if routeCoinsCollected ~= 0 then
			return nil, "Classic route coin count must equal zero"
		end
		return routeCoinsCollected, nil
	elseif courseId ~= "FrostTrailV1" then
		return nil, "invalid CourseId"
	end

	local config = frostRouteContentConfig
	if config == nil then
		return nil, "Frost route configuration unavailable: " .. (frostRouteContentLoadFailure or "unknown load failure")
	end
	local runtime = config.Runtime
	if not table.isfrozen(config)
		or typeof(runtime) ~= "table"
		or not table.isfrozen(runtime)
		or config.RuntimeEnabled ~= true
		or config.RuntimeVersion ~= 1
		or runtime.CoinRewardPerPickup ~= 1
		or runtime.MaximumRouteCoins ~= 160
	then
		return nil, "Frost route configuration is invalid"
	end
	if routeCoinsCollected > runtime.MaximumRouteCoins then
		return nil, "Frost route coin count exceeds the configured maximum"
	end

	return routeCoinsCollected, nil
end

local function getOrCreatePlayerResultState(player: Player): PlayerResultState
	local existing = playerResultState[player]
	if existing then
		return existing
	end

	local created: PlayerResultState = {
		FinalizedRuns = {},
		FinalizingRuns = {},
	}
	playerResultState[player] = created
	return created
end

local function calculateCoins(outcome: Outcome, finalDistanceMeters: number): number
	local baseCoins = math.floor(finalDistanceMeters / RESULT.DistanceStepMeters) * RESULT.CoinsPerDistanceStep
	local coins: number
	if outcome == ResultTypes.Outcomes.CleanLanding then
		coins = baseCoins + RESULT.CleanLandingBonus
	elseif outcome == ResultTypes.Outcomes.Crashed then
		coins = math.floor(baseCoins * RESULT.CrashRewardMultiplier)
	else
		coins = RESULT.StalledReward
	end

	return math.clamp(coins, 0, RESULT.MaximumCoinsPerRun)
end

local function validateOutcomeFacts(facts: ServerFacts): string?
	if facts.Outcome == ResultTypes.Outcomes.CleanLanding then
		if not facts.EnteredAirborne or not facts.TouchedFrozenLake then
			return "clean landing lacks airborne or lake contact"
		elseif facts.SeatSeparatedAfterAirborne then
			return "clean landing rider separated"
		elseif facts.FinalUprightDot < RESULT.MinimumCleanUprightDot then
			return "clean landing is not upright"
		end
	elseif facts.Outcome == ResultTypes.Outcomes.Crashed then
		if not facts.EnteredAirborne or not facts.TouchedFrozenLake then
			return "crash lacks airborne or lake contact"
		elseif not facts.SeatSeparatedAfterAirborne
			and facts.FinalUprightDot >= RESULT.MinimumCleanUprightDot
		then
			return "crash has no observed crash fact"
		end
	elseif facts.EnteredAirborne then
		return "stalled run entered Airborne"
	end

	return nil
end

function ResultService.finalize(
	player: Player,
	courseId: CourseId,
	facts: ServerFacts,
	routeCoinsCollectedValue: any
): (Payload?, string?)
	if not PlayerDataService.isSupportedCourseId(courseId) then
		return nil, "invalid CourseId"
	end
	local routeCoinsCollected, routeCoinError = validateRouteCoinCount(courseId, routeCoinsCollectedValue)
	if routeCoinsCollected == nil then
		return nil, routeCoinError
	elseif facts.RunId <= 0 or facts.RunId % 1 ~= 0 then
		return nil, "invalid RunId"
	elseif not isKnownOutcome(facts.Outcome) then
		return nil, "invalid outcome"
	elseif not isFiniteNumber(facts.FinalStopDistanceMeters) then
		return nil, "invalid final distance"
	elseif not isFiniteNumber(facts.MaximumDistanceMeters) then
		return nil, "invalid maximum distance"
	elseif not isFiniteNumber(facts.FinalUprightDot) then
		return nil, "invalid upright dot"
	end
	local invalidFactsReason = validateOutcomeFacts(facts)
	if invalidFactsReason then
		return nil, invalidFactsReason
	end
	if not PlayerDataService.waitForLoad(player, GameConfig.PlayerData.LoadWaitTimeoutSeconds) then
		return nil, "player profile did not finish loading"
	end

	local resultState = getOrCreatePlayerResultState(player)
	if resultState.FinalizedRuns[facts.RunId] then
		return nil, "RunId already finalized"
	elseif resultState.FinalizingRuns[facts.RunId] then
		return nil, "RunId finalization is already in progress"
	end
	resultState.FinalizingRuns[facts.RunId] = true

	local finalDistanceMeters = math.max(0, facts.FinalStopDistanceMeters)
	local legacyReward = calculateCoins(facts.Outcome, finalDistanceMeters)
	local routeReward = routeCoinsCollected * 1
	local frostCoinsEarned = legacyReward + routeReward
	local rewardUpdate, mutationError = PlayerDataService.applyRunReward(
		player,
		courseId,
		finalDistanceMeters,
		frostCoinsEarned
	)
	if not rewardUpdate then
		resultState.FinalizingRuns[facts.RunId] = nil
		return nil, mutationError or "player progression mutation failed"
	end

	local payload: Payload = table.freeze({
		Version = ResultTypes.Version,
		RunId = facts.RunId,
		Outcome = facts.Outcome,
		FinalDistanceMeters = roundDistance(finalDistanceMeters),
		BestDistanceMeters = roundDistance(rewardUpdate.CourseBestDistance),
		FrostCoinsEarned = frostCoinsEarned,
		TotalFrostCoins = rewardUpdate.FrostCoins,
		TuckUsed = facts.TuckUsed,
		IsNewBest = rewardUpdate.IsNewBest,
		PersistenceStatus = rewardUpdate.PersistenceStatus,
	})

	resultState.FinalizedRuns[facts.RunId] = {
		Payload = payload,
	}
	resultState.FinalizingRuns[facts.RunId] = nil
	return payload, nil
end

function ResultService.removePlayer(player: Player)
	playerResultState[player] = nil
end

return ResultService
