--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)
local PlayerDataService = require(script.Parent.PlayerDataService)

local RESULT = GameConfig.Result

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

function ResultService.finalize(player: Player, facts: ServerFacts): (Payload?, string?)
	if facts.RunId <= 0 or facts.RunId % 1 ~= 0 then
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
	local frostCoinsEarned = calculateCoins(facts.Outcome, finalDistanceMeters)
	local rewardUpdate, mutationError = PlayerDataService.applyRunReward(
		player,
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
		BestDistanceMeters = roundDistance(rewardUpdate.BestDistance),
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
