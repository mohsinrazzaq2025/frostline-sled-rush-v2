--!strict

local PlayerDataTypes = require(script.Parent.PlayerDataTypes)

export type Outcome = "CleanLanding" | "Crashed" | "Stalled"
export type Action = "PlayAgain" | "ReturnToStart"

type OutcomeConstants = {
	CleanLanding: "CleanLanding",
	Crashed: "Crashed",
	Stalled: "Stalled",
}

type ActionConstants = {
	PlayAgain: "PlayAgain",
	ReturnToStart: "ReturnToStart",
}

local outcomes: OutcomeConstants = table.freeze({
	CleanLanding = "CleanLanding",
	Crashed = "Crashed",
	Stalled = "Stalled",
})

local actions: ActionConstants = table.freeze({
	PlayAgain = "PlayAgain",
	ReturnToStart = "ReturnToStart",
})

local ResultTypes = {
	Version = 2,
	Outcomes = outcomes,
	Actions = actions,
}

export type ServerFacts = {
	RunId: number,
	Outcome: Outcome,
	FinalStopDistanceMeters: number,
	MaximumDistanceMeters: number,
	TuckUsed: boolean,
	EnteredAirborne: boolean,
	TouchedFrozenLake: boolean,
	SeatSeparatedAfterAirborne: boolean,
	FinalUprightDot: number,
}

export type Payload = {
	Version: number,
	RunId: number,
	Outcome: Outcome,
	FinalDistanceMeters: number,
	BestDistanceMeters: number,
	FrostCoinsEarned: number,
	TotalFrostCoins: number,
	TuckUsed: boolean,
	IsNewBest: boolean,
	PersistenceStatus: PlayerDataTypes.PersistenceStatus,
}

return table.freeze(ResultTypes)
