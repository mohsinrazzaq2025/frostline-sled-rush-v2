--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)
local CourseRegistry = require(script.Parent.CourseRegistry)
local FrostTrailConfig = require(script.Parent.FrostTrailConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ResultService = require(script.Parent.ResultService)
local SledFactory = require(script.Parent.SledFactory)

local RUN = GameConfig.Run
local RESULT = GameConfig.Result

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local TUCK_REMOTE_NAME = "TuckIntent"
local STEERING_REMOTE_NAME = "SteeringIntent"
local STATE_REMOTE_NAME = "RunState"
local RESULT_REMOTE_NAME = "RunResult"
local RESULT_ACTION_REMOTE_NAME = "ResultAction"
local PROMPT_NAME = "StartRunPrompt"
local STUDIO_COURSE_CONTROL_BRIDGE_NAME = "FrostlineStudioCourseControl"
local PRESENTATION_COURSE_ATTRIBUTE = "FrostlinePresentationCourseId"
local CLASSIC_COURSE_ID: CourseRegistry.CourseId = "FrozenLakeV2"
local FROST_TRAIL_COURSE_ID: CourseRegistry.CourseId = "FrostTrailV1"
local FROST_LAKE_MARKED_PART_NAME = "FrostTrailLakeMarked_0000m_1500m"
local FROST_LAKE_RUNOFF_PART_NAME = "FrostTrailLakeRunoff_1500m_1800m"
local FROST_ROUTE_EXPECTED_AUTHORED_LENGTH = 6696.671726289
local FROST_ROUTE_LENGTH_TOLERANCE = 0.01
local FROST_ROUTE_EXPECTED_SAMPLE_COUNT = 57
local FROST_ROUTE_EXPECTED_GEOMETRY_POINT_COUNT = 75
local FROST_ROUTE_EXPECTED_SPLIT_COUNT = 20
local FROST_ROUTE_EXPECTED_MAXIMUM_ABSOLUTE_SLOPE = 0.24647727272727274
local FROST_ROUTE_SLOPE_TOLERANCE = 1e-12
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
local RAMP_EXIT_ROLL_WRITE_EPSILON = 1e-4
local RAMP_EXIT_INVARIANT_EPSILON = 1e-5
local COURSE_BASIS_EPSILON = 1e-5
local LANDING_CONTACT_LOG_PREFIX = "[Frostline][LandingContact]"
local LANDING_CONTACT_SOURCE = "SledRoot.Touched"
local LANDING_CONTACT_CONDITION =
	"activeExact&&!CleanupStarted&&isCourseLandingSurface(session.ResolvedCourse,otherPart)&&phase==Airborne&&SledRoot.Parent~=nil&&transitionTo(Landed)==true"

type Phase = RunPhase.Name
type Sled = SledFactory.Sled
type CourseId = CourseRegistry.CourseId
type CourseDefinition = CourseRegistry.CourseDefinition
type RouteData = CourseRegistry.RouteData
type SteeringTuning = FrostTrailConfig.SteeringTuning
type StallObservationKind = "recovery" | "missed-launch"
type RunOutcome = "missed-launch"
type ResultAction = ResultTypes.Action
type ResultOutcome = ResultTypes.Outcome
type ResultPayload = ResultTypes.Payload

type LandingContactMotionSnapshot = {
	CapturedAt: number,
	RunId: number,
	Phase: Phase,
	Position: Vector3,
	CFrame: CFrame,
	LinearVelocity: Vector3,
	HorizontalSpeed: number,
	VerticalSpeed: number,
	AngularVelocity: Vector3,
	BodyRightRate: number,
	BodyUpRate: number,
	LongitudinalRollRate: number,
	UprightDot: number,
	LookUpDot: number,
	RightUpDot: number,
	AssemblyCenterOfMass: Vector3?,
	OwnerLabel: string,
	AutomaticOwnershipLabel: string,
	OwnerIsServer: boolean?,
	SeatOccupantLabel: string,
	SeatOccupantPresent: boolean,
	SeatOccupantValid: boolean,
	ExpectedPlayerSeated: boolean,
	TuckActive: boolean,
	AntiStallActive: boolean,
	StabilizationActive: boolean,
	SledValid: boolean,
	ActiveSessionExact: boolean,
	CleanupStarted: boolean,
}

type LandingContactTriggerSnapshot = {
	CapturedAt: number,
	RunId: number,
	Phase: Phase,
	DetectorSource: string,
	AcceptedCondition: string,
	HitName: string,
	HitPath: string,
	HitClass: string,
	HitMaterial: string,
	HitPosition: Vector3,
	HitSize: Vector3,
	HitTopSurfaceY: number,
	HitCanCollide: boolean,
	HitCanTouch: boolean,
	HitCanQuery: boolean,
	HitCollisionGroup: string,
	RootPosition: Vector3,
	RootBottomY: number,
	OwnerLabel: string,
	AutomaticOwnershipLabel: string,
	OwnerIsServer: boolean?,
	SeatOccupantLabel: string,
	SeatOccupantPresent: boolean,
	SeatOccupantValid: boolean,
	ExpectedPlayerSeated: boolean,
	SledValid: boolean,
	ActiveSessionExact: boolean,
}

type ResolvedCourse = {
	Definition: CourseDefinition,
	CourseId: CourseId,
	World: Model,
	Geometry: Folder,
	Markers: Folder,
	ActiveSleds: Folder,
	StartTrigger: BasePart,
	SummitPlatform: BasePart,
	LaunchEdge: BasePart,
	LandingSurfaces: Folder,
	ExactLandingSurfaces: { [BasePart]: boolean }?,
	PlayerSpawn: SpawnLocation,
	CoordinateOrigin: Vector3,
	ForwardDirection: Vector3,
	RightDirection: Vector3,
	LaunchLongitudinal: number,
	TrackWidth: number,
	StudsPerMeter: number,
	RampFreedomLongitudinal: number,
	LandingFieldDistanceMeters: number,
	MaximumRunDurationSeconds: number,
	SafetyMaximumLateralDistance: number,
	SafetyMinimumWorldY: number,
}

type ResolvedCourseDictionary = { [CourseId]: ResolvedCourse }

type RouteSample = {
	CenterX: number,
	CenterY: number,
	TrackWidth: number,
}

type PreparedCourseState = {
	CourseId: CourseId,
	Generation: number,
	Routing: boolean,
	SawInitialCharacter: boolean,
	CharacterConnection: RBXScriptConnection?,
}

type Session = {
	RunId: number,
	CourseId: CourseId,
	ResolvedCourse: ResolvedCourse,
	Player: Player,
	Character: Model,
	Humanoid: Humanoid,
	Sled: Sled,
	TuckAttachment: Attachment,
	TuckForce: VectorForce,
	AntiStallForce: VectorForce,
	StabilityTorque: Torque,
	SteeringForce: VectorForce?,
	SteeringProfile: SteeringTuning?,
	SteeringTarget: number,
	SteeringApplied: number,
	LastSteeringSeenSequence: number,
	LastSteeringAcceptedAt: number?,
	SteeringRateTokens: number,
	SteeringRateRefillAt: number,
	GroundRaycastParams: RaycastParams,
	Phase: Phase,
	CountdownValue: number?,
	OriginalMassless: { [BasePart]: boolean },
	Connections: { RBXScriptConnection },
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
	ReleaseLongitudinal: number?,
	StallObservationStartedAt: number?,
	StallObservationStartLongitudinal: number?,
	StallObservationKind: StallObservationKind?,
	StallRecoveryUsed: boolean,
	LastStallRejectionAt: number,
	EnteredAirborne: boolean,
	rampExitRollGuardConsumed: boolean,
	rampExitRollGuardApplied: boolean,
	rampExitRollGuardSkipReason: string?,
	LastAirborneContactSnapshot: LandingContactMotionSnapshot?,
	LandingContactDiagnosticsConsumed: boolean?,
	TouchedFrozenLake: boolean,
	SeatSeparatedAfterAirborne: boolean,
	MissedLaunchConfirmed: boolean,
	Outcome: RunOutcome?,
	ResultOutcome: ResultOutcome?,
	MaximumDescentProgress: number,
	StopConfirmed: boolean,
	TuckUsed: boolean,
	LaunchHorizontalSpeed: number?,
	TouchdownHorizontalSpeed: number?,
	MaximumDistanceMeters: number,
	FinalStopDistanceMeters: number?,
	FinalUprightDot: number?,
	ResultFinalized: boolean,
	ResultPayload: ResultPayload?,
	ResultActionAccepted: boolean,
	ReplayRequested: boolean,
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

type PendingReplay = {
	Session: Session,
	RunId: number,
	CourseId: CourseId,
}

export type StoreOperationToken = {
	_OpaqueStoreOperationToken: boolean,
}

type NetworkOwnershipSnapshot = {
	OwnerLabel: string,
	AutomaticLabel: string,
	OwnerIsServer: boolean?,
	OwnerReadFailure: string?,
}

type RampExitGuardResult = {
	Applied: boolean,
	SkipReason: string?,
	InvariantFailure: string?,
	RollRateBefore: number?,
	RollRateAfter: number?,
	CorrectionMagnitude: number?,
	PitchRateBefore: number?,
	PitchRateAfter: number?,
	PitchCorrection: number?,
	PitchGuardApplied: boolean,
	LinearVelocityBefore: Vector3?,
	LinearVelocityAfter: Vector3?,
	BodyRightRateBefore: number?,
	BodyRightRateAfter: number?,
	BodyUpRateBefore: number?,
	BodyUpRateAfter: number?,
	OwnerBefore: string?,
	OwnerAfter: string?,
	AutomaticBefore: string?,
	AutomaticAfter: string?,
}

local RunManager = {}

local sessions: { [Player]: Session } = {}
local started = false
local stateRemote: RemoteEvent? = nil
local resultRemote: RemoteEvent? = nil
local startPrompts: { [CourseId]: ProximityPrompt } = {}
local trustedReplay: ((Player, CourseId) -> ())? = nil
local resolvedCourses: ResolvedCourseDictionary? = nil
local pendingReplays: { [Player]: PendingReplay } = {}
local storeOperations: { [Player]: StoreOperationToken } = {}
local preparedCourses: { [Player]: PreparedCourseState } = {}
local studioCourseControlBridge: BindableFunction? = nil
local studioCourseControlWarningIssued = false
local latestRunId = 0

local function exactCourseId(value: string): CourseId?
	if value == CLASSIC_COURSE_ID then
		return CLASSIC_COURSE_ID
	elseif value == FROST_TRAIL_COURSE_ID then
		return FROST_TRAIL_COURSE_ID
	end

	return nil
end

local function setPreparedCourse(player: Player, courseId: CourseId): boolean
	local state = preparedCourses[player]
	if state == nil or player.Parent ~= Players then
		return false
	end

	state.CourseId = courseId
	state.Generation += 1
	player:SetAttribute(PRESENTATION_COURSE_ATTRIBUTE, courseId)
	return true
end

local function refreshStartPrompts()
	local enabled = next(sessions) == nil
	for _, prompt in startPrompts do
		if prompt.Parent then
			prompt.Enabled = enabled
		end
	end
end

local function disableStartPrompts()
	for _, prompt in startPrompts do
		if prompt.Parent then
			prompt.Enabled = false
		end
	end
end

local function hasPreparedCourseRouting(): boolean
	for _, state in preparedCourses do
		if state.Routing then
			return true
		end
	end

	return false
end

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

local function lifecycleLog(session: Session, event: string, detail: string)
	if not RESULT.LifecycleDiagnosticsEnabled then
		return
	end

	print(
		string.format(
			"[Frostline][Lifecycle] player=%s RunId=%d session=%s phase=%s event=%s sled=%s activeExact=%s %s",
			session.Player.Name,
			session.RunId,
			tostring(session),
			session.Phase,
			event,
			session.Sled.Model:GetFullName(),
			tostring(sessions[session.Player] == session),
			detail
		)
	)
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFinitePositiveNumber(value: number): boolean
	return isFiniteNumber(value) and value > 0
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function isNonEmptyString(value: string): boolean
	return string.len(value) > 0
end

local function forwardCoordinate(course: ResolvedCourse, position: Vector3): number
	return (position - course.CoordinateOrigin):Dot(course.ForwardDirection)
end

local function forwardProgress(course: ResolvedCourse, fromPosition: Vector3, toPosition: Vector3): number
	return (toPosition - fromPosition):Dot(course.ForwardDirection)
end

local function interpolateRouteSample(course: ResolvedCourse, longitudinal: number): RouteSample?
	local routeData = course.Definition.RouteData
	if course.Definition.RouteMode ~= "MonotonicZCenterline" or routeData == nil then
		return nil
	end

	local points = routeData.GeometryPoints
	local firstPoint = points[1]
	local lastPoint = points[#points]
	if firstPoint == nil or lastPoint == nil then
		return nil
	end

	local function fromPoint(point: FrostTrailConfig.RouteGeometryPoint): RouteSample
		return {
			CenterX = point.LocalPosition.X,
			CenterY = point.LocalPosition.Y,
			TrackWidth = point.TrackWidth,
		}
	end

	if longitudinal <= firstPoint.LocalPosition.Z then
		return fromPoint(firstPoint)
	elseif longitudinal >= lastPoint.LocalPosition.Z then
		return fromPoint(lastPoint)
	end

	local lowerIndex = 1
	local upperIndex = #points
	while upperIndex - lowerIndex > 1 do
		local middleIndex = math.floor((lowerIndex + upperIndex) * 0.5)
		if points[middleIndex].LocalPosition.Z <= longitudinal then
			lowerIndex = middleIndex
		else
			upperIndex = middleIndex
		end
	end

	local lowerPoint = points[lowerIndex]
	local upperPoint = points[upperIndex]
	local alpha = (longitudinal - lowerPoint.LocalPosition.Z)
		/ (upperPoint.LocalPosition.Z - lowerPoint.LocalPosition.Z)
	local center = lowerPoint.LocalPosition:Lerp(upperPoint.LocalPosition, alpha)
	return {
		CenterX = center.X,
		CenterY = center.Y,
		TrackWidth = lowerPoint.TrackWidth + (upperPoint.TrackWidth - lowerPoint.TrackWidth) * alpha,
	}
end

local function lateralOffset(course: ResolvedCourse, position: Vector3): number
	if course.Definition.RouteMode == "MonotonicZCenterline" then
		local routeSample = interpolateRouteSample(course, forwardCoordinate(course, position))
		if routeSample == nil then
			return math.huge
		end
		local localX = (position - course.CoordinateOrigin):Dot(course.RightDirection)
		return localX - routeSample.CenterX
	end

	return (position - course.CoordinateOrigin):Dot(course.RightDirection)
end

local function activeTrackWidth(course: ResolvedCourse, position: Vector3): number
	if course.Definition.RouteMode == "MonotonicZCenterline" then
		local routeSample = interpolateRouteSample(course, forwardCoordinate(course, position))
		return if routeSample then routeSample.TrackWidth else 0
	end

	return course.TrackWidth
end

local function isCourseLandingSurface(course: ResolvedCourse, part: BasePart): boolean
	if course.CourseId == FROST_TRAIL_COURSE_ID then
		local exactLandingSurfaces = course.ExactLandingSurfaces
		return exactLandingSurfaces ~= nil
			and exactLandingSurfaces[part] == true
			and part.Parent == course.LandingSurfaces
	end

	return part:IsDescendantOf(course.LandingSurfaces)
end

local function forwardSpeed(course: ResolvedCourse, velocity: Vector3): number
	return velocity:Dot(course.ForwardDirection)
end

local function crossedForwardPlane(course: ResolvedCourse, position: Vector3, longitudinal: number): boolean
	return forwardCoordinate(course, position) >= longitudinal
end

local function withMinimumForwardSpeed(
	course: ResolvedCourse,
	velocity: Vector3,
	minimumSpeed: number
): Vector3
	local currentForwardSpeed = forwardSpeed(course, velocity)
	if currentForwardSpeed >= minimumSpeed then
		return velocity
	end

	return velocity + course.ForwardDirection * (minimumSpeed - currentForwardSpeed)
end

local function distanceFromLaunch(course: ResolvedCourse, position: Vector3): number
	local distanceMeters = math.max(
		0,
		(forwardCoordinate(course, position) - course.LaunchLongitudinal) / course.StudsPerMeter
	)
	if course.Definition.RouteMode == "MonotonicZCenterline" then
		return math.min(distanceMeters, course.LandingFieldDistanceMeters)
	end

	return distanceMeters
end

local function isFiniteCFrame(value: CFrame): boolean
	local components = { value:GetComponents() }
	for _, component in components do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function captureNetworkOwnership(root: BasePart): NetworkOwnershipSnapshot
	local owner: Player? = nil
	local ownerReadSucceeded, ownerReadError = pcall(function()
		owner = root:GetNetworkOwner()
	end)
	local automatic: boolean? = nil
	local automaticReadSucceeded = pcall(function()
		automatic = root:GetNetworkOwnershipAuto()
	end)

	return {
		OwnerLabel = if not ownerReadSucceeded
			then "Unavailable"
			elseif owner == nil
			then "Server"
			else (owner :: Player).Name,
		AutomaticLabel = if not automaticReadSucceeded
			then "unavailable"
			elseif automatic == true
			then "automatic"
			else "manual",
		OwnerIsServer = if ownerReadSucceeded then owner == nil else nil,
		OwnerReadFailure = if ownerReadSucceeded then nil else tostring(ownerReadError),
	}
end

local function formatDiagnosticNumber(value: number?): string
	if value == nil then
		return "unavailable"
	end
	return if isFiniteNumber(value) then string.format("%.5f", value) else tostring(value)
end

local function formatDiagnosticBoolean(value: boolean?): string
	return if value == nil then "unavailable" else tostring(value)
end

local function formatDiagnosticVector(value: Vector3?): string
	if value == nil then
		return "unavailable"
	end
	return string.format(
		"(%s,%s,%s)",
		formatDiagnosticNumber(value.X),
		formatDiagnosticNumber(value.Y),
		formatDiagnosticNumber(value.Z)
	)
end

local function getDiagnosticFullName(instance: Instance): string
	local fullName = instance.Name
	pcall(function()
		fullName = instance:GetFullName()
	end)
	return fullName
end

local function getWorldVerticalHalfExtent(cframe: CFrame, size: Vector3): number
	local halfSize = size * 0.5
	return math.abs(cframe.RightVector.Y) * halfSize.X
		+ math.abs(cframe.UpVector.Y) * halfSize.Y
		+ math.abs(cframe.LookVector.Y) * halfSize.Z
end

local function captureSeatOccupantState(session: Session): (string, boolean, boolean, boolean)
	local occupant = session.Sled.DriverSeat.Occupant
	if occupant == nil then
		return "none", false, false, false
	end

	local occupantValid = occupant.Parent ~= nil and occupant:IsDescendantOf(Workspace)
	local expectedPlayerSeated = occupantValid
		and occupant == session.Humanoid
		and session.Player.Character == session.Character
		and session.Character.Parent ~= nil
		and session.Humanoid.Parent == session.Character
	return getDiagnosticFullName(occupant), true, occupantValid, expectedPlayerSeated
end

local function captureLandingContactMotionSnapshot(
	session: Session,
	runId: number,
	timestamp: number
): LandingContactMotionSnapshot
	local root = session.Sled.Root
	local model = session.Sled.Model
	local capturedCFrame = root.CFrame
	local linearVelocity = root.AssemblyLinearVelocity
	local angularVelocity = root.AssemblyAngularVelocity
	local ownership = captureNetworkOwnership(root)
	local occupantLabel, occupantPresent, occupantValid, expectedPlayerSeated = captureSeatOccupantState(session)
	local assemblyCenterOfMass: Vector3? = nil
	pcall(function()
		assemblyCenterOfMass = root.AssemblyCenterOfMass
	end)

	return {
		CapturedAt = timestamp,
		RunId = runId,
		Phase = session.Phase,
		Position = capturedCFrame.Position,
		CFrame = capturedCFrame,
		LinearVelocity = linearVelocity,
		HorizontalSpeed = Vector3.new(linearVelocity.X, 0, linearVelocity.Z).Magnitude,
		VerticalSpeed = linearVelocity.Y,
		AngularVelocity = angularVelocity,
		BodyRightRate = angularVelocity:Dot(capturedCFrame.RightVector),
		BodyUpRate = angularVelocity:Dot(capturedCFrame.UpVector),
		LongitudinalRollRate = angularVelocity:Dot(capturedCFrame.LookVector),
		UprightDot = capturedCFrame.UpVector:Dot(Vector3.yAxis),
		LookUpDot = capturedCFrame.LookVector:Dot(Vector3.yAxis),
		RightUpDot = capturedCFrame.RightVector:Dot(Vector3.yAxis),
		AssemblyCenterOfMass = assemblyCenterOfMass,
		OwnerLabel = ownership.OwnerLabel,
		AutomaticOwnershipLabel = ownership.AutomaticLabel,
		OwnerIsServer = ownership.OwnerIsServer,
		SeatOccupantLabel = occupantLabel,
		SeatOccupantPresent = occupantPresent,
		SeatOccupantValid = occupantValid,
		ExpectedPlayerSeated = expectedPlayerSeated,
		TuckActive = session.Tucking,
		AntiStallActive = session.AntiStallActive,
		StabilizationActive = session.StabilityTorque.Parent ~= nil and session.StabilityTorque.Enabled,
		SledValid = root.Parent == model
			and model:IsDescendantOf(Workspace)
			and session.Sled.DriverSeat.Parent == model,
		ActiveSessionExact = isSameSession(session, runId),
		CleanupStarted = session.CleanupStarted,
	}
end

local function safelyCaptureLandingContactMotionSnapshot(
	session: Session,
	runId: number,
	timestamp: number
): (LandingContactMotionSnapshot?, string?)
	local snapshot: LandingContactMotionSnapshot? = nil
	local succeeded, captureError = pcall(function()
		snapshot = captureLandingContactMotionSnapshot(session, runId, timestamp)
	end)
	if not succeeded then
		return nil, tostring(captureError)
	end
	return snapshot, nil
end

local function captureLandingContactTriggerSnapshot(
	session: Session,
	runId: number,
	hitPart: BasePart,
	timestamp: number,
	detectorSource: string,
	acceptedCondition: string
): LandingContactTriggerSnapshot
	local root = session.Sled.Root
	local rootCFrame = root.CFrame
	local rootSize = root.Size
	local hitCFrame = hitPart.CFrame
	local hitSize = hitPart.Size
	local ownership = captureNetworkOwnership(root)
	local occupantLabel, occupantPresent, occupantValid, expectedPlayerSeated = captureSeatOccupantState(session)

	return {
		CapturedAt = timestamp,
		RunId = runId,
		Phase = session.Phase,
		DetectorSource = detectorSource,
		AcceptedCondition = acceptedCondition,
		HitName = hitPart.Name,
		HitPath = getDiagnosticFullName(hitPart),
		HitClass = hitPart.ClassName,
		HitMaterial = hitPart.Material.Name,
		HitPosition = hitCFrame.Position,
		HitSize = hitSize,
		HitTopSurfaceY = hitCFrame.Position.Y + getWorldVerticalHalfExtent(hitCFrame, hitSize),
		HitCanCollide = hitPart.CanCollide,
		HitCanTouch = hitPart.CanTouch,
		HitCanQuery = hitPart.CanQuery,
		HitCollisionGroup = hitPart.CollisionGroup,
		RootPosition = rootCFrame.Position,
		RootBottomY = rootCFrame.Position.Y - getWorldVerticalHalfExtent(rootCFrame, rootSize),
		OwnerLabel = ownership.OwnerLabel,
		AutomaticOwnershipLabel = ownership.AutomaticLabel,
		OwnerIsServer = ownership.OwnerIsServer,
		SeatOccupantLabel = occupantLabel,
		SeatOccupantPresent = occupantPresent,
		SeatOccupantValid = occupantValid,
		ExpectedPlayerSeated = expectedPlayerSeated,
		SledValid = root.Parent == session.Sled.Model
			and session.Sled.Model:IsDescendantOf(Workspace)
			and session.Sled.DriverSeat.Parent == session.Sled.Model,
		ActiveSessionExact = isSameSession(session, runId),
	}
end

local function safelyCaptureLandingContactTriggerSnapshot(
	session: Session,
	runId: number,
	hitPart: BasePart,
	timestamp: number,
	detectorSource: string,
	acceptedCondition: string
): (LandingContactTriggerSnapshot?, string?)
	local snapshot: LandingContactTriggerSnapshot? = nil
	local succeeded, captureError = pcall(function()
		snapshot = captureLandingContactTriggerSnapshot(
			session,
			runId,
			hitPart,
			timestamp,
			detectorSource,
			acceptedCondition
		)
	end)
	if not succeeded then
		return nil, tostring(captureError)
	end
	return snapshot, nil
end

local function formatLandingContactMotionRecord(
	session: Session,
	runId: number,
	stage: string,
	snapshot: LandingContactMotionSnapshot,
	snapshotAge: number
): string
	local fields: { string } = {
		LANDING_CONTACT_LOG_PREFIX,
		"player=" .. session.Player.Name,
		string.format("RunId=%d", runId),
		string.format("capturedRunId=%d", snapshot.RunId),
		"phase=" .. snapshot.Phase,
		"stage=" .. stage,
		"activeExact=" .. tostring(isSameSession(session, runId)),
		"capturedActiveExact=" .. tostring(snapshot.ActiveSessionExact),
		"owner=" .. snapshot.OwnerLabel,
		"ownership=" .. snapshot.AutomaticOwnershipLabel,
		"serverOwned=" .. formatDiagnosticBoolean(snapshot.OwnerIsServer),
		"timestamp=" .. formatDiagnosticNumber(snapshot.CapturedAt),
		"snapshotAge=" .. formatDiagnosticNumber(snapshotAge),
		"position=" .. formatDiagnosticVector(snapshot.Position),
		"orientationRight=" .. formatDiagnosticVector(snapshot.CFrame.RightVector),
		"orientationUp=" .. formatDiagnosticVector(snapshot.CFrame.UpVector),
		"orientationLook=" .. formatDiagnosticVector(snapshot.CFrame.LookVector),
		"linear=" .. formatDiagnosticVector(snapshot.LinearVelocity),
		"horizontalSpeed=" .. formatDiagnosticNumber(snapshot.HorizontalSpeed),
		"verticalSpeed=" .. formatDiagnosticNumber(snapshot.VerticalSpeed),
		"angularWorld=" .. formatDiagnosticVector(snapshot.AngularVelocity),
		"bodyRightRate=" .. formatDiagnosticNumber(snapshot.BodyRightRate),
		"bodyUpRate=" .. formatDiagnosticNumber(snapshot.BodyUpRate),
		"longitudinalRollRate=" .. formatDiagnosticNumber(snapshot.LongitudinalRollRate),
		"uprightDot=" .. formatDiagnosticNumber(snapshot.UprightDot),
		"lookUpDot=" .. formatDiagnosticNumber(snapshot.LookUpDot),
		"rightUpDot=" .. formatDiagnosticNumber(snapshot.RightUpDot),
		"assemblyCenterOfMass=" .. formatDiagnosticVector(snapshot.AssemblyCenterOfMass),
		"seatOccupant=" .. snapshot.SeatOccupantLabel,
		"seatOccupantPresent=" .. tostring(snapshot.SeatOccupantPresent),
		"seatOccupantValid=" .. tostring(snapshot.SeatOccupantValid),
		"expectedPlayerSeated=" .. tostring(snapshot.ExpectedPlayerSeated),
		"tuck=" .. tostring(snapshot.TuckActive),
		"antiStall=" .. tostring(snapshot.AntiStallActive),
		"stabilization=" .. tostring(snapshot.StabilizationActive),
		"sledValid=" .. tostring(snapshot.SledValid),
		"cleanupStarted=" .. tostring(snapshot.CleanupStarted),
	}
	return table.concat(fields, " ")
end

local function formatMissingLastAirborneRecord(
	session: Session,
	runId: number,
	triggerSnapshot: LandingContactTriggerSnapshot?
): string
	local ownerLabel = if triggerSnapshot then triggerSnapshot.OwnerLabel else "unavailable"
	local ownershipLabel = if triggerSnapshot then triggerSnapshot.AutomaticOwnershipLabel else "unavailable"
	local serverOwned = if triggerSnapshot then formatDiagnosticBoolean(triggerSnapshot.OwnerIsServer) else "unavailable"
	local phase = if triggerSnapshot then triggerSnapshot.Phase else session.Phase
	return table.concat({
		LANDING_CONTACT_LOG_PREFIX,
		"player=" .. session.Player.Name,
		string.format("RunId=%d", runId),
		"phase=" .. phase,
		"stage=last-airborne-pre-contact",
		"activeExact=" .. tostring(isSameSession(session, runId)),
		"capturedActiveExact=unavailable",
		"owner=" .. ownerLabel,
		"ownership=" .. ownershipLabel,
		"serverOwned=" .. serverOwned,
		"ownerSample=touchdown-trigger-fallback",
		"timestamp=unavailable",
		"snapshotAge=unavailable",
		"position=unavailable",
		"orientationRight=unavailable",
		"orientationUp=unavailable",
		"orientationLook=unavailable",
		"linear=unavailable",
		"horizontalSpeed=unavailable",
		"verticalSpeed=unavailable",
		"angularWorld=unavailable",
		"bodyRightRate=unavailable",
		"bodyUpRate=unavailable",
		"longitudinalRollRate=unavailable",
		"uprightDot=unavailable",
		"lookUpDot=unavailable",
		"rightUpDot=unavailable",
		"assemblyCenterOfMass=unavailable",
		"seatOccupant=unavailable",
		"seatOccupantPresent=unavailable",
		"seatOccupantValid=unavailable",
		"expectedPlayerSeated=unavailable",
		"tuck=unavailable",
		"antiStall=unavailable",
		"stabilization=unavailable",
		"sledValid=unavailable",
		"cleanupStarted=" .. tostring(session.CleanupStarted),
		"reason=no-authoritative-Airborne-update-before-touchdown",
	}, " ")
end

local function formatLandingContactTriggerRecord(
	session: Session,
	runId: number,
	snapshot: LandingContactTriggerSnapshot
): string
	local fields: { string } = {
		LANDING_CONTACT_LOG_PREFIX,
		"player=" .. session.Player.Name,
		string.format("RunId=%d", runId),
		string.format("capturedRunId=%d", snapshot.RunId),
		"phase=" .. snapshot.Phase,
		"stage=touchdown-trigger",
		"activeExact=" .. tostring(isSameSession(session, runId)),
		"capturedActiveExact=" .. tostring(snapshot.ActiveSessionExact),
		"owner=" .. snapshot.OwnerLabel,
		"ownership=" .. snapshot.AutomaticOwnershipLabel,
		"serverOwned=" .. formatDiagnosticBoolean(snapshot.OwnerIsServer),
		"timestamp=" .. formatDiagnosticNumber(snapshot.CapturedAt),
		"source=" .. snapshot.DetectorSource,
		"condition=" .. snapshot.AcceptedCondition,
		"hitUnique=true",
		"hitName=" .. snapshot.HitName,
		"hitPath=" .. snapshot.HitPath,
		"hitClass=" .. snapshot.HitClass,
		"hitMaterial=" .. snapshot.HitMaterial,
		"hitPosition=" .. formatDiagnosticVector(snapshot.HitPosition),
		"hitSize=" .. formatDiagnosticVector(snapshot.HitSize),
		"hitTopSurfaceY=" .. formatDiagnosticNumber(snapshot.HitTopSurfaceY),
		"hitCanCollide=" .. tostring(snapshot.HitCanCollide),
		"hitCanTouch=" .. tostring(snapshot.HitCanTouch),
		"hitCanQuery=" .. tostring(snapshot.HitCanQuery),
		"hitCollisionGroup=" .. snapshot.HitCollisionGroup,
		"raycastResultAvailable=false",
		"raycastHitPosition=unavailable",
		"raycastNormal=unavailable",
		"raycastDistance=unavailable",
		"rootBottomY=" .. formatDiagnosticNumber(snapshot.RootBottomY),
		"rootPosition=" .. formatDiagnosticVector(snapshot.RootPosition),
		"seatOccupant=" .. snapshot.SeatOccupantLabel,
		"seatOccupantPresent=" .. tostring(snapshot.SeatOccupantPresent),
		"seatOccupantValid=" .. tostring(snapshot.SeatOccupantValid),
		"expectedPlayerSeated=" .. tostring(snapshot.ExpectedPlayerSeated),
		"sledValid=" .. tostring(snapshot.SledValid),
		"detectorLimitation=SledRoot.Touched-provides-no-contact-position-normal-or-distance",
	}
	return table.concat(fields, " ")
end

local function emitLandingContactRecord(
	session: Session,
	runId: number,
	stage: string,
	buildRecord: () -> string
)
	local succeeded, recordOrError = pcall(buildRecord)
	if succeeded then
		print(recordOrError)
		return
	end

	warn(
		string.format(
			"%s player=%s RunId=%d phase=%s stage=%s activeExact=%s owner=unavailable ownership=unavailable serverOwned=unavailable diagnosticError=%s",
			LANDING_CONTACT_LOG_PREFIX,
			session.Player.Name,
			runId,
			session.Phase,
			stage,
			tostring(isSameSession(session, runId)),
			tostring(recordOrError)
		)
	)
end

local function retainLastAirborneContactSnapshot(session: Session, runId: number, timestamp: number)
	if not RUN.LaunchStabilityDiagnosticsEnabled then
		return
	end
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Airborne
		or session.Sled.Root.Parent ~= session.Sled.Model
	then
		return
	end

	local snapshot = safelyCaptureLandingContactMotionSnapshot(session, runId, timestamp)
	session.LastAirborneContactSnapshot = snapshot
end

local function emitLandingContactDiagnostics(
	session: Session,
	runId: number,
	touchdownAt: number,
	triggerSnapshot: LandingContactTriggerSnapshot?,
	triggerCaptureError: string?
)
	if not RUN.LaunchStabilityDiagnosticsEnabled then
		return
	end
	if session.LandingContactDiagnosticsConsumed == true then
		return
	end

	-- Consume before capture, formatting, or output so this diagnostic path is
	-- bounded to three records even if an individual record cannot be formatted.
	session.LandingContactDiagnosticsConsumed = true
	local lastAirborneSnapshot = session.LastAirborneContactSnapshot
	session.LastAirborneContactSnapshot = nil

	emitLandingContactRecord(session, runId, "last-airborne-pre-contact", function(): string
		if lastAirborneSnapshot and lastAirborneSnapshot.RunId == runId then
			return formatLandingContactMotionRecord(
				session,
				runId,
				"last-airborne-pre-contact",
				lastAirborneSnapshot,
				math.max(0, touchdownAt - lastAirborneSnapshot.CapturedAt)
			)
		end
		return formatMissingLastAirborneRecord(session, runId, triggerSnapshot)
	end)

	emitLandingContactRecord(session, runId, "touchdown-trigger", function(): string
		if triggerSnapshot then
			return formatLandingContactTriggerRecord(session, runId, triggerSnapshot)
		end
		error("trigger capture failed: " .. (triggerCaptureError or "unknown"))
	end)

	local postStateSnapshot, postCaptureError = safelyCaptureLandingContactMotionSnapshot(session, runId, os.clock())
	emitLandingContactRecord(session, runId, "touchdown-post-state", function(): string
		if postStateSnapshot then
			return formatLandingContactMotionRecord(
				session,
				runId,
				"touchdown-post-state",
				postStateSnapshot,
				0
			)
		end
		error("post-state capture failed: " .. (postCaptureError or "unknown"))
	end)
end

local function logLaunchStabilitySnapshot(
	session: Session,
	stage: string,
	guardResult: RampExitGuardResult?,
	asWarning: boolean
): boolean
	if not RUN.LaunchStabilityDiagnosticsEnabled then
		return false
	end

	local succeeded, message = pcall(function(): string
		local root = session.Sled.Root
		if root.Parent ~= session.Sled.Model then
			return string.format(
				"[Frostline][LaunchStability] player=%s RunId=%d phase=%s stage=%s root=unavailable guardConsumed=%s guardApplied=%s rollLimit=%s skipReason=%s",
				session.Player.Name,
				session.RunId,
				session.Phase,
				stage,
				tostring(session.rampExitRollGuardConsumed),
				tostring(session.rampExitRollGuardApplied),
				formatDiagnosticNumber(RUN.RampExitMaxRollRateRadiansPerSecond),
				session.rampExitRollGuardSkipReason or "root unavailable"
			)
		end

		local capturedCFrame = root.CFrame
		local linearVelocity = root.AssemblyLinearVelocity
		local horizontalSpeed = Vector3.new(linearVelocity.X, 0, linearVelocity.Z).Magnitude
		local angularVelocity = root.AssemblyAngularVelocity
		local bodyRightRate = angularVelocity:Dot(capturedCFrame.RightVector)
		local bodyUpRate = angularVelocity:Dot(capturedCFrame.UpVector)
		local longitudinalRollRate = angularVelocity:Dot(capturedCFrame.LookVector)
		local ownership = captureNetworkOwnership(root)
		local stabilizing = session.StabilityTorque.Parent ~= nil and session.StabilityTorque.Enabled
		local line = string.format(
			"[Frostline][LaunchStability] player=%s RunId=%d phase=%s stage=%s owner=%s ownership=%s position=%s mass=%s linear=%s horizontalSpeed=%s angularWorld=%s bodyRightRate=%s bodyUpRate=%s longitudinalRollRate=%s uprightDot=%s tuck=%s antiStall=%s stabilization=%s guardConsumed=%s guardApplied=%s rollLimit=%s skipReason=%s",
			session.Player.Name,
			session.RunId,
			session.Phase,
			stage,
			ownership.OwnerLabel,
			ownership.AutomaticLabel,
			formatDiagnosticVector(capturedCFrame.Position),
			formatDiagnosticNumber(root.AssemblyMass),
			formatDiagnosticVector(linearVelocity),
			formatDiagnosticNumber(horizontalSpeed),
			formatDiagnosticVector(angularVelocity),
			formatDiagnosticNumber(bodyRightRate),
			formatDiagnosticNumber(bodyUpRate),
			formatDiagnosticNumber(longitudinalRollRate),
			formatDiagnosticNumber(capturedCFrame.UpVector:Dot(Vector3.yAxis)),
			tostring(session.Tucking),
			tostring(session.AntiStallActive),
			tostring(stabilizing),
			tostring(session.rampExitRollGuardConsumed),
			tostring(session.rampExitRollGuardApplied),
			formatDiagnosticNumber(RUN.RampExitMaxRollRateRadiansPerSecond),
			session.rampExitRollGuardSkipReason or "none"
		)

		if guardResult then
			line ..= string.format(
				" rollBefore=%s rollAfter=%s correctionMagnitude=%s pitchBefore=%s pitchAfter=%s pitchCorrection=%s pitchGuardApplied=%s linearBefore=%s linearAfter=%s bodyRightBefore=%s bodyRightAfter=%s bodyUpBefore=%s bodyUpAfter=%s ownerBefore=%s ownerAfter=%s ownershipBefore=%s ownershipAfter=%s invariantFailure=%s",
				formatDiagnosticNumber(guardResult.RollRateBefore),
				formatDiagnosticNumber(guardResult.RollRateAfter),
				formatDiagnosticNumber(guardResult.CorrectionMagnitude),
				formatDiagnosticNumber(guardResult.PitchRateBefore),
				formatDiagnosticNumber(guardResult.PitchRateAfter),
				formatDiagnosticNumber(guardResult.PitchCorrection),
				tostring(guardResult.PitchGuardApplied),
				formatDiagnosticVector(guardResult.LinearVelocityBefore),
				formatDiagnosticVector(guardResult.LinearVelocityAfter),
				formatDiagnosticNumber(guardResult.BodyRightRateBefore),
				formatDiagnosticNumber(guardResult.BodyRightRateAfter),
				formatDiagnosticNumber(guardResult.BodyUpRateBefore),
				formatDiagnosticNumber(guardResult.BodyUpRateAfter),
				guardResult.OwnerBefore or "unavailable",
				guardResult.OwnerAfter or "unavailable",
				guardResult.AutomaticBefore or "unavailable",
				guardResult.AutomaticAfter or "unavailable",
				guardResult.InvariantFailure or "none"
			)
		end
		return line
	end)

	if succeeded then
		if asWarning then
			warn(message)
		else
			print(message)
		end
	else
		warn(
			string.format(
				"[Frostline][LaunchStability] player=%s RunId=%d phase=%s stage=%s snapshot failed reason=%s",
				session.Player.Name,
				session.RunId,
				session.Phase,
				stage,
				tostring(message)
			)
		)
	end
	return true
end

local function applyRampExitRollGuard(session: Session, runId: number): RampExitGuardResult
	local result: RampExitGuardResult = {
		Applied = false,
		SkipReason = nil,
		InvariantFailure = nil,
		RollRateBefore = nil,
		RollRateAfter = nil,
		CorrectionMagnitude = nil,
		PitchRateBefore = nil,
		PitchRateAfter = nil,
		PitchCorrection = nil,
		PitchGuardApplied = false,
		LinearVelocityBefore = nil,
		LinearVelocityAfter = nil,
		BodyRightRateBefore = nil,
		BodyRightRateAfter = nil,
		BodyUpRateBefore = nil,
		BodyUpRateAfter = nil,
		OwnerBefore = nil,
		OwnerAfter = nil,
		AutomaticBefore = nil,
		AutomaticAfter = nil,
	}

	local function skip(reason: string): RampExitGuardResult
		result.SkipReason = reason
		session.rampExitRollGuardSkipReason = reason
		return result
	end

	if not isSameSession(session, runId) then
		return skip("active session or RunId changed")
	elseif session.CleanupStarted then
		return skip("cleanup already started")
	elseif session.Phase ~= RunPhase.Airborne then
		return skip("first Airborne transition was not accepted")
	elseif session.EnteredAirborne then
		return skip("Airborne transition was not the first")
	elseif session.rampExitRollGuardConsumed then
		return skip("guard already consumed")
	end

	local root = session.Sled.Root
	local model = session.Sled.Model
	if root.Parent ~= model or not model:IsDescendantOf(Workspace) then
		return skip("SledRoot is not parented to the active sled")
	elseif root.Anchored then
		return skip("SledRoot is anchored")
	end

	local capturedCFrame = root.CFrame
	local angularVelocityBefore = root.AssemblyAngularVelocity
	local maximumRollRate = RUN.RampExitMaxRollRateRadiansPerSecond
	local maximumPitchRate = RUN.RampExitMaxPitchRateRadiansPerSecond
	if not isFiniteCFrame(capturedCFrame) then
		return skip("SledRoot CFrame is not finite")
	elseif not isFiniteVector3(angularVelocityBefore) then
		return skip("AssemblyAngularVelocity is not finite")
	elseif not isFinitePositiveNumber(maximumRollRate) then
		return skip("configured roll limit is not finite and positive")
	elseif not isFinitePositiveNumber(maximumPitchRate) then
		return skip("configured pitch limit is not finite and positive")
	end

	local ownershipBefore = captureNetworkOwnership(root)
	result.OwnerBefore = ownershipBefore.OwnerLabel
	result.AutomaticBefore = ownershipBefore.AutomaticLabel
	if ownershipBefore.OwnerReadFailure then
		return skip("network owner unavailable: " .. ownershipBefore.OwnerReadFailure)
	elseif ownershipBefore.OwnerIsServer ~= true then
		return skip("network owner is " .. ownershipBefore.OwnerLabel)
	end

	-- Consumption happens before any correction calculation or write, so this
	-- validated first-Airborne hook can never apply more than once per RunId.
	session.rampExitRollGuardConsumed = true
	local longitudinalAxis = capturedCFrame.LookVector.Unit
	local bodyRightAxis = capturedCFrame.RightVector.Unit
	local bodyUpAxis = capturedCFrame.UpVector.Unit
	local linearVelocityBefore = root.AssemblyLinearVelocity
	local rollRateBefore = angularVelocityBefore:Dot(longitudinalAxis)
	local rollRateAfter = math.clamp(rollRateBefore, -maximumRollRate, maximumRollRate)
	local rollCorrection = rollRateAfter - rollRateBefore
	local pitchRateBefore = angularVelocityBefore:Dot(bodyRightAxis)
	local pitchRateAfter = math.clamp(pitchRateBefore, -maximumPitchRate, maximumPitchRate)
	local pitchCorrection = pitchRateAfter - pitchRateBefore
	local applyRollCorrection = RUN.RampExitRollGuardEnabled
		and math.abs(rollCorrection) > RAMP_EXIT_ROLL_WRITE_EPSILON
	local applyPitchCorrection = RUN.RampExitPitchGuardEnabled
		and math.abs(pitchCorrection) > RAMP_EXIT_ROLL_WRITE_EPSILON
	local appliedRollCorrection = if applyRollCorrection then rollCorrection else 0
	local appliedPitchCorrection = if applyPitchCorrection then pitchCorrection else 0
	local combinedCorrection = longitudinalAxis * appliedRollCorrection
		+ bodyRightAxis * appliedPitchCorrection

	result.RollRateBefore = rollRateBefore
	result.CorrectionMagnitude = math.abs(rollCorrection)
	result.PitchRateBefore = pitchRateBefore
	result.PitchCorrection = 0
	result.LinearVelocityBefore = linearVelocityBefore
	result.BodyRightRateBefore = angularVelocityBefore:Dot(bodyRightAxis)
	result.BodyUpRateBefore = angularVelocityBefore:Dot(bodyUpAxis)

	local angularVelocityAfter = angularVelocityBefore
	if combinedCorrection.Magnitude > RAMP_EXIT_ROLL_WRITE_EPSILON then
		local correctedAngularVelocity = angularVelocityBefore + combinedCorrection
		local writeSucceeded, writeError = pcall(function()
			root.AssemblyAngularVelocity = correctedAngularVelocity
		end)
		if not writeSucceeded then
			return skip("AssemblyAngularVelocity correction failed: " .. tostring(writeError))
		end
		result.Applied = true
		result.PitchCorrection = appliedPitchCorrection
		result.PitchGuardApplied = applyPitchCorrection
		session.rampExitRollGuardApplied = applyRollCorrection
		angularVelocityAfter = correctedAngularVelocity
	end

	local linearVelocityAfter = root.AssemblyLinearVelocity
	local ownershipAfter = captureNetworkOwnership(root)
	result.RollRateAfter = angularVelocityAfter:Dot(longitudinalAxis)
	result.PitchRateAfter = angularVelocityAfter:Dot(bodyRightAxis)
	result.LinearVelocityAfter = linearVelocityAfter
	result.BodyRightRateAfter = angularVelocityAfter:Dot(bodyRightAxis)
	result.BodyUpRateAfter = angularVelocityAfter:Dot(bodyUpAxis)
	result.OwnerAfter = ownershipAfter.OwnerLabel
	result.AutomaticAfter = ownershipAfter.AutomaticLabel

	if result.Applied then
		local invariantFailures: { string } = {}
		if (linearVelocityAfter - linearVelocityBefore).Magnitude > RAMP_EXIT_INVARIANT_EPSILON then
			table.insert(invariantFailures, "linear velocity changed")
		end
		if math.abs(
			(result.BodyRightRateAfter :: number)
				- ((result.BodyRightRateBefore :: number) + appliedPitchCorrection)
		)
			> RAMP_EXIT_INVARIANT_EPSILON
		then
			table.insert(invariantFailures, "body-right angular rate did not match pitch correction")
		end
		if math.abs((result.BodyUpRateAfter :: number) - (result.BodyUpRateBefore :: number))
			> RAMP_EXIT_INVARIANT_EPSILON
		then
			table.insert(invariantFailures, "body-up angular rate changed")
		end
		if ownershipAfter.OwnerIsServer ~= true then
			table.insert(invariantFailures, "network ownership left the server")
		end
		if #invariantFailures > 0 then
			result.InvariantFailure = table.concat(invariantFailures, ", ")
		end
	end

	return result
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
		session.Outcome,
		session.Phase == RunPhase.Descent
			and not session.ReleaseInProgress
			and session.TuckActivationReady
	)
end

local function transitionTo(session: Session, nextPhase: Phase, deferStateDispatch: boolean?): boolean
	if session.Phase == nextPhase then
		if not deferStateDispatch then
			sendState(session)
		end
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
	if not deferStateDispatch then
		sendState(session)
	end
	return true
end

local function setTuckActive(session: Session, active: boolean)
	local forceAvailable = session.TuckForce.Parent ~= nil
	local root = session.Sled.Root
	local course = session.ResolvedCourse
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
		and not crossedForwardPlane(course, root.Position, course.LaunchLongitudinal)
	session.Tucking = shouldApply

	if shouldApply then
		session.TuckForce.Force = course.ForwardDirection * assemblyMass * RUN.TuckAcceleration
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

local function clearSteeringState(session: Session)
	session.SteeringTarget = 0
	session.SteeringApplied = 0
	local steeringForce = session.SteeringForce
	if steeringForce and steeringForce.Parent then
		steeringForce.Force = Vector3.zero
		steeringForce.Enabled = false
	end
end

local function disableSteeringForce(session: Session)
	local steeringForce = session.SteeringForce
	if steeringForce and steeringForce.Parent then
		steeringForce.Force = Vector3.zero
		steeringForce.Enabled = false
	end
end

local function hasExactSteeringAuthorization(session: Session): boolean
	local courses = resolvedCourses
	local course = session.ResolvedCourse
	local definition = CourseRegistry.Definitions[FROST_TRAIL_COURSE_ID]
	local profile = session.SteeringProfile
	return RunService:IsStudio()
		and courses ~= nil
		and session.CourseId == FROST_TRAIL_COURSE_ID
		and courses[FROST_TRAIL_COURSE_ID] == course
		and course.CourseId == FROST_TRAIL_COURSE_ID
		and course.Definition == definition
		and table.isfrozen(definition)
		and definition.ActivationMode == "StudioControlledTest"
		and FrostTrailConfig.ActivationMode == "StudioControlledTest"
		and FrostTrailConfig.Playable == false
		and table.isfrozen(FrostTrailConfig)
		and profile ~= nil
		and profile == FrostTrailConfig.Steering
		and table.isfrozen(profile)
		and profile.Enabled == true
end

local function hasExactSteeringOccupant(session: Session): boolean
	local sled = session.Sled
	return session.Player.Parent == Players
		and session.Player.Character == session.Character
		and session.Character.Parent == Workspace
		and session.Humanoid.Parent == session.Character
		and session.Humanoid.Health > 0
		and session.ResolvedCourse.World.Parent == Workspace
		and session.ResolvedCourse.ActiveSleds.Parent == session.ResolvedCourse.World
		and sled.Model.Parent == session.ResolvedCourse.ActiveSleds
		and sled.Model.PrimaryPart == sled.Root
		and sled.Root.Parent == sled.Model
		and sled.DriverSeat.Parent == sled.Model
		and sled.DriverSeat.Occupant == session.Humanoid
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
	if not RESULT.LifecycleDiagnosticsEnabled then
		if not valid then
			warn(
				string.format(
					"[Frostline][Run] %s Release validation failed stage=%s reason=%s",
					runLabel(session),
					stage,
					reason
				)
			)
		end
		return
	end

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
	local course = session.ResolvedCourse
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
		session.AntiStallForce.Force = course.ForwardDirection * assemblyMass * RUN.AntiStallAcceleration
		session.AntiStallForce.Enabled = true
		if RESULT.LifecycleDiagnosticsEnabled then
			print(string.format("[Frostline][Run] %s AntiStall activated", runLabel(session)))
		end
	elseif forceAvailable then
		session.AntiStallForce.Enabled = false
		session.AntiStallForce.Force = Vector3.zero
		if RESULT.LifecycleDiagnosticsEnabled then
			print(string.format("[Frostline][Run] %s AntiStall deactivated", runLabel(session)))
		end
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

	local currentForwardSpeed = forwardSpeed(
		session.ResolvedCourse,
		session.Sled.Root.AssemblyLinearVelocity
	)
	if session.AntiStallActive then
		if currentForwardSpeed >= RUN.AntiStallSpeed then
			setAntiStallActive(session, runId, false)
		end
	elseif currentForwardSpeed < RUN.AntiStallSpeed - ANTI_STALL_REACTIVATION_MARGIN then
		setAntiStallActive(session, runId, true)
	end
end

local function isTrackSurface(instance: Instance): boolean
	return string.match(instance.Name, "^Track_%d+$") ~= nil
		or instance:GetAttribute(TRACK_SURFACE_ATTRIBUTE) == true
end

local function updateFrostSteering(session: Session, runId: number, deltaTime: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or not hasExactSteeringAuthorization(session)
	then
		clearSteeringState(session)
		return
	end

	if session.Phase == RunPhase.Countdown then
		disableSteeringForce(session)
		return
	elseif session.Phase ~= RunPhase.Descent or session.RampFreedomEntered then
		clearSteeringState(session)
		return
	end

	if not hasExactSteeringOccupant(session) then
		clearSteeringState(session)
		return
	elseif session.ReleaseInProgress or not session.TuckActivationReady then
		-- Countdown intent survives the bounded release-synchronization window,
		-- but no lateral force is allowed until the release is authoritative.
		disableSteeringForce(session)
		return
	end

	local root = session.Sled.Root
	local course = session.ResolvedCourse
	local profile = session.SteeringProfile :: SteeringTuning
	local steeringForce = session.SteeringForce
	if steeringForce == nil
		or steeringForce.Parent ~= root
		or steeringForce.Attachment0 ~= session.TuckAttachment
		or session.TuckAttachment.Parent ~= root
		or root.Anchored
		or not isFiniteVector3(root.Position)
		or forwardCoordinate(course, root.Position) >= course.RampFreedomLongitudinal
	then
		clearSteeringState(session)
		return
	end

	local assemblyMass = root.AssemblyMass
	local linearVelocity = root.AssemblyLinearVelocity
	if not isFinitePositiveNumber(assemblyMass)
		or not isFiniteVector3(linearVelocity)
		or not isFiniteNumber(session.SteeringTarget)
		or not isFiniteNumber(session.SteeringApplied)
	then
		clearSteeringState(session)
		return
	end

	local now = os.clock()
	local lastAcceptedAt = session.LastSteeringAcceptedAt
	if session.SteeringTarget ~= 0
		and (lastAcceptedAt == nil or now - lastAcceptedAt > profile.ServerIntentTimeoutSeconds)
	then
		session.SteeringTarget = 0
	end

	local rayResult = Workspace:Raycast(
		root.Position,
		Vector3.new(0, -profile.GroundRayDistance, 0),
		session.GroundRaycastParams
	)
	local hit = if rayResult then rayResult.Instance else nil
	if hit == nil
		or not hit:IsA("BasePart")
		or not hit.CanCollide
		or not isTrackSurface(hit)
		or not hit:IsDescendantOf(course.Geometry)
	then
		disableSteeringForce(session)
		return
	end

	local integrationDelta = if isFiniteNumber(deltaTime) then math.clamp(deltaTime, 0, 0.10) else 0
	local target = math.clamp(session.SteeringTarget, -1, 1)
	local applied = math.clamp(session.SteeringApplied, -1, 1)
	local reversing = target ~= 0 and applied ~= 0 and math.sign(target) ~= math.sign(applied)
	local responseRate = if target == 0 or reversing
		then profile.AppliedInputReleasePerSecond
		else profile.AppliedInputRisePerSecond
	local maximumStep = responseRate * integrationDelta
	if target > applied then
		applied = math.min(target, applied + maximumStep)
	elseif target < applied then
		applied = math.max(target, applied - maximumStep)
	end
	if math.abs(applied) < profile.AppliedInputSnapEpsilon then
		applied = 0
	end
	session.SteeringApplied = math.clamp(applied, -1, 1)

	local forwardVelocity = math.max(0, linearVelocity:Dot(course.ForwardDirection))
	local lateralVelocity = linearVelocity:Dot(course.RightDirection)
	local maximumLateralSpeed = math.clamp(
		profile.LateralSpeedBase + profile.LateralSpeedPerForwardSpeed * forwardVelocity,
		profile.MinimumLateralSpeed,
		profile.MaximumLateralSpeed
	)
	local targetLateralVelocity = session.SteeringApplied * maximumLateralSpeed
	local lateralAcceleration = math.clamp(
		(targetLateralVelocity - lateralVelocity) / profile.LateralVelocityResponseSeconds,
		-profile.MaximumLateralAcceleration,
		profile.MaximumLateralAcceleration
	)
	local lateralForce = course.RightDirection * assemblyMass * lateralAcceleration
	if not isFiniteVector3(lateralForce) then
		disableSteeringForce(session)
		return
	end

	steeringForce.Force = lateralForce
	steeringForce.Enabled = true
end

local function getStallGroundRayDistance(root: Part): number
	local halfSize = root.Size * 0.5
	local rootCFrame = root.CFrame
	local verticalHalfExtent = math.abs(rootCFrame.RightVector.Y) * halfSize.X
		+ math.abs(rootCFrame.UpVector.Y) * halfSize.Y
		+ math.abs(rootCFrame.LookVector.Y) * halfSize.Z
	return verticalHalfExtent + STALL_GROUND_CONTACT_CLEARANCE
end

local function getStallSnapshot(session: Session, root: Part, releaseLongitudinal: number): StallSnapshot
	local course = session.ResolvedCourse
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
		Progress = forwardCoordinate(course, root.Position) - releaseLongitudinal,
		ForwardSpeed = forwardSpeed(course, velocity),
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

local function evaluateEarlyRecoveryCandidate(
	course: ResolvedCourse,
	root: Part,
	snapshot: StallSnapshot
): (boolean, string)
	local stopped, stoppedReason = evaluateStoppedCandidate(root, snapshot, true)
	if not stopped then
		return false, stoppedReason
	end

	local maximumLateralPosition = activeTrackWidth(course, snapshot.Position) * 0.5
		- math.max(root.Size.X, root.Size.Z) * 0.5
	if math.abs(lateralOffset(course, snapshot.Position)) > maximumLateralPosition then
		return false, "outside-track-footprint"
	end

	return true, "ok"
end

local function resetStallObservation(session: Session)
	session.StallObservationStartedAt = nil
	session.StallObservationStartLongitudinal = nil
	session.StallObservationKind = nil
end

local function updateStallObservation(
	session: Session,
	kind: StallObservationKind,
	root: Part,
	now: number
): (boolean, number)
	local course = session.ResolvedCourse
	local observationStartedAt = session.StallObservationStartedAt
	local observationStartLongitudinal = session.StallObservationStartLongitudinal
	if session.StallObservationKind ~= kind
		or observationStartedAt == nil
		or observationStartLongitudinal == nil
	then
		session.StallObservationKind = kind
		session.StallObservationStartedAt = now
		session.StallObservationStartLongitudinal = forwardCoordinate(course, root.Position)
		return false, 0
	end

	local currentLongitudinal = forwardCoordinate(course, root.Position)
	local observationProgress = math.abs(currentLongitudinal - observationStartLongitudinal)
	if observationProgress > EARLY_STALL_MAXIMUM_OBSERVATION_PROGRESS then
		session.StallObservationStartedAt = now
		session.StallObservationStartLongitudinal = currentLongitudinal
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
	if not RESULT.LifecycleDiagnosticsEnabled then
		return
	end
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
		or session.EnteredAirborne
	then
		resetStallObservation(session)
		return nil
	end

	local releaseLongitudinal = session.ReleaseLongitudinal
	local descentStartedAt = session.DescentStartedAt
	if releaseLongitudinal == nil or descentStartedAt == nil then
		resetStallObservation(session)
		return nil
	end

	local root = session.Sled.Root
	if not isCurrentSledRootValid(session, root) then
		resetStallObservation(session)
		return nil
	end

	local course = session.ResolvedCourse
	local snapshot = getStallSnapshot(session, root, releaseLongitudinal)
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
			candidateAccepted, rejectionReason = evaluateEarlyRecoveryCandidate(course, root, snapshot)
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
			or session.EnteredAirborne
			or session.MissedLaunchConfirmed
			or not isCurrentSledRootValid(session, root)
		then
			resetStallObservation(session)
			return nil
		end

		local finalSnapshot = getStallSnapshot(session, root, releaseLongitudinal)
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

	local finalSnapshot = getStallSnapshot(session, root, releaseLongitudinal)
	session.MaximumDescentProgress = math.max(session.MaximumDescentProgress, finalSnapshot.Progress)
	local finalElapsed = now - descentStartedAt
	local finalAtForwardFrontier = session.MaximumDescentProgress - finalSnapshot.Progress
		<= EARLY_STALL_MAXIMUM_OBSERVATION_PROGRESS
	local finalCandidateAccepted, finalRejectionReason = evaluateEarlyRecoveryCandidate(course, root, finalSnapshot)
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
	local currentVelocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = withMinimumForwardSpeed(course, currentVelocity, RUN.InitialPushSpeed)
	if RESULT.LifecycleDiagnosticsEnabled then
		local recoveryStartPosition = root.Position
		print(
			string.format(
				"[Frostline][Run] %s Stall recovery confirmed progress=%.2f forwardSpeed=%.2f reappliedSpeed=%.2f",
				runLabel(session),
				observationProgress,
				finalSnapshot.ForwardSpeed,
				forwardSpeed(course, root.AssemblyLinearVelocity)
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

			local recoveredProgress = forwardProgress(course, recoveryStartPosition, root.Position)
			local recoveredSpeed = forwardSpeed(course, root.AssemblyLinearVelocity)
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
	end
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
	clearSteeringState(session)
end

local function updateRampFreedom(session: Session, runId: number)
	local course = session.ResolvedCourse
	if session.Phase == RunPhase.Descent
		and not session.RampFreedomEntered
		and session.Sled.Root.Parent
		and crossedForwardPlane(course, session.Sled.Root.Position, course.RampFreedomLongitudinal)
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

local function logCharacterRootPosition(session: Session, event: string, character: Model?)
	if not RESULT.LifecycleDiagnosticsEnabled then
		return
	end

	local liveCharacter = character
	local root: BasePart? = nil
	if liveCharacter and liveCharacter.Parent then
		local rootInstance = liveCharacter:FindFirstChild("HumanoidRootPart")
		if rootInstance and rootInstance:IsA("BasePart") then
			root = rootInstance
		end
	end

	local characterIdentity = if liveCharacter then liveCharacter:GetFullName() else "nil"
	local positionText = "unavailable"
	if root then
		local position = root.Position
		positionText = string.format("(%.2f,%.2f,%.2f)", position.X, position.Y, position.Z)
	end
	lifecycleLog(
		session,
		event,
		string.format("character=%s rootPosition=%s", characterIdentity, positionText)
	)
end

local function teleportToSpawn(session: Session, runId: number, traceReturn: boolean): boolean
	if not isSameSession(session, runId) or session.Player.Parent ~= Players then
		return false
	end

	local targetCFrame = CFrame.new()
	local targetAvailable = pcall(function()
		local playerSpawn = session.ResolvedCourse.PlayerSpawn
		if not playerSpawn.Parent or not playerSpawn:IsDescendantOf(Workspace) then
			error("PlayerSpawn unavailable")
		end
		targetCFrame = playerSpawn.CFrame + Vector3.new(0, 4, 0)
	end)
	if not targetAvailable then
		warn(string.format("[Frostline][Run] %s Teleport verification result=spawn unavailable", runLabel(session)))
		return false
	end
	if RESULT.LifecycleDiagnosticsEnabled then
		lifecycleLog(
			session,
			"teleport-target",
			string.format("target=(%.1f,%.1f,%.1f)", targetCFrame.X, targetCFrame.Y, targetCFrame.Z)
		)
	end

	local controlledRoot: BasePart? = nil
	local function releaseControlledRoot()
		local root = controlledRoot
		controlledRoot = nil
		if not root or not root.Parent then
			return
		end
		pcall(function()
			root.Anchored = false
		end)
		pcall(function()
			root:SetNetworkOwnershipAuto()
		end)
	end

	local function getLiveCharacter(): (Model?, Humanoid?, BasePart?)
		local character = session.Player.Character
		if not character or not character:IsA("Model") or not character.Parent then
			return nil, nil, nil
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootInstance = character:FindFirstChild("HumanoidRootPart")
		if not humanoid
			or humanoid.Health <= 0
			or not rootInstance
			or not rootInstance:IsA("BasePart")
		then
			return nil, nil, nil
		end
		return character, humanoid, rootInstance
	end

	local characterReadyWaitElapsed = 0
	local function getLiveCharacterWithinBudget(): (Model?, Humanoid?, BasePart?)
		local character, humanoid, root = getLiveCharacter()
		local loggedWait = false
		while not character
			and characterReadyWaitElapsed < RESULT.TeleportCharacterReadyTimeoutSeconds
		do
			if not isSameSession(session, runId) or session.Player.Parent ~= Players then
				return nil, nil, nil
			end
			if not loggedWait then
				loggedWait = true
				lifecycleLog(session, "teleport-character-wait", "state=waiting-for-live-character")
			end
			characterReadyWaitElapsed += RunService.Heartbeat:Wait()
			character, humanoid, root = getLiveCharacter()
		end
		return character, humanoid, root
	end

	local function isCurrentSubject(character: Model, humanoid: Humanoid, root: BasePart): boolean
		return isSameSession(session, runId)
			and session.Player.Parent == Players
			and session.Player.Character == character
			and character.Parent ~= nil
			and humanoid.Parent == character
			and humanoid.Health > 0
			and root.Parent ~= nil
			and root:IsDescendantOf(character)
	end

	local function setServerOwnership(root: BasePart): boolean
		local succeeded = pcall(function()
			root:SetNetworkOwner(nil)
		end)
		return succeeded
	end

	local function logTeleportStage(stage: string, attempt: number, character: Model, root: BasePart, distance: number)
		if not traceReturn or not RESULT.LifecycleDiagnosticsEnabled then
			return
		end
		local position = root.Position
		lifecycleLog(
			session,
			"teleport-" .. stage,
			string.format(
				"attempt=%d character=%s rootPosition=(%.2f,%.2f,%.2f) distance=%.2f",
				attempt,
				character:GetFullName(),
				position.X,
				position.Y,
				position.Z,
				distance
			)
		)
	end

	local function readDistance(character: Model, humanoid: Humanoid, root: BasePart): (boolean, number)
		if not isCurrentSubject(character, humanoid, root) then
			return false, math.huge
		end
		return true, (root.Position - targetCFrame.Position).Magnitude
	end

	local function waitUntilElapsed(
		character: Model,
		humanoid: Humanoid,
		root: BasePart,
		elapsed: number,
		targetElapsed: number
	): (boolean, number)
		local accumulated = elapsed
		while accumulated < targetElapsed do
			accumulated += RunService.Heartbeat:Wait()
			if not isCurrentSubject(character, humanoid, root) then
				return false, accumulated
			end
		end
		return true, accumulated
	end

	local function performAttempt(attempt: number): (boolean, number, string)
		if not isSameSession(session, runId) or session.Player.Parent ~= Players then
			return false, math.huge, "session unavailable"
		end
		local character, humanoid, root = getLiveCharacterWithinBudget()
		if not character or not humanoid or not root then
			return false, math.huge, "character unavailable"
		end
		controlledRoot = root

		if root.Anchored then
			root.Anchored = false
		end
		if not setServerOwnership(root) then
			return false, math.huge, "server network ownership unavailable"
		end

		root.Anchored = true
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		character:PivotTo(targetCFrame)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		local immediateAvailable, immediateDistance = readDistance(character, humanoid, root)
		if not immediateAvailable then
			return false, math.huge, "character changed after pivot"
		end
		logTeleportStage("pivot-immediate", attempt, character, root, immediateDistance)

		for anchoredStep = 1, 2 do
			RunService.PostSimulation:Wait()
			local stepAvailable, stepDistance = readDistance(character, humanoid, root)
			if not stepAvailable then
				return false, math.huge, "character changed while anchored"
			end
			if anchoredStep == 1 then
				logTeleportStage("anchored-first-step", attempt, character, root, stepDistance)
			end
		end

		root.Anchored = false
		if not setServerOwnership(root) then
			return false, math.huge, "server network ownership lost on release"
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)

		local elapsed = RunService.Heartbeat:Wait()
		local firstAvailable, firstDistance = readDistance(character, humanoid, root)
		if not firstAvailable then
			return false, math.huge, "character changed after release"
		end
		logTeleportStage("released-first-step", attempt, character, root, firstDistance)
		if firstDistance > RESULT.TeleportToleranceStuds then
			return false, firstDistance, "rollback after first released step"
		end

		local intermediateWaited: boolean
		intermediateWaited, elapsed = waitUntilElapsed(
			character,
			humanoid,
			root,
			elapsed,
			RESULT.TeleportIntermediateVerificationSeconds
		)
		if not intermediateWaited then
			return false, math.huge, "character changed before intermediate verification"
		end
		local intermediateAvailable, intermediateDistance = readDistance(character, humanoid, root)
		if not intermediateAvailable then
			return false, math.huge, "character changed at intermediate verification"
		end
		logTeleportStage("released-0.25", attempt, character, root, intermediateDistance)
		if intermediateDistance > RESULT.TeleportToleranceStuds then
			return false, intermediateDistance, "rollback by intermediate verification"
		end

		local finalWaited: boolean
		finalWaited, elapsed = waitUntilElapsed(
			character,
			humanoid,
			root,
			elapsed,
			RESULT.TeleportFinalVerificationSeconds
		)
		if not finalWaited then
			return false, math.huge, "character changed before final verification"
		end
		local finalAvailable, finalDistance = readDistance(character, humanoid, root)
		if not finalAvailable then
			return false, math.huge, "character changed at final verification"
		end
		logTeleportStage("released-0.75", attempt, character, root, finalDistance)
		if finalDistance > RESULT.TeleportToleranceStuds then
			return false, finalDistance, "rollback by final verification"
		end

		return true, finalDistance, "stable"
	end

	local callSucceeded, verified, finalDistance, detail = pcall(function(): (boolean, number, string)
		local firstVerified, firstDistance, firstDetail = performAttempt(1)
		if firstVerified then
			return true, firstDistance, firstDetail
		end

		warn(
			string.format(
				"[Frostline][Run] %s Teleport attempt failed distance=%s detail=%s; retrying once",
				runLabel(session),
				if firstDistance < math.huge then string.format("%.2f", firstDistance) else "unavailable",
				firstDetail
			)
		)
		releaseControlledRoot()
		if not isSameSession(session, runId) or session.Player.Parent ~= Players then
			return false, math.huge, "session unavailable before retry"
		end
		local retryVerified, retryDistance, retryDetail = performAttempt(2)
		return retryVerified, retryDistance, retryDetail
	end)

	releaseControlledRoot()
	if not callSucceeded then
		warn(
			string.format(
				"[Frostline][Run] %s Teleport verification result=error detail=%s",
				runLabel(session),
				tostring(verified)
			)
		)
		return false
	end

	if verified then
		if RESULT.LifecycleDiagnosticsEnabled then
			local resultMessage = string.format(
				"result=passed distance=%s detail=%s",
				if finalDistance < math.huge then string.format("%.2f", finalDistance) else "unavailable",
				detail
			)
			print(string.format("[Frostline][Run] %s Teleport verification %s", runLabel(session), resultMessage))
			lifecycleLog(session, "teleport-verification", resultMessage)
		end
	else
		local resultMessage = string.format(
			"result=failed distance=%s detail=%s",
			if finalDistance < math.huge then string.format("%.2f", finalDistance) else "unavailable",
			detail
		)
		warn(string.format("[Frostline][Run] %s Teleport verification %s", runLabel(session), resultMessage))
		lifecycleLog(session, "teleport-verification", resultMessage)
	end
	return verified
end

local function scheduleTrustedReplay(session: Session, runId: number)
	local player = session.Player
	local courseId = session.CourseId
	pendingReplays[player] = {
		Session = session,
		RunId = runId,
		CourseId = courseId,
	}
	lifecycleLog(session, "replay-queued", "waitingFor=cleanup-boundary")

	task.defer(function()
		RunService.Heartbeat:Wait()
		local pendingReplay = pendingReplays[player]
		if not pendingReplay
			or pendingReplay.Session ~= session
			or pendingReplay.RunId ~= runId
			or pendingReplay.CourseId ~= courseId
			or session.CourseId ~= courseId
		then
			return
		end
		if sessions[player] ~= session or session.RunId ~= runId then
			pendingReplays[player] = nil
			refreshStartPrompts()
			return
		end

		pendingReplays[player] = nil
		if player.Parent ~= Players then
			sessions[player] = nil
			refreshStartPrompts()
			return
		end

		local replay = trustedReplay
		if not replay then
			lifecycleLog(session, "replay-cancelled", "reason=trusted-replay-unavailable")
			sessions[player] = nil
			refreshStartPrompts()
			return
		end

		-- Remove the captured old session and synchronously enter the trusted start
		-- path. beginRun publishes the replacement session before its first yield.
		lifecycleLog(session, "replay-creation", "state=starting")
		sessions[player] = nil
		replay(player, courseId)
		refreshStartPrompts()
	end)
end

local function cleanupSession(session: Session, runId: number, teleportPlayer: boolean, reason: string)
	clearSteeringState(session)
	if not isSameSession(session, runId) then
		return
	end
	session.LastAirborneContactSnapshot = nil
	session.LandingContactDiagnosticsConsumed = nil
	if RESULT.LifecycleDiagnosticsEnabled then
		lifecycleLog(session, "cleanup-started", string.format("reason=%s", reason))
	end

	disconnectSession(session)
	local traceReturn = teleportPlayer and session.ResultActionAccepted and not session.ReplayRequested
	if traceReturn then
		logCharacterRootPosition(session, "return-before-seat-detachment", session.Player.Character)
	end
	pcall(function()
		if session.Humanoid.Parent then
			session.Humanoid.Sit = false
			session.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
	pcall(function()
		local seatWeld = session.Sled.DriverSeat:FindFirstChild("SeatWeld", true)
		if seatWeld then
			seatWeld:Destroy()
		end
	end)
	if traceReturn then
		logCharacterRootPosition(session, "return-after-seat-detachment", session.Player.Character)
	end

	if session.Sled.Model.Parent then
		session.Sled.Model:Destroy()
	end
	if traceReturn then
		logCharacterRootPosition(session, "return-after-sled-destruction", session.Player.Character)
	end
	restoreCharacterMass(session.OriginalMassless)

	RunService.PostSimulation:Wait()
	if not isSameSession(session, runId) then
		return
	end

	local teleportVerified = not teleportPlayer
	if teleportPlayer then
		setPreparedCourse(session.Player, session.CourseId)
		local teleportCallSucceeded, teleportResult = pcall(teleportToSpawn, session, runId, traceReturn)
		teleportVerified = teleportCallSucceeded and teleportResult == true
		if not teleportCallSucceeded then
			warn(
				string.format(
					"[Frostline][Run] %s Teleport verification result=error detail=%s",
					runLabel(session),
					tostring(teleportResult)
				)
			)
		elseif not teleportVerified then
			warn(string.format("[Frostline][Run] %s Teleport verification result=failed", runLabel(session)))
		end
	end

	if not isSameSession(session, runId) then
		return
	end
	if teleportPlayer and not teleportVerified then
		session.ReplayRequested = false
		lifecycleLog(session, "cleanup-failed", "reason=teleport-not-stable")
		warn(
			string.format(
				"[Frostline][Run] %s Cleanup incomplete reason=%s teleportStable=false",
				runLabel(session),
				reason
			)
		)
		if sessions[session.Player] == session then
			sessions[session.Player] = nil
		end
		refreshStartPrompts()
		return
	end
	local replayRequested = session.ReplayRequested and teleportVerified
	if session.Player.Parent == Players then
		session.Outcome = nil
		transitionTo(session, RunPhase.Idle)
	end
	if RESULT.LifecycleDiagnosticsEnabled then
		print(
			string.format(
				"[Frostline][Run] %s Cleanup completed reason=%s",
				runLabel(session),
				reason
			)
		)
	end

	if replayRequested and session.Player.Parent == Players then
		scheduleTrustedReplay(session, runId)
	elseif sessions[session.Player] == session then
		sessions[session.Player] = nil
	end
	refreshStartPrompts()
end

local function formatTelemetryNumber(value: number?): string
	return if value == nil then "n/a" else string.format("%.2f", value)
end

local function updateMaximumDistance(session: Session)
	if not session.Sled.Root.Parent then
		return
	end

	session.MaximumDistanceMeters = math.max(
		session.MaximumDistanceMeters,
		distanceFromLaunch(session.ResolvedCourse, session.Sled.Root.Position)
	)
end

local function emitTelemetry(session: Session)
	if session.TelemetryLogged then
		return
	end
	session.TelemetryLogged = true
	if not RESULT.RunTelemetryEnabled then
		return
	end

	local fieldDistance = session.ResolvedCourse.LandingFieldDistanceMeters
	local finalStopDistance = session.FinalStopDistanceMeters
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
		session.MaximumDistanceMeters,
		formatTelemetryNumber(session.FinalStopDistanceMeters),
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
		if RESULT.LifecycleDiagnosticsEnabled then
			print(
				string.format(
					"[Frostline][Run] %s Duplicate cleanup ignored reason=%s firstReason=%s",
					runLabel(session),
					reason,
					session.FirstCleanupReason or "unknown"
				)
			)
		end
		return
	end

	-- This flag is deliberately first: changing Reset state, seating, or physics can fire callbacks.
	session.CleanupStarted = true
	session.FirstCleanupReason = reason
	session.LastAirborneContactSnapshot = nil
	session.LandingContactDiagnosticsConsumed = nil
	if RESULT.LifecycleDiagnosticsEnabled then
		print(string.format("[Frostline][Run] %s Cleanup requested firstReason=%s", runLabel(session), reason))
		lifecycleLog(session, "cleanup-requested", string.format("reason=%s", reason))
	end
	session.ReleaseInProgress = false
	resetStallObservation(session)
	clearTuckState(session)
	clearSteeringState(session)
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

local function acceptResultAction(session: Session, runId: number, action: ResultAction, source: string)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Results
		or not session.ResultFinalized
		or session.ResultActionAccepted
	then
		return
	end

	session.ResultActionAccepted = true
	session.ReplayRequested = action == ResultTypes.Actions.PlayAgain
	if RESULT.LifecycleDiagnosticsEnabled then
		lifecycleLog(session, "result-action", string.format("action=%s source=%s", action, source))
	end
	requestCleanup(session, runId, string.format("result action %s source=%s", action, source), true)
end

local function scheduleResultTimeout(session: Session, runId: number)
	task.delay(RESULT.ResultActionTimeoutSeconds, function()
		if isSameSession(session, runId)
			and not session.CleanupStarted
			and session.Phase == RunPhase.Results
			and session.ResultFinalized
			and not session.ResultActionAccepted
		then
			acceptResultAction(session, runId, ResultTypes.Actions.ReturnToStart, "timeout")
		end
	end)
end

local function finalizeResult(session: Session, runId: number, outcome: ResultOutcome): boolean
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Results
		or session.ResultFinalized
	then
		return false
	end

	local courseId = session.CourseId
	local finalStopDistanceMeters = session.FinalStopDistanceMeters
	local finalUprightDot = session.FinalUprightDot
	local remote = resultRemote
	if finalStopDistanceMeters == nil
		or finalUprightDot == nil
		or not remote
		or session.Player.Parent ~= Players
	then
		return false
	end

	local facts: ResultTypes.ServerFacts = {
		RunId = runId,
		Outcome = outcome,
		FinalStopDistanceMeters = finalStopDistanceMeters,
		MaximumDistanceMeters = session.MaximumDistanceMeters,
		TuckUsed = session.TuckUsed,
		EnteredAirborne = session.EnteredAirborne,
		TouchedFrozenLake = session.TouchedFrozenLake,
		SeatSeparatedAfterAirborne = session.SeatSeparatedAfterAirborne,
		FinalUprightDot = finalUprightDot,
	}
	local payload, failureReason = ResultService.finalize(session.Player, courseId, facts)
	if not payload then
		warn(
			string.format(
				"[Frostline][Result] %s Finalization rejected reason=%s",
				runLabel(session),
				failureReason or "unknown"
			)
		)
		return false
	end

	session.ResultOutcome = outcome
	session.ResultPayload = payload
	session.ResultFinalized = true
	remote:FireClient(session.Player, payload)
	scheduleResultTimeout(session, runId)
	return true
end

local function finishMissedLaunch(session: Session, runId: number, snapshot: StallSnapshot)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.ReleaseInProgress
		or not session.TuckActivationReady
		or session.Phase ~= RunPhase.Descent
		or session.EnteredAirborne
		or session.MissedLaunchConfirmed
	then
		return
	end

	session.MissedLaunchConfirmed = true
	session.Outcome = MISSED_LAUNCH_OUTCOME
	session.MaximumDescentProgress = math.max(session.MaximumDescentProgress, snapshot.Progress)
	local root = session.Sled.Root
	if not root.Parent then
		requestCleanup(session, runId, "sled removed during missed launch", true)
		return
	end
	session.FinalStopDistanceMeters = distanceFromLaunch(session.ResolvedCourse, root.Position)
	session.FinalUprightDot = root.CFrame.UpVector:Dot(Vector3.yAxis)
	resetStallObservation(session)
	clearTuckState(session)
	clearSteeringState(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
	if RESULT.LifecycleDiagnosticsEnabled then
		print(
			string.format(
				"[Frostline][Run] %s Missed launch confirmed progress=%.2f horizontalSpeed=%.2f angularSpeed=%.2f",
				runLabel(session),
				session.MaximumDescentProgress,
				snapshot.HorizontalSpeed,
				snapshot.AngularSpeed
			)
		)
	end

	if not transitionTo(session, RunPhase.Results) then
		requestCleanup(session, runId, "missed launch transition failed", true)
		return
	end
	if not finalizeResult(session, runId, ResultTypes.Outcomes.Stalled) then
		requestCleanup(session, runId, "stalled result finalization failed", true)
	end
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
	local diagnosticHorizontalSpeed = 0
	local diagnosticAngularSpeed = 0
	if RESULT.LifecycleDiagnosticsEnabled then
		local velocity = root.AssemblyLinearVelocity
		diagnosticHorizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		diagnosticAngularSpeed = root.AssemblyAngularVelocity.Magnitude
	end
	updateMaximumDistance(session)
	session.FinalStopDistanceMeters = distanceFromLaunch(session.ResolvedCourse, position)
	session.FinalUprightDot = root.CFrame.UpVector:Dot(Vector3.yAxis)
	if session.Sled.DriverSeat.Occupant ~= session.Humanoid then
		session.SeatSeparatedAfterAirborne = true
	end
	session.StopConfirmed = true
	logLaunchStabilitySnapshot(session, "final-stop", nil, false)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.Anchored = true

	if RESULT.LifecycleDiagnosticsEnabled then
		print(
			string.format(
				"[Frostline][Run] %s Landing stop confirmed position=(%.1f, %.1f, %.1f) speed=%.2f angularSpeed=%.2f",
				runLabel(session),
				position.X,
				position.Y,
				position.Z,
				diagnosticHorizontalSpeed,
				diagnosticAngularSpeed
			)
		)
	end
	if not transitionTo(session, RunPhase.Results) then
		requestCleanup(session, runId, "results transition failed", true)
		return
	end

	if not session.EnteredAirborne or not session.TouchedFrozenLake then
		requestCleanup(session, runId, "landing result facts invalid", true)
		return
	end
	local finalUprightDot = session.FinalUprightDot
	if finalUprightDot == nil then
		requestCleanup(session, runId, "landing upright result unavailable", true)
		return
	end
	local outcome: ResultOutcome = if session.SeatSeparatedAfterAirborne
		or finalUprightDot < RESULT.MinimumCleanUprightDot
		then ResultTypes.Outcomes.Crashed
		else ResultTypes.Outcomes.CleanLanding
	if not finalizeResult(session, runId, outcome) then
		requestCleanup(session, runId, "landing result finalization failed", true)
	end
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

local function isExtremeLateralPosition(course: ResolvedCourse, position: Vector3): boolean
	return math.abs(lateralOffset(course, position)) > course.SafetyMaximumLateralDistance
end

local function addSessionConnection(session: Session, connection: RBXScriptConnection)
	table.insert(session.Connections, connection)
end

local function enterAirborne(session: Session, runId: number)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Descent
		or session.EnteredAirborne
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
	clearSteeringState(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
	if transitionTo(session, RunPhase.Airborne, true) then
		local guardResult = applyRampExitRollGuard(session, runId)
		session.EnteredAirborne = true
		local warningReason = guardResult.SkipReason or guardResult.InvariantFailure
		local diagnosticReported = logLaunchStabilitySnapshot(
			session,
			"first-airborne",
			guardResult,
			warningReason ~= nil
		)
		if warningReason and not diagnosticReported then
			warn(
				string.format(
					"[Frostline][LaunchStability] player=%s RunId=%d ramp-exit roll guard warning reason=%s",
					session.Player.Name,
					session.RunId,
					warningReason
				)
			)
		end
		sendState(session)
		if RESULT.LifecycleDiagnosticsEnabled then
			print(string.format("[Frostline][Run] %s Airborne", runLabel(session)))
		end
	end
end

local function enterLanded(session: Session, runId: number, hitPart: BasePart)
	if not isSameSession(session, runId)
		or session.CleanupStarted
		or session.Phase ~= RunPhase.Airborne
		or not session.Sled.Root.Parent
	then
		return
	end

	local diagnosticsEnabled = RUN.LaunchStabilityDiagnosticsEnabled
	local touchdownAt = 0
	local triggerSnapshot: LandingContactTriggerSnapshot? = nil
	local triggerCaptureError: string? = nil
	if diagnosticsEnabled then
		touchdownAt = os.clock()
		triggerSnapshot, triggerCaptureError = safelyCaptureLandingContactTriggerSnapshot(
			session,
			runId,
			hitPart,
			touchdownAt,
			LANDING_CONTACT_SOURCE,
			LANDING_CONTACT_CONDITION
		)
	end

	clearTuckState(session)
	clearSteeringState(session)
	setAntiStallActive(session, runId, false)
	setStabilityActive(session, false)
	if transitionTo(session, RunPhase.Landed) then
		if diagnosticsEnabled then
			emitLandingContactDiagnostics(
				session,
				runId,
				touchdownAt,
				triggerSnapshot,
				triggerCaptureError
			)
		end
		session.TouchedFrozenLake = true
		if session.Sled.DriverSeat.Occupant ~= session.Humanoid then
			session.SeatSeparatedAfterAirborne = true
		end
		local touchdownVelocity = session.Sled.Root.AssemblyLinearVelocity
		local touchdownHorizontalSpeed = Vector3.new(
			touchdownVelocity.X,
			0,
			touchdownVelocity.Z
		).Magnitude
		session.TouchdownHorizontalSpeed = touchdownHorizontalSpeed
		session.LandingSettledSince = nil
		updateMaximumDistance(session)
		logLaunchStabilitySnapshot(session, "first-touchdown", nil, false)
		if RESULT.LifecycleDiagnosticsEnabled then
			print(
				string.format(
					"[Frostline][Run] %s Landed z=%.1f horizontalSpeed=%.1f",
					runLabel(session),
					session.Sled.Root.Position.Z,
					touchdownHorizontalSpeed
				)
			)
		end
		updateLandingStopDetection(session, runId, os.clock())
	end
end

local function monitorSession(session: Session, runId: number)
	addSessionConnection(
		session,
		RunService.Heartbeat:Connect(function(deltaTime: number)
			if not isSameSession(session, runId) or session.CleanupStarted then
				if session.CourseId == FROST_TRAIL_COURSE_ID then
					clearSteeringState(session)
				end
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
			local course = session.ResolvedCourse
			if not root.Parent then
				local removalReason = if session.ReleaseInProgress then "sled removed during release" else "sled removed"
				requestCleanup(session, runId, removalReason, true)
				return
			end
			local now = os.clock()
			updateRampFreedom(session, runId)
			if session.Phase == RunPhase.Descent
				and crossedForwardPlane(course, root.Position, course.LaunchLongitudinal)
			then
				enterAirborne(session, runId)
			end
			if RUN.LaunchStabilityDiagnosticsEnabled then
				retainLastAirborneContactSnapshot(session, runId, now)
			end
			if session.CourseId == FROST_TRAIL_COURSE_ID then
				updateFrostSteering(session, runId, deltaTime)
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
			if position.Y < course.SafetyMinimumWorldY then
				requestCleanup(session, runId, "fell below the world", true)
				return
			elseif isExtremeLateralPosition(course, position) then
				requestCleanup(session, runId, "exceeded lateral safety bounds", true)
				return
			end

			local descentStartedAt = session.DescentStartedAt
			if session.Phase ~= RunPhase.Landed
				and session.Phase ~= RunPhase.Results
				and descentStartedAt
				and now - descentStartedAt >= course.MaximumRunDurationSeconds
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

local function connectRunEvents(session: Session, runId: number)
	local course = session.ResolvedCourse
	addSessionConnection(
		session,
		session.Sled.Root.Touched:Connect(function(otherPart: BasePart)
			if not isSameSession(session, runId) or session.CleanupStarted then
				return
			end

			if otherPart == course.LaunchEdge and session.Phase == RunPhase.Descent then
				enterAirborne(session, runId)
			elseif isCourseLandingSurface(course, otherPart) then
				-- A high-speed sled can cross the thin LaunchEdge between physics events.
				-- Promote it first so touchdown is still recognized on the same contact.
				if session.Phase == RunPhase.Descent
					and crossedForwardPlane(course, session.Sled.Root.Position, course.LaunchLongitudinal)
				then
					enterAirborne(session, runId)
				end
				if session.Phase == RunPhase.Airborne then
					enterLanded(session, runId, otherPart)
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
				or session.Phase == RunPhase.Reset
			then
				return
			end

			local seatSeparated = session.Sled.DriverSeat.Occupant ~= session.Humanoid
			if session.EnteredAirborne and seatSeparated then
				session.SeatSeparatedAfterAirborne = true
			end
			if session.Phase == RunPhase.Landed or session.Phase == RunPhase.Results then
				return
			end

			-- Once ramp freedom begins, a natural launch or crash may unseat the rider;
			-- the physical run still owns cleanup and returns them after the sled stops.
			local phaseAllowsSeatExit = session.Phase == RunPhase.Countdown
				or (session.Phase == RunPhase.Descent and not session.RampFreedomEntered)
			if phaseAllowsSeatExit and seatSeparated then
				requestCleanup(session, runId, "player left sled", true)
			end
		end)
	)

	monitorSession(session, runId)
end

local function verifyReleaseAfterHeartbeat(
	session: Session,
	runId: number,
	releaseLongitudinal: number
): (boolean, string)
	local releaseValid, releaseReason = validateRelease(session, runId, RunPhase.Descent, false)
	logReleaseValidity(session, "post", releaseValid, releaseReason)
	if not releaseValid then
		return false, releaseReason
	end

	local root = session.Sled.Root
	local course = session.ResolvedCourse
	local measuredVelocity = root.AssemblyLinearVelocity
	local measuredForwardSpeed = forwardSpeed(course, measuredVelocity)
	local reapplied = false
	if measuredForwardSpeed < RUN.InitialPushSpeed then
		root.AssemblyLinearVelocity = withMinimumForwardSpeed(course, measuredVelocity, RUN.InitialPushSpeed)
		reapplied = true
	end

	if RESULT.LifecycleDiagnosticsEnabled then
		local progress = forwardCoordinate(course, root.Position) - releaseLongitudinal
		print(
			string.format(
				"[Frostline][Run] %s Release verification result=%s progress=%.2f forwardSpeed=%.2f",
				runLabel(session),
				if reapplied then "reapplied" else "passed",
				progress,
				measuredForwardSpeed
			)
		)
	end
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
	lifecycleLog(session, "countdown-completed", "state=validating-release")
	local preReleaseValid, preReleaseReason = validateRelease(session, runId, RunPhase.Countdown, true)
	logReleaseValidity(session, "pre", preReleaseValid, preReleaseReason)
	if RESULT.LifecycleDiagnosticsEnabled then
		lifecycleLog(
			session,
			"release-validation",
			string.format("stage=pre valid=%s reason=%s", tostring(preReleaseValid), preReleaseReason)
		)
	end
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
	logLaunchStabilitySnapshot(session, "pre-release", nil, false)
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
	local course = session.ResolvedCourse
	root.AssemblyAngularVelocity = Vector3.zero
	root.AssemblyLinearVelocity = withMinimumForwardSpeed(course, currentVelocity, RUN.InitialPushSpeed)
	local releaseLongitudinal = forwardCoordinate(course, root.Position)
	session.DescentStartedAt = os.clock()
	session.ReleaseLongitudinal = releaseLongitudinal
	logLaunchStabilitySnapshot(session, "post-release", nil, false)
	if RESULT.LifecycleDiagnosticsEnabled then
		print(
			string.format(
				"[Frostline][Run] %s Released initialSpeed=%.1f",
				runLabel(session),
				forwardSpeed(course, root.AssemblyLinearVelocity)
			)
		)
	end

	RunService.Heartbeat:Wait()
	local releaseVerified, releaseVerificationReason = verifyReleaseAfterHeartbeat(
		session,
		runId,
		releaseLongitudinal
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
	lifecycleLog(session, "release-validation", "stage=post valid=true reason=ok")

	session.ReleaseInProgress = false
	resetStallObservation(session)
	session.MaximumDescentProgress = math.max(
		0,
		forwardCoordinate(course, root.Position) - releaseLongitudinal
	)
	session.TuckActivationReady = true
	local activateQueuedTuck = session.TuckQueued and session.TuckIntentHeld
	session.TuckQueued = false
	setTuckActive(session, activateQueuedTuck)
	updateAntiStall(session, runId)
	if session.TuckQueueScheduled then
		if RESULT.LifecycleDiagnosticsEnabled then
			print(
				string.format(
					"[Frostline][Run] %s Queued Tuck acceptance accepted=%s held=%s",
					runLabel(session),
					tostring(session.Tucking),
					tostring(session.TuckIntentHeld)
				)
			)
		end
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

local function createFrostTrailSteeringForce(root: Part, attachment: Attachment): VectorForce
	local steeringForce = Instance.new("VectorForce")
	steeringForce.Name = "FrostTrailSteeringForce"
	steeringForce.Attachment0 = attachment
	steeringForce.RelativeTo = Enum.ActuatorRelativeTo.World
	steeringForce.ApplyAtCenterOfMass = true
	steeringForce.Force = Vector3.zero
	steeringForce.Enabled = false
	steeringForce.Parent = root
	return steeringForce
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

local function validateResolvedCourseLive(course: ResolvedCourse): (boolean, string)
	local definition = course.Definition
	local courses = resolvedCourses
	if not courses or not table.isfrozen(courses) or courses[course.CourseId] ~= course then
		return false, "resolved course identity changed"
	elseif not table.isfrozen(course) then
		return false, "resolved course is not frozen"
	elseif not table.isfrozen(definition) then
		return false, "course definition is not frozen"
	elseif CourseRegistry.getDefinition(course.CourseId) ~= definition then
		return false, "course definition identity changed"
	end

	local world = course.World
	if not world:IsA("Model")
		or world.Name ~= definition.WorldModelName
		or world.Parent ~= Workspace
	then
		return false, "world reference is stale"
	end

	local geometry = course.Geometry
	if not geometry:IsA("Folder")
		or geometry.Name ~= definition.GeometryFolderName
		or geometry.Parent ~= world
		or not geometry:IsDescendantOf(world)
	then
		return false, "geometry reference is stale"
	end

	local markers = course.Markers
	if not markers:IsA("Folder")
		or markers.Name ~= definition.MarkersFolderName
		or markers.Parent ~= world
		or not markers:IsDescendantOf(world)
	then
		return false, "markers reference is stale"
	end

	local activeSleds = course.ActiveSleds
	if not activeSleds:IsA("Folder")
		or activeSleds.Name ~= definition.ActiveSledsFolderName
		or activeSleds.Parent ~= world
		or not activeSleds:IsDescendantOf(world)
	then
		return false, "active sleds reference is stale"
	end

	local startTrigger = course.StartTrigger
	if not startTrigger:IsA("BasePart")
		or startTrigger.Name ~= definition.StartTriggerName
		or startTrigger.Parent ~= markers
		or not startTrigger:IsDescendantOf(world)
	then
		return false, "start trigger reference is stale"
	end

	local summitPlatform = course.SummitPlatform
	if not summitPlatform:IsA("BasePart")
		or summitPlatform.Name ~= definition.SummitPlatformName
		or summitPlatform.Parent ~= geometry
		or not summitPlatform:IsDescendantOf(world)
	then
		return false, "summit platform reference is stale"
	end

	local launchEdge = course.LaunchEdge
	if not launchEdge:IsA("BasePart")
		or launchEdge.Name ~= definition.LaunchEdgeName
		or launchEdge.Parent ~= markers
		or not launchEdge:IsDescendantOf(world)
	then
		return false, "launch edge reference is stale"
	end

	local landingSurfaces = course.LandingSurfaces
	if not landingSurfaces:IsA("Folder")
		or landingSurfaces.Name ~= definition.LandingSurfacesName
		or landingSurfaces.Parent ~= geometry
		or not landingSurfaces:IsDescendantOf(world)
		or landingSurfaces:FindFirstChildWhichIsA("BasePart", false) == nil
	then
		return false, "landing surfaces reference is stale"
	end

	local playerSpawn = course.PlayerSpawn
	if not playerSpawn:IsA("SpawnLocation")
		or playerSpawn.Name ~= definition.PlayerSpawnName
		or playerSpawn.Parent ~= geometry
		or not playerSpawn:IsDescendantOf(world)
	then
		return false, "player spawn reference is stale"
	end
	local spawnLook = playerSpawn.CFrame.LookVector
	local horizontalSpawnLook = Vector3.new(spawnLook.X, 0, spawnLook.Z)
	if horizontalSpawnLook.Magnitude <= COURSE_BASIS_EPSILON
		or horizontalSpawnLook.Unit:Dot(course.ForwardDirection) < 1 - COURSE_BASIS_EPSILON
	then
		return false, "player spawn facing changed"
	end

	if course.CourseId == CLASSIC_COURSE_ID then
		if definition.ActivationMode ~= "LiveDefault"
			or definition.RouteMode ~= "FixedBasis"
			or definition.RouteData ~= nil
			or course.ExactLandingSurfaces ~= nil
			or world:GetAttribute("CourseId") ~= CLASSIC_COURSE_ID
		then
			return false, "Classic routing identity changed"
		end
	elseif course.CourseId == FROST_TRAIL_COURSE_ID then
		local markedLandingPart = landingSurfaces:FindFirstChild(FROST_LAKE_MARKED_PART_NAME)
		local runoffLandingPart = landingSurfaces:FindFirstChild(FROST_LAKE_RUNOFF_PART_NAME)
		local exactLandingSurfaces = course.ExactLandingSurfaces
		if definition.ActivationMode ~= "StudioControlledTest"
			or definition.RouteMode ~= "MonotonicZCenterline"
			or definition.RouteData ~= FrostTrailConfig.RouteData
			or world:GetAttribute("CourseId") ~= FROST_TRAIL_COURSE_ID
			or world:GetAttribute("DisplayName") ~= FrostTrailConfig.DisplayName
			or world:GetAttribute("WorldVersion") ~= FrostTrailConfig.WorldVersion
			or world:GetAttribute("StaticFoundationOnly") ~= false
			or world:GetAttribute("Playable") ~= false
			or world:GetAttribute("ActivationMode") ~= "StudioControlledTest"
			or world:GetAttribute("ForwardX") ~= FrostTrailConfig.ForwardDirection.X
			or world:GetAttribute("ForwardY") ~= FrostTrailConfig.ForwardDirection.Y
			or world:GetAttribute("ForwardZ") ~= FrostTrailConfig.ForwardDirection.Z
			or world:GetAttribute("OriginX") ~= FrostTrailConfig.WorldOrigin.X
			or world:GetAttribute("OriginY") ~= FrostTrailConfig.WorldOrigin.Y
			or world:GetAttribute("OriginZ") ~= FrostTrailConfig.WorldOrigin.Z
			or world:GetAttribute("TrackStartLongitudinal") ~= FrostTrailConfig.PathPoints[1].Z
			or world:GetAttribute("LaunchLongitudinal") ~= 6350
			or world:GetAttribute("AuthoredPathLengthStuds") ~= FrostTrailConfig.RouteData.AuthoredPathLengthStuds
			or world:GetAttribute("BasePartCount") ~= 447
			or launchEdge.Anchored ~= true
			or launchEdge.Transparency ~= 1
			or launchEdge.CanCollide ~= false
			or launchEdge.CanTouch ~= true
			or launchEdge.CanQuery ~= false
			or launchEdge.CastShadow ~= false
			or playerSpawn.Enabled ~= false
			or not markedLandingPart
			or not markedLandingPart:IsA("BasePart")
			or markedLandingPart.Parent ~= landingSurfaces
			or not runoffLandingPart
			or not runoffLandingPart:IsA("BasePart")
			or runoffLandingPart.Parent ~= landingSurfaces
			or exactLandingSurfaces == nil
			or not table.isfrozen(exactLandingSurfaces)
			or exactLandingSurfaces[markedLandingPart] ~= true
			or exactLandingSurfaces[runoffLandingPart] ~= true
		then
			return false, "Frost routing or lifecycle identity changed"
		end
		local validatedLandingSurfaces = exactLandingSurfaces :: { [BasePart]: boolean }

		local directLakeParts = 0
		for _, child in ipairs(landingSurfaces:GetChildren()) do
			if child:IsA("BasePart") then
				directLakeParts += 1
				if validatedLandingSurfaces[child] ~= true
					or not child.Anchored
					or not child.CanCollide
					or not child.CanTouch
					or not child.CanQuery
				then
					return false, "Frost landing touch lifecycle changed"
				end
			end
		end
		if directLakeParts ~= 2 then
			return false, "Frost landing surface identity changed"
		end
	else
		return false, "resolved CourseId is not allowlisted"
	end

	return true, "ok"
end

local function isPreparedRoutingCurrent(
	player: Player,
	state: PreparedCourseState,
	generation: number,
	character: Model,
	course: ResolvedCourse
): boolean
	local courses = resolvedCourses
	return started
		and player.Parent == Players
		and preparedCourses[player] == state
		and state.Generation == generation
		and state.CourseId == course.CourseId
		and state.Routing
		and player.Character == character
		and character.Parent ~= nil
		and next(sessions) == nil
		and next(pendingReplays) == nil
		and courses ~= nil
		and courses[course.CourseId] == course
end

local function teleportPreparedCharacter(
	player: Player,
	state: PreparedCourseState,
	generation: number,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	course: ResolvedCourse
): boolean
	local targetCFrame = course.PlayerSpawn.CFrame + Vector3.new(0, 4, 0)
	local originalAnchored = root.Anchored
	local controlled = false

	local function releaseRoot()
		if not controlled then
			return
		end
		controlled = false
		if root.Parent and root:IsDescendantOf(character) then
			pcall(function()
				root.Anchored = originalAnchored
			end)
			if not originalAnchored then
				pcall(function()
					root:SetNetworkOwnershipAuto()
				end)
			end
		end
	end

	local function subjectIsCurrent(): boolean
		return isPreparedRoutingCurrent(player, state, generation, character, course)
			and humanoid.Parent == character
			and humanoid.Health > 0
			and root.Parent ~= nil
			and root:IsDescendantOf(character)
	end

	local callSucceeded, verified = pcall(function(): boolean
		if not subjectIsCurrent() then
			return false
		end
		controlled = true
		if root.Anchored then
			root.Anchored = false
		end
		local ownershipSucceeded = pcall(function()
			root:SetNetworkOwner(nil)
		end)
		if not ownershipSucceeded or not subjectIsCurrent() then
			return false
		end

		root.Anchored = true
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		character:PivotTo(targetCFrame)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		RunService.PostSimulation:Wait()
		if not subjectIsCurrent() then
			return false
		end
		RunService.PostSimulation:Wait()
		if not subjectIsCurrent() then
			return false
		end

		root.Anchored = originalAnchored
		if not originalAnchored then
			root:SetNetworkOwnershipAuto()
		end
		controlled = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)

		RunService.Heartbeat:Wait()
		if not subjectIsCurrent() then
			return false
		end
		return (root.Position - targetCFrame.Position).Magnitude <= RESULT.TeleportToleranceStuds
	end)

	releaseRoot()
	return callSucceeded and verified == true
end

local function routePreparedCharacter(player: Player, state: PreparedCourseState, character: Model)
	if not RunService:IsStudio() or state.Routing then
		return
	end

	local generation = state.Generation
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootInstance = character:FindFirstChild("HumanoidRootPart")
	if not humanoid then
		local waitedHumanoid = character:WaitForChild("Humanoid", RESULT.TeleportCharacterReadyTimeoutSeconds)
		if waitedHumanoid and waitedHumanoid:IsA("Humanoid") then
			humanoid = waitedHumanoid
		end
	end
	if not rootInstance then
		rootInstance = character:WaitForChild("HumanoidRootPart", RESULT.TeleportCharacterReadyTimeoutSeconds)
	end
	if preparedCourses[player] ~= state
		or state.Generation ~= generation
		or player.Character ~= character
	then
		return
	end
	if not humanoid
		or humanoid.Health <= 0
		or not rootInstance
		or not rootInstance:IsA("BasePart")
		or sessions[player] ~= nil
		or pendingReplays[player] ~= nil
		or storeOperations[player] ~= nil
	then
		return
	end

	local courses = resolvedCourses
	local course = if courses then courses[state.CourseId] else nil
	if course == nil then
		return
	end
	local courseValid = validateResolvedCourseLive(course)
	if not courseValid then
		return
	end

	state.Routing = true
	local routeGeneration = state.Generation
	teleportPreparedCharacter(player, state, routeGeneration, character, humanoid, rootInstance, course)
	if preparedCourses[player] == state and state.Generation == routeGeneration then
		state.Routing = false
	end
end

local function onPreparedCharacterAdded(player: Player, state: PreparedCourseState, character: Model)
	if preparedCourses[player] ~= state then
		return
	end
	if not state.SawInitialCharacter then
		state.SawInitialCharacter = true
		return
	end

	routePreparedCharacter(player, state, character)
end

local function initializePreparedPlayer(player: Player)
	if player.Parent ~= Players or preparedCourses[player] ~= nil then
		return
	end

	local state: PreparedCourseState = {
		CourseId = CLASSIC_COURSE_ID,
		Generation = 0,
		Routing = false,
		SawInitialCharacter = player.Character ~= nil,
		CharacterConnection = nil,
	}
	preparedCourses[player] = state
	player:SetAttribute(PRESENTATION_COURSE_ATTRIBUTE, CLASSIC_COURSE_ID)
	if RunService:IsStudio() then
		state.CharacterConnection = player.CharacterAdded:Connect(function(character: Model)
			onPreparedCharacterAdded(player, state, character)
		end)
	end
end

local function clearPreparedPlayer(player: Player)
	local state = preparedCourses[player]
	if state == nil then
		return
	end
	state.Generation += 1
	state.Routing = false
	local connection = state.CharacterConnection
	state.CharacterConnection = nil
	if connection then
		connection:Disconnect()
	end
	preparedCourses[player] = nil
end

local function beginRun(player: Player, course: ResolvedCourse, trustedStart: boolean)
	if player.Parent ~= Players
		or next(sessions) ~= nil
		or hasPreparedCourseRouting()
		or pendingReplays[player]
		or storeOperations[player]
		or PlayerDataService.hasUnresolvedStoreSave(player)
	then
		return
	end
	local preparedState = preparedCourses[player]
	if preparedState == nil or preparedState.Routing then
		return
	elseif course.CourseId == FROST_TRAIL_COURSE_ID
		and (not RunService:IsStudio() or preparedState.CourseId ~= FROST_TRAIL_COURSE_ID)
	then
		return
	end
	local courseValid, courseReason = validateResolvedCourseLive(course)
	if not courseValid then
		warn(
			string.format(
				"[Frostline][Course] CourseId=%s refusing run for player=%s reason=%s",
				course.CourseId,
				player.Name,
				courseReason
			)
		)
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
	if not trustedStart and (rootPart.Position - course.StartTrigger.Position).Magnitude > MAX_START_DISTANCE then
		return
	end
	local equippedSledId = PlayerDataService.getEquippedSledId(player)
	if not setPreparedCourse(player, course.CourseId) then
		return
	end
	disableStartPrompts()

	local triggerCenter = course.StartTrigger.Position
	local sled = SledFactory.create(
		CFrame.lookAt(triggerCenter, triggerCenter + course.ForwardDirection),
		equippedSledId
	)
	local summitTopY = course.SummitPlatform.Position.Y + course.SummitPlatform.Size.Y * 0.5
	local startY = summitTopY + sled.Root.Size.Y * 0.5 + START_BOTTOM_CLEARANCE
	local startPosition = triggerCenter + Vector3.yAxis * (startY - triggerCenter.Y)
	local spawnCFrame = CFrame.lookAt(startPosition, startPosition + course.ForwardDirection)
	sled.Model:PivotTo(spawnCFrame)
	sled.Model.Parent = course.ActiveSleds

	latestRunId += 1
	local runId = latestRunId
	local tuckAttachment, tuckForce, antiStallForce, stabilityTorque = createSledActuators(sled.Root)
	local steeringProfile: SteeringTuning? = if course.CourseId == FROST_TRAIL_COURSE_ID
		then FrostTrailConfig.Steering
		else nil
	local steeringForce = if steeringProfile
		then createFrostTrailSteeringForce(sled.Root, tuckAttachment)
		else nil
	local steeringRateRefillAt = os.clock()
	local groundRaycastParams = RaycastParams.new()
	groundRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	groundRaycastParams.FilterDescendantsInstances = { sled.Model, character }
	groundRaycastParams.IgnoreWater = true
	groundRaycastParams.RespectCanCollide = true
	local session: Session = {
		RunId = runId,
		CourseId = course.CourseId,
		ResolvedCourse = course,
		Player = player,
		Character = character,
		Humanoid = humanoidInstance,
		Sled = sled,
		TuckAttachment = tuckAttachment,
		TuckForce = tuckForce,
		AntiStallForce = antiStallForce,
		StabilityTorque = stabilityTorque,
		SteeringForce = steeringForce,
		SteeringProfile = steeringProfile,
		SteeringTarget = 0,
		SteeringApplied = 0,
		LastSteeringSeenSequence = 0,
		LastSteeringAcceptedAt = nil,
		SteeringRateTokens = FrostTrailConfig.Steering.ServerRateBucketCapacity,
		SteeringRateRefillAt = steeringRateRefillAt,
		GroundRaycastParams = groundRaycastParams,
		Phase = RunPhase.Idle,
		CountdownValue = nil,
		OriginalMassless = {},
		Connections = {},
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
		ReleaseLongitudinal = nil,
		StallObservationStartedAt = nil,
		StallObservationStartLongitudinal = nil,
		StallObservationKind = nil,
		StallRecoveryUsed = false,
		LastStallRejectionAt = -math.huge,
		EnteredAirborne = false,
		rampExitRollGuardConsumed = false,
		rampExitRollGuardApplied = false,
		rampExitRollGuardSkipReason = nil,
		LastAirborneContactSnapshot = nil,
		LandingContactDiagnosticsConsumed = nil,
		TouchedFrozenLake = false,
		SeatSeparatedAfterAirborne = false,
		MissedLaunchConfirmed = false,
		Outcome = nil,
		ResultOutcome = nil,
		MaximumDescentProgress = 0,
		StopConfirmed = false,
		TuckUsed = false,
		LaunchHorizontalSpeed = nil,
		TouchdownHorizontalSpeed = nil,
		MaximumDistanceMeters = 0,
		FinalStopDistanceMeters = nil,
		FinalUprightDot = nil,
		ResultFinalized = false,
		ResultPayload = nil,
		ResultActionAccepted = false,
		ReplayRequested = false,
		TelemetryLogged = false,
	}
	sessions[player] = session
	if RESULT.LifecycleDiagnosticsEnabled then
		lifecycleLog(session, "run-created", string.format("source=%s", if trustedStart then "replay" else "prompt"))
	end

	if not transitionTo(session, RunPhase.Countdown) then
		requestCleanup(session, runId, "could not start countdown", true)
		return
	end

	session.OriginalMassless = makeCharacterMassless(character)
	connectRunEvents(session, runId)

	if not seatPlayer(session, runId) then
		requestCleanup(session, runId, "could not seat player", true)
		return
	end

	task.spawn(runCountdown, session, runId)
end

local function startRunSafely(player: Player, courseId: CourseId, trustedStart: boolean)
	local courses = resolvedCourses
	local definition = CourseRegistry.getDefinition(courseId)
	local course = if courses and definition then courses[courseId] else nil
	if course == nil or course.Definition ~= definition then
		warn(
			string.format(
				"[Frostline][Course] CourseId=%s refusing run for player=%s reason=course unavailable",
				courseId,
				player.Name
			)
		)
		refreshStartPrompts()
		return
	end

	local ok, message = pcall(beginRun, player, course, trustedStart)
	if ok then
		if not sessions[player] then
			refreshStartPrompts()
		end
		return
	end

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
		refreshStartPrompts()
	end
end

local function validateSteeringProfile(profile: any): (boolean, string)
	if typeof(profile) ~= "table" then
		return false, "Frost steering profile is unavailable"
	elseif profile ~= FrostTrailConfig.Steering
		or not table.isfrozen(FrostTrailConfig)
		or not table.isfrozen(profile)
	then
		return false, "Frost steering profile identity or freeze is invalid"
	elseif profile.Enabled ~= true then
		return false, "Frost steering is not enabled"
	elseif typeof(profile.InputQuantizationSteps) ~= "number"
		or typeof(profile.MaximumSequence) ~= "number"
		or typeof(profile.MaximumSequenceJump) ~= "number"
		or typeof(profile.ServerRateTokensPerSecond) ~= "number"
		or typeof(profile.ServerRateBucketCapacity) ~= "number"
		or typeof(profile.ServerIntentTimeoutSeconds) ~= "number"
		or typeof(profile.AppliedInputRisePerSecond) ~= "number"
		or typeof(profile.AppliedInputReleasePerSecond) ~= "number"
		or typeof(profile.MinimumLateralSpeed) ~= "number"
		or typeof(profile.LateralSpeedBase) ~= "number"
		or typeof(profile.LateralSpeedPerForwardSpeed) ~= "number"
		or typeof(profile.MaximumLateralSpeed) ~= "number"
		or typeof(profile.LateralVelocityResponseSeconds) ~= "number"
		or typeof(profile.MaximumLateralAcceleration) ~= "number"
		or typeof(profile.GroundRayDistance) ~= "number"
		or typeof(profile.AppliedInputSnapEpsilon) ~= "number"
	then
		return false, "Frost steering profile contains a non-numeric value"
	elseif not isFinitePositiveNumber(profile.InputQuantizationSteps)
		or not isFinitePositiveNumber(profile.MaximumSequence)
		or not isFinitePositiveNumber(profile.MaximumSequenceJump)
		or not isFinitePositiveNumber(profile.ServerRateTokensPerSecond)
		or not isFinitePositiveNumber(profile.ServerRateBucketCapacity)
		or not isFinitePositiveNumber(profile.ServerIntentTimeoutSeconds)
		or not isFinitePositiveNumber(profile.AppliedInputRisePerSecond)
		or not isFinitePositiveNumber(profile.AppliedInputReleasePerSecond)
		or not isFinitePositiveNumber(profile.MinimumLateralSpeed)
		or not isFinitePositiveNumber(profile.LateralSpeedBase)
		or not isFinitePositiveNumber(profile.LateralSpeedPerForwardSpeed)
		or not isFinitePositiveNumber(profile.MaximumLateralSpeed)
		or not isFinitePositiveNumber(profile.LateralVelocityResponseSeconds)
		or not isFinitePositiveNumber(profile.MaximumLateralAcceleration)
		or not isFinitePositiveNumber(profile.GroundRayDistance)
		or not isFinitePositiveNumber(profile.AppliedInputSnapEpsilon)
	then
		return false, "Frost steering profile contains an invalid numeric value"
	elseif profile.InputQuantizationSteps % 1 ~= 0
		or profile.MaximumSequence % 1 ~= 0
		or profile.MaximumSequenceJump % 1 ~= 0
		or profile.ServerRateBucketCapacity % 1 ~= 0
	then
		return false, "Frost steering integer fields are invalid"
	elseif profile.InputQuantizationSteps ~= 20 then
		return false, "Frost steering quantization is invalid"
	elseif profile.MaximumSequence ~= 2147483647 then
		return false, "Frost steering sequence maximum is invalid"
	elseif profile.MaximumSequenceJump > 64 then
		return false, "Frost steering sequence jump is invalid"
	elseif profile.ServerRateBucketCapacity > 8 then
		return false, "Frost steering token capacity is invalid"
	elseif profile.ServerIntentTimeoutSeconds < 0.35 or profile.ServerIntentTimeoutSeconds > 0.50 then
		return false, "Frost steering timeout is invalid"
	elseif profile.AppliedInputReleasePerSecond < profile.AppliedInputRisePerSecond then
		return false, "Frost steering release response is invalid"
	elseif profile.MinimumLateralSpeed > profile.MaximumLateralSpeed then
		return false, "Frost steering lateral speed range is invalid"
	elseif profile.MaximumLateralAcceleration > 45 then
		return false, "Frost steering acceleration limit is invalid"
	elseif profile.GroundRayDistance > RUN.StabilityRayDistance then
		return false, "Frost steering ground ray exceeds the stability ray"
	end

	return true, "ok"
end

local function validateRouteData(routeData: RouteData): (boolean, string)
	if routeData ~= FrostTrailConfig.RouteData or not table.isfrozen(routeData) then
		return false, "Frost route data identity or freeze is invalid"
	elseif not table.isfrozen(routeData.SampledCenterlinePoints)
		or #routeData.SampledCenterlinePoints ~= FROST_ROUTE_EXPECTED_SAMPLE_COUNT
	then
		return false, "Frost sampled centerline is invalid"
	elseif not table.isfrozen(routeData.GeometryPoints)
		or #routeData.GeometryPoints ~= FROST_ROUTE_EXPECTED_GEOMETRY_POINT_COUNT
	then
		return false, "Frost geometry route is invalid"
	elseif not table.isfrozen(routeData.GeometrySplitLongitudinals)
		or #routeData.GeometrySplitLongitudinals ~= FROST_ROUTE_EXPECTED_SPLIT_COUNT
	then
		return false, "Frost geometry splits are invalid"
	elseif not isFiniteNumber(routeData.AuthoredPathLengthStuds)
		or math.abs(routeData.AuthoredPathLengthStuds - FROST_ROUTE_EXPECTED_AUTHORED_LENGTH)
			> FROST_ROUTE_LENGTH_TOLERANCE
	then
		return false, "Frost authored route length is invalid"
	end

	local measuredLength = 0
	local maximumAbsoluteSlope = 0
	for index, point in ipairs(routeData.SampledCenterlinePoints) do
		if not isFiniteVector3(point) then
			return false, "Frost sampled centerline contains a non-finite point"
		end
		if index > 1 then
			local previous = routeData.SampledCenterlinePoints[index - 1]
			local chord = point - previous
			if point.Z <= previous.Z or chord.Magnitude <= COURSE_BASIS_EPSILON then
				return false, "Frost sampled centerline is not strictly monotonic"
			end
			measuredLength += chord.Magnitude
			local absoluteSlope = math.abs(chord.X / chord.Z)
			if not isFiniteNumber(absoluteSlope) then
				return false, "Frost sampled centerline slope is not finite"
			end
			maximumAbsoluteSlope = math.max(maximumAbsoluteSlope, absoluteSlope)
		end
	end
	if math.abs(measuredLength - routeData.AuthoredPathLengthStuds) > FROST_ROUTE_LENGTH_TOLERANCE then
		return false, "Frost sampled centerline length does not match its metadata"
	elseif math.abs(maximumAbsoluteSlope - FROST_ROUTE_EXPECTED_MAXIMUM_ABSOLUTE_SLOPE)
		> FROST_ROUTE_SLOPE_TOLERANCE
	then
		return false, "Frost sampled centerline maximum slope is invalid"
	end

	for index, routePoint in ipairs(routeData.GeometryPoints) do
		if not table.isfrozen(routePoint)
			or not isFiniteVector3(routePoint.LocalPosition)
			or not isFinitePositiveNumber(routePoint.TrackWidth)
			or not isFinitePositiveNumber(routePoint.ClearPlayableWidth)
			or routePoint.ClearPlayableWidth > routePoint.TrackWidth
		then
			return false, "Frost geometry route point is invalid"
		end
		if index > 1 then
			local previous = routeData.GeometryPoints[index - 1].LocalPosition
			local chord = routePoint.LocalPosition - previous
			if routePoint.LocalPosition.Z <= previous.Z or chord.Magnitude <= COURSE_BASIS_EPSILON then
				return false, "Frost geometry route is not strictly monotonic"
			end
		end
	end

	local firstSample = routeData.SampledCenterlinePoints[1]
	local lastSample = routeData.SampledCenterlinePoints[#routeData.SampledCenterlinePoints]
	local firstGeometry = routeData.GeometryPoints[1].LocalPosition
	local lastGeometry = routeData.GeometryPoints[#routeData.GeometryPoints].LocalPosition
	if firstSample ~= firstGeometry
		or lastSample ~= lastGeometry
		or firstGeometry ~= FrostTrailConfig.PathPoints[1]
		or lastGeometry ~= FrostTrailConfig.PathPoints[#FrostTrailConfig.PathPoints]
	then
		return false, "Frost route endpoints are invalid"
	end

	local previousSplit = -math.huge
	for _, splitLongitudinal in ipairs(routeData.GeometrySplitLongitudinals) do
		if not isFiniteNumber(splitLongitudinal) or splitLongitudinal <= previousSplit then
			return false, "Frost geometry splits are not strictly ordered"
		end
		previousSplit = splitLongitudinal
		local found = false
		for _, routePoint in ipairs(routeData.GeometryPoints) do
			if math.abs(routePoint.LocalPosition.Z - splitLongitudinal) <= FrostTrailConfig.ValidationEpsilon then
				found = true
				break
			end
		end
		if not found then
			return false, "Frost geometry split is absent from the route"
		end
	end

	return true, "ok"
end

local function validateDefinitionNames(definition: CourseDefinition): boolean
	return isNonEmptyString(definition.CourseId)
		and isNonEmptyString(definition.DisplayName)
		and isNonEmptyString(definition.WorldModelName)
		and isNonEmptyString(definition.GeometryFolderName)
		and isNonEmptyString(definition.MarkersFolderName)
		and isNonEmptyString(definition.ActiveSledsFolderName)
		and isNonEmptyString(definition.StartTriggerName)
		and isNonEmptyString(definition.SummitPlatformName)
		and isNonEmptyString(definition.LaunchEdgeName)
		and isNonEmptyString(definition.LandingSurfacesName)
		and isNonEmptyString(definition.PlayerSpawnName)
end

local function validateRegistry(): ({ [CourseId]: CourseDefinition }?, string)
	if not table.isfrozen(CourseRegistry) then
		return nil, "registry API is not frozen"
	elseif not table.isfrozen(CourseRegistry.Definitions) then
		return nil, "definitions dictionary is not frozen"
	end

	local definitionCount = 0
	for courseId, definition in CourseRegistry.Definitions do
		definitionCount += 1
		if exactCourseId(courseId) == nil then
			return nil, "definitions contain a non-allowlisted CourseId"
		elseif courseId ~= definition.CourseId then
			return nil, "definition key does not match CourseId"
		elseif not table.isfrozen(definition) then
			return nil, "course definition is not frozen"
		end
	end
	if definitionCount ~= 2 then
		return nil, "definitions must contain exactly two courses"
	end

	if CourseRegistry.DefaultCourseId ~= CLASSIC_COURSE_ID then
		return nil, "default CourseId is not FrozenLakeV2"
	elseif CourseRegistry.DefaultCourseId ~= GameConfig.Leaderboard.CourseId then
		return nil, "default CourseId does not match leaderboard CourseId"
	end

	local classicDefinition = CourseRegistry.getDefinition(CLASSIC_COURSE_ID)
	local frostDefinition = CourseRegistry.getDefinition(FROST_TRAIL_COURSE_ID)
	if classicDefinition == nil
		or frostDefinition == nil
		or CourseRegistry.Definitions[CLASSIC_COURSE_ID] ~= classicDefinition
		or CourseRegistry.Definitions[FROST_TRAIL_COURSE_ID] ~= frostDefinition
	then
		return nil, "allowlisted course definitions are unavailable"
	elseif CourseRegistry.getDefinition("UnknownCourse") ~= nil
		or CourseRegistry.getDefinition("frozenlakev2") ~= nil
		or CourseRegistry.getDefinition("FROST TRAIL") ~= nil
		or CourseRegistry.getDefinition("1") ~= nil
	then
		return nil, "registry accepted a non-exact CourseId"
	end

	if classicDefinition.ActivationMode ~= "LiveDefault"
		or classicDefinition.RouteMode ~= "FixedBasis"
		or classicDefinition.RouteData ~= nil
		or not validateDefinitionNames(classicDefinition)
	then
		return nil, "Classic routing discriminators are invalid"
	end

	return CourseRegistry.Definitions, "ok"
end

local function validateFrostDefinition(definition: CourseDefinition): (boolean, string)
	local frostRouteData = definition.RouteData
	if not table.isfrozen(FrostTrailConfig)
		or not table.isfrozen(FrostTrailConfig.PathPoints)
		or not validateDefinitionNames(definition)
		or definition.ActivationMode ~= "StudioControlledTest"
		or definition.RouteMode ~= "MonotonicZCenterline"
		or frostRouteData == nil
		or definition.CourseId ~= FrostTrailConfig.CourseId
		or definition.DisplayName ~= FrostTrailConfig.DisplayName
		or definition.WorldModelName ~= FrostTrailConfig.WorldModelName
		or definition.CoordinateOrigin ~= FrostTrailConfig.WorldOrigin
		or definition.ForwardDirection ~= FrostTrailConfig.ForwardDirection
		or definition.TrackWidth ~= FrostTrailConfig.TrackWidth
		or definition.StudsPerMeter ~= FrostTrailConfig.StudsPerMeter
		or definition.RampFreedomLongitudinal ~= FrostTrailConfig.RampFreedomLongitudinal
		or definition.LandingFieldDistanceMeters ~= FrostTrailConfig.LandingFieldDistanceMeters
		or definition.MaximumRunDurationSeconds ~= FrostTrailConfig.MaximumRunDurationSeconds
		or definition.SafetyMaximumLateralDistance ~= FrostTrailConfig.SafetyMaximumLateralDistance
		or definition.SafetyMinimumWorldY ~= FrostTrailConfig.SafetyMinimumWorldY
		or FrostTrailConfig.StaticFoundationOnly ~= false
		or FrostTrailConfig.Playable ~= false
		or FrostTrailConfig.ActivationMode ~= "StudioControlledTest"
	then
		return false, "Frost definition or lifecycle metadata is invalid"
	end
	local steeringValid, steeringReason = validateSteeringProfile(FrostTrailConfig.Steering)
	if not steeringValid then
		return false, steeringReason
	end

	return validateRouteData(frostRouteData)
end

local function resolveCourseDefinition(definition: CourseDefinition): (ResolvedCourse?, string)
	if definition.CourseId == FROST_TRAIL_COURSE_ID then
		local frostDefinitionValid, frostDefinitionReason = validateFrostDefinition(definition)
		if not frostDefinitionValid then
			return nil, frostDefinitionReason
		end
	elseif definition.CourseId ~= CLASSIC_COURSE_ID or not validateDefinitionNames(definition) then
		return nil, "course definition identity is invalid"
	end

	local coordinateOrigin = definition.CoordinateOrigin
	local configuredForward = definition.ForwardDirection
	if not isFiniteVector3(coordinateOrigin) then
		return nil, "CoordinateOrigin is not finite"
	elseif not isFiniteVector3(configuredForward) then
		return nil, "ForwardDirection is not finite"
	elseif math.abs(configuredForward.Y) > COURSE_BASIS_EPSILON then
		return nil, "ForwardDirection is not horizontal"
	elseif configuredForward.Magnitude <= COURSE_BASIS_EPSILON then
		return nil, "ForwardDirection is zero"
	elseif math.abs(configuredForward.Magnitude - 1) > COURSE_BASIS_EPSILON then
		return nil, "ForwardDirection is not unit length"
	end

	local forwardDirection = configuredForward.Unit
	local rightCandidate = forwardDirection:Cross(Vector3.yAxis)
	if not isFiniteVector3(rightCandidate) or rightCandidate.Magnitude <= COURSE_BASIS_EPSILON then
		return nil, "RightDirection could not be derived"
	end
	local rightDirection = rightCandidate.Unit
	local basisForward = Vector3.yAxis:Cross(rightDirection)
	if not isFiniteVector3(rightDirection)
		or math.abs(rightDirection.Y) > COURSE_BASIS_EPSILON
		or math.abs(rightDirection.Magnitude - 1) > COURSE_BASIS_EPSILON
		or math.abs(forwardDirection:Dot(rightDirection)) > COURSE_BASIS_EPSILON
		or basisForward.Magnitude <= COURSE_BASIS_EPSILON
		or basisForward.Unit:Dot(forwardDirection) < 1 - COURSE_BASIS_EPSILON
	then
		return nil, "course basis is invalid"
	end

	if not isFinitePositiveNumber(definition.TrackWidth) then
		return nil, "TrackWidth is not finite and positive"
	elseif not isFinitePositiveNumber(definition.StudsPerMeter) then
		return nil, "StudsPerMeter is not finite and positive"
	elseif not isFiniteNumber(definition.RampFreedomLongitudinal) then
		return nil, "RampFreedomLongitudinal is not finite"
	elseif not isFinitePositiveNumber(definition.LandingFieldDistanceMeters) then
		return nil, "LandingFieldDistanceMeters is not finite and positive"
	elseif not isFinitePositiveNumber(definition.MaximumRunDurationSeconds) then
		return nil, "MaximumRunDurationSeconds is not finite and positive"
	elseif not isFinitePositiveNumber(definition.SafetyMaximumLateralDistance) then
		return nil, "SafetyMaximumLateralDistance is not finite and positive"
	elseif not isFiniteNumber(definition.SafetyMinimumWorldY) then
		return nil, "SafetyMinimumWorldY is not finite"
	end

	local worldInstance = Workspace:FindFirstChild(definition.WorldModelName)
	if not worldInstance or not worldInstance:IsA("Model") or worldInstance.Parent ~= Workspace then
		return nil, "world Model is unavailable"
	end
	local world = worldInstance

	local geometryInstance = world:FindFirstChild(definition.GeometryFolderName)
	local markersInstance = world:FindFirstChild(definition.MarkersFolderName)
	if not geometryInstance
		or not geometryInstance:IsA("Folder")
		or geometryInstance.Parent ~= world
		or not markersInstance
		or not markersInstance:IsA("Folder")
		or markersInstance.Parent ~= world
	then
		return nil, "course folders are unavailable"
	end
	local geometry = geometryInstance
	local markers = markersInstance

	local startTriggerInstance = markers:FindFirstChild(definition.StartTriggerName)
	local summitPlatformInstance = geometry:FindFirstChild(definition.SummitPlatformName)
	local launchEdgeInstance = markers:FindFirstChild(definition.LaunchEdgeName)
	local landingSurfacesInstance = geometry:FindFirstChild(definition.LandingSurfacesName)
	local playerSpawnInstance = geometry:FindFirstChild(definition.PlayerSpawnName)
	if not startTriggerInstance
		or not startTriggerInstance:IsA("BasePart")
		or startTriggerInstance.Parent ~= markers
		or not summitPlatformInstance
		or not summitPlatformInstance:IsA("BasePart")
		or summitPlatformInstance.Parent ~= geometry
		or not launchEdgeInstance
		or not launchEdgeInstance:IsA("BasePart")
		or launchEdgeInstance.Parent ~= markers
		or not landingSurfacesInstance
		or not landingSurfacesInstance:IsA("Folder")
		or landingSurfacesInstance.Parent ~= geometry
		or not playerSpawnInstance
		or not playerSpawnInstance:IsA("SpawnLocation")
		or playerSpawnInstance.Parent ~= geometry
	then
		return nil, "required course Instances are unavailable"
	end
	local startTrigger = startTriggerInstance
	local summitPlatform = summitPlatformInstance
	local launchEdge = launchEdgeInstance
	local landingSurfaces = landingSurfacesInstance
	local playerSpawn = playerSpawnInstance
	local exactLandingSurfaces: { [BasePart]: boolean }? = nil

	if not geometry:IsDescendantOf(world)
		or not markers:IsDescendantOf(world)
		or not startTrigger:IsDescendantOf(world)
		or not summitPlatform:IsDescendantOf(world)
		or not launchEdge:IsDescendantOf(world)
		or not landingSurfaces:IsDescendantOf(world)
		or not playerSpawn:IsDescendantOf(world)
	then
		return nil, "course Instances do not share the resolved world"
	elseif landingSurfaces:FindFirstChildWhichIsA("BasePart", false) == nil then
		return nil, "landing surfaces contain no direct BasePart"
	end
	local spawnLook = playerSpawn.CFrame.LookVector
	local horizontalSpawnLook = Vector3.new(spawnLook.X, 0, spawnLook.Z)
	if horizontalSpawnLook.Magnitude <= COURSE_BASIS_EPSILON
		or horizontalSpawnLook.Unit:Dot(forwardDirection) < 1 - COURSE_BASIS_EPSILON
	then
		return nil, "PlayerSpawn does not face the course"
	end

	if definition.CourseId == FROST_TRAIL_COURSE_ID then
		local markedLandingInstance = landingSurfaces:FindFirstChild(FROST_LAKE_MARKED_PART_NAME)
		local runoffLandingInstance = landingSurfaces:FindFirstChild(FROST_LAKE_RUNOFF_PART_NAME)
		if not markedLandingInstance
			or not markedLandingInstance:IsA("BasePart")
			or markedLandingInstance.Parent ~= landingSurfaces
			or not runoffLandingInstance
			or not runoffLandingInstance:IsA("BasePart")
			or runoffLandingInstance.Parent ~= landingSurfaces
		then
			return nil, "Frost landing surface identities are invalid"
		end
		local markedLandingPart = markedLandingInstance :: BasePart
		local runoffLandingPart = runoffLandingInstance :: BasePart
		local landingSurfaceSet: { [BasePart]: boolean } = {
			[markedLandingPart] = true,
			[runoffLandingPart] = true,
		}
		table.freeze(landingSurfaceSet)
		exactLandingSurfaces = landingSurfaceSet

		local frostPartCount = 0
		for _, descendant in ipairs(world:GetDescendants()) do
			if descendant:IsA("BasePart") then
				frostPartCount += 1
			end
		end
		local directLakeParts = 0
		for _, child in ipairs(landingSurfaces:GetChildren()) do
			if child:IsA("BasePart") then
				directLakeParts += 1
				if landingSurfaceSet[child] ~= true
					or not child.Anchored
					or not child.CanCollide
					or not child.CanTouch
					or not child.CanQuery
				then
					return nil, "Frost landing surface touch lifecycle is invalid"
				end
			end
		end
		if world:GetAttribute("CourseId") ~= FrostTrailConfig.CourseId
			or world:GetAttribute("DisplayName") ~= FrostTrailConfig.DisplayName
			or world:GetAttribute("WorldVersion") ~= FrostTrailConfig.WorldVersion
			or world:GetAttribute("StaticFoundationOnly") ~= false
			or world:GetAttribute("Playable") ~= false
			or world:GetAttribute("ActivationMode") ~= "StudioControlledTest"
			or world:GetAttribute("ForwardX") ~= FrostTrailConfig.ForwardDirection.X
			or world:GetAttribute("ForwardY") ~= FrostTrailConfig.ForwardDirection.Y
			or world:GetAttribute("ForwardZ") ~= FrostTrailConfig.ForwardDirection.Z
			or world:GetAttribute("OriginX") ~= FrostTrailConfig.WorldOrigin.X
			or world:GetAttribute("OriginY") ~= FrostTrailConfig.WorldOrigin.Y
			or world:GetAttribute("OriginZ") ~= FrostTrailConfig.WorldOrigin.Z
			or world:GetAttribute("TrackStartLongitudinal") ~= FrostTrailConfig.PathPoints[1].Z
			or world:GetAttribute("BasePartCount") ~= 447
			or frostPartCount ~= 447
			or world:GetAttribute("LaunchLongitudinal") ~= 6350
			or world:GetAttribute("AuthoredPathLengthStuds") ~= FrostTrailConfig.RouteData.AuthoredPathLengthStuds
			or launchEdge.Anchored ~= true
			or launchEdge.Transparency ~= 1
			or launchEdge.CanCollide ~= false
			or launchEdge.CanTouch ~= true
			or launchEdge.CanQuery ~= false
			or launchEdge.CastShadow ~= false
			or directLakeParts ~= 2
			or playerSpawn.Enabled ~= false
		then
			return nil, "Frost world identity or lifecycle attributes are invalid"
		end
	end

	local launchLongitudinal = (launchEdge.Position - coordinateOrigin):Dot(forwardDirection)
	local startLongitudinal = (startTrigger.Position - coordinateOrigin):Dot(forwardDirection)
	if not isFiniteNumber(launchLongitudinal) or not isFiniteNumber(startLongitudinal) then
		return nil, "course planes are not finite"
	elseif startLongitudinal >= launchLongitudinal then
		return nil, "StartTrigger must be before LaunchEdge"
	elseif definition.RampFreedomLongitudinal >= launchLongitudinal then
		return nil, "ramp freedom must be before LaunchEdge"
	elseif definition.CourseId == FROST_TRAIL_COURSE_ID and launchLongitudinal ~= 6350 then
		return nil, "Frost launch plane is invalid"
	end

	if definition.CourseId == CLASSIC_COURSE_ID then
		world:SetAttribute("CourseId", CLASSIC_COURSE_ID)
	end

	-- Reconcile ActiveSleds only after every registry, metric, basis, lifecycle,
	-- hierarchy, ancestry, and touch check above has succeeded.
	local activeSleds: Folder
	local existingSleds = world:FindFirstChild(definition.ActiveSledsFolderName)
	if existingSleds and existingSleds:IsA("Folder") then
		activeSleds = existingSleds
	else
		if existingSleds then
			existingSleds:Destroy()
		end
		activeSleds = Instance.new("Folder")
		activeSleds.Name = definition.ActiveSledsFolderName
		activeSleds.Parent = world
	end

	local resolvedCourse: ResolvedCourse = {
		Definition = definition,
		CourseId = definition.CourseId,
		World = world,
		Geometry = geometry,
		Markers = markers,
		ActiveSleds = activeSleds,
		StartTrigger = startTrigger,
		SummitPlatform = summitPlatform,
		LaunchEdge = launchEdge,
		LandingSurfaces = landingSurfaces,
		ExactLandingSurfaces = exactLandingSurfaces,
		PlayerSpawn = playerSpawn,
		CoordinateOrigin = coordinateOrigin,
		ForwardDirection = forwardDirection,
		RightDirection = rightDirection,
		LaunchLongitudinal = launchLongitudinal,
		TrackWidth = definition.TrackWidth,
		StudsPerMeter = definition.StudsPerMeter,
		RampFreedomLongitudinal = definition.RampFreedomLongitudinal,
		LandingFieldDistanceMeters = definition.LandingFieldDistanceMeters,
		MaximumRunDurationSeconds = definition.MaximumRunDurationSeconds,
		SafetyMaximumLateralDistance = definition.SafetyMaximumLateralDistance,
		SafetyMinimumWorldY = definition.SafetyMinimumWorldY,
	}
	table.freeze(resolvedCourse)
	if not table.isfrozen(resolvedCourse) then
		return nil, "resolved course is not frozen"
	end

	return resolvedCourse, "ok"
end

local function resolveCourses(): (ResolvedCourseDictionary?, string)
	local definitions, registryReason = validateRegistry()
	if not definitions then
		return nil, registryReason
	end

	local classicCourse, classicReason = resolveCourseDefinition(definitions[CLASSIC_COURSE_ID])
	if not classicCourse then
		return nil, classicReason
	end
	local courses: ResolvedCourseDictionary = {
		[CLASSIC_COURSE_ID] = classicCourse,
	}

	local frostDefinition = definitions[FROST_TRAIL_COURSE_ID]
	if Workspace:FindFirstChild("FrostTrailWorld") ~= nil then
		local succeeded, frostCourseOrError, frostReason = pcall(function(): (ResolvedCourse?, string)
			return resolveCourseDefinition(frostDefinition)
		end)
		local frostCourse = if succeeded then frostCourseOrError :: ResolvedCourse? else nil
		if frostCourse then
			courses[FROST_TRAIL_COURSE_ID] = frostCourse
		else
			warn(
				string.format(
					"[Frostline][Course] CourseId=%s unavailable reason=%s",
					FROST_TRAIL_COURSE_ID,
					if succeeded then frostReason else tostring(frostCourseOrError)
				)
			)
		end
	end

	table.freeze(courses)
	if not table.isfrozen(courses) then
		return nil, "resolved course dictionary is not frozen"
	end

	return courses, "ok"
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
	prompt.Enabled = false
	return prompt
end

local function noteQueuedTuckScheduling(session: Session, sourcePhase: Phase)
	if session.TuckQueueScheduled then
		return
	end
	session.TuckQueueScheduled = true
	if RESULT.LifecycleDiagnosticsEnabled then
		print(
			string.format(
				"[Frostline][Run] %s Queued Tuck scheduling phase=%s",
				runLabel(session),
				sourcePhase
			)
		)
	end
end

local function onSteeringIntent(player: Player, requestedRunId: any, sequenceValue: any, axisQValue: any)
	if typeof(requestedRunId) ~= "number"
		or typeof(sequenceValue) ~= "number"
		or typeof(axisQValue) ~= "number"
		or not isFiniteNumber(requestedRunId)
		or not isFiniteNumber(sequenceValue)
		or not isFiniteNumber(axisQValue)
		or requestedRunId % 1 ~= 0
		or sequenceValue % 1 ~= 0
		or axisQValue % 1 ~= 0
		or requestedRunId <= 0
		or sequenceValue < 1
		or sequenceValue > 2147483647
		or axisQValue < -20
		or axisQValue > 20
	then
		return
	end

	local session = sessions[player]
	if session == nil
		or requestedRunId ~= session.RunId
		or sessions[player] ~= session
		or session.Player ~= player
		or session.CleanupStarted
		or session.CourseId ~= FROST_TRAIL_COURSE_ID
		or not hasExactSteeringAuthorization(session)
		or (session.Phase ~= RunPhase.Countdown and session.Phase ~= RunPhase.Descent)
		or not hasExactSteeringOccupant(session)
		or session.RampFreedomEntered
	then
		return
	end

	local profile = session.SteeringProfile :: SteeringTuning
	local sequence = sequenceValue :: number
	local axisQ = axisQValue :: number
	local previousSequence = session.LastSteeringSeenSequence
	if sequence <= previousSequence or sequence - previousSequence > profile.MaximumSequenceJump then
		return
	end
	session.LastSteeringSeenSequence = sequence

	if axisQ == 0 then
		if session.SteeringTarget == 0 then
			return
		end
		session.SteeringTarget = 0
		return
	end

	local now = os.clock()
	local elapsed = math.max(0, now - session.SteeringRateRefillAt)
	local tokens = math.min(
		profile.ServerRateBucketCapacity,
		session.SteeringRateTokens + elapsed * profile.ServerRateTokensPerSecond
	)
	session.SteeringRateRefillAt = now
	if tokens < 1 then
		session.SteeringRateTokens = tokens
		return
	end

	session.SteeringRateTokens = tokens - 1
	session.SteeringTarget = axisQ / profile.InputQuantizationSteps
	session.LastSteeringAcceptedAt = now
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

local function onResultAction(player: Player, requestedRunId: any, requestedAction: any)
	if typeof(requestedRunId) ~= "number"
		or requestedRunId % 1 ~= 0
		or typeof(requestedAction) ~= "string"
		or (requestedAction ~= ResultTypes.Actions.PlayAgain
			and requestedAction ~= ResultTypes.Actions.ReturnToStart)
	then
		return
	end

	local session = sessions[player]
	if not session
		or requestedRunId ~= session.RunId
		or not isSameSession(session, requestedRunId)
	then
		return
	end

	acceptResultAction(session, requestedRunId, requestedAction :: ResultAction, "client")
end

function RunManager.prepareStudioCourse(player: Player, requestedCourseId: string): (boolean, string)
	if not started or resolvedCourses == nil then
		return false, "RunManager unavailable"
	elseif not RunService:IsStudio() then
		return false, "Studio only"
	elseif typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return false, "Player unavailable"
	end

	local courseId = exactCourseId(requestedCourseId)
	if courseId == nil then
		return false, "Unknown course"
	end
	local courses = resolvedCourses :: ResolvedCourseDictionary
	local course = courses[courseId]
	if course == nil or CourseRegistry.getDefinition(requestedCourseId) ~= course.Definition then
		return false, "Course unavailable"
	end
	local courseValid = validateResolvedCourseLive(course)
	if not courseValid then
		return false, "Course invalid"
	end

	local state = preparedCourses[player]
	if state == nil then
		return false, "Player state unavailable"
	elseif sessions[player] ~= nil then
		return false, "Run active"
	elseif pendingReplays[player] ~= nil then
		return false, "Replay pending"
	elseif next(sessions) ~= nil or next(pendingReplays) ~= nil then
		return false, "Server busy"
	elseif state.Routing then
		return false, "Course preparation active"
	elseif hasPreparedCourseRouting() then
		return false, "Server busy"
	elseif storeOperations[player] ~= nil then
		return false, "Store operation active"
	elseif PlayerDataService.hasUnresolvedStoreSave(player) then
		return false, "Store save unresolved"
	end

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local rootInstance = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not character
		or not character:IsA("Model")
		or not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootInstance
		or not rootInstance:IsA("BasePart")
		or not course.PlayerSpawn.Parent
	then
		return false, "Character unavailable"
	end

	local previousCourseId = state.CourseId
	state.Routing = true
	if not setPreparedCourse(player, courseId) then
		state.Routing = false
		return false, "Player state unavailable"
	end
	local generation = state.Generation
	local teleported = teleportPreparedCharacter(
		player,
		state,
		generation,
		character,
		humanoid,
		rootInstance,
		course
	)
	if preparedCourses[player] ~= state then
		return false, "Player unavailable"
	end
	state.Routing = false
	if not teleported then
		state.CourseId = previousCourseId
		state.Generation += 1
		player:SetAttribute(PRESENTATION_COURSE_ATTRIBUTE, previousCourseId)
		return false, "Teleport failed"
	end

	return true, "Prepared"
end

local function warnStudioCourseControlOnce(reason: string)
	if studioCourseControlWarningIssued then
		return
	end
	studioCourseControlWarningIssued = true
	warn(string.format("[Frostline][StudioControl] Bridge unavailable reason=%s", reason))
end

local function publishStudioCourseControlBridge()
	if not RunService:IsStudio() then
		return
	elseif studioCourseControlBridge ~= nil then
		return
	end

	local existing = ServerStorage:FindFirstChild(STUDIO_COURSE_CONTROL_BRIDGE_NAME, false)
	if existing ~= nil then
		warnStudioCourseControlOnce("name already in use")
		return
	end

	local runningPrepareStudioCourse = RunManager.prepareStudioCourse
	local bridge = Instance.new("BindableFunction")
	bridge.Name = STUDIO_COURSE_CONTROL_BRIDGE_NAME
	bridge.OnInvoke = function(player: any, requestedCourseId: any): (boolean, string)
		if not RunService:IsStudio() then
			return false, "Studio only"
		elseif studioCourseControlBridge ~= bridge or bridge.Parent ~= ServerStorage then
			return false, "Bridge unavailable"
		elseif typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
			return false, "Player unavailable"
		elseif type(requestedCourseId) ~= "string" then
			return false, "Unknown course"
		end

		local courseId = exactCourseId(requestedCourseId)
		local definition = CourseRegistry.getDefinition(requestedCourseId)
		if courseId == nil or definition == nil or definition.CourseId ~= courseId then
			return false, "Unknown course"
		elseif courseId == FROST_TRAIL_COURSE_ID and definition.ActivationMode ~= "StudioControlledTest" then
			return false, "Course unavailable"
		elseif courseId == CLASSIC_COURSE_ID and definition.ActivationMode ~= "LiveDefault" then
			return false, "Course unavailable"
		end

		return runningPrepareStudioCourse(player, requestedCourseId)
	end
	studioCourseControlBridge = bridge
	bridge.Parent = ServerStorage
end

function RunManager.handlePlayerRemoving(player: Player)
	local session = sessions[player]
	clearPreparedPlayer(player)
	pendingReplays[player] = nil
	storeOperations[player] = nil
	if session then
		local runId = session.RunId
		if isSameSession(session, runId) then
			requestCleanup(session, runId, "player removed", false)
			if session.CleanupStarted and session.Phase == RunPhase.Idle and sessions[player] == session then
				sessions[player] = nil
			end
		end
	end
	refreshStartPrompts()
	ResultService.removePlayer(player)
end

function RunManager.canAccessStore(player: Player): boolean
	local preparedState = preparedCourses[player]
	return started
		and player.Parent == Players
		and sessions[player] == nil
		and pendingReplays[player] == nil
		and (preparedState == nil or not preparedState.Routing)
end

function RunManager.beginStoreOperation(player: Player): (StoreOperationToken?, string?)
	if not started then
		return nil, "run manager unavailable"
	elseif player.Parent ~= Players then
		return nil, "player unavailable"
	elseif sessions[player] ~= nil then
		return nil, "run active"
	elseif pendingReplays[player] ~= nil then
		return nil, "replay pending"
	elseif preparedCourses[player] ~= nil and (preparedCourses[player] :: PreparedCourseState).Routing then
		return nil, "course preparation active"
	elseif storeOperations[player] ~= nil then
		return nil, "store operation already reserved"
	end

	local token: StoreOperationToken = {
		_OpaqueStoreOperationToken = true,
	}
	storeOperations[player] = token
	return token, nil
end

function RunManager.isStoreOperationCurrent(player: Player, token: StoreOperationToken): boolean
	return started
		and player.Parent == Players
		and storeOperations[player] == token
		and sessions[player] == nil
		and pendingReplays[player] == nil
		and (preparedCourses[player] == nil or not (preparedCourses[player] :: PreparedCourseState).Routing)
end

function RunManager.endStoreOperation(player: Player, token: StoreOperationToken)
	if storeOperations[player] == token then
		storeOperations[player] = nil
	end
end

function RunManager.start()
	if started then
		return
	end
	started = true

	local courses, resolutionReason = resolveCourses()
	if not courses then
		warn(
			string.format(
				"[Frostline][Course] CourseId=%s unavailable reason=%s",
				CourseRegistry.DefaultCourseId,
				resolutionReason
			)
		)
		started = false
		return
	end
	resolvedCourses = courses

	local remoteFolder = getOrCreateRemoteFolder()
	local tuckRemote = getOrCreateRemote(remoteFolder, TUCK_REMOTE_NAME)
	stateRemote = getOrCreateRemote(remoteFolder, STATE_REMOTE_NAME)
	resultRemote = getOrCreateRemote(remoteFolder, RESULT_REMOTE_NAME)
	local resultActionRemote = getOrCreateRemote(remoteFolder, RESULT_ACTION_REMOTE_NAME)

	tuckRemote.OnServerEvent:Connect(onTuckIntent)
	resultActionRemote.OnServerEvent:Connect(onResultAction)
	if RunService:IsStudio() and courses[FROST_TRAIL_COURSE_ID] ~= nil then
		local steeringRemote = getOrCreateRemote(remoteFolder, STEERING_REMOTE_NAME)
		steeringRemote.OnServerEvent:Connect(onSteeringIntent)
	end
	trustedReplay = function(player: Player, courseId: CourseId)
		startRunSafely(player, courseId, true)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		initializePreparedPlayer(player)
	end
	Players.PlayerAdded:Connect(initializePreparedPlayer)

	local function connectCoursePrompt(courseId: CourseId)
		local course = courses[courseId]
		if course == nil then
			return
		end
		local prompt = configurePrompt(course.StartTrigger)
		startPrompts[courseId] = prompt
		prompt.Triggered:Connect(function(player: Player)
			local preparedState = preparedCourses[player]
			if preparedState == nil or preparedState.Routing then
				return
			elseif courseId == FROST_TRAIL_COURSE_ID
				and (not RunService:IsStudio() or preparedState.CourseId ~= FROST_TRAIL_COURSE_ID)
			then
				return
			end
			startRunSafely(player, courseId, false)
		end)
	end

	connectCoursePrompt(CLASSIC_COURSE_ID)
	if RunService:IsStudio() and courses[FROST_TRAIL_COURSE_ID] ~= nil then
		connectCoursePrompt(FROST_TRAIL_COURSE_ID)
	end
	refreshStartPrompts()

	print("[Frostline] RunManager ready")
	publishStudioCourseControlBridge()
end

return RunManager
