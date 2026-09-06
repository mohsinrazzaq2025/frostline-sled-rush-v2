--!strict

export type SectionDefinition = {
	SectionId: string,
	StartLongitudinal: number,
	EndLongitudinal: number,
}

export type RouteWidthZone = {
	StartLongitudinal: number,
	EndLongitudinal: number,
}

export type TaperZone = {
	StartLongitudinal: number,
	EndLongitudinal: number,
	Widens: boolean,
}

export type FrostTrailConfig = {
	CourseId: string,
	DisplayName: string,
	WorldModelName: string,
	WorldVersion: number,
	StaticFoundationOnly: boolean,
	Playable: boolean,
	WorldOrigin: Vector3,
	ForwardDirection: Vector3,
	ValidationEpsilon: number,
	TrackWidth: number,
	ClearPlayableWidth: number,
	LaneCenterOffsets: { number },
	WidenedTrackWidth: number,
	WidenedClearPlayableWidth: number,
	TrackThickness: number,
	TrackSegmentOverlap: number,
	SamplesPerCurve: number,
	SnowBankWidth: number,
	SafetyWallThickness: number,
	SafetyWallHeight: number,
	StudsPerMeter: number,
	MaximumRunDurationSeconds: number,
	SafetyMaximumLateralDistance: number,
	SafetyMinimumWorldY: number,
	RampFreedomLongitudinal: number,
	LandingFieldDistanceMeters: number,
	LandingMarkedDistanceMeters: number,
	LandingRunoffDistanceMeters: number,
	LandingWidth: number,
	LandingThickness: number,
	LandingTopY: number,
	LandingSegmentOverlap: number,
	PathPoints: { Vector3 },
	Sections: { SectionDefinition },
	WidenedRouteZones: { RouteWidthZone },
	TaperZones: { TaperZone },
	SummitPlatformCenter: Vector3,
	SummitPlatformSize: Vector3,
	PlayerSpawnCenter: Vector3,
	PlayerSpawnSize: Vector3,
	StartTriggerCenter: Vector3,
	StartTriggerSize: Vector3,
	StartSlotBaseCenter: Vector3,
	StartSlotSize: Vector3,
	LaunchMarkerSize: Vector3,
	LandingStartLongitudinal: number,
	LandingEndLongitudinal: number,
}

local pathPoints: { Vector3 } = {
	Vector3.new(0, 560, -250),
	Vector3.new(-18, 548, 100),
	Vector3.new(34, 520, 550),
	Vector3.new(-42, 480, 1050),
	Vector3.new(46, 430, 1550),
	Vector3.new(-34, 382, 2050),
	Vector3.new(40, 330, 2550),
	Vector3.new(-48, 282, 3100),
	Vector3.new(52, 232, 3650),
	Vector3.new(-38, 185, 4200),
	Vector3.new(42, 142, 4750),
	Vector3.new(-30, 108, 5300),
	Vector3.new(22, 82, 5750),
	Vector3.new(0, 62, 6100),
	Vector3.new(0, 82, 6350),
}
table.freeze(pathPoints)

local sections: { SectionDefinition } = {
	table.freeze({ SectionId = "SummitCamp", StartLongitudinal = -400, EndLongitudinal = 500 }),
	table.freeze({ SectionId = "PineSlalom", StartLongitudinal = 500, EndLongitudinal = 1400 }),
	table.freeze({ SectionId = "CrystalCave", StartLongitudinal = 1400, EndLongitudinal = 2250 }),
	table.freeze({ SectionId = "GlacierBridge", StartLongitudinal = 2250, EndLongitudinal = 3000 }),
	table.freeze({ SectionId = "AvalanchePass", StartLongitudinal = 3000, EndLongitudinal = 3800 }),
	table.freeze({ SectionId = "FrozenVillage", StartLongitudinal = 3800, EndLongitudinal = 4700 }),
	table.freeze({ SectionId = "FrozenRiver", StartLongitudinal = 4700, EndLongitudinal = 5550 }),
	table.freeze({ SectionId = "AlpineChute", StartLongitudinal = 5550, EndLongitudinal = 6350 }),
	table.freeze({ SectionId = "LandingLake", StartLongitudinal = 6350, EndLongitudinal = 8600 }),
}
table.freeze(sections)

local widenedRouteZones: { RouteWidthZone } = {
	table.freeze({ StartLongitudinal = 3150, EndLongitudinal = 3600 }),
	table.freeze({ StartLongitudinal = 4050, EndLongitudinal = 4500 }),
}
table.freeze(widenedRouteZones)

local taperZones: { TaperZone } = {
	table.freeze({ StartLongitudinal = 3050, EndLongitudinal = 3150, Widens = true }),
	table.freeze({ StartLongitudinal = 3600, EndLongitudinal = 3700, Widens = false }),
	table.freeze({ StartLongitudinal = 3950, EndLongitudinal = 4050, Widens = true }),
	table.freeze({ StartLongitudinal = 4500, EndLongitudinal = 4600, Widens = false }),
}
table.freeze(taperZones)

local laneCenterOffsets: { number } = { -24, 0, 24 }
table.freeze(laneCenterOffsets)

local config: FrostTrailConfig = {
	CourseId = "FrostTrailV1",
	DisplayName = "FROST TRAIL",
	WorldModelName = "FrostTrailWorld",
	WorldVersion = 1,
	StaticFoundationOnly = true,
	Playable = false,
	WorldOrigin = Vector3.new(3200, 0, 0),
	ForwardDirection = Vector3.zAxis,
	ValidationEpsilon = 1e-5,
	TrackWidth = 84,
	ClearPlayableWidth = 72,
	LaneCenterOffsets = laneCenterOffsets,
	WidenedTrackWidth = 120,
	WidenedClearPlayableWidth = 108,
	TrackThickness = 3,
	TrackSegmentOverlap = 1.5,
	SamplesPerCurve = 4,
	SnowBankWidth = 10,
	SafetyWallThickness = 2,
	SafetyWallHeight = 14,
	StudsPerMeter = 1.25,
	MaximumRunDurationSeconds = 150,
	SafetyMaximumLateralDistance = 900,
	SafetyMinimumWorldY = -200,
	RampFreedomLongitudinal = 6100,
	LandingFieldDistanceMeters = 1800,
	LandingMarkedDistanceMeters = 1500,
	LandingRunoffDistanceMeters = 300,
	LandingWidth = 360,
	LandingThickness = 3,
	LandingTopY = 0,
	LandingSegmentOverlap = 0.25,
	PathPoints = pathPoints,
	Sections = sections,
	WidenedRouteZones = widenedRouteZones,
	TaperZones = taperZones,
	SummitPlatformCenter = Vector3.new(0, 554, -325),
	SummitPlatformSize = Vector3.new(160, 12, 170),
	PlayerSpawnCenter = Vector3.new(0, 560.5, -355),
	PlayerSpawnSize = Vector3.new(12, 1, 12),
	StartTriggerCenter = Vector3.new(0, 561, -242),
	StartTriggerSize = Vector3.new(32, 1, 18),
	StartSlotBaseCenter = Vector3.new(0, 561, -260),
	StartSlotSize = Vector3.new(4, 1, 8),
	LaunchMarkerSize = Vector3.new(84, 12, 2),
	LandingStartLongitudinal = 6350,
	LandingEndLongitudinal = 8600,
}

return table.freeze(config)
