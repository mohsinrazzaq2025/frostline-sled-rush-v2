--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FrostTrailConfig = require(script.Parent.FrostTrailConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PHYSICS = GameConfig.Physics
local PALETTE = GameConfig.Palette

local FrostTrailWorldBuilder = {}

local EXPECTED_BASE_SAMPLES = 57
local EXPECTED_BASE_CHORDS = 56
local EXPECTED_GEOMETRY_POINTS = 75
local EXPECTED_GEOMETRY_SEGMENTS = 74
local EXPECTED_AUTHORED_LENGTH = 6696.671726289
local EXPECTED_BASE_PART_COUNT = 447
local EXPECTED_COLLIDABLE_COUNT = 229
local EXPECTED_SHADOW_COUNT = 68
local EXPECTED_MARKER_COUNT = 15
local EXPECTED_DECOR_COUNT = 129
local TRACK_SURFACE_ATTRIBUTE = "FrostlineTrackSurface"
local SHOULDER_THICKNESS = 4
local SHOULDER_SURFACE_GAP = 0.05
local SUMMIT_WALL_OVERLAP = 1
local CRYSTAL_ENVELOPE_WIDTH = 100
local CRYSTAL_ENVELOPE_HEIGHT = 35
local LOCAL_BOUNDS_MIN = Vector3.new(-700, -20, -500)
local LOCAL_BOUNDS_MAX = Vector3.new(700, 850, 8800)
local MINIMUM_CLASSIC_SEPARATION_X = 1000
local START_SLOT_OFFSETS = table.freeze({ -27, -9, 9, 27 })
local GEOMETRY_SPLIT_LONGITUDINALS = table.freeze({
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
})

local REQUIRED_PATH_POINTS = table.freeze({
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
})

local REQUIRED_SECTIONS = table.freeze({
	table.freeze({ "SummitCamp", -400, 500 }),
	table.freeze({ "PineSlalom", 500, 1400 }),
	table.freeze({ "CrystalCave", 1400, 2250 }),
	table.freeze({ "GlacierBridge", 2250, 3000 }),
	table.freeze({ "AvalanchePass", 3000, 3800 }),
	table.freeze({ "FrozenVillage", 3800, 4700 }),
	table.freeze({ "FrozenRiver", 4700, 5550 }),
	table.freeze({ "AlpineChute", 5550, 6350 }),
	table.freeze({ "LandingLake", 6350, 8600 }),
})

local RIGHT_DIRECTION = FrostTrailConfig.ForwardDirection:Cross(Vector3.yAxis).Unit

type Widths = {
	Track: number,
	Clear: number,
}

type SegmentPlan = {
	PointA: Vector3,
	PointB: Vector3,
	Direction: Vector3,
	Length: number,
	TrackWidth: number,
	ClearWidth: number,
	StartExtension: number,
	EndExtension: number,
}

type Bounds = {
	Minimum: Vector3,
	Maximum: Vector3,
}

local function fail(message: string): never
	error("Frost Trail static world: " .. message, 0)
end

local function requireCondition(condition: boolean, message: string)
	if not condition then
		fail(message)
	end
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function approximatelyEqual(a: number, b: number, epsilon: number): boolean
	return math.abs(a - b) <= epsilon
end

local function validatePositiveFinite(value: number, name: string)
	requireCondition(isFiniteNumber(value) and value > 0, name .. " must be finite and positive")
end

local function validateExactVector(actual: Vector3, expected: Vector3, name: string)
	requireCondition(actual == expected, name .. " does not match the authored value")
end

local function validateConfiguration()
	local epsilon = FrostTrailConfig.ValidationEpsilon
	requireCondition(table.isfrozen(FrostTrailConfig), "configuration must be frozen")
	requireCondition(epsilon == 1e-5, "ValidationEpsilon must equal 1e-5")
	requireCondition(FrostTrailConfig.CourseId == "FrostTrailV1", "CourseId mismatch")
	requireCondition(FrostTrailConfig.DisplayName == "FROST TRAIL", "DisplayName mismatch")
	requireCondition(FrostTrailConfig.WorldModelName == "FrostTrailWorld", "WorldModelName mismatch")
	requireCondition(FrostTrailConfig.WorldVersion == 1, "WorldVersion mismatch")
	requireCondition(FrostTrailConfig.StaticFoundationOnly == true, "static-foundation flag must be true")
	requireCondition(FrostTrailConfig.Playable == false, "playable flag must be false")
	validateExactVector(FrostTrailConfig.WorldOrigin, Vector3.new(3200, 0, 0), "WorldOrigin")
	validateExactVector(FrostTrailConfig.ForwardDirection, Vector3.zAxis, "ForwardDirection")
	requireCondition(isFiniteVector3(FrostTrailConfig.WorldOrigin), "WorldOrigin must be finite")
	requireCondition(isFiniteVector3(FrostTrailConfig.ForwardDirection), "ForwardDirection must be finite")
	requireCondition(math.abs(FrostTrailConfig.ForwardDirection.Y) <= epsilon, "ForwardDirection must be horizontal")
	requireCondition(
		approximatelyEqual(FrostTrailConfig.ForwardDirection.Magnitude, 1, epsilon),
		"ForwardDirection must be unit length"
	)
	requireCondition(isFiniteVector3(RIGHT_DIRECTION), "derived RightDirection must be finite")
	requireCondition(
		(RIGHT_DIRECTION - Vector3.new(-1, 0, 0)).Magnitude <= epsilon,
		"derived RightDirection must equal world -X"
	)

	requireCondition(FrostTrailConfig.TrackWidth == 84, "TrackWidth mismatch")
	requireCondition(FrostTrailConfig.ClearPlayableWidth == 72, "ClearPlayableWidth mismatch")
	requireCondition(FrostTrailConfig.WidenedTrackWidth == 120, "WidenedTrackWidth mismatch")
	requireCondition(FrostTrailConfig.WidenedClearPlayableWidth == 108, "WidenedClearPlayableWidth mismatch")
	requireCondition(FrostTrailConfig.TrackThickness == 3, "TrackThickness mismatch")
	requireCondition(FrostTrailConfig.TrackSegmentOverlap == 1.5, "TrackSegmentOverlap mismatch")
	requireCondition(FrostTrailConfig.SamplesPerCurve == 4, "SamplesPerCurve must equal 4")
	requireCondition(FrostTrailConfig.SamplesPerCurve % 1 == 0, "SamplesPerCurve must be an integer")
	requireCondition(FrostTrailConfig.SnowBankWidth == 10, "SnowBankWidth mismatch")
	requireCondition(FrostTrailConfig.SafetyWallThickness == 2, "SafetyWallThickness mismatch")
	requireCondition(FrostTrailConfig.SafetyWallHeight == 14, "SafetyWallHeight mismatch")
	requireCondition(FrostTrailConfig.StudsPerMeter == 1.25, "StudsPerMeter mismatch")
	requireCondition(FrostTrailConfig.MaximumRunDurationSeconds == 150, "maximum duration mismatch")
	requireCondition(FrostTrailConfig.SafetyMaximumLateralDistance == 900, "lateral safety mismatch")
	requireCondition(FrostTrailConfig.SafetyMinimumWorldY == -200, "minimum world Y mismatch")
	requireCondition(FrostTrailConfig.RampFreedomLongitudinal == 6100, "ramp freedom mismatch")
	requireCondition(FrostTrailConfig.LandingFieldDistanceMeters == 1800, "landing field distance mismatch")
	requireCondition(FrostTrailConfig.LandingMarkedDistanceMeters == 1500, "marked landing distance mismatch")
	requireCondition(FrostTrailConfig.LandingRunoffDistanceMeters == 300, "landing runoff mismatch")
	requireCondition(FrostTrailConfig.LandingWidth == 360, "landing width mismatch")
	requireCondition(FrostTrailConfig.LandingThickness == 3, "landing thickness mismatch")
	requireCondition(FrostTrailConfig.LandingTopY == 0, "landing top Y mismatch")
	requireCondition(FrostTrailConfig.LandingSegmentOverlap == 0.25, "landing overlap mismatch")
	requireCondition(FrostTrailConfig.LandingStartLongitudinal == 6350, "landing start mismatch")
	requireCondition(FrostTrailConfig.LandingEndLongitudinal == 8600, "landing end mismatch")

	validatePositiveFinite(FrostTrailConfig.TrackWidth, "TrackWidth")
	validatePositiveFinite(FrostTrailConfig.ClearPlayableWidth, "ClearPlayableWidth")
	validatePositiveFinite(FrostTrailConfig.WidenedTrackWidth, "WidenedTrackWidth")
	validatePositiveFinite(FrostTrailConfig.WidenedClearPlayableWidth, "WidenedClearPlayableWidth")
	validatePositiveFinite(FrostTrailConfig.TrackThickness, "TrackThickness")
	validatePositiveFinite(FrostTrailConfig.TrackSegmentOverlap, "TrackSegmentOverlap")
	validatePositiveFinite(FrostTrailConfig.SnowBankWidth, "SnowBankWidth")
	validatePositiveFinite(FrostTrailConfig.SafetyWallThickness, "SafetyWallThickness")
	validatePositiveFinite(FrostTrailConfig.SafetyWallHeight, "SafetyWallHeight")
	validatePositiveFinite(FrostTrailConfig.StudsPerMeter, "StudsPerMeter")
	validatePositiveFinite(FrostTrailConfig.MaximumRunDurationSeconds, "MaximumRunDurationSeconds")
	validatePositiveFinite(FrostTrailConfig.SafetyMaximumLateralDistance, "SafetyMaximumLateralDistance")
	requireCondition(isFiniteNumber(FrostTrailConfig.SafetyMinimumWorldY), "SafetyMinimumWorldY must be finite")
	validatePositiveFinite(FrostTrailConfig.RampFreedomLongitudinal, "RampFreedomLongitudinal")
	validatePositiveFinite(FrostTrailConfig.LandingFieldDistanceMeters, "LandingFieldDistanceMeters")
	validatePositiveFinite(FrostTrailConfig.LandingMarkedDistanceMeters, "LandingMarkedDistanceMeters")
	validatePositiveFinite(FrostTrailConfig.LandingRunoffDistanceMeters, "LandingRunoffDistanceMeters")
	validatePositiveFinite(FrostTrailConfig.LandingWidth, "LandingWidth")
	validatePositiveFinite(FrostTrailConfig.LandingThickness, "LandingThickness")
	requireCondition(isFiniteNumber(FrostTrailConfig.LandingTopY), "LandingTopY must be finite")
	validatePositiveFinite(FrostTrailConfig.LandingSegmentOverlap, "LandingSegmentOverlap")
	requireCondition(
		FrostTrailConfig.ClearPlayableWidth <= FrostTrailConfig.TrackWidth,
		"clear width must fit inside track width"
	)
	requireCondition(
		FrostTrailConfig.WidenedClearPlayableWidth >= FrostTrailConfig.ClearPlayableWidth
			and FrostTrailConfig.WidenedTrackWidth >= FrostTrailConfig.TrackWidth,
		"widened widths must not shrink"
	)
	requireCondition(
		FrostTrailConfig.WidenedClearPlayableWidth <= FrostTrailConfig.WidenedTrackWidth,
		"widened clear width must fit inside widened track width"
	)

	requireCondition(table.isfrozen(FrostTrailConfig.PathPoints), "PathPoints must be frozen")
	requireCondition(#FrostTrailConfig.PathPoints == 15, "PathPoints must contain exactly 15 points")
	for index, point in ipairs(FrostTrailConfig.PathPoints) do
		requireCondition(isFiniteVector3(point), string.format("PathPoints[%d] must be finite", index))
		validateExactVector(point, REQUIRED_PATH_POINTS[index], string.format("PathPoints[%d]", index))
		if index > 1 then
			requireCondition(
				point.Z > FrostTrailConfig.PathPoints[index - 1].Z,
				"PathPoints local Z must increase strictly"
			)
		end
	end
	requireCondition(FrostTrailConfig.PathPoints[1] == Vector3.new(0, 560, -250), "first path point mismatch")
	requireCondition(FrostTrailConfig.PathPoints[15] == Vector3.new(0, 82, 6350), "final path point mismatch")

	requireCondition(table.isfrozen(FrostTrailConfig.LaneCenterOffsets), "lane offsets must be frozen")
	requireCondition(#FrostTrailConfig.LaneCenterOffsets == 3, "exactly three lane offsets are required")
	requireCondition(
		FrostTrailConfig.LaneCenterOffsets[1] == -24
			and FrostTrailConfig.LaneCenterOffsets[2] == 0
			and FrostTrailConfig.LaneCenterOffsets[3] == 24,
		"lane offsets mismatch"
	)
	local laneOffsetSum = 0
	for index, offset in ipairs(FrostTrailConfig.LaneCenterOffsets) do
		requireCondition(isFiniteNumber(offset), "lane offset must be finite")
		laneOffsetSum += offset
		if index > 1 then
			requireCondition(offset > FrostTrailConfig.LaneCenterOffsets[index - 1], "lane offsets must be unique and ordered")
		end
		requireCondition(
			math.abs(offset) + FrostTrailConfig.StartSlotSize.X * 0.5 <= FrostTrailConfig.ClearPlayableWidth * 0.5,
			"lane marker footprint must fit inside the clear width"
		)
	end
	requireCondition(laneOffsetSum == 0, "lane offsets must sum to zero")

	requireCondition(table.isfrozen(FrostTrailConfig.Sections), "Sections must be frozen")
	requireCondition(#FrostTrailConfig.Sections == #REQUIRED_SECTIONS, "section count mismatch")
	for index, section in ipairs(FrostTrailConfig.Sections) do
		local required = REQUIRED_SECTIONS[index]
		requireCondition(table.isfrozen(section), string.format("section %d must be frozen", index))
		requireCondition(section.SectionId == required[1], string.format("section %d id mismatch", index))
		requireCondition(section.StartLongitudinal == required[2], string.format("section %d start mismatch", index))
		requireCondition(section.EndLongitudinal == required[3], string.format("section %d end mismatch", index))
		requireCondition(
			isFiniteNumber(section.StartLongitudinal)
				and isFiniteNumber(section.EndLongitudinal)
				and section.EndLongitudinal > section.StartLongitudinal,
			"section range must be finite and positive"
		)
		if index > 1 then
			requireCondition(
				section.StartLongitudinal == FrostTrailConfig.Sections[index - 1].EndLongitudinal,
				"section ranges must be contiguous"
			)
		end
	end
	requireCondition(FrostTrailConfig.Sections[1].StartLongitudinal == -400, "section coverage must start at -400")
	requireCondition(FrostTrailConfig.Sections[9].EndLongitudinal == 8600, "section coverage must end at 8600")

	requireCondition(table.isfrozen(FrostTrailConfig.WidenedRouteZones), "WidenedRouteZones must be frozen")
	requireCondition(#FrostTrailConfig.WidenedRouteZones == 2, "widened route zone count mismatch")
	local expectedWidened = { { 3150, 3600 }, { 4050, 4500 } }
	for index, zone in ipairs(FrostTrailConfig.WidenedRouteZones) do
		requireCondition(table.isfrozen(zone), string.format("widened zone %d must be frozen", index))
		requireCondition(
			zone.StartLongitudinal == expectedWidened[index][1]
				and zone.EndLongitudinal == expectedWidened[index][2],
			string.format("widened zone %d mismatch", index)
		)
		requireCondition(
			isFiniteNumber(zone.StartLongitudinal)
				and isFiniteNumber(zone.EndLongitudinal)
				and zone.EndLongitudinal > zone.StartLongitudinal
				and zone.StartLongitudinal >= FrostTrailConfig.Sections[1].StartLongitudinal
				and zone.EndLongitudinal < FrostTrailConfig.LandingStartLongitudinal,
			"widened route zone domain mismatch"
		)
		if index > 1 then
			requireCondition(
				zone.StartLongitudinal >= FrostTrailConfig.WidenedRouteZones[index - 1].EndLongitudinal,
				"widened route zones must be ordered and nonoverlapping"
			)
		end
	end

	requireCondition(table.isfrozen(FrostTrailConfig.TaperZones), "TaperZones must be frozen")
	requireCondition(#FrostTrailConfig.TaperZones == 4, "taper zone count mismatch")
	local expectedTapers = {
		{ 3050, 3150, true },
		{ 3600, 3700, false },
		{ 3950, 4050, true },
		{ 4500, 4600, false },
	}
	for index, zone in ipairs(FrostTrailConfig.TaperZones) do
		requireCondition(table.isfrozen(zone), string.format("taper zone %d must be frozen", index))
		requireCondition(
			zone.StartLongitudinal == expectedTapers[index][1]
				and zone.EndLongitudinal == expectedTapers[index][2]
				and zone.Widens == expectedTapers[index][3],
			string.format("taper zone %d mismatch", index)
		)
		requireCondition(
			isFiniteNumber(zone.StartLongitudinal)
				and isFiniteNumber(zone.EndLongitudinal)
				and zone.EndLongitudinal > zone.StartLongitudinal
				and zone.EndLongitudinal - zone.StartLongitudinal == 100
				and zone.StartLongitudinal >= FrostTrailConfig.Sections[1].StartLongitudinal
				and zone.EndLongitudinal < FrostTrailConfig.LandingStartLongitudinal,
			"taper zone domain mismatch"
		)
		if index > 1 then
			requireCondition(
				zone.StartLongitudinal >= FrostTrailConfig.TaperZones[index - 1].EndLongitudinal,
				"taper zones must be ordered and nonoverlapping"
			)
		end
	end
	requireCondition(
		FrostTrailConfig.TaperZones[1].EndLongitudinal == FrostTrailConfig.WidenedRouteZones[1].StartLongitudinal
			and FrostTrailConfig.WidenedRouteZones[1].EndLongitudinal
				== FrostTrailConfig.TaperZones[2].StartLongitudinal
			and FrostTrailConfig.TaperZones[3].EndLongitudinal
				== FrostTrailConfig.WidenedRouteZones[2].StartLongitudinal
			and FrostTrailConfig.WidenedRouteZones[2].EndLongitudinal
				== FrostTrailConfig.TaperZones[4].StartLongitudinal,
		"width zones and tapers must meet at exact boundaries"
	)

	validateExactVector(FrostTrailConfig.SummitPlatformCenter, Vector3.new(0, 554, -325), "SummitPlatformCenter")
	validateExactVector(FrostTrailConfig.SummitPlatformSize, Vector3.new(160, 12, 170), "SummitPlatformSize")
	validateExactVector(FrostTrailConfig.PlayerSpawnCenter, Vector3.new(0, 560.5, -355), "PlayerSpawnCenter")
	validateExactVector(FrostTrailConfig.PlayerSpawnSize, Vector3.new(12, 1, 12), "PlayerSpawnSize")
	validateExactVector(FrostTrailConfig.StartTriggerCenter, Vector3.new(0, 561, -242), "StartTriggerCenter")
	validateExactVector(FrostTrailConfig.StartTriggerSize, Vector3.new(32, 1, 18), "StartTriggerSize")
	validateExactVector(FrostTrailConfig.StartSlotBaseCenter, Vector3.new(0, 561, -260), "StartSlotBaseCenter")
	validateExactVector(FrostTrailConfig.StartSlotSize, Vector3.new(4, 1, 8), "StartSlotSize")
	validateExactVector(FrostTrailConfig.LaunchMarkerSize, Vector3.new(84, 12, 2), "LaunchMarkerSize")
	for _, size in ipairs({
		FrostTrailConfig.SummitPlatformSize,
		FrostTrailConfig.PlayerSpawnSize,
		FrostTrailConfig.StartTriggerSize,
		FrostTrailConfig.StartSlotSize,
		FrostTrailConfig.LaunchMarkerSize,
	}) do
		requireCondition(isFiniteVector3(size) and size.X > 0 and size.Y > 0 and size.Z > 0, "authored size must be positive")
	end
	requireCondition(
		FrostTrailConfig.SummitPlatformCenter.Y + FrostTrailConfig.SummitPlatformSize.Y * 0.5
			== FrostTrailConfig.PathPoints[1].Y,
		"summit top must match the first path surface"
	)
	requireCondition(
		FrostTrailConfig.PlayerSpawnCenter.Y - FrostTrailConfig.PlayerSpawnSize.Y * 0.5
			== FrostTrailConfig.SummitPlatformCenter.Y + FrostTrailConfig.SummitPlatformSize.Y * 0.5,
		"PlayerSpawn bottom must match the summit top"
	)
	requireCondition(
		FrostTrailConfig.LandingMarkedDistanceMeters + FrostTrailConfig.LandingRunoffDistanceMeters
			== FrostTrailConfig.LandingFieldDistanceMeters,
		"landing distance components must sum to the field distance"
	)
	requireCondition(
		FrostTrailConfig.LandingEndLongitudinal - FrostTrailConfig.LandingStartLongitudinal
			== FrostTrailConfig.LandingFieldDistanceMeters * FrostTrailConfig.StudsPerMeter,
		"landing longitudinal extent mismatch"
	)
end

local function localToWorldPoint(point: Vector3): Vector3
	return FrostTrailConfig.WorldOrigin
		+ RIGHT_DIRECTION * point.X
		+ Vector3.yAxis * point.Y
		+ FrostTrailConfig.ForwardDirection * point.Z
end

local function worldToLocalPoint(point: Vector3): Vector3
	local offset = point - FrostTrailConfig.WorldOrigin
	return Vector3.new(
		offset:Dot(RIGHT_DIRECTION),
		offset:Dot(Vector3.yAxis),
		offset:Dot(FrostTrailConfig.ForwardDirection)
	)
end

local function courseAlignedFrame(localPoint: Vector3): CFrame
	local worldPoint = localToWorldPoint(localPoint)
	return CFrame.lookAt(worldPoint, worldPoint + FrostTrailConfig.ForwardDirection, Vector3.yAxis)
end

local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2 = t * t
	local t3 = t2 * t
	return 0.5
		* (
			(2 * p1)
			+ ((-p0 + p2) * t)
			+ ((2 * p0 - 5 * p1 + 4 * p2 - p3) * t2)
			+ ((-p0 + 3 * p1 - 3 * p2 + p3) * t3)
		)
end

local function samplePath(): { Vector3 }
	local sampled: { Vector3 } = {}
	local controlPoints = FrostTrailConfig.PathPoints
	for index = 1, #controlPoints - 1 do
		local p0 = controlPoints[math.max(1, index - 1)]
		local p1 = controlPoints[index]
		local p2 = controlPoints[index + 1]
		local p3 = controlPoints[math.min(#controlPoints, index + 2)]
		for sampleIndex = 0, FrostTrailConfig.SamplesPerCurve - 1 do
			local alpha = sampleIndex / FrostTrailConfig.SamplesPerCurve
			table.insert(sampled, catmullRom(p0, p1, p2, p3, alpha))
		end
	end
	table.insert(sampled, controlPoints[#controlPoints])
	return sampled
end

local function validateAndMeasureSampledPath(sampled: { Vector3 }): number
	requireCondition(#sampled == EXPECTED_BASE_SAMPLES, "sampled centerline must contain exactly 57 points")
	local authoredLength = 0
	for index = 1, #sampled - 1 do
		local pointA = sampled[index]
		local pointB = sampled[index + 1]
		local chord = pointB - pointA
		requireCondition(isFiniteVector3(pointA) and isFiniteVector3(pointB), "sampled centerline must be finite")
		requireCondition(chord.Magnitude > FrostTrailConfig.ValidationEpsilon, "sampled chord must be nonzero")
		requireCondition(pointB.Z > pointA.Z, "sampled path must progress positively in local Z")
		requireCondition(
			localToWorldPoint(pointB):Dot(FrostTrailConfig.ForwardDirection)
				> localToWorldPoint(pointA):Dot(FrostTrailConfig.ForwardDirection),
			"sampled chord must progress along ForwardDirection"
		)
		authoredLength += chord.Magnitude
	end
	requireCondition(#sampled - 1 == EXPECTED_BASE_CHORDS, "sampled centerline must contain exactly 56 chords")
	requireCondition(isFiniteNumber(authoredLength), "authored path length must be finite")
	requireCondition(
		math.abs(authoredLength - EXPECTED_AUTHORED_LENGTH) <= 0.01,
		"authored path length does not match the required spline convention"
	)
	return authoredLength
end

local function smoothstep(alpha: number): number
	local clamped = math.clamp(alpha, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function widthsAt(longitudinal: number): Widths
	for _, taper in ipairs(FrostTrailConfig.TaperZones) do
		if longitudinal >= taper.StartLongitudinal and longitudinal <= taper.EndLongitudinal then
			local alpha = (longitudinal - taper.StartLongitudinal)
				/ (taper.EndLongitudinal - taper.StartLongitudinal)
			local eased = smoothstep(alpha)
			if taper.Widens then
				return {
					Track = FrostTrailConfig.TrackWidth
						+ (FrostTrailConfig.WidenedTrackWidth - FrostTrailConfig.TrackWidth) * eased,
					Clear = FrostTrailConfig.ClearPlayableWidth
						+ (FrostTrailConfig.WidenedClearPlayableWidth - FrostTrailConfig.ClearPlayableWidth) * eased,
				}
			end
			return {
				Track = FrostTrailConfig.WidenedTrackWidth
					+ (FrostTrailConfig.TrackWidth - FrostTrailConfig.WidenedTrackWidth) * eased,
				Clear = FrostTrailConfig.WidenedClearPlayableWidth
					+ (FrostTrailConfig.ClearPlayableWidth - FrostTrailConfig.WidenedClearPlayableWidth) * eased,
			}
		end
	end
	for _, zone in ipairs(FrostTrailConfig.WidenedRouteZones) do
		if longitudinal >= zone.StartLongitudinal and longitudinal <= zone.EndLongitudinal then
			return {
				Track = FrostTrailConfig.WidenedTrackWidth,
				Clear = FrostTrailConfig.WidenedClearPlayableWidth,
			}
		end
	end
	return {
		Track = FrostTrailConfig.TrackWidth,
		Clear = FrostTrailConfig.ClearPlayableWidth,
	}
end

local function splitSampledPath(sampled: { Vector3 }): { Vector3 }
	local geometryPoints: { Vector3 } = { sampled[1] }
	for index = 1, #sampled - 1 do
		local pointA = sampled[index]
		local pointB = sampled[index + 1]
		for _, splitLongitudinal in ipairs(GEOMETRY_SPLIT_LONGITUDINALS) do
			if splitLongitudinal > pointA.Z and splitLongitudinal < pointB.Z then
				local alpha = (splitLongitudinal - pointA.Z) / (pointB.Z - pointA.Z)
				table.insert(geometryPoints, pointA:Lerp(pointB, alpha))
			end
		end
		table.insert(geometryPoints, pointB)
	end
	requireCondition(#geometryPoints == EXPECTED_GEOMETRY_POINTS, "geometry split must create exactly 75 points")
	for index = 1, #geometryPoints - 1 do
		requireCondition(
			geometryPoints[index + 1].Z > geometryPoints[index].Z,
			"split geometry path must progress positively"
		)
	end
	for _, requiredLongitudinal in ipairs(GEOMETRY_SPLIT_LONGITUDINALS) do
		local found = false
		for _, point in ipairs(geometryPoints) do
			if approximatelyEqual(point.Z, requiredLongitudinal, FrostTrailConfig.ValidationEpsilon) then
				found = true
				break
			end
		end
		requireCondition(found, string.format("missing required geometry split at %.0f", requiredLongitudinal))
	end
	for _, taper in ipairs(FrostTrailConfig.TaperZones) do
		for index = 1, #geometryPoints - 1 do
			local overlapStart = math.max(geometryPoints[index].Z, taper.StartLongitudinal)
			local overlapEnd = math.min(geometryPoints[index + 1].Z, taper.EndLongitudinal)
			if overlapEnd > overlapStart then
				requireCondition(
					overlapEnd - overlapStart <= 25 + FrostTrailConfig.ValidationEpsilon,
					"taper geometry must be subdivided at no more than 25-stud intervals"
				)
			end
		end
	end
	return geometryPoints
end

local function angleBetween(directionA: Vector3, directionB: Vector3): number
	return math.acos(math.clamp(directionA:Dot(directionB), -1, 1))
end

local function requiredJoinExtension(width: number, turnAngle: number): number
	return math.max(
		FrostTrailConfig.TrackSegmentOverlap * 0.5,
		width * 0.5 * math.tan(turnAngle * 0.5) + FrostTrailConfig.ValidationEpsilon
	)
end

local function createSegmentPlans(geometryPoints: { Vector3 }): { SegmentPlan }
	local plans: { SegmentPlan } = {}
	for index = 1, #geometryPoints - 1 do
		local pointA = geometryPoints[index]
		local pointB = geometryPoints[index + 1]
		local chord = pointB - pointA
		local startWidths = widthsAt(pointA.Z)
		local endWidths = widthsAt(pointB.Z)
		local trackWidth = math.max(startWidths.Track, endWidths.Track)
		local clearWidth = math.max(startWidths.Clear, endWidths.Clear)
		requireCondition(chord.Magnitude > FrostTrailConfig.ValidationEpsilon, "geometry chord must be nonzero")
		requireCondition(chord.Z > 0, "geometry chord must not reverse forward progress")
		requireCondition(trackWidth >= clearWidth, "geometry piece must cover the clear width")
		table.insert(plans, {
			PointA = pointA,
			PointB = pointB,
			Direction = chord.Unit,
			Length = chord.Magnitude,
			TrackWidth = trackWidth,
			ClearWidth = clearWidth,
			StartExtension = FrostTrailConfig.TrackSegmentOverlap * 0.5,
			EndExtension = FrostTrailConfig.TrackSegmentOverlap * 0.5,
		})
	end
	requireCondition(#plans == EXPECTED_GEOMETRY_SEGMENTS, "geometry must contain exactly 74 segments")

	for index, plan in ipairs(plans) do
		if index > 1 then
			local previous = plans[index - 1]
			local turnAngle = angleBetween(previous.Direction, plan.Direction)
			local activeWidth = math.max(previous.TrackWidth, plan.TrackWidth)
			plan.StartExtension = requiredJoinExtension(activeWidth, turnAngle)
		end
		if index < #plans then
			local following = plans[index + 1]
			local turnAngle = angleBetween(plan.Direction, following.Direction)
			local activeWidth = math.max(plan.TrackWidth, following.TrackWidth)
			plan.EndExtension = requiredJoinExtension(activeWidth, turnAngle)
		end
	end

	for index = 1, #plans - 1 do
		local first = plans[index]
		local second = plans[index + 1]
		local turnAngle = angleBetween(first.Direction, second.Direction)
		local required = math.max(first.TrackWidth, second.TrackWidth) * 0.5 * math.tan(turnAngle * 0.5)
			+ FrostTrailConfig.ValidationEpsilon
		requireCondition(first.EndExtension >= required, "outgoing join coverage is insufficient")
		requireCondition(second.StartExtension >= required, "incoming join coverage is insufficient")
		requireCondition(
			first.TrackWidth >= math.max(widthsAt(first.PointA.Z).Track, widthsAt(first.PointB.Z).Track),
			"track piece under-covers its endpoint width"
		)
		requireCondition(
			first.ClearWidth >= math.max(widthsAt(first.PointA.Z).Clear, widthsAt(first.PointB.Z).Clear),
			"clear-width coverage is discontinuous"
		)
	end
	return plans
end

local function segmentFrame(pointA: Vector3, pointB: Vector3, startExtension: number, endExtension: number): (CFrame, number)
	local direction = pointB - pointA
	requireCondition(direction.Magnitude > FrostTrailConfig.ValidationEpsilon, "cannot frame a zero-length segment")
	local unitDirection = direction.Unit
	local extendedA = pointA - unitDirection * startExtension
	local extendedB = pointB + unitDirection * endExtension
	local worldA = localToWorldPoint(extendedA)
	local worldB = localToWorldPoint(extendedB)
	local worldDirection = worldB - worldA
	local midpoint = (worldA + worldB) * 0.5
	return CFrame.lookAt(midpoint, midpoint + worldDirection.Unit, Vector3.yAxis), worldDirection.Magnitude
end

local function createFolder(parent: Instance, name: string): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function configureBasePart(
	part: BasePart,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	canCollide: boolean,
	canQuery: boolean,
	castShadow: boolean,
	transparency: number
)
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = canCollide
	part.CanTouch = false
	part.CanQuery = canQuery
	part.CastShadow = castShadow
	part.Transparency = transparency
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function createPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	canCollide: boolean,
	canQuery: boolean,
	castShadow: boolean,
	transparency: number
): Part
	local part = Instance.new("Part")
	configureBasePart(part, name, size, cframe, color, material, canCollide, canQuery, castShadow, transparency)
	part.Parent = parent
	return part
end

local function createDecorPart(
	parent: Instance,
	name: string,
	localPosition: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	castShadow: boolean,
	yawDegrees: number
): Part
	local cframe = courseAlignedFrame(localPosition) * CFrame.Angles(0, math.rad(yawDegrees), 0)
	return createPart(parent, name, size, cframe, color, material, false, false, castShadow, 0)
end

local function createDecorWedge(
	parent: Instance,
	name: string,
	localPosition: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	castShadow: boolean,
	yawDegrees: number
): WedgePart
	local wedge = Instance.new("WedgePart")
	local cframe = courseAlignedFrame(localPosition) * CFrame.Angles(0, math.rad(yawDegrees), 0)
	configureBasePart(wedge, name, size, cframe, color, material, false, false, castShadow, 0)
	wedge.Parent = parent
	return wedge
end

local function trackPhysicalProperties(): PhysicalProperties
	return PhysicalProperties.new(
		PHYSICS.TrackDensity,
		PHYSICS.TrackFriction,
		PHYSICS.TrackElasticity,
		PHYSICS.TrackFrictionWeight,
		PHYSICS.TrackElasticityWeight
	)
end

local function lakePhysicalProperties(): PhysicalProperties
	return PhysicalProperties.new(
		PHYSICS.FrozenLakeDensity,
		PHYSICS.FrozenLakeFriction,
		PHYSICS.FrozenLakeElasticity,
		PHYSICS.FrozenLakeFrictionWeight,
		PHYSICS.FrozenLakeElasticityWeight
	)
end

local function buildTrack(track: Folder, safety: Folder, plans: { SegmentPlan })
	for index, plan in ipairs(plans) do
		local frame, extendedLength = segmentFrame(
			plan.PointA,
			plan.PointB,
			plan.StartExtension,
			plan.EndExtension
		)
		local shoulder = createPart(
			track,
			string.format("SnowShoulders_%03d", index),
			Vector3.new(plan.TrackWidth + FrostTrailConfig.SnowBankWidth * 2, SHOULDER_THICKNESS, extendedLength),
			frame * CFrame.new(0, -(SHOULDER_THICKNESS * 0.5 + SHOULDER_SURFACE_GAP), 0),
			PALETTE.Snow,
			Enum.Material.Snow,
			false,
			false,
			false,
			0
		)
		shoulder:SetAttribute("FrostTrailSnowShoulders", true)

		local surface = createPart(
			track,
			string.format("TrackSurface_%03d", index),
			Vector3.new(plan.TrackWidth, FrostTrailConfig.TrackThickness, extendedLength),
			frame * CFrame.new(0, -FrostTrailConfig.TrackThickness * 0.5, 0),
			PALETTE.Ice,
			Enum.Material.Ice,
			true,
			true,
			false,
			0
		)
		surface.CustomPhysicalProperties = trackPhysicalProperties()
		surface.Reflectance = 0.06
		surface:SetAttribute(TRACK_SURFACE_ATTRIBUTE, true)

		for _, side in ipairs({ -1, 1 }) do
			local startTrackWidth = widthsAt(plan.PointA.Z).Track
			local endTrackWidth = widthsAt(plan.PointB.Z).Track
			local startOffset = side
				* (startTrackWidth * 0.5 + FrostTrailConfig.SnowBankWidth + FrostTrailConfig.SafetyWallThickness * 0.5)
			local endOffset = side
				* (endTrackWidth * 0.5 + FrostTrailConfig.SnowBankWidth + FrostTrailConfig.SafetyWallThickness * 0.5)
			local wallPointA = plan.PointA + Vector3.new(startOffset, 0, 0)
			local wallPointB = plan.PointB + Vector3.new(endOffset, 0, 0)
			local wallFrame, wallLength = segmentFrame(
				wallPointA,
				wallPointB,
				plan.StartExtension,
				plan.EndExtension
			)
			local sideName = if side < 0 then "Left" else "Right"
			local wall = createPart(
				safety,
				string.format("%sWall_%03d", sideName, index),
				Vector3.new(FrostTrailConfig.SafetyWallThickness, FrostTrailConfig.SafetyWallHeight, wallLength),
				wallFrame * CFrame.new(0, FrostTrailConfig.SafetyWallHeight * 0.5, 0),
				PALETTE.IceDeep,
				Enum.Material.SmoothPlastic,
				true,
				true,
				false,
				1
			)
			wall:SetAttribute("FrostTrailSafetyBoundary", true)
		end
	end
end

local function pathPointAtLongitudinal(sampled: { Vector3 }, longitudinal: number): Vector3
	for index = 1, #sampled - 1 do
		local pointA = sampled[index]
		local pointB = sampled[index + 1]
		if longitudinal >= pointA.Z and longitudinal <= pointB.Z then
			local alpha = (longitudinal - pointA.Z) / (pointB.Z - pointA.Z)
			return pointA:Lerp(pointB, alpha)
		end
	end
	fail(string.format("cannot interpolate centerline at %.3f", longitudinal))
end

local function sceneryPosition(sampled: { Vector3 }, longitudinal: number, lateral: number, height: number): Vector3
	return pathPointAtLongitudinal(sampled, longitudinal) + Vector3.new(lateral, height, 0)
end

local function createInvisibleMarker(parent: Instance, name: string, size: Vector3, localPosition: Vector3): Part
	return createPart(
		parent,
		name,
		size,
		courseAlignedFrame(localPosition),
		PALETTE.Ice,
		Enum.Material.SmoothPlastic,
		false,
		false,
		false,
		1
	)
end

local function buildSummit(geometry: Folder, safety: Folder)
	local summitPlatform = createPart(
		geometry,
		"SummitPlatform",
		FrostTrailConfig.SummitPlatformSize,
		courseAlignedFrame(FrostTrailConfig.SummitPlatformCenter),
		PALETTE.Snow,
		Enum.Material.Snow,
		true,
		true,
		true,
		0
	)
	summitPlatform.CustomPhysicalProperties = trackPhysicalProperties()

	local spawnWorldPosition = localToWorldPoint(FrostTrailConfig.PlayerSpawnCenter)
	local firstPathWorldPosition = localToWorldPoint(FrostTrailConfig.PathPoints[1])
	local horizontalTarget = Vector3.new(firstPathWorldPosition.X, spawnWorldPosition.Y, firstPathWorldPosition.Z)
	requireCondition(
		(horizontalTarget - spawnWorldPosition).Magnitude > FrostTrailConfig.ValidationEpsilon,
		"PlayerSpawn must have a horizontal ramp-facing direction"
	)
	local spawn = Instance.new("SpawnLocation")
	configureBasePart(
		spawn,
		"PlayerSpawn",
		FrostTrailConfig.PlayerSpawnSize,
		CFrame.lookAt(spawnWorldPosition, horizontalTarget, Vector3.yAxis),
		PALETTE.Snow,
		Enum.Material.Snow,
		true,
		true,
		false,
		1
	)
	spawn.Enabled = false
	spawn.Neutral = false
	spawn.CustomPhysicalProperties = trackPhysicalProperties()
	spawn.Parent = geometry

	local summitTopY = FrostTrailConfig.SummitPlatformCenter.Y + FrostTrailConfig.SummitPlatformSize.Y * 0.5
	local wallCenterY = summitTopY + FrostTrailConfig.SafetyWallHeight * 0.5
	local sideOffset = FrostTrailConfig.SummitPlatformSize.X * 0.5
		- SUMMIT_WALL_OVERLAP
		+ FrostTrailConfig.SafetyWallThickness * 0.5
	local sideWallSize = Vector3.new(
		FrostTrailConfig.SafetyWallThickness,
		FrostTrailConfig.SafetyWallHeight,
		FrostTrailConfig.SummitPlatformSize.Z
	)
	for _, side in ipairs({ -1, 1 }) do
		local sideName = if side < 0 then "SummitLeftWall" else "SummitRightWall"
		local wall = createPart(
			safety,
			sideName,
			sideWallSize,
			courseAlignedFrame(Vector3.new(
				FrostTrailConfig.SummitPlatformCenter.X + side * sideOffset,
				wallCenterY,
				FrostTrailConfig.SummitPlatformCenter.Z
			)),
			PALETTE.IceDeep,
			Enum.Material.SmoothPlastic,
			true,
			true,
			false,
			1
		)
		wall:SetAttribute("FrostTrailSafetyBoundary", true)
	end

	local rearWallSize = Vector3.new(
		FrostTrailConfig.SummitPlatformSize.X + FrostTrailConfig.SafetyWallThickness * 2,
		FrostTrailConfig.SafetyWallHeight,
		FrostTrailConfig.SafetyWallThickness
	)
	local rearLongitudinal = FrostTrailConfig.SummitPlatformCenter.Z
		- FrostTrailConfig.SummitPlatformSize.Z * 0.5
		+ FrostTrailConfig.SafetyWallThickness * 0.5
		- SUMMIT_WALL_OVERLAP
	local rearWall = createPart(
		safety,
		"SummitRearWall",
		rearWallSize,
		courseAlignedFrame(Vector3.new(FrostTrailConfig.SummitPlatformCenter.X, wallCenterY, rearLongitudinal)),
		PALETTE.IceDeep,
		Enum.Material.SmoothPlastic,
		true,
		true,
		false,
		1
	)
	rearWall:SetAttribute("FrostTrailSafetyBoundary", true)
end

local function buildMarkers(markers: Folder, sampled: { Vector3 })
	local startTrigger = createInvisibleMarker(
		markers,
		"StartTrigger",
		FrostTrailConfig.StartTriggerSize,
		FrostTrailConfig.StartTriggerCenter
	)
	startTrigger:SetAttribute("AuthoringMarkerOnly", true)

	local launchPosition = FrostTrailConfig.PathPoints[#FrostTrailConfig.PathPoints] + Vector3.new(0, 1, 0)
	local launchEdge = createInvisibleMarker(markers, "LaunchEdge", FrostTrailConfig.LaunchMarkerSize, launchPosition)
	launchEdge:SetAttribute("AuthoringMarkerOnly", true)

	local startSlots = createFolder(markers, "StartSlots")
	for index, offset in ipairs(START_SLOT_OFFSETS) do
		local baseWorld = localToWorldPoint(FrostTrailConfig.StartSlotBaseCenter)
		local center = baseWorld + RIGHT_DIRECTION * offset
		local slot = createPart(
			startSlots,
			string.format("Slot_%02d", index),
			FrostTrailConfig.StartSlotSize,
			CFrame.lookAt(center, center + FrostTrailConfig.ForwardDirection, Vector3.yAxis),
			PALETTE.Ice,
			Enum.Material.SmoothPlastic,
			false,
			false,
			false,
			1
		)
		slot:SetAttribute("LayoutMarkerOnly", true)
	end

	local sectionAnchors = createFolder(markers, "SectionAnchors")
	for index, section in ipairs(FrostTrailConfig.Sections) do
		local localPosition: Vector3
		if section.SectionId == "LandingLake" then
			localPosition = Vector3.new(0, FrostTrailConfig.LandingTopY, 7475)
		else
			localPosition = pathPointAtLongitudinal(
				sampled,
				(section.StartLongitudinal + section.EndLongitudinal) * 0.5
			)
		end
		local anchor = createInvisibleMarker(sectionAnchors, section.SectionId, Vector3.new(2, 2, 2), localPosition)
		anchor:SetAttribute("SectionId", section.SectionId)
		anchor:SetAttribute("StartLongitudinal", section.StartLongitudinal)
		anchor:SetAttribute("EndLongitudinal", section.EndLongitudinal)
		anchor:SetAttribute("Order", index)
	end
end

local function buildLandingLake(geometry: Folder): Folder
	local lake = createFolder(geometry, "FrostTrailLake")
	local halfOverlap = FrostTrailConfig.LandingSegmentOverlap * 0.5
	local markedEnd = FrostTrailConfig.LandingStartLongitudinal
		+ FrostTrailConfig.LandingMarkedDistanceMeters * FrostTrailConfig.StudsPerMeter
	local markedStart = FrostTrailConfig.LandingStartLongitudinal
	local markedExtendedEnd = markedEnd + halfOverlap
	local runoffStart = markedEnd - halfOverlap
	local runoffEnd = FrostTrailConfig.LandingEndLongitudinal

	local function createLakePart(name: string, startLongitudinal: number, endLongitudinal: number): Part
		local length = endLongitudinal - startLongitudinal
		local center = Vector3.new(
			0,
			FrostTrailConfig.LandingTopY - FrostTrailConfig.LandingThickness * 0.5,
			(startLongitudinal + endLongitudinal) * 0.5
		)
		local part = createPart(
			lake,
			name,
			Vector3.new(FrostTrailConfig.LandingWidth, FrostTrailConfig.LandingThickness, length),
			courseAlignedFrame(center),
			PALETTE.Ice,
			Enum.Material.Ice,
			true,
			true,
			false,
			0
		)
		part.CustomPhysicalProperties = lakePhysicalProperties()
		part.Reflectance = 0.08
		return part
	end

	local marked = createLakePart("FrostTrailLakeMarked_0000m_1500m", markedStart, markedExtendedEnd)
	local runoff = createLakePart("FrostTrailLakeRunoff_1500m_1800m", runoffStart, runoffEnd)
	requireCondition(approximatelyEqual(marked.Size.Z, 1875.125, FrostTrailConfig.ValidationEpsilon), "marked lake length mismatch")
	requireCondition(approximatelyEqual(runoff.Size.Z, 375.125, FrostTrailConfig.ValidationEpsilon), "runoff lake length mismatch")
	requireCondition(
		approximatelyEqual(marked.Size.Z + runoff.Size.Z, 2250.25, FrostTrailConfig.ValidationEpsilon),
		"landing segment summed lengths mismatch"
	)
	requireCondition(
		approximatelyEqual(markedExtendedEnd - runoffStart, 0.25, FrostTrailConfig.ValidationEpsilon),
		"landing segment intersection mismatch"
	)
	requireCondition(
		approximatelyEqual(runoffEnd - markedStart, 2250, FrostTrailConfig.ValidationEpsilon),
		"landing union length mismatch"
	)
	return lake
end

local function createTwoPartFlag(
	parent: Instance,
	name: string,
	basePosition: Vector3,
	color: Color3,
	castShadow: boolean
)
	createDecorPart(
		parent,
		name .. "_Pole",
		basePosition + Vector3.new(0, 6, 0),
		Vector3.new(0.8, 12, 0.8),
		PALETTE.Wood,
		Enum.Material.Wood,
		castShadow,
		0
	)
	createDecorWedge(
		parent,
		name .. "_Pennant",
		basePosition + Vector3.new(2.2, 10, 0),
		Vector3.new(4.4, 3.5, 0.6),
		color,
		Enum.Material.SmoothPlastic,
		castShadow,
		0
	)
end

local function createTwoPartPine(
	parent: Instance,
	name: string,
	basePosition: Vector3,
	scale: number,
	color: Color3,
	castShadow: boolean
)
	createDecorPart(
		parent,
		name .. "_Trunk",
		basePosition + Vector3.new(0, 4 * scale, 0),
		Vector3.new(2.2, 8, 2.2) * scale,
		PALETTE.Wood,
		Enum.Material.Wood,
		castShadow,
		0
	)
	createDecorWedge(
		parent,
		name .. "_Canopy",
		basePosition + Vector3.new(0, 14 * scale, 0),
		Vector3.new(15, 20, 6) * scale,
		color,
		Enum.Material.SmoothPlastic,
		castShadow,
		if basePosition.X < 0 then -90 else 90
	)
end

local function createTwoPartCrystal(
	parent: Instance,
	name: string,
	basePosition: Vector3,
	scale: number,
	primaryColor: Color3,
	castShadow: boolean
)
	createDecorWedge(
		parent,
		name .. "_Tall",
		basePosition + Vector3.new(-3 * scale, 7 * scale, 0),
		Vector3.new(6, 14, 6) * scale,
		primaryColor,
		Enum.Material.Glass,
		castShadow,
		15
	)
	createDecorWedge(
		parent,
		name .. "_Short",
		basePosition + Vector3.new(4 * scale, 4.5 * scale, 2 * scale),
		Vector3.new(5, 9, 5) * scale,
		PALETTE.Ice,
		Enum.Material.Glass,
		castShadow,
		-20
	)
end

local function buildSummitCampDecor(parent: Folder)
	local archCenter = Vector3.new(0, 560, -230)
	for _, side in ipairs({ -1, 1 }) do
		for stripe = 1, 3 do
			createDecorPart(
				parent,
				string.format("StartArch_%sStripe_%02d", if side < 0 then "Left" else "Right", stripe),
				archCenter + Vector3.new(side * 25, 3 + (stripe - 1) * 6, 0),
				Vector3.new(3.2, 6, 3.2),
				if stripe % 2 == 1 then PALETTE.Red else PALETTE.White,
				Enum.Material.SmoothPlastic,
				true,
				0
			)
		end
	end
	for stripe = 1, 3 do
		createDecorPart(
			parent,
			string.format("StartArch_TopStripe_%02d", stripe),
			archCenter + Vector3.new(-18 + (stripe - 1) * 18, 20, 0),
			Vector3.new(18, 3.2, 3.2),
			if stripe % 2 == 1 then PALETTE.Red else PALETTE.White,
			Enum.Material.SmoothPlastic,
			true,
			0
		)
	end
	createDecorPart(
		parent,
		"StartArch_SnowCap",
		archCenter + Vector3.new(0, 22, 0),
		Vector3.new(58, 1.5, 4.6),
		PALETTE.Snow,
		Enum.Material.Snow,
		true,
		0
	)

	createTwoPartFlag(parent, "SummitFlag_Red", Vector3.new(-55, 560, -350), PALETTE.Red, true)
	createTwoPartFlag(parent, "SummitFlag_White", Vector3.new(55, 560, -350), PALETTE.White, true)
	createDecorPart(
		parent,
		"SupplyCrate_01",
		Vector3.new(67, 564, -315),
		Vector3.new(9, 8, 9),
		PALETTE.Wood,
		Enum.Material.WoodPlanks,
		true,
		15
	)
	createDecorPart(
		parent,
		"SupplyCrate_02",
		Vector3.new(-67, 563.5, -315),
		Vector3.new(8, 7, 8),
		PALETTE.Wood,
		Enum.Material.WoodPlanks,
		true,
		-15
	)
	createDecorWedge(
		parent,
		"NearbyAlpinePeak_Left",
		Vector3.new(-235, 610, -270),
		Vector3.new(150, 100, 120),
		PALETTE.Snow,
		Enum.Material.Snow,
		false,
		90
	)
	createDecorWedge(
		parent,
		"NearbyAlpinePeak_Right",
		Vector3.new(235, 605, -190),
		Vector3.new(145, 90, 120),
		PALETTE.Snow,
		Enum.Material.Snow,
		false,
		-90
	)
end

local function buildPineSlalomDecor(parent: Folder, sampled: { Vector3 })
	for index = 1, 6 do
		local side = if index % 2 == 0 then -1 else 1
		local longitudinal = 590 + (index - 1) * 145
		local base = sceneryPosition(sampled, longitudinal, side * (108 + (index % 3) * 18), 0)
		createTwoPartPine(
			parent,
			string.format("Pine_%02d", index),
			base,
			0.9 + (index % 2) * 0.12,
			if index % 2 == 0 then PALETTE.PineDark else PALETTE.PineLight,
			false
		)
	end
	createTwoPartFlag(parent, "TrailFlag_Red", sceneryPosition(sampled, 760, -88, 0), PALETTE.Red, true)
	createTwoPartFlag(parent, "TrailFlag_White", sceneryPosition(sampled, 1210, 88, 0), PALETTE.White, true)
	local cabinBase = sceneryPosition(sampled, 1030, 165, 0)
	createDecorPart(
		parent,
		"LookoutCabin_Body",
		cabinBase + Vector3.new(0, 6, 0),
		Vector3.new(22, 12, 18),
		PALETTE.Wood,
		Enum.Material.WoodPlanks,
		true,
		8
	)
	createDecorWedge(
		parent,
		"LookoutCabin_Roof",
		cabinBase + Vector3.new(0, 14, 0),
		Vector3.new(26, 8, 22),
		PALETTE.Snow,
		Enum.Material.Snow,
		true,
		98
	)
	local secondCabinBase = sceneryPosition(sampled, 1320, -165, 0)
	createDecorPart(
		parent,
		"TrailCabin_Body",
		secondCabinBase + Vector3.new(0, 5, 0),
		Vector3.new(18, 10, 16),
		PALETTE.Wood,
		Enum.Material.WoodPlanks,
		true,
		-8
	)
	createDecorWedge(
		parent,
		"TrailCabin_Roof",
		secondCabinBase + Vector3.new(0, 12, 0),
		Vector3.new(22, 7, 20),
		PALETTE.Snow,
		Enum.Material.Snow,
		true,
		82
	)
end

local function buildCrystalCaveDecor(parent: Folder, sampled: { Vector3 })
	local paleCyan = Color3.fromRGB(196, 244, 255)
	local violet = Color3.fromRGB(154, 129, 226)
	for archIndex = 1, 2 do
		local side = if archIndex == 1 then -1 else 1
		local longitudinal = if archIndex == 1 then 1575 else 2075
		local center = sceneryPosition(sampled, longitudinal, side * 132, 0)
		for rib = 1, 3 do
			createDecorWedge(
				parent,
				string.format("CrystalArch_%02d_Rib_%02d", archIndex, rib),
				center + Vector3.new(side * (rib - 2) * 11, 13 + rib * 6, (rib - 2) * 9),
				Vector3.new(11, 28 + rib * 6, 12),
				if rib == 2 then violet else PALETTE.IceDeep,
				Enum.Material.Glass,
				true,
				side * (72 + rib * 5)
			)
		end
	end
	for cluster = 1, 4 do
		local side = if cluster % 2 == 0 then -1 else 1
		local longitudinal = 1475 + cluster * 145
		local base = sceneryPosition(sampled, longitudinal, side * (122 + (cluster % 2) * 18), 0)
		createTwoPartCrystal(
			parent,
			string.format("CrystalCluster_%02d", cluster),
			base,
			1 + cluster * 0.08,
			if cluster % 2 == 0 then violet else paleCyan,
			true
		)
	end
end

local function buildGlacierBridgeDecor(parent: Folder, sampled: { Vector3 })
	for _, side in ipairs({ -1, 1 }) do
		createDecorPart(
			parent,
			if side < 0 then "BridgeEdge_Left" else "BridgeEdge_Right",
			sceneryPosition(sampled, 2625, side * 62, 2),
			Vector3.new(5, 4, 500),
			PALETTE.IceDeep,
			Enum.Material.Glass,
			true,
			0
		)
		createDecorPart(
			parent,
			if side < 0 then "Crevasse_Left" else "Crevasse_Right",
			sceneryPosition(sampled, 2660, side * 175, -26),
			Vector3.new(120, 12, 540),
			Color3.fromRGB(20, 58, 92),
			Enum.Material.Glass,
			false,
			0
		)
	end
	local waterfallBase = sceneryPosition(sampled, 2810, 205, -8)
	for index = 1, 6 do
		createDecorPart(
			parent,
			string.format("FrozenWaterfall_%02d", index),
			waterfallBase + Vector3.new((index - 3.5) * 8, 18 + (index % 2) * 8, (index % 3) * 5),
			Vector3.new(7, 58 + (index % 2) * 15, 9),
			if index % 2 == 0 then PALETTE.Ice else Color3.fromRGB(198, 244, 255),
			Enum.Material.Glass,
			true,
			0
		)
	end
end

local function buildAvalanchePassDecor(parent: Folder, sampled: { Vector3 })
	for index = 1, 4 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("AvalanchePeak_%02d", index),
			sceneryPosition(sampled, 3070 + index * 165, side * (210 + index * 18), 45),
			Vector3.new(115, 105 + index * 8, 125),
			PALETTE.Snow,
			Enum.Material.Snow,
			false,
			side * 90
		)
	end
	for index = 1, 4 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("VisualDebris_%02d", index),
			sceneryPosition(sampled, 3120 + index * 155, side * (96 + (index % 2) * 22), 4),
			Vector3.new(18 + index * 3, 11 + index, 16),
			PALETTE.Snow,
			Enum.Material.Snow,
			true,
			side * 35
		)
	end
	for index = 1, 4 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorPart(
			parent,
			string.format("WarningPole_%02d", index),
			sceneryPosition(sampled, 3030 + index * 185, side * 82, 8),
			Vector3.new(1.6, 16, 1.6),
			if index % 2 == 0 then PALETTE.Red else PALETTE.White,
			Enum.Material.Neon,
			true,
			0
		)
	end
end

local function buildFrozenVillageDecor(parent: Folder, sampled: { Vector3 })
	for cabin = 1, 3 do
		local side = if cabin % 2 == 0 then -1 else 1
		local base = sceneryPosition(sampled, 3900 + cabin * 185, side * (132 + cabin * 9), 0)
		createDecorPart(
			parent,
			string.format("VillageCabin_%02d_Body", cabin),
			base + Vector3.new(0, 7, 0),
			Vector3.new(24, 14, 21),
			PALETTE.Wood,
			Enum.Material.WoodPlanks,
			true,
			side * 10
		)
		createDecorWedge(
			parent,
			string.format("VillageCabin_%02d_Roof", cabin),
			base + Vector3.new(0, 17, 0),
			Vector3.new(30, 9, 27),
			PALETTE.Red,
			Enum.Material.SmoothPlastic,
			not (cabin == 1),
			90 + side * 10
		)
		createDecorPart(
			parent,
			string.format("VillageCabin_%02d_Snow", cabin),
			base + Vector3.new(0, 21, 0),
			Vector3.new(28, 2, 25),
			PALETTE.Snow,
			Enum.Material.Snow,
			true,
			side * 10
		)
	end
	for lamp = 1, 4 do
		local side = if lamp % 2 == 0 then -1 else 1
		createDecorPart(
			parent,
			string.format("EmissiveLamp_%02d", lamp),
			sceneryPosition(sampled, 3870 + lamp * 190, side * 92, 8),
			Vector3.new(2.2, 12, 2.2),
			PALETTE.Gold,
			Enum.Material.Neon,
			false,
			0
		)
	end
	for fence = 1, 3 do
		local side = if fence % 2 == 0 then -1 else 1
		createDecorPart(
			parent,
			string.format("VillageFence_%02d", fence),
			sceneryPosition(sampled, 3940 + fence * 220, side * 108, 3),
			Vector3.new(34, 5, 1.5),
			PALETTE.Wood,
			Enum.Material.WoodPlanks,
			true,
			side * 12
		)
	end
	for banner = 1, 2 do
		local side = if banner == 1 then -1 else 1
		createDecorPart(
			parent,
			string.format("VillageBanner_%02d", banner),
			sceneryPosition(sampled, 4140 + banner * 240, side * 86, 11),
			Vector3.new(8, 7, 0.8),
			if banner == 1 then PALETTE.Red else PALETTE.White,
			Enum.Material.SmoothPlastic,
			true,
			0
		)
	end
end

local function buildFrozenRiverDecor(parent: Folder, sampled: { Vector3 })
	for index = 1, 4 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorPart(
			parent,
			string.format("ShorelineRhythm_%02d", index),
			sceneryPosition(sampled, 4740 + index * 165, side * 118, 3),
			Vector3.new(34, 7, 85),
			PALETTE.Snow,
			Enum.Material.Snow,
			false,
			side * 8
		)
	end
	for index = 1, 3 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("RiverCrystal_%02d", index),
			sceneryPosition(sampled, 4820 + index * 210, side * 145, 9),
			Vector3.new(10, 22, 10),
			if index == 2 then Color3.fromRGB(154, 129, 226) else PALETTE.IceDeep,
			Enum.Material.Glass,
			false,
			side * 25
		)
	end
	for index = 1, 2 do
		local side = if index == 1 then -1 else 1
		createDecorWedge(
			parent,
			string.format("RiverFlag_%02d", index),
			sceneryPosition(sampled, 4930 + index * 310, side * 90, 9),
			Vector3.new(7, 7, 0.8),
			if index == 1 then PALETTE.Red else PALETTE.White,
			Enum.Material.SmoothPlastic,
			false,
			0
		)
	end
	for index = 1, 3 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("RiverDistantPeak_%02d", index),
			sceneryPosition(sampled, 4760 + index * 245, side * (285 + index * 20), 54),
			Vector3.new(125, 112, 130),
			PALETTE.Snow,
			Enum.Material.Snow,
			false,
			side * 90
		)
	end
end

local function buildAlpineChuteDecor(parent: Folder, sampled: { Vector3 })
	for index = 1, 4 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("ChuteMountainWall_%02d", index),
			sceneryPosition(sampled, 5570 + index * 145, side * (170 + index * 18), 42),
			Vector3.new(100, 105, 160),
			if index % 2 == 0 then PALETTE.IceDeep else PALETTE.Snow,
			Enum.Material.Snow,
			false,
			side * 90
		)
	end
	for index = 1, 4 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorPart(
			parent,
			string.format("ChuteDirectionAccent_%02d", index),
			sceneryPosition(sampled, 5650 + index * 135, side * 78, 9),
			Vector3.new(2, 18, 2),
			if index % 2 == 0 then PALETTE.Red else PALETTE.White,
			Enum.Material.Neon,
			false,
			0
		)
	end
	for index = 1, 3 do
		local side = if index == 2 then -1 else 1
		createDecorWedge(
			parent,
			string.format("LaunchMouthFrame_%02d", index),
			sceneryPosition(sampled, 6170 + index * 45, side * (92 + index * 18), 18 + index * 4),
			Vector3.new(18, 38 + index * 4, 18),
			if index == 2 then PALETTE.White else PALETTE.Red,
			Enum.Material.SmoothPlastic,
			false,
			side * 70
		)
	end
end

local function buildLandingLakeDecor(parent: Folder)
	local shorelineCenterA = (FrostTrailConfig.LandingStartLongitudinal + 7475) * 0.5
	local shorelineCenterB = (7475 + FrostTrailConfig.LandingEndLongitudinal) * 0.5
	for _, side in ipairs({ -1, 1 }) do
		for half = 1, 2 do
			local longitudinal = if half == 1 then shorelineCenterA else shorelineCenterB
			createDecorPart(
				parent,
				string.format("LakeShore_%s_%02d", if side < 0 then "Left" else "Right", half),
				Vector3.new(side * 198, 2, longitudinal),
				Vector3.new(36, 7, 1125),
				PALETTE.Snow,
				Enum.Material.Snow,
				false,
				0
			)
		end
	end
	for index = 1, 2 do
		local side = if index == 1 then -1 else 1
		createTwoPartPine(
			parent,
			string.format("LakePine_%02d", index),
			Vector3.new(side * 245, 0, 6810 + index * 610),
			1.25,
			if index == 1 then PALETTE.PineDark else PALETTE.PineLight,
			false
		)
	end
	for index = 1, 3 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("LakeCrystal_%02d", index),
			Vector3.new(side * (225 + index * 12), 10, 6600 + index * 510),
			Vector3.new(11, 24, 11),
			if index == 2 then Color3.fromRGB(154, 129, 226) else PALETTE.IceDeep,
			Enum.Material.Glass,
			false,
			side * 28
		)
	end
	for index = 1, 3 do
		local side = if index % 2 == 0 then -1 else 1
		createDecorWedge(
			parent,
			string.format("LakeDistantMountain_%02d", index),
			Vector3.new(side * (390 + index * 22), 62 + index * 5, 6960 + index * 520),
			Vector3.new(170, 135 + index * 10, 190),
			PALETTE.Snow,
			Enum.Material.Snow,
			false,
			side * 90
		)
	end
end

local function buildDecor(decor: Folder, sampled: { Vector3 })
	local sectionFolders: { [string]: Folder } = {}
	for _, section in ipairs(FrostTrailConfig.Sections) do
		sectionFolders[section.SectionId] = createFolder(decor, section.SectionId)
	end
	buildSummitCampDecor(sectionFolders.SummitCamp)
	buildPineSlalomDecor(sectionFolders.PineSlalom, sampled)
	buildCrystalCaveDecor(sectionFolders.CrystalCave, sampled)
	buildGlacierBridgeDecor(sectionFolders.GlacierBridge, sampled)
	buildAvalanchePassDecor(sectionFolders.AvalanchePass, sampled)
	buildFrozenVillageDecor(sectionFolders.FrozenVillage, sampled)
	buildFrozenRiverDecor(sectionFolders.FrozenRiver, sampled)
	buildAlpineChuteDecor(sectionFolders.AlpineChute, sampled)
	buildLandingLakeDecor(sectionFolders.LandingLake)
end

local function transformedCorners(part: BasePart): { Vector3 }
	local corners: { Vector3 } = {}
	local halfSize = part.Size * 0.5
	for _, xSign in ipairs({ -1, 1 }) do
		for _, ySign in ipairs({ -1, 1 }) do
			for _, zSign in ipairs({ -1, 1 }) do
				table.insert(
					corners,
					part.CFrame:PointToWorldSpace(Vector3.new(
						halfSize.X * xSign,
						halfSize.Y * ySign,
						halfSize.Z * zSign
					))
				)
			end
		end
	end
	return corners
end

local function collectBaseParts(root: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function transformedWorldBounds(root: Instance): Bounds
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	local partCount = 0
	for _, part in ipairs(collectBaseParts(root)) do
		partCount += 1
		for _, corner in ipairs(transformedCorners(part)) do
			minimum = Vector3.new(
				math.min(minimum.X, corner.X),
				math.min(minimum.Y, corner.Y),
				math.min(minimum.Z, corner.Z)
			)
			maximum = Vector3.new(
				math.max(maximum.X, corner.X),
				math.max(maximum.Y, corner.Y),
				math.max(maximum.Z, corner.Z)
			)
		end
	end
	requireCondition(partCount > 0, "cannot calculate bounds for a world without parts")
	requireCondition(isFiniteVector3(minimum) and isFiniteVector3(maximum), "world bounds must be finite")
	return { Minimum = minimum, Maximum = maximum }
end

local function validateLocalPartBounds(candidate: Model)
	local epsilon = FrostTrailConfig.ValidationEpsilon
	for _, part in ipairs(collectBaseParts(candidate)) do
		for _, corner in ipairs(transformedCorners(part)) do
			local localCorner = worldToLocalPoint(corner)
			requireCondition(isFiniteVector3(localCorner), part.Name .. " has a nonfinite transformed corner")
			requireCondition(
				localCorner.X >= LOCAL_BOUNDS_MIN.X - epsilon
					and localCorner.X <= LOCAL_BOUNDS_MAX.X + epsilon
					and localCorner.Y >= LOCAL_BOUNDS_MIN.Y - epsilon
					and localCorner.Y <= LOCAL_BOUNDS_MAX.Y + epsilon
					and localCorner.Z >= LOCAL_BOUNDS_MIN.Z - epsilon
					and localCorner.Z <= LOCAL_BOUNDS_MAX.Z + epsilon,
				part.Name .. " exceeds the conservative local authored bounds"
			)
		end
	end
end

local function directChild(parent: Instance, name: string, className: string): Instance
	local matches: { Instance } = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			table.insert(matches, child)
		end
	end
	requireCondition(#matches == 1, string.format("%s must contain one direct child named %s", parent.Name, name))
	local child = matches[1]
	requireCondition(child.ClassName == className, string.format("%s must be a %s", name, className))
	return child
end

local function validateHierarchy(candidate: Model)
	requireCondition(candidate.Parent == nil, "candidate must remain unpublished during validation")
	requireCondition(#candidate:GetChildren() == 4, "candidate must have exactly four high-level folders")
	local geometry = directChild(candidate, "Geometry", "Folder") :: Folder
	local decor = directChild(candidate, "Decor", "Folder") :: Folder
	local markers = directChild(candidate, "Markers", "Folder") :: Folder
	local presentation = directChild(candidate, "Presentation", "Folder") :: Folder
	requireCondition(#geometry:GetChildren() == 5, "Geometry hierarchy mismatch")
	directChild(geometry, "SummitPlatform", "Part")
	directChild(geometry, "PlayerSpawn", "SpawnLocation")
	local track = directChild(geometry, "Track", "Folder") :: Folder
	local safety = directChild(geometry, "Safety", "Folder") :: Folder
	local lake = directChild(geometry, "FrostTrailLake", "Folder") :: Folder
	requireCondition(#track:GetChildren() == EXPECTED_GEOMETRY_SEGMENTS * 2, "Track part count mismatch")
	requireCondition(#safety:GetChildren() == EXPECTED_GEOMETRY_SEGMENTS * 2 + 3, "Safety part count mismatch")
	requireCondition(#lake:GetChildren() == 2, "FrostTrailLake must contain exactly two direct parts")
	for _, child in ipairs(lake:GetChildren()) do
		requireCondition(child:IsA("BasePart"), "FrostTrailLake children must be BaseParts")
	end
	requireCondition(#decor:GetChildren() == #FrostTrailConfig.Sections, "Decor must contain nine section folders")
	for _, section in ipairs(FrostTrailConfig.Sections) do
		directChild(decor, section.SectionId, "Folder")
	end
	requireCondition(#markers:GetChildren() == 4, "Markers hierarchy mismatch")
	directChild(markers, "StartTrigger", "Part")
	directChild(markers, "LaunchEdge", "Part")
	directChild(markers, "StartSlots", "Folder")
	directChild(markers, "SectionAnchors", "Folder")
	requireCondition(#presentation:GetChildren() == 0, "Presentation must not contain interactive or duplicate content")
	requireCondition(candidate:FindFirstChild("ActiveSleds", true) == nil, "ActiveSleds must not be created")
	requireCondition(candidate:FindFirstChild("Leaderboards", true) == nil, "Leaderboards must not be created")
end

local function physicalPropertiesMatch(actual: PhysicalProperties, expected: PhysicalProperties): boolean
	local epsilon = FrostTrailConfig.ValidationEpsilon
	return approximatelyEqual(actual.Density, expected.Density, epsilon)
		and approximatelyEqual(actual.Friction, expected.Friction, epsilon)
		and approximatelyEqual(actual.Elasticity, expected.Elasticity, epsilon)
		and approximatelyEqual(actual.FrictionWeight, expected.FrictionWeight, epsilon)
		and approximatelyEqual(actual.ElasticityWeight, expected.ElasticityWeight, epsilon)
end

local function validateTrackAndSafety(candidate: Model, plans: { SegmentPlan })
	local geometry = candidate.Geometry :: Folder
	local track = geometry.Track :: Folder
	local safety = geometry.Safety :: Folder
	local expectedTrackProperties = trackPhysicalProperties()
	for index, plan in ipairs(plans) do
		local surface = directChild(track, string.format("TrackSurface_%03d", index), "Part") :: BasePart
		local shoulder = directChild(track, string.format("SnowShoulders_%03d", index), "Part") :: BasePart
		requireCondition(surface.Anchored and surface.CanCollide and surface.CanQuery, "track surface flags mismatch")
		requireCondition(not surface.CanTouch and not surface.CastShadow, "track surface touch/shadow flags mismatch")
		requireCondition(surface:GetAttribute(TRACK_SURFACE_ATTRIBUTE) == true, "track surface attribute missing")
		requireCondition(surface.CustomPhysicalProperties ~= nil, "track physical properties missing")
		requireCondition(
			physicalPropertiesMatch(surface.CustomPhysicalProperties :: PhysicalProperties, expectedTrackProperties),
			"track physical properties mismatch"
		)
		requireCondition(surface.Size.X == plan.TrackWidth, "track width does not match its plan")
		requireCondition(surface.Size.X >= plan.ClearWidth, "track does not cover planned clear width")
		requireCondition(
			shoulder.Anchored
				and not shoulder.CanCollide
				and not shoulder.CanTouch
				and not shoulder.CanQuery
				and not shoulder.CastShadow,
			"snow shoulder must be static and nonphysical"
		)
		requireCondition(
			approximatelyEqual(
				shoulder.Size.X - surface.Size.X,
				FrostTrailConfig.SnowBankWidth * 2,
				FrostTrailConfig.ValidationEpsilon
			),
			"snow shoulder exposure mismatch"
		)
		for _, sideName in ipairs({ "Left", "Right" }) do
			local wall = directChild(safety, string.format("%sWall_%03d", sideName, index), "Part") :: BasePart
			requireCondition(
				wall.Anchored
					and wall.CanCollide
					and wall.CanQuery
					and not wall.CanTouch
					and not wall.CastShadow
					and wall.Transparency == 1,
				"course safety-wall flags mismatch"
			)
			requireCondition(
				wall.Size.X == FrostTrailConfig.SafetyWallThickness
					and wall.Size.Y == FrostTrailConfig.SafetyWallHeight,
				"course safety-wall dimensions mismatch"
			)
		end
	end
	for _, name in ipairs({ "SummitLeftWall", "SummitRightWall", "SummitRearWall" }) do
		local wall = directChild(safety, name, "Part") :: BasePart
		requireCondition(
			wall.Anchored
				and wall.CanCollide
				and wall.CanQuery
				and not wall.CanTouch
				and not wall.CastShadow
				and wall.Transparency == 1,
			"summit safety-wall flags mismatch"
		)
	end
end

local function validateSummitAndMarkers(candidate: Model, sampled: { Vector3 })
	local geometry = candidate.Geometry :: Folder
	local markers = candidate.Markers :: Folder
	local summit = geometry.SummitPlatform :: BasePart
	local spawn = geometry.PlayerSpawn :: SpawnLocation
	requireCondition(summit.Anchored and summit.CanCollide and summit.CanQuery and not summit.CanTouch, "summit flags mismatch")
	requireCondition(spawn.Anchored and spawn.CanCollide and spawn.CanQuery and not spawn.CanTouch, "PlayerSpawn flags mismatch")
	requireCondition(not spawn.Enabled and not spawn.Neutral, "PlayerSpawn must remain disabled and non-neutral")
	requireCondition(spawn.Size == FrostTrailConfig.PlayerSpawnSize, "PlayerSpawn size mismatch")
	requireCondition(
		(worldToLocalPoint(spawn.Position) - FrostTrailConfig.PlayerSpawnCenter).Magnitude
			<= FrostTrailConfig.ValidationEpsilon,
		"PlayerSpawn position mismatch"
	)
	local expectedSpawnDirection = Vector3.new(
		localToWorldPoint(FrostTrailConfig.PathPoints[1]).X - spawn.Position.X,
		0,
		localToWorldPoint(FrostTrailConfig.PathPoints[1]).Z - spawn.Position.Z
	).Unit
	requireCondition(spawn.CFrame.LookVector:Dot(expectedSpawnDirection) >= 1 - FrostTrailConfig.ValidationEpsilon, "PlayerSpawn facing mismatch")

	local startTrigger = markers.StartTrigger :: BasePart
	local launchEdge = markers.LaunchEdge :: BasePart
	for _, marker in ipairs({ startTrigger, launchEdge }) do
		requireCondition(
			marker.Anchored
				and not marker.CanCollide
				and not marker.CanTouch
				and not marker.CanQuery
				and not marker.CastShadow
				and marker.Transparency == 1,
			"authoring marker flags mismatch"
		)
	end
	requireCondition(startTrigger.Size == FrostTrailConfig.StartTriggerSize, "StartTrigger size mismatch")
	requireCondition(
		(worldToLocalPoint(startTrigger.Position) - FrostTrailConfig.StartTriggerCenter).Magnitude
			<= FrostTrailConfig.ValidationEpsilon,
		"StartTrigger position mismatch"
	)
	requireCondition(launchEdge.Size == FrostTrailConfig.LaunchMarkerSize, "LaunchEdge size mismatch")
	requireCondition(
		(worldToLocalPoint(launchEdge.Position) - (FrostTrailConfig.PathPoints[15] + Vector3.new(0, 1, 0))).Magnitude
			<= FrostTrailConfig.ValidationEpsilon,
		"LaunchEdge position mismatch"
	)

	local slots = markers.StartSlots :: Folder
	requireCondition(#slots:GetChildren() == 4, "exactly four start slots are required")
	for index, offset in ipairs(START_SLOT_OFFSETS) do
		local slot = directChild(slots, string.format("Slot_%02d", index), "Part") :: BasePart
		local expectedCenter = localToWorldPoint(FrostTrailConfig.StartSlotBaseCenter) + RIGHT_DIRECTION * offset
		requireCondition((slot.Position - expectedCenter).Magnitude <= FrostTrailConfig.ValidationEpsilon, "start-slot center mismatch")
		requireCondition(slot.Size == FrostTrailConfig.StartSlotSize, "start-slot size mismatch")
		requireCondition(slot.CFrame.LookVector:Dot(FrostTrailConfig.ForwardDirection) >= 1 - FrostTrailConfig.ValidationEpsilon, "start-slot facing mismatch")
		requireCondition(
			math.abs(offset) + slot.Size.X * 0.5 <= FrostTrailConfig.ClearPlayableWidth * 0.5,
			"start slot exceeds the clear corridor"
		)
		requireCondition(not slot.CanCollide and not slot.CanTouch and not slot.CanQuery, "start slot must be metadata only")
	end

	local sectionAnchors = markers.SectionAnchors :: Folder
	requireCondition(#sectionAnchors:GetChildren() == 9, "exactly nine section anchors are required")
	for index, section in ipairs(FrostTrailConfig.Sections) do
		local anchor = directChild(sectionAnchors, section.SectionId, "Part") :: BasePart
		local expectedLocal = if section.SectionId == "LandingLake"
			then Vector3.new(0, FrostTrailConfig.LandingTopY, 7475)
			else pathPointAtLongitudinal(sampled, (section.StartLongitudinal + section.EndLongitudinal) * 0.5)
		requireCondition((worldToLocalPoint(anchor.Position) - expectedLocal).Magnitude <= 1e-3, "section anchor position mismatch")
		requireCondition(anchor.Size == Vector3.new(2, 2, 2), "section anchor size mismatch")
		requireCondition(anchor:GetAttribute("SectionId") == section.SectionId, "section anchor id mismatch")
		requireCondition(anchor:GetAttribute("StartLongitudinal") == section.StartLongitudinal, "section anchor start mismatch")
		requireCondition(anchor:GetAttribute("EndLongitudinal") == section.EndLongitudinal, "section anchor end mismatch")
		requireCondition(anchor:GetAttribute("Order") == index, "section anchor order mismatch")
		requireCondition(not anchor.CanCollide and not anchor.CanTouch and not anchor.CanQuery, "section anchor must be metadata only")
	end
end

local function validateLake(candidate: Model)
	local lake = (candidate.Geometry :: Folder).FrostTrailLake :: Folder
	local marked = lake.FrostTrailLakeMarked_0000m_1500m :: BasePart
	local runoff = lake.FrostTrailLakeRunoff_1500m_1800m :: BasePart
	local markedCenter = worldToLocalPoint(marked.Position)
	local runoffCenter = worldToLocalPoint(runoff.Position)
	local markedStart = markedCenter.Z - marked.Size.Z * 0.5
	local markedEnd = markedCenter.Z + marked.Size.Z * 0.5
	local runoffStart = runoffCenter.Z - runoff.Size.Z * 0.5
	local runoffEnd = runoffCenter.Z + runoff.Size.Z * 0.5
	local intersection = math.min(markedEnd, runoffEnd) - math.max(markedStart, runoffStart)
	local unionLength = math.max(markedEnd, runoffEnd) - math.min(markedStart, runoffStart)
	requireCondition(approximatelyEqual(markedStart, 6350, FrostTrailConfig.ValidationEpsilon), "landing union start mismatch")
	requireCondition(approximatelyEqual(runoffEnd, 8600, FrostTrailConfig.ValidationEpsilon), "landing union end mismatch")
	requireCondition(approximatelyEqual(intersection, 0.25, FrostTrailConfig.ValidationEpsilon), "landing overlap mismatch")
	requireCondition(approximatelyEqual(unionLength, 2250, FrostTrailConfig.ValidationEpsilon), "landing union length mismatch")
	requireCondition(approximatelyEqual(marked.Size.Z + runoff.Size.Z, 2250.25, FrostTrailConfig.ValidationEpsilon), "landing summed lengths mismatch")
	requireCondition(
		approximatelyEqual(markedCenter.Y + marked.Size.Y * 0.5, FrostTrailConfig.LandingTopY, FrostTrailConfig.ValidationEpsilon)
			and approximatelyEqual(runoffCenter.Y + runoff.Size.Y * 0.5, FrostTrailConfig.LandingTopY, FrostTrailConfig.ValidationEpsilon),
		"landing segments must share the exact top height"
	)
	local expectedProperties = lakePhysicalProperties()
	for _, part in ipairs({ marked, runoff }) do
		requireCondition(part.Anchored and part.CanCollide and part.CanQuery and not part.CanTouch, "landing part flags mismatch")
		requireCondition(part.CustomPhysicalProperties ~= nil, "landing physical properties missing")
		requireCondition(
			physicalPropertiesMatch(part.CustomPhysicalProperties :: PhysicalProperties, expectedProperties),
			"landing physical properties mismatch"
		)
	end
end

local function projectedBoundsInFrame(part: BasePart, frame: CFrame): (Vector3, Vector3)
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, corner in ipairs(transformedCorners(part)) do
		local projected = frame:PointToObjectSpace(corner)
		minimum = Vector3.new(
			math.min(minimum.X, projected.X),
			math.min(minimum.Y, projected.Y),
			math.min(minimum.Z, projected.Z)
		)
		maximum = Vector3.new(
			math.max(maximum.X, projected.X),
			math.max(maximum.Y, projected.Y),
			math.max(maximum.Z, projected.Z)
		)
	end
	return minimum, maximum
end

local function validateCrystalCaveEnvelope(candidate: Model, sampled: { Vector3 })
	local decor = candidate.Decor :: Folder
	local decorativeParts = collectBaseParts(decor)
	for index = 1, #sampled - 1 do
		local pointA = sampled[index]
		local pointB = sampled[index + 1]
		if pointB.Z >= 1400 and pointA.Z <= 2250 then
			local frame, chordLength = segmentFrame(pointA, pointB, 0, 0)
			local halfLength = chordLength * 0.5 + FrostTrailConfig.ValidationEpsilon
			for _, part in ipairs(decorativeParts) do
				local minimum, maximum = projectedBoundsInFrame(part, frame)
				local overlapsLateral = maximum.X >= -CRYSTAL_ENVELOPE_WIDTH * 0.5
					and minimum.X <= CRYSTAL_ENVELOPE_WIDTH * 0.5
				local overlapsVertical = maximum.Y >= 0 and minimum.Y <= CRYSTAL_ENVELOPE_HEIGHT
				local overlapsLongitudinal = maximum.Z >= -halfLength and minimum.Z <= halfLength
				requireCondition(
					not (overlapsLateral and overlapsVertical and overlapsLongitudinal),
					part.Name .. " intrudes into the CrystalCave camera-safe envelope"
				)
			end
		end
	end
end

local FORBIDDEN_DESCENDANT_CLASSES: { [string]: boolean } = table.freeze({
	MeshPart = true,
	UnionOperation = true,
	Terrain = true,
	Decal = true,
	Texture = true,
	SurfaceGui = true,
	BillboardGui = true,
	ScreenGui = true,
	ParticleEmitter = true,
	Trail = true,
	Beam = true,
	Highlight = true,
	Light = true,
	PointLight = true,
	SpotLight = true,
	SurfaceLight = true,
	Sound = true,
	Animation = true,
	Script = true,
	LocalScript = true,
	ModuleScript = true,
	RemoteEvent = true,
	RemoteFunction = true,
	BindableEvent = true,
	BindableFunction = true,
})

local function validateBudgetsAndAllowedInstances(candidate: Model)
	local basePartCount = 0
	local collidableCount = 0
	local shadowCount = 0
	local spawnCount = 0
	local promptCount = 0
	local prohibitedCount = 0
	for _, descendant in ipairs(candidate:GetDescendants()) do
		if FORBIDDEN_DESCENDANT_CLASSES[descendant.ClassName] then
			prohibitedCount += 1
		end
		if descendant:IsA("ProximityPrompt") then
			promptCount += 1
		end
		if descendant:IsA("SpawnLocation") then
			spawnCount += 1
			requireCondition(not descendant.Enabled, "the sole PlayerSpawn must be disabled")
		end
		if descendant:IsA("BasePart") then
			basePartCount += 1
			requireCondition(descendant.Anchored, descendant.Name .. " must be anchored")
			requireCondition(not descendant.CanTouch, descendant.Name .. " must be non-touchable")
			if descendant.CanCollide then
				collidableCount += 1
			end
			if descendant.CastShadow then
				shadowCount += 1
			end
		end
	end
	requireCondition(basePartCount == EXPECTED_BASE_PART_COUNT, "BasePart count must equal the authored 447")
	requireCondition(basePartCount <= 450, "BasePart budget exceeded")
	requireCondition(collidableCount == EXPECTED_COLLIDABLE_COUNT, "collidable count must equal the authored 229")
	requireCondition(collidableCount <= 230, "collidable-part budget exceeded")
	requireCondition(shadowCount == EXPECTED_SHADOW_COUNT, "shadow count must equal the authored 68")
	requireCondition(shadowCount <= 170, "shadow-caster budget exceeded")
	requireCondition(spawnCount == 1, "exactly one disabled SpawnLocation is required")
	requireCondition(promptCount == 0, "Frost Trail must contain zero ProximityPrompts")
	requireCondition(prohibitedCount == 0, "Frost Trail contains a prohibited or asset-backed instance")
	requireCondition(candidate:GetAttribute("BasePartCount") == basePartCount, "BasePartCount attribute mismatch")

	local decor = candidate.Decor :: Folder
	local decorParts = collectBaseParts(decor)
	requireCondition(#decorParts == EXPECTED_DECOR_COUNT, "decor must contain the authored 129 parts")
	for _, part in ipairs(decorParts) do
		requireCondition(
			part.Anchored and not part.CanCollide and not part.CanTouch and not part.CanQuery,
			part.Name .. " must remain static and nonphysical"
		)
	end
	local markerParts = collectBaseParts(candidate.Markers :: Folder)
	requireCondition(#markerParts == EXPECTED_MARKER_COUNT, "marker count must equal the authored 15")
end

local function validateAttributes(candidate: Model, authoredLength: number)
	requireCondition(candidate:GetAttribute("CourseId") == "FrostTrailV1", "CourseId attribute mismatch")
	requireCondition(candidate:GetAttribute("DisplayName") == "FROST TRAIL", "DisplayName attribute mismatch")
	requireCondition(candidate:GetAttribute("WorldVersion") == 1, "WorldVersion attribute mismatch")
	requireCondition(candidate:GetAttribute("StaticFoundationOnly") == true, "static attribute mismatch")
	requireCondition(candidate:GetAttribute("Playable") == false, "playable attribute mismatch")
	requireCondition(candidate:GetAttribute("ForwardX") == 0, "ForwardX attribute mismatch")
	requireCondition(candidate:GetAttribute("ForwardY") == 0, "ForwardY attribute mismatch")
	requireCondition(candidate:GetAttribute("ForwardZ") == 1, "ForwardZ attribute mismatch")
	requireCondition(candidate:GetAttribute("OriginX") == 3200, "OriginX attribute mismatch")
	requireCondition(candidate:GetAttribute("OriginY") == 0, "OriginY attribute mismatch")
	requireCondition(candidate:GetAttribute("OriginZ") == 0, "OriginZ attribute mismatch")
	requireCondition(candidate:GetAttribute("TrackStartLongitudinal") == -250, "track-start attribute mismatch")
	requireCondition(candidate:GetAttribute("LaunchLongitudinal") == 6350, "launch attribute mismatch")
	local storedLength = candidate:GetAttribute("AuthoredPathLengthStuds")
	requireCondition(type(storedLength) == "number", "authored-length attribute must be numeric")
	requireCondition(
		approximatelyEqual(storedLength :: number, authoredLength, FrostTrailConfig.ValidationEpsilon),
		"authored-length attribute mismatch"
	)
end

local function validateSpatialSeparation(candidate: Model)
	local classic = Workspace:FindFirstChild("FrostlineWorld")
	requireCondition(classic ~= nil and classic:IsA("Model"), "valid Classic FrostlineWorld model is required")
	local candidateBounds = transformedWorldBounds(candidate)
	local classicBounds = transformedWorldBounds(classic :: Model)
	requireCondition(
		candidateBounds.Minimum.X >= 2500 - FrostTrailConfig.ValidationEpsilon,
		"Frost Trail extends inside its conservative world-X separation envelope"
	)
	requireCondition(
		candidateBounds.Minimum.X - classicBounds.Maximum.X >= MINIMUM_CLASSIC_SEPARATION_X,
		"Frost Trail is not separated from Classic by at least 1000 world-X studs"
	)
end

local function validateCandidate(candidate: Model, sampled: { Vector3 }, plans: { SegmentPlan }, authoredLength: number)
	validateHierarchy(candidate)
	validateTrackAndSafety(candidate, plans)
	validateSummitAndMarkers(candidate, sampled)
	validateLake(candidate)
	validateCrystalCaveEnvelope(candidate, sampled)
	validateLocalPartBounds(candidate)
	validateBudgetsAndAllowedInstances(candidate)
	validateAttributes(candidate, authoredLength)
	validateSpatialSeparation(candidate)
end

local function setWorldAttributes(candidate: Model, authoredLength: number)
	candidate:SetAttribute("CourseId", FrostTrailConfig.CourseId)
	candidate:SetAttribute("DisplayName", FrostTrailConfig.DisplayName)
	candidate:SetAttribute("WorldVersion", FrostTrailConfig.WorldVersion)
	candidate:SetAttribute("StaticFoundationOnly", FrostTrailConfig.StaticFoundationOnly)
	candidate:SetAttribute("Playable", FrostTrailConfig.Playable)
	candidate:SetAttribute("ForwardX", FrostTrailConfig.ForwardDirection.X)
	candidate:SetAttribute("ForwardY", FrostTrailConfig.ForwardDirection.Y)
	candidate:SetAttribute("ForwardZ", FrostTrailConfig.ForwardDirection.Z)
	candidate:SetAttribute("OriginX", FrostTrailConfig.WorldOrigin.X)
	candidate:SetAttribute("OriginY", FrostTrailConfig.WorldOrigin.Y)
	candidate:SetAttribute("OriginZ", FrostTrailConfig.WorldOrigin.Z)
	candidate:SetAttribute("TrackStartLongitudinal", FrostTrailConfig.PathPoints[1].Z)
	candidate:SetAttribute("LaunchLongitudinal", FrostTrailConfig.PathPoints[#FrostTrailConfig.PathPoints].Z)
	candidate:SetAttribute("AuthoredPathLengthStuds", authoredLength)
	candidate:SetAttribute("BasePartCount", #collectBaseParts(candidate))
end

local function constructCandidate(candidate: Model)
	validateConfiguration()
	local sampled = samplePath()
	local authoredLength = validateAndMeasureSampledPath(sampled)
	local geometryPoints = splitSampledPath(sampled)
	local plans = createSegmentPlans(geometryPoints)

	local geometry = createFolder(candidate, "Geometry")
	local decor = createFolder(candidate, "Decor")
	local markers = createFolder(candidate, "Markers")
	createFolder(candidate, "Presentation")
	local track = createFolder(geometry, "Track")
	local safety = createFolder(geometry, "Safety")

	buildTrack(track, safety, plans)
	buildSummit(geometry, safety)
	buildLandingLake(geometry)
	buildMarkers(markers, sampled)
	buildDecor(decor, sampled)
	setWorldAttributes(candidate, authoredLength)
	validateCandidate(candidate, sampled, plans, authoredLength)
end

function FrostTrailWorldBuilder.build(): Model
	local candidate = Instance.new("Model")
	candidate.Name = FrostTrailConfig.WorldModelName

	local constructionSucceeded, failureReason = pcall(function()
		constructCandidate(candidate)
	end)
	if not constructionSucceeded then
		candidate:Destroy()
		error(tostring(failureReason), 0)
	end

	local existingWorlds: { Instance } = {}
	for _, child in ipairs(Workspace:GetChildren()) do
		if child.Name == FrostTrailConfig.WorldModelName then
			table.insert(existingWorlds, child)
		end
	end
	for _, existingWorld in ipairs(existingWorlds) do
		existingWorld:Destroy()
	end
	candidate.Parent = Workspace

	local publishedMatches = 0
	for _, child in ipairs(Workspace:GetChildren()) do
		if child.Name == FrostTrailConfig.WorldModelName then
			publishedMatches += 1
		end
	end
	if publishedMatches ~= 1 or candidate.Parent ~= Workspace then
		candidate:Destroy()
		fail("transactional publication did not leave exactly one FrostTrailWorld")
	end
	return candidate
end

return table.freeze(FrostTrailWorldBuilder)
