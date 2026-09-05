--!strict

export type PersistenceStatus = "Persistent" | "SessionOnly"

export type OwnedSleds = { [string]: boolean }

export type PlayerProgress = {
	SchemaVersion: number,
	FrostCoins: number,
	BestDistance: number,
	OwnedSleds: OwnedSleds,
	EquippedSledId: string,
}

export type ProgressSnapshot = {
	SchemaVersion: number,
	FrostCoins: number,
	BestDistance: number,
	OwnedSleds: OwnedSleds,
	EquippedSledId: string,
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
