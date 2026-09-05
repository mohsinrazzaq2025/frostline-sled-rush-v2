--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local STATE_REMOTE_NAME = "RunState"
local ACTIVE_SLEDS_FOLDER_NAME = "ActiveSleds"
local SLED_MODEL_NAME = "ChristmasSled"
local SLED_ROOT_NAME = "SledRoot"
local DRIVER_SEAT_NAME = "DriverSeat"
local ACTIVE_MINIMUM_ZOOM_DISTANCE = 16
local ACTIVE_MAXIMUM_ZOOM_DISTANCE = 19

type CameraSnapshot = {
	Camera: Camera,
	Character: Model,
	CameraType: Enum.CameraType,
	CameraSubject: Instance?,
	MinimumZoomDistance: number,
	MaximumZoomDistance: number,
}

type SledIdentity = {
	World: Model,
	ActiveSleds: Folder,
	Character: Model,
	Humanoid: Humanoid,
	DriverSeat: Seat,
	Sled: Model,
	Root: BasePart,
}

type ActiveCameraSession = SledIdentity & {
	RunId: number,
	Generation: number,
	Snapshot: CameraSnapshot,
}

type PendingRestoration = {
	RunId: number,
	Snapshot: CameraSnapshot,
	ExcludedCharacter: Model?,
}

local CameraController = {}

local localPlayer = Players.LocalPlayer
local started = false
local destroyed = false
local runtimeWarningIssued = false
local latestRunId = 0
local currentRunId: number? = nil
local currentPhase: string = RunPhase.Idle
local currentPhaseRank = 0
local sessionGeneration = 0
local terminalRunId: number? = nil
local invalidatedRunId: number? = nil
local activeSession: ActiveCameraSession? = nil
local pendingRestoration: PendingRestoration? = nil
local pendingCharacterConnection: RBXScriptConnection? = nil
local pendingCharacter: Model? = nil
local controllerConnections: { RBXScriptConnection } = {}
local activeIdentityConnections: { RBXScriptConnection } = {}

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isValidRunId(value: any): boolean
	return typeof(value) == "number"
		and isFiniteNumber(value)
		and value > 0
		and value % 1 == 0
end

local function phaseRank(phase: string): number?
	if phase == RunPhase.Countdown then
		return 1
	elseif phase == RunPhase.Descent then
		return 2
	elseif phase == RunPhase.Airborne then
		return 3
	elseif phase == RunPhase.Landed then
		return 4
	elseif phase == RunPhase.Results then
		return 5
	elseif phase == RunPhase.Reset then
		return 6
	elseif phase == RunPhase.Idle then
		return 7
	end
	return nil
end

local function isNativeCameraPhase(phase: string): boolean
	return phase == RunPhase.Descent or phase == RunPhase.Airborne or phase == RunPhase.Landed
end

local function isActivationPhase(phase: string): boolean
	return phase == RunPhase.Descent or phase == RunPhase.Airborne
end

local function isTerminalPhase(phase: string): boolean
	return phase == RunPhase.Results or phase == RunPhase.Reset or phase == RunPhase.Idle
end

local function currentLiveHumanoid(excludedCharacter: Model?): Humanoid?
	local character = localPlayer.Character
	if not character or character == excludedCharacter or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return humanoid
end

local function subjectBelongsToModel(subject: Instance, model: Model): boolean
	return subject == model or subject:IsDescendantOf(model)
end

local function isRestorableSubject(
	subject: Instance?,
	snapshotCharacter: Model,
	excludedCharacter: Model?
): boolean
	if not subject or not subject.Parent then
		return false
	end
	if subject:IsA("Humanoid") and subject.Health <= 0 then
		return false
	end
	if excludedCharacter and subjectBelongsToModel(subject, excludedCharacter) then
		return false
	end
	if localPlayer.Character ~= snapshotCharacter and subjectBelongsToModel(subject, snapshotCharacter) then
		return false
	end
	return true
end

local function warnRuntimeOnce(message: string)
	if runtimeWarningIssued then
		return
	end
	runtimeWarningIssued = true
	warn(string.format("[Frostline] Native sled camera restored Roblox camera: %s", message))
end

local function disconnectActiveIdentityConnections()
	for _, connection in activeIdentityConnections do
		connection:Disconnect()
	end
	table.clear(activeIdentityConnections)
end

local function disconnectPendingCharacterConnection()
	local connection = pendingCharacterConnection
	if connection then
		connection:Disconnect()
		pendingCharacterConnection = nil
	end
	pendingCharacter = nil
end

local function clearPendingRestoration()
	pendingRestoration = nil
	disconnectPendingCharacterConnection()
end

local function setZoomBounds(minimumDistance: number, maximumDistance: number)
	if not isFiniteNumber(minimumDistance)
		or not isFiniteNumber(maximumDistance)
		or minimumDistance < 0
		or maximumDistance < minimumDistance
	then
		error("Invalid native camera zoom bounds")
	end

	-- Widen maximum first so neither activation nor restoration can briefly make
	-- CameraMinZoomDistance greater than CameraMaxZoomDistance.
	localPlayer.CameraMaxZoomDistance = math.max(
		localPlayer.CameraMaxZoomDistance,
		minimumDistance,
		maximumDistance
	)
	localPlayer.CameraMinZoomDistance = minimumDistance
	localPlayer.CameraMaxZoomDistance = maximumDistance
end

local function restorationSubject(snapshot: CameraSnapshot, excludedCharacter: Model?): Instance?
	if isRestorableSubject(snapshot.CameraSubject, snapshot.Character, excludedCharacter) then
		return snapshot.CameraSubject
	end
	return currentLiveHumanoid(excludedCharacter)
end

local function applySnapshotToCamera(
	camera: Camera,
	snapshot: CameraSnapshot,
	subject: Instance?
): boolean
	local succeeded, failureReason = pcall(function()
		camera.CameraType = snapshot.CameraType
		if subject then
			camera.CameraSubject = subject
		end
	end)
	if not succeeded then
		warnRuntimeOnce(tostring(failureReason))
	end
	return succeeded
end

local function applyRestoration(snapshot: CameraSnapshot, excludedCharacter: Model?): boolean
	local zoomSucceeded, zoomFailure = pcall(function()
		setZoomBounds(snapshot.MinimumZoomDistance, snapshot.MaximumZoomDistance)
	end)
	if not zoomSucceeded then
		warnRuntimeOnce(tostring(zoomFailure))
	end

	local subject = restorationSubject(snapshot, excludedCharacter)
	local capturedCameraSucceeded = true
	if snapshot.Camera.Parent then
		capturedCameraSucceeded = applySnapshotToCamera(snapshot.Camera, snapshot, subject)
	end

	local currentCamera = Workspace.CurrentCamera
	local currentCameraSucceeded = false
	if currentCamera and currentCamera.Parent then
		if currentCamera == snapshot.Camera then
			currentCameraSucceeded = capturedCameraSucceeded
		else
			currentCameraSucceeded = applySnapshotToCamera(currentCamera, snapshot, subject)
		end
	end

	return zoomSucceeded and capturedCameraSucceeded and currentCameraSucceeded and subject ~= nil
end

local function tryCompletePendingRestoration()
	local pending = pendingRestoration
	if not pending then
		return
	end
	if currentRunId and pending.RunId < currentRunId then
		clearPendingRestoration()
		return
	end
	if applyRestoration(pending.Snapshot, pending.ExcludedCharacter) and pendingRestoration == pending then
		clearPendingRestoration()
	end
end

local function onPendingCharacterChildAdded(child: Instance)
	local character = pendingCharacter
	if character and child.Parent == character and child:IsA("Humanoid") then
		tryCompletePendingRestoration()
	end
end

local function observePendingCharacter(character: Model)
	disconnectPendingCharacterConnection()
	if not pendingRestoration or currentLiveHumanoid(nil) then
		return
	end
	pendingCharacter = character
	pendingCharacterConnection = character.ChildAdded:Connect(onPendingCharacterChildAdded)
end

local function restoreActiveSession(excludedCharacter: Model?)
	local session = activeSession
	if not session then
		return
	end

	activeSession = nil
	disconnectActiveIdentityConnections()
	local pending: PendingRestoration = {
		RunId = session.RunId,
		Snapshot = session.Snapshot,
		ExcludedCharacter = excludedCharacter,
	}
	pendingRestoration = pending
	if applyRestoration(pending.Snapshot, excludedCharacter) and pendingRestoration == pending then
		clearPendingRestoration()
	end
end

local function resolveCurrentSledIdentity(): SledIdentity?
	local character = localPlayer.Character
	if not character or not character:IsDescendantOf(Workspace) then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local seatPart = humanoid.SeatPart
	if not seatPart or not seatPart:IsA("Seat") or seatPart.Name ~= DRIVER_SEAT_NAME then
		return nil
	end
	if seatPart.Occupant ~= humanoid then
		return nil
	end

	local worldInstance = Workspace:FindFirstChild(GameConfig.World.FolderName)
	if not worldInstance or not worldInstance:IsA("Model") then
		return nil
	end
	local activeSledsInstance = worldInstance:FindFirstChild(ACTIVE_SLEDS_FOLDER_NAME)
	if not activeSledsInstance or not activeSledsInstance:IsA("Folder") then
		return nil
	end
	local sledInstance = seatPart.Parent
	if not sledInstance
		or not sledInstance:IsA("Model")
		or sledInstance.Name ~= SLED_MODEL_NAME
		or sledInstance.Parent ~= activeSledsInstance
	then
		return nil
	end
	local rootInstance = sledInstance:FindFirstChild(SLED_ROOT_NAME)
	local driverSeatInstance = sledInstance:FindFirstChild(DRIVER_SEAT_NAME)
	if not rootInstance
		or not rootInstance:IsA("BasePart")
		or driverSeatInstance ~= seatPart
		or sledInstance.PrimaryPart ~= rootInstance
	then
		return nil
	end

	return {
		World = worldInstance,
		ActiveSleds = activeSledsInstance,
		Character = character,
		Humanoid = humanoid,
		DriverSeat = seatPart,
		Sled = sledInstance,
		Root = rootInstance,
	}
end

local function isActiveSessionValid(session: ActiveCameraSession): boolean
	if not started
		or destroyed
		or activeSession ~= session
		or currentRunId ~= session.RunId
		or latestRunId ~= session.RunId
		or session.Generation ~= sessionGeneration
		or terminalRunId == session.RunId
		or invalidatedRunId == session.RunId
		or not isNativeCameraPhase(currentPhase)
		or Workspace.CurrentCamera ~= session.Snapshot.Camera
		or not session.Snapshot.Camera.Parent
		or localPlayer.Character ~= session.Character
		or not session.Character:IsDescendantOf(Workspace)
		or session.Character:FindFirstChildOfClass("Humanoid") ~= session.Humanoid
		or not session.Humanoid.Parent
		or session.Humanoid.Health <= 0
		or session.Humanoid.SeatPart ~= session.DriverSeat
		or session.DriverSeat.Occupant ~= session.Humanoid
		or session.World.Parent ~= Workspace
		or Workspace:FindFirstChild(GameConfig.World.FolderName) ~= session.World
		or session.ActiveSleds.Parent ~= session.World
		or session.World:FindFirstChild(ACTIVE_SLEDS_FOLDER_NAME) ~= session.ActiveSleds
		or session.Sled.Parent ~= session.ActiveSleds
		or session.Sled.Name ~= SLED_MODEL_NAME
		or session.DriverSeat.Parent ~= session.Sled
		or session.Sled:FindFirstChild(DRIVER_SEAT_NAME) ~= session.DriverSeat
		or session.Root.Parent ~= session.Sled
		or session.Sled:FindFirstChild(SLED_ROOT_NAME) ~= session.Root
		or session.Sled.PrimaryPart ~= session.Root
	then
		return false
	end
	return true
end

local function invalidateActiveRun(runId: number, excludedCharacter: Model?)
	if currentRunId ~= runId then
		return
	end
	if invalidatedRunId ~= runId then
		invalidatedRunId = runId
		sessionGeneration += 1
	end
	local session = activeSession
	if session and session.RunId == runId then
		restoreActiveSession(excludedCharacter)
	end
end

local function handleActiveIdentityChanged()
	local session = activeSession
	if session and not isActiveSessionValid(session) then
		invalidateActiveRun(session.RunId, nil)
	end
end

local function handleActiveAncestryChanged(_instance: Instance, _parent: Instance?)
	handleActiveIdentityChanged()
end

local function connectActiveIdentitySignals(session: ActiveCameraSession)
	disconnectActiveIdentityConnections()
	table.insert(
		activeIdentityConnections,
		session.Humanoid:GetPropertyChangedSignal("SeatPart"):Connect(handleActiveIdentityChanged)
	)
	table.insert(
		activeIdentityConnections,
		session.DriverSeat:GetPropertyChangedSignal("Occupant"):Connect(handleActiveIdentityChanged)
	)
	table.insert(activeIdentityConnections, session.DriverSeat.AncestryChanged:Connect(handleActiveAncestryChanged))
	table.insert(activeIdentityConnections, session.Root.AncestryChanged:Connect(handleActiveAncestryChanged))
	table.insert(activeIdentityConnections, session.Sled.AncestryChanged:Connect(handleActiveAncestryChanged))
end

local function activateForCurrentState()
	local runId = currentRunId
	if not runId
		or not isActivationPhase(currentPhase)
		or terminalRunId == runId
		or invalidatedRunId == runId
		or destroyed
		or not started
	then
		return
	end
	if activeSession then
		if not isActiveSessionValid(activeSession) then
			invalidateActiveRun(runId, nil)
		end
		return
	end

	local identity = resolveCurrentSledIdentity()
	if not identity then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera or not camera.Parent then
		return
	end
	local currentSubject = camera.CameraSubject
	local capturedSubject = if isRestorableSubject(currentSubject, identity.Character, nil)
		then currentSubject
		else nil
	local snapshot: CameraSnapshot = {
		Camera = camera,
		Character = identity.Character,
		CameraType = camera.CameraType,
		CameraSubject = capturedSubject,
		MinimumZoomDistance = localPlayer.CameraMinZoomDistance,
		MaximumZoomDistance = localPlayer.CameraMaxZoomDistance,
	}

	local session: ActiveCameraSession = {
		World = identity.World,
		ActiveSleds = identity.ActiveSleds,
		Character = identity.Character,
		Humanoid = identity.Humanoid,
		DriverSeat = identity.DriverSeat,
		Sled = identity.Sled,
		Root = identity.Root,
		RunId = runId,
		Generation = sessionGeneration,
		Snapshot = snapshot,
	}
	activeSession = session
	clearPendingRestoration()

	local succeeded, failureReason = pcall(function()
		connectActiveIdentitySignals(session)
		if not isActiveSessionValid(session) then
			error("Native camera session became invalid during activation")
		end
		camera.CameraSubject = identity.Humanoid
		camera.CameraType = Enum.CameraType.Follow
		setZoomBounds(ACTIVE_MINIMUM_ZOOM_DISTANCE, ACTIVE_MAXIMUM_ZOOM_DISTANCE)
	end)
	if not succeeded then
		invalidateActiveRun(runId, nil)
		warnRuntimeOnce(tostring(failureReason))
	end
end

local function acceptRunState(phaseValue: any, runIdValue: any)
	if destroyed or not started or typeof(phaseValue) ~= "string" or not isValidRunId(runIdValue) then
		return
	end
	local phase = phaseValue :: string
	local runId = runIdValue :: number
	if runId < latestRunId then
		return
	end

	local rank = phaseRank(phase)
	if runId > latestRunId or currentRunId ~= runId then
		if activeSession then
			sessionGeneration += 1
			restoreActiveSession(nil)
		end
		latestRunId = runId
		currentRunId = runId
		currentPhase = RunPhase.Idle
		currentPhaseRank = 0
		terminalRunId = nil
		invalidatedRunId = nil
		sessionGeneration += 1
		local pending = pendingRestoration
		if pending and pending.RunId < runId then
			clearPendingRestoration()
		end
	end
	if not rank then
		invalidatedRunId = runId
		sessionGeneration += 1
		restoreActiveSession(nil)
		return
	end
	if rank < currentPhaseRank then
		return
	end

	currentPhase = phase
	currentPhaseRank = rank
	if phase == RunPhase.Countdown then
		-- Countdown deliberately preserves the player's current native camera.
		return
	end
	if isTerminalPhase(phase) then
		if terminalRunId ~= runId then
			terminalRunId = runId
			sessionGeneration += 1
		end
		restoreActiveSession(nil)
		tryCompletePendingRestoration()
		return
	end
	if terminalRunId == runId or invalidatedRunId == runId then
		return
	end
	if not isNativeCameraPhase(phase) then
		invalidatedRunId = runId
		sessionGeneration += 1
		restoreActiveSession(nil)
		return
	end
	local session = activeSession
	if session then
		if not isActiveSessionValid(session) then
			invalidateActiveRun(runId, nil)
		end
		return
	end
	if isActivationPhase(phase) then
		activateForCurrentState()
	end
end

local function onRunState(
	phase: any,
	_countdown: any,
	_speed: any,
	runId: any,
	_tuckQueued: any,
	_tucking: any,
	_outcome: any,
	_releaseAccepted: any
)
	acceptRunState(phase, runId)
end

local function onCharacterRemoving(character: Model)
	if pendingCharacter == character then
		disconnectPendingCharacterConnection()
	end
	local runId = currentRunId
	if runId then
		invalidateActiveRun(runId, character)
		local pending = pendingRestoration
		if pending and pending.RunId == runId then
			pending.ExcludedCharacter = character
		end
	end
end

local function onCharacterAdded(character: Model)
	local runId = currentRunId
	local session = activeSession
	if session then
		if runId and session.Character ~= character then
			invalidateActiveRun(runId, session.Character)
		end
	elseif runId and not isTerminalPhase(currentPhase) and invalidatedRunId ~= runId then
		invalidatedRunId = runId
		sessionGeneration += 1
	end
	tryCompletePendingRestoration()
	if pendingRestoration then
		observePendingCharacter(character)
	end
end

local function onCurrentCameraChanged()
	local session = activeSession
	if session and Workspace.CurrentCamera ~= session.Snapshot.Camera then
		invalidateActiveRun(session.RunId, nil)
	else
		tryCompletePendingRestoration()
	end
end

function CameraController.start()
	if started then
		return
	end

	local remoteFolder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not remoteFolder or not remoteFolder:IsA("Folder") then
		error("FrostlineRemotes was unavailable; native run camera remains disabled")
	end
	local runStateInstance = remoteFolder:FindFirstChild(STATE_REMOTE_NAME)
	if not runStateInstance or not runStateInstance:IsA("RemoteEvent") then
		error("RunState was unavailable; native run camera remains disabled")
	end

	destroyed = false
	started = true
	runtimeWarningIssued = false
	latestRunId = 0
	currentRunId = nil
	currentPhase = RunPhase.Idle
	currentPhaseRank = 0
	terminalRunId = nil
	invalidatedRunId = nil
	clearPendingRestoration()
	sessionGeneration += 1

	table.insert(controllerConnections, runStateInstance.OnClientEvent:Connect(onRunState))
	table.insert(controllerConnections, localPlayer.CharacterRemoving:Connect(onCharacterRemoving))
	table.insert(controllerConnections, localPlayer.CharacterAdded:Connect(onCharacterAdded))
	table.insert(
		controllerConnections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(onCurrentCameraChanged)
	)
	table.insert(controllerConnections, script.Destroying:Connect(CameraController.destroy))
end

function CameraController.destroy()
	if destroyed then
		return
	end
	destroyed = true
	sessionGeneration += 1
	restoreActiveSession(nil)
	tryCompletePendingRestoration()

	for _, connection in controllerConnections do
		connection:Disconnect()
	end
	table.clear(controllerConnections)
	disconnectActiveIdentityConnections()
	clearPendingRestoration()
	currentRunId = nil
	currentPhase = RunPhase.Idle
	currentPhaseRank = 0
	terminalRunId = nil
	invalidatedRunId = nil
	latestRunId = 0
	started = false
end

return CameraController
