--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local FrostTrailConfig = require(script.Parent.FrostTrailConfig)
local FrostTrailRouteContentConfig = require(script.Parent.FrostTrailRouteContentConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PHYSICS = GameConfig.Physics
local PALETTE = GameConfig.Palette

local FrostTrailWorldBuilder = {}

local EXPECTED_BASE_SAMPLES = 57
local EXPECTED_BASE_CHORDS = 56
local EXPECTED_GEOMETRY_POINTS = 75
local EXPECTED_GEOMETRY_SEGMENTS = 74
local EXPECTED_AUTHORED_LENGTH = 6696.671726289
local EXPECTED_BASE_PART_COUNT = 628
local EXPECTED_COLLIDABLE_COUNT = 229
local EXPECTED_SHADOW_COUNT = 89
local EXPECTED_MARKER_COUNT = 15
local EXPECTED_DECOR_COUNT = 129
local EXPECTED_GAMEPLAY_PART_COUNT = 181
local EXPECTED_COIN_COUNT = 160
local EXPECTED_OBSTACLE_COUNT = 21
local EXPECTED_OBSTACLE_ROW_COUNT = 18
local EXPECTED_ICE_BLOCKER_COUNT = 14
local EXPECTED_HOP_BARRIER_COUNT = 7
local NOMINAL_HOP_APEX_GAIN = 8.9917
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
local GEOMETRY_SPLIT_LONGITUDINALS = FrostTrailConfig.RouteData.GeometrySplitLongitudinals

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

type RouteGeometryPoint = FrostTrailConfig.RouteGeometryPoint
type CoinPattern = FrostTrailRouteContentConfig.CoinPattern
type CoinPlacement = FrostTrailRouteContentConfig.CoinPlacement
type ObstacleKind = FrostTrailRouteContentConfig.ObstacleKind
type ObstacleRowDefinition = FrostTrailRouteContentConfig.ObstacleRowDefinition
type ObstaclePlacement = FrostTrailRouteContentConfig.ObstaclePlacement

type SegmentPlan = {
	PointA: Vector3,
	PointB: Vector3,
	Direction: Vector3,
	Length: number,
	TrackWidth: number,
	ClearWidth: number,
	StartTrackWidth: number,
	EndTrackWidth: number,
	StartExtension: number,
	EndExtension: number,
}

type Bounds = {
	Minimum: Vector3,
	Maximum: Vector3,
}

type RouteSample = {
	Frame: CFrame,
	TrackWidth: number,
	ClearPlayableWidth: number,
}

type CoinGroupExpectation = {
	GroupId: string,
	SectionId: string,
	Pattern: CoinPattern,
	Count: number,
	StartLongitudinal: number,
	EndLongitudinal: number,
	LaneOffsets: { number },
	HeightOffsets: { number },
}

type ObstacleRowExpectation = {
	EncounterId: string,
	SectionId: string,
	Longitudinal: number,
	ObstacleKind: ObstacleKind,
	LaneOffsets: { number },
}

local function frozenNumbers(values: { number }): { number }
	return table.freeze(values)
end

local function expectedCoinGroup(
	groupId: string,
	sectionId: string,
	pattern: CoinPattern,
	count: number,
	startLongitudinal: number,
	endLongitudinal: number,
	laneOffsets: { number },
	heightOffsets: { number }
): CoinGroupExpectation
	return table.freeze({
		GroupId = groupId,
		SectionId = sectionId,
		Pattern = pattern,
		Count = count,
		StartLongitudinal = startLongitudinal,
		EndLongitudinal = endLongitudinal,
		LaneOffsets = frozenNumbers(laneOffsets),
		HeightOffsets = frozenNumbers(heightOffsets),
	})
end

local EXPECTED_COIN_GROUPS: { CoinGroupExpectation } = table.freeze({
	expectedCoinGroup("SC01", "SummitCamp", "Line", 6, -160, 40, { 0 }, { 3.5 }),
	expectedCoinGroup("SC02", "SummitCamp", "Sweep", 5, 100, 260, { 0, -24 }, { 3.5 }),
	expectedCoinGroup("SC03", "SummitCamp", "Arc", 3, 388, 412, { 0 }, { 3.5, 8.5, 3.5 }),
	expectedCoinGroup("PS01", "PineSlalom", "Parallel", 10, 520, 680, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("PS02", "PineSlalom", "Line", 7, 760, 1180, { -24 }, { 3.5 }),
	expectedCoinGroup("PS03", "PineSlalom", "Arc", 5, 1264, 1296, { 0 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	expectedCoinGroup("CC01", "CrystalCave", "Parallel", 8, 1400, 1550, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("CC02", "CrystalCave", "Line", 4, 1630, 1810, { 24 }, { 3.5 }),
	expectedCoinGroup("CC03", "CrystalCave", "Line", 3, 1880, 2000, { 0 }, { 3.5 }),
	expectedCoinGroup("CC04", "CrystalCave", "Arc", 5, 2094, 2126, { 24 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	expectedCoinGroup("GB01", "GlacierBridge", "Line", 4, 2270, 2450, { 0 }, { 3.5 }),
	expectedCoinGroup("GB02", "GlacierBridge", "Parallel", 8, 2520, 2700, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("GB03", "GlacierBridge", "Line", 3, 2770, 2890, { 24 }, { 3.5 }),
	expectedCoinGroup("GB04", "GlacierBridge", "Arc", 3, 2928, 2952, { -24 }, { 3.5, 8.5, 3.5 }),
	expectedCoinGroup("AP01", "AvalanchePass", "Line", 3, 3040, 3160, { 0 }, { 3.5 }),
	expectedCoinGroup("AP02", "AvalanchePass", "Parallel", 10, 3200, 3440, { -42, 42 }, { 3.5 }),
	expectedCoinGroup("AP03", "AvalanchePass", "Arc", 5, 3442, 3498, { 0 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	expectedCoinGroup("AP04", "AvalanchePass", "Parallel", 6, 3510, 3710, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("FV01", "FrozenVillage", "Parallel", 8, 3860, 4070, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("FV02", "FrozenVillage", "Line", 5, 4150, 4350, { 24 }, { 3.5 }),
	expectedCoinGroup("FV03", "FrozenVillage", "Arc", 5, 4364, 4396, { -24 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	expectedCoinGroup("FV04", "FrozenVillage", "Parallel", 4, 4540, 4640, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("FR01", "FrozenRiver", "Parallel", 6, 4700, 4800, { -24, 24 }, { 3.5 }),
	expectedCoinGroup("FR02", "FrozenRiver", "Line", 4, 4870, 5050, { 24 }, { 3.5 }),
	expectedCoinGroup("FR03", "FrozenRiver", "Arc", 5, 5084, 5116, { 0 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	expectedCoinGroup("FR04", "FrozenRiver", "Line", 5, 5160, 5360, { 24 }, { 3.5 }),
	expectedCoinGroup("FR05", "FrozenRiver", "Sweep", 4, 5430, 5550, { 24, 0 }, { 3.5 }),
	expectedCoinGroup("AC01", "AlpineChute", "Line", 3, 5580, 5660, { 24 }, { 3.5 }),
	expectedCoinGroup("AC02", "AlpineChute", "Sweep", 5, 5700, 5860, { 24, 0 }, { 3.5 }),
	expectedCoinGroup("AC03", "AlpineChute", "Arc", 3, 5896, 5944, { 0 }, { 3.5, 8.5, 3.5 }),
	expectedCoinGroup("AC04", "AlpineChute", "Line", 5, 5980, 6060, { 0 }, { 3.5 }),
})

local function expectedObstacleRow(
	encounterId: string,
	sectionId: string,
	longitudinal: number,
	obstacleKind: ObstacleKind,
	laneOffsets: { number }
): ObstacleRowExpectation
	return table.freeze({
		EncounterId = encounterId,
		SectionId = sectionId,
		Longitudinal = longitudinal,
		ObstacleKind = obstacleKind,
		LaneOffsets = frozenNumbers(laneOffsets),
	})
end

local EXPECTED_OBSTACLE_ROWS: { ObstacleRowExpectation } = table.freeze({
	expectedObstacleRow("FrostRow_01", "SummitCamp", 400, "HopBarrier", { 0 }),
	expectedObstacleRow("FrostRow_02", "PineSlalom", 720, "IceBlocker", { 0 }),
	expectedObstacleRow("FrostRow_03", "PineSlalom", 1040, "IceBlocker", { 24 }),
	expectedObstacleRow("FrostRow_04", "PineSlalom", 1280, "HopBarrier", { 0 }),
	expectedObstacleRow("FrostRow_05", "CrystalCave", 1600, "IceBlocker", { 0 }),
	expectedObstacleRow("FrostRow_06", "CrystalCave", 1840, "IceBlocker", { -24 }),
	expectedObstacleRow("FrostRow_07", "CrystalCave", 2110, "HopBarrier", { 24 }),
	expectedObstacleRow("FrostRow_08", "GlacierBridge", 2460, "IceBlocker", { -24, 24 }),
	expectedObstacleRow("FrostRow_09", "GlacierBridge", 2720, "IceBlocker", { 0 }),
	expectedObstacleRow("FrostRow_10", "GlacierBridge", 2940, "HopBarrier", { -24 }),
	expectedObstacleRow("FrostRow_11", "AvalanchePass", 3300, "IceBlocker", { -24, 24 }),
	expectedObstacleRow("FrostRow_12", "AvalanchePass", 3470, "HopBarrier", { 0 }),
	expectedObstacleRow("FrostRow_13", "AvalanchePass", 3740, "IceBlocker", { 0 }),
	expectedObstacleRow("FrostRow_14", "FrozenVillage", 4110, "IceBlocker", { 0 }),
	expectedObstacleRow("FrostRow_15", "FrozenVillage", 4380, "HopBarrier", { -24 }),
	expectedObstacleRow("FrostRow_16", "FrozenRiver", 4820, "IceBlocker", { 0 }),
	expectedObstacleRow("FrostRow_17", "FrozenRiver", 5100, "HopBarrier", { 0 }),
	expectedObstacleRow("FrostRow_18", "FrozenRiver", 5390, "IceBlocker", { -24, 0 }),
})

local EXPECTED_COIN_SECTION_COUNTS: { [string]: number } = table.freeze({
	SummitCamp = 14,
	PineSlalom = 22,
	CrystalCave = 20,
	GlacierBridge = 18,
	AvalanchePass = 24,
	FrozenVillage = 22,
	FrozenRiver = 24,
	AlpineChute = 16,
	LandingLake = 0,
})

local EXPECTED_OBSTACLE_SECTION_COUNTS: { [string]: number } = table.freeze({
	SummitCamp = 1,
	PineSlalom = 3,
	CrystalCave = 3,
	GlacierBridge = 4,
	AvalanchePass = 4,
	FrozenVillage = 2,
	FrozenRiver = 4,
	AlpineChute = 0,
	LandingLake = 0,
})

local COIN_ATTRIBUTE_NAMES: { string } = table.freeze({
	"ContentId",
	"ContentKind",
	"SectionId",
	"GroupId",
	"Pattern",
	"Longitudinal",
	"LateralOffset",
	"HeightOffset",
	"RuntimeEnabled",
})

local OBSTACLE_ATTRIBUTE_NAMES: { string } = table.freeze({
	"ContentId",
	"ContentKind",
	"SectionId",
	"EncounterId",
	"ObstacleKind",
	"Longitudinal",
	"LateralOffset",
	"RuntimeEnabled",
})

local function fail(message: string): never
	error("Frost Trail world: " .. message, 0)
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

local function inclusiveValue(startValue: number, endValue: number, index: number, count: number): number
	if count == 1 then
		return startValue
	end
	return startValue + (endValue - startValue) * ((index - 1) / (count - 1))
end

local function expectedCoinValues(group: CoinGroupExpectation, index: number): (number, number, number)
	if group.Pattern == "Parallel" then
		local perLane = group.Count / 2
		local laneIndex = math.floor((index - 1) / perLane) + 1
		local indexInLane = ((index - 1) % perLane) + 1
		return inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, indexInLane, perLane),
			group.LaneOffsets[laneIndex],
			group.HeightOffsets[1]
	end

	local longitudinal = inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, index, group.Count)
	if group.Pattern == "Sweep" then
		return longitudinal,
			inclusiveValue(group.LaneOffsets[1], group.LaneOffsets[2], index, group.Count),
			group.HeightOffsets[1]
	elseif group.Pattern == "Arc" then
		return longitudinal, group.LaneOffsets[1], group.HeightOffsets[index]
	end
	return longitudinal, group.LaneOffsets[1], group.HeightOffsets[1]
end

local function tableEntryCount(value: { [any]: any }): number
	local count = 0
	for _ in value do
		count += 1
	end
	return count
end

local function validateRouteContentConfiguration()
	local config = FrostTrailRouteContentConfig
	requireCondition(table.isfrozen(config), "route-content configuration must be frozen")
	requireCondition(config.CourseId == "FrostTrailV1", "route-content CourseId mismatch")
	requireCondition(config.ContentVersion == 1, "route-content version mismatch")
	requireCondition(config.RuntimeEnabled == true, "route content must be runtime-enabled")
	requireCondition(config.RuntimeVersion == 1, "route-content runtime version mismatch")
	local runtime = config.Runtime
	requireCondition(table.isfrozen(runtime), "route-content Runtime must be separately frozen")
	requireCondition(tableEntryCount(runtime :: any) == 24, "route-content Runtime field count mismatch")
	local function validateExactRuntimeNumber(value: number, expected: number, name: string)
		requireCondition(isFiniteNumber(value) and value == expected, name .. " runtime value mismatch")
	end
	validateExactRuntimeNumber(runtime.CoinRewardPerPickup, 1, "CoinRewardPerPickup")
	validateExactRuntimeNumber(runtime.MaximumRouteCoins, 160, "MaximumRouteCoins")
	validateExactRuntimeNumber(runtime.MaximumObstacleEncounters, 18, "MaximumObstacleEncounters")
	validateExactRuntimeNumber(runtime.EvaluationStartLongitudinal, -200, "EvaluationStartLongitudinal")
	validateExactRuntimeNumber(runtime.EvaluationEndLongitudinal, 6100, "EvaluationEndLongitudinal")
	validateExactRuntimeNumber(runtime.CoinPickupRadiusStuds, 5.25, "CoinPickupRadiusStuds")
	validateExactRuntimeNumber(runtime.BroadphasePaddingStuds, 20, "BroadphasePaddingStuds")
	validateExactRuntimeNumber(runtime.MaximumEvaluationDeltaSeconds, 0.10, "MaximumEvaluationDeltaSeconds")
	validateExactRuntimeNumber(runtime.MaximumSweepSubstepSeconds, 0.05, "MaximumSweepSubstepSeconds")
	validateExactRuntimeNumber(runtime.MaximumSweepSubsteps, 2, "MaximumSweepSubsteps")
	validateExactRuntimeNumber(
		runtime.MaximumHorizontalSpeedStudsPerSecond,
		165,
		"MaximumHorizontalSpeedStudsPerSecond"
	)
	validateExactRuntimeNumber(runtime.MaximumTotalSpeedStudsPerSecond, 180, "MaximumTotalSpeedStudsPerSecond")
	validateExactRuntimeNumber(runtime.MovementSlackStuds, 12, "MovementSlackStuds")
	validateExactRuntimeNumber(runtime.MaximumCandidatesPerUpdate, 24, "MaximumCandidatesPerUpdate")
	validateExactVector(runtime.SledRootHalfSize, Vector3.new(2.8, 0.4, 4.3), "route-content SledRootHalfSize")
	requireCondition(isFiniteVector3(runtime.SledRootHalfSize), "route-content SledRootHalfSize must be finite")
	validateExactRuntimeNumber(runtime.ObstacleContactPaddingStuds, 0.20, "ObstacleContactPaddingStuds")
	validateExactRuntimeNumber(runtime.ParallelAxisEpsilon, 0.00000001, "ParallelAxisEpsilon")
	validateExactRuntimeNumber(runtime.TimeOfImpactEpsilon, 0.000001, "TimeOfImpactEpsilon")
	validateExactRuntimeNumber(runtime.IceBlockerSpeedLoss, 30, "IceBlockerSpeedLoss")
	validateExactRuntimeNumber(runtime.IceBlockerMinimumSpeedCap, 18, "IceBlockerMinimumSpeedCap")
	validateExactRuntimeNumber(runtime.IceBlockerPenaltySeconds, 1.50, "IceBlockerPenaltySeconds")
	validateExactRuntimeNumber(runtime.HopBarrierSpeedLoss, 20, "HopBarrierSpeedLoss")
	validateExactRuntimeNumber(runtime.HopBarrierMinimumSpeedCap, 22, "HopBarrierMinimumSpeedCap")
	validateExactRuntimeNumber(runtime.HopBarrierPenaltySeconds, 1.00, "HopBarrierPenaltySeconds")
	requireCondition(config.GroundCoinHeight == 3.5, "ground-coin height mismatch")
	validateExactVector(config.CoinSize, Vector3.new(0.75, 3.6, 3.6), "route-content CoinSize")
	validateExactVector(config.IceBlockerSize, Vector3.new(12, 6, 5), "route-content IceBlockerSize")
	validateExactVector(config.HopBarrierSize, Vector3.new(16, 3, 3), "route-content HopBarrierSize")
	for _, size in ipairs({ config.CoinSize, config.IceBlockerSize, config.HopBarrierSize }) do
		requireCondition(
			isFiniteVector3(size) and size.X > 0 and size.Y > 0 and size.Z > 0,
			"route-content sizes must be finite and positive"
		)
	end

	requireCondition(table.isfrozen(config.CoinPlacements), "CoinPlacements must be frozen")
	requireCondition(table.isfrozen(config.ObstacleRows), "ObstacleRows must be frozen")
	requireCondition(table.isfrozen(config.ObstaclePlacements), "ObstaclePlacements must be frozen")
	requireCondition(#config.CoinPlacements == EXPECTED_COIN_COUNT, "coin-placement count mismatch")
	requireCondition(#config.ObstacleRows == EXPECTED_OBSTACLE_ROW_COUNT, "obstacle-row count mismatch")
	requireCondition(#config.ObstaclePlacements == EXPECTED_OBSTACLE_COUNT, "obstacle-placement count mismatch")

	local coinSectionCounts: { [string]: number } = {}
	local obstacleSectionCounts: { [string]: number } = {}
	for _, section in ipairs(FrostTrailConfig.Sections) do
		coinSectionCounts[section.SectionId] = 0
		obstacleSectionCounts[section.SectionId] = 0
	end

	local coinIndex = 0
	local seenCoinIds: { [string]: boolean } = {}
	for _, expectedGroup in ipairs(EXPECTED_COIN_GROUPS) do
		for indexInGroup = 1, expectedGroup.Count do
			coinIndex += 1
			local placement = config.CoinPlacements[coinIndex]
			requireCondition(placement ~= nil, "missing expanded coin placement")
			local expectedLongitudinal, expectedLateral, expectedHeight = expectedCoinValues(expectedGroup, indexInGroup)
			local expectedId = string.format("FrostCoin_%03d", coinIndex)
			requireCondition(table.isfrozen(placement), expectedId .. " placement must be frozen")
			requireCondition(tableEntryCount(placement :: any) == 7, expectedId .. " placement field count mismatch")
			requireCondition(placement.ContentId == expectedId, expectedId .. " stable ID mismatch")
			requireCondition(not seenCoinIds[placement.ContentId], expectedId .. " stable ID is duplicated")
			seenCoinIds[placement.ContentId] = true
			requireCondition(placement.SectionId == expectedGroup.SectionId, expectedId .. " section mismatch")
			requireCondition(placement.GroupId == expectedGroup.GroupId, expectedId .. " group mismatch")
			requireCondition(placement.Pattern == expectedGroup.Pattern, expectedId .. " pattern mismatch")
			requireCondition(
				isFiniteNumber(placement.Longitudinal)
					and isFiniteNumber(placement.LateralOffset)
					and isFiniteNumber(placement.HeightOffset),
				expectedId .. " placement must be finite"
			)
			requireCondition(
				approximatelyEqual(placement.Longitudinal, expectedLongitudinal, FrostTrailConfig.ValidationEpsilon),
				expectedId .. " longitudinal mismatch"
			)
			requireCondition(
				approximatelyEqual(placement.LateralOffset, expectedLateral, FrostTrailConfig.ValidationEpsilon),
				expectedId .. " lateral offset mismatch"
			)
			requireCondition(
				approximatelyEqual(placement.HeightOffset, expectedHeight, FrostTrailConfig.ValidationEpsilon),
				expectedId .. " height offset mismatch"
			)
			if placement.Pattern == "Arc" then
				requireCondition(placement.HeightOffset <= NOMINAL_HOP_APEX_GAIN, expectedId .. " exceeds the hop envelope")
			else
				requireCondition(placement.HeightOffset == config.GroundCoinHeight, expectedId .. " ground height mismatch")
			end
			requireCondition(
				placement.Longitudinal >= -160 and placement.Longitudinal <= 6060,
				expectedId .. " is outside the authored scoring interval"
			)
			requireCondition(
				placement.Longitudinal < runtime.EvaluationEndLongitudinal,
				expectedId .. " enters the clear launch interval"
			)
			local previousSectionCount = coinSectionCounts[placement.SectionId]
			requireCondition(previousSectionCount ~= nil, expectedId .. " has an unknown section")
			coinSectionCounts[placement.SectionId] = (previousSectionCount :: number) + 1
		end
	end
	requireCondition(coinIndex == EXPECTED_COIN_COUNT, "coin groups did not consume exactly 160 placements")

	local obstacleIndex = 0
	local iceBlockerCount = 0
	local hopBarrierCount = 0
	local seenObstacleIds: { [string]: boolean } = {}
	local seenEncounterIds: { [string]: boolean } = {}
	for rowIndex, expectedRow in ipairs(EXPECTED_OBSTACLE_ROWS) do
		local row = config.ObstacleRows[rowIndex]
		requireCondition(row ~= nil, "missing obstacle row")
		requireCondition(table.isfrozen(row), expectedRow.EncounterId .. " must be frozen")
		requireCondition(table.isfrozen(row.LaneOffsets), expectedRow.EncounterId .. " lanes must be frozen")
		requireCondition(tableEntryCount(row :: any) == 5, expectedRow.EncounterId .. " field count mismatch")
		requireCondition(row.EncounterId == expectedRow.EncounterId, expectedRow.EncounterId .. " ID mismatch")
		requireCondition(not seenEncounterIds[row.EncounterId], expectedRow.EncounterId .. " ID is duplicated")
		seenEncounterIds[row.EncounterId] = true
		requireCondition(row.SectionId == expectedRow.SectionId, expectedRow.EncounterId .. " section mismatch")
		requireCondition(row.Longitudinal == expectedRow.Longitudinal, expectedRow.EncounterId .. " longitudinal mismatch")
		requireCondition(row.ObstacleKind == expectedRow.ObstacleKind, expectedRow.EncounterId .. " kind mismatch")
		requireCondition(#row.LaneOffsets == #expectedRow.LaneOffsets, expectedRow.EncounterId .. " lane count mismatch")
		for laneIndex, expectedLane in ipairs(expectedRow.LaneOffsets) do
			requireCondition(row.LaneOffsets[laneIndex] == expectedLane, expectedRow.EncounterId .. " lane mismatch")
		end
		if rowIndex > 1 then
			requireCondition(
				row.Longitudinal - config.ObstacleRows[rowIndex - 1].Longitudinal >= 170,
				expectedRow.EncounterId .. " is too close to its preceding row"
			)
		end

		local occupiedNormalLanes: { [number]: boolean } = {}
		for _, laneOffset in ipairs(row.LaneOffsets) do
			occupiedNormalLanes[laneOffset] = true
		end
		local hasGroundBypass = false
		for _, normalLane in ipairs(FrostTrailConfig.LaneCenterOffsets) do
			if not occupiedNormalLanes[normalLane] then
				hasGroundBypass = true
				break
			end
		end
		requireCondition(hasGroundBypass, expectedRow.EncounterId .. " must leave a normal ground bypass")
		if row.ObstacleKind == "HopBarrier" then
			requireCondition(#row.LaneOffsets < 3, expectedRow.EncounterId .. " must leave a steering bypass")
			for otherIndex, otherRow in ipairs(config.ObstacleRows) do
				if otherIndex ~= rowIndex then
					local relative = otherRow.Longitudinal - row.Longitudinal
					requireCondition(
						relative < -50 or relative > 100,
						expectedRow.EncounterId .. " has another obstacle inside its hop-clearance interval"
					)
				end
			end
		end

		for _, expectedLane in ipairs(expectedRow.LaneOffsets) do
			obstacleIndex += 1
			local placement = config.ObstaclePlacements[obstacleIndex]
			local expectedId = string.format("FrostObstacle_%03d", obstacleIndex)
			requireCondition(placement ~= nil, "missing expanded obstacle placement")
			requireCondition(table.isfrozen(placement), expectedId .. " placement must be frozen")
			requireCondition(tableEntryCount(placement :: any) == 6, expectedId .. " placement field count mismatch")
			requireCondition(placement.ContentId == expectedId, expectedId .. " stable ID mismatch")
			requireCondition(not seenObstacleIds[placement.ContentId], expectedId .. " stable ID is duplicated")
			seenObstacleIds[placement.ContentId] = true
			requireCondition(placement.SectionId == expectedRow.SectionId, expectedId .. " section mismatch")
			requireCondition(placement.EncounterId == expectedRow.EncounterId, expectedId .. " encounter mismatch")
			requireCondition(placement.ObstacleKind == expectedRow.ObstacleKind, expectedId .. " kind mismatch")
			requireCondition(placement.Longitudinal == expectedRow.Longitudinal, expectedId .. " longitudinal mismatch")
			requireCondition(placement.LateralOffset == expectedLane, expectedId .. " lane mismatch")
			requireCondition(
				isFiniteNumber(placement.Longitudinal) and isFiniteNumber(placement.LateralOffset),
				expectedId .. " placement must be finite"
			)
			requireCondition(
				placement.Longitudinal >= 400 and placement.Longitudinal <= 5390,
				expectedId .. " is outside the authored obstacle interval"
			)
			requireCondition(
				placement.Longitudinal < runtime.EvaluationEndLongitudinal,
				expectedId .. " enters the clear launch interval"
			)
			local previousSectionCount = obstacleSectionCounts[placement.SectionId]
			requireCondition(previousSectionCount ~= nil, expectedId .. " has an unknown section")
			obstacleSectionCounts[placement.SectionId] = (previousSectionCount :: number) + 1
			if placement.ObstacleKind == "IceBlocker" then
				iceBlockerCount += 1
			else
				hopBarrierCount += 1
			end
		end
	end
	requireCondition(obstacleIndex == EXPECTED_OBSTACLE_COUNT, "obstacle rows did not consume exactly 21 placements")
	requireCondition(
		tableEntryCount(seenEncounterIds :: any) == EXPECTED_OBSTACLE_ROW_COUNT,
		"obstacle EncounterId count mismatch"
	)
	requireCondition(iceBlockerCount == EXPECTED_ICE_BLOCKER_COUNT, "ice-blocker count mismatch")
	requireCondition(hopBarrierCount == EXPECTED_HOP_BARRIER_COUNT, "hop-barrier count mismatch")
	requireCondition(config.ObstacleRows[11].Longitudinal == 3300, "AvalanchePass seam repair must remain at 3300")

	for sectionId, expectedCount in EXPECTED_COIN_SECTION_COUNTS do
		requireCondition(coinSectionCounts[sectionId] == expectedCount, sectionId .. " coin count mismatch")
	end
	for sectionId, expectedCount in EXPECTED_OBSTACLE_SECTION_COUNTS do
		requireCondition(obstacleSectionCounts[sectionId] == expectedCount, sectionId .. " obstacle count mismatch")
	end
end

local function validateConfiguration()
	local epsilon = FrostTrailConfig.ValidationEpsilon
	requireCondition(table.isfrozen(FrostTrailConfig), "configuration must be frozen")
	requireCondition(epsilon == 1e-5, "ValidationEpsilon must equal 1e-5")
	requireCondition(FrostTrailConfig.CourseId == "FrostTrailV1", "CourseId mismatch")
	requireCondition(FrostTrailConfig.DisplayName == "FROST TRAIL", "DisplayName mismatch")
	requireCondition(FrostTrailConfig.WorldModelName == "FrostTrailWorld", "WorldModelName mismatch")
	requireCondition(FrostTrailConfig.WorldVersion == 1, "WorldVersion mismatch")
	requireCondition(FrostTrailConfig.StaticFoundationOnly == false, "static-foundation flag must be false")
	requireCondition(FrostTrailConfig.Playable == false, "playable flag must be false")
	requireCondition(
		FrostTrailConfig.ActivationMode == "StudioControlledTest",
		"ActivationMode must equal StudioControlledTest"
	)
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

	local routeData = FrostTrailConfig.RouteData
	requireCondition(table.isfrozen(routeData), "RouteData must be frozen")
	requireCondition(
		table.isfrozen(routeData.SampledCenterlinePoints),
		"SampledCenterlinePoints must be frozen"
	)
	requireCondition(table.isfrozen(routeData.GeometryPoints), "GeometryPoints must be frozen")
	requireCondition(
		table.isfrozen(routeData.GeometrySplitLongitudinals),
		"GeometrySplitLongitudinals must be frozen"
	)
	requireCondition(
		routeData.GeometrySplitLongitudinals == GEOMETRY_SPLIT_LONGITUDINALS,
		"builder must use the configured geometry splits"
	)
	requireCondition(#routeData.SampledCenterlinePoints == EXPECTED_BASE_SAMPLES, "sampled point count mismatch")
	requireCondition(#routeData.GeometryPoints == EXPECTED_GEOMETRY_POINTS, "geometry point count mismatch")
	requireCondition(#routeData.GeometrySplitLongitudinals == 20, "geometry split count mismatch")
	requireCondition(
		isFiniteNumber(routeData.AuthoredPathLengthStuds)
			and math.abs(routeData.AuthoredPathLengthStuds - EXPECTED_AUTHORED_LENGTH) <= 0.01,
		"configured authored path length mismatch"
	)
	for index, point in ipairs(routeData.GeometryPoints) do
		requireCondition(table.isfrozen(point), string.format("GeometryPoints[%d] must be frozen", index))
		requireCondition(isFiniteVector3(point.LocalPosition), "geometry route point must be finite")
		validatePositiveFinite(point.TrackWidth, "geometry route TrackWidth")
		validatePositiveFinite(point.ClearPlayableWidth, "geometry route ClearPlayableWidth")
		requireCondition(
			point.ClearPlayableWidth <= point.TrackWidth,
			"geometry route clear width must fit inside track width"
		)
		if index > 1 then
			requireCondition(
				point.LocalPosition.Z > routeData.GeometryPoints[index - 1].LocalPosition.Z,
				"geometry route local Z must increase strictly"
			)
		end
	end

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

local function routeSampleAtLongitudinal(
	geometryPoints: { RouteGeometryPoint },
	longitudinal: number
): RouteSample
	requireCondition(isFiniteNumber(longitudinal), "route-content longitudinal must be finite")
	requireCondition(#geometryPoints >= 2, "route-content placement requires at least two geometry points")
	requireCondition(
		longitudinal >= geometryPoints[1].LocalPosition.Z
			and longitudinal <= geometryPoints[#geometryPoints].LocalPosition.Z,
		"route-content longitudinal is outside the authored geometry"
	)

	local low = 1
	local high = #geometryPoints
	while low < high do
		local midpoint = math.floor((low + high + 1) * 0.5)
		if geometryPoints[midpoint].LocalPosition.Z <= longitudinal then
			low = midpoint
		else
			high = midpoint - 1
		end
	end
	local segmentIndex = math.min(low, #geometryPoints - 1)
	local routePointA = geometryPoints[segmentIndex]
	local routePointB = geometryPoints[segmentIndex + 1]
	local pointA = routePointA.LocalPosition
	local pointB = routePointB.LocalPosition
	local localChord = pointB - pointA
	requireCondition(localChord.Magnitude > FrostTrailConfig.ValidationEpsilon, "route-content chord must be nonzero")
	requireCondition(localChord.Z > 0, "route-content chord must progress forward")
	local alpha = (longitudinal - pointA.Z) / (pointB.Z - pointA.Z)
	requireCondition(alpha >= 0 and alpha <= 1, "route-content interpolation alpha is invalid")
	local localCenter = pointA:Lerp(pointB, alpha)
	local worldA = localToWorldPoint(pointA)
	local worldB = localToWorldPoint(pointB)
	local worldChord = worldB - worldA
	requireCondition(worldChord.Magnitude > FrostTrailConfig.ValidationEpsilon, "route-content world chord must be nonzero")
	local worldCenter = localToWorldPoint(localCenter)
	local frame = CFrame.lookAt(worldCenter, worldCenter + worldChord.Unit, Vector3.yAxis)
	local trackWidth = routePointA.TrackWidth + (routePointB.TrackWidth - routePointA.TrackWidth) * alpha
	local clearPlayableWidth = routePointA.ClearPlayableWidth
		+ (routePointB.ClearPlayableWidth - routePointA.ClearPlayableWidth) * alpha
	requireCondition(
		isFiniteVector3(frame.Position)
			and isFiniteVector3(frame.RightVector)
			and isFiniteVector3(frame.UpVector)
			and isFiniteVector3(frame.LookVector),
		"route-content frame must be finite"
	)
	validatePositiveFinite(trackWidth, "route-content TrackWidth")
	validatePositiveFinite(clearPlayableWidth, "route-content ClearPlayableWidth")
	return {
		Frame = frame,
		TrackWidth = trackWidth,
		ClearPlayableWidth = clearPlayableWidth,
	}
end

local function coinFrameAtPlacement(geometryPoints: { RouteGeometryPoint }, placement: CoinPlacement): CFrame
	local sample = routeSampleAtLongitudinal(geometryPoints, placement.Longitudinal)
	return sample.Frame
		* CFrame.new(placement.LateralOffset, placement.HeightOffset, 0)
		* CFrame.Angles(0, math.rad(90), 0)
end

local function obstacleFrameAtPlacement(
	geometryPoints: { RouteGeometryPoint },
	placement: ObstaclePlacement,
	size: Vector3
): CFrame
	local sample = routeSampleAtLongitudinal(geometryPoints, placement.Longitudinal)
	return sample.Frame * CFrame.new(placement.LateralOffset, size.Y * 0.5, 0)
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
	requireCondition(
		math.abs(authoredLength - FrostTrailConfig.RouteData.AuthoredPathLengthStuds)
			<= FrostTrailConfig.ValidationEpsilon,
		"configured authored path length does not match its sampled centerline"
	)
	return authoredLength
end

local function validateGeometryPoints(geometryPoints: { RouteGeometryPoint })
	requireCondition(#geometryPoints == EXPECTED_GEOMETRY_POINTS, "geometry split must create exactly 75 points")
	for index = 1, #geometryPoints - 1 do
		local pointA = geometryPoints[index]
		local pointB = geometryPoints[index + 1]
		requireCondition(
			pointB.LocalPosition.Z > pointA.LocalPosition.Z,
			"split geometry path must progress positively"
		)
		requireCondition(
			(pointB.LocalPosition - pointA.LocalPosition).Magnitude > FrostTrailConfig.ValidationEpsilon,
			"split geometry chord must be nonzero"
		)
	end
	for _, requiredLongitudinal in ipairs(GEOMETRY_SPLIT_LONGITUDINALS) do
		local found = false
		for _, point in ipairs(geometryPoints) do
			if approximatelyEqual(
				point.LocalPosition.Z,
				requiredLongitudinal,
				FrostTrailConfig.ValidationEpsilon
			) then
				found = true
				break
			end
		end
		requireCondition(found, string.format("missing required geometry split at %.0f", requiredLongitudinal))
	end
	for _, taper in ipairs(FrostTrailConfig.TaperZones) do
		for index = 1, #geometryPoints - 1 do
			local overlapStart = math.max(geometryPoints[index].LocalPosition.Z, taper.StartLongitudinal)
			local overlapEnd = math.min(geometryPoints[index + 1].LocalPosition.Z, taper.EndLongitudinal)
			if overlapEnd > overlapStart then
				requireCondition(
					overlapEnd - overlapStart <= 25 + FrostTrailConfig.ValidationEpsilon,
					"taper geometry must be subdivided at no more than 25-stud intervals"
				)
			end
		end
	end
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

local function createSegmentPlans(geometryPoints: { RouteGeometryPoint }): { SegmentPlan }
	local plans: { SegmentPlan } = {}
	for index = 1, #geometryPoints - 1 do
		local routePointA = geometryPoints[index]
		local routePointB = geometryPoints[index + 1]
		local pointA = routePointA.LocalPosition
		local pointB = routePointB.LocalPosition
		local chord = pointB - pointA
		local trackWidth = math.max(routePointA.TrackWidth, routePointB.TrackWidth)
		local clearWidth = math.max(routePointA.ClearPlayableWidth, routePointB.ClearPlayableWidth)
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
			StartTrackWidth = routePointA.TrackWidth,
			EndTrackWidth = routePointB.TrackWidth,
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
			first.TrackWidth >= math.max(first.StartTrackWidth, first.EndTrackWidth),
			"track piece under-covers its endpoint width"
		)
		requireCondition(
			first.ClearWidth >= math.max(
				geometryPoints[index].ClearPlayableWidth,
				geometryPoints[index + 1].ClearPlayableWidth
			),
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

local function setCoinAttributes(part: Part, placement: CoinPlacement)
	part:SetAttribute("ContentId", placement.ContentId)
	part:SetAttribute("ContentKind", "Coin")
	part:SetAttribute("SectionId", placement.SectionId)
	part:SetAttribute("GroupId", placement.GroupId)
	part:SetAttribute("Pattern", placement.Pattern)
	part:SetAttribute("Longitudinal", placement.Longitudinal)
	part:SetAttribute("LateralOffset", placement.LateralOffset)
	part:SetAttribute("HeightOffset", placement.HeightOffset)
	part:SetAttribute("RuntimeEnabled", FrostTrailRouteContentConfig.RuntimeEnabled)
end

local function setObstacleAttributes(part: Part, placement: ObstaclePlacement)
	part:SetAttribute("ContentId", placement.ContentId)
	part:SetAttribute("ContentKind", "Obstacle")
	part:SetAttribute("SectionId", placement.SectionId)
	part:SetAttribute("EncounterId", placement.EncounterId)
	part:SetAttribute("ObstacleKind", placement.ObstacleKind)
	part:SetAttribute("Longitudinal", placement.Longitudinal)
	part:SetAttribute("LateralOffset", placement.LateralOffset)
	part:SetAttribute("RuntimeEnabled", FrostTrailRouteContentConfig.RuntimeEnabled)
end

local function buildRouteContent(gameplay: Folder, geometryPoints: { RouteGeometryPoint })
	local coins = createFolder(gameplay, "Coins")
	local obstacles = createFolder(gameplay, "Obstacles")
	for _, placement in ipairs(FrostTrailRouteContentConfig.CoinPlacements) do
		local coin = createPart(
			coins,
			placement.ContentId,
			FrostTrailRouteContentConfig.CoinSize,
			coinFrameAtPlacement(geometryPoints, placement),
			PALETTE.Gold,
			Enum.Material.Neon,
			false,
			false,
			false,
			0
		)
		coin.Shape = Enum.PartType.Cylinder
		coin.Reflectance = 0.05
		setCoinAttributes(coin, placement)
	end

	for _, placement in ipairs(FrostTrailRouteContentConfig.ObstaclePlacements) do
		local isIceBlocker = placement.ObstacleKind == "IceBlocker"
		local size = if isIceBlocker
			then FrostTrailRouteContentConfig.IceBlockerSize
			else FrostTrailRouteContentConfig.HopBarrierSize
		local obstacle = createPart(
			obstacles,
			placement.ContentId,
			size,
			obstacleFrameAtPlacement(geometryPoints, placement, size),
			if isIceBlocker then PALETTE.IceDeep else PALETTE.Red,
			if isIceBlocker then Enum.Material.Ice else Enum.Material.SmoothPlastic,
			false,
			false,
			true,
			if isIceBlocker then 0.05 else 0
		)
		obstacle.Shape = Enum.PartType.Block
		obstacle.Reflectance = if isIceBlocker then 0.1 else 0
		setObstacleAttributes(obstacle, placement)
	end
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
			local startOffset = side
				* (plan.StartTrackWidth * 0.5
					+ FrostTrailConfig.SnowBankWidth
					+ FrostTrailConfig.SafetyWallThickness * 0.5)
			local endOffset = side
				* (plan.EndTrackWidth * 0.5
					+ FrostTrailConfig.SnowBankWidth
					+ FrostTrailConfig.SafetyWallThickness * 0.5)
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
	launchEdge.CanTouch = true
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
		part.CanTouch = true
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
	requireCondition(#candidate:GetChildren() == 5, "candidate must have exactly five high-level folders")
	local geometry = directChild(candidate, "Geometry", "Folder") :: Folder
	local decor = directChild(candidate, "Decor", "Folder") :: Folder
	local markers = directChild(candidate, "Markers", "Folder") :: Folder
	local presentation = directChild(candidate, "Presentation", "Folder") :: Folder
	local gameplay = directChild(candidate, "Gameplay", "Folder") :: Folder
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
	requireCondition(#gameplay:GetChildren() == 2, "Gameplay must contain exactly Coins and Obstacles")
	local coins = directChild(gameplay, "Coins", "Folder") :: Folder
	local obstacles = directChild(gameplay, "Obstacles", "Folder") :: Folder
	requireCondition(#coins:GetChildren() == EXPECTED_COIN_COUNT, "Coins must contain exactly 160 direct Parts")
	requireCondition(#obstacles:GetChildren() == EXPECTED_OBSTACLE_COUNT, "Obstacles must contain exactly 21 direct Parts")
	for _, child in ipairs(coins:GetChildren()) do
		requireCondition(child.ClassName == "Part", "Coins may contain only primitive Parts")
		requireCondition(#child:GetChildren() == 0, "coin Parts may not contain descendants")
	end
	for _, child in ipairs(obstacles:GetChildren()) do
		requireCondition(child.ClassName == "Part", "Obstacles may contain only primitive Parts")
		requireCondition(#child:GetChildren() == 0, "obstacle Parts may not contain descendants")
	end
	requireCondition(candidate:FindFirstChild("ActiveSleds", true) == nil, "ActiveSleds must not be created")
	requireCondition(candidate:FindFirstChild("Leaderboards", true) == nil, "Leaderboards must not be created")
end

local function cframesApproximatelyEqual(actual: CFrame, expected: CFrame): boolean
	local epsilon = FrostTrailConfig.ValidationEpsilon * 10
	return (actual.Position - expected.Position).Magnitude <= epsilon
		and (actual.RightVector - expected.RightVector).Magnitude <= epsilon
		and (actual.UpVector - expected.UpVector).Magnitude <= epsilon
		and (actual.LookVector - expected.LookVector).Magnitude <= epsilon
end

local function validateExactAttributeNames(instance: Instance, expectedNames: { string })
	local attributes = instance:GetAttributes()
	requireCondition(tableEntryCount(attributes) == #expectedNames, instance.Name .. " attribute count mismatch")
	for _, attributeName in ipairs(expectedNames) do
		requireCondition(attributes[attributeName] ~= nil, instance.Name .. " is missing attribute " .. attributeName)
	end
end

local function directPartMap(folder: Folder, expectedCount: number): { [string]: Part }
	local parts: { [string]: Part } = {}
	local count = 0
	for _, child in ipairs(folder:GetChildren()) do
		requireCondition(child.ClassName == "Part", folder.Name .. " may contain only primitive Parts")
		requireCondition(parts[child.Name] == nil, folder.Name .. " contains duplicate Part name " .. child.Name)
		parts[child.Name] = child :: Part
		count += 1
	end
	requireCondition(count == expectedCount, folder.Name .. " direct Part count mismatch")
	return parts
end

local function validateContentSection(sectionId: string, longitudinal: number, contentId: string)
	local matchedSection = false
	for _, section in ipairs(FrostTrailConfig.Sections) do
		if section.SectionId == sectionId then
			matchedSection = true
			requireCondition(
				longitudinal >= section.StartLongitudinal and longitudinal <= section.EndLongitudinal,
				contentId .. " lies outside its declared section"
			)
			break
		end
	end
	requireCondition(matchedSection, contentId .. " references an unknown section")
end

local function validateContentFootprint(
	geometryPoints: { RouteGeometryPoint },
	longitudinal: number,
	lateralOffset: number,
	lateralHalfWidth: number,
	contentId: string
)
	local sample = routeSampleAtLongitudinal(geometryPoints, longitudinal)
	requireCondition(
		math.abs(lateralOffset) + lateralHalfWidth
			<= sample.ClearPlayableWidth * 0.5 + FrostTrailConfig.ValidationEpsilon,
		contentId .. " exceeds the clear playable width"
	)
	if approximatelyEqual(math.abs(lateralOffset), 42, FrostTrailConfig.ValidationEpsilon) then
		requireCondition(
			longitudinal >= 3150
				and longitudinal <= 3600
				and approximatelyEqual(
					sample.ClearPlayableWidth,
					FrostTrailConfig.WidenedClearPlayableWidth,
					FrostTrailConfig.ValidationEpsilon
				),
			contentId .. " uses an outer lane outside a fully widened zone"
		)
	else
		requireCondition(math.abs(lateralOffset) <= 24, contentId .. " uses an unsupported lane offset")
	end
	requireCondition(
		longitudinal < 6100 or longitudinal > 6350,
		contentId .. " enters the clear final launch interval"
	)
end

local function validateCommonContentPart(
	part: Part,
	expectedSize: Vector3,
	expectedCFrame: CFrame,
	expectedShadow: boolean
)
	requireCondition(
		part.Anchored
			and not part.CanCollide
			and not part.CanTouch
			and not part.CanQuery,
		part.Name .. " must remain static and inert"
	)
	requireCondition(part.CastShadow == expectedShadow, part.Name .. " shadow flag mismatch")
	requireCondition(part.Size == expectedSize, part.Name .. " size mismatch")
	requireCondition(
		isFiniteVector3(part.Size)
			and isFiniteVector3(part.CFrame.Position)
			and isFiniteVector3(part.CFrame.RightVector)
			and isFiniteVector3(part.CFrame.UpVector)
			and isFiniteVector3(part.CFrame.LookVector),
		part.Name .. " has a nonfinite size or CFrame"
	)
	requireCondition(cframesApproximatelyEqual(part.CFrame, expectedCFrame), part.Name .. " tangent CFrame mismatch")
	requireCondition(part:GetAttribute(TRACK_SURFACE_ATTRIBUTE) == nil, part.Name .. " may not be a track surface")
	requireCondition(part.TopSurface == Enum.SurfaceType.Smooth, part.Name .. " top surface mismatch")
	requireCondition(part.BottomSurface == Enum.SurfaceType.Smooth, part.Name .. " bottom surface mismatch")
end

local function validateObstaclePlacementSafety(
	part: Part,
	placement: ObstaclePlacement,
	geometryPoints: { RouteGeometryPoint }
)
	local halfLongitudinal = part.Size.Z * 0.5
	local footprintStart = placement.Longitudinal - halfLongitudinal
	local footprintEnd = placement.Longitudinal + halfLongitudinal
	for _, geometryPoint in ipairs(geometryPoints) do
		local seamDistance = math.abs(placement.Longitudinal - geometryPoint.LocalPosition.Z) - halfLongitudinal
		requireCondition(
			seamDistance >= 7 - FrostTrailConfig.ValidationEpsilon,
			placement.ContentId .. " is within seven studs of a geometry seam"
		)
	end
	for _, taper in ipairs(FrostTrailConfig.TaperZones) do
		requireCondition(
			footprintEnd <= taper.StartLongitudinal or footprintStart >= taper.EndLongitudinal,
			placement.ContentId .. " overlaps a track-width taper"
		)
	end

	local halfSize = part.Size * 0.5
	for _, xSign in ipairs({ -1, 1 }) do
		for _, zSign in ipairs({ -1, 1 }) do
			local bottomCorner = part.CFrame:PointToWorldSpace(Vector3.new(
				halfSize.X * xSign,
				-halfSize.Y,
				halfSize.Z * zSign
			))
			local cornerLocal = worldToLocalPoint(bottomCorner)
			local cornerSample = routeSampleAtLongitudinal(geometryPoints, cornerLocal.Z)
			local surfaceSeparation = math.abs((bottomCorner - cornerSample.Frame.Position):Dot(cornerSample.Frame.UpVector))
			requireCondition(
				surfaceSeparation <= 0.25 + FrostTrailConfig.ValidationEpsilon,
				placement.ContentId .. " floats or penetrates the route at a footprint corner"
			)
		end
	end
end

local function validateRouteContent(candidate: Model, geometryPoints: { RouteGeometryPoint })
	local gameplay = candidate.Gameplay :: Folder
	local coins = gameplay.Coins :: Folder
	local obstacles = gameplay.Obstacles :: Folder
	local coinParts = directPartMap(coins, EXPECTED_COIN_COUNT)
	local obstacleParts = directPartMap(obstacles, EXPECTED_OBSTACLE_COUNT)

	for _, placement in ipairs(FrostTrailRouteContentConfig.CoinPlacements) do
		local part = coinParts[placement.ContentId]
		requireCondition(part ~= nil, placement.ContentId .. " is missing from the runtime world")
		local expectedCFrame = coinFrameAtPlacement(geometryPoints, placement)
		validateCommonContentPart(part, FrostTrailRouteContentConfig.CoinSize, expectedCFrame, false)
		requireCondition(part.Parent == coins, placement.ContentId .. " must be a direct Coins child")
		requireCondition(part.Shape == Enum.PartType.Cylinder, placement.ContentId .. " must be a Cylinder")
		requireCondition(part.Material == Enum.Material.Neon, placement.ContentId .. " material mismatch")
		requireCondition(part.Color == PALETTE.Gold, placement.ContentId .. " color mismatch")
		requireCondition(part.Transparency == 0, placement.ContentId .. " transparency mismatch")
		requireCondition(
			approximatelyEqual(part.Reflectance, 0.05, FrostTrailConfig.ValidationEpsilon),
			placement.ContentId .. " reflectance mismatch"
		)
		validateExactAttributeNames(part, COIN_ATTRIBUTE_NAMES)
		requireCondition(part:GetAttribute("ContentId") == placement.ContentId, placement.ContentId .. " ContentId mismatch")
		requireCondition(part:GetAttribute("ContentKind") == "Coin", placement.ContentId .. " ContentKind mismatch")
		requireCondition(part:GetAttribute("SectionId") == placement.SectionId, placement.ContentId .. " SectionId mismatch")
		requireCondition(part:GetAttribute("GroupId") == placement.GroupId, placement.ContentId .. " GroupId mismatch")
		requireCondition(part:GetAttribute("Pattern") == placement.Pattern, placement.ContentId .. " Pattern mismatch")
		requireCondition(part:GetAttribute("Longitudinal") == placement.Longitudinal, placement.ContentId .. " Longitudinal mismatch")
		requireCondition(part:GetAttribute("LateralOffset") == placement.LateralOffset, placement.ContentId .. " LateralOffset mismatch")
		requireCondition(part:GetAttribute("HeightOffset") == placement.HeightOffset, placement.ContentId .. " HeightOffset mismatch")
		requireCondition(part:GetAttribute("RuntimeEnabled") == true, placement.ContentId .. " must be runtime-enabled")
		local routeSample = routeSampleAtLongitudinal(geometryPoints, placement.Longitudinal)
		requireCondition(
			math.abs(part.CFrame.RightVector:Dot(routeSample.Frame.LookVector)) >= 1 - FrostTrailConfig.ValidationEpsilon,
			placement.ContentId .. " cylinder face is not aligned to route travel"
		)
		validateContentSection(placement.SectionId, placement.Longitudinal, placement.ContentId)
		validateContentFootprint(
			geometryPoints,
			placement.Longitudinal,
			placement.LateralOffset,
			FrostTrailRouteContentConfig.CoinSize.Z * 0.5,
			placement.ContentId
		)
	end

	for _, placement in ipairs(FrostTrailRouteContentConfig.ObstaclePlacements) do
		local part = obstacleParts[placement.ContentId]
		requireCondition(part ~= nil, placement.ContentId .. " is missing from the runtime world")
		local isIceBlocker = placement.ObstacleKind == "IceBlocker"
		local expectedSize = if isIceBlocker
			then FrostTrailRouteContentConfig.IceBlockerSize
			else FrostTrailRouteContentConfig.HopBarrierSize
		local expectedCFrame = obstacleFrameAtPlacement(geometryPoints, placement, expectedSize)
		validateCommonContentPart(part, expectedSize, expectedCFrame, true)
		requireCondition(part.Parent == obstacles, placement.ContentId .. " must be a direct Obstacles child")
		requireCondition(part.Shape == Enum.PartType.Block, placement.ContentId .. " must be a Block")
		requireCondition(
			part.Material == (if isIceBlocker then Enum.Material.Ice else Enum.Material.SmoothPlastic),
			placement.ContentId .. " material mismatch"
		)
		requireCondition(
			part.Color == (if isIceBlocker then PALETTE.IceDeep else PALETTE.Red),
			placement.ContentId .. " color mismatch"
		)
		requireCondition(
			approximatelyEqual(
				part.Transparency,
				if isIceBlocker then 0.05 else 0,
				FrostTrailConfig.ValidationEpsilon
			),
			placement.ContentId .. " transparency mismatch"
		)
		requireCondition(
			approximatelyEqual(
				part.Reflectance,
				if isIceBlocker then 0.1 else 0,
				FrostTrailConfig.ValidationEpsilon
			),
			placement.ContentId .. " reflectance mismatch"
		)
		validateExactAttributeNames(part, OBSTACLE_ATTRIBUTE_NAMES)
		requireCondition(part:GetAttribute("ContentId") == placement.ContentId, placement.ContentId .. " ContentId mismatch")
		requireCondition(part:GetAttribute("ContentKind") == "Obstacle", placement.ContentId .. " ContentKind mismatch")
		requireCondition(part:GetAttribute("SectionId") == placement.SectionId, placement.ContentId .. " SectionId mismatch")
		requireCondition(part:GetAttribute("EncounterId") == placement.EncounterId, placement.ContentId .. " EncounterId mismatch")
		requireCondition(part:GetAttribute("ObstacleKind") == placement.ObstacleKind, placement.ContentId .. " ObstacleKind mismatch")
		requireCondition(part:GetAttribute("Longitudinal") == placement.Longitudinal, placement.ContentId .. " Longitudinal mismatch")
		requireCondition(part:GetAttribute("LateralOffset") == placement.LateralOffset, placement.ContentId .. " LateralOffset mismatch")
		requireCondition(part:GetAttribute("RuntimeEnabled") == true, placement.ContentId .. " must be runtime-enabled")
		validateContentSection(placement.SectionId, placement.Longitudinal, placement.ContentId)
		validateContentFootprint(
			geometryPoints,
			placement.Longitudinal,
			placement.LateralOffset,
			expectedSize.X * 0.5,
			placement.ContentId
		)
		validateObstaclePlacementSafety(part, placement, geometryPoints)
	end

	requireCondition(#collectBaseParts(gameplay) == EXPECTED_GAMEPLAY_PART_COUNT, "Gameplay must contain exactly 181 BaseParts")
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
				and not marker.CanQuery
				and not marker.CastShadow
				and marker.Transparency == 1,
			"authoring marker flags mismatch"
		)
	end
	requireCondition(not startTrigger.CanTouch, "StartTrigger must remain non-touchable")
	requireCondition(launchEdge.CanTouch, "LaunchEdge must be touchable")
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
		requireCondition(part.Anchored and part.CanCollide and part.CanQuery and part.CanTouch, "landing part flags mismatch")
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
	local geometry = candidate.Geometry :: Folder
	local markers = candidate.Markers :: Folder
	local lake = geometry.FrostTrailLake :: Folder
	local allowedTouchableParts: { [BasePart]: boolean } = {
		[markers.LaunchEdge :: BasePart] = true,
		[lake.FrostTrailLakeMarked_0000m_1500m :: BasePart] = true,
		[lake.FrostTrailLakeRunoff_1500m_1800m :: BasePart] = true,
	}
	table.freeze(allowedTouchableParts)
	local basePartCount = 0
	local collidableCount = 0
	local shadowCount = 0
	local touchableCount = 0
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
			if descendant.CanTouch then
				touchableCount += 1
				requireCondition(
					allowedTouchableParts[descendant] == true,
					descendant.Name .. " is not an allowed touch detector"
				)
			end
			if descendant.CanCollide then
				collidableCount += 1
			end
			if descendant.CastShadow then
				shadowCount += 1
			end
		end
	end
	requireCondition(basePartCount == EXPECTED_BASE_PART_COUNT, "BasePart count must equal the authored 628")
	requireCondition(basePartCount <= 650, "BasePart budget exceeded")
	requireCondition(collidableCount == EXPECTED_COLLIDABLE_COUNT, "collidable count must equal the authored 229")
	requireCondition(collidableCount <= 230, "collidable-part budget exceeded")
	requireCondition(shadowCount == EXPECTED_SHADOW_COUNT, "shadow count must equal the authored 89")
	requireCondition(shadowCount <= 170, "shadow-caster budget exceeded")
	requireCondition(touchableCount == 3, "exactly LaunchEdge and two lake parts must be touchable")
	for part in allowedTouchableParts do
		requireCondition(part.CanTouch, part.Name .. " must remain touchable")
	end
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
	requireCondition(candidate:GetAttribute("StaticFoundationOnly") == false, "static attribute mismatch")
	requireCondition(candidate:GetAttribute("Playable") == false, "playable attribute mismatch")
	requireCondition(
		candidate:GetAttribute("ActivationMode") == "StudioControlledTest",
		"activation-mode attribute mismatch"
	)
	requireCondition(candidate:GetAttribute("ForwardX") == 0, "ForwardX attribute mismatch")
	requireCondition(candidate:GetAttribute("ForwardY") == 0, "ForwardY attribute mismatch")
	requireCondition(candidate:GetAttribute("ForwardZ") == 1, "ForwardZ attribute mismatch")
	requireCondition(candidate:GetAttribute("OriginX") == 3200, "OriginX attribute mismatch")
	requireCondition(candidate:GetAttribute("OriginY") == 0, "OriginY attribute mismatch")
	requireCondition(candidate:GetAttribute("OriginZ") == 0, "OriginZ attribute mismatch")
	requireCondition(candidate:GetAttribute("TrackStartLongitudinal") == -250, "track-start attribute mismatch")
	requireCondition(candidate:GetAttribute("LaunchLongitudinal") == 6350, "launch attribute mismatch")
	requireCondition(candidate:GetAttribute("RouteContentVersion") == 1, "route-content version attribute mismatch")
	requireCondition(
		candidate:GetAttribute("RouteContentRuntimeEnabled") == true,
		"route-content runtime attribute mismatch"
	)
	requireCondition(
		candidate:GetAttribute("RouteContentRuntimeVersion") == 1,
		"route-content runtime-version attribute mismatch"
	)
	requireCondition(candidate:GetAttribute("RouteCoinCount") == 160, "route coin-count attribute mismatch")
	requireCondition(candidate:GetAttribute("RouteObstacleCount") == 21, "route obstacle-count attribute mismatch")
	requireCondition(candidate:GetAttribute("RouteObstacleRowCount") == 18, "route row-count attribute mismatch")
	requireCondition(candidate:GetAttribute("RouteGameplayPartCount") == 181, "route gameplay-count attribute mismatch")
	requireCondition(candidate:GetAttribute("BasePartCount") == 628, "route-content BasePartCount attribute mismatch")
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

local function validateCandidate(
	candidate: Model,
	sampled: { Vector3 },
	geometryPoints: { RouteGeometryPoint },
	plans: { SegmentPlan },
	authoredLength: number
)
	validateHierarchy(candidate)
	validateTrackAndSafety(candidate, plans)
	validateSummitAndMarkers(candidate, sampled)
	validateLake(candidate)
	validateRouteContent(candidate, geometryPoints)
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
	candidate:SetAttribute("ActivationMode", FrostTrailConfig.ActivationMode)
	candidate:SetAttribute("ForwardX", FrostTrailConfig.ForwardDirection.X)
	candidate:SetAttribute("ForwardY", FrostTrailConfig.ForwardDirection.Y)
	candidate:SetAttribute("ForwardZ", FrostTrailConfig.ForwardDirection.Z)
	candidate:SetAttribute("OriginX", FrostTrailConfig.WorldOrigin.X)
	candidate:SetAttribute("OriginY", FrostTrailConfig.WorldOrigin.Y)
	candidate:SetAttribute("OriginZ", FrostTrailConfig.WorldOrigin.Z)
	candidate:SetAttribute("TrackStartLongitudinal", FrostTrailConfig.PathPoints[1].Z)
	candidate:SetAttribute("LaunchLongitudinal", FrostTrailConfig.PathPoints[#FrostTrailConfig.PathPoints].Z)
	candidate:SetAttribute("AuthoredPathLengthStuds", authoredLength)
	candidate:SetAttribute("RouteContentVersion", FrostTrailRouteContentConfig.ContentVersion)
	candidate:SetAttribute("RouteContentRuntimeEnabled", FrostTrailRouteContentConfig.RuntimeEnabled)
	candidate:SetAttribute("RouteContentRuntimeVersion", FrostTrailRouteContentConfig.RuntimeVersion)
	candidate:SetAttribute("RouteCoinCount", #FrostTrailRouteContentConfig.CoinPlacements)
	candidate:SetAttribute("RouteObstacleCount", #FrostTrailRouteContentConfig.ObstaclePlacements)
	candidate:SetAttribute("RouteObstacleRowCount", #FrostTrailRouteContentConfig.ObstacleRows)
	candidate:SetAttribute(
		"RouteGameplayPartCount",
		#FrostTrailRouteContentConfig.CoinPlacements + #FrostTrailRouteContentConfig.ObstaclePlacements
	)
	candidate:SetAttribute("BasePartCount", #collectBaseParts(candidate))
end

local function constructCandidate(candidate: Model)
	validateConfiguration()
	validateRouteContentConfiguration()
	local routeData = FrostTrailConfig.RouteData
	local sampled = routeData.SampledCenterlinePoints
	local authoredLength = validateAndMeasureSampledPath(sampled)
	local geometryPoints = routeData.GeometryPoints
	validateGeometryPoints(geometryPoints)
	local plans = createSegmentPlans(geometryPoints)

	local geometry = createFolder(candidate, "Geometry")
	local decor = createFolder(candidate, "Decor")
	local markers = createFolder(candidate, "Markers")
	createFolder(candidate, "Presentation")
	local gameplay = createFolder(candidate, "Gameplay")
	local track = createFolder(geometry, "Track")
	local safety = createFolder(geometry, "Safety")

	buildTrack(track, safety, plans)
	buildSummit(geometry, safety)
	buildLandingLake(geometry)
	buildMarkers(markers, sampled)
	buildDecor(decor, sampled)
	buildRouteContent(gameplay, geometryPoints)
	setWorldAttributes(candidate, authoredLength)
	validateCandidate(candidate, sampled, geometryPoints, plans, authoredLength)
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
