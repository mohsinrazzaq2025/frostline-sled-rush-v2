--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local FrostTrailConfig = require(script.Parent.FrostTrailConfig)

export type CourseId = "FrozenLakeV2" | "FrostTrailV1"
export type ActivationMode = "LiveDefault" | "StudioControlledTest"
export type RouteMode = "FixedBasis" | "MonotonicZCenterline"
export type RouteData = FrostTrailConfig.RouteData

export type CourseDefinition = {
	CourseId: CourseId,
	DisplayName: string,
	WorldModelName: string,
	GeometryFolderName: string,
	MarkersFolderName: string,
	ActiveSledsFolderName: string,
	StartTriggerName: string,
	SummitPlatformName: string,
	LaunchEdgeName: string,
	LandingSurfacesName: string,
	PlayerSpawnName: string,
	CoordinateOrigin: Vector3,
	ForwardDirection: Vector3,
	TrackWidth: number,
	StudsPerMeter: number,
	RampFreedomLongitudinal: number,
	LandingFieldDistanceMeters: number,
	MaximumRunDurationSeconds: number,
	SafetyMaximumLateralDistance: number,
	SafetyMinimumWorldY: number,
	ActivationMode: ActivationMode,
	RouteMode: RouteMode,
	RouteData: RouteData?,
}

export type CourseRegistryApi = {
	DefaultCourseId: CourseId,
	Definitions: { [CourseId]: CourseDefinition },
	getDefinition: (courseId: string) -> CourseDefinition?,
}

local FROZEN_LAKE_V2: CourseId = "FrozenLakeV2"
local FROST_TRAIL_V1: CourseId = "FrostTrailV1"

local frozenLakeV2: CourseDefinition = {
	CourseId = FROZEN_LAKE_V2,
	DisplayName = "CLASSIC DISTANCE",
	WorldModelName = GameConfig.World.FolderName,
	GeometryFolderName = "Geometry",
	MarkersFolderName = "Markers",
	ActiveSledsFolderName = "ActiveSleds",
	StartTriggerName = "StartTrigger",
	SummitPlatformName = "SummitPlatform",
	LaunchEdgeName = "LaunchEdge",
	LandingSurfacesName = "FrozenLake",
	PlayerSpawnName = "PlayerSpawn",
	CoordinateOrigin = Vector3.zero,
	ForwardDirection = Vector3.zAxis,
	TrackWidth = GameConfig.World.TrackWidth,
	StudsPerMeter = GameConfig.World.StudsPerMeter,
	RampFreedomLongitudinal = GameConfig.Run.RampFreedomStartZ,
	LandingFieldDistanceMeters = GameConfig.World.LandingMarkedDistanceMeters
		+ GameConfig.World.LandingRunoffDistanceMeters,
	MaximumRunDurationSeconds = GameConfig.Run.MaximumRunDuration,
	SafetyMaximumLateralDistance = GameConfig.Run.SafetyBounds.MaximumLateralDistance,
	SafetyMinimumWorldY = GameConfig.Run.SafetyBounds.MinimumY,
	ActivationMode = "LiveDefault",
	RouteMode = "FixedBasis",
}
table.freeze(frozenLakeV2)

local frostTrailV1: CourseDefinition = {
	CourseId = FROST_TRAIL_V1,
	DisplayName = FrostTrailConfig.DisplayName,
	WorldModelName = FrostTrailConfig.WorldModelName,
	GeometryFolderName = "Geometry",
	MarkersFolderName = "Markers",
	ActiveSledsFolderName = "ActiveSleds",
	StartTriggerName = "StartTrigger",
	SummitPlatformName = "SummitPlatform",
	LaunchEdgeName = "LaunchEdge",
	LandingSurfacesName = "FrostTrailLake",
	PlayerSpawnName = "PlayerSpawn",
	CoordinateOrigin = FrostTrailConfig.WorldOrigin,
	ForwardDirection = FrostTrailConfig.ForwardDirection,
	TrackWidth = FrostTrailConfig.TrackWidth,
	StudsPerMeter = FrostTrailConfig.StudsPerMeter,
	RampFreedomLongitudinal = FrostTrailConfig.RampFreedomLongitudinal,
	LandingFieldDistanceMeters = FrostTrailConfig.LandingFieldDistanceMeters,
	MaximumRunDurationSeconds = FrostTrailConfig.MaximumRunDurationSeconds,
	SafetyMaximumLateralDistance = FrostTrailConfig.SafetyMaximumLateralDistance,
	SafetyMinimumWorldY = FrostTrailConfig.SafetyMinimumWorldY,
	ActivationMode = FrostTrailConfig.ActivationMode,
	RouteMode = "MonotonicZCenterline",
	RouteData = FrostTrailConfig.RouteData,
}
table.freeze(frostTrailV1)

local definitions: { [CourseId]: CourseDefinition } = {
	[FROZEN_LAKE_V2] = frozenLakeV2,
	[FROST_TRAIL_V1] = frostTrailV1,
}
table.freeze(definitions)

local function getDefinition(courseId: string): CourseDefinition?
	if courseId == FROZEN_LAKE_V2 then
		return definitions[FROZEN_LAKE_V2]
	elseif courseId == FROST_TRAIL_V1 then
		return definitions[FROST_TRAIL_V1]
	end

	return nil
end

local CourseRegistry: CourseRegistryApi = {
	DefaultCourseId = FROZEN_LAKE_V2,
	Definitions = definitions,
	getDefinition = getDefinition,
}
table.freeze(CourseRegistry)

return CourseRegistry
