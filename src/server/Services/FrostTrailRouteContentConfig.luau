--!strict

export type CoinPattern = "Line" | "Sweep" | "Parallel" | "Arc"

export type CoinPlacement = {
	ContentId: string,
	SectionId: string,
	GroupId: string,
	Pattern: CoinPattern,
	Longitudinal: number,
	LateralOffset: number,
	HeightOffset: number,
}

export type ObstacleKind = "IceBlocker" | "HopBarrier"

export type ObstacleRowDefinition = {
	EncounterId: string,
	SectionId: string,
	Longitudinal: number,
	ObstacleKind: ObstacleKind,
	LaneOffsets: { number },
}

export type ObstaclePlacement = {
	ContentId: string,
	SectionId: string,
	EncounterId: string,
	ObstacleKind: ObstacleKind,
	Longitudinal: number,
	LateralOffset: number,
}

export type FrostTrailRouteContentConfig = {
	CourseId: string,
	ContentVersion: number,
	RuntimeEnabled: boolean,
	GroundCoinHeight: number,
	CoinSize: Vector3,
	IceBlockerSize: Vector3,
	HopBarrierSize: Vector3,
	CoinPlacements: { CoinPlacement },
	ObstacleRows: { ObstacleRowDefinition },
	ObstaclePlacements: { ObstaclePlacement },
}

type CoinGroupDefinition = {
	GroupId: string,
	SectionId: string,
	Pattern: CoinPattern,
	Count: number,
	StartLongitudinal: number,
	EndLongitudinal: number,
	LaneOffsets: { number },
	HeightOffsets: { number },
}

local GROUND_COIN_HEIGHT = 3.5
local COIN_SIZE = Vector3.new(0.75, 3.6, 3.6)
local ICE_BLOCKER_SIZE = Vector3.new(12, 6, 5)
local HOP_BARRIER_SIZE = Vector3.new(16, 3, 3)

local function frozenNumberList(values: { number }): { number }
	return table.freeze(values)
end

local function coinGroup(
	groupId: string,
	sectionId: string,
	pattern: CoinPattern,
	count: number,
	startLongitudinal: number,
	endLongitudinal: number,
	laneOffsets: { number },
	heightOffsets: { number }
): CoinGroupDefinition
	local definition: CoinGroupDefinition = {
		GroupId = groupId,
		SectionId = sectionId,
		Pattern = pattern,
		Count = count,
		StartLongitudinal = startLongitudinal,
		EndLongitudinal = endLongitudinal,
		LaneOffsets = frozenNumberList(laneOffsets),
		HeightOffsets = frozenNumberList(heightOffsets),
	}
	return table.freeze(definition)
end

local coinGroups: { CoinGroupDefinition } = {
	coinGroup("SC01", "SummitCamp", "Line", 6, -160, 40, { 0 }, { 3.5 }),
	coinGroup("SC02", "SummitCamp", "Sweep", 5, 100, 260, { 0, -24 }, { 3.5 }),
	coinGroup("SC03", "SummitCamp", "Arc", 3, 388, 412, { 0 }, { 3.5, 8.5, 3.5 }),
	coinGroup("PS01", "PineSlalom", "Parallel", 10, 520, 680, { -24, 24 }, { 3.5 }),
	coinGroup("PS02", "PineSlalom", "Line", 7, 760, 1180, { -24 }, { 3.5 }),
	coinGroup("PS03", "PineSlalom", "Arc", 5, 1264, 1296, { 0 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	coinGroup("CC01", "CrystalCave", "Parallel", 8, 1400, 1550, { -24, 24 }, { 3.5 }),
	coinGroup("CC02", "CrystalCave", "Line", 4, 1630, 1810, { 24 }, { 3.5 }),
	coinGroup("CC03", "CrystalCave", "Line", 3, 1880, 2000, { 0 }, { 3.5 }),
	coinGroup("CC04", "CrystalCave", "Arc", 5, 2094, 2126, { 24 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	coinGroup("GB01", "GlacierBridge", "Line", 4, 2270, 2450, { 0 }, { 3.5 }),
	coinGroup("GB02", "GlacierBridge", "Parallel", 8, 2520, 2700, { -24, 24 }, { 3.5 }),
	coinGroup("GB03", "GlacierBridge", "Line", 3, 2770, 2890, { 24 }, { 3.5 }),
	coinGroup("GB04", "GlacierBridge", "Arc", 3, 2928, 2952, { -24 }, { 3.5, 8.5, 3.5 }),
	coinGroup("AP01", "AvalanchePass", "Line", 3, 3040, 3160, { 0 }, { 3.5 }),
	coinGroup("AP02", "AvalanchePass", "Parallel", 10, 3200, 3440, { -42, 42 }, { 3.5 }),
	coinGroup("AP03", "AvalanchePass", "Arc", 5, 3442, 3498, { 0 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	coinGroup("AP04", "AvalanchePass", "Parallel", 6, 3510, 3710, { -24, 24 }, { 3.5 }),
	coinGroup("FV01", "FrozenVillage", "Parallel", 8, 3860, 4070, { -24, 24 }, { 3.5 }),
	coinGroup("FV02", "FrozenVillage", "Line", 5, 4150, 4350, { 24 }, { 3.5 }),
	coinGroup("FV03", "FrozenVillage", "Arc", 5, 4364, 4396, { -24 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	coinGroup("FV04", "FrozenVillage", "Parallel", 4, 4540, 4640, { -24, 24 }, { 3.5 }),
	coinGroup("FR01", "FrozenRiver", "Parallel", 6, 4700, 4800, { -24, 24 }, { 3.5 }),
	coinGroup("FR02", "FrozenRiver", "Line", 4, 4870, 5050, { 24 }, { 3.5 }),
	coinGroup("FR03", "FrozenRiver", "Arc", 5, 5084, 5116, { 0 }, { 3.5, 6.25, 8.5, 6.25, 3.5 }),
	coinGroup("FR04", "FrozenRiver", "Line", 5, 5160, 5360, { 24 }, { 3.5 }),
	coinGroup("FR05", "FrozenRiver", "Sweep", 4, 5430, 5550, { 24, 0 }, { 3.5 }),
	coinGroup("AC01", "AlpineChute", "Line", 3, 5580, 5660, { 24 }, { 3.5 }),
	coinGroup("AC02", "AlpineChute", "Sweep", 5, 5700, 5860, { 24, 0 }, { 3.5 }),
	coinGroup("AC03", "AlpineChute", "Arc", 3, 5896, 5944, { 0 }, { 3.5, 8.5, 3.5 }),
	coinGroup("AC04", "AlpineChute", "Line", 5, 5980, 6060, { 0 }, { 3.5 }),
}
table.freeze(coinGroups)

local function inclusiveValue(startValue: number, endValue: number, index: number, count: number): number
	if count == 1 then
		return startValue
	end
	return startValue + (endValue - startValue) * ((index - 1) / (count - 1))
end

local coinPlacements: { CoinPlacement } = {}

local function appendCoinPlacement(
	group: CoinGroupDefinition,
	longitudinal: number,
	lateralOffset: number,
	heightOffset: number
)
	local placement: CoinPlacement = {
		ContentId = string.format("FrostCoin_%03d", #coinPlacements + 1),
		SectionId = group.SectionId,
		GroupId = group.GroupId,
		Pattern = group.Pattern,
		Longitudinal = longitudinal,
		LateralOffset = lateralOffset,
		HeightOffset = heightOffset,
	}
	table.freeze(placement)
	table.insert(coinPlacements, placement)
end

for _, group in ipairs(coinGroups) do
	assert(group.Count > 0 and group.Count == math.floor(group.Count), `Invalid coin count for {group.GroupId}`)
	if group.Pattern == "Line" then
		assert(#group.LaneOffsets == 1 and #group.HeightOffsets == 1, `Invalid Line group {group.GroupId}`)
		for index = 1, group.Count do
			appendCoinPlacement(
				group,
				inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, index, group.Count),
				group.LaneOffsets[1],
				group.HeightOffsets[1]
			)
		end
	elseif group.Pattern == "Sweep" then
		assert(#group.LaneOffsets == 2 and #group.HeightOffsets == 1, `Invalid Sweep group {group.GroupId}`)
		for index = 1, group.Count do
			appendCoinPlacement(
				group,
				inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, index, group.Count),
				inclusiveValue(group.LaneOffsets[1], group.LaneOffsets[2], index, group.Count),
				group.HeightOffsets[1]
			)
		end
	elseif group.Pattern == "Parallel" then
		assert(
			group.Count % 2 == 0 and #group.LaneOffsets == 2 and #group.HeightOffsets == 1,
			`Invalid Parallel group {group.GroupId}`
		)
		local coinsPerLane = group.Count / 2
		local lowerLane = math.min(group.LaneOffsets[1], group.LaneOffsets[2])
		local upperLane = math.max(group.LaneOffsets[1], group.LaneOffsets[2])
		for index = 1, coinsPerLane do
			appendCoinPlacement(
				group,
				inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, index, coinsPerLane),
				lowerLane,
				group.HeightOffsets[1]
			)
		end
		for index = 1, coinsPerLane do
			appendCoinPlacement(
				group,
				inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, index, coinsPerLane),
				upperLane,
				group.HeightOffsets[1]
			)
		end
	else
		assert(
			#group.LaneOffsets == 1 and #group.HeightOffsets == group.Count,
			`Invalid Arc group {group.GroupId}`
		)
		for index = 1, group.Count do
			appendCoinPlacement(
				group,
				inclusiveValue(group.StartLongitudinal, group.EndLongitudinal, index, group.Count),
				group.LaneOffsets[1],
				group.HeightOffsets[index]
			)
		end
	end
end

assert(#coinGroups == 31, "Frost Trail route content must define exactly 31 coin groups")
assert(#coinPlacements == 160, "Frost Trail route content must expand to exactly 160 coins")
table.freeze(coinPlacements)

local function obstacleRow(
	encounterId: string,
	sectionId: string,
	longitudinal: number,
	obstacleKind: ObstacleKind,
	laneOffsets: { number }
): ObstacleRowDefinition
	local definition: ObstacleRowDefinition = {
		EncounterId = encounterId,
		SectionId = sectionId,
		Longitudinal = longitudinal,
		ObstacleKind = obstacleKind,
		LaneOffsets = frozenNumberList(laneOffsets),
	}
	return table.freeze(definition)
end

local obstacleRows: { ObstacleRowDefinition } = {
	obstacleRow("FrostRow_01", "SummitCamp", 400, "HopBarrier", { 0 }),
	obstacleRow("FrostRow_02", "PineSlalom", 720, "IceBlocker", { 0 }),
	obstacleRow("FrostRow_03", "PineSlalom", 1040, "IceBlocker", { 24 }),
	obstacleRow("FrostRow_04", "PineSlalom", 1280, "HopBarrier", { 0 }),
	obstacleRow("FrostRow_05", "CrystalCave", 1600, "IceBlocker", { 0 }),
	obstacleRow("FrostRow_06", "CrystalCave", 1840, "IceBlocker", { -24 }),
	obstacleRow("FrostRow_07", "CrystalCave", 2110, "HopBarrier", { 24 }),
	obstacleRow("FrostRow_08", "GlacierBridge", 2460, "IceBlocker", { -24, 24 }),
	obstacleRow("FrostRow_09", "GlacierBridge", 2720, "IceBlocker", { 0 }),
	obstacleRow("FrostRow_10", "GlacierBridge", 2940, "HopBarrier", { -24 }),
	obstacleRow("FrostRow_11", "AvalanchePass", 3300, "IceBlocker", { -24, 24 }),
	obstacleRow("FrostRow_12", "AvalanchePass", 3470, "HopBarrier", { 0 }),
	obstacleRow("FrostRow_13", "AvalanchePass", 3740, "IceBlocker", { 0 }),
	obstacleRow("FrostRow_14", "FrozenVillage", 4110, "IceBlocker", { 0 }),
	obstacleRow("FrostRow_15", "FrozenVillage", 4380, "HopBarrier", { -24 }),
	obstacleRow("FrostRow_16", "FrozenRiver", 4820, "IceBlocker", { 0 }),
	obstacleRow("FrostRow_17", "FrozenRiver", 5100, "HopBarrier", { 0 }),
	obstacleRow("FrostRow_18", "FrozenRiver", 5390, "IceBlocker", { -24, 0 }),
}
table.freeze(obstacleRows)

local obstaclePlacements: { ObstaclePlacement } = {}
local iceBlockerCount = 0
local hopBarrierCount = 0

local function appendObstaclePlacement(row: ObstacleRowDefinition, lateralOffset: number)
	local placement: ObstaclePlacement = {
		ContentId = string.format("FrostObstacle_%03d", #obstaclePlacements + 1),
		SectionId = row.SectionId,
		EncounterId = row.EncounterId,
		ObstacleKind = row.ObstacleKind,
		Longitudinal = row.Longitudinal,
		LateralOffset = lateralOffset,
	}
	table.freeze(placement)
	table.insert(obstaclePlacements, placement)
	if row.ObstacleKind == "IceBlocker" then
		iceBlockerCount += 1
	else
		hopBarrierCount += 1
	end
end

for _, row in ipairs(obstacleRows) do
	assert(#row.LaneOffsets == 1 or #row.LaneOffsets == 2, `Invalid obstacle row {row.EncounterId}`)
	if #row.LaneOffsets == 1 then
		appendObstaclePlacement(row, row.LaneOffsets[1])
	else
		appendObstaclePlacement(row, math.min(row.LaneOffsets[1], row.LaneOffsets[2]))
		appendObstaclePlacement(row, math.max(row.LaneOffsets[1], row.LaneOffsets[2]))
	end
end

assert(#obstacleRows == 18, "Frost Trail route content must define exactly 18 obstacle rows")
assert(#obstaclePlacements == 21, "Frost Trail route content must expand to exactly 21 obstacles")
assert(iceBlockerCount == 14, "Frost Trail route content must contain exactly 14 ice blockers")
assert(hopBarrierCount == 7, "Frost Trail route content must contain exactly 7 hop barriers")
table.freeze(obstaclePlacements)

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

for _, placement in ipairs(coinPlacements) do
	assert(
		isFinite(placement.Longitudinal)
			and isFinite(placement.LateralOffset)
			and isFinite(placement.HeightOffset),
		`Non-finite coin placement {placement.ContentId}`
	)
end

for _, row in ipairs(obstacleRows) do
	assert(isFinite(row.Longitudinal), `Non-finite obstacle row {row.EncounterId}`)
	for _, lateralOffset in ipairs(row.LaneOffsets) do
		assert(isFinite(lateralOffset), `Non-finite obstacle lane in {row.EncounterId}`)
	end
end

local config: FrostTrailRouteContentConfig = {
	CourseId = "FrostTrailV1",
	ContentVersion = 1,
	RuntimeEnabled = false,
	GroundCoinHeight = GROUND_COIN_HEIGHT,
	CoinSize = COIN_SIZE,
	IceBlockerSize = ICE_BLOCKER_SIZE,
	HopBarrierSize = HOP_BARRIER_SIZE,
	CoinPlacements = coinPlacements,
	ObstacleRows = obstacleRows,
	ObstaclePlacements = obstaclePlacements,
}

return table.freeze(config)
