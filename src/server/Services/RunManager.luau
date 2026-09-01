--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)
local SledFactory = require(script.Parent.SledFactory)

local RUN = GameConfig.Run
local WORLD = GameConfig.World

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local TUCK_REMOTE_NAME = "TuckIntent"
local STATE_REMOTE_NAME = "RunState"
local PROMPT_NAME = "StartRunPrompt"
local MIN_TUCK_REQUEST_INTERVAL = 0.06
local HUD_UPDATE_INTERVAL = 0.1
local MAX_START_DISTANCE = 20
local START_BOTTOM_CLEARANCE = 0.85
local ANTI_STALL_REACTIVATION_MARGIN = 1.5
local MIN_STABILITY_DIRECTION_SPEED = 4
local EARLY_STALL_CONFIRMATION_DURATION = 1
local EARLY_STALL_MAXIMUM_OBSERVATION_PROGRESS = 0.5
local EARLY_STALL_MAXIMUM_SPEED = 0.5
local EARLY_STALL_MAXIMUM_ANGULAR_SPEED = 0.5
local EARLY_STALL_MAXIMUM_DISTANCE = 65
local EARLY_STALL_MAXIMUM_DURATION = 5
local STALL_GROUND_CONTACT_CLEARANCE = 0.25
local STALL_RECOVERY_RESULT_MINIMUM_PROGRESS = 3
local STALL_RECOVERY_RESULT_MINIMUM_SPEED = 4
local STALL_RECOVERY_RESULT_DELAY = 0.5
local STALL_REJECTION_LOG_INTERVAL = 3
local TRACK_SURFACE_ATTRIBUTE = "FrostlineTrackSurface"
local MISSED_LAUNCH_OUTCOME = "missed-launch"

type Phase = RunPhase.Name
type Sled = SledFactory.Sled
type StallObservationKind = "recovery" | "missed-launch"
type RunOutcome = "missed-launch"

type WorldReferences = {
	ActiveSleds: Folder,
	StartTrigger: BasePart,
	SummitPlatform: BasePart,
	LaunchEdge: BasePart,
	LandingSurfaces: Folder,
	PlayerSpawn: SpawnLocation,
	LaunchZ: number,
	StudsPerMeter: number,
}

type Session = {
	RunId: number,
	Player: Player,
	Character: Model,
	Humanoid: Humanoid,
	Sled: Sled,
	TuckAttachment: Attachment,
	TuckForce: VectorForce,
	AntiStallForce: VectorForce,
	StabilityTorque: Torque,
	GroundRaycastParams: RaycastParams,
	Phase: Phase,
	CountdownValue: number?,
	OriginalMassless: { [BasePart]: boolean },
	Connections: { RBXScriptConnection },
	PlayerSpawn: SpawnLocation,
	LaunchZ: number,
	StudsPerMeter: number,
	DescentStartedAt: number?,
	LandingSettledSince: number?,
	LastTuckRequestAt: number,
	LastHudUpdateAt: number,
	TuckIntentHeld: boolean,
	TuckQueued: boolean,
	Tucking: boolean,
	TuckActivationReady: boolean,
	TuckQueueScheduled: boolean,
	AntiStallActive: boolean,
	RampFreedomEntered: boolean,
	CleanupStarted: boolean,
	FirstCleanupReason: string?,
	ReleaseInProgress: boolean,
	ReleasePositionZ: number?,
	StallObservationStartedAt: number?,
	StallObservationStartZ: number?,
	StallObservationKind: StallObservationKind?,
	StallRecoveryUsed: boolean,
	LastStallRejectionAt: number,
	HasEnteredAirborne: boolean,
	MissedLaunchConfirmed: boolean,
	Outcome: RunOutcome?,
	MaximumDescentProgress: number,
	StopConfirmed: boolean,
	TuckUsed: boolean,
	LaunchHorizontalSpeed: number?,
	TouchdownHorizontalSpeed: number?,
	MaximumDistance: number,
	FinalStopDistance: number?,
	TelemetryLogged: boolean,
}

type StallSnapshot = {
	Position: Vector3,
	Progress: number,
	ForwardSpeed: number,
	HorizontalSpeed: number,
	AngularSpeed: number,
	Grounded: boolean,
	GroundedOnTrack: boolean,
	GroundHit: string,
}

local RunManager = {}

local sessions: { [Player]: Session } = {}
local started = false
local stateRemote: RemoteEvent? = nil
local latestRunId = 0

local function isTransitionAllowed(currentPhase: Phase, nextPhase: Phase): boolean
	if currentPhase == RunPhase.Idle then
		return nextPhase == RunPhase.Countdown
	elseif currentPhase == RunPhase.Countdown then
		return nextPhase == RunPhase.Descent or nextPhase == RunPhase.Reset
	elseif currentPhase == RunPhase.Descent then
		return nextPhase == RunPhase.Airborne or nextPhase == RunPhase.Results or nextPhase == RunPhase.Reset
	elseif currentPhase == RunPhase.Airborne then
		return nextPhase == RunPhase.Landed or nextPhase == RunPhase.Reset
	elseif currentPhase == RunPhase.Landed then
		return nextPhase == RunPhase.Results or nextPhase == RunPhase.Reset
	elseif currentPhase == RunPhase.Results then
		return nextPhase == RunPhase.Reset
	elseif currentPhase == RunPhase.Reset then
		return nextPhase == RunPhase.Idle
	end

	return false
end

local function isSameSession(session: Session, runId: number): boolean
	local activeSession = sessions[session.Player]
	return activeSession ~= nil and activeSession == session and activeSession.RunId == runId
end

local function runLabel(session: Session): string
	return string.format("player=%s RunId=%d", session.Player.Name, session.RunId)
end

local function isFinitePositiveNumber(value: number): boolean
	return value == value and value > 0 and value < math.huge
end

local function sendState(session: Session)
	local remote = stateRemote
	if not remote or session.Player.Parent ~= Players then
		return
	end

	local speed = 0
	if session.Sled.Root.Parent then
		speed = session.Sled.Root.AssemblyLinearVelocity.Magnitude
	end

	remote:FireClient(
		session.Player,
		session.Phase,
		session.CountdownValue,
		speed,
		session.RunId,
		session.TuckQueued,
		session.Tucking,
		session.Outcome
	)
end

local function transitionTo(session: Session, nextPhase: Phase): boolean
	if session.Phase == nextPhase then
		sendState(session)
		return true
	end

	if not isTransitionAllowed(session.Phase, nextPhase) then
		warn(
			string.format(
				"[Frostline][Run] %s Refused transition %s -> %s",
				runLabel(session),
				session.Phase,
				nextPhase
			)
		)
		return false
	end

	session.Phase = nextPhase
	if nextPhase ~= RunPhase.Countdown then
		session.CountdownValue = nil
	end
	sendState(session)
	return true
end

local function setTuckActive(session: Session, active: boolean)
	local forceAvailable = session.TuckForce.Parent ~= nil
	local root = session.Sled.Root
	local assemblyMass = math.huge
	if root.Parent and not root.Anchored then
		assemblyMass = root.AssemblyMass
	end
	local hasUsableMass = isFinitePositiveNumber(assemblyMass)
	local shouldApply = active
		and forceAvailable
		and not session.CleanupStarted
		and session.TuckActivationReady
		and session.Phase == RunPhase.Descent
		and root.Parent ~= nil
		and not root.Anchored
		and hasUsableMass
		and root.Position.Z < session.LaunchZ
	session.Tucking = shouldApply

	if shouldApply then
		session.TuckForce.Force = Vector3.new(0, 0, assemblyMass * RUN.TuckAcceleration)
		session.TuckForce.Enabled = true
		session.TuckUsed = true
	elseif forceAvailable then
		session.TuckForce.Enabled = false
		session.TuckForce.Force = Vector3.zero
	end
end

local function clearTuckState(session: Session)
	session.TuckIntentHeld = false
	session.TuckQueued = false
	session.TuckActivationReady = false
	session.TuckQueueScheduled = false
	setTuckActive(session, false)
end

local function validateRelease(
	session: Session,
	runId: number,
	expectedPhase: Phase,
	expectedAnchored: boolean
): (boolean, string)
	if not isSameSession(session, runId) then
		return false, "session changed"
	elseif session.CleanupStarted then
		return false, "cleanup started"
	elseif session.Player.Parent ~= Players then
		return false, "player unavailable"
	elseif session.Player.Character ~= session.Character or not session.Character.Parent then
		return false, "character unavailable"
	elseif session.Humanoid.Parent ~= session.Character or session.Humanoid.Health <= 0 then
		return false, "Humanoid unavailable"
	elseif session.Phase ~= expectedPhase then
		return false, string.format("phase is %s", session.Phase)
	end

	local sled = session.Sled
	if not sled.Model.Parent or not sled.Model:IsDescendantOf(Workspace) then
		return false, "sled unavailable"
	elseif sled.Root.Parent ~= sled.Model or not sled.Root:IsDescendantOf(Workspace) then
		return false, "root unavailable"
	elseif sled.DriverSeat.Parent ~= sled.Model or not sled.DriverSeat:IsDescendantOf(Workspace) then
		return false, "seat unavailable"
	elseif sled.DriverSeat.Occupant ~= session.Humanoid then
		return false, "seat occupant changed"
	elseif sled.Root.Anchored ~= expectedAnchored then
		return false, if expectedAnchored then "root unexpectedly unanchored" else "root unexpectedly anchored"
	elseif not expectedAnchored and not isFinitePositiveNumber(sled.Root.AssemblyMass) then
		return false, "root mass is not finite"
	end

	return true, "ok"
end

local function logReleaseValidity(
	session: Session,
	stage: string,
	valid: boolean,
	reason: string
)
	local sled = session.Sled
	local characterValid = session.Player.Character == session.Character and session.Character.Parent ~= nil
	local humanoidValid = session.Humanoid.Parent == session.Character and session.Humanoid.Health > 0
	local modelValid = sled.Model.Parent ~= nil and sled.Model:IsDescendantOf(Workspace)
	local rootValid = sled.Root.Parent == sled.Model and sled.Root:IsDescendantOf(Workspace)
	local seatValid = sled.DriverSeat.Parent == sled.Model and sled.DriverSeat:IsDescendantOf(Workspace)
	local occupantValid = seatValid and sled.DriverSeat.Occupant == session.Humanoid
	local message = string.format(
		"[Frostline][Run] %s Release validity stage=%s valid=%s reason=%s character=%s humanoid=%s sled=%s root=%s seat=%s occupant=%s anchored=%s held=%s queued=%s",
		runLabel(session),
		stage,
		tostring(valid),
		reason,
		tostring(characterValid),
		tostring(humanoidValid),
		tostring(modelValid),
		tostring(rootValid),
		tostring(seatValid),
		tostring(occupantValid),
		tostring(sled.Root.Anchored),
		tostring(session.TuckIntentHeld),
		tostring(session.TuckQueued)
	)
	if valid then
		print(message)
	else
		warn(message)
	end
end

local function setAntiStallActive(session: Session, runId: number, active: boolean)
	local forceAvailable = session.AntiStallForce.Parent ~= nil
	local root = session.Sled.Root
	local assemblyMass = math.huge
	if root.Parent and not root.Anchored then
		assemblyMass = root.AssemblyMass
	end
	local shouldApply = active
		and forceAvailable
		and isSameSession(session, runId)
		and not session.CleanupStarted
		and session.TuckActivationReady
		and not session.RampFreedomEntered
		and session.Phase == RunPhase.Descent
		and root.Parent ~= nil
		and not root.Anchored
		and isFinitePositiveNumber(assemblyMass)

	if shouldApply == session.AntiStallActive then
		return
	end

	session.AntiStallActive = shouldApply
	if shouldApply then
		session.AntiStallForce.Force = Vector3.new(
			0,
			0,
			assemblyMass * RUN.AntiStallAcceleration
		)
		session.AntiStallForce.Enabled = true
		print(string.format("[Frostline][Run] %s AntiStall activated", runLabel(session)))
	elseif forceAvailable then
		session.AntiStallForce.Enabled = false
		session.AntiStallForce.Force = Vector3.zero
		print(string.format("[Frostline][Run] %s AntiStall deactivated", runLabel(session)))
	end
end

local function updateAntiStall(session: Session, runId: number)
	if session.Phase ~= RunPhase.Descent
		or session.DescentStartedAt == nil
		or session.CleanupStarted
		or not session.TuckActivationReady
		or session.RampFreedomEntered
		or not session.Sled.Root.Parent
	then
		setAntiStallActive(session, runId, false)
		return
	end

	local forwardSpeed = session.Sled.Root.AssemblyLinearVelocity.Z
	if session.AntiStallActive then
		if forwardSpeed >= RUN.AntiStallSpeed then
			setAntiStallActive(session, runId, false)
		end
	elseif forwardSpeed < RUN.AntiStallSpeed - ANTI_STALL_REACTIVATION_MARGIN then
		setAntiStallActive(session, runId, true)
	end
end

local function isTrackSurface(instance: Instance): boolean
	return string.match(instance.Name, "^Track_%d+$") ~= nil
		or instance:GetAttribute(TRACK_SURFACE_ATTRIBUTE) == true
end

local function getStallGroundRayDistance(root: Part): number
	local halfSize = root.Size * 0.5
	local rootCFrame = root.CFrame
	local verticalHalfExtent = math.abs(rootCFrame.RightVector.Y) * halfSize.X
		+ math.abs(rootCFrame.UpVector.Y) * halfSize.Y
		+ math.abs(rootCFrame.LookVector.Y) * halfSize.Z
	return verticalHalfExtent + STALL_GROUND_CONTACT_CLEARANCE
end

local function getStallSnapshot(session: Session, root: Part, releasePositionZ: number): StallSnapshot
	local velocity = root.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local rayResult = Workspace:Raycast(
		root.Position,
		Vector3.new(0, -getStallGroundRayDistance(root), 0),
		session.GroundRaycastParams
	)
	local groundHit = if rayResult then rayResult.Instance.Name else "none"
	local grounded = rayResult ~= nil and rayResult.Instance.CanCollide
	local groundedOnTrack = rayResult ~= nil
		and rayResult.Instance.CanCollide
		and isTrackSurface(rayResult.Instance)

	return {
		Position = root.Position,
		Progress = root.Position.Z - releasePositionZ,
		ForwardSpeed = velocity.Z,
		HorizontalSpeed = horizontalSpeed,
		AngularSpeed = root.AssemblyAngularVelocity.Magnitude,
		Grounded = grounded,
		GroundedOnTrack = groundedOnTrack,
		GroundHit = groundHit,
	}
end

local function evaluateStoppedCandidate(
	root: Part,
	snapshot: StallSnapshot,
	requireTrackSurface: boolean
): (boolean, string)
	if root.Anchored then
		return false, "root-anchored"
	elseif not isFinitePositiveNumber(root.AssemblyMass) then
		return false, "root-mass-invalid"
	elseif math.abs(snapshot.ForwardSpeed) > EARLY_STALL_MAXIMUM_SPEED then
		return false, "forward-speed"
	elseif snapshot.HorizontalSpeed > EARLY_STALL_MAXIMUM_SPEED then
		return false, "horizontal-speed"
	elseif snapshot.AngularSpeed > EARLY_STALL_MAXIMUM_ANGULAR_SPEED then
		return false, "angular-speed"
	elseif not snapshot.Grounded then
		return false, "not-grounded:" .. snapshot.GroundHit
	elseif requireTrackSurface and not snapshot.GroundedOnTrack then
		return false, "not-track-surface:" .. snapshot.GroundHit
	end

	return true, "ok"
end

local function evaluateEarlyRecoveryCandidate(root: Part, snapshot: StallSnapshot): (boolean, string)
	local stopped, stoppedReason = evaluateStoppedCandidate(root, snapshot, true)
	if not stopped then
		return false, stoppedReason
	end

	local maximumLateralPosition = WORLD.TrackWidth * 0.5 - math.max(root.Size.X, root.Size.Z) * 0.5
	if math.abs(snapshot.Position.X) > maximumLateralPosition then
		return false, "outside-track-footprint"
	end

	return true, "ok"
end

local function resetStallObservation(session: Session)
	session.StallObservationStartedAt = nil
	session.StallObservationStartZ = nil
	session.StallObservationKind = nil
end

local function updateStallObservation(
	session: Session,
	kind: StallObservationKind,
	root: Part,
	now: number
): (boolean, number)
	local observationStartedAt = session.StallObservationStartedAt
	local observationStartZ = session.StallObservationStartZ
	if session.StallObservationKind ~= kind or observationStartedAt == nil or observationStartZ == nil then
		session.StallObservationKind = kind
		session.StallObservationStartedAt = now
		session.StallObservationStartZ = root.Position.Z
		return false, 0
	end

	local observationProgress = math.abs(root.Position.Z - observationStartZ)
	if observationProgress > EARLY_STALL_MAXIMUM_OBSERVATION_PROGRESS then
		session.StallObservationStartedAt = now
		session.StallObservationStartZ = root.Position.Z
		return false, observationProgress
	end

	return now - observationStartedAt >= EARLY_STALL_CONFIRMATION_DURATION, observationProgress
end

local function isCurrentSledRootValid(session: Session, root: Part): boolean
	local sled = session.Sled
	return sled.Model.Parent ~= nil
		and sled.Model:IsDescendantOf(Workspace)
		and root == sled.Root
		and root.Parent == sled.Model
		and root:IsDescendantOf(Workspace)
		and not root.Anchored
		and isFinitePositiveNumber(root.AssemblyMass)
end

local function logStallRecoveryRejection(
	session: Session,
	now: number,
	reason: string,
	snapshot: StallSnapshot
)
	if now - session.LastStallRejectionAt < STALL_REJECTION_LOG_INTERVAL then
		return
	end
	session.LastStallRejectionAt = now
	print(
		string.format(
			"[Frostline][Run] %s Stall recovery rejected reason=%s progress=%.2f position=(%.1f, %.1f, %.1f) forwardSpeed=%.2f horizontalSpeed=%.2f angularSpeed=%.2f grounded=%s groundHit=%s recoveryUsed=%s",
			runLabel(session),
			reason,
			snapshot.Progress,
			snapshot.Position.X,
			snapshot.Position.Y,
			snapshot.Position.Z,
			snapshot.ForwardSpeed,
			snapshot.HorizontalSpeed,
			snapshot.AngularSpeed,
			tostring(snapshot.Grounded),
			snapshot.GroundHit,
			tostring(session.StallRecoveryUsed)
		)
	)
end

local function updateDescentStopDetection(session: Session, runId: number, now: number): StallSnapshot?
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.ReleaseInProgress
		or not session.TuckActivationReady
		or session.Phase ~= RunPhase.Descent
		or session.HasEnteredAirborne
	then
		resetStallObservation(session)
		return nil
	end

	local releasePositionZ = session.ReleasePositionZ
	local descentStartedAt = session.DescentStartedAt
	if releasePositionZ == nil or descentStartedAt == nil then
		resetStallObservation(session)
		return nil
	end

	local root = session.Sled.Root
	if not isCurrentSledRootValid(session, root) then
		resetStallObservation(session)
		return nil
	end

	local snapshot = getStallSnapshot(session, root, releasePositionZ)
	session.MaximumDescentProgress = math.max(session.MaximumDescentProgress, snapshot.Progress)
	local elapsed = now - descentStartedAt
	local insideEarlyWindow = elapsed <= EARLY_STALL_MAXIMUM_DURATION
		and session.MaximumDescentProgress <= EARLY_STALL_MAXIMUM_DISTANCE
		and not session.RampFreedomEntered
	local atForwardFrontier = session.MaximumDescentProgress - snapshot.Progress
		<= EARLY_STALL_MAXIMUM_OBSERVATION_PROGRESS
	local missedLaunchEligible = session.StallRecoveryUsed or not insideEarlyWindow
	local observationKind: StallObservationKind = if missedLaunchEligible then "missed-launch" else "recovery"

	local candidateAccepted = false
	local rejectionReason = "unknown"
	if missedLaunchEligible then
		candidateAccepted, rejectionReason = evaluateStoppedCandidate(root, snapshot, false)
	else
		local releaseValid, releaseReason = validateRelease(session, runId, RunPhase.Descent, false)
		if not releaseValid then
			candidateAccepted = false
			rejectionReason = "release-invalid:" .. releaseReason
		elseif not atForwardFrontier then
			candidateAccepted = false
			rejectionReason = "rollback-from-maximum"
		else
			candidateAccepted, rejectionReason = evaluateEarlyRecoveryCandidate(root, snapshot)
		end
	end

	if not candidateAccepted then
		resetStallObservation(session)
		local nearZeroForwardSpeed = math.abs(snapshot.ForwardSpeed) <= EARLY_STALL_MAXIMUM_SPEED
		if not missedLaunchEligible and nearZeroForwardSpeed then
			logStallRecoveryRejection(session, now, rejectionReason, snapshot)
		end
		return nil
	end

	if missedLaunchEligible and not session.StallRecoveryUsed then
		logStallRecoveryRejection(session, now, "outside-safety-window", snapshot)
	end

	local confirmed, observationProgress = updateStallObservation(session, observationKind, root, now)
	if not confirmed then
		return nil
	end

	if missedLaunchEligible then
		if not isSameSession(session, runId)
			or session.CleanupStarted
			or session.ReleaseInProgress
			or not session.TuckActivationReady
			or session.Phase ~= RunPhase.Descent
			or session.HasEnteredAirborne
			or session.MissedLaunchConfirmed
			or not isCurrentSledRootValid(session, root)
		then
			resetStallObservation(session)
			return nil
		end

		local finalSnapshot = getStallSnapshot(session, root, releasePositionZ)
		session.MaximumDescentProgress = math.max(session.MaximumDescentProgress, finalSnapshot.Progress)
		local finalElapsed = now - descentStartedAt
		local finalMissedLaunchEligible = session.StallRecoveryUsed
			or finalElapsed > EARLY_STALL_MAXIMUM_DURATION
			or session.MaximumDescentProgress > EARLY_STALL_MAXIMUM_DISTANCE
			or session.RampFreedomEntered
		local finalCandidateAccepted = evaluateStoppedCandidate(root, finalSnapshot, false)
		if not finalMissedLaunchEligible or not finalCandidateAccepted then
			resetStallObservation(session)
			return nil
		end

		resetStallObservation(session)
		return finalSnapshot
	end

	local releaseValid, releaseReason = validateRelease(session, runId, RunPhase.Descent, false)
	if not releaseValid then
		resetStallObservation(session)
		logStallRecoveryRejection(session, now, "release-invalid:" .. releaseReason, snapshot)
		return nil
	end

	local finalSnapshot = getStallSnapshot(session, root, releasePositionZ)
	session.MaximumDescentProgress = math.max(session.MaximumDescentProgress, finalSnapshot.Progress)
	local finalElapsed = now - descentStartedAt
	local finalAtForwardFrontier = session.MaximumDescentProgress - finalSnapshot.Progress
		<= EARLY_STALL_MAXIMUM_OBSERVATION_PROGRESS
	local finalCandidateAccepted, finalRejectionReason = evaluateEarlyRecoveryCandidate(root, finalSnapshot)
	local finalContextRejection: string? = nil
	if session.StallRecoveryUsed then
		finalContextRejection = "already-used"
	elseif finalElapsed > EARLY_STALL_MAXIMUM_DURATION
		or session.MaximumDescentProgress > EARLY_STALL_MAXIMUM_DISTANCE
		or session.RampFreedomEntered
	then
		finalContextRejection = "outside-safety-window"
	elseif not finalAtForwardFrontier then
		finalContextRejection = "rollback-from-maximum"
	elseif not finalCandidateAccepted then
		finalContextRejection = finalRejectionReason
	end
	if finalContextRejection then
		resetStallObservation(session)
		logStallRecoveryRejection(session, now, finalContextRejection, finalSnapshot)
		return nil
	end

	session.StallRecoveryUsed = true
	resetStallObservation(session)
	local recoveryStartZ = root.Position.Z
	local currentVelocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(
		currentVelocity.X,
		currentVelocity.Y,
		math.max(currentVelocity.Z, RUN.InitialPushSpeed)
	)
	print(
		string.format(
			"[Frostline][Run] %s Stall recovery confirmed progress=%.2f forwardSpeed=%.2f reappliedSpeed=%.2f",
			runLabel(session),
			observationProgress,
			finalSnapshot.ForwardSpeed,
			root.AssemblyLinearVelocity.Z
		)
	)

	task.delay(STALL_RECOVERY_RESULT_DELAY, function()
		if not isSameSession(session, runId) then
			return
		end
		if session.CleanupStarted then
			print(string.format("[Frostline][Run] %s Stall recovery result=cleanup-started", runLabel(session)))
			return
		end
		if not root.Parent then
			print(string.format("[Frostline][Run] %s Stall recovery result=root-unavailable", runLabel(session)))
			return
		end

		local recoveredProgress = root.Position.Z - recoveryStartZ
		local recoveredSpeed = root.AssemblyLinearVelocity.Z
		local recovered = recoveredProgress > STALL_RECOVERY_RESULT_MINIMUM_PROGRESS
			or recoveredSpeed > STALL_RECOVERY_RESULT_MINIMUM_SPEED
		print(
			string.format(
				"[Frostline][Run] %s Stall recovery result=%s progress=%.2f forwardSpeed=%.2f",
				runLabel(session),
				if recovered then "recovered" else "still-stalled",
				recoveredProgress,
				recoveredSpeed
			)
		)
	end)
	return nil
end

local function setStabilityActive(session: Session, active: boolean)
	local torqueAvailable = session.StabilityTorque.Parent ~= nil
	local shouldApply = active
		and torqueAvailable
		and not session.CleanupStarted
		and not session.RampFreedomEntered
		and session.Phase == RunPhase.Descent
		and session.Sled.Root.Parent ~= nil

	if shouldApply then
		session.StabilityTorque.Enabled = true
	else
		if torqueAvailable then
			session.StabilityTorque.Enabled = false
			session.StabilityTorque.Torque = Vector3.zero
		end
	end
end

local function updateGroundStability(session: Session)
	if session.Phase ~= RunPhase.Descent
		or session.CleanupStarted
		or session.RampFreedomEntered
		or not session.Sled.Root.Parent
	then
		setStabilityActive(session, false)
		return
	end

	local root = session.Sled.Root
	local rayResult = Workspace:Raycast(
		root.Position,
		Vector3.new(0, -RUN.StabilityRayDistance, 0),
		session.GroundRaycastParams
	)
	if not rayResult then
		setStabilityActive(session, false)
		return
	end
	if not isTrackSurface(rayResult.Instance) then
		setStabilityActive(session, false)
		return
	end

	local linearVelocity = root.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(linearVelocity.X, 0, linearVelocity.Z)
	local lookVector = root.CFrame.LookVector
	local horizontalForward = Vector3.new(lookVector.X, 0, lookVector.Z)
	if horizontalVelocity.Magnitude < MIN_STABILITY_DIRECTION_SPEED or horizontalForward.Magnitude < 0.001 then
		setStabilityActive(session, false)
		return
	end

	local forwardDirection = horizontalForward.Unit
	local velocityDirection = horizontalVelocity.Unit
	local yawError = math.atan2(
		forwardDirection:Cross(velocityDirection).Y,
		math.clamp(forwardDirection:Dot(velocityDirection), -1, 1)
	)
	local angularVelocity = root.AssemblyAngularVelocity
	local rollAxis = lookVector.Unit
	local rootUp = root.CFrame.UpVector
	local projectedUp = rootUp - rollAxis * rootUp:Dot(rollAxis)
	local projectedWorldUp = Vector3.yAxis - rollAxis * Vector3.yAxis:Dot(rollAxis)
	if projectedUp.Magnitude < 0.001 or projectedWorldUp.Magnitude < 0.001 then
		setStabilityActive(session, false)
		return
	end
	local currentUp = projectedUp.Unit
	local desiredUp = projectedWorldUp.Unit
	local rollError = math.atan2(
		rollAxis:Dot(currentUp:Cross(desiredUp)),
		math.clamp(currentUp:Dot(desiredUp), -1, 1)
	)
	local rollRate = angularVelocity:Dot(rollAxis)
	local yawTorque = yawError * RUN.StabilityYawResponse
		- angularVelocity.Y * RUN.StabilityAngularDamping
	local rollTorque = rollError * RUN.StabilityRollResponse
		- rollRate * RUN.StabilityAngularDamping
	local stabilityTorque = Vector3.yAxis * yawTorque + rollAxis * rollTorque
	local maximumTorque = RUN.MaximumStabilityTorque

	if stabilityTorque.Magnitude > maximumTorque then
		stabilityTorque = stabilityTorque.Unit * maximumTorque
	end

	setStabilityActive(session, true)
	session.StabilityTorque.Torque = stabilityTorque
end

local function enterRampFreedom(session: Session, runId: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.RampFreedomEntered
		or session.Phase ~= RunPhase.Descent
		or not session.Sled.Root.Parent
	then
		return
	end

	session.RampFreedomEntered = true
	resetStallObservation(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
end

local function updateRampFreedom(session: Session, runId: number)
	if session.Phase == RunPhase.Descent
		and not session.RampFreedomEntered
		and session.Sled.Root.Parent
		and session.Sled.Root.Position.Z >= RUN.RampFreedomStartZ
	then
		enterRampFreedom(session, runId)
	end
end

local function makeCharacterMassless(character: Model): { [BasePart]: boolean }
	local originalMassless: { [BasePart]: boolean } = {}

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			originalMassless[descendant] = descendant.Massless
			descendant.Massless = true
		end
	end

	return originalMassless
end

local function restoreCharacterMass(characterMassless: { [BasePart]: boolean })
	for part, wasMassless in characterMassless do
		if part.Parent then
			part.Massless = wasMassless
		end
	end
end

local function disconnectSession(session: Session)
	for _, connection in session.Connections do
		connection:Disconnect()
	end
	table.clear(session.Connections)
end

local function teleportToSpawn(session: Session, runId: number): boolean
	if session.Player.Parent ~= Players then
		return false
	end

	local character = session.Player.Character
	local humanoidRootPart = session.Character:FindFirstChild("HumanoidRootPart")
	if character ~= session.Character
		or not session.Character.Parent
		or not humanoidRootPart
		or not humanoidRootPart:IsA("BasePart")
	then
		warn(string.format("[Frostline][Run] %s Teleport verification result=character unavailable", runLabel(session)))
		return false
	end

	local originalAnchored = humanoidRootPart.Anchored
	local function restoreRootAnchored()
		pcall(function()
			humanoidRootPart.Anchored = originalAnchored
		end)
	end

	local targetCFrame = CFrame.new()
	local targetAvailable = pcall(function()
		targetCFrame = session.PlayerSpawn.CFrame + Vector3.new(0, 4, 0)
	end)
	if not targetAvailable then
		warn(string.format("[Frostline][Run] %s Teleport verification result=spawn unavailable", runLabel(session)))
		return false
	end

	local function readTeleportDistance(): (boolean, number)
		local distance = math.huge
		local succeeded = pcall(function()
			if not humanoidRootPart.Parent or humanoidRootPart.Parent ~= session.Character then
				error("HumanoidRootPart is no longer in the run character")
			end
			distance = (humanoidRootPart.Position - targetCFrame.Position).Magnitude
		end)
		return succeeded, distance
	end

	local setupSucceeded = pcall(function()
		humanoidRootPart.Anchored = true
		humanoidRootPart.AssemblyLinearVelocity = Vector3.zero
		humanoidRootPart.AssemblyAngularVelocity = Vector3.zero
		session.Character:PivotTo(targetCFrame)
	end)
	if not setupSucceeded then
		restoreRootAnchored()
		warn(string.format("[Frostline][Run] %s Teleport verification result=initial pivot failed", runLabel(session)))
		return false
	end

	RunService.Heartbeat:Wait()
	if not isSameSession(session, runId) then
		restoreRootAnchored()
		return false
	end

	local distanceAvailable, distance = readTeleportDistance()
	if not distanceAvailable then
		restoreRootAnchored()
		warn(string.format("[Frostline][Run] %s Teleport verification result=character invalid", runLabel(session)))
		return false
	end
	local retried = false
	if distance > 8 then
		retried = true
		warn(
			string.format(
				"[Frostline][Run] %s Teleport verification failed distance=%.1f; retrying",
				runLabel(session),
				distance
			)
		)
		pcall(function()
			humanoidRootPart.AssemblyLinearVelocity = Vector3.zero
			humanoidRootPart.AssemblyAngularVelocity = Vector3.zero
			session.Character:PivotTo(targetCFrame)
		end)
		RunService.Heartbeat:Wait()
		if not isSameSession(session, runId) then
			restoreRootAnchored()
			return false
		end
		local retryDistanceAvailable, retryDistance = readTeleportDistance()
		if not retryDistanceAvailable then
			restoreRootAnchored()
			warn(
				string.format("[Frostline][Run] %s Teleport verification result=character invalid after retry", runLabel(session))
			)
			return false
		end
		distance = retryDistance
	end

	restoreRootAnchored()
	pcall(function()
		session.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)

	local verified = distance <= 8
	print(
		string.format(
			"[Frostline][Run] %s Teleport verification result=%s distance=%.1f retried=%s",
			runLabel(session),
			if verified then "passed" else "failed",
			distance,
			tostring(retried)
		)
	)
	return verified
end

local function cleanupSession(session: Session, runId: number, teleportPlayer: boolean, reason: string)
	if not isSameSession(session, runId) then
		return
	end

	disconnectSession(session)
	pcall(function()
		if session.Humanoid.Parent then
			session.Humanoid.Sit = false
		end
	end)
	pcall(function()
		local seatWeld = session.Sled.DriverSeat:FindFirstChild("SeatWeld")
		if seatWeld then
			seatWeld:Destroy()
		end
	end)

	RunService.Heartbeat:Wait()
	if not isSameSession(session, runId) then
		return
	end

	if session.Sled.Model.Parent then
		session.Sled.Model:Destroy()
	end
	restoreCharacterMass(session.OriginalMassless)

	if teleportPlayer then
		local teleportCallSucceeded, teleportError = pcall(teleportToSpawn, session, runId)
		if not teleportCallSucceeded then
			warn(
				string.format(
					"[Frostline][Run] %s Teleport verification result=error detail=%s",
					runLabel(session),
					tostring(teleportError)
				)
			)
		end
	end

	if not isSameSession(session, runId) then
		return
	end
	if session.Player.Parent == Players then
		session.Outcome = nil
		transitionTo(session, RunPhase.Idle)
	end
	sessions[session.Player] = nil
	print(
		string.format(
			"[Frostline][Run] %s Cleanup completed reason=%s",
			runLabel(session),
			reason
		)
	)
end

local function formatTelemetryNumber(value: number?): string
	return if value == nil then "n/a" else string.format("%.2f", value)
end

local function distanceFromLaunch(session: Session, zPosition: number): number
	return math.max(0, (zPosition - session.LaunchZ) / session.StudsPerMeter)
end

local function updateMaximumDistance(session: Session)
	if not session.Sled.Root.Parent then
		return
	end

	session.MaximumDistance = math.max(
		session.MaximumDistance,
		distanceFromLaunch(session, session.Sled.Root.Position.Z)
	)
end

local function emitTelemetry(session: Session)
	if session.TelemetryLogged then
		return
	end
	session.TelemetryLogged = true
	local fieldDistance = WORLD.LandingMarkedDistanceMeters + WORLD.LandingRunoffDistanceMeters
	local finalStopDistance = session.FinalStopDistance
	local remainingDistance = if finalStopDistance == nil
		then nil
		else math.max(0, fieldDistance - finalStopDistance)

	local telemetryMessage = string.format(
		"[Frostline][Telemetry] player=%s RunId=%d mode=%s launchHorizontalSpeed=%s touchdownHorizontalSpeed=%s maximumDistanceM=%.2f finalStopDistanceM=%s remainingToFieldEndM=%s",
		session.Player.Name,
		session.RunId,
		if session.TuckUsed then "tuck" else "no-tuck",
		formatTelemetryNumber(session.LaunchHorizontalSpeed),
		formatTelemetryNumber(session.TouchdownHorizontalSpeed),
		session.MaximumDistance,
		formatTelemetryNumber(session.FinalStopDistance),
		formatTelemetryNumber(remainingDistance)
	)
	if session.Outcome == MISSED_LAUNCH_OUTCOME then
		telemetryMessage ..= string.format(
			" outcome=%s maximumProgressStuds=%.2f",
			MISSED_LAUNCH_OUTCOME,
			session.MaximumDescentProgress
		)
	end
	print(telemetryMessage)
end

local function requestCleanup(session: Session, runId: number, reason: string, teleportPlayer: boolean)
	if not isSameSession(session, runId) then
		return
	end
	if session.CleanupStarted then
		print(
			string.format(
				"[Frostline][Run] %s Duplicate cleanup ignored reason=%s firstReason=%s",
				runLabel(session),
				reason,
				session.FirstCleanupReason or "unknown"
			)
		)
		return
	end

	-- This flag is deliberately first: changing Reset state, seating, or physics can fire callbacks.
	session.CleanupStarted = true
	session.FirstCleanupReason = reason
	print(string.format("[Frostline][Run] %s Cleanup requested firstReason=%s", runLabel(session), reason))
	session.ReleaseInProgress = false
	resetStallObservation(session)
	clearTuckState(session)
	emitTelemetry(session)
	if session.Phase ~= RunPhase.Reset and not transitionTo(session, RunPhase.Reset) then
		session.Phase = RunPhase.Reset
		session.CountdownValue = nil
		sendState(session)
	end

	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)

	task.defer(function()
		if isSameSession(session, runId) then
			cleanupSession(session, runId, teleportPlayer, session.FirstCleanupReason or reason)
		end
	end)
end

local function finishMissedLaunch(session: Session, runId: number, snapshot: StallSnapshot)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.ReleaseInProgress
		or not session.TuckActivationReady
		or session.Phase ~= RunPhase.Descent
		or session.HasEnteredAirborne
		or session.MissedLaunchConfirmed
	then
		return
	end

	session.MissedLaunchConfirmed = true
	session.Outcome = MISSED_LAUNCH_OUTCOME
	session.MaximumDescentProgress = math.max(session.MaximumDescentProgress, snapshot.Progress)
	resetStallObservation(session)
	clearTuckState(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
	print(
		string.format(
			"[Frostline][Run] %s Missed launch confirmed progress=%.2f horizontalSpeed=%.2f angularSpeed=%.2f",
			runLabel(session),
			session.MaximumDescentProgress,
			snapshot.HorizontalSpeed,
			snapshot.AngularSpeed
		)
	)

	if not transitionTo(session, RunPhase.Results) then
		requestCleanup(session, runId, "missed launch transition failed", true)
		return
	end

	task.delay(RUN.ResultsPauseDuration, function()
		if isSameSession(session, runId)
			and not session.CleanupStarted
			and session.MissedLaunchConfirmed
			and session.Outcome == MISSED_LAUNCH_OUTCOME
			and session.Phase == RunPhase.Results
		then
			requestCleanup(session, runId, "missed launch physically stopped", true)
		end
	end)
end

local function finishLanding(session: Session, runId: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Landed
		or session.StopConfirmed
	then
		return
	end

	local root = session.Sled.Root
	if not root.Parent then
		requestCleanup(session, runId, "sled removed during landing", true)
		return
	end

	local position = root.Position
	local velocity = root.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local angularSpeed = root.AssemblyAngularVelocity.Magnitude
	updateMaximumDistance(session)
	session.FinalStopDistance = distanceFromLaunch(session, position.Z)
	session.StopConfirmed = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.Anchored = true

	print(
		string.format(
			"[Frostline][Run] %s Landing stop confirmed position=(%.1f, %.1f, %.1f) speed=%.2f angularSpeed=%.2f",
			runLabel(session),
			position.X,
			position.Y,
			position.Z,
			horizontalSpeed,
			angularSpeed
		)
	)
	if not transitionTo(session, RunPhase.Results) then
		requestCleanup(session, runId, "results transition failed", true)
		return
	end

	task.delay(RUN.ResultsPauseDuration, function()
		if isSameSession(session, runId)
			and not session.CleanupStarted
			and session.StopConfirmed
			and session.Phase == RunPhase.Results
		then
			requestCleanup(session, runId, "landing physically stopped", true)
		end
	end)
end

local function updateLandingStopDetection(session: Session, runId: number, now: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Landed
		or session.StopConfirmed
		or not session.Sled.Root.Parent
	then
		return
	end

	local root = session.Sled.Root
	local velocity = root.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local angularVelocity = root.AssemblyAngularVelocity

	local horizontalSpeed = horizontalVelocity.Magnitude
	local angularSpeed = angularVelocity.Magnitude
	if horizontalSpeed <= RUN.LandingStopHorizontalSpeed and angularSpeed <= RUN.LandingStopAngularSpeed then
		local settledSince = session.LandingSettledSince
		if settledSince == nil then
			session.LandingSettledSince = now
		elseif now - settledSince >= RUN.LandingStopConfirmationDuration then
			finishLanding(session, runId)
			return
		end
	else
		session.LandingSettledSince = nil
	end
end

local function isExtremeLateralPosition(position: Vector3): boolean
	return math.abs(position.X) > RUN.SafetyBounds.MaximumLateralDistance
end

local function addSessionConnection(session: Session, connection: RBXScriptConnection)
	table.insert(session.Connections, connection)
end

local function enterAirborne(session: Session, runId: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Descent
		or not session.Sled.Root.Parent
	then
		return
	end

	enterRampFreedom(session, runId)
	local launchVelocity = session.Sled.Root.AssemblyLinearVelocity
	session.LaunchHorizontalSpeed = Vector3.new(launchVelocity.X, 0, launchVelocity.Z).Magnitude

	-- Every actuator is disabled before the phase changes. Airborne motion is then
	-- entirely the result of gravity, momentum, and physical contact.
	resetStallObservation(session)
	clearTuckState(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
	if transitionTo(session, RunPhase.Airborne) then
		session.HasEnteredAirborne = true
		print(string.format("[Frostline][Run] %s Airborne", runLabel(session)))
	end
end

local function enterLanded(session: Session, runId: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Airborne
		or not session.Sled.Root.Parent
	then
		return
	end

	clearTuckState(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
	if transitionTo(session, RunPhase.Landed) then
		local touchdownVelocity = session.Sled.Root.AssemblyLinearVelocity
		local touchdownHorizontalSpeed = Vector3.new(
			touchdownVelocity.X,
			0,
			touchdownVelocity.Z
		).Magnitude
		session.TouchdownHorizontalSpeed = touchdownHorizontalSpeed
		session.LandingSettledSince = nil
		updateMaximumDistance(session)
		print(
			string.format(
				"[Frostline][Run] %s Landed z=%.1f horizontalSpeed=%.1f",
				runLabel(session),
				session.Sled.Root.Position.Z,
				touchdownHorizontalSpeed
			)
		)
		updateLandingStopDetection(session, runId, os.clock())
	end
end

local function monitorSession(session: Session, runId: number)
	addSessionConnection(
		session,
		RunService.Heartbeat:Connect(function()
			if not isSameSession(session, runId) or session.CleanupStarted then
				resetStallObservation(session)
				return
			end
			if session.Player.Character ~= session.Character
				or not session.Character.Parent
				or not session.Humanoid.Parent
			then
				requestCleanup(session, runId, "character removed", true)
				return
			end

			local root = session.Sled.Root
			if not root.Parent then
				local removalReason = if session.ReleaseInProgress then "sled removed during release" else "sled removed"
				requestCleanup(session, runId, removalReason, true)
				return
			end
			local now = os.clock()
			updateRampFreedom(session, runId)
			if session.Phase == RunPhase.Descent and root.Position.Z >= session.LaunchZ then
				enterAirborne(session, runId)
			end
			updateAntiStall(session, runId)
			updateGroundStability(session)
			local missedLaunchSnapshot = updateDescentStopDetection(session, runId, now)
			if missedLaunchSnapshot then
				finishMissedLaunch(session, runId, missedLaunchSnapshot)
			end
			if session.Phase == RunPhase.Airborne
				or session.Phase == RunPhase.Landed
				or session.Phase == RunPhase.Results
			then
				updateMaximumDistance(session)
			end
			updateLandingStopDetection(session, runId, now)
			if session.CleanupStarted then
				return
			end

			local position = root.Position
			if position.Y < RUN.SafetyBounds.MinimumY then
				requestCleanup(session, runId, "fell below the world", true)
				return
			elseif isExtremeLateralPosition(position) then
				requestCleanup(session, runId, "exceeded lateral safety bounds", true)
				return
			end

			local descentStartedAt = session.DescentStartedAt
			if session.Phase ~= RunPhase.Landed
				and session.Phase ~= RunPhase.Results
				and descentStartedAt
				and now - descentStartedAt >= RUN.MaximumRunDuration
			then
				requestCleanup(session, runId, "run timed out", true)
				return
			end

			if now - session.LastHudUpdateAt >= HUD_UPDATE_INTERVAL then
				session.LastHudUpdateAt = now
				sendState(session)
			end
		end)
	)
end

local function connectRunEvents(session: Session, references: WorldReferences, runId: number)
	addSessionConnection(
		session,
		session.Sled.Root.Touched:Connect(function(otherPart: BasePart)
			if not isSameSession(session, runId) or session.CleanupStarted then
				return
			end

			if otherPart == references.LaunchEdge and session.Phase == RunPhase.Descent then
				enterAirborne(session, runId)
			elseif otherPart:IsDescendantOf(references.LandingSurfaces) then
				-- A high-speed sled can cross the thin LaunchEdge between physics events.
				-- Promote it first so touchdown is still recognized on the same contact.
				if session.Phase == RunPhase.Descent and session.Sled.Root.Position.Z >= session.LaunchZ then
					enterAirborne(session, runId)
				end
				if session.Phase == RunPhase.Airborne then
					enterLanded(session, runId)
				end
			end
		end)
	)

	addSessionConnection(
		session,
		session.Humanoid.Died:Connect(function()
			if isSameSession(session, runId) then
				requestCleanup(session, runId, "character died", true)
			end
		end)
	)

	addSessionConnection(
		session,
		session.Player.CharacterRemoving:Connect(function(character: Model)
			if isSameSession(session, runId) and character == session.Character then
				requestCleanup(session, runId, "character removed", true)
			end
		end)
	)

	addSessionConnection(
		session,
		session.Character.DescendantAdded:Connect(function(descendant: Instance)
			if isSameSession(session, runId)
				and not session.CleanupStarted
				and descendant:IsA("BasePart")
				and session.OriginalMassless[descendant] == nil
			then
				session.OriginalMassless[descendant] = descendant.Massless
				descendant.Massless = true
			end
		end)
	)

	addSessionConnection(
		session,
		session.Sled.DriverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if not isSameSession(session, runId)
				or session.CleanupStarted
				or session.Phase == RunPhase.Landed
				or session.Phase == RunPhase.Results
				or session.Phase == RunPhase.Reset
			then
				return
			end

			-- Once ramp freedom begins, a natural launch or crash may unseat the rider;
			-- the physical run still owns cleanup and returns them after the sled stops.
			local phaseAllowsSeatExit = session.Phase == RunPhase.Countdown
				or (session.Phase == RunPhase.Descent and not session.RampFreedomEntered)
			if phaseAllowsSeatExit and session.Sled.DriverSeat.Occupant ~= session.Humanoid then
				requestCleanup(session, runId, "player left sled", true)
			end
		end)
	)

	monitorSession(session, runId)
end

local function verifyReleaseAfterHeartbeat(
	session: Session,
	runId: number,
	releasePositionZ: number
): (boolean, string)
	local releaseValid, releaseReason = validateRelease(session, runId, RunPhase.Descent, false)
	logReleaseValidity(session, "post", releaseValid, releaseReason)
	if not releaseValid then
		return false, releaseReason
	end

	local root = session.Sled.Root
	local measuredVelocity = root.AssemblyLinearVelocity
	local measuredForwardSpeed = measuredVelocity.Z
	local progress = root.Position.Z - releasePositionZ
	local result = "passed"
	if measuredForwardSpeed < RUN.InitialPushSpeed then
		root.AssemblyLinearVelocity = Vector3.new(
			measuredVelocity.X,
			measuredVelocity.Y,
			math.max(measuredForwardSpeed, RUN.InitialPushSpeed)
		)
		result = "reapplied"
	end

	print(
		string.format(
			"[Frostline][Run] %s Release verification result=%s progress=%.2f forwardSpeed=%.2f",
			runLabel(session),
			result,
			progress,
			measuredForwardSpeed
		)
	)
	return true, "ok"
end

local function runCountdown(session: Session, runId: number)
	local countDuration = math.max(0.1, RUN.CountdownDuration / 3)

	for count = 3, 1, -1 do
		if not isSameSession(session, runId)
			or session.CleanupStarted
			or session.Phase ~= RunPhase.Countdown
		then
			return
		end

		session.CountdownValue = count
		sendState(session)
		task.wait(countDuration)
	end

	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Countdown
	then
		return
	end

	session.CountdownValue = nil
	local preReleaseValid, preReleaseReason = validateRelease(session, runId, RunPhase.Countdown, true)
	logReleaseValidity(session, "pre", preReleaseValid, preReleaseReason)
	if not preReleaseValid then
		requestCleanup(session, runId, "release validation failed before GO: " .. preReleaseReason, true)
		return
	end

	session.ReleaseInProgress = true
	if not transitionTo(session, RunPhase.Descent) then
		session.ReleaseInProgress = false
		requestCleanup(session, runId, "countdown transition failed", true)
		return
	end

	local root = session.Sled.Root
	root.Anchored = false
	local ownershipSucceeded, ownershipError = pcall(function()
		root:SetNetworkOwner(nil)
	end)
	if not ownershipSucceeded then
		session.ReleaseInProgress = false
		logReleaseValidity(session, "ownership", false, tostring(ownershipError))
		requestCleanup(session, runId, "release network ownership failed", true)
		return
	end

	-- Apply the existing baseline before the first unanchored physics synchronization.
	local currentVelocity = root.AssemblyLinearVelocity
	root.AssemblyAngularVelocity = Vector3.zero
	root.AssemblyLinearVelocity = Vector3.new(
		currentVelocity.X,
		currentVelocity.Y,
		math.max(currentVelocity.Z, RUN.InitialPushSpeed)
	)
	local releasePositionZ = root.Position.Z
	session.DescentStartedAt = os.clock()
	session.ReleasePositionZ = releasePositionZ
	print(
		string.format(
			"[Frostline][Run] %s Released initialSpeed=%.1f",
			runLabel(session),
			root.AssemblyLinearVelocity.Z
		)
	)

	RunService.Heartbeat:Wait()
	local releaseVerified, releaseVerificationReason = verifyReleaseAfterHeartbeat(
		session,
		runId,
		releasePositionZ
	)
	if not releaseVerified then
		session.ReleaseInProgress = false
		requestCleanup(
			session,
			runId,
			"release validation failed after sync: " .. releaseVerificationReason,
			true
		)
		return
	end

	session.ReleaseInProgress = false
	resetStallObservation(session)
	session.MaximumDescentProgress = math.max(0, root.Position.Z - releasePositionZ)
	session.TuckActivationReady = true
	local activateQueuedTuck = session.TuckQueued and session.TuckIntentHeld
	session.TuckQueued = false
	setTuckActive(session, activateQueuedTuck)
	updateAntiStall(session, runId)
	if session.TuckQueueScheduled then
		print(
			string.format(
				"[Frostline][Run] %s Queued Tuck acceptance accepted=%s held=%s",
				runLabel(session),
				tostring(session.Tucking),
				tostring(session.TuckIntentHeld)
			)
		)
		session.TuckQueueScheduled = false
	end
	sendState(session)
end

local function createSledActuators(root: Part): (Attachment, VectorForce, VectorForce, Torque)
	local attachment = Instance.new("Attachment")
	attachment.Name = "SledPhysicsAttachment"
	attachment.Parent = root

	local tuckForce = Instance.new("VectorForce")
	tuckForce.Name = "TuckVectorForce"
	tuckForce.Attachment0 = attachment
	tuckForce.RelativeTo = Enum.ActuatorRelativeTo.World
	tuckForce.ApplyAtCenterOfMass = true
	tuckForce.Force = Vector3.zero
	tuckForce.Enabled = false
	tuckForce.Parent = root

	local antiStallForce = Instance.new("VectorForce")
	antiStallForce.Name = "AntiStallVectorForce"
	antiStallForce.Attachment0 = attachment
	antiStallForce.RelativeTo = Enum.ActuatorRelativeTo.World
	antiStallForce.ApplyAtCenterOfMass = true
	antiStallForce.Force = Vector3.zero
	antiStallForce.Enabled = false
	antiStallForce.Parent = root

	local stabilityTorque = Instance.new("Torque")
	stabilityTorque.Name = "GroundedDescentStability"
	stabilityTorque.Attachment0 = attachment
	stabilityTorque.RelativeTo = Enum.ActuatorRelativeTo.World
	stabilityTorque.Torque = Vector3.zero
	stabilityTorque.Enabled = false
	stabilityTorque.Parent = root

	return attachment, tuckForce, antiStallForce, stabilityTorque
end

local function seatPlayer(session: Session, runId: number): boolean
	local seat = session.Sled.DriverSeat
	local character = session.Character

	character:PivotTo(seat.CFrame * CFrame.new(0, 2.7, 0))
	RunService.Heartbeat:Wait()
	if not isSameSession(session, runId) or session.CleanupStarted or session.Humanoid.Health <= 0 then
		return false
	end

	seat:Sit(session.Humanoid)
	RunService.Heartbeat:Wait()
	return isSameSession(session, runId)
		and not session.CleanupStarted
		and seat.Occupant == session.Humanoid
end

local function beginRun(player: Player, references: WorldReferences)
	if sessions[player] then
		return
	end
	if not references.PlayerSpawn.Parent or not references.PlayerSpawn:IsDescendantOf(Workspace) then
		warn(string.format("[Frostline] PlayerSpawn unavailable; refusing run for %s", player.Name))
		return
	end
	if not references.SummitPlatform.Parent or not references.SummitPlatform:IsDescendantOf(Workspace) then
		warn(string.format("[Frostline] SummitPlatform unavailable; refusing run for %s", player.Name))
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidInstance or humanoidInstance.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	if (rootPart.Position - references.StartTrigger.Position).Magnitude > MAX_START_DISTANCE then
		return
	end

	local triggerCenter = references.StartTrigger.Position
	local sled = SledFactory.create(CFrame.lookAt(triggerCenter, triggerCenter + Vector3.zAxis))
	local summitTopY = references.SummitPlatform.Position.Y + references.SummitPlatform.Size.Y * 0.5
	local startPosition = Vector3.new(
		triggerCenter.X,
		summitTopY + sled.Root.Size.Y * 0.5 + START_BOTTOM_CLEARANCE,
		triggerCenter.Z
	)
	local spawnCFrame = CFrame.lookAt(startPosition, startPosition + Vector3.zAxis)
	sled.Model:PivotTo(spawnCFrame)
	sled.Model.Parent = references.ActiveSleds

	latestRunId += 1
	local runId = latestRunId
	local tuckAttachment, tuckForce, antiStallForce, stabilityTorque = createSledActuators(sled.Root)
	local groundRaycastParams = RaycastParams.new()
	groundRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	groundRaycastParams.FilterDescendantsInstances = { sled.Model, character }
	groundRaycastParams.IgnoreWater = true
	groundRaycastParams.RespectCanCollide = true
	local session: Session = {
		RunId = runId,
		Player = player,
		Character = character,
		Humanoid = humanoidInstance,
		Sled = sled,
		TuckAttachment = tuckAttachment,
		TuckForce = tuckForce,
		AntiStallForce = antiStallForce,
		StabilityTorque = stabilityTorque,
		GroundRaycastParams = groundRaycastParams,
		Phase = RunPhase.Idle,
		CountdownValue = nil,
		OriginalMassless = {},
		Connections = {},
		PlayerSpawn = references.PlayerSpawn,
		LaunchZ = references.LaunchZ,
		StudsPerMeter = references.StudsPerMeter,
		DescentStartedAt = nil,
		LandingSettledSince = nil,
		LastTuckRequestAt = 0,
		LastHudUpdateAt = 0,
		TuckIntentHeld = false,
		TuckQueued = false,
		Tucking = false,
		TuckActivationReady = false,
		TuckQueueScheduled = false,
		AntiStallActive = false,
		RampFreedomEntered = false,
		CleanupStarted = false,
		FirstCleanupReason = nil,
		ReleaseInProgress = false,
		ReleasePositionZ = nil,
		StallObservationStartedAt = nil,
		StallObservationStartZ = nil,
		StallObservationKind = nil,
		StallRecoveryUsed = false,
		LastStallRejectionAt = -math.huge,
		HasEnteredAirborne = false,
		MissedLaunchConfirmed = false,
		Outcome = nil,
		MaximumDescentProgress = 0,
		StopConfirmed = false,
		TuckUsed = false,
		LaunchHorizontalSpeed = nil,
		TouchdownHorizontalSpeed = nil,
		MaximumDistance = 0,
		FinalStopDistance = nil,
		TelemetryLogged = false,
	}
	sessions[player] = session

	if not transitionTo(session, RunPhase.Countdown) then
		requestCleanup(session, runId, "could not start countdown", true)
		return
	end

	session.OriginalMassless = makeCharacterMassless(character)
	connectRunEvents(session, references, runId)

	if not seatPlayer(session, runId) then
		requestCleanup(session, runId, "could not seat player", true)
		return
	end

	task.spawn(runCountdown, session, runId)
end

local function findWorldReferences(): WorldReferences?
	local world = Workspace:FindFirstChild(WORLD.FolderName)
	if not world or not world:IsA("Model") then
		warn("[Frostline] RunManager could not find FrostlineWorld")
		return nil
	end

	local markers = world:FindFirstChild("Markers")
	local geometry = world:FindFirstChild("Geometry")
	if not markers or not markers:IsA("Folder") or not geometry or not geometry:IsA("Folder") then
		warn("[Frostline] RunManager could not find world folders")
		return nil
	end

	local startTrigger = markers:FindFirstChild("StartTrigger")
	local summitPlatform = geometry:FindFirstChild("SummitPlatform")
	local launchEdge = markers:FindFirstChild("LaunchEdge")
	local landingSurfaces = geometry:FindFirstChild("FrozenLake")
	local playerSpawn = geometry:FindFirstChild("PlayerSpawn", true)
	if not startTrigger
		or not startTrigger:IsA("BasePart")
		or not summitPlatform
		or not summitPlatform:IsA("BasePart")
		or not launchEdge
		or not launchEdge:IsA("BasePart")
		or not landingSurfaces
		or not landingSurfaces:IsA("Folder")
		or not playerSpawn
		or not playerSpawn:IsA("SpawnLocation")
	then
		warn("[Frostline] RunManager could not resolve required world objects")
		return nil
	end
	if not landingSurfaces:FindFirstChildWhichIsA("BasePart") then
		warn("[Frostline] RunManager found no FrozenLake surface parts")
		return nil
	end
	if WORLD.StudsPerMeter <= 0 then
		warn("[Frostline] RunManager found invalid StudsPerMeter")
		return nil
	end

	local activeSleds: Folder
	local existingSleds = world:FindFirstChild("ActiveSleds")
	if existingSleds and existingSleds:IsA("Folder") then
		activeSleds = existingSleds
	else
		if existingSleds then
			existingSleds:Destroy()
		end
		activeSleds = Instance.new("Folder")
		activeSleds.Name = "ActiveSleds"
		activeSleds.Parent = world
	end

	return {
		ActiveSleds = activeSleds,
		StartTrigger = startTrigger,
		SummitPlatform = summitPlatform,
		LaunchEdge = launchEdge,
		LandingSurfaces = landingSurfaces,
		PlayerSpawn = playerSpawn,
		LaunchZ = launchEdge.Position.Z,
		StudsPerMeter = WORLD.StudsPerMeter,
	}
end

local function getOrCreateRemoteFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function getOrCreateRemote(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function configurePrompt(startTrigger: BasePart): ProximityPrompt
	local existing = startTrigger:FindFirstChild(PROMPT_NAME)
	local prompt: ProximityPrompt
	if existing and existing:IsA("ProximityPrompt") then
		prompt = existing
	else
		if existing then
			existing:Destroy()
		end
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = PROMPT_NAME
		prompt.Parent = startTrigger
	end

	prompt.ActionText = "Start Run"
	prompt.ObjectText = "Frostline Sled"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = RUN.StartPromptHoldDuration
	prompt.MaxActivationDistance = 14
	return prompt
end

local function noteQueuedTuckScheduling(session: Session, sourcePhase: Phase)
	if session.TuckQueueScheduled then
		return
	end
	session.TuckQueueScheduled = true
	print(
		string.format(
			"[Frostline][Run] %s Queued Tuck scheduling phase=%s",
			runLabel(session),
			sourcePhase
		)
	)
end

local function onTuckIntent(player: Player, requestedRunId: any, intent: any)
	if typeof(requestedRunId) ~= "number"
		or requestedRunId % 1 ~= 0
		or typeof(intent) ~= "boolean"
	then
		return
	end

	local session = sessions[player]
	if not session then
		return
	end
	local runId = session.RunId
	if requestedRunId ~= runId
		or not isSameSession(session, runId)
		or session.CleanupStarted
	then
		return
	end

	local now = os.clock()
	if now - session.LastTuckRequestAt < MIN_TUCK_REQUEST_INTERVAL then
		-- A valid release is always fail-safe, even when activation requests are throttled.
		if intent == false then
			session.TuckIntentHeld = false
			session.TuckQueued = false
			setTuckActive(session, false)
			sendState(session)
		end
		return
	end
	session.LastTuckRequestAt = now

	if session.Phase == RunPhase.Countdown then
		session.TuckIntentHeld = intent
		session.TuckQueued = intent
		setTuckActive(session, false)
		if intent then
			noteQueuedTuckScheduling(session, RunPhase.Countdown)
		end
	elseif session.Phase == RunPhase.Descent then
		session.TuckIntentHeld = intent
		if session.TuckActivationReady then
			session.TuckQueued = false
			setTuckActive(session, intent)
		else
			session.TuckQueued = intent
			setTuckActive(session, false)
			if intent then
				noteQueuedTuckScheduling(session, RunPhase.Descent)
			end
		end
	else
		clearTuckState(session)
	end
	sendState(session)
end

function RunManager.start()
	if started then
		return
	end
	started = true

	local references = findWorldReferences()
	if not references then
		started = false
		return
	end

	local remoteFolder = getOrCreateRemoteFolder()
	local tuckRemote = getOrCreateRemote(remoteFolder, TUCK_REMOTE_NAME)
	stateRemote = getOrCreateRemote(remoteFolder, STATE_REMOTE_NAME)

	tuckRemote.OnServerEvent:Connect(onTuckIntent)

	local prompt = configurePrompt(references.StartTrigger)
	prompt.Triggered:Connect(function(player: Player)
		local ok, message = pcall(beginRun, player, references)
		if not ok then
			local session = sessions[player]
			if session then
				local runId = session.RunId
				if isSameSession(session, runId) then
					warn(
						string.format(
							"[Frostline][Run] %s Run setup error=%s",
							runLabel(session),
							tostring(message)
						)
					)
					requestCleanup(session, runId, "run setup error", true)
				end
			else
				warn(string.format("[Frostline] Failed to create run for %s: %s", player.Name, tostring(message)))
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local session = sessions[player]
		if session then
			local runId = session.RunId
			if isSameSession(session, runId) then
				requestCleanup(session, runId, "player removed", false)
			end
		end
	end)

	print("[Frostline] RunManager ready")
end

return RunManager
