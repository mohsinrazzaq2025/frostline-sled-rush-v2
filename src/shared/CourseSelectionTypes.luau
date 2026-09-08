--!strict

export type CourseId = "FrozenLakeV2" | "FrostTrailV1"
export type Action = "GetState" | "Select"

export type StatusCode = "State"
	| "Success"
	| "AlreadySelected"
	| "InvalidRequest"
	| "UnsupportedVersion"
	| "RequestIdConflict"
	| "RequestInProgress"
	| "RateLimited"
	| "Busy"
	| "CourseUnavailable"
	| "CharacterUnavailable"
	| "TeleportFailed"
	| "SafetyFallback"
	| "InternalError"

export type RunPhase = "Idle" | "Countdown" | "Descent" | "Airborne" | "Landed" | "Results" | "Reset"

export type CourseDescriptor = {
	CourseId: CourseId,
	DisplayName: string,
	Available: boolean,
}

export type Catalog = { CourseDescriptor }

export type GetStateRequest = {
	ProtocolVersion: number,
	RequestId: string,
	ClientSequence: number,
	Action: "GetState",
}

export type SelectRequest = {
	ProtocolVersion: number,
	RequestId: string,
	ClientSequence: number,
	Action: "Select",
	CourseId: CourseId,
}

export type Request = GetStateRequest | SelectRequest

export type GetStateResponse = {
	ProtocolVersion: number,
	CatalogVersion: number,
	ServerSequence: number,
	ResponseToRequestId: string,
	ResponseClientSequence: number,
	ResponseAction: "GetState",
	Ok: boolean,
	StatusCode: StatusCode,
	SelectedCourseId: CourseId,
	CanSelect: boolean,
	RunPhase: RunPhase,
	Courses: Catalog,
}

export type SelectResponse = {
	ProtocolVersion: number,
	CatalogVersion: number,
	ServerSequence: number,
	ResponseToRequestId: string,
	ResponseClientSequence: number,
	ResponseAction: "Select",
	ResponseCourseId: CourseId,
	Ok: boolean,
	StatusCode: StatusCode,
	SelectedCourseId: CourseId,
	CanSelect: boolean,
	RunPhase: RunPhase,
	Courses: Catalog,
}

export type Response = GetStateResponse | SelectResponse

type CourseIdConstants = {
	FrozenLakeV2: "FrozenLakeV2",
	FrostTrailV1: "FrostTrailV1",
}

type ActionConstants = {
	GetState: "GetState",
	Select: "Select",
}

type StatusCodeConstants = {
	State: "State",
	Success: "Success",
	AlreadySelected: "AlreadySelected",
	InvalidRequest: "InvalidRequest",
	UnsupportedVersion: "UnsupportedVersion",
	RequestIdConflict: "RequestIdConflict",
	RequestInProgress: "RequestInProgress",
	RateLimited: "RateLimited",
	Busy: "Busy",
	CourseUnavailable: "CourseUnavailable",
	CharacterUnavailable: "CharacterUnavailable",
	TeleportFailed: "TeleportFailed",
	SafetyFallback: "SafetyFallback",
	InternalError: "InternalError",
}

type RunPhaseConstants = {
	Idle: "Idle",
	Countdown: "Countdown",
	Descent: "Descent",
	Airborne: "Airborne",
	Landed: "Landed",
	Results: "Results",
	Reset: "Reset",
}

local courseIds: CourseIdConstants = table.freeze({
	FrozenLakeV2 = "FrozenLakeV2",
	FrostTrailV1 = "FrostTrailV1",
})

local actions: ActionConstants = table.freeze({
	GetState = "GetState",
	Select = "Select",
})

local statusCodes: StatusCodeConstants = table.freeze({
	State = "State",
	Success = "Success",
	AlreadySelected = "AlreadySelected",
	InvalidRequest = "InvalidRequest",
	UnsupportedVersion = "UnsupportedVersion",
	RequestIdConflict = "RequestIdConflict",
	RequestInProgress = "RequestInProgress",
	RateLimited = "RateLimited",
	Busy = "Busy",
	CourseUnavailable = "CourseUnavailable",
	CharacterUnavailable = "CharacterUnavailable",
	TeleportFailed = "TeleportFailed",
	SafetyFallback = "SafetyFallback",
	InternalError = "InternalError",
})

local runPhases: RunPhaseConstants = table.freeze({
	Idle = "Idle",
	Countdown = "Countdown",
	Descent = "Descent",
	Airborne = "Airborne",
	Landed = "Landed",
	Results = "Results",
	Reset = "Reset",
})

local CourseSelectionTypes = {
	RemoteName = "CourseSelection",
	ProtocolVersion = 1,
	CatalogVersion = 1,
	MaximumServerSequence = 2147483647,
	MaximumClientSequence = 2147483647,
	MaximumClientSequenceJump = 32,
	CompletedRequestCacheCapacity = 8,
	TransportRateTokensPerSecond = 2,
	TransportRateBucketCapacity = 4,
	SelectRateTokensPerSecond = 1,
	SelectRateBucketCapacity = 2,
	CourseIds = courseIds,
	Actions = actions,
	StatusCodes = statusCodes,
	RunPhases = runPhases,
}

return table.freeze(CourseSelectionTypes)
