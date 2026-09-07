--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AudioController = require(script.Parent.AudioController)

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local ROUTE_REMOTE_NAME = "FrostTrailContentEvent"
local FROST_WORLD_NAME = "FrostTrailWorld"
local PRESENTATION_COURSE_ATTRIBUTE = "FrostlinePresentationCourseId"
local COURSE_ID = "FrostTrailV1"
local PROTOCOL_VERSION = 1
local MAXIMUM_ROUTE_COINS = 160
local MAXIMUM_OBSTACLE_HITS = 18
local MAXIMUM_DELTA_ENTRIES = 24
local STARTUP_TIMEOUT_SECONDS = 5
local OBSTACLE_FEEDBACK_SECONDS = 0.65

type ObstacleKind = "IceBlocker" | "HopBarrier"

type ObstacleExpectation = {
	EncounterId: string,
	ObstacleKind: ObstacleKind,
}

type RuntimeReferences = {
	PlayerGui: PlayerGui,
	RunHud: ScreenGui,
	StatusPanel: Frame,
}

type StreamedContentFolders = {
	World: Model,
	Gameplay: Folder,
	Coins: Folder?,
	Obstacles: Folder?,
}

type PresentationState = {
	RunId: number,
	LastSequence: number,
	RouteCoinsCollected: number,
	ObstacleHits: number,
	AcceptedContentIds: { [string]: boolean },
	CollectedCoinIds: { [string]: boolean },
	ResolvedEncounterIds: { [string]: boolean },
	Sealed: boolean,
	Invalidated: boolean,
	FailedClosed: boolean,
}

local function frozenObstacle(encounterId: string, obstacleKind: ObstacleKind): ObstacleExpectation
	return table.freeze({
		EncounterId = encounterId,
		ObstacleKind = obstacleKind,
	})
end

local OBSTACLE_EXPECTATIONS: { [string]: ObstacleExpectation } = table.freeze({
	FrostObstacle_001 = frozenObstacle("FrostRow_01", "HopBarrier"),
	FrostObstacle_002 = frozenObstacle("FrostRow_02", "IceBlocker"),
	FrostObstacle_003 = frozenObstacle("FrostRow_03", "IceBlocker"),
	FrostObstacle_004 = frozenObstacle("FrostRow_04", "HopBarrier"),
	FrostObstacle_005 = frozenObstacle("FrostRow_05", "IceBlocker"),
	FrostObstacle_006 = frozenObstacle("FrostRow_06", "IceBlocker"),
	FrostObstacle_007 = frozenObstacle("FrostRow_07", "HopBarrier"),
	FrostObstacle_008 = frozenObstacle("FrostRow_08", "IceBlocker"),
	FrostObstacle_009 = frozenObstacle("FrostRow_08", "IceBlocker"),
	FrostObstacle_010 = frozenObstacle("FrostRow_09", "IceBlocker"),
	FrostObstacle_011 = frozenObstacle("FrostRow_10", "HopBarrier"),
	FrostObstacle_012 = frozenObstacle("FrostRow_11", "IceBlocker"),
	FrostObstacle_013 = frozenObstacle("FrostRow_11", "IceBlocker"),
	FrostObstacle_014 = frozenObstacle("FrostRow_12", "HopBarrier"),
	FrostObstacle_015 = frozenObstacle("FrostRow_13", "IceBlocker"),
	FrostObstacle_016 = frozenObstacle("FrostRow_14", "IceBlocker"),
	FrostObstacle_017 = frozenObstacle("FrostRow_15", "HopBarrier"),
	FrostObstacle_018 = frozenObstacle("FrostRow_16", "IceBlocker"),
	FrostObstacle_019 = frozenObstacle("FrostRow_17", "HopBarrier"),
	FrostObstacle_020 = frozenObstacle("FrostRow_18", "IceBlocker"),
	FrostObstacle_021 = frozenObstacle("FrostRow_18", "IceBlocker"),
})

local PACKET_KEYS: { [string]: boolean } = table.freeze({
	Version = true,
	CourseId = true,
	RunId = true,
	EventSequence = true,
	EventKind = true,
	Entries = true,
	RouteCoinsCollected = true,
	ObstacleHits = true,
	Invalidated = true,
})

local COIN_ENTRY_KEYS: { [string]: boolean } = table.freeze({
	Kind = true,
	ContentId = true,
})

local OBSTACLE_ENTRY_KEYS: { [string]: boolean } = table.freeze({
	Kind = true,
	ContentId = true,
	EncounterId = true,
	ObstacleKind = true,
	SpeedLoss = true,
})

local FrostTrailRouteContentController = {}

local started = false
local runtimeReferences: RuntimeReferences? = nil
local routeConnection: RBXScriptConnection? = nil
local routeLabel: TextLabel? = nil
local currentState: PresentationState? = nil
local latestRunId = 0
local hiddenCoinModifiers: { [Part]: number } = {}
local activeFlashPart: Part? = nil
local activeFlashOriginalModifier: number? = nil
local feedbackGeneration = 0

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isIntegerInRange(value: any, minimum: number, maximum: number): boolean
	return isFiniteNumber(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function hasExactKeys(value: { [any]: any }, expected: { [string]: boolean }): boolean
	local count = 0
	for key in value do
		if typeof(key) ~= "string" or expected[key] ~= true then
			return false
		end
		count += 1
	end

	local expectedCount = 0
	for _ in expected do
		expectedCount += 1
	end
	return count == expectedCount
end

local function denseArrayLength(value: any, maximum: number): number?
	if typeof(value) ~= "table" then
		return nil
	end

	local count = 0
	for key in value do
		if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximum then
			return nil
		end
		count += 1
	end
	if count ~= #value or count > maximum then
		return nil
	end
	for index = 1, count do
		if value[index] == nil then
			return nil
		end
	end
	return count
end

local function isKnownCoinId(contentId: any): boolean
	if typeof(contentId) ~= "string" then
		return false
	end
	local digits = string.match(contentId, "^FrostCoin_(%d%d%d)$")
	if digits == nil then
		return false
	end
	local index = tonumber(digits)
	return index ~= nil
		and index >= 1
		and index <= MAXIMUM_ROUTE_COINS
		and contentId == string.format("FrostCoin_%03d", index)
end

local function remainingTime(deadline: number): number
	return math.max(0, deadline - os.clock())
end

local function waitForUniqueDirectChild(
	parent: Instance,
	name: string,
	className: string,
	deadline: number
): Instance
	local child = parent:FindFirstChild(name)
	if child == nil then
		local remaining = remainingTime(deadline)
		if remaining <= 0 then
			error(string.format("timed out waiting for %s/%s", parent:GetFullName(), name), 0)
		end
		child = parent:WaitForChild(name, remaining)
	end
	if child == nil then
		error(string.format("timed out waiting for %s/%s", parent:GetFullName(), name), 0)
	end

	local matchingChildren = 0
	for _, candidate in ipairs(parent:GetChildren()) do
		if candidate.Name == name then
			matchingChildren += 1
		end
	end
	if matchingChildren ~= 1 or child.Parent ~= parent or child.ClassName ~= className then
		error(string.format("%s/%s must be one direct %s", parent:GetFullName(), name, className), 0)
	end
	return child
end

local function isUniqueDirectChild(parent: Instance, name: string, expected: Instance): boolean
	local matchingChildren = 0
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			matchingChildren += 1
		end
	end
	return matchingChildren == 1 and expected.Parent == parent and parent:FindFirstChild(name) == expected
end

local function findUniqueDirectChild(parent: Instance, name: string, className: string): Instance?
	local child = parent:FindFirstChild(name)
	if child == nil or child.ClassName ~= className or not isUniqueDirectChild(parent, name, child) then
		return nil
	end
	return child
end

local function resolveStreamedContentFolders(): StreamedContentFolders?
	local worldInstance = findUniqueDirectChild(Workspace, FROST_WORLD_NAME, "Model")
	if worldInstance == nil then
		return nil
	end
	local world = worldInstance :: Model
	if world:GetAttribute("CourseId") ~= COURSE_ID
		or world:GetAttribute("RouteContentRuntimeEnabled") ~= true
		or world:GetAttribute("RouteContentRuntimeVersion") ~= PROTOCOL_VERSION
	then
		return nil
	end

	local gameplayInstance = findUniqueDirectChild(world, "Gameplay", "Folder")
	if gameplayInstance == nil then
		return nil
	end
	local gameplay = gameplayInstance :: Folder
	local coinsInstance = findUniqueDirectChild(gameplay, "Coins", "Folder")
	local obstaclesInstance = findUniqueDirectChild(gameplay, "Obstacles", "Folder")
	return {
		World = world,
		Gameplay = gameplay,
		Coins = if coinsInstance ~= nil then coinsInstance :: Folder else nil,
		Obstacles = if obstaclesInstance ~= nil then obstaclesInstance :: Folder else nil,
	}
end

local function resolveStreamedCoinPart(folders: StreamedContentFolders, contentId: string): Part?
	local coins = folders.Coins
	if coins == nil then
		return nil
	end
	local instance = findUniqueDirectChild(coins, contentId, "Part")
	if instance == nil then
		return nil
	end
	local part = instance :: Part
	if part.Parent ~= coins then
		return nil
	end
	if part.Name ~= contentId
		or not part.Anchored
		or part.CanCollide
		or part.CanTouch
		or part.CanQuery
		or part.CastShadow
		or part:GetAttribute("ContentId") ~= contentId
		or part:GetAttribute("ContentKind") ~= "Coin"
		or part:GetAttribute("RuntimeEnabled") ~= true
	then
		return nil
	end
	return part
end

local function resolveStreamedObstaclePart(
	folders: StreamedContentFolders,
	contentId: string,
	encounterId: string,
	obstacleKind: ObstacleKind
): Part?
	local expectation = OBSTACLE_EXPECTATIONS[contentId]
	if expectation == nil
		or expectation.EncounterId ~= encounterId
		or expectation.ObstacleKind ~= obstacleKind
	then
		return nil
	end
	local obstacles = folders.Obstacles
	if obstacles == nil then
		return nil
	end
	local instance = findUniqueDirectChild(obstacles, contentId, "Part")
	if instance == nil then
		return nil
	end
	local part = instance :: Part
	if part.Parent ~= obstacles
		or part.Name ~= contentId
		or not part.Anchored
		or part.CanCollide
		or part.CanTouch
		or part.CanQuery
		or not part.CastShadow
		or part:GetAttribute("ContentId") ~= contentId
		or part:GetAttribute("ContentKind") ~= "Obstacle"
		or part:GetAttribute("EncounterId") ~= encounterId
		or part:GetAttribute("ObstacleKind") ~= obstacleKind
		or part:GetAttribute("RuntimeEnabled") ~= true
	then
		return nil
	end
	return part
end

local function validateHudHierarchy(references: RuntimeReferences): boolean
	return references.PlayerGui.Parent == Players.LocalPlayer
		and isUniqueDirectChild(Players.LocalPlayer, "PlayerGui", references.PlayerGui)
		and references.RunHud.Parent == references.PlayerGui
		and isUniqueDirectChild(references.PlayerGui, "FrostlineRunHud", references.RunHud)
		and references.StatusPanel.Parent == references.RunHud
		and isUniqueDirectChild(references.RunHud, "StatusPanel", references.StatusPanel)
		and routeLabel ~= nil
		and routeLabel.Parent == references.StatusPanel
		and isUniqueDirectChild(references.StatusPanel, "FrostRouteStatus", routeLabel)
end

local function restoreActiveFlash()
	local part = activeFlashPart
	local original = activeFlashOriginalModifier
	activeFlashPart = nil
	activeFlashOriginalModifier = nil
	if part and original ~= nil then
		pcall(function()
			part.LocalTransparencyModifier = original
		end)
	end
end

local function cancelFeedback()
	feedbackGeneration += 1
	restoreActiveFlash()
end

local function restoreHiddenCoins()
	for part, original in hiddenCoinModifiers do
		pcall(function()
			part.LocalTransparencyModifier = original
		end)
	end
	table.clear(hiddenCoinModifiers)
end

local function hideRouteLabel()
	local label = routeLabel
	if label then
		label.Visible = false
	end
end

local function restoreLocalPresentation()
	cancelFeedback()
	restoreHiddenCoins()
	hideRouteLabel()
end

local function counterText(state: PresentationState): string
	return string.format("COINS %d/160 • HITS %d", state.RouteCoinsCollected, state.ObstacleHits)
end

local function showCurrentCounters()
	local state = currentState
	local label = routeLabel
	if state and label and not state.Invalidated and not state.FailedClosed then
		label.Text = counterText(state)
		label.Visible = true
	end
end

local function failClosedCurrentPresentation()
	local state = currentState
	if not state or state.FailedClosed then
		return
	end
	state.FailedClosed = true
	state.Invalidated = true
	state.Sealed = true
	state.RouteCoinsCollected = 0
	table.clear(state.AcceptedContentIds)
	table.clear(state.CollectedCoinIds)
	table.clear(state.ResolvedEncounterIds)
	restoreLocalPresentation()
end

local function validatePacketEnvelope(rawPacket: any): ({ [any]: any }?, number?)
	if typeof(rawPacket) ~= "table" or not hasExactKeys(rawPacket, PACKET_KEYS) then
		return nil, nil
	end
	local packet = rawPacket :: { [any]: any }
	if packet.Version ~= PROTOCOL_VERSION
		or packet.CourseId ~= COURSE_ID
		or not isIntegerInRange(packet.RunId, 1, math.huge)
		or not isIntegerInRange(packet.EventSequence, 1, math.huge)
		or (packet.EventKind ~= "Begin"
			and packet.EventKind ~= "Delta"
			and packet.EventKind ~= "Seal"
			and packet.EventKind ~= "Clear")
		or not isIntegerInRange(packet.RouteCoinsCollected, 0, MAXIMUM_ROUTE_COINS)
		or not isIntegerInRange(packet.ObstacleHits, 0, MAXIMUM_OBSTACLE_HITS)
		or typeof(packet.Invalidated) ~= "boolean"
	then
		return nil, nil
	end
	local entryCount = denseArrayLength(packet.Entries, MAXIMUM_DELTA_ENTRIES)
	if entryCount == nil then
		return nil, nil
	end
	return packet, entryCount
end

local function validateCoinEntry(
	entry: { [any]: any },
	state: PresentationState,
	contentIdsInDelta: { [string]: boolean }
): boolean
	if not hasExactKeys(entry, COIN_ENTRY_KEYS) or entry.Kind ~= "CoinCollected" then
		return false
	end
	local contentId = entry.ContentId
	if not isKnownCoinId(contentId)
		or contentIdsInDelta[contentId] == true
		or state.AcceptedContentIds[contentId] == true
		or state.CollectedCoinIds[contentId] == true
	then
		return false
	end
	contentIdsInDelta[contentId] = true
	return true
end

local function validateObstacleEntry(
	entry: { [any]: any },
	folders: StreamedContentFolders?,
	state: PresentationState,
	contentIdsInDelta: { [string]: boolean },
	encounterIdsInDelta: { [string]: boolean }
): (boolean, Part?)
	if not hasExactKeys(entry, OBSTACLE_ENTRY_KEYS)
		or entry.Kind ~= "ObstacleHit"
		or typeof(entry.ContentId) ~= "string"
		or typeof(entry.EncounterId) ~= "string"
		or (entry.ObstacleKind ~= "IceBlocker" and entry.ObstacleKind ~= "HopBarrier")
		or not isFiniteNumber(entry.SpeedLoss)
		or entry.SpeedLoss < 0
	then
		return false, nil
	end
	local contentId = entry.ContentId :: string
	local encounterId = entry.EncounterId :: string
	local obstacleKind = entry.ObstacleKind :: ObstacleKind
	if contentIdsInDelta[contentId] == true
		or encounterIdsInDelta[encounterId] == true
		or state.AcceptedContentIds[contentId] == true
		or state.ResolvedEncounterIds[encounterId] == true
	then
		return false, nil
	end
	if folders == nil then
		return false, nil
	end
	local part = resolveStreamedObstaclePart(folders, contentId, encounterId, obstacleKind)
	if part == nil then
		return false, nil
	end
	contentIdsInDelta[contentId] = true
	encounterIdsInDelta[encounterId] = true
	return true, part
end

local function hideCollectedCoin(part: Part): boolean
	if hiddenCoinModifiers[part] ~= nil then
		return true
	end
	local original = part.LocalTransparencyModifier
	local succeeded = pcall(function()
		part.LocalTransparencyModifier = 1
	end)
	if succeeded and hiddenCoinModifiers[part] == nil then
		hiddenCoinModifiers[part] = original
	end
	return succeeded
end

local function beginObstacleFeedback(part: Part, obstacleKind: ObstacleKind, runId: number): boolean
	restoreActiveFlash()
	feedbackGeneration += 1
	local generation = feedbackGeneration
	local original = part.LocalTransparencyModifier
	local succeeded = pcall(function()
		part.LocalTransparencyModifier = 0.55
	end)
	if not succeeded then
		return false
	end
	activeFlashPart = part
	activeFlashOriginalModifier = original

	local label = routeLabel
	if label then
		label.Text = if obstacleKind == "IceBlocker" then "ICE HIT • SLOWDOWN" else "MISSED HOP • SLOWDOWN"
		label.Visible = true
	end

	task.delay(OBSTACLE_FEEDBACK_SECONDS, function()
		local state = currentState
		if generation ~= feedbackGeneration
			or not state
			or state.RunId ~= runId
			or state.Invalidated
			or state.FailedClosed
		then
			return
		end
		if activeFlashPart == part and activeFlashOriginalModifier == original then
			restoreActiveFlash()
			showCurrentCounters()
		end
	end)
	return true
end

local function applyDelta(packet: { [any]: any }, entryCount: number, state: PresentationState): boolean
	if state.Sealed or state.Invalidated or state.FailedClosed or packet.Invalidated ~= false or entryCount < 1 then
		return false
	end
	local references = runtimeReferences
	if not references or not validateHudHierarchy(references) then
		return false
	end

	local contentIdsInDelta: { [string]: boolean } = {}
	local encounterIdsInDelta: { [string]: boolean } = {}
	local newCoinCount = 0
	local newObstacleCount = 0
	local firstObstaclePart: Part? = nil
	local firstObstacleKind: ObstacleKind? = nil
	local folders = resolveStreamedContentFolders()
	for index = 1, entryCount do
		local entryValue = packet.Entries[index]
		if typeof(entryValue) ~= "table" then
			return false
		end
		local entry = entryValue :: { [any]: any }
		local valid: boolean
		local part: Part? = nil
		if entry.Kind == "CoinCollected" then
			valid = validateCoinEntry(entry, state, contentIdsInDelta)
			if valid then
				newCoinCount += 1
			end
		elseif entry.Kind == "ObstacleHit" then
			valid, part = validateObstacleEntry(
				entry,
				folders,
				state,
				contentIdsInDelta,
				encounterIdsInDelta
			)
			if valid then
				newObstacleCount += 1
				if firstObstaclePart == nil then
					firstObstaclePart = part
					firstObstacleKind = entry.ObstacleKind :: ObstacleKind
				end
			end
		else
			return false
		end
		if not valid then
			return false
		end
	end

	if packet.RouteCoinsCollected ~= state.RouteCoinsCollected + newCoinCount
		or packet.ObstacleHits ~= state.ObstacleHits + newObstacleCount
	then
		return false
	end

	state.LastSequence = packet.EventSequence :: number
	state.RouteCoinsCollected = packet.RouteCoinsCollected :: number
	state.ObstacleHits = packet.ObstacleHits :: number
	for index = 1, entryCount do
		local entry = packet.Entries[index] :: { [any]: any }
		local contentId = entry.ContentId :: string
		state.AcceptedContentIds[contentId] = true
		if entry.Kind == "CoinCollected" then
			state.CollectedCoinIds[contentId] = true
		else
			state.ResolvedEncounterIds[entry.EncounterId :: string] = true
		end
	end

	if folders then
		for contentId in state.CollectedCoinIds do
			local part = resolveStreamedCoinPart(folders, contentId)
			if part then
				hideCollectedCoin(part)
			end
		end
	end

	if firstObstaclePart and firstObstacleKind then
		if not beginObstacleFeedback(firstObstaclePart, firstObstacleKind, state.RunId) then
			return false
		end
	elseif activeFlashPart == nil then
		showCurrentCounters()
	end
	AudioController.presentRouteContent(state.RunId, newCoinCount > 0, newObstacleCount > 0)
	return true
end

local function applySeal(packet: { [any]: any }, entryCount: number, state: PresentationState): boolean
	if entryCount ~= 0 then
		return false
	end
	if packet.Invalidated == true then
		if state.Invalidated
			or state.FailedClosed
			or packet.RouteCoinsCollected ~= 0
			or packet.ObstacleHits ~= state.ObstacleHits
		then
			return false
		end
		state.LastSequence = packet.EventSequence :: number
		state.RouteCoinsCollected = 0
		state.Sealed = true
		state.Invalidated = true
		table.clear(state.AcceptedContentIds)
		table.clear(state.CollectedCoinIds)
		table.clear(state.ResolvedEncounterIds)
		restoreLocalPresentation()
		return true
	end

	if state.Sealed
		or state.Invalidated
		or state.FailedClosed
		or packet.RouteCoinsCollected ~= state.RouteCoinsCollected
		or packet.ObstacleHits ~= state.ObstacleHits
	then
		return false
	end
	state.LastSequence = packet.EventSequence :: number
	state.Sealed = true
	if activeFlashPart == nil then
		showCurrentCounters()
	end
	return true
end

local function acceptBegin(packet: { [any]: any }, entryCount: number): boolean
	local runId = packet.RunId :: number
	if packet.EventSequence ~= 1
		or entryCount ~= 0
		or packet.RouteCoinsCollected ~= 0
		or packet.ObstacleHits ~= 0
		or packet.Invalidated ~= false
		or runId <= latestRunId
		or Players.LocalPlayer:GetAttribute(PRESENTATION_COURSE_ATTRIBUTE) ~= COURSE_ID
	then
		return false
	end
	local references = runtimeReferences
	if not references or not validateHudHierarchy(references) then
		return false
	end

	restoreLocalPresentation()
	resolveStreamedContentFolders()
	local state: PresentationState = {
		RunId = runId,
		LastSequence = 1,
		RouteCoinsCollected = 0,
		ObstacleHits = 0,
		AcceptedContentIds = {},
		CollectedCoinIds = {},
		ResolvedEncounterIds = {},
		Sealed = false,
		Invalidated = false,
		FailedClosed = false,
	}
	currentState = state
	latestRunId = runId
	showCurrentCounters()
	return true
end

local function acceptClear(packet: { [any]: any }, entryCount: number, state: PresentationState): boolean
	if entryCount ~= 0 or packet.Invalidated ~= false then
		return false
	end
	state.LastSequence = packet.EventSequence :: number
	restoreLocalPresentation()
	currentState = nil
	return true
end

local function onRoutePacket(rawPacket: any)
	local rawRunId: number? = nil
	local rawSequence: number? = nil
	if typeof(rawPacket) == "table" then
		if isIntegerInRange(rawPacket.RunId, 1, math.huge) then
			rawRunId = rawPacket.RunId :: number
		end
		if isIntegerInRange(rawPacket.EventSequence, 1, math.huge) then
			rawSequence = rawPacket.EventSequence :: number
		end
	end
	if rawRunId and rawRunId < latestRunId then
		return
	end
	local stateBeforeValidation = currentState
	if stateBeforeValidation
		and rawRunId == stateBeforeValidation.RunId
		and rawSequence ~= nil
		and rawSequence <= stateBeforeValidation.LastSequence
	then
		return
	end

	local packet, entryCount = validatePacketEnvelope(rawPacket)
	if not packet or entryCount == nil then
		if stateBeforeValidation and rawRunId == stateBeforeValidation.RunId then
			failClosedCurrentPresentation()
		end
		return
	end
	local runId = packet.RunId :: number
	if packet.EventKind == "Begin" then
		if not acceptBegin(packet, entryCount) and currentState and runId == currentState.RunId then
			failClosedCurrentPresentation()
		end
		return
	end

	local state = currentState
	if not state or runId ~= state.RunId then
		return
	end
	if (packet.EventSequence :: number) <= state.LastSequence then
		return
	end
	if packet.EventKind == "Clear" then
		if not acceptClear(packet, entryCount, state) then
			failClosedCurrentPresentation()
		end
		return
	end
	if state.FailedClosed then
		return
	end
	if Players.LocalPlayer:GetAttribute(PRESENTATION_COURSE_ATTRIBUTE) ~= COURSE_ID then
		failClosedCurrentPresentation()
		return
	end
	local references = runtimeReferences
	if not references or not validateHudHierarchy(references) then
		failClosedCurrentPresentation()
		return
	end

	local accepted = if packet.EventKind == "Delta"
		then applyDelta(packet, entryCount, state)
		else applySeal(packet, entryCount, state)
	if not accepted then
		failClosedCurrentPresentation()
	end
end

local function resolveStartupReferences(deadline: number): (RemoteEvent, RuntimeReferences)
	local remoteFolder = waitForUniqueDirectChild(ReplicatedStorage, REMOTES_FOLDER_NAME, "Folder", deadline) :: Folder
	local remote = waitForUniqueDirectChild(remoteFolder, ROUTE_REMOTE_NAME, "RemoteEvent", deadline) :: RemoteEvent
	local playerGui = waitForUniqueDirectChild(Players.LocalPlayer, "PlayerGui", "PlayerGui", deadline) :: PlayerGui
	local runHud = waitForUniqueDirectChild(playerGui, "FrostlineRunHud", "ScreenGui", deadline) :: ScreenGui
	local statusPanel = waitForUniqueDirectChild(runHud, "StatusPanel", "Frame", deadline) :: Frame
	if statusPanel:FindFirstChild("FrostRouteStatus") then
		error("FrostRouteStatus already exists", 0)
	end

	return remote, {
		PlayerGui = playerGui,
		RunHud = runHud,
		StatusPanel = statusPanel,
	}
end

local function createRouteLabel(statusPanel: Frame): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "FrostRouteStatus"
	label.Position = UDim2.fromScale(0.055, 0.43)
	label.Size = UDim2.fromScale(0.60, 0.12)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = "COINS 0/160 • HITS 0"
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(255, 207, 64)
	label.Visible = false
	label.Active = false
	label.Selectable = false

	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MinTextSize = 8
	textConstraint.MaxTextSize = 12
	textConstraint.Parent = label
	label.Parent = statusPanel
	return label
end

local function cleanupPartialStartup()
	local connection = routeConnection
	routeConnection = nil
	if connection then
		connection:Disconnect()
	end
	restoreLocalPresentation()
	local label = routeLabel
	routeLabel = nil
	if label then
		label:Destroy()
	end
	runtimeReferences = nil
	currentState = nil
	latestRunId = 0
	table.clear(hiddenCoinModifiers)
	activeFlashPart = nil
	activeFlashOriginalModifier = nil
end

function FrostTrailRouteContentController.start()
	if started then
		return
	end
	started = true
	if not RunService:IsStudio() then
		return
	end

	local succeeded, failureReason = pcall(function()
		local deadline = os.clock() + STARTUP_TIMEOUT_SECONDS
		local remote, references = resolveStartupReferences(deadline)
		if os.clock() > deadline then
			error("route-content startup deadline expired", 0)
		end
		runtimeReferences = references
		routeLabel = createRouteLabel(references.StatusPanel)
		routeConnection = remote.OnClientEvent:Connect(onRoutePacket)
	end)
	if not succeeded then
		cleanupPartialStartup()
		started = false
		error(tostring(failureReason), 0)
	end
end

return FrostTrailRouteContentController
