--!strict

export type Action = "GetState" | "Purchase" | "Equip"

export type StatusCode = "State"
	| "InvalidRequest"
	| "UnsupportedVersion"
	| "RequestIdConflict"
	| "RequestInProgress"
	| "RateLimited"
	| "ProfileLoading"
	| "PersistenceUnavailable"
	| "StoreUnavailable"
	| "UnknownSled"
	| "NotForSale"
	| "StateChanged"
	| "InsufficientFunds"
	| "NotOwned"
	| "Busy"
	| "SavePending"
	| "InternalError"
	| "AlreadyOwned"
	| "AlreadyEquipped"
	| "Success"

export type PersistenceState = "Persistent" | "Loading" | "SessionOnly" | "Releasing" | "SavePending"

export type OwnershipSnapshot = { [string]: boolean }

export type CatalogEntry = {
	SledId: string,
	DisplayName: string,
	Price: number,
	ForSale: boolean,
	Description: string,
}

export type Catalog = { [string]: CatalogEntry }

export type Request = {
	ProtocolVersion: number,
	RequestId: string,
	Action: Action,
	SledId: string?,
	ExpectedRevision: number?,
}

export type StoreState = {
	ProtocolVersion: number,
	CatalogVersion: number,
	ServerSequence: number,
	DataRevision: number,
	ResponseToRequestId: string,
	ResponseAction: Action,
	ResponseSledId: string?,
	Ok: boolean,
	StatusCode: StatusCode,
	CanBrowse: boolean,
	CanTransact: boolean,
	PersistenceState: PersistenceState,
	FrostCoins: number,
	OwnedSleds: OwnershipSnapshot,
	EquippedSledId: string,
}

type ActionConstants = {
	GetState: "GetState",
	Purchase: "Purchase",
	Equip: "Equip",
}

type StatusCodeConstants = {
	State: "State",
	InvalidRequest: "InvalidRequest",
	UnsupportedVersion: "UnsupportedVersion",
	RequestIdConflict: "RequestIdConflict",
	RequestInProgress: "RequestInProgress",
	RateLimited: "RateLimited",
	ProfileLoading: "ProfileLoading",
	PersistenceUnavailable: "PersistenceUnavailable",
	StoreUnavailable: "StoreUnavailable",
	UnknownSled: "UnknownSled",
	NotForSale: "NotForSale",
	StateChanged: "StateChanged",
	InsufficientFunds: "InsufficientFunds",
	NotOwned: "NotOwned",
	Busy: "Busy",
	SavePending: "SavePending",
	InternalError: "InternalError",
	AlreadyOwned: "AlreadyOwned",
	AlreadyEquipped: "AlreadyEquipped",
	Success: "Success",
}

type PersistenceStateConstants = {
	Persistent: "Persistent",
	Loading: "Loading",
	SessionOnly: "SessionOnly",
	Releasing: "Releasing",
	SavePending: "SavePending",
}

local actions: ActionConstants = table.freeze({
	GetState = "GetState",
	Purchase = "Purchase",
	Equip = "Equip",
})

local statusCodes: StatusCodeConstants = table.freeze({
	State = "State",
	InvalidRequest = "InvalidRequest",
	UnsupportedVersion = "UnsupportedVersion",
	RequestIdConflict = "RequestIdConflict",
	RequestInProgress = "RequestInProgress",
	RateLimited = "RateLimited",
	ProfileLoading = "ProfileLoading",
	PersistenceUnavailable = "PersistenceUnavailable",
	StoreUnavailable = "StoreUnavailable",
	UnknownSled = "UnknownSled",
	NotForSale = "NotForSale",
	StateChanged = "StateChanged",
	InsufficientFunds = "InsufficientFunds",
	NotOwned = "NotOwned",
	Busy = "Busy",
	SavePending = "SavePending",
	InternalError = "InternalError",
	AlreadyOwned = "AlreadyOwned",
	AlreadyEquipped = "AlreadyEquipped",
	Success = "Success",
})

local persistenceStates: PersistenceStateConstants = table.freeze({
	Persistent = "Persistent",
	Loading = "Loading",
	SessionOnly = "SessionOnly",
	Releasing = "Releasing",
	SavePending = "SavePending",
})

local StoreTypes = {
	ProtocolVersion = 1,
	Actions = actions,
	StatusCodes = statusCodes,
	PersistenceStates = persistenceStates,
}

return table.freeze(StoreTypes)
