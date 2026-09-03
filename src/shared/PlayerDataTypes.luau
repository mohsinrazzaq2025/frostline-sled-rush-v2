--!strict

export type PersistenceStatus = "Persistent" | "SessionOnly"

export type PlayerProgress = {
	SchemaVersion: number,
	FrostCoins: number,
	BestDistance: number,
}

export type ProgressSnapshot = {
	SchemaVersion: number,
	FrostCoins: number,
	BestDistance: number,
	PersistenceStatus: PersistenceStatus,
}

export type RewardUpdate = ProgressSnapshot & {
	IsNewBest: boolean,
}

type PersistenceStatusConstants = {
	Persistent: "Persistent",
	SessionOnly: "SessionOnly",
}

local persistenceStatuses: PersistenceStatusConstants = table.freeze({
	Persistent = "Persistent",
	SessionOnly = "SessionOnly",
})

local PlayerDataTypes = {
	PersistenceStatuses = persistenceStatuses,
}

return table.freeze(PlayerDataTypes)
