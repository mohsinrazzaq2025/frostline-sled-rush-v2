--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

export type CourseId = "FrozenLakeV2"

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
}

export type CourseRegistryApi = {
	DefaultCourseId: CourseId,
	Definitions: { [CourseId]: CourseDefinition },
	getDefinition: (courseId: string) -> CourseDefinition?,
}

local FROZEN_LAKE_V2: CourseId = "FrozenLakeV2"

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
}
table.freeze(frozenLakeV2)

local definitions: { [CourseId]: CourseDefinition } = {
	[FROZEN_LAKE_V2] = frozenLakeV2,
}
table.freeze(definitions)

local function getDefinition(courseId: string): CourseDefinition?
	if courseId ~= FROZEN_LAKE_V2 then
		return nil
	end

	return definitions[FROZEN_LAKE_V2]
end

local CourseRegistry: CourseRegistryApi = {
	DefaultCourseId = FROZEN_LAKE_V2,
	Definitions = definitions,
	getDefinition = getDefinition,
}
table.freeze(CourseRegistry)

return CourseRegistry
