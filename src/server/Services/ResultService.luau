--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)

local RESULT = GameConfig.Result

type Outcome = ResultTypes.Outcome
type Payload = ResultTypes.Payload
type ServerFacts = ResultTypes.ServerFacts

type FinalizedRecord = {
	PreciseFinalDistanceMeters: number,
	PreciseBestDistanceMeters: number,
	Payload: Payload,
}

type PlayerData = {
	BestDistanceMeters: number,
	TotalFrostCoins: number,
	FinalizedRuns: { [number]: FinalizedRecord },
}

local ResultService = {}

local playerData: { [Player]: PlayerData } = {}

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

local function getOrCreatePlayerData(player: Player): PlayerData
	local existing = playerData[player]
	if existing then
		return existing
	end

	local created: PlayerData = {
		BestDistanceMeters = 0,
		TotalFrostCoins = 0,
		FinalizedRuns = {},
	}
	playerData[player] = created
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

	local data = getOrCreatePlayerData(player)
	if data.FinalizedRuns[facts.RunId] then
		return nil, "RunId already finalized"
	end

	local finalDistanceMeters = math.max(0, facts.FinalStopDistanceMeters)
	local isNewBest = finalDistanceMeters > data.BestDistanceMeters
	if isNewBest then
		data.BestDistanceMeters = finalDistanceMeters
	end

	local frostCoinsEarned = calculateCoins(facts.Outcome, finalDistanceMeters)
	data.TotalFrostCoins += frostCoinsEarned

	local payload: Payload = table.freeze({
		Version = ResultTypes.Version,
		RunId = facts.RunId,
		Outcome = facts.Outcome,
		FinalDistanceMeters = roundDistance(finalDistanceMeters),
		BestDistanceMeters = roundDistance(data.BestDistanceMeters),
		FrostCoinsEarned = frostCoinsEarned,
		TotalFrostCoins = data.TotalFrostCoins,
		TuckUsed = facts.TuckUsed,
		IsNewBest = isNewBest,
	})

	data.FinalizedRuns[facts.RunId] = {
		PreciseFinalDistanceMeters = finalDistanceMeters,
		PreciseBestDistanceMeters = data.BestDistanceMeters,
		Payload = payload,
	}
	return payload, nil
end

function ResultService.removePlayer(player: Player)
	playerData[player] = nil
end

return ResultService
