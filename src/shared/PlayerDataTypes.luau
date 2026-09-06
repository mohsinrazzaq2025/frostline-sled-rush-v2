--!strict

export type PersistenceStatus = "Persistent" | "SessionOnly"

export type CourseId = "FrozenLakeV2" | "FrostTrailV1"

export type OwnedSleds = { [string]: boolean }

export type CourseBestDistances = {
	FrostTrailV1: number,
}

export type PlayerProgress = {
	SchemaVersion: number,
	FrostCoins: number,
	BestDistance: number,
	CourseBestDistances: CourseBestDistances,
	OwnedSleds: OwnedSleds,
	EquippedSledId: string,
}

export type ProgressSnapshot = {
	SchemaVersion: number,
	FrostCoins: number,
	BestDistance: number,
	CourseBestDistances: CourseBestDistances,
	OwnedSleds: OwnedSleds,
	EquippedSledId: string,
	PersistenceStatus: PersistenceStatus,
}

export type RewardUpdate = ProgressSnapshot & {
	CourseBestDistance: number,
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
