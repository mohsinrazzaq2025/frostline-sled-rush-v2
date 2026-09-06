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

export type RouteGeometryPoint = {
	LocalPosition: Vector3,
	TrackWidth: number,
	ClearPlayableWidth: number,
}

export type RouteData = {
	SampledCenterlinePoints: { Vector3 },
	GeometryPoints: { RouteGeometryPoint },
	GeometrySplitLongitudinals: { number },
	AuthoredPathLengthStuds: number,
}

export type FrostTrailConfig = {
	CourseId: string,
	DisplayName: string,
	WorldModelName: string,
	WorldVersion: number,
	StaticFoundationOnly: boolean,
	Playable: boolean,
	ActivationMode: "StudioControlledTest",
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
	RouteData: RouteData,
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

local TRACK_WIDTH = 84
local CLEAR_PLAYABLE_WIDTH = 72
local WIDENED_TRACK_WIDTH = 120
local WIDENED_CLEAR_PLAYABLE_WIDTH = 108
local SAMPLES_PER_CURVE = 4

local geometrySplitLongitudinals: { number } = {
	3050,
	3075,
	3100,
	3125,
	3150,
	3600,
	3625,
	3650,
	3675,
	3700,
	3950,
	3975,
	4000,
	4025,
	4050,
	4500,
	4525,
	4550,
	4575,
	4600,
}
table.freeze(geometrySplitLongitudinals)

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

local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, alpha: number): Vector3
	local alphaSquared = alpha * alpha
	local alphaCubed = alphaSquared * alpha
	return 0.5
		* (
			(2 * p1)
			+ ((-p0 + p2) * alpha)
			+ ((2 * p0 - 5 * p1 + 4 * p2 - p3) * alphaSquared)
			+ ((-p0 + 3 * p1 - 3 * p2 + p3) * alphaCubed)
		)
end

local function sampleCenterline(): { Vector3 }
	local sampled: { Vector3 } = {}
	for index = 1, #pathPoints - 1 do
		local p0 = pathPoints[math.max(1, index - 1)]
		local p1 = pathPoints[index]
		local p2 = pathPoints[index + 1]
		local p3 = pathPoints[math.min(#pathPoints, index + 2)]
		for sampleIndex = 0, SAMPLES_PER_CURVE - 1 do
			local alpha = sampleIndex / SAMPLES_PER_CURVE
			table.insert(sampled, catmullRom(p0, p1, p2, p3, alpha))
		end
	end
	table.insert(sampled, pathPoints[#pathPoints])
	return sampled
end

local function smoothstep(alpha: number): number
	local clamped = math.clamp(alpha, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function widthsAt(longitudinal: number): (number, number)
	for _, taper in ipairs(taperZones) do
		if longitudinal >= taper.StartLongitudinal and longitudinal <= taper.EndLongitudinal then
			local alpha = (longitudinal - taper.StartLongitudinal)
				/ (taper.EndLongitudinal - taper.StartLongitudinal)
			local eased = smoothstep(alpha)
			if taper.Widens then
				return TRACK_WIDTH + (WIDENED_TRACK_WIDTH - TRACK_WIDTH) * eased,
					CLEAR_PLAYABLE_WIDTH
						+ (WIDENED_CLEAR_PLAYABLE_WIDTH - CLEAR_PLAYABLE_WIDTH) * eased
			end
			return WIDENED_TRACK_WIDTH + (TRACK_WIDTH - WIDENED_TRACK_WIDTH) * eased,
				WIDENED_CLEAR_PLAYABLE_WIDTH
					+ (CLEAR_PLAYABLE_WIDTH - WIDENED_CLEAR_PLAYABLE_WIDTH) * eased
		end
	end
	for _, zone in ipairs(widenedRouteZones) do
		if longitudinal >= zone.StartLongitudinal and longitudinal <= zone.EndLongitudinal then
			return WIDENED_TRACK_WIDTH, WIDENED_CLEAR_PLAYABLE_WIDTH
		end
	end
	return TRACK_WIDTH, CLEAR_PLAYABLE_WIDTH
end

local function splitCenterline(sampled: { Vector3 }): { Vector3 }
	local geometryPositions: { Vector3 } = { sampled[1] }
	for index = 1, #sampled - 1 do
		local pointA = sampled[index]
		local pointB = sampled[index + 1]
		for _, splitLongitudinal in ipairs(geometrySplitLongitudinals) do
			if splitLongitudinal > pointA.Z and splitLongitudinal < pointB.Z then
				local alpha = (splitLongitudinal - pointA.Z) / (pointB.Z - pointA.Z)
				table.insert(geometryPositions, pointA:Lerp(pointB, alpha))
			end
		end
		table.insert(geometryPositions, pointB)
	end
	return geometryPositions
end

local sampledCenterlinePoints = sampleCenterline()
local authoredPathLengthStuds = 0
for index = 1, #sampledCenterlinePoints - 1 do
	authoredPathLengthStuds += (sampledCenterlinePoints[index + 1] - sampledCenterlinePoints[index]).Magnitude
end
table.freeze(sampledCenterlinePoints)

local geometryPositions = splitCenterline(sampledCenterlinePoints)
local geometryPoints: { RouteGeometryPoint } = {}
for _, localPosition in ipairs(geometryPositions) do
	local trackWidth, clearPlayableWidth = widthsAt(localPosition.Z)
	local routePoint: RouteGeometryPoint = {
		LocalPosition = localPosition,
		TrackWidth = trackWidth,
		ClearPlayableWidth = clearPlayableWidth,
	}
	table.freeze(routePoint)
	table.insert(geometryPoints, routePoint)
end
table.freeze(geometryPoints)

local routeData: RouteData = {
	SampledCenterlinePoints = sampledCenterlinePoints,
	GeometryPoints = geometryPoints,
	GeometrySplitLongitudinals = geometrySplitLongitudinals,
	AuthoredPathLengthStuds = authoredPathLengthStuds,
}
table.freeze(routeData)

local config: FrostTrailConfig = {
	CourseId = "FrostTrailV1",
	DisplayName = "FROST TRAIL",
	WorldModelName = "FrostTrailWorld",
	WorldVersion = 1,
	StaticFoundationOnly = false,
	Playable = false,
	ActivationMode = "StudioControlledTest",
	WorldOrigin = Vector3.new(3200, 0, 0),
	ForwardDirection = Vector3.zAxis,
	ValidationEpsilon = 1e-5,
	TrackWidth = TRACK_WIDTH,
	ClearPlayableWidth = CLEAR_PLAYABLE_WIDTH,
	LaneCenterOffsets = laneCenterOffsets,
	WidenedTrackWidth = WIDENED_TRACK_WIDTH,
	WidenedClearPlayableWidth = WIDENED_CLEAR_PLAYABLE_WIDTH,
	TrackThickness = 3,
	TrackSegmentOverlap = 1.5,
	SamplesPerCurve = SAMPLES_PER_CURVE,
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
	RouteData = routeData,
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
