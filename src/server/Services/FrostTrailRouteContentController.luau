--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FrostTrailConfig = require(script.Parent.FrostTrailConfig)
local FrostTrailRouteContentConfig = require(script.Parent.FrostTrailRouteContentConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

type CoinPlacement = FrostTrailRouteContentConfig.CoinPlacement
type ObstacleKind = FrostTrailRouteContentConfig.ObstacleKind
type ObstaclePlacement = FrostTrailRouteContentConfig.ObstaclePlacement
type RouteGeometryPoint = FrostTrailConfig.RouteGeometryPoint

export type CoinDescriptor = {
	ContentId: string,
	SectionId: string,
	GroupId: string,
	Pattern: string,
	AuthoredLongitudinal: number,
	LateralOffset: number,
	HeightOffset: number,
	CFrame: CFrame,
	Size: Vector3,
	Part: Part,
	ForwardMinimum: number,
	ForwardMaximum: number,
}

export type ObstacleDescriptor = {
	ContentId: string,
	SectionId: string,
	EncounterId: string,
	ObstacleKind: ObstacleKind,
	AuthoredLongitudinal: number,
	LateralOffset: number,
	CFrame: CFrame,
	Size: Vector3,
	Part: Part,
	ForwardMinimum: number,
	ForwardMaximum: number,
}

export type EncounterDescriptor = {
	EncounterId: string,
	ObstacleKind: ObstacleKind,
	AuthoredLongitudinal: number,
	Parts: { ObstacleDescriptor },
	ForwardMinimum: number,
	ForwardMaximum: number,
	SortContentId: string,
}

export type ResolvedContent = {
	World: Model,
	Gameplay: Folder,
	Coins: Folder,
	Obstacles: Folder,
	CoinDescriptors: { CoinDescriptor },
	ObstacleDescriptors: { ObstacleDescriptor },
	EncounterDescriptors: { EncounterDescriptor },
	CoinsByContentId: { [string]: CoinDescriptor },
	ObstaclesByContentId: { [string]: ObstacleDescriptor },
	EncountersById: { [string]: EncounterDescriptor },
	CourseOrigin: Vector3,
	CourseForward: Vector3,
}

export type AuthoritativeContext = {
	IsCurrentSession: boolean,
	IsResolvedCourseCurrent: boolean,
	Player: Player,
	RunId: number,
	CourseId: string,
	Playable: boolean,
	ActivationMode: string,
	ResolvedContent: ResolvedContent,
	World: Model,
	ActiveSleds: Folder,
	Character: Model,
	Humanoid: Humanoid,
	Sled: Model,
	Root: Part,
	DriverSeat: Seat,
	GovernorAttachment: Attachment,
	GovernorForce: VectorForce?,
	SpeedProfile: any,
	Phase: string,
	CleanupStarted: boolean,
	ReleaseInProgress: boolean,
	TuckActivationReady: boolean,
	SpeedGovernorReleaseAuthorized: boolean,
	SpeedGovernorDisqualified: boolean,
	RampFreedomEntered: boolean,
}

export type State = {
	RunId: number,
	Player: Player,
	ResolvedContent: ResolvedContent,
	PreviousCFrame: CFrame?,
	PreviousPosition: Vector3?,
	PreviousVelocity: Vector3?,
	PreviousAngularVelocity: Vector3?,
	PreviousSampleAt: number?,
	MaximumLongitudinalSeen: number,
	CoinCursor: number,
	ObstacleCursor: number,
	EncounterCursor: number,
	LastCandidateCount: number,
	RetiredCoinIds: { [string]: boolean },
	RetiredEncounterIds: { [string]: boolean },
	CollectedContentIds: { [string]: boolean },
	ResolvedEncounterIds: { [string]: boolean },
	CollectedCoinCount: number,
	ObstacleHitCount: number,
	RewardEligibleCoinCount: number,
	ActiveSpeedCap: number?,
	SpeedCapExpiry: number?,
	OutboundEventSequence: number,
	PresentedCoinCount: number,
	PresentedObstacleHits: number,
	Began: boolean,
	Armed: boolean,
	Sealed: boolean,
	Invalidated: boolean,
	Cleared: boolean,
	NormalSealSent: boolean,
	InvalidatedSealSent: boolean,
	ClearSent: boolean,
	WarningEmitted: boolean,
}

type CoinCollectedEntry = {
	Kind: "CoinCollected",
	ContentId: string,
}

type ObstacleHitEntry = {
	Kind: "ObstacleHit",
	ContentId: string,
	EncounterId: string,
	ObstacleKind: ObstacleKind,
	SpeedLoss: number,
}

type PacketEntry = CoinCollectedEntry | ObstacleHitEntry
type PacketKind = "Begin" | "Delta" | "Seal" | "Clear"

type RouteSample = {
	Frame: CFrame,
}

type SweepChord = {
	StartPoint: Vector3,
	EndPoint: Vector3,
	GlobalStart: number,
	GlobalEnd: number,
}

type AcceptedContact = {
	Time: number,
	ContentId: string,
	Coin: CoinDescriptor?,
	Obstacle: ObstacleDescriptor?,
}

local COURSE_ID = "FrostTrailV1"
local REMOTE_FOLDER_NAME = "FrostlineRemotes"
local REMOTE_NAME = "FrostTrailContentEvent"
local TRACK_SURFACE_ATTRIBUTE = "FrostlineTrackSurface"
local EXPECTED_ROOT_SIZE = Vector3.new(5.6, 0.8, 8.6)
local EXPECTED_GEOMETRY_POINT_COUNT = 75
local COURSE_RIGHT = FrostTrailConfig.ForwardDirection:Cross(Vector3.yAxis).Unit
local PALETTE = GameConfig.Palette
local RUNTIME = FrostTrailRouteContentConfig.Runtime

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

local FrostTrailRouteContentController = {}
local boundRemote: RemoteEvent? = nil

local function fail(message: string): never
	error("Frost Trail route content: " .. message, 0)
end

local function requireCondition(condition: boolean, message: string)
	if not condition then
		fail(message)
	end
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isPositiveInteger(value: number): boolean
	return isFiniteNumber(value) and value > 0 and value % 1 == 0
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

local function approximatelyEqual(left: number, right: number): boolean
	return math.abs(left - right) <= FrostTrailConfig.ValidationEpsilon
end

local function vectorsApproximatelyEqual(left: Vector3, right: Vector3): boolean
	return approximatelyEqual(left.X, right.X)
		and approximatelyEqual(left.Y, right.Y)
		and approximatelyEqual(left.Z, right.Z)
end

local function colorsApproximatelyEqual(left: Color3, right: Color3): boolean
	return approximatelyEqual(left.R, right.R)
		and approximatelyEqual(left.G, right.G)
		and approximatelyEqual(left.B, right.B)
end

local function cframesApproximatelyEqual(left: CFrame, right: CFrame): boolean
	return vectorsApproximatelyEqual(left.Position, right.Position)
		and vectorsApproximatelyEqual(left.RightVector, right.RightVector)
		and vectorsApproximatelyEqual(left.UpVector, right.UpVector)
		and vectorsApproximatelyEqual(left.LookVector, right.LookVector)
end

local function tableEntryCount(values: { [any]: any }): number
	local count = 0
	for _ in values do
		count += 1
	end
	return count
end

local function validateExactAttributeNames(instance: Instance, expectedNames: { string })
	local attributes = instance:GetAttributes()
	requireCondition(tableEntryCount(attributes) == #expectedNames, instance.Name .. " attribute count mismatch")
	for _, name in ipairs(expectedNames) do
		requireCondition(attributes[name] ~= nil, instance.Name .. " is missing attribute " .. name)
	end
end

local function localToWorldPoint(localPoint: Vector3): Vector3
	return FrostTrailConfig.WorldOrigin
		+ COURSE_RIGHT * localPoint.X
		+ Vector3.yAxis * localPoint.Y
		+ FrostTrailConfig.ForwardDirection * localPoint.Z
end

local function routeSampleAtLongitudinal(longitudinal: number): RouteSample
	local geometryPoints = FrostTrailConfig.RouteData.GeometryPoints
	requireCondition(isFiniteNumber(longitudinal), "route longitudinal must be finite")
	requireCondition(#geometryPoints == EXPECTED_GEOMETRY_POINT_COUNT, "geometry-point count mismatch")
	requireCondition(
		longitudinal >= geometryPoints[1].LocalPosition.Z
			and longitudinal <= geometryPoints[#geometryPoints].LocalPosition.Z,
		"route longitudinal lies outside geometry"
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
	local pointA = geometryPoints[segmentIndex].LocalPosition
	local pointB = geometryPoints[segmentIndex + 1].LocalPosition
	local chord = pointB - pointA
	requireCondition(isFiniteVector3(pointA) and isFiniteVector3(pointB), "route geometry must be finite")
	requireCondition(chord.Magnitude > FrostTrailConfig.ValidationEpsilon and chord.Z > 0, "route chord is invalid")
	local alpha = (longitudinal - pointA.Z) / (pointB.Z - pointA.Z)
	requireCondition(isFiniteNumber(alpha) and alpha >= 0 and alpha <= 1, "route interpolation is invalid")
	local worldA = localToWorldPoint(pointA)
	local worldB = localToWorldPoint(pointB)
	local worldChord = worldB - worldA
	requireCondition(worldChord.Magnitude > FrostTrailConfig.ValidationEpsilon, "world route chord is invalid")
	local worldCenter = localToWorldPoint(pointA:Lerp(pointB, alpha))
	local frame = CFrame.lookAt(worldCenter, worldCenter + worldChord.Unit, Vector3.yAxis)
	requireCondition(isFiniteCFrame(frame), "route frame is non-finite")
	return { Frame = frame }
end

local function coinFrame(placement: CoinPlacement): CFrame
	return routeSampleAtLongitudinal(placement.Longitudinal).Frame
		* CFrame.new(placement.LateralOffset, placement.HeightOffset, 0)
		* CFrame.Angles(0, math.rad(90), 0)
end

local function obstacleFrame(placement: ObstaclePlacement, size: Vector3): CFrame
	return routeSampleAtLongitudinal(placement.Longitudinal).Frame
		* CFrame.new(placement.LateralOffset, size.Y * 0.5, 0)
end

local function forwardCoordinate(position: Vector3): number
	return (position - FrostTrailConfig.WorldOrigin):Dot(FrostTrailConfig.ForwardDirection)
end

local function requireExactNumber(actual: number, expected: number, name: string)
	requireCondition(isFiniteNumber(actual) and actual == expected, name .. " mismatch")
end

local function validateConfiguration()
	requireCondition(RunService:IsServer(), "controller may load only on the server")
	requireCondition(table.isfrozen(FrostTrailConfig), "FrostTrailConfig must be frozen")
	requireCondition(table.isfrozen(FrostTrailConfig.RouteData), "Frost route data must be frozen")
	requireCondition(table.isfrozen(FrostTrailConfig.RouteData.GeometryPoints), "geometry points must be frozen")
	requireCondition(FrostTrailConfig.CourseId == COURSE_ID, "Frost course ID mismatch")
	requireCondition(FrostTrailConfig.Playable == false, "Frost must remain non-playable")
	requireCondition(FrostTrailConfig.ActivationMode == "StudioControlledTest", "Frost activation mode mismatch")
	requireCondition(FrostTrailConfig.WorldOrigin == Vector3.new(3200, 0, 0), "Frost origin mismatch")
	requireCondition(FrostTrailConfig.ForwardDirection == Vector3.new(0, 0, 1), "Frost forward direction mismatch")
	requireCondition(#FrostTrailConfig.RouteData.GeometryPoints == EXPECTED_GEOMETRY_POINT_COUNT, "geometry-point count mismatch")
	for _, point in ipairs(FrostTrailConfig.RouteData.GeometryPoints) do
		requireCondition(table.isfrozen(point), "geometry point must be frozen")
		requireCondition(isFiniteVector3(point.LocalPosition), "geometry point must be finite")
	end

	requireCondition(table.isfrozen(FrostTrailRouteContentConfig), "route config must be frozen")
	requireCondition(table.isfrozen(RUNTIME), "route runtime config must be separately frozen")
	requireCondition(FrostTrailRouteContentConfig.CourseId == COURSE_ID, "route config course mismatch")
	requireCondition(FrostTrailRouteContentConfig.ContentVersion == 1, "content version mismatch")
	requireCondition(FrostTrailRouteContentConfig.RuntimeEnabled == true, "route runtime must be enabled")
	requireCondition(FrostTrailRouteContentConfig.RuntimeVersion == 1, "runtime version mismatch")
	requireExactNumber(
		FrostTrailRouteContentConfig.MaximumRecoverableEvaluationDeltaSeconds,
		0.25,
		"MaximumRecoverableEvaluationDeltaSeconds"
	)
	requireExactNumber(
		FrostTrailRouteContentConfig.MaximumRecoverableSweepSubsteps,
		5,
		"MaximumRecoverableSweepSubsteps"
	)
	requireCondition(table.isfrozen(FrostTrailRouteContentConfig.CoinPlacements), "coin placements must be frozen")
	requireCondition(table.isfrozen(FrostTrailRouteContentConfig.ObstacleRows), "obstacle rows must be frozen")
	requireCondition(table.isfrozen(FrostTrailRouteContentConfig.ObstaclePlacements), "obstacle placements must be frozen")
	requireCondition(#FrostTrailRouteContentConfig.CoinPlacements == 160, "coin count mismatch")
	requireCondition(#FrostTrailRouteContentConfig.ObstacleRows == 18, "encounter count mismatch")
	requireCondition(#FrostTrailRouteContentConfig.ObstaclePlacements == 21, "obstacle count mismatch")

	requireExactNumber(RUNTIME.CoinRewardPerPickup, 1, "CoinRewardPerPickup")
	requireExactNumber(RUNTIME.MaximumRouteCoins, 160, "MaximumRouteCoins")
	requireExactNumber(RUNTIME.MaximumObstacleEncounters, 18, "MaximumObstacleEncounters")
	requireExactNumber(RUNTIME.EvaluationStartLongitudinal, -200, "EvaluationStartLongitudinal")
	requireExactNumber(RUNTIME.EvaluationEndLongitudinal, 6100, "EvaluationEndLongitudinal")
	requireExactNumber(RUNTIME.CoinPickupRadiusStuds, 5.25, "CoinPickupRadiusStuds")
	requireExactNumber(RUNTIME.BroadphasePaddingStuds, 20, "BroadphasePaddingStuds")
	requireExactNumber(RUNTIME.MaximumEvaluationDeltaSeconds, 0.10, "MaximumEvaluationDeltaSeconds")
	requireExactNumber(RUNTIME.MaximumSweepSubstepSeconds, 0.05, "MaximumSweepSubstepSeconds")
	requireExactNumber(RUNTIME.MaximumSweepSubsteps, 2, "MaximumSweepSubsteps")
	requireExactNumber(RUNTIME.MaximumHorizontalSpeedStudsPerSecond, 165, "MaximumHorizontalSpeedStudsPerSecond")
	requireExactNumber(RUNTIME.MaximumTotalSpeedStudsPerSecond, 180, "MaximumTotalSpeedStudsPerSecond")
	requireExactNumber(RUNTIME.MovementSlackStuds, 12, "MovementSlackStuds")
	requireExactNumber(RUNTIME.MaximumCandidatesPerUpdate, 24, "MaximumCandidatesPerUpdate")
	requireCondition(RUNTIME.SledRootHalfSize == Vector3.new(2.8, 0.4, 4.3), "SledRootHalfSize mismatch")
	requireExactNumber(RUNTIME.ObstacleContactPaddingStuds, 0.20, "ObstacleContactPaddingStuds")
	requireExactNumber(RUNTIME.ParallelAxisEpsilon, 0.00000001, "ParallelAxisEpsilon")
	requireExactNumber(RUNTIME.TimeOfImpactEpsilon, 0.000001, "TimeOfImpactEpsilon")
	requireExactNumber(RUNTIME.IceBlockerSpeedLoss, 30, "IceBlockerSpeedLoss")
	requireExactNumber(RUNTIME.IceBlockerMinimumSpeedCap, 18, "IceBlockerMinimumSpeedCap")
	requireExactNumber(RUNTIME.IceBlockerPenaltySeconds, 1.50, "IceBlockerPenaltySeconds")
	requireExactNumber(RUNTIME.HopBarrierSpeedLoss, 20, "HopBarrierSpeedLoss")
	requireExactNumber(RUNTIME.HopBarrierMinimumSpeedCap, 22, "HopBarrierMinimumSpeedCap")
	requireExactNumber(RUNTIME.HopBarrierPenaltySeconds, 1.00, "HopBarrierPenaltySeconds")
end

local function validateWorldMetadata(world: Model)
	requireCondition(world.ClassName == "Model", "world must be a Model")
	requireCondition(world.Name == FrostTrailConfig.WorldModelName, "world name mismatch")
	requireCondition(world.Parent == Workspace, "world must be published directly under Workspace")
	requireCondition(world:GetAttribute("CourseId") == COURSE_ID, "world CourseId mismatch")
	requireCondition(world:GetAttribute("Playable") == false, "world Playable mismatch")
	requireCondition(world:GetAttribute("ActivationMode") == "StudioControlledTest", "world activation mode mismatch")
	requireCondition(
		world:GetAttribute("RouteContentVersion") == FrostTrailRouteContentConfig.ContentVersion,
		"world content version mismatch"
	)
	requireCondition(world:GetAttribute("RouteContentRuntimeEnabled") == true, "world route runtime must be enabled")
	requireCondition(
		world:GetAttribute("RouteContentRuntimeVersion") == FrostTrailRouteContentConfig.RuntimeVersion,
		"world route runtime version mismatch"
	)
	requireCondition(world:GetAttribute("RouteCoinCount") == 160, "world route coin count mismatch")
	requireCondition(world:GetAttribute("RouteObstacleCount") == 21, "world route obstacle count mismatch")
	requireCondition(world:GetAttribute("RouteObstacleRowCount") == 18, "world route row count mismatch")
	requireCondition(world:GetAttribute("RouteGameplayPartCount") == 181, "world route gameplay count mismatch")
	requireCondition(world:GetAttribute("BasePartCount") == 628, "world BasePart count mismatch")
	requireCondition(world:GetAttribute("OriginX") == FrostTrailConfig.WorldOrigin.X, "world OriginX mismatch")
	requireCondition(world:GetAttribute("OriginY") == FrostTrailConfig.WorldOrigin.Y, "world OriginY mismatch")
	requireCondition(world:GetAttribute("OriginZ") == FrostTrailConfig.WorldOrigin.Z, "world OriginZ mismatch")
end

local function exactDirectChild(parent: Instance, name: string, className: string): Instance
	local result: Instance? = nil
	local count = 0
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			count += 1
			result = child
		end
	end
	requireCondition(count == 1 and result ~= nil, parent.Name .. " must contain exactly one direct " .. name)
	requireCondition((result :: Instance).ClassName == className, name .. " class mismatch")
	return result :: Instance
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
	requireCondition(#folder:GetDescendants() == expectedCount, folder.Name .. " may not contain nested descendants")
	return parts
end

local function validateCommonPart(part: Part, expectedCFrame: CFrame, expectedSize: Vector3, castShadow: boolean)
	requireCondition(part.ClassName == "Part", part.Name .. " must be a primitive Part")
	requireCondition(part.Anchored == true, part.Name .. " must remain anchored")
	requireCondition(part.CanCollide == false, part.Name .. " must remain noncollidable")
	requireCondition(part.CanTouch == false, part.Name .. " must remain nontouchable")
	requireCondition(part.CanQuery == false, part.Name .. " must remain nonqueryable")
	requireCondition(part.CastShadow == castShadow, part.Name .. " CastShadow mismatch")
	requireCondition(part.Massless == false, part.Name .. " Massless mismatch")
	requireCondition(part.CollisionGroup == "Default", part.Name .. " collision group mismatch")
	requireCondition(part.CustomPhysicalProperties == nil, part.Name .. " custom physical properties mismatch")
	requireCondition(part.TopSurface == Enum.SurfaceType.Smooth, part.Name .. " top surface mismatch")
	requireCondition(part.BottomSurface == Enum.SurfaceType.Smooth, part.Name .. " bottom surface mismatch")
	requireCondition(vectorsApproximatelyEqual(part.Size, expectedSize), part.Name .. " size mismatch")
	requireCondition(isFiniteCFrame(part.CFrame), part.Name .. " CFrame must be finite")
	requireCondition(cframesApproximatelyEqual(part.CFrame, expectedCFrame), part.Name .. " CFrame mismatch")
	requireCondition(part:GetAttribute(TRACK_SURFACE_ATTRIBUTE) == nil, part.Name .. " may not be a track surface")
	requireCondition(#part:GetChildren() == 0, part.Name .. " may not contain descendants")
end

local function validateCoinPart(part: Part, descriptor: CoinDescriptor)
	requireCondition(part == descriptor.Part, descriptor.ContentId .. " Part identity changed")
	requireCondition(part.Name == descriptor.ContentId, descriptor.ContentId .. " name mismatch")
	validateCommonPart(part, descriptor.CFrame, descriptor.Size, false)
	requireCondition(part.Shape == Enum.PartType.Cylinder, descriptor.ContentId .. " shape mismatch")
	requireCondition(part.Material == Enum.Material.Neon, descriptor.ContentId .. " material mismatch")
	requireCondition(colorsApproximatelyEqual(part.Color, PALETTE.Gold), descriptor.ContentId .. " color mismatch")
	requireCondition(approximatelyEqual(part.Transparency, 0), descriptor.ContentId .. " transparency mismatch")
	requireCondition(approximatelyEqual(part.Reflectance, 0.05), descriptor.ContentId .. " reflectance mismatch")
	validateExactAttributeNames(part, COIN_ATTRIBUTE_NAMES)
	requireCondition(part:GetAttribute("ContentId") == descriptor.ContentId, descriptor.ContentId .. " ContentId mismatch")
	requireCondition(part:GetAttribute("ContentKind") == "Coin", descriptor.ContentId .. " ContentKind mismatch")
	requireCondition(part:GetAttribute("SectionId") == descriptor.SectionId, descriptor.ContentId .. " SectionId mismatch")
	requireCondition(part:GetAttribute("GroupId") == descriptor.GroupId, descriptor.ContentId .. " GroupId mismatch")
	requireCondition(part:GetAttribute("Pattern") == descriptor.Pattern, descriptor.ContentId .. " Pattern mismatch")
	requireCondition(
		part:GetAttribute("Longitudinal") == descriptor.AuthoredLongitudinal,
		descriptor.ContentId .. " Longitudinal mismatch"
	)
	requireCondition(
		part:GetAttribute("LateralOffset") == descriptor.LateralOffset,
		descriptor.ContentId .. " LateralOffset mismatch"
	)
	requireCondition(
		part:GetAttribute("HeightOffset") == descriptor.HeightOffset,
		descriptor.ContentId .. " HeightOffset mismatch"
	)
	requireCondition(part:GetAttribute("RuntimeEnabled") == true, descriptor.ContentId .. " runtime marker mismatch")
end

local function validateObstaclePart(part: Part, descriptor: ObstacleDescriptor)
	requireCondition(part == descriptor.Part, descriptor.ContentId .. " Part identity changed")
	requireCondition(part.Name == descriptor.ContentId, descriptor.ContentId .. " name mismatch")
	validateCommonPart(part, descriptor.CFrame, descriptor.Size, true)
	local isIceBlocker = descriptor.ObstacleKind == "IceBlocker"
	requireCondition(part.Shape == Enum.PartType.Block, descriptor.ContentId .. " shape mismatch")
	requireCondition(
		part.Material == (if isIceBlocker then Enum.Material.Ice else Enum.Material.SmoothPlastic),
		descriptor.ContentId .. " material mismatch"
	)
	requireCondition(
		colorsApproximatelyEqual(part.Color, if isIceBlocker then PALETTE.IceDeep else PALETTE.Red),
		descriptor.ContentId .. " color mismatch"
	)
	requireCondition(
		approximatelyEqual(part.Transparency, if isIceBlocker then 0.05 else 0),
		descriptor.ContentId .. " transparency mismatch"
	)
	requireCondition(
		approximatelyEqual(part.Reflectance, if isIceBlocker then 0.1 else 0),
		descriptor.ContentId .. " reflectance mismatch"
	)
	validateExactAttributeNames(part, OBSTACLE_ATTRIBUTE_NAMES)
	requireCondition(part:GetAttribute("ContentId") == descriptor.ContentId, descriptor.ContentId .. " ContentId mismatch")
	requireCondition(part:GetAttribute("ContentKind") == "Obstacle", descriptor.ContentId .. " ContentKind mismatch")
	requireCondition(part:GetAttribute("SectionId") == descriptor.SectionId, descriptor.ContentId .. " SectionId mismatch")
	requireCondition(
		part:GetAttribute("EncounterId") == descriptor.EncounterId,
		descriptor.ContentId .. " EncounterId mismatch"
	)
	requireCondition(
		part:GetAttribute("ObstacleKind") == descriptor.ObstacleKind,
		descriptor.ContentId .. " ObstacleKind mismatch"
	)
	requireCondition(
		part:GetAttribute("Longitudinal") == descriptor.AuthoredLongitudinal,
		descriptor.ContentId .. " Longitudinal mismatch"
	)
	requireCondition(
		part:GetAttribute("LateralOffset") == descriptor.LateralOffset,
		descriptor.ContentId .. " LateralOffset mismatch"
	)
	requireCondition(part:GetAttribute("RuntimeEnabled") == true, descriptor.ContentId .. " runtime marker mismatch")
end

local function descriptorSort(left: any, right: any): boolean
	if left.ForwardMinimum == right.ForwardMinimum then
		return left.ContentId < right.ContentId
	end
	return left.ForwardMinimum < right.ForwardMinimum
end

local function encounterSort(left: EncounterDescriptor, right: EncounterDescriptor): boolean
	if left.ForwardMinimum == right.ForwardMinimum then
		return left.SortContentId < right.SortContentId
	end
	return left.ForwardMinimum < right.ForwardMinimum
end


local function resolveUnsafe(world: Model): ResolvedContent
	validateConfiguration()
	requireCondition(RunService:IsStudio(), "route content may resolve only in Studio")
	validateWorldMetadata(world)

	local gameplay = exactDirectChild(world, "Gameplay", "Folder") :: Folder
	requireCondition(#gameplay:GetChildren() == 2, "Gameplay must contain exactly Coins and Obstacles")
	local coins = exactDirectChild(gameplay, "Coins", "Folder") :: Folder
	local obstacles = exactDirectChild(gameplay, "Obstacles", "Folder") :: Folder
	local coinParts = directPartMap(coins, 160)
	local obstacleParts = directPartMap(obstacles, 21)

	local coinDescriptors: { CoinDescriptor } = {}
	local obstacleDescriptors: { ObstacleDescriptor } = {}
	local coinsByContentId: { [string]: CoinDescriptor } = {}
	local obstaclesByContentId: { [string]: ObstacleDescriptor } = {}
	local encounterMembers: { [string]: { ObstacleDescriptor } } = {}

	for index, placement in ipairs(FrostTrailRouteContentConfig.CoinPlacements) do
		requireCondition(table.isfrozen(placement), "coin placement must be frozen")
		requireCondition(placement.ContentId == string.format("FrostCoin_%03d", index), "coin ID sequence mismatch")
		requireCondition(coinsByContentId[placement.ContentId] == nil, "duplicate coin ContentId")
		requireCondition(
			placement.Longitudinal >= -160 and placement.Longitudinal <= 6060,
			placement.ContentId .. " lies outside the authored scoring range"
		)
		local part = coinParts[placement.ContentId]
		requireCondition(part ~= nil, placement.ContentId .. " is missing")
		local expectedCFrame = coinFrame(placement)
		local centerForward = forwardCoordinate(expectedCFrame.Position)
		local descriptor: CoinDescriptor = table.freeze({
			ContentId = placement.ContentId,
			SectionId = placement.SectionId,
			GroupId = placement.GroupId,
			Pattern = placement.Pattern,
			AuthoredLongitudinal = placement.Longitudinal,
			LateralOffset = placement.LateralOffset,
			HeightOffset = placement.HeightOffset,
			CFrame = expectedCFrame,
			Size = FrostTrailRouteContentConfig.CoinSize,
			Part = part :: Part,
			ForwardMinimum = centerForward - RUNTIME.CoinPickupRadiusStuds,
			ForwardMaximum = centerForward + RUNTIME.CoinPickupRadiusStuds,
		})
		requireCondition(
			isFiniteNumber(descriptor.ForwardMinimum) and isFiniteNumber(descriptor.ForwardMaximum),
			placement.ContentId .. " has a non-finite forward interval"
		)
		validateCoinPart(part :: Part, descriptor)
		table.insert(coinDescriptors, descriptor)
		coinsByContentId[descriptor.ContentId] = descriptor
	end

	local maximumRootSupport = RUNTIME.SledRootHalfSize.Magnitude
	for index, placement in ipairs(FrostTrailRouteContentConfig.ObstaclePlacements) do
		requireCondition(table.isfrozen(placement), "obstacle placement must be frozen")
		requireCondition(
			placement.ContentId == string.format("FrostObstacle_%03d", index),
			"obstacle ID sequence mismatch"
		)
		requireCondition(obstaclesByContentId[placement.ContentId] == nil, "duplicate obstacle ContentId")
		requireCondition(
			placement.Longitudinal >= 400 and placement.Longitudinal <= 5390,
			placement.ContentId .. " lies outside the authored scoring range"
		)
		local part = obstacleParts[placement.ContentId]
		requireCondition(part ~= nil, placement.ContentId .. " is missing")
		local size = if placement.ObstacleKind == "IceBlocker"
			then FrostTrailRouteContentConfig.IceBlockerSize
			else FrostTrailRouteContentConfig.HopBarrierSize
		local expectedCFrame = obstacleFrame(placement, size)
		local halfSize = size * 0.5
		local obstacleForwardRadius = math.abs(FrostTrailConfig.ForwardDirection:Dot(expectedCFrame.RightVector))
			* halfSize.X
			+ math.abs(FrostTrailConfig.ForwardDirection:Dot(expectedCFrame.UpVector)) * halfSize.Y
			+ math.abs(FrostTrailConfig.ForwardDirection:Dot(expectedCFrame.LookVector)) * halfSize.Z
		local centerForward = forwardCoordinate(expectedCFrame.Position)
		local broadphaseRadius = obstacleForwardRadius
			+ maximumRootSupport
			+ maximumRootSupport
			+ RUNTIME.ObstacleContactPaddingStuds
		local descriptor: ObstacleDescriptor = table.freeze({
			ContentId = placement.ContentId,
			SectionId = placement.SectionId,
			EncounterId = placement.EncounterId,
			ObstacleKind = placement.ObstacleKind,
			AuthoredLongitudinal = placement.Longitudinal,
			LateralOffset = placement.LateralOffset,
			CFrame = expectedCFrame,
			Size = size,
			Part = part :: Part,
			ForwardMinimum = centerForward - broadphaseRadius,
			ForwardMaximum = centerForward + broadphaseRadius,
		})
		requireCondition(
			isFiniteNumber(descriptor.ForwardMinimum) and isFiniteNumber(descriptor.ForwardMaximum),
			placement.ContentId .. " has a non-finite forward interval"
		)
		validateObstaclePart(part :: Part, descriptor)
		table.insert(obstacleDescriptors, descriptor)
		obstaclesByContentId[descriptor.ContentId] = descriptor
		local members = encounterMembers[descriptor.EncounterId]
		if members == nil then
			members = {}
			encounterMembers[descriptor.EncounterId] = members
		end
		table.insert(members :: { ObstacleDescriptor }, descriptor)
	end

	table.sort(coinDescriptors, descriptorSort)
	table.sort(obstacleDescriptors, descriptorSort)
	table.freeze(coinDescriptors)
	table.freeze(obstacleDescriptors)
	table.freeze(coinsByContentId)
	table.freeze(obstaclesByContentId)

	local encounterDescriptors: { EncounterDescriptor } = {}
	local encountersById: { [string]: EncounterDescriptor } = {}
	for _, row in ipairs(FrostTrailRouteContentConfig.ObstacleRows) do
		requireCondition(table.isfrozen(row) and table.isfrozen(row.LaneOffsets), "obstacle row must be fully frozen")
		requireCondition(encountersById[row.EncounterId] == nil, "duplicate obstacle EncounterId")
		local members = encounterMembers[row.EncounterId]
		requireCondition(members ~= nil, row.EncounterId .. " has no physical Parts")
		table.sort(members :: { ObstacleDescriptor }, function(left: ObstacleDescriptor, right: ObstacleDescriptor): boolean
			return left.ContentId < right.ContentId
		end)
		requireCondition(
			#(members :: { ObstacleDescriptor }) == #row.LaneOffsets,
			row.EncounterId .. " physical Part count mismatch"
		)
		local forwardMinimum = math.huge
		local forwardMaximum = -math.huge
		for _, member in ipairs(members :: { ObstacleDescriptor }) do
			requireCondition(member.EncounterId == row.EncounterId, row.EncounterId .. " membership mismatch")
			requireCondition(member.ObstacleKind == row.ObstacleKind, row.EncounterId .. " kind mismatch")
			requireCondition(member.AuthoredLongitudinal == row.Longitudinal, row.EncounterId .. " longitudinal mismatch")
			forwardMinimum = math.min(forwardMinimum, member.ForwardMinimum)
			forwardMaximum = math.max(forwardMaximum, member.ForwardMaximum)
		end
		table.freeze(members :: { ObstacleDescriptor })
		local descriptor: EncounterDescriptor = table.freeze({
			EncounterId = row.EncounterId,
			ObstacleKind = row.ObstacleKind,
			AuthoredLongitudinal = row.Longitudinal,
			Parts = members :: { ObstacleDescriptor },
			ForwardMinimum = forwardMinimum,
			ForwardMaximum = forwardMaximum,
			SortContentId = (members :: { ObstacleDescriptor })[1].ContentId,
		})
		table.insert(encounterDescriptors, descriptor)
		encountersById[row.EncounterId] = descriptor
	end
	requireCondition(#encounterDescriptors == 18, "resolved encounter count mismatch")
	table.sort(encounterDescriptors, encounterSort)
	table.freeze(encounterDescriptors)
	table.freeze(encountersById)

	return table.freeze({
		World = world,
		Gameplay = gameplay,
		Coins = coins,
		Obstacles = obstacles,
		CoinDescriptors = coinDescriptors,
		ObstacleDescriptors = obstacleDescriptors,
		EncounterDescriptors = encounterDescriptors,
		CoinsByContentId = coinsByContentId,
		ObstaclesByContentId = obstaclesByContentId,
		EncountersById = encountersById,
		CourseOrigin = FrostTrailConfig.WorldOrigin,
		CourseForward = FrostTrailConfig.ForwardDirection,
	}) :: ResolvedContent
end

local function validateResolvedUnsafe(resolved: ResolvedContent, world: Model)
	validateConfiguration()
	requireCondition(RunService:IsStudio(), "route content may validate only in Studio")
	requireCondition(table.isfrozen(resolved), "resolved content must be frozen")
	requireCondition(resolved.World == world, "resolved world identity changed")
	validateWorldMetadata(world)

	local gameplay = exactDirectChild(world, "Gameplay", "Folder") :: Folder
	requireCondition(gameplay == resolved.Gameplay, "Gameplay identity changed")
	requireCondition(#gameplay:GetChildren() == 2, "Gameplay child count changed")
	local coins = exactDirectChild(gameplay, "Coins", "Folder") :: Folder
	local obstacles = exactDirectChild(gameplay, "Obstacles", "Folder") :: Folder
	requireCondition(coins == resolved.Coins and obstacles == resolved.Obstacles, "content folder identity changed")
	local coinParts = directPartMap(coins, 160)
	local obstacleParts = directPartMap(obstacles, 21)

	requireCondition(table.isfrozen(resolved.CoinDescriptors), "coin descriptor array must be frozen")
	requireCondition(table.isfrozen(resolved.ObstacleDescriptors), "obstacle descriptor array must be frozen")
	requireCondition(table.isfrozen(resolved.EncounterDescriptors), "encounter descriptor array must be frozen")
	requireCondition(table.isfrozen(resolved.CoinsByContentId), "coin descriptor map must be frozen")
	requireCondition(table.isfrozen(resolved.ObstaclesByContentId), "obstacle descriptor map must be frozen")
	requireCondition(table.isfrozen(resolved.EncountersById), "encounter descriptor map must be frozen")
	requireCondition(#resolved.CoinDescriptors == 160, "resolved coin count changed")
	requireCondition(#resolved.ObstacleDescriptors == 21, "resolved obstacle count changed")
	requireCondition(#resolved.EncounterDescriptors == 18, "resolved encounter count changed")
	requireCondition(tableEntryCount(resolved.CoinsByContentId) == 160, "resolved coin map count changed")
	requireCondition(tableEntryCount(resolved.ObstaclesByContentId) == 21, "resolved obstacle map count changed")
	requireCondition(tableEntryCount(resolved.EncountersById) == 18, "resolved encounter map count changed")
	requireCondition(resolved.CourseOrigin == FrostTrailConfig.WorldOrigin, "resolved course origin changed")
	requireCondition(resolved.CourseForward == FrostTrailConfig.ForwardDirection, "resolved course forward changed")

	for _, placement in ipairs(FrostTrailRouteContentConfig.CoinPlacements) do
		local descriptor = resolved.CoinsByContentId[placement.ContentId]
		requireCondition(descriptor ~= nil and table.isfrozen(descriptor), placement.ContentId .. " descriptor changed")
		local exact = descriptor :: CoinDescriptor
		local expectedCFrame = coinFrame(placement)
		local centerForward = forwardCoordinate(expectedCFrame.Position)
		requireCondition(exact.ContentId == placement.ContentId, placement.ContentId .. " descriptor ID mismatch")
		requireCondition(exact.SectionId == placement.SectionId, placement.ContentId .. " descriptor section mismatch")
		requireCondition(exact.GroupId == placement.GroupId, placement.ContentId .. " descriptor group mismatch")
		requireCondition(exact.Pattern == placement.Pattern, placement.ContentId .. " descriptor pattern mismatch")
		requireCondition(
			exact.AuthoredLongitudinal == placement.Longitudinal
				and exact.LateralOffset == placement.LateralOffset
				and exact.HeightOffset == placement.HeightOffset,
			placement.ContentId .. " descriptor placement mismatch"
		)
		requireCondition(exact.Size == FrostTrailRouteContentConfig.CoinSize, placement.ContentId .. " descriptor size mismatch")
		requireCondition(cframesApproximatelyEqual(exact.CFrame, expectedCFrame), placement.ContentId .. " descriptor CFrame mismatch")
		requireCondition(
			exact.ForwardMinimum == centerForward - RUNTIME.CoinPickupRadiusStuds
				and exact.ForwardMaximum == centerForward + RUNTIME.CoinPickupRadiusStuds,
			placement.ContentId .. " descriptor interval mismatch"
		)
		requireCondition(exact.Part == coinParts[placement.ContentId], placement.ContentId .. " descriptor Part mismatch")
		requireCondition(exact.Part.Parent == coins, placement.ContentId .. " ancestry mismatch")
		validateCoinPart(exact.Part, exact)
	end

	local maximumRootSupport = RUNTIME.SledRootHalfSize.Magnitude
	for _, placement in ipairs(FrostTrailRouteContentConfig.ObstaclePlacements) do
		local descriptor = resolved.ObstaclesByContentId[placement.ContentId]
		requireCondition(descriptor ~= nil and table.isfrozen(descriptor), placement.ContentId .. " descriptor changed")
		local exact = descriptor :: ObstacleDescriptor
		local size = if placement.ObstacleKind == "IceBlocker"
			then FrostTrailRouteContentConfig.IceBlockerSize
			else FrostTrailRouteContentConfig.HopBarrierSize
		local expectedCFrame = obstacleFrame(placement, size)
		local halfSize = size * 0.5
		local projectedRadius = math.abs(FrostTrailConfig.ForwardDirection:Dot(expectedCFrame.RightVector)) * halfSize.X
			+ math.abs(FrostTrailConfig.ForwardDirection:Dot(expectedCFrame.UpVector)) * halfSize.Y
			+ math.abs(FrostTrailConfig.ForwardDirection:Dot(expectedCFrame.LookVector)) * halfSize.Z
		local broadphaseRadius = projectedRadius
			+ maximumRootSupport
			+ maximumRootSupport
			+ RUNTIME.ObstacleContactPaddingStuds
		local centerForward = forwardCoordinate(expectedCFrame.Position)
		requireCondition(
			exact.ContentId == placement.ContentId
				and exact.SectionId == placement.SectionId
				and exact.EncounterId == placement.EncounterId
				and exact.ObstacleKind == placement.ObstacleKind,
			placement.ContentId .. " descriptor identity mismatch"
		)
		requireCondition(
			exact.AuthoredLongitudinal == placement.Longitudinal
				and exact.LateralOffset == placement.LateralOffset,
			placement.ContentId .. " descriptor placement mismatch"
		)
		requireCondition(exact.Size == size, placement.ContentId .. " descriptor size mismatch")
		requireCondition(cframesApproximatelyEqual(exact.CFrame, expectedCFrame), placement.ContentId .. " descriptor CFrame mismatch")
		requireCondition(
			exact.ForwardMinimum == centerForward - broadphaseRadius
				and exact.ForwardMaximum == centerForward + broadphaseRadius,
			placement.ContentId .. " descriptor interval mismatch"
		)
		requireCondition(exact.Part == obstacleParts[placement.ContentId], placement.ContentId .. " descriptor Part mismatch")
		requireCondition(exact.Part.Parent == obstacles, placement.ContentId .. " ancestry mismatch")
		validateObstaclePart(exact.Part, exact)
	end

	for index, descriptor in ipairs(resolved.CoinDescriptors) do
		requireCondition(table.isfrozen(descriptor), descriptor.ContentId .. " descriptor must be frozen")
		requireCondition(resolved.CoinsByContentId[descriptor.ContentId] == descriptor, "coin sorted index identity mismatch")
		if index > 1 then
			requireCondition(
				not descriptorSort(descriptor, resolved.CoinDescriptors[index - 1]),
				"coin broad-phase order changed"
			)
		end
	end
	for index, descriptor in ipairs(resolved.ObstacleDescriptors) do
		requireCondition(table.isfrozen(descriptor), descriptor.ContentId .. " descriptor must be frozen")
		requireCondition(
			resolved.ObstaclesByContentId[descriptor.ContentId] == descriptor,
			"obstacle sorted index identity mismatch"
		)
		if index > 1 then
			requireCondition(
				not descriptorSort(descriptor, resolved.ObstacleDescriptors[index - 1]),
				"obstacle broad-phase order changed"
			)
		end
	end

	for _, row in ipairs(FrostTrailRouteContentConfig.ObstacleRows) do
		local encounter = resolved.EncountersById[row.EncounterId]
		requireCondition(encounter ~= nil and table.isfrozen(encounter), row.EncounterId .. " descriptor changed")
		local exact = encounter :: EncounterDescriptor
		requireCondition(table.isfrozen(exact.Parts), row.EncounterId .. " Part array must be frozen")
		requireCondition(
			exact.EncounterId == row.EncounterId
				and exact.ObstacleKind == row.ObstacleKind
				and exact.AuthoredLongitudinal == row.Longitudinal,
			row.EncounterId .. " descriptor identity mismatch"
		)
		requireCondition(#exact.Parts == #row.LaneOffsets, row.EncounterId .. " descriptor Part count mismatch")
		local forwardMinimum = math.huge
		local forwardMaximum = -math.huge
		for index, partDescriptor in ipairs(exact.Parts) do
			requireCondition(partDescriptor.EncounterId == row.EncounterId, row.EncounterId .. " member mismatch")
			requireCondition(
				resolved.ObstaclesByContentId[partDescriptor.ContentId] == partDescriptor,
				row.EncounterId .. " member identity mismatch"
			)
			if index > 1 then
				requireCondition(
					partDescriptor.ContentId > exact.Parts[index - 1].ContentId,
					row.EncounterId .. " members are not lexical"
				)
			end
			forwardMinimum = math.min(forwardMinimum, partDescriptor.ForwardMinimum)
			forwardMaximum = math.max(forwardMaximum, partDescriptor.ForwardMaximum)
		end
		requireCondition(
			exact.ForwardMinimum == forwardMinimum and exact.ForwardMaximum == forwardMaximum,
			row.EncounterId .. " interval mismatch"
		)
		requireCondition(exact.SortContentId == exact.Parts[1].ContentId, row.EncounterId .. " sort key mismatch")
	end
	for index, descriptor in ipairs(resolved.EncounterDescriptors) do
		requireCondition(resolved.EncountersById[descriptor.EncounterId] == descriptor, "encounter index identity mismatch")
		if index > 1 then
			requireCondition(
				not encounterSort(descriptor, resolved.EncounterDescriptors[index - 1]),
				"encounter broad-phase order changed"
			)
		end
	end
end

function FrostTrailRouteContentController.resolve(world: Model): (ResolvedContent?, string?)
	local ok, result = pcall(resolveUnsafe, world)
	if not ok then
		return nil, tostring(result)
	end
	return result :: ResolvedContent, nil
end

function FrostTrailRouteContentController.validateResolved(
	resolved: ResolvedContent,
	world: Model
): (boolean, string?)
	local ok, reason = pcall(validateResolvedUnsafe, resolved, world)
	if not ok then
		return false, tostring(reason)
	end
	return true, nil
end

local function warnOnce(state: State, reason: string)
	if state.WarningEmitted then
		return
	end
	state.WarningEmitted = true
	warn(string.format("[Frostline][RouteContent] player=%s RunId=%d reason=%s", state.Player.Name, state.RunId, reason))
end

local function remoteIsExact(remote: RemoteEvent): boolean
	local parent = remote.Parent
	return RunService:IsServer()
		and RunService:IsStudio()
		and remote.ClassName == "RemoteEvent"
		and remote.Name == REMOTE_NAME
		and parent ~= nil
		and parent.ClassName == "Folder"
		and parent.Name == REMOTE_FOLDER_NAME
		and parent.Parent == ReplicatedStorage
end

function FrostTrailRouteContentController.bindRemote(remote: RemoteEvent): (boolean, string?)
	if not remoteIsExact(remote) then
		return false, "FrostTrailContentEvent identity is invalid"
	elseif boundRemote ~= nil and boundRemote ~= remote then
		return false, "FrostTrailContentEvent was already bound to another instance"
	end
	boundRemote = remote
	return true, nil
end

local function copyAndFreezeEntries(entries: { PacketEntry }): { PacketEntry }
	local copy: { PacketEntry } = {}
	for _, entry in ipairs(entries) do
		requireCondition(table.isfrozen(entry), "outbound entry must be frozen")
		table.insert(copy, entry)
	end
	return table.freeze(copy)
end

local function sendPacket(
	state: State,
	eventKind: PacketKind,
	entries: { PacketEntry },
	routeCoinsCollected: number,
	obstacleHits: number,
	invalidated: boolean
): boolean
	local remote = boundRemote
	if remote == nil or not remoteIsExact(remote) then
		return false
	end
	requireCondition(isPositiveInteger(state.RunId), "packet RunId is invalid")
	requireCondition(routeCoinsCollected % 1 == 0 and routeCoinsCollected >= 0 and routeCoinsCollected <= 160, "packet coin total is invalid")
	requireCondition(obstacleHits % 1 == 0 and obstacleHits >= 0 and obstacleHits <= 18, "packet hit total is invalid")
	requireCondition(#entries <= RUNTIME.MaximumCandidatesPerUpdate, "packet entry count exceeds the bound")
	if eventKind == "Delta" then
		requireCondition(#entries >= 1, "Delta must contain an entry")
	else
		requireCondition(#entries == 0, eventKind .. " must have empty Entries")
	end
	if invalidated then
		requireCondition(eventKind == "Seal" and routeCoinsCollected == 0, "invalidated packet shape is invalid")
	end

	state.OutboundEventSequence += 1
	local frozenEntries = copyAndFreezeEntries(entries)
	local packet = table.freeze({
		Version = 1,
		CourseId = COURSE_ID,
		RunId = state.RunId,
		EventSequence = state.OutboundEventSequence,
		EventKind = eventKind,
		Entries = frozenEntries,
		RouteCoinsCollected = routeCoinsCollected,
		ObstacleHits = obstacleHits,
		Invalidated = invalidated,
	})
	local ok = pcall(function()
		(remote :: RemoteEvent):FireClient(state.Player, packet)
	end)
	if ok then
		state.PresentedCoinCount = routeCoinsCollected
		state.PresentedObstacleHits = obstacleHits
	end
	return ok
end

local function invalidateState(state: State, reason: string)
	if state.Cleared then
		return
	end
	state.Invalidated = true
	state.Armed = false
	state.Sealed = true
	state.RewardEligibleCoinCount = 0
	state.ActiveSpeedCap = nil
	state.SpeedCapExpiry = nil
	warnOnce(state, reason)
	if state.Began and not state.InvalidatedSealSent then
		state.InvalidatedSealSent = true
		sendPacket(state, "Seal", {}, 0, state.ObstacleHitCount, true)
	end
end

function FrostTrailRouteContentController.invalidate(state: State, reason: string)
	invalidateState(state, if type(reason) == "string" and reason ~= "" then reason else "route-content adapter failure")
end

local function validateBoundedResolvedIdentity(resolved: ResolvedContent): (boolean, string?)
	if not table.isfrozen(resolved) then
		return false, "resolved content is mutable"
	elseif resolved.World.Parent ~= Workspace
		or resolved.World.Name ~= FrostTrailConfig.WorldModelName
		or resolved.Gameplay.Parent ~= resolved.World
		or resolved.Gameplay.Name ~= "Gameplay"
		or resolved.Gameplay.ClassName ~= "Folder"
		or resolved.Coins.Parent ~= resolved.Gameplay
		or resolved.Coins.Name ~= "Coins"
		or resolved.Coins.ClassName ~= "Folder"
		or resolved.Obstacles.Parent ~= resolved.Gameplay
		or resolved.Obstacles.Name ~= "Obstacles"
		or resolved.Obstacles.ClassName ~= "Folder"
	then
		return false, "resolved content hierarchy changed"
	end
	local gameplayMatches = 0
	for _, child in ipairs(resolved.World:GetChildren()) do
		if child.Name == "Gameplay" then
			gameplayMatches += 1
		end
	end
	if gameplayMatches ~= 1
		or resolved.World:FindFirstChild("Gameplay") ~= resolved.Gameplay
		or #resolved.Gameplay:GetChildren() ~= 2
		or resolved.Gameplay:FindFirstChild("Coins") ~= resolved.Coins
		or resolved.Gameplay:FindFirstChild("Obstacles") ~= resolved.Obstacles
	then
		return false, "resolved direct hierarchy identity changed"
	end
	local world = resolved.World
	if world:GetAttribute("CourseId") ~= COURSE_ID
		or world:GetAttribute("Playable") ~= false
		or world:GetAttribute("ActivationMode") ~= "StudioControlledTest"
		or world:GetAttribute("RouteContentVersion") ~= FrostTrailRouteContentConfig.ContentVersion
		or world:GetAttribute("RouteContentRuntimeEnabled") ~= true
		or world:GetAttribute("RouteContentRuntimeVersion") ~= FrostTrailRouteContentConfig.RuntimeVersion
		or world:GetAttribute("RouteCoinCount") ~= 160
		or world:GetAttribute("RouteObstacleCount") ~= 21
		or world:GetAttribute("RouteObstacleRowCount") ~= 18
		or world:GetAttribute("RouteGameplayPartCount") ~= 181
		or world:GetAttribute("BasePartCount") ~= 628
	then
		return false, "resolved world metadata changed"
	end
	return true, nil
end

local function validateContextIdentity(
	state: State,
	context: AuthoritativeContext,
	expectedPhase: string?
): (boolean, string?)
	local remote = boundRemote
	if not RunService:IsServer() or not RunService:IsStudio() then
		return false, "route runtime requires a Studio server"
	elseif remote == nil or not remoteIsExact(remote) then
		return false, "presentation remote identity changed"
	elseif state.Cleared then
		return false, "route state was cleared"
	elseif not context.IsCurrentSession then
		return false, "current session identity changed"
	elseif not context.IsResolvedCourseCurrent then
		return false, "resolved course identity changed"
	elseif context.Player ~= state.Player or context.RunId ~= state.RunId then
		return false, "player or RunId identity changed"
	elseif context.CourseId ~= COURSE_ID
		or context.Playable ~= false
		or context.ActivationMode ~= "StudioControlledTest"
	then
		return false, "course authorization changed"
	elseif context.ResolvedContent ~= state.ResolvedContent
		or context.World ~= state.ResolvedContent.World
	then
		return false, "resolved content identity changed"
	elseif expectedPhase ~= nil and context.Phase ~= expectedPhase then
		return false, "phase authorization changed"
	elseif context.CleanupStarted then
		return false, "cleanup already started"
	elseif context.Player.Parent ~= Players or context.Player.Character ~= context.Character then
		return false, "player Character identity changed"
	elseif context.Character.ClassName ~= "Model"
		or not context.Character:IsDescendantOf(Workspace)
		or context.Humanoid.Parent ~= context.Character
		or context.Sled.ClassName ~= "Model"
		or context.Sled.Parent ~= context.ActiveSleds
		or context.ActiveSleds.Parent ~= context.World
		or context.ActiveSleds.Name ~= "ActiveSleds"
		or context.ActiveSleds.ClassName ~= "Folder"
		or context.Root.Parent ~= context.Sled
		or context.Root.Name ~= "SledRoot"
		or context.DriverSeat.Parent ~= context.Sled
		or context.DriverSeat.Name ~= "DriverSeat"
	then
		return false, "authoritative hierarchy changed"
	end
	return validateBoundedResolvedIdentity(state.ResolvedContent)
end

local function manualServerOwnership(root: Part): (boolean, string?)
	local automaticOk, automatic = pcall(function(): boolean
		return root:GetNetworkOwnershipAuto()
	end)
	local ownerOk, owner = pcall(function(): Player?
		return root:GetNetworkOwner()
	end)
	if not automaticOk or not ownerOk then
		return false, "network ownership could not be verified"
	elseif automatic ~= false then
		return false, "network ownership became automatic"
	elseif owner ~= nil then
		return false, "network ownership belongs to a client"
	end
	return true, nil
end

local function validateRuntimeContext(state: State, context: AuthoritativeContext): (boolean, string?)
	local identityValid, identityReason = validateContextIdentity(state, context, "Descent")
	if not identityValid then
		return false, identityReason
	elseif context.ReleaseInProgress
		or not context.TuckActivationReady
		or not context.SpeedGovernorReleaseAuthorized
		or context.SpeedGovernorDisqualified
		or context.RampFreedomEntered
	then
		return false, "release or governor authorization changed"
	elseif context.Humanoid.Health <= 0 or context.DriverSeat.Occupant ~= context.Humanoid then
		return false, "authoritative occupant identity changed"
	elseif context.Root.ClassName ~= "Part"
		or context.Root.Shape ~= Enum.PartType.Block
		or not vectorsApproximatelyEqual(context.Root.Size, EXPECTED_ROOT_SIZE)
		or context.Root.Anchored
	then
		return false, "authoritative root collider changed"
	elseif context.GovernorAttachment.Name ~= "SledPhysicsAttachment"
		or context.GovernorAttachment.Parent ~= context.Root
	then
		return false, "governor attachment identity changed"
	end

	local governorForce = context.GovernorForce
	if governorForce == nil
		or governorForce.Name ~= "FrostTrailSpeedGovernorForce"
		or governorForce.Parent ~= context.Root
		or governorForce.Attachment0 ~= context.GovernorAttachment
		or governorForce.RelativeTo ~= Enum.ActuatorRelativeTo.World
		or governorForce.ApplyAtCenterOfMass ~= true
	then
		return false, "governor force identity changed"
	elseif context.SpeedProfile ~= FrostTrailConfig.Speed
		or not table.isfrozen(FrostTrailConfig.Speed)
		or FrostTrailConfig.Speed.Enabled ~= true
	then
		return false, "governor profile identity changed"
	end

	local root = context.Root
	local mass = root.AssemblyMass
	if not isFiniteCFrame(root.CFrame)
		or not isFiniteVector3(root.AssemblyLinearVelocity)
		or not isFiniteVector3(root.AssemblyAngularVelocity)
		or not isFiniteNumber(mass)
		or mass <= 0
	then
		return false, "authoritative root motion is invalid"
	end
	return manualServerOwnership(root)
end

function FrostTrailRouteContentController.createState(
	player: Player,
	runId: number,
	resolved: ResolvedContent
): (State?, string?)
	if not RunService:IsServer() or not RunService:IsStudio() then
		return nil, "route state may be created only on a Studio server"
	elseif not isPositiveInteger(runId) then
		return nil, "RunId must be a positive integer"
	elseif player.Parent ~= Players then
		return nil, "player is not active"
	end
	local identityValid, identityReason = validateBoundedResolvedIdentity(resolved)
	if not identityValid then
		return nil, identityReason
	end
	local state: State = {
		RunId = runId,
		Player = player,
		ResolvedContent = resolved,
		PreviousCFrame = nil,
		PreviousPosition = nil,
		PreviousVelocity = nil,
		PreviousAngularVelocity = nil,
		PreviousSampleAt = nil,
		MaximumLongitudinalSeen = -math.huge,
		CoinCursor = 1,
		ObstacleCursor = 1,
		EncounterCursor = 1,
		LastCandidateCount = 0,
		RetiredCoinIds = {},
		RetiredEncounterIds = {},
		CollectedContentIds = {},
		ResolvedEncounterIds = {},
		CollectedCoinCount = 0,
		ObstacleHitCount = 0,
		RewardEligibleCoinCount = 0,
		ActiveSpeedCap = nil,
		SpeedCapExpiry = nil,
		OutboundEventSequence = 0,
		PresentedCoinCount = 0,
		PresentedObstacleHits = 0,
		Began = false,
		Armed = false,
		Sealed = false,
		Invalidated = false,
		Cleared = false,
		NormalSealSent = false,
		InvalidatedSealSent = false,
		ClearSent = false,
		WarningEmitted = false,
	}
	return state, nil
end

function FrostTrailRouteContentController.begin(
	state: State,
	context: AuthoritativeContext
): (boolean, string?)
	if state.Began or state.OutboundEventSequence ~= 0 then
		return false, "Begin was already attempted"
	end
	local contextValid, contextReason = validateContextIdentity(state, context, "Countdown")
	if not contextValid then
		invalidateState(state, contextReason or "Begin authorization failed")
		return false, contextReason
	elseif boundRemote == nil or not remoteIsExact(boundRemote :: RemoteEvent) then
		invalidateState(state, "presentation remote is unavailable")
		return false, "presentation remote is unavailable"
	end

	state.Began = true
	if not sendPacket(state, "Begin", {}, 0, 0, false) then
		invalidateState(state, "Begin delivery failed")
		return false, "Begin delivery failed"
	end
	return true, nil
end

function FrostTrailRouteContentController.arm(
	state: State,
	context: AuthoritativeContext,
	now: number
): (boolean, string?)
	if not isFiniteNumber(now) then
		invalidateState(state, "arm time is non-finite")
		return false, "arm time is non-finite"
	elseif not state.Began or state.Armed or state.Sealed or state.Invalidated or state.Cleared then
		return false, "route state cannot be armed"
	end
	local contextValid, contextReason = validateRuntimeContext(state, context)
	if not contextValid then
		invalidateState(state, contextReason or "arm authorization failed")
		return false, contextReason
	end
	local fullValid, fullReason = pcall(validateResolvedUnsafe, state.ResolvedContent, context.World)
	if not fullValid then
		local reason = tostring(fullReason)
		invalidateState(state, reason)
		return false, reason
	end

	state.PreviousCFrame = nil
	state.PreviousPosition = nil
	state.PreviousVelocity = nil
	state.PreviousAngularVelocity = nil
	state.PreviousSampleAt = nil
	state.MaximumLongitudinalSeen = -math.huge
	state.ActiveSpeedCap = nil
	state.SpeedCapExpiry = nil
	state.Armed = true
	return true, nil
end

local function hermitePoint(
	startPosition: Vector3,
	endPosition: Vector3,
	startVelocity: Vector3,
	endVelocity: Vector3,
	deltaTime: number,
	u: number
): Vector3
	local uSquared = u * u
	local uCubed = uSquared * u
	local m0 = startVelocity * deltaTime
	local m1 = endVelocity * deltaTime
	return (2 * uCubed - 3 * uSquared + 1) * startPosition
		+ (uCubed - 2 * uSquared + u) * m0
		+ (-2 * uCubed + 3 * uSquared) * endPosition
		+ (uCubed - uSquared) * m1
end

local function clipChordToEvaluationInterval(
	startPoint: Vector3,
	endPoint: Vector3,
	globalStart: number,
	globalEnd: number
): SweepChord?
	local startForward = forwardCoordinate(startPoint)
	local endForward = forwardCoordinate(endPoint)
	local deltaForward = endForward - startForward
	local lower = 0
	local upper = 1
	if math.abs(deltaForward) <= RUNTIME.ParallelAxisEpsilon then
		if startForward < RUNTIME.EvaluationStartLongitudinal
			or startForward >= RUNTIME.EvaluationEndLongitudinal
		then
			return nil
		end
	else
		local boundaryA = (RUNTIME.EvaluationStartLongitudinal - startForward) / deltaForward
		local boundaryB = (RUNTIME.EvaluationEndLongitudinal - startForward) / deltaForward
		local intervalStart = math.min(boundaryA, boundaryB)
		local intervalEnd = math.max(boundaryA, boundaryB)
		lower = math.max(lower, intervalStart)
		upper = math.min(upper, intervalEnd)
		if upper < lower then
			return nil
		end
	end

	local clippedStart = startPoint:Lerp(endPoint, lower)
	local clippedEnd = startPoint:Lerp(endPoint, upper)
	local clippedGlobalStart = globalStart + (globalEnd - globalStart) * lower
	local clippedGlobalEnd = globalStart + (globalEnd - globalStart) * upper
	if not isFiniteVector3(clippedStart)
		or not isFiniteVector3(clippedEnd)
		or not isFiniteNumber(clippedGlobalStart)
		or not isFiniteNumber(clippedGlobalEnd)
	then
		fail("clipped sweep chord is non-finite")
	end
	return {
		StartPoint = clippedStart,
		EndPoint = clippedEnd,
		GlobalStart = clippedGlobalStart,
		GlobalEnd = clippedGlobalEnd,
	}
end

local function buildSweepChords(
	previousPosition: Vector3,
	currentCFrame: CFrame,
	previousVelocity: Vector3,
	currentVelocity: Vector3,
	deltaTime: number
): ({ SweepChord }, number, number)
	local maximumSubsteps = if deltaTime <= RUNTIME.MaximumEvaluationDeltaSeconds
		then RUNTIME.MaximumSweepSubsteps
		else FrostTrailRouteContentConfig.MaximumRecoverableSweepSubsteps
	local substepCount = math.ceil(deltaTime / RUNTIME.MaximumSweepSubstepSeconds)
	requireCondition(substepCount % 1 == 0, "sweep substep count is not integral")
	requireCondition(substepCount >= 1 and substepCount <= maximumSubsteps, "sweep substep count exceeds the bound")
	local points: { Vector3 } = {}
	local minimumForward = math.huge
	local maximumForward = -math.huge
	for index = 0, substepCount do
		local u = index / substepCount
		local point = hermitePoint(
			previousPosition,
			currentCFrame.Position,
			previousVelocity,
			currentVelocity,
			deltaTime,
			u
		)
		requireCondition(isFiniteVector3(point), "Hermite sweep point is non-finite")
		local longitudinal = forwardCoordinate(point)
		requireCondition(isFiniteNumber(longitudinal), "Hermite longitudinal is non-finite")
		minimumForward = math.min(minimumForward, longitudinal)
		maximumForward = math.max(maximumForward, longitudinal)
		table.insert(points, point)
	end

	local chords: { SweepChord } = {}
	for index = 1, substepCount do
		local globalStart = (index - 1) / substepCount
		local globalEnd = index / substepCount
		local chord = clipChordToEvaluationInterval(points[index], points[index + 1], globalStart, globalEnd)
		if chord ~= nil then
			table.insert(chords, chord)
		end
	end
	return chords, minimumForward, maximumForward
end

local function horizontalSpeed(velocity: Vector3): number
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
end

local function hasAnyMovementSample(state: State): boolean
	return state.PreviousCFrame ~= nil
		or state.PreviousPosition ~= nil
		or state.PreviousVelocity ~= nil
		or state.PreviousAngularVelocity ~= nil
		or state.PreviousSampleAt ~= nil
end

local function hasCompleteMovementSample(state: State): boolean
	return state.PreviousCFrame ~= nil
		and state.PreviousPosition ~= nil
		and state.PreviousVelocity ~= nil
		and state.PreviousAngularVelocity ~= nil
		and state.PreviousSampleAt ~= nil
end

local function captureMovementSample(state: State, root: Part, sampleAt: number)
	local currentCFrame = root.CFrame
	local currentPosition = root.Position
	local currentVelocity = root.AssemblyLinearVelocity
	local currentAngularVelocity = root.AssemblyAngularVelocity
	requireCondition(
		isFiniteNumber(sampleAt)
			and isFiniteCFrame(currentCFrame)
			and isFiniteVector3(currentPosition)
			and isFiniteVector3(currentVelocity)
			and isFiniteVector3(currentAngularVelocity),
		"movement sample is non-finite"
	)
	requireCondition(
		(currentCFrame.Position - currentPosition).Magnitude <= 0.0001,
		"movement sample position is inconsistent"
	)
	state.PreviousCFrame = currentCFrame
	state.PreviousPosition = currentPosition
	state.PreviousVelocity = currentVelocity
	state.PreviousAngularVelocity = currentAngularVelocity
	state.PreviousSampleAt = sampleAt
	local currentLongitudinal = forwardCoordinate(currentPosition)
	requireCondition(isFiniteNumber(currentLongitudinal), "current longitudinal is non-finite")
	state.MaximumLongitudinalSeen = math.max(state.MaximumLongitudinalSeen, currentLongitudinal)
end

local function validateMovement(
	state: State,
	context: AuthoritativeContext,
	deltaTime: number
): (CFrame?, Vector3?, Vector3?, Vector3?, string?)
	local previousCFrame = state.PreviousCFrame
	local previousPosition = state.PreviousPosition
	local previousVelocity = state.PreviousVelocity
	local previousAngularVelocity = state.PreviousAngularVelocity
	if previousCFrame == nil
		or previousPosition == nil
		or previousVelocity == nil
		or previousAngularVelocity == nil
		or state.PreviousSampleAt == nil
	then
		return nil, nil, nil, nil, "trusted movement baseline is missing"
	elseif not isFiniteNumber(deltaTime) or deltaTime <= 0 then
		return nil, nil, nil, nil, "evaluation delta is outside the bound"
	end

	local currentCFrame = context.Root.CFrame
	local currentVelocity = context.Root.AssemblyLinearVelocity
	local currentAngularVelocity = context.Root.AssemblyAngularVelocity
	if not isFiniteCFrame(previousCFrame)
		or not isFiniteCFrame(currentCFrame)
		or not isFiniteVector3(previousPosition)
		or not isFiniteVector3(previousVelocity)
		or not isFiniteVector3(currentVelocity)
		or not isFiniteVector3(previousAngularVelocity)
		or not isFiniteVector3(currentAngularVelocity)
	then
		return nil, nil, nil, nil, "movement endpoints are non-finite"
	elseif (previousCFrame.Position - previousPosition).Magnitude > 0.0001 then
		return nil, nil, nil, nil, "trusted movement baseline position changed"
	end

	local previousHorizontalSpeed = horizontalSpeed(previousVelocity)
	local currentHorizontalSpeed = horizontalSpeed(currentVelocity)
	local previousTotalSpeed = previousVelocity.Magnitude
	local currentTotalSpeed = currentVelocity.Magnitude
	local displacement = (currentCFrame.Position - previousPosition).Magnitude
	if not isFiniteNumber(previousHorizontalSpeed)
		or not isFiniteNumber(currentHorizontalSpeed)
		or not isFiniteNumber(previousTotalSpeed)
		or not isFiniteNumber(currentTotalSpeed)
		or not isFiniteNumber(displacement)
	then
		return nil, nil, nil, nil, "movement bounds are non-finite"
	elseif previousHorizontalSpeed > RUNTIME.MaximumHorizontalSpeedStudsPerSecond
		or currentHorizontalSpeed > RUNTIME.MaximumHorizontalSpeedStudsPerSecond
		or previousTotalSpeed > RUNTIME.MaximumTotalSpeedStudsPerSecond
		or currentTotalSpeed > RUNTIME.MaximumTotalSpeedStudsPerSecond
		or displacement > RUNTIME.MovementSlackStuds + RUNTIME.MaximumTotalSpeedStudsPerSecond * deltaTime
	then
		return nil, nil, nil, nil, "movement integrity bound exceeded"
	end
	return previousCFrame, previousPosition, previousVelocity, previousAngularVelocity, nil
end

local function binaryUpperBound(descriptors: { any }, forwardMaximum: number): number
	local low = 1
	local high = #descriptors
	local result = 0
	while low <= high do
		local midpoint = math.floor((low + high) * 0.5)
		if descriptors[midpoint].ForwardMinimum <= forwardMaximum then
			result = midpoint
			low = midpoint + 1
		else
			high = midpoint - 1
		end
	end
	return result
end

local function queryCandidates(
	state: State,
	sweepMinimum: number,
	sweepMaximum: number
): ({ CoinDescriptor }, { ObstacleDescriptor }, string?)
	local resolved = state.ResolvedContent
	local paddedMinimum = sweepMinimum - RUNTIME.BroadphasePaddingStuds
	local paddedMaximum = sweepMaximum + RUNTIME.BroadphasePaddingStuds
	local coinCandidates: { CoinDescriptor } = {}
	local obstacleCandidates: { ObstacleDescriptor } = {}
	local candidateCount = 0

	local coinUpper = binaryUpperBound(resolved.CoinDescriptors, paddedMaximum)
	for index = state.CoinCursor, coinUpper do
		local descriptor = resolved.CoinDescriptors[index]
		if not state.CollectedContentIds[descriptor.ContentId]
			and not state.RetiredCoinIds[descriptor.ContentId]
			and descriptor.ForwardMaximum >= paddedMinimum
		then
			candidateCount += 1
			if candidateCount > RUNTIME.MaximumCandidatesPerUpdate then
				return {}, {}, "candidate bound exceeded"
			end
			table.insert(coinCandidates, descriptor)
		end
	end

	local encounterUpper = binaryUpperBound(resolved.EncounterDescriptors, paddedMaximum)
	for index = state.EncounterCursor, encounterUpper do
		local encounter = resolved.EncounterDescriptors[index]
		if not state.ResolvedEncounterIds[encounter.EncounterId]
			and not state.RetiredEncounterIds[encounter.EncounterId]
			and encounter.ForwardMaximum >= paddedMinimum
		then
			for _, descriptor in ipairs(encounter.Parts) do
				if descriptor.ForwardMinimum <= paddedMaximum
					and descriptor.ForwardMaximum >= paddedMinimum
				then
					candidateCount += 1
					if candidateCount > RUNTIME.MaximumCandidatesPerUpdate then
						return {}, {}, "candidate bound exceeded"
					end
					table.insert(obstacleCandidates, descriptor)
				end
			end
		end
	end
	state.LastCandidateCount = candidateCount
	return coinCandidates, obstacleCandidates, nil
end

local function segmentSphereEntry(startPoint: Vector3, endPoint: Vector3, center: Vector3, radius: number): number?
	local relativeStart = startPoint - center
	local radiusSquared = radius * radius
	local constant = relativeStart:Dot(relativeStart) - radiusSquared
	requireCondition(isFiniteNumber(constant), "coin sphere constant is non-finite")
	if constant <= 0 then
		return 0
	end
	local direction = endPoint - startPoint
	local quadratic = direction:Dot(direction)
	requireCondition(isFiniteNumber(quadratic), "coin sphere quadratic coefficient is non-finite")
	if quadratic <= RUNTIME.ParallelAxisEpsilon then
		return nil
	end
	local linear = 2 * relativeStart:Dot(direction)
	local discriminant = linear * linear - 4 * quadratic * constant
	requireCondition(isFiniteNumber(linear), "coin sphere linear coefficient is non-finite")
	requireCondition(isFiniteNumber(discriminant), "coin sphere discriminant is non-finite")
	if discriminant < 0 then
		return nil
	end
	local root = (-linear - math.sqrt(discriminant)) / (2 * quadratic)
	requireCondition(isFiniteNumber(root), "coin sphere solution is non-finite")
	if root < 0 or root > 1 then
		return nil
	end
	return root
end

local function slabAxis(
	position: number,
	direction: number,
	extent: number,
	entryTime: number,
	exitTime: number
): (number?, number?)
	if not isFiniteNumber(position) or not isFiniteNumber(direction) or not isFiniteNumber(extent) then
		return nil, nil
	elseif math.abs(direction) <= RUNTIME.ParallelAxisEpsilon then
		if position < -extent or position > extent then
			return nil, nil
		end
		return entryTime, exitTime
	end
	local first = (-extent - position) / direction
	local second = (extent - position) / direction
	if first > second then
		first, second = second, first
	end
	entryTime = math.max(entryTime, first)
	exitTime = math.min(exitTime, second)
	if not isFiniteNumber(entryTime) or not isFiniteNumber(exitTime) or entryTime > exitTime then
		return nil, nil
	end
	return entryTime, exitTime
end

local function segmentExpandedBoxEntry(
	startPoint: Vector3,
	endPoint: Vector3,
	descriptor: ObstacleDescriptor,
	previousRootCFrame: CFrame,
	currentRootCFrame: CFrame,
	rotationPadding: number
): number?
	local obstacleCFrame = descriptor.CFrame
	local localStart = obstacleCFrame:PointToObjectSpace(startPoint)
	local localEnd = obstacleCFrame:PointToObjectSpace(endPoint)
	local direction = localEnd - localStart
	if not isFiniteVector3(localStart) or not isFiniteVector3(localEnd) or not isFiniteVector3(direction) then
		fail(descriptor.ContentId .. " produced a non-finite local sweep")
	end

	local rootHalfSize = RUNTIME.SledRootHalfSize
	local function rootSupport(axisWorld: Vector3, rootCFrame: CFrame): number
		local support = math.abs(axisWorld:Dot(rootCFrame.RightVector)) * rootHalfSize.X
			+ math.abs(axisWorld:Dot(rootCFrame.UpVector)) * rootHalfSize.Y
			+ math.abs(axisWorld:Dot(rootCFrame.LookVector)) * rootHalfSize.Z
		requireCondition(isFiniteNumber(support), descriptor.ContentId .. " root support is non-finite")
		return support
	end

	local halfSize = descriptor.Size * 0.5
	local rightSupport = math.max(
		rootSupport(obstacleCFrame.RightVector, previousRootCFrame),
		rootSupport(obstacleCFrame.RightVector, currentRootCFrame)
	)
	local upSupport = math.max(
		rootSupport(obstacleCFrame.UpVector, previousRootCFrame),
		rootSupport(obstacleCFrame.UpVector, currentRootCFrame)
	)
	local lookSupport = math.max(
		rootSupport(obstacleCFrame.LookVector, previousRootCFrame),
		rootSupport(obstacleCFrame.LookVector, currentRootCFrame)
	)
	local padding = RUNTIME.ObstacleContactPaddingStuds + rotationPadding
	local extents = Vector3.new(
		halfSize.X + rightSupport + padding,
		halfSize.Y + upSupport + padding,
		halfSize.Z + lookSupport + padding
	)
	requireCondition(isFiniteVector3(extents), descriptor.ContentId .. " expanded extents are non-finite")

	local entryTime = 0
	local exitTime = 1
	local nextEntry, nextExit = slabAxis(localStart.X, direction.X, extents.X, entryTime, exitTime)
	if nextEntry == nil or nextExit == nil then
		return nil
	end
	entryTime, exitTime = nextEntry, nextExit
	nextEntry, nextExit = slabAxis(localStart.Y, direction.Y, extents.Y, entryTime, exitTime)
	if nextEntry == nil or nextExit == nil then
		return nil
	end
	entryTime, exitTime = nextEntry, nextExit
	nextEntry, nextExit = slabAxis(localStart.Z, direction.Z, extents.Z, entryTime, exitTime)
	if nextEntry == nil or nextExit == nil then
		return nil
	end
	entryTime = nextEntry
	if entryTime < 0 or entryTime > 1 then
		return nil
	end
	return entryTime
end

local function calculateRotationPadding(
	previousCFrame: CFrame,
	currentCFrame: CFrame,
	previousAngularVelocity: Vector3,
	currentAngularVelocity: Vector3,
	deltaTime: number
): number
	local relativeRotation = previousCFrame.Rotation:ToObjectSpace(currentCFrame.Rotation)
	local axis, rawEndpointAngle = relativeRotation:ToAxisAngle()
	requireCondition(isFiniteVector3(axis) and isFiniteNumber(rawEndpointAngle), "relative rotation is non-finite")
	local endpointRotationAngle = math.clamp(math.abs(rawEndpointAngle), 0, math.pi)
	local rotationSweepAngle = math.min(
		math.pi,
		math.max(
			endpointRotationAngle,
			previousAngularVelocity.Magnitude * deltaTime,
			currentAngularVelocity.Magnitude * deltaTime
		)
	)
	requireCondition(isFiniteNumber(rotationSweepAngle), "rotation sweep is non-finite")
	local rootRadius = RUNTIME.SledRootHalfSize.Magnitude
	local padding = math.min(rootRadius, rootRadius * rotationSweepAngle * 0.5)
	requireCondition(isFiniteNumber(padding), "rotation padding is non-finite")
	return padding
end

local function earliestCoinEntry(descriptor: CoinDescriptor, chords: { SweepChord }): number?
	local earliest: number? = nil
	for _, chord in ipairs(chords) do
		local localEntry = segmentSphereEntry(
			chord.StartPoint,
			chord.EndPoint,
			descriptor.CFrame.Position,
			RUNTIME.CoinPickupRadiusStuds
		)
		if localEntry ~= nil then
			local globalEntry = chord.GlobalStart + (chord.GlobalEnd - chord.GlobalStart) * localEntry
			requireCondition(isFiniteNumber(globalEntry), descriptor.ContentId .. " entry time is non-finite")
			if earliest == nil or globalEntry < earliest then
				earliest = globalEntry
			end
		end
	end
	return earliest
end

local function earliestObstacleEntry(
	descriptor: ObstacleDescriptor,
	chords: { SweepChord },
	previousRootCFrame: CFrame,
	currentRootCFrame: CFrame,
	rotationPadding: number
): number?
	local earliest: number? = nil
	for _, chord in ipairs(chords) do
		local localEntry = segmentExpandedBoxEntry(
			chord.StartPoint,
			chord.EndPoint,
			descriptor,
			previousRootCFrame,
			currentRootCFrame,
			rotationPadding
		)
		if localEntry ~= nil then
			local globalEntry = chord.GlobalStart + (chord.GlobalEnd - chord.GlobalStart) * localEntry
			requireCondition(isFiniteNumber(globalEntry), descriptor.ContentId .. " entry time is non-finite")
			if earliest == nil or globalEntry < earliest then
				earliest = globalEntry
			end
		end
	end
	return earliest
end

local function orderContacts(
	coinCandidates: { CoinDescriptor },
	obstacleCandidates: { ObstacleDescriptor },
	chords: { SweepChord },
	previousRootCFrame: CFrame,
	currentRootCFrame: CFrame,
	rotationPadding: number
): { AcceptedContact }
	local contacts: { AcceptedContact } = {}
	for _, descriptor in ipairs(coinCandidates) do
		local entryTime = earliestCoinEntry(descriptor, chords)
		if entryTime ~= nil then
			table.insert(contacts, {
				Time = entryTime,
				ContentId = descriptor.ContentId,
				Coin = descriptor,
				Obstacle = nil,
			})
		end
	end

	local earliestByEncounter: { [string]: AcceptedContact } = {}
	for _, descriptor in ipairs(obstacleCandidates) do
		local entryTime = earliestObstacleEntry(
			descriptor,
			chords,
			previousRootCFrame,
			currentRootCFrame,
			rotationPadding
		)
		if entryTime ~= nil then
			local existing = earliestByEncounter[descriptor.EncounterId]
			if existing == nil
				or entryTime < existing.Time
				or (entryTime == existing.Time and descriptor.ContentId < existing.ContentId)
			then
				earliestByEncounter[descriptor.EncounterId] = {
					Time = entryTime,
					ContentId = descriptor.ContentId,
					Coin = nil,
					Obstacle = descriptor,
				}
			end
		end
	end
	for _, contact in earliestByEncounter do
		table.insert(contacts, contact)
	end

	table.sort(contacts, function(left: AcceptedContact, right: AcceptedContact): boolean
		if left.Time == right.Time then
			return left.ContentId < right.ContentId
		end
		return left.Time < right.Time
	end)

	local ordered: { AcceptedContact } = {}
	local index = 1
	while index <= #contacts do
		local clusterStart = contacts[index].Time
		local cluster: { AcceptedContact } = {}
		while index <= #contacts and contacts[index].Time <= clusterStart + RUNTIME.TimeOfImpactEpsilon do
			table.insert(cluster, contacts[index])
			index += 1
		end
		table.sort(cluster, function(left: AcceptedContact, right: AcceptedContact): boolean
			local leftIsObstacle = left.Obstacle ~= nil
			local rightIsObstacle = right.Obstacle ~= nil
			if leftIsObstacle ~= rightIsObstacle then
				return leftIsObstacle
			elseif left.Time ~= right.Time then
				return left.Time < right.Time
			end
			return left.ContentId < right.ContentId
		end)
		for _, contact in ipairs(cluster) do
			table.insert(ordered, contact)
		end
	end
	return ordered
end

local function expireSpeedCap(state: State, now: number)
	local expiry = state.SpeedCapExpiry
	if expiry ~= nil and now >= expiry then
		state.ActiveSpeedCap = nil
		state.SpeedCapExpiry = nil
	end
end

local function applyObstaclePenalty(
	state: State,
	descriptor: ObstacleDescriptor,
	currentHorizontalSpeed: number,
	now: number
): number
	expireSpeedCap(state, now)
	local speedLoss = if descriptor.ObstacleKind == "IceBlocker"
		then RUNTIME.IceBlockerSpeedLoss
		else RUNTIME.HopBarrierSpeedLoss
	local minimumCap = if descriptor.ObstacleKind == "IceBlocker"
		then RUNTIME.IceBlockerMinimumSpeedCap
		else RUNTIME.HopBarrierMinimumSpeedCap
	local duration = if descriptor.ObstacleKind == "IceBlocker"
		then RUNTIME.IceBlockerPenaltySeconds
		else RUNTIME.HopBarrierPenaltySeconds
	local candidateCap = math.max(minimumCap, currentHorizontalSpeed - speedLoss)
	local candidateExpiry = now + duration
	local existingCap = state.ActiveSpeedCap
	local existingExpiry = state.SpeedCapExpiry
	local effectiveBefore = if existingCap ~= nil and existingExpiry ~= nil and now < existingExpiry
		then math.min(currentHorizontalSpeed, existingCap)
		else currentHorizontalSpeed
	local finalCap = if existingCap ~= nil and existingExpiry ~= nil and now < existingExpiry
		then math.min(existingCap, candidateCap)
		else candidateCap
	local finalExpiry = if existingExpiry ~= nil and now < existingExpiry
		then math.max(existingExpiry, candidateExpiry)
		else candidateExpiry
	local effectiveAfter = math.min(effectiveBefore, candidateCap)
	local marginalLoss = math.max(0, effectiveBefore - effectiveAfter)
	requireCondition(
		isFiniteNumber(finalCap) and isFiniteNumber(finalExpiry) and isFiniteNumber(marginalLoss),
		"obstacle speed-cap math is non-finite"
	)
	state.ActiveSpeedCap = finalCap
	state.SpeedCapExpiry = finalExpiry
	return marginalLoss
end

local function applyContacts(
	state: State,
	context: AuthoritativeContext,
	contacts: { AcceptedContact },
	now: number
)
	if #contacts == 0 then
		return
	end
	local ownerValid, ownerReason = manualServerOwnership(context.Root)
	if not ownerValid then
		fail(ownerReason or "manual server ownership changed before contact acceptance")
	end

	local entries: { PacketEntry } = {}
	local currentHorizontalSpeed = horizontalSpeed(context.Root.AssemblyLinearVelocity)
	for _, contact in ipairs(contacts) do
		local obstacle = contact.Obstacle
		local coin = contact.Coin
		if obstacle ~= nil then
			if not state.ResolvedEncounterIds[obstacle.EncounterId]
				and not state.RetiredEncounterIds[obstacle.EncounterId]
			then
				state.ResolvedEncounterIds[obstacle.EncounterId] = true
				state.ObstacleHitCount += 1
				requireCondition(state.ObstacleHitCount <= RUNTIME.MaximumObstacleEncounters, "obstacle-hit count overflow")
				local marginalLoss = applyObstaclePenalty(state, obstacle, currentHorizontalSpeed, now)
				local entry: ObstacleHitEntry = table.freeze({
					Kind = "ObstacleHit",
					ContentId = obstacle.ContentId,
					EncounterId = obstacle.EncounterId,
					ObstacleKind = obstacle.ObstacleKind,
					SpeedLoss = marginalLoss,
				})
				table.insert(entries, entry)
			end
		elseif coin ~= nil
			and not state.CollectedContentIds[coin.ContentId]
			and not state.RetiredCoinIds[coin.ContentId]
		then
			state.CollectedContentIds[coin.ContentId] = true
			state.CollectedCoinCount += 1
			requireCondition(state.CollectedCoinCount <= RUNTIME.MaximumRouteCoins, "coin count overflow")
			state.RewardEligibleCoinCount = state.CollectedCoinCount
			local entry: CoinCollectedEntry = table.freeze({
				Kind = "CoinCollected",
				ContentId = coin.ContentId,
			})
			table.insert(entries, entry)
		end
	end
	if #entries > 0 and not sendPacket(
		state,
		"Delta",
		entries,
		state.CollectedCoinCount,
		state.ObstacleHitCount,
		false
	) then
		fail("Delta delivery failed")
	end
end

local function retirePassedContent(state: State)
	local maximum = state.MaximumLongitudinalSeen
	local resolved = state.ResolvedContent
	local coinUpper = binaryUpperBound(resolved.CoinDescriptors, maximum)
	for index = state.CoinCursor, coinUpper do
		local descriptor = resolved.CoinDescriptors[index]
		if not state.CollectedContentIds[descriptor.ContentId]
			and maximum > descriptor.ForwardMaximum + 0.05
		then
			state.RetiredCoinIds[descriptor.ContentId] = true
		end
	end
	while state.CoinCursor <= #resolved.CoinDescriptors do
		local descriptor = resolved.CoinDescriptors[state.CoinCursor]
		if not state.CollectedContentIds[descriptor.ContentId]
			and not state.RetiredCoinIds[descriptor.ContentId]
		then
			break
		end
		state.CoinCursor += 1
	end

	local encounterUpper = binaryUpperBound(resolved.EncounterDescriptors, maximum)
	for index = state.EncounterCursor, encounterUpper do
		local descriptor = resolved.EncounterDescriptors[index]
		if not state.ResolvedEncounterIds[descriptor.EncounterId]
			and maximum > descriptor.ForwardMaximum + 0.05
		then
			state.RetiredEncounterIds[descriptor.EncounterId] = true
		end
	end
	while state.EncounterCursor <= #resolved.EncounterDescriptors do
		local descriptor = resolved.EncounterDescriptors[state.EncounterCursor]
		if not state.ResolvedEncounterIds[descriptor.EncounterId]
			and not state.RetiredEncounterIds[descriptor.EncounterId]
		then
			break
		end
		state.EncounterCursor += 1
	end
	while state.ObstacleCursor <= #resolved.ObstacleDescriptors do
		local descriptor = resolved.ObstacleDescriptors[state.ObstacleCursor]
		if not state.ResolvedEncounterIds[descriptor.EncounterId]
			and not state.RetiredEncounterIds[descriptor.EncounterId]
		then
			break
		end
		state.ObstacleCursor += 1
	end
end

local function fullLifecycleValidation(
	state: State,
	context: AuthoritativeContext,
	requireRuntimeAuthorization: boolean
): (boolean, string?)
	local contextValid, contextReason
	if requireRuntimeAuthorization then
		contextValid, contextReason = validateRuntimeContext(state, context)
	else
		contextValid, contextReason = validateContextIdentity(state, context, nil)
	end
	if not contextValid then
		return false, contextReason
	end
	local fullValid, fullReason = pcall(validateResolvedUnsafe, state.ResolvedContent, context.World)
	if not fullValid then
		return false, tostring(fullReason)
	end
	return true, nil
end

function FrostTrailRouteContentController.sealProvisional(state: State, context: AuthoritativeContext)
	if state.Cleared or state.Invalidated or state.Sealed then
		return
	elseif not state.Began or not state.Armed then
		invalidateState(state, "provisional seal requested for an unarmed state")
		return
	end
	local valid, reason = fullLifecycleValidation(state, context, true)
	if not valid then
		invalidateState(state, reason or "provisional seal validation failed")
		return
	end

	state.Armed = false
	state.Sealed = true
	state.ActiveSpeedCap = nil
	state.SpeedCapExpiry = nil
	state.RewardEligibleCoinCount = state.CollectedCoinCount
	if not sendPacket(
		state,
		"Seal",
		{},
		state.CollectedCoinCount,
		state.ObstacleHitCount,
		false
	) then
		invalidateState(state, "provisional Seal delivery failed")
		return
	end
	state.NormalSealSent = true
end

function FrostTrailRouteContentController.captureFinalRouteCoins(
	state: State,
	context: AuthoritativeContext
): number
	if state.Cleared or state.Invalidated then
		return 0
	elseif not state.Began or not state.Sealed or not state.NormalSealSent then
		invalidateState(state, "final route count was captured before a normal provisional seal")
		return 0
	end
	local valid, reason = fullLifecycleValidation(state, context, false)
	if not valid then
		invalidateState(state, reason or "final route-content validation failed")
		return 0
	elseif state.RewardEligibleCoinCount ~= state.CollectedCoinCount
		or state.RewardEligibleCoinCount < 0
		or state.RewardEligibleCoinCount > RUNTIME.MaximumRouteCoins
		or state.RewardEligibleCoinCount % 1 ~= 0
	then
		invalidateState(state, "final route count is invalid")
		return 0
	end
	return state.RewardEligibleCoinCount
end

local function clearState(state: State, abort: boolean)
	if state.Cleared then
		return
	end
	state.Armed = false
	state.Sealed = true
	state.ActiveSpeedCap = nil
	state.SpeedCapExpiry = nil
	if abort then
		state.RewardEligibleCoinCount = 0
	end
	if state.Began and not state.ClearSent then
		state.ClearSent = true
		if not sendPacket(
			state,
			"Clear",
			{},
			state.PresentedCoinCount,
			state.PresentedObstacleHits,
			false
		) then
			warnOnce(state, "Clear delivery failed")
		end
	end
	state.Cleared = true
	state.PreviousCFrame = nil
	state.PreviousPosition = nil
	state.PreviousVelocity = nil
	state.PreviousAngularVelocity = nil
	state.PreviousSampleAt = nil
	table.clear(state.RetiredCoinIds)
	table.clear(state.RetiredEncounterIds)
	table.clear(state.CollectedContentIds)
	table.clear(state.ResolvedEncounterIds)
end

function FrostTrailRouteContentController.clearAbort(state: State)
	clearState(state, true)
end

function FrostTrailRouteContentController.clearAfterResult(state: State)
	clearState(state, false)
end

function FrostTrailRouteContentController.getActiveSpeedCap(state: State, now: number): number?
	if state.Cleared or state.Invalidated or state.Sealed or not state.Armed then
		return nil
	elseif not isFiniteNumber(now) then
		invalidateState(state, "speed-cap time is non-finite")
		return nil
	end
	expireSpeedCap(state, now)
	local cap = state.ActiveSpeedCap
	local expiry = state.SpeedCapExpiry
	if cap == nil and expiry == nil then
		return nil
	elseif cap == nil
		or expiry == nil
		or not isFiniteNumber(cap)
		or cap < 0
		or not isFiniteNumber(expiry)
		or now >= expiry
	then
		invalidateState(state, "speed-cap state is invalid")
		return nil
	end
	return cap
end

function FrostTrailRouteContentController.clampTargetSpeed(
	state: State,
	plannedTargetSpeed: number,
	now: number
): number
	if not isFiniteNumber(plannedTargetSpeed) or plannedTargetSpeed < 0 then
		invalidateState(state, "planned governor target is invalid")
		return plannedTargetSpeed
	end
	local cap = FrostTrailRouteContentController.getActiveSpeedCap(state, now)
	if cap == nil then
		return plannedTargetSpeed
	end
	return math.min(plannedTargetSpeed, cap)
end

local function updateUnsafe(
	state: State,
	context: AuthoritativeContext,
	deltaTime: number,
	now: number
)
	requireCondition(isFiniteNumber(now), "evaluation time is non-finite")
	requireCondition(isFiniteNumber(deltaTime) and deltaTime > 0, "Heartbeat delta is invalid")
	local contextValid, contextReason = validateRuntimeContext(state, context)
	requireCondition(contextValid, contextReason or "route-content authorization failed")

	local hasAnySample = hasAnyMovementSample(state)
	local hasCompleteSample = hasCompleteMovementSample(state)
	requireCondition(not hasAnySample or hasCompleteSample, "trusted movement baseline is incomplete")
	if not hasCompleteSample then
		captureMovementSample(state, context.Root, now)
		return
	end

	local previousSampleAt = state.PreviousSampleAt :: number
	local measuredDelta = now - previousSampleAt
	local previousCFrame, previousPosition, previousVelocity, previousAngularVelocity, movementReason = validateMovement(
		state,
		context,
		measuredDelta
	)
	requireCondition(
		previousCFrame ~= nil
			and previousPosition ~= nil
			and previousVelocity ~= nil
			and previousAngularVelocity ~= nil,
		movementReason or "movement validation failed"
	)

	local exactPreviousCFrame = previousCFrame :: CFrame
	local exactPreviousPosition = previousPosition :: Vector3
	local exactPreviousVelocity = previousVelocity :: Vector3
	local exactPreviousAngularVelocity = previousAngularVelocity :: Vector3
	local currentCFrame = context.Root.CFrame
	local currentVelocity = context.Root.AssemblyLinearVelocity
	local currentAngularVelocity = context.Root.AssemblyAngularVelocity
	expireSpeedCap(state, now)
	if measuredDelta > FrostTrailRouteContentConfig.MaximumRecoverableEvaluationDeltaSeconds then
		local resynchronizedLongitudinal = forwardCoordinate(currentCFrame.Position)
		requireCondition(isFiniteNumber(resynchronizedLongitudinal), "resynchronized longitudinal is non-finite")
		captureMovementSample(state, context.Root, now)
		retirePassedContent(state)
		if resynchronizedLongitudinal >= RUNTIME.EvaluationEndLongitudinal then
			FrostTrailRouteContentController.sealProvisional(state, context)
		end
		return
	end
	local chords, minimumForward, maximumForward = buildSweepChords(
		exactPreviousPosition,
		currentCFrame,
		exactPreviousVelocity,
		currentVelocity,
		measuredDelta
	)

	if #chords > 0 then
		local evaluatedMinimum = math.huge
		local evaluatedMaximum = -math.huge
		for _, chord in ipairs(chords) do
			evaluatedMinimum = math.min(
				evaluatedMinimum,
				forwardCoordinate(chord.StartPoint),
				forwardCoordinate(chord.EndPoint)
			)
			evaluatedMaximum = math.max(
				evaluatedMaximum,
				forwardCoordinate(chord.StartPoint),
				forwardCoordinate(chord.EndPoint)
			)
		end
		requireCondition(
			isFiniteNumber(evaluatedMinimum) and isFiniteNumber(evaluatedMaximum),
			"evaluated sweep interval is non-finite"
		)
		local coinCandidates, obstacleCandidates, candidateReason = queryCandidates(
			state,
			evaluatedMinimum,
			evaluatedMaximum
		)
		requireCondition(candidateReason == nil, candidateReason or "candidate query failed")

		for _, descriptor in ipairs(coinCandidates) do
			requireCondition(
				descriptor.Part.Parent == state.ResolvedContent.Coins
					and state.ResolvedContent.Coins:FindFirstChild(descriptor.ContentId) == descriptor.Part,
				descriptor.ContentId .. " candidate identity changed"
			)
			validateCoinPart(descriptor.Part, descriptor)
		end
		for _, descriptor in ipairs(obstacleCandidates) do
			requireCondition(
				descriptor.Part.Parent == state.ResolvedContent.Obstacles
					and state.ResolvedContent.Obstacles:FindFirstChild(descriptor.ContentId) == descriptor.Part,
				descriptor.ContentId .. " candidate identity changed"
			)
			validateObstaclePart(descriptor.Part, descriptor)
		end

		local rotationPadding = calculateRotationPadding(
			exactPreviousCFrame,
			currentCFrame,
			exactPreviousAngularVelocity,
			currentAngularVelocity,
			measuredDelta
		)
		local contacts = orderContacts(
			coinCandidates,
			obstacleCandidates,
			chords,
			exactPreviousCFrame,
			currentCFrame,
			rotationPadding
		)
		applyContacts(state, context, contacts, now)
	end

	captureMovementSample(state, context.Root, now)
	retirePassedContent(state)

	if maximumForward >= RUNTIME.EvaluationEndLongitudinal then
		FrostTrailRouteContentController.sealProvisional(state, context)
	elseif maximumForward < RUNTIME.EvaluationStartLongitudinal and minimumForward < RUNTIME.EvaluationStartLongitudinal then
		-- The trusted endpoint state was updated above, but no out-of-range contact was considered.
		return
	end
end

function FrostTrailRouteContentController.update(
	state: State,
	context: AuthoritativeContext,
	deltaTime: number,
	now: number
)
	if not state.Armed or state.Sealed or state.Invalidated or state.Cleared then
		return
	end
	local measuredDelta: number? = nil
	local previousSampleAt = state.PreviousSampleAt
	if isFiniteNumber(now) and previousSampleAt ~= nil and isFiniteNumber(previousSampleAt) then
		measuredDelta = now - previousSampleAt
	end
	local ok, reason = pcall(updateUnsafe, state, context, deltaTime, now)
	if not ok then
		local deltaText = if measuredDelta ~= nil and isFiniteNumber(measuredDelta)
			then string.format("%.6f", measuredDelta)
			else "unavailable"
		invalidateState(state, string.format("evaluation delta=%s reason=%s", deltaText, tostring(reason)))
	end
end

return table.freeze(FrostTrailRouteContentController)
