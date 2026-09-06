--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local STATE_REMOTE_NAME = "RunState"
local ACTIVE_SLEDS_FOLDER_NAME = "ActiveSleds"
local SLED_MODEL_NAME = "ChristmasSled"
local SLED_ROOT_NAME = "SledRoot"
local DRIVER_SEAT_NAME = "DriverSeat"
local GEOMETRY_FOLDER_NAME = "Geometry"
local PLAYER_SPAWN_NAME = "PlayerSpawn"
local ACTIVE_MINIMUM_ZOOM_DISTANCE = 16
local ACTIVE_MAXIMUM_ZOOM_DISTANCE = 19
local COLD_JOIN_RENDER_BIND_NAME = "FrostlineColdJoinCameraAlignment"
local COLD_JOIN_TIMEOUT_SECONDS = 3
local COLD_JOIN_MAXIMUM_READINESS_CALLBACKS = 10
local COLD_JOIN_MAXIMUM_FOCUS_DISTANCE = 32
local COLD_JOIN_MINIMUM_HORIZONTAL_MAGNITUDE = 1e-4
local COLD_JOIN_MINIMUM_ROOT_ALIGNMENT_DOT = 0.99
local READY_ALIGNMENT_MAXIMUM_SPAWN_DISTANCE = 24
local READY_ALIGNMENT_ROOT_VERTICAL_OFFSET = Vector3.new(0, 4, 0)

type ColdJoinHandoffStage = "Readiness" | "Acquiring" | "Release"
type ColdJoinAttemptResult = "Acquired" | "AlreadyAligned" | "Retry" | "Cancel"
type ReadyAlignmentReason = "ColdJoin" | "CharacterAdded" | "ReturnToStart"
type ReadyAlignmentValidation = "Ready" | "Retry" | "Cancel"

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
local coldJoinGeneration = 0
local coldJoinBoundaryConsumed = false
local latestCharacterBoundary: Model? = nil
local latestReturnIdleRunId = 0
local alignmentRequestReason: ReadyAlignmentReason? = nil
local alignmentRequestCharacter: Model? = nil
local alignmentRequestRunId: number? = nil
local coldJoinCharacterWasInWorkspace = false
local coldJoinHumanoid: Humanoid? = nil
local coldJoinRoot: BasePart? = nil
local coldJoinCamera: Camera? = nil
local coldJoinTerminal = true
local coldJoinDeadline = 0
local coldJoinRenderBound = false
local coldJoinReadinessCallbackCount = 0
local coldJoinHandoffStage: ColdJoinHandoffStage = "Readiness"
local coldJoinOwnsCamera = false
local coldJoinOwnedCamera: Camera? = nil
local coldJoinOriginalCameraType: Enum.CameraType? = nil
local coldJoinDesiredCFrame: CFrame? = nil
local coldJoinDesiredFocus: CFrame? = nil
local coldJoinTimeoutThread: thread? = nil
local coldJoinCharacterChildAddedConnection: RBXScriptConnection? = nil
local coldJoinCharacterChildRemovedConnection: RBXScriptConnection? = nil
local coldJoinCharacterAncestryConnection: RBXScriptConnection? = nil
local coldJoinHumanoidDiedConnection: RBXScriptConnection? = nil
local coldJoinCameraAncestryConnection: RBXScriptConnection? = nil
local coldJoinCameraTypeConnection: RBXScriptConnection? = nil
local coldJoinCameraSubjectConnection: RBXScriptConnection? = nil
local evaluateColdJoinReadiness: () -> ()

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function isFiniteCFrame(value: CFrame): boolean
	return isFiniteVector3(value.Position)
		and isFiniteVector3(value.RightVector)
		and isFiniteVector3(value.UpVector)
		and isFiniteVector3(value.LookVector)
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

local function isReadyAlignmentPhaseEligible(reason: ReadyAlignmentReason, requestRunId: number?): boolean
	if reason == "ColdJoin" then
		return currentRunId == nil and currentPhase == RunPhase.Idle
	elseif reason == "CharacterAdded" then
		if requestRunId == nil then
			return currentRunId == nil and currentPhase == RunPhase.Idle
		end
		return currentRunId == requestRunId
			and latestRunId == requestRunId
			and currentPhase == RunPhase.Idle
	elseif reason == "ReturnToStart" then
		return requestRunId ~= nil
			and currentRunId == requestRunId
			and latestRunId == requestRunId
			and currentPhase == RunPhase.Idle
	end
	return false
end

local function resolveReadyPlayerSpawn(): (SpawnLocation?, ReadyAlignmentValidation)
	local worldInstance = Workspace:FindFirstChild(GameConfig.World.FolderName)
	if not worldInstance then
		return nil, "Retry"
	end
	if not worldInstance:IsA("Model") or worldInstance.Parent ~= Workspace then
		return nil, "Cancel"
	end
	local geometryInstance = worldInstance:FindFirstChild(GEOMETRY_FOLDER_NAME)
	if not geometryInstance then
		return nil, "Retry"
	end
	if not geometryInstance:IsA("Folder") or geometryInstance.Parent ~= worldInstance then
		return nil, "Cancel"
	end
	local spawnInstance = geometryInstance:FindFirstChild(PLAYER_SPAWN_NAME)
	if not spawnInstance then
		return nil, "Retry"
	end
	if not spawnInstance:IsA("SpawnLocation") or spawnInstance.Parent ~= geometryInstance then
		return nil, "Cancel"
	end
	return spawnInstance, "Ready"
end

local function validateReadyAlignmentPosition(
	root: BasePart,
	reason: ReadyAlignmentReason,
	reportFacingMismatch: boolean
): (ReadyAlignmentValidation, Vector3?, Vector3?)
	local playerSpawn, spawnStatus = resolveReadyPlayerSpawn()
	if not playerSpawn then
		return spawnStatus, nil, nil
	end

	local rootPosition = root.Position
	local expectedRootPosition = playerSpawn.Position + READY_ALIGNMENT_ROOT_VERTICAL_OFFSET
	if not isFiniteVector3(rootPosition) or not isFiniteVector3(expectedRootPosition) then
		return "Cancel", nil, nil
	end
	local spawnDistance = (rootPosition - expectedRootPosition).Magnitude
	if not isFiniteNumber(spawnDistance) or spawnDistance > READY_ALIGNMENT_MAXIMUM_SPAWN_DISTANCE then
		return "Cancel", nil, nil
	end

	local rampTarget = GameConfig.World.PathPoints[1]
	local toRamp = rampTarget - rootPosition
	local flatToRamp = Vector3.new(toRamp.X, 0, toRamp.Z)
	local flatToRampMagnitude = flatToRamp.Magnitude
	local rootLook = root.CFrame.LookVector
	local flatRootLook = Vector3.new(rootLook.X, 0, rootLook.Z)
	local flatRootLookMagnitude = flatRootLook.Magnitude
	if not isFiniteVector3(rampTarget)
		or not isFiniteVector3(toRamp)
		or not isFiniteVector3(flatToRamp)
		or not isFiniteNumber(flatToRampMagnitude)
		or flatToRampMagnitude <= COLD_JOIN_MINIMUM_HORIZONTAL_MAGNITUDE
		or not isFiniteVector3(rootLook)
		or not isFiniteVector3(flatRootLook)
		or not isFiniteNumber(flatRootLookMagnitude)
		or flatRootLookMagnitude <= COLD_JOIN_MINIMUM_HORIZONTAL_MAGNITUDE
	then
		return "Cancel", nil, nil
	end

	local rampDirection = flatToRamp.Unit
	local forward = flatRootLook.Unit
	local rootAlignment = forward:Dot(rampDirection)
	if not isFiniteVector3(rampDirection)
		or not isFiniteVector3(forward)
		or not isFiniteNumber(rootAlignment)
	then
		return "Cancel", nil, nil
	end
	if rootAlignment < COLD_JOIN_MINIMUM_ROOT_ALIGNMENT_DOT then
		if reportFacingMismatch then
			warnRuntimeOnce(string.format(
				"ready alignment skipped: root/course mismatch reason=%s dot=%.4f",
				reason,
				rootAlignment
			))
		end
		return "Cancel", nil, nil
	end

	return "Ready", forward, rampDirection
end

local function unbindColdJoinRenderStep()
	if not coldJoinRenderBound then
		return
	end
	coldJoinRenderBound = false
	RunService:UnbindFromRenderStep(COLD_JOIN_RENDER_BIND_NAME)
end

local function disconnectColdJoinCameraConnections()
	local ancestryConnection = coldJoinCameraAncestryConnection
	if ancestryConnection then
		ancestryConnection:Disconnect()
		coldJoinCameraAncestryConnection = nil
	end
	local typeConnection = coldJoinCameraTypeConnection
	if typeConnection then
		typeConnection:Disconnect()
		coldJoinCameraTypeConnection = nil
	end
	local subjectConnection = coldJoinCameraSubjectConnection
	if subjectConnection then
		subjectConnection:Disconnect()
		coldJoinCameraSubjectConnection = nil
	end
	coldJoinCamera = nil
end

local function disconnectColdJoinCharacterConnections()
	local childAddedConnection = coldJoinCharacterChildAddedConnection
	if childAddedConnection then
		childAddedConnection:Disconnect()
		coldJoinCharacterChildAddedConnection = nil
	end
	local childRemovedConnection = coldJoinCharacterChildRemovedConnection
	if childRemovedConnection then
		childRemovedConnection:Disconnect()
		coldJoinCharacterChildRemovedConnection = nil
	end
	local ancestryConnection = coldJoinCharacterAncestryConnection
	if ancestryConnection then
		ancestryConnection:Disconnect()
		coldJoinCharacterAncestryConnection = nil
	end
	local diedConnection = coldJoinHumanoidDiedConnection
	if diedConnection then
		diedConnection:Disconnect()
		coldJoinHumanoidDiedConnection = nil
	end
	coldJoinHumanoid = nil
	coldJoinRoot = nil
end

local function cancelColdJoinTimeout()
	local timeoutThread = coldJoinTimeoutThread
	coldJoinTimeoutThread = nil
	if timeoutThread then
		pcall(function()
			task.cancel(timeoutThread)
		end)
	end
end

local function applyColdJoinPose(camera: Camera, desiredCFrame: CFrame, desiredFocus: CFrame)
	camera.CFrame = desiredCFrame
	camera.Focus = desiredFocus
end

local function restoreColdJoinCameraType(camera: Camera, originalCameraType: Enum.CameraType)
	camera.CameraType = originalCameraType
end

local function clearColdJoinLease()
	coldJoinOwnsCamera = false
	coldJoinOwnedCamera = nil
	coldJoinOriginalCameraType = nil
	coldJoinDesiredCFrame = nil
	coldJoinDesiredFocus = nil
	coldJoinHandoffStage = "Readiness"
end

local function clearReadyAlignmentRequest()
	alignmentRequestReason = nil
	alignmentRequestCharacter = nil
	alignmentRequestRunId = nil
	coldJoinCharacterWasInWorkspace = false
end

local function terminateColdJoinAlignment(generation: number, reassertOwnedPose: boolean?)
	if generation ~= coldJoinGeneration or coldJoinTerminal then
		return
	end

	local ownedCamera = coldJoinOwnedCamera
	local originalCameraType = coldJoinOriginalCameraType
	local desiredCFrame = coldJoinDesiredCFrame
	local desiredFocus = coldJoinDesiredFocus
	local ownsExactCapturedCamera = coldJoinOwnsCamera
		and ownedCamera ~= nil
		and ownedCamera == coldJoinCamera

	unbindColdJoinRenderStep()
	coldJoinTerminal = true
	coldJoinGeneration += 1
	disconnectColdJoinCameraConnections()
	disconnectColdJoinCharacterConnections()
	cancelColdJoinTimeout()
	coldJoinDeadline = 0

	if ownsExactCapturedCamera
		and ownedCamera
		and ownedCamera.Parent
		and ownedCamera.CameraType == Enum.CameraType.Scriptable
		and originalCameraType == Enum.CameraType.Custom
	then
		if reassertOwnedPose and desiredCFrame and desiredFocus then
			pcall(applyColdJoinPose, ownedCamera, desiredCFrame, desiredFocus)
		end
		local restored = pcall(restoreColdJoinCameraType, ownedCamera, originalCameraType)
		if (not restored or ownedCamera.CameraType == Enum.CameraType.Scriptable) and ownedCamera.Parent then
			pcall(restoreColdJoinCameraType, ownedCamera, originalCameraType)
		end
	end

	clearColdJoinLease()
	clearReadyAlignmentRequest()
end

local function resetReadyAlignmentLifecycle()
	if not coldJoinTerminal then
		terminateColdJoinAlignment(coldJoinGeneration)
	else
		unbindColdJoinRenderStep()
		disconnectColdJoinCameraConnections()
		disconnectColdJoinCharacterConnections()
		cancelColdJoinTimeout()
		clearColdJoinLease()
		clearReadyAlignmentRequest()
	end
	coldJoinGeneration += 1
	coldJoinBoundaryConsumed = false
	latestCharacterBoundary = nil
	latestReturnIdleRunId = 0
	coldJoinTerminal = true
	coldJoinDeadline = 0
	coldJoinReadinessCallbackCount = 0
end

local function attemptColdJoinHandoff(generation: number): ColdJoinAttemptResult
	local reason = alignmentRequestReason
	local character = alignmentRequestCharacter
	if not started
		or destroyed
		or generation ~= coldJoinGeneration
		or coldJoinTerminal
		or os.clock() >= coldJoinDeadline
		or coldJoinOwnsCamera
		or coldJoinHandoffStage ~= "Readiness"
		or not reason
		or not character
		or not isReadyAlignmentPhaseEligible(reason, alignmentRequestRunId)
		or activeSession ~= nil
	then
		return "Cancel"
	end
	if pendingRestoration ~= nil then
		return "Retry"
	end

	local humanoid = coldJoinHumanoid
	local root = coldJoinRoot
	local camera = coldJoinCamera
	if not character or not humanoid or not root then
		return "Cancel"
	end
	if not camera or camera ~= Workspace.CurrentCamera then
		return "Retry"
	end
	if localPlayer.Character ~= character
		or not character:IsDescendantOf(Workspace)
		or character:FindFirstChildOfClass("Humanoid") ~= humanoid
		or humanoid.Parent ~= character
		or humanoid.Health <= 0
		or humanoid.SeatPart ~= nil
		or character:FindFirstChild("HumanoidRootPart") ~= root
		or root.Parent ~= character
	then
		return "Cancel"
	end
	if not camera.Parent then
		return "Cancel"
	end
	if camera.CameraType ~= Enum.CameraType.Custom or camera.CameraSubject ~= humanoid then
		return "Retry"
	end

	local nativeCFrame = camera.CFrame
	local desiredFocus = camera.Focus
	if not isFiniteCFrame(nativeCFrame) or not isFiniteCFrame(desiredFocus) then
		return "Cancel"
	end
	local focusPosition = desiredFocus.Position
	local nativeCameraPosition = nativeCFrame.Position
	local rootPosition = root.Position
	if not isFiniteVector3(focusPosition)
		or not isFiniteVector3(nativeCameraPosition)
		or not isFiniteVector3(rootPosition)
	then
		return "Cancel"
	end
	local focusDistance = (focusPosition - rootPosition).Magnitude
	if not isFiniteNumber(focusDistance) then
		return "Cancel"
	end
	if focusDistance > COLD_JOIN_MAXIMUM_FOCUS_DISTANCE then
		return "Retry"
	end

	local offset = nativeCameraPosition - focusPosition
	local verticalOffset = offset:Dot(Vector3.yAxis)
	local horizontalOffset = offset - Vector3.yAxis * verticalOffset
	local horizontalRadius = horizontalOffset.Magnitude
	if not isFiniteVector3(offset)
		or not isFiniteNumber(verticalOffset)
		or not isFiniteVector3(horizontalOffset)
		or not isFiniteNumber(horizontalRadius)
	then
		return "Cancel"
	end
	if horizontalRadius <= COLD_JOIN_MINIMUM_HORIZONTAL_MAGNITUDE then
		return "Retry"
	end

	local positionStatus, forward, rampDirection = validateReadyAlignmentPosition(root, reason, true)
	if positionStatus ~= "Ready" then
		return positionStatus
	end
	if not forward or not rampDirection then
		return "Cancel"
	end

	local cameraPosition = focusPosition
		- forward * horizontalRadius
		+ Vector3.yAxis * verticalOffset
	if not isFiniteVector3(cameraPosition) then
		return "Cancel"
	end
	local desiredCFrame = CFrame.lookAt(
		cameraPosition,
		focusPosition,
		Vector3.yAxis
	)
	if not isFiniteCFrame(desiredCFrame) then
		return "Cancel"
	end

	local flatCameraLook = Vector3.new(nativeCFrame.LookVector.X, 0, nativeCFrame.LookVector.Z)
	local flatCameraLookMagnitude = flatCameraLook.Magnitude
	if not isFiniteVector3(flatCameraLook) or not isFiniteNumber(flatCameraLookMagnitude) then
		return "Cancel"
	end
	if flatCameraLookMagnitude > COLD_JOIN_MINIMUM_HORIZONTAL_MAGNITUDE then
		local cameraAlignment = flatCameraLook.Unit:Dot(rampDirection)
		if not isFiniteNumber(cameraAlignment) then
			return "Cancel"
		end
		if cameraAlignment >= COLD_JOIN_MINIMUM_ROOT_ALIGNMENT_DOT then
			return "AlreadyAligned"
		end
	end

	coldJoinOwnsCamera = true
	coldJoinOwnedCamera = camera
	coldJoinOriginalCameraType = camera.CameraType
	coldJoinDesiredCFrame = desiredCFrame
	coldJoinDesiredFocus = desiredFocus
	coldJoinHandoffStage = "Acquiring"

	local acquired = pcall(function()
		camera.CameraType = Enum.CameraType.Scriptable
	end)
	if not acquired or camera.CameraType ~= Enum.CameraType.Scriptable then
		return "Cancel"
	end
	local poseApplied = pcall(applyColdJoinPose, camera, desiredCFrame, desiredFocus)
	if not poseApplied then
		return "Cancel"
	end

	coldJoinHandoffStage = "Release"
	return "Acquired"
end

local function isColdJoinReleaseValid(generation: number): boolean
	local reason = alignmentRequestReason
	local character = alignmentRequestCharacter
	local humanoid = coldJoinHumanoid
	local root = coldJoinRoot
	local ownedCamera = coldJoinOwnedCamera
	local desiredCFrame = coldJoinDesiredCFrame
	local desiredFocus = coldJoinDesiredFocus
	if not started
		or destroyed
		or generation ~= coldJoinGeneration
		or coldJoinTerminal
		or os.clock() >= coldJoinDeadline
		or coldJoinHandoffStage ~= "Release"
		or not coldJoinOwnsCamera
		or not reason
		or not character
		or not isReadyAlignmentPhaseEligible(reason, alignmentRequestRunId)
		or activeSession ~= nil
		or pendingRestoration ~= nil
		or not humanoid
		or not root
		or not ownedCamera
		or not desiredCFrame
		or not desiredFocus
	then
		return false
	end
	if localPlayer.Character ~= character
		or not character:IsDescendantOf(Workspace)
		or character:FindFirstChildOfClass("Humanoid") ~= humanoid
		or humanoid.Parent ~= character
		or humanoid.Health <= 0
		or humanoid.SeatPart ~= nil
		or character:FindFirstChild("HumanoidRootPart") ~= root
		or root.Parent ~= character
		or ownedCamera ~= coldJoinCamera
		or Workspace.CurrentCamera ~= ownedCamera
		or not ownedCamera.Parent
		or ownedCamera.CameraType ~= Enum.CameraType.Scriptable
		or ownedCamera.CameraSubject ~= humanoid
		or coldJoinOriginalCameraType ~= Enum.CameraType.Custom
		or not isFiniteCFrame(desiredCFrame)
		or not isFiniteCFrame(desiredFocus)
	then
		return false
	end

	local positionStatus = validateReadyAlignmentPosition(root, reason, true)
	return positionStatus == "Ready"
end

local function processColdJoinRenderCallback(generation: number)
	if generation ~= coldJoinGeneration or coldJoinTerminal then
		return
	end

	if coldJoinHandoffStage == "Release" then
		local reassertOwnedPose = isColdJoinReleaseValid(generation)
		terminateColdJoinAlignment(generation, reassertOwnedPose)
		return
	end
	if coldJoinHandoffStage ~= "Readiness" then
		terminateColdJoinAlignment(generation)
		return
	end

	coldJoinReadinessCallbackCount += 1
	local attempted, result = pcall(attemptColdJoinHandoff, generation)
	if not attempted then
		terminateColdJoinAlignment(generation)
		return
	end
	if result == "Acquired" then
		return
	end
	if result == "Retry"
		and coldJoinReadinessCallbackCount < COLD_JOIN_MAXIMUM_READINESS_CALLBACKS
		and os.clock() < coldJoinDeadline
	then
		evaluateColdJoinReadiness()
		return
	end
	terminateColdJoinAlignment(generation)
end

local function scheduleColdJoinAlignment(generation: number)
	if coldJoinRenderBound then
		return
	end
	coldJoinRenderBound = true
	local bindSucceeded = pcall(function()
		RunService:BindToRenderStep(
			COLD_JOIN_RENDER_BIND_NAME,
			Enum.RenderPriority.Camera.Value + 1,
			function()
				local processed = pcall(processColdJoinRenderCallback, generation)
				if not processed then
					terminateColdJoinAlignment(generation)
				end
			end
		)
	end)
	if not bindSucceeded then
		coldJoinRenderBound = false
		terminateColdJoinAlignment(generation)
	end
end

local function observeColdJoinCamera(camera: Camera, generation: number)
	disconnectColdJoinCameraConnections()
	coldJoinCamera = camera
	coldJoinCameraAncestryConnection = camera.AncestryChanged:Connect(function()
		if generation ~= coldJoinGeneration or coldJoinTerminal then
			return
		end
		if Workspace.CurrentCamera == camera and not camera.Parent then
			terminateColdJoinAlignment(generation)
		else
			evaluateColdJoinReadiness()
		end
	end)
	coldJoinCameraTypeConnection = camera:GetPropertyChangedSignal("CameraType"):Connect(function()
		if generation == coldJoinGeneration and not coldJoinTerminal then
			evaluateColdJoinReadiness()
		end
	end)
	coldJoinCameraSubjectConnection = camera:GetPropertyChangedSignal("CameraSubject"):Connect(function()
		if generation == coldJoinGeneration and not coldJoinTerminal then
			evaluateColdJoinReadiness()
		end
	end)
end

evaluateColdJoinReadiness = function()
	local generation = coldJoinGeneration
	local reason = alignmentRequestReason
	local character = alignmentRequestCharacter
	if coldJoinTerminal or not started or destroyed or not reason or not character then
		return
	end
	if os.clock() >= coldJoinDeadline then
		terminateColdJoinAlignment(generation)
		return
	end
	if not isReadyAlignmentPhaseEligible(reason, alignmentRequestRunId) or activeSession ~= nil then
		terminateColdJoinAlignment(generation)
		return
	end
	if pendingRestoration ~= nil then
		if coldJoinOwnsCamera then
			terminateColdJoinAlignment(generation)
		end
		return
	end

	if localPlayer.Character ~= character then
		terminateColdJoinAlignment(generation)
		return
	end
	if not character:IsDescendantOf(Workspace) then
		if coldJoinCharacterWasInWorkspace then
			terminateColdJoinAlignment(generation)
		end
		return
	end
	coldJoinCharacterWasInWorkspace = true

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if coldJoinHumanoid and coldJoinHumanoid ~= humanoid then
		terminateColdJoinAlignment(generation)
		return
	end
	if not humanoid then
		return
	end
	if not coldJoinHumanoid then
		coldJoinHumanoid = humanoid
		coldJoinHumanoidDiedConnection = humanoid.Died:Connect(function()
			terminateColdJoinAlignment(generation)
		end)
	end
	if humanoid.Parent ~= character or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		terminateColdJoinAlignment(generation)
		return
	end

	local rootInstance = character:FindFirstChild("HumanoidRootPart")
	if rootInstance and not rootInstance:IsA("BasePart") then
		terminateColdJoinAlignment(generation)
		return
	end
	local root = if rootInstance and rootInstance:IsA("BasePart") then rootInstance else nil
	if coldJoinRoot and coldJoinRoot ~= root then
		terminateColdJoinAlignment(generation)
		return
	end
	if not root then
		return
	end
	coldJoinRoot = root
	local positionStatus = validateReadyAlignmentPosition(root, reason, true)
	if positionStatus == "Cancel" then
		terminateColdJoinAlignment(generation)
		return
	end

	local currentCamera = Workspace.CurrentCamera
	if coldJoinOwnsCamera then
		local ownedCamera = coldJoinOwnedCamera
		if not ownedCamera
			or ownedCamera ~= coldJoinCamera
			or currentCamera ~= ownedCamera
			or not ownedCamera.Parent
			or ownedCamera.CameraType ~= Enum.CameraType.Scriptable
			or ownedCamera.CameraSubject ~= humanoid
		then
			terminateColdJoinAlignment(generation)
		end
		return
	end
	if currentCamera ~= coldJoinCamera then
		unbindColdJoinRenderStep()
		disconnectColdJoinCameraConnections()
		if currentCamera then
			observeColdJoinCamera(currentCamera, generation)
		end
	end
	local camera = coldJoinCamera
	if not camera or not camera.Parent then
		return
	end

	scheduleColdJoinAlignment(generation)
end

local function requestReadyAlignment(
	reason: ReadyAlignmentReason,
	character: Model,
	requestRunId: number?
)
	if not started
		or destroyed
		or localPlayer.Character ~= character
		or activeSession ~= nil
		or (requestRunId ~= nil and not isValidRunId(requestRunId))
		or not isReadyAlignmentPhaseEligible(reason, requestRunId)
	then
		return
	end

	if not coldJoinTerminal then
		local activeReason = alignmentRequestReason
		if alignmentRequestCharacter == character
			and activeReason ~= nil
			and isReadyAlignmentPhaseEligible(activeReason, alignmentRequestRunId)
		then
			evaluateColdJoinReadiness()
			return
		end
		terminateColdJoinAlignment(coldJoinGeneration)
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and (humanoid.Parent ~= character or humanoid.Health <= 0 or humanoid.SeatPart ~= nil) then
		return
	end
	local rootInstance = character:FindFirstChild("HumanoidRootPart")
	if rootInstance and not rootInstance:IsA("BasePart") then
		return
	end
	if rootInstance and rootInstance:IsA("BasePart") then
		local positionStatus = validateReadyAlignmentPosition(rootInstance, reason, true)
		if positionStatus == "Cancel" then
			return
		end
	end

	coldJoinGeneration += 1
	local generation = coldJoinGeneration
	alignmentRequestReason = reason
	alignmentRequestCharacter = character
	alignmentRequestRunId = requestRunId
	coldJoinTerminal = false
	coldJoinCharacterWasInWorkspace = character:IsDescendantOf(Workspace)
	coldJoinDeadline = os.clock() + COLD_JOIN_TIMEOUT_SECONDS
	coldJoinReadinessCallbackCount = 0
	clearColdJoinLease()
	coldJoinCharacterChildAddedConnection = character.ChildAdded:Connect(function()
		if generation == coldJoinGeneration and not coldJoinTerminal then
			evaluateColdJoinReadiness()
		end
	end)
	coldJoinCharacterChildRemovedConnection = character.ChildRemoved:Connect(function(child: Instance)
		if generation ~= coldJoinGeneration or coldJoinTerminal then
			return
		end
		if child == coldJoinHumanoid or child == coldJoinRoot then
			terminateColdJoinAlignment(generation)
		else
			evaluateColdJoinReadiness()
		end
	end)
	coldJoinCharacterAncestryConnection = character.AncestryChanged:Connect(function()
		if generation ~= coldJoinGeneration or coldJoinTerminal then
			return
		end
		if character:IsDescendantOf(Workspace) then
			coldJoinCharacterWasInWorkspace = true
			evaluateColdJoinReadiness()
		elseif coldJoinCharacterWasInWorkspace then
			terminateColdJoinAlignment(generation)
		end
	end)
	coldJoinTimeoutThread = task.delay(COLD_JOIN_TIMEOUT_SECONDS, function()
		if generation ~= coldJoinGeneration or coldJoinTerminal then
			return
		end
		coldJoinTimeoutThread = nil
		terminateColdJoinAlignment(generation)
	end)
	evaluateColdJoinReadiness()
end

local function consumeCharacterAlignmentBoundary(character: Model)
	if not coldJoinBoundaryConsumed then
		coldJoinBoundaryConsumed = true
		latestCharacterBoundary = character
		requestReadyAlignment("ColdJoin", character, nil)
		return
	end
	if latestCharacterBoundary == character then
		return
	end

	latestCharacterBoundary = character
	if currentRunId == nil or currentPhase == RunPhase.Idle then
		requestReadyAlignment("CharacterAdded", character, currentRunId)
	end
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
		evaluateColdJoinReadiness()
		return
	end
	if applyRestoration(pending.Snapshot, pending.ExcludedCharacter) and pendingRestoration == pending then
		clearPendingRestoration()
		evaluateColdJoinReadiness()
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
	if typeof(phase) ~= "string" or not isValidRunId(runId) then
		acceptRunState(phase, runId)
		return
	end

	local phaseName = phase :: string
	local acceptedRunId = runId :: number
	local rank = phaseRank(phaseName)
	local previousRunId = currentRunId
	local previousPhase = currentPhase
	local previousPhaseRank = currentPhaseRank
	local stale = acceptedRunId < latestRunId
		or (previousRunId == acceptedRunId and rank ~= nil and rank < previousPhaseRank)

	if not stale
		and not coldJoinTerminal
		and (acceptedRunId > latestRunId or rank == nil or phaseName ~= RunPhase.Idle)
	then
		terminateColdJoinAlignment(coldJoinGeneration)
	end

	acceptRunState(phase, runId)
	if stale or rank == nil then
		return
	end

	local acceptedResetToIdle = previousRunId == acceptedRunId
		and previousPhase == RunPhase.Reset
		and previousPhaseRank == phaseRank(RunPhase.Reset)
		and phaseName == RunPhase.Idle
		and currentRunId == acceptedRunId
		and currentPhase == RunPhase.Idle
		and currentPhaseRank == rank
	if not acceptedResetToIdle or acceptedRunId <= latestReturnIdleRunId then
		return
	end

	latestReturnIdleRunId = acceptedRunId
	local character = localPlayer.Character
	if character and character:IsA("Model") then
		requestReadyAlignment("ReturnToStart", character, acceptedRunId)
	end
end

local function onCharacterRemoving(character: Model)
	if alignmentRequestCharacter == character then
		terminateColdJoinAlignment(coldJoinGeneration)
	end
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
	if alignmentRequestCharacter and alignmentRequestCharacter ~= character then
		terminateColdJoinAlignment(coldJoinGeneration)
	end
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
	consumeCharacterAlignmentBoundary(character)
end

local function onCurrentCameraChanged()
	local session = activeSession
	if session and Workspace.CurrentCamera ~= session.Snapshot.Camera then
		invalidateActiveRun(session.RunId, nil)
	else
		tryCompletePendingRestoration()
	end
	evaluateColdJoinReadiness()
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
	resetReadyAlignmentLifecycle()

	table.insert(controllerConnections, runStateInstance.OnClientEvent:Connect(onRunState))
	table.insert(controllerConnections, localPlayer.CharacterRemoving:Connect(onCharacterRemoving))
	table.insert(controllerConnections, localPlayer.CharacterAdded:Connect(onCharacterAdded))
	table.insert(
		controllerConnections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(onCurrentCameraChanged)
	)
	table.insert(controllerConnections, script.Destroying:Connect(CameraController.destroy))

	local initialCharacter = localPlayer.Character
	if initialCharacter and initialCharacter:IsA("Model") then
		consumeCharacterAlignmentBoundary(initialCharacter)
	end
end

function CameraController.destroy()
	if destroyed then
		return
	end
	destroyed = true
	terminateColdJoinAlignment(coldJoinGeneration)
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
