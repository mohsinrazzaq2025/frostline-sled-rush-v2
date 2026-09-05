--!strict

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local WORLD = GameConfig.World
local PHYSICS = GameConfig.Physics
local PALETTE = GameConfig.Palette
local RUN = GameConfig.Run

local WorldBuilder = {}

local TRACK_SEGMENT_OVERLAP = 1.25
local START_CHUTE_LAST_TRACK_INDEX = 5
local START_CHUTE_BEND_SAMPLE_INDEX = 4
local START_CHUTE_BEND_RAISE = 0.25
local TRACK_SURFACE_ATTRIBUTE = "FrostlineTrackSurface"
local START_PAD_THICKNESS = 0.12
local START_PAD_SURFACE_GAP = 0.01
local MILESTONE_SURFACE_GAP = 0.03
local MINOR_MILESTONE_COLOR = Color3.fromRGB(83, 210, 238)
local MILESTONE_STROKE_COLOR = Color3.fromRGB(11, 27, 48)

type MajorMilestoneStyle = {
	AccentColor: Color3,
	BandSize: Vector3,
	BandTransparency: number,
	BeaconSize: Vector3,
	BeaconTransparency: number,
	LabelText: string,
	LabelSize: Vector2,
	LabelMaxDistance: number,
}

local MAJOR_MILESTONE_STYLES: { [number]: MajorMilestoneStyle } = {
	[500] = {
		AccentColor = Color3.fromRGB(72, 220, 255),
		BandSize = Vector3.new(WORLD.LandingWidth - 16, 0.12, 3.5),
		BandTransparency = 0.28,
		BeaconSize = Vector3.new(2, 16, 2),
		BeaconTransparency = 0.18,
		LabelText = "500 m",
		LabelSize = Vector2.new(180, 60),
		LabelMaxDistance = 260,
	},
	[1000] = {
		AccentColor = Color3.fromRGB(174, 120, 255),
		BandSize = Vector3.new(WORLD.LandingWidth - 10, 0.14, 5),
		BandTransparency = 0.22,
		BeaconSize = Vector3.new(2.4, 21, 2.4),
		BeaconTransparency = 0.12,
		LabelText = "1 KM",
		LabelSize = Vector2.new(210, 70),
		LabelMaxDistance = 300,
	},
	[1500] = {
		AccentColor = Color3.fromRGB(255, 205, 92),
		BandSize = Vector3.new(WORLD.LandingWidth - 4, 0.16, 6.5),
		BandTransparency = 0.16,
		BeaconSize = Vector3.new(2.8, 26, 2.8),
		BeaconTransparency = 0.08,
		LabelText = "1.5 KM",
		LabelSize = Vector2.new(240, 80),
		LabelMaxDistance = 340,
	},
}

local function disableTemplatePart(name: string)
	local templatePart = Workspace:FindFirstChild(name)
	if not templatePart or not templatePart:IsA("BasePart") then
		return
	end

	templatePart.Transparency = 1
	templatePart.CanCollide = false
	templatePart.CanTouch = false
	templatePart.CanQuery = false

	if templatePart:IsA("SpawnLocation") then
		templatePart.Enabled = false
	end
end

local function createPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	canCollide: boolean
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = canCollide
	part.CanTouch = true
	part.CanQuery = true
	part.CastShadow = true
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
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

local function samplePath(controlPoints: { Vector3 }, samplesPerCurve: number): { Vector3 }
	local sampled = {}

	for index = 1, #controlPoints - 1 do
		local p0 = controlPoints[math.max(1, index - 1)]
		local p1 = controlPoints[index]
		local p2 = controlPoints[index + 1]
		local p3 = controlPoints[math.min(#controlPoints, index + 2)]

		for sampleIndex = 0, samplesPerCurve - 1 do
			local alpha = sampleIndex / samplesPerCurve
			table.insert(sampled, catmullRom(p0, p1, p2, p3, alpha))
		end
	end

	table.insert(sampled, controlPoints[#controlPoints])
	return sampled
end

local function segmentSurfaceFrame(pointA: Vector3, pointB: Vector3): (CFrame, number)
	local direction = pointB - pointA
	local midpoint = (pointA + pointB) * 0.5
	local surfaceFrame = CFrame.lookAt(midpoint, midpoint + direction.Unit, Vector3.yAxis)
	return surfaceFrame, direction.Magnitude
end

local function createTrackCollisionPart(
	geometry: Folder,
	name: string,
	pointA: Vector3,
	pointB: Vector3
)
	local surfaceFrame, length = segmentSurfaceFrame(pointA, pointB)
	local collisionPart = createPart(
		geometry,
		name,
		Vector3.new(WORLD.TrackWidth, WORLD.TrackThickness, length),
		surfaceFrame * CFrame.new(0, -WORLD.TrackThickness * 0.5, 0),
		PALETTE.Ice,
		Enum.Material.Ice,
		true
	)
	collisionPart.Transparency = 1
	collisionPart.CastShadow = false
	collisionPart.CanTouch = false
	collisionPart:SetAttribute(TRACK_SURFACE_ATTRIBUTE, true)
	collisionPart.CustomPhysicalProperties = PhysicalProperties.new(
		PHYSICS.TrackDensity,
		PHYSICS.TrackFriction,
		PHYSICS.TrackElasticity,
		PHYSICS.TrackFrictionWeight,
		PHYSICS.TrackElasticityWeight
	)
end

local function buildStartChuteCollision(geometry: Folder, sampledPath: { Vector3 })
	-- These two faces meet only at downhill-steepening edges and remain above the
	-- decorative track faces and collidable mountain-bed surfaces.
	local chuteStart = sampledPath[1]
	local chuteBend = sampledPath[START_CHUTE_BEND_SAMPLE_INDEX] + Vector3.new(0, START_CHUTE_BEND_RAISE, 0)
	local followingSegmentStart = sampledPath[START_CHUTE_LAST_TRACK_INDEX + 1]
	local followingSegmentEnd = sampledPath[START_CHUTE_LAST_TRACK_INDEX + 2]
	local followingDirection = (followingSegmentEnd - followingSegmentStart).Unit
	local chuteEnd = followingSegmentStart - followingDirection * (TRACK_SEGMENT_OVERLAP * 0.5)

	createTrackCollisionPart(geometry, "StartChuteCollision_01", chuteStart, chuteBend)
	createTrackCollisionPart(geometry, "StartChuteCollision_02", chuteBend, chuteEnd)

	for index = 1, START_CHUTE_LAST_TRACK_INDEX do
		local track = geometry:FindFirstChild(string.format("Track_%02d", index))
		if not track or not track:IsA("BasePart") then
			error(string.format("Missing decorative Start-chute track Track_%02d", index))
		end
		track.CanCollide = false
	end
end

local function findLaunchRampTrackIndex(sampledPath: { Vector3 }): number
	for index = 1, #sampledPath - 1 do
		local pointA = sampledPath[index]
		local pointB = sampledPath[index + 1]
		if pointA.Z >= RUN.RampFreedomStartZ and pointB.Y > pointA.Y then
			return index
		end
	end

	error("Unable to identify the authored launch-ramp collision boundary")
end

local function overlappingTrackStartEdge(sampledPath: { Vector3 }, trackIndex: number): Vector3
	local segmentStart = sampledPath[trackIndex]
	local segmentEnd = sampledPath[trackIndex + 1]
	return segmentStart - (segmentEnd - segmentStart).Unit * (TRACK_SEGMENT_OVERLAP * 0.5)
end

local function buildDescentCollision(geometry: Folder, sampledPath: { Vector3 })
	local firstTrackIndex = START_CHUTE_LAST_TRACK_INDEX + 1
	local launchRampTrackIndex = findLaunchRampTrackIndex(sampledPath)
	local lastDescentTrackIndex = launchRampTrackIndex - 1
	local firstProxyStart = overlappingTrackStartEdge(sampledPath, firstTrackIndex)
	local rampCollisionStart = overlappingTrackStartEdge(sampledPath, launchRampTrackIndex)

	for trackIndex = firstTrackIndex, lastDescentTrackIndex do
		local pointA = if trackIndex == firstTrackIndex then firstProxyStart else sampledPath[trackIndex]
		local pointB = if trackIndex == lastDescentTrackIndex
			then rampCollisionStart
			else sampledPath[trackIndex + 1]

		createTrackCollisionPart(
			geometry,
			string.format("DescentCollision_%02d", trackIndex),
			pointA,
			pointB
		)

		local track = geometry:FindFirstChild(string.format("Track_%02d", trackIndex))
		if not track or not track:IsA("BasePart") then
			error(string.format("Missing decorative Descent track Track_%02d", trackIndex))
		end
		track.CanCollide = false
	end
end

local function buildStartPadVisual(geometry: Folder, markers: Folder, startTrigger: BasePart)
	local summitPlatform = geometry:FindFirstChild("SummitPlatform")
	if not summitPlatform or not summitPlatform:IsA("BasePart") then
		error("Missing SummitPlatform for StartPadVisual placement")
	end

	local summitTopY = summitPlatform.Position.Y + summitPlatform.Size.Y * 0.5
	local padPosition = Vector3.new(
		startTrigger.Position.X,
		summitTopY + START_PAD_SURFACE_GAP + START_PAD_THICKNESS * 0.5,
		startTrigger.Position.Z
	)
	local padCFrame = CFrame.new(padPosition) * startTrigger.CFrame.Rotation
	local startPadVisual = createPart(
		markers,
		"StartPadVisual",
		Vector3.new(startTrigger.Size.X, START_PAD_THICKNESS, startTrigger.Size.Z),
		padCFrame,
		startTrigger.Color,
		Enum.Material.Neon,
		false
	)
	startPadVisual.Transparency = 0.35
	startPadVisual.CastShadow = false
	startPadVisual.CanTouch = false
	startPadVisual.CanQuery = false
end

local function configureLighting()
	Lighting.ClockTime = 17.2
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(105, 122, 150)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 148, 174)
	Lighting.EnvironmentDiffuseScale = 0.35
	Lighting.EnvironmentSpecularScale = 0.55
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.28

	local atmosphere = Lighting:FindFirstChild("FrostlineAtmosphere") :: Atmosphere?
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "FrostlineAtmosphere"
		atmosphere.Parent = Lighting
	end
	atmosphere.Color = Color3.fromRGB(205, 225, 244)
	atmosphere.Decay = Color3.fromRGB(90, 111, 145)
	atmosphere.Density = 0.24
	atmosphere.Glare = 0.08
	atmosphere.Haze = 1.4

	local bloom = Lighting:FindFirstChild("FrostlineBloom") :: BloomEffect?
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Name = "FrostlineBloom"
		bloom.Parent = Lighting
	end
	bloom.Intensity = 0.22
	bloom.Size = 24
	bloom.Threshold = 1.1
end

local function createPine(parent: Instance, basePosition: Vector3, scale: number, alternate: boolean)
	local tree = Instance.new("Model")
	tree.Name = "Pine"
	tree.Parent = parent

	local trunk = createPart(
		tree,
		"Trunk",
		Vector3.new(1.8, 7, 1.8) * scale,
		CFrame.new(basePosition + Vector3.new(0, 3.5 * scale, 0)),
		PALETTE.Wood,
		Enum.Material.Wood,
		false
	)
	trunk.CanTouch = false

	local foliageColor = if alternate then PALETTE.PineLight else PALETTE.PineDark
	local layerSizes = {
		Vector3.new(12, 8, 12),
		Vector3.new(9, 7, 9),
		Vector3.new(6, 6, 6),
	}
	local layerHeights = { 7, 11, 14.5 }

	for index, layerSize in ipairs(layerSizes) do
		local foliage = createPart(
			tree,
			"Foliage" .. index,
			layerSize * scale,
			CFrame.new(basePosition + Vector3.new(0, layerHeights[index] * scale, 0)),
			foliageColor,
			Enum.Material.SmoothPlastic,
			false
		)
		foliage.Shape = Enum.PartType.Ball
		foliage.CanTouch = false
	end
end

local function createStartArch(parent: Instance)
	local arch = Instance.new("Model")
	arch.Name = "CandyCaneStartArch"
	arch.Parent = parent

	local origin = CFrame.new(0, 127, -265)
	local stripeHeight = 4

	for _, side in ipairs({ -1, 1 }) do
		for stripe = 0, 3 do
			local color = if stripe % 2 == 0 then PALETTE.Red else PALETTE.White
			createPart(
				arch,
				"PostStripe",
				Vector3.new(2.5, stripeHeight, 2.5),
				origin * CFrame.new(side * 15, 2 + stripe * stripeHeight, 0),
				color,
				Enum.Material.SmoothPlastic,
				true
			)
		end
	end

	for stripe = 0, 7 do
		local color = if stripe % 2 == 0 then PALETTE.White else PALETTE.Red
		createPart(
			arch,
			"BeamStripe",
			Vector3.new(4, 2.5, 2.5),
			origin * CFrame.new(-14 + stripe * 4, 17, 0),
			color,
			Enum.Material.SmoothPlastic,
			true
		)
	end

	local sign = createPart(
		arch,
		"FrostlineSign",
		Vector3.new(17, 5, 1),
		origin * CFrame.new(0, 17, -1.8),
		PALETTE.IceDeep,
		Enum.Material.SmoothPlastic,
		false
	)

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "SignGui"
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.LightInfluence = 0
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = 40
	surfaceGui.Parent = sign

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = "FROSTLINE"
	label.TextColor3 = PALETTE.White
	label.TextScaled = true
	label.Parent = surfaceGui
end

local function setMilestoneAttributes(instance: Instance, metres: number)
	instance:SetAttribute("DistanceMeters", metres)
	instance:SetAttribute("VisualOnly", true)
end

local function createMilestonePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	transparency: number,
	metres: number
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	setMilestoneAttributes(part, metres)
	part.Parent = parent
	return part
end

local function createMilestoneLabel(
	parent: BasePart,
	name: string,
	text: string,
	color: Color3,
	size: Vector2,
	worldOffset: Vector3,
	maxDistance: number,
	font: Enum.Font,
	metres: number
)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = name
	billboard.Size = UDim2.fromOffset(size.X, size.Y)
	billboard.StudsOffsetWorldSpace = worldOffset
	billboard.MaxDistance = maxDistance
	billboard.AlwaysOnTop = false
	setMilestoneAttributes(billboard, metres)
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = font
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeColor3 = MILESTONE_STROKE_COLOR
	label.TextStrokeTransparency = 0.12
	setMilestoneAttributes(label, metres)
	label.Parent = billboard
end

local function createMilestoneContainer(parent: Instance, metres: number, tierName: string): Folder
	local container = Instance.new("Folder")
	container.Name = string.format("Milestone_%04dm_%s", metres, tierName)
	setMilestoneAttributes(container, metres)
	container.Parent = parent
	return container
end

local function createMinorMilestone(parent: Instance, zPosition: number, metres: number)
	local container = createMilestoneContainer(parent, metres, "Minor")
	local bandHeight = 0.08
	local band = createMilestonePart(
		container,
		string.format("Band_%04dm", metres),
		Vector3.new(WORLD.LandingWidth - 28, bandHeight, 1.4),
		CFrame.new(0, WORLD.LandingTopY + MILESTONE_SURFACE_GAP + bandHeight * 0.5, zPosition),
		MINOR_MILESTONE_COLOR,
		0.5,
		metres
	)
	createMilestoneLabel(
		band,
		string.format("Label_%04dm", metres),
		string.format("%d m", metres),
		MINOR_MILESTONE_COLOR,
		Vector2.new(96, 34),
		Vector3.new(WORLD.LandingWidth * 0.34, 6, 0),
		120,
		Enum.Font.GothamBold,
		metres
	)
end

local function createMajorMilestone(
	parent: Instance,
	zPosition: number,
	metres: number,
	style: MajorMilestoneStyle
)
	local container = createMilestoneContainer(parent, metres, "Major")
	createMilestonePart(
		container,
		string.format("Band_%04dm", metres),
		style.BandSize,
		CFrame.new(
			0,
		WORLD.LandingTopY + MILESTONE_SURFACE_GAP + style.BandSize.Y * 0.5,
			zPosition
		),
		style.AccentColor,
		style.BandTransparency,
		metres
	)

	local rightBeacon: Part? = nil
	local beaconOffset = WORLD.LandingWidth * 0.5 - 7
	for _, side in ipairs({ -1, 1 }) do
		local sideName = if side == -1 then "Left" else "Right"
		local beacon = createMilestonePart(
			container,
			string.format("Beacon_%04dm_%s", metres, sideName),
			style.BeaconSize,
			CFrame.new(
				side * beaconOffset,
				WORLD.LandingTopY + MILESTONE_SURFACE_GAP + style.BeaconSize.Y * 0.5,
				zPosition
			),
			style.AccentColor,
			style.BeaconTransparency,
			metres
		)
		if side == 1 then
			rightBeacon = beacon
		end
	end

	local labelBeacon = rightBeacon
	if not labelBeacon then
		error(string.format("Missing right beacon for %dm milestone", metres))
	end
	createMilestoneLabel(
		labelBeacon,
		string.format("Label_%04dm", metres),
		style.LabelText,
		style.AccentColor,
		style.LabelSize,
		Vector3.new(0, style.BeaconSize.Y * 0.5 + 4, 0),
		style.LabelMaxDistance,
		Enum.Font.GothamBlack,
		metres
	)
end

local function buildDistanceMilestones(parent: Instance, launchZ: number)
	for metres = 100, WORLD.LandingMarkedDistanceMeters, 100 do
		local zPosition = launchZ + metres * WORLD.StudsPerMeter
		local majorStyle = MAJOR_MILESTONE_STYLES[metres]
		if majorStyle then
			createMajorMilestone(parent, zPosition, metres, majorStyle)
		else
			createMinorMilestone(parent, zPosition, metres)
		end
	end
end

local function buildCourse(world: Model, geometry: Folder, decor: Folder, markers: Folder)
	local sampledPath = samplePath(WORLD.PathPoints, WORLD.SamplesPerCurve)
	local treeCounter = 0

	for index = 1, #sampledPath - 1 do
		local pointA = sampledPath[index]
		local pointB = sampledPath[index + 1]
		local surfaceFrame, length = segmentSurfaceFrame(pointA, pointB)
		local overlapLength = length + TRACK_SEGMENT_OVERLAP

		createPart(
			geometry,
			string.format("MountainBed_%02d", index),
			Vector3.new(170, 14, overlapLength),
			surfaceFrame * CFrame.new(0, -7.05, 0),
			PALETTE.Snow,
			Enum.Material.Snow,
			true
		)

		local track = createPart(
			geometry,
			string.format("Track_%02d", index),
			Vector3.new(WORLD.TrackWidth, WORLD.TrackThickness, overlapLength),
			surfaceFrame * CFrame.new(0, -WORLD.TrackThickness * 0.5, 0),
			PALETTE.Ice,
			Enum.Material.Ice,
			true
		)
		track.CustomPhysicalProperties = PhysicalProperties.new(
			PHYSICS.TrackDensity,
			PHYSICS.TrackFriction,
			PHYSICS.TrackElasticity,
			PHYSICS.TrackFrictionWeight,
			PHYSICS.TrackElasticityWeight
		)

		for _, side in ipairs({ -1, 1 }) do
			local sideName = if side == -1 then "Left" else "Right"
			local bankOffset = WORLD.TrackWidth * 0.5 + WORLD.BankWidth * 0.5 - 0.75
			local bankCenterY = 3.2
			local bankFrame = surfaceFrame
				* CFrame.new(side * bankOffset, bankCenterY, 0)
				* CFrame.Angles(0, 0, math.rad(side * WORLD.BankAngleDegrees))

			local bank = createPart(
				geometry,
				string.format("%sBank_%02d", sideName, index),
				Vector3.new(WORLD.BankWidth, WORLD.BankThickness, overlapLength),
				bankFrame,
				PALETTE.Snow,
				Enum.Material.Snow,
				true
			)
			bank.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0, 100, 1)

			local railColor = if index % 2 == 0 then PALETTE.Red else PALETTE.White
			createPart(
				geometry,
				string.format("%sRail_%02d", sideName, index),
				Vector3.new(2.2, WORLD.RailHeight, overlapLength),
				surfaceFrame * CFrame.new(side * (WORLD.TrackWidth * 0.5 + 11.2), 6.2, 0),
				railColor,
				Enum.Material.SmoothPlastic,
				true
			)
		end

		if index % 5 == 0 and index < #sampledPath - 6 then
			for _, side in ipairs({ -1, 1 }) do
				treeCounter += 1
				local treeBase = surfaceFrame:PointToWorldSpace(Vector3.new(side * 67, 0, 0))
				createPine(decor, treeBase, 0.82 + (treeCounter % 3) * 0.1, treeCounter % 2 == 0)
			end
		end
	end

	buildStartChuteCollision(geometry, sampledPath)
	buildDescentCollision(geometry, sampledPath)

	local startTrigger = createPart(
		markers,
		"StartTrigger",
		Vector3.new(28, 1, 16),
		CFrame.new(0, 127, -246),
		Color3.fromRGB(64, 224, 200),
		Enum.Material.Neon,
		false
	)
	startTrigger.Transparency = 1
	startTrigger.CastShadow = false
	startTrigger.CanTouch = false
	startTrigger.CanQuery = false

	buildStartPadVisual(geometry, markers, startTrigger)

	local launchEdge = createPart(
		markers,
		"LaunchEdge",
		Vector3.new(WORLD.TrackWidth, 10, 2),
		CFrame.new(WORLD.PathPoints[#WORLD.PathPoints] + Vector3.new(0, 1, 0)),
		PALETTE.Gold,
		Enum.Material.Neon,
		false
	)
	launchEdge.Transparency = 0.35
	launchEdge.CanTouch = true

	world:SetAttribute("PathSampleCount", #sampledPath)
	world:SetAttribute("TrackStartZ", WORLD.PathPoints[1].Z)
	world:SetAttribute("LaunchZ", WORLD.PathPoints[#WORLD.PathPoints].Z)
end

local function buildSummit(geometry: Folder, decor: Folder)
	createPart(
		geometry,
		"SummitPlatform",
		Vector3.new(120, 8, 110),
		CFrame.new(0, 122, -305),
		PALETTE.Snow,
		Enum.Material.Snow,
		true
	)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, 126.5, -325)
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Transparency = 0.3
	spawn.Color = PALETTE.Ice
	spawn.Material = Enum.Material.Ice
	spawn.Parent = geometry

	createStartArch(decor)
end

local function buildLandingField(geometry: Folder, decor: Folder, milestones: Folder)
	local launchZ = WORLD.PathPoints[#WORLD.PathPoints].Z
	local markedEndZ = launchZ + WORLD.LandingMarkedDistanceMeters * WORLD.StudsPerMeter
	local landingEndZ = markedEndZ + WORLD.LandingRunoffDistanceMeters * WORLD.StudsPerMeter
	local halfOverlap = WORLD.LandingSegmentOverlap * 0.5

	-- Preserve the original snow floor and continue it beyond the ice runoff so the
	-- expanded landing field remains visually grounded from every marker.
	createPart(
		geometry,
		"WorldSnow",
		Vector3.new(1000, 4, 1800),
		CFrame.new(0, -4, 320),
		PALETTE.Snow,
		Enum.Material.Snow,
		true
	)

	local existingSnowEndZ = 1220
	local extendedSnowEndZ = landingEndZ + 250
	createPart(
		geometry,
		"WorldSnowExtension",
		Vector3.new(1000, 4, extendedSnowEndZ - existingSnowEndZ + halfOverlap),
		CFrame.new(0, -4, (existingSnowEndZ - halfOverlap + extendedSnowEndZ) * 0.5),
		PALETTE.Snow,
		Enum.Material.Snow,
		true
	)

	local lake = Instance.new("Folder")
	lake.Name = "FrozenLake"
	lake.Parent = geometry

	local function createLakeSegment(name: string, startZ: number, endZ: number)
		local segment = createPart(
			lake,
			name,
			Vector3.new(WORLD.LandingWidth, WORLD.LandingThickness, endZ - startZ),
			CFrame.new(0, WORLD.LandingTopY - WORLD.LandingThickness * 0.5, (startZ + endZ) * 0.5),
			PALETTE.Ice,
			Enum.Material.Ice,
			true
		)
		segment.Reflectance = 0.08
		segment.CustomPhysicalProperties = PhysicalProperties.new(
			PHYSICS.FrozenLakeDensity,
			PHYSICS.FrozenLakeFriction,
			PHYSICS.FrozenLakeElasticity,
			PHYSICS.FrozenLakeFrictionWeight,
			PHYSICS.FrozenLakeElasticityWeight
		)
	end

	-- The two surfaces share an exact top height and overlap slightly at 1500m,
	-- preventing a collision lip while keeping the full 1800m field flat.
	createLakeSegment("FrozenLakeMarked_0000m_1500m", launchZ, markedEndZ + halfOverlap)
	createLakeSegment("FrozenLakeRunoff_1500m_1800m", markedEndZ - halfOverlap, landingEndZ)

	buildDistanceMilestones(milestones, launchZ)

	local landingTreeCount = math.max(16, math.floor((landingEndZ - 470) / 43))
	for index = 1, landingTreeCount do
		local side = if index % 2 == 0 then -1 else 1
		local z = 390 + index * 43
		local x = side * (165 + (index % 3) * 18)
		createPine(decor, Vector3.new(x, 0, z), 0.8 + (index % 4) * 0.08, index % 2 == 0)
	end
end

function WorldBuilder.build()
	disableTemplatePart("Baseplate")
	disableTemplatePart("SpawnLocation")
	configureLighting()

	local existing = Workspace:FindFirstChild(WORLD.FolderName)
	if existing then
		existing:Destroy()
	end

	local world = Instance.new("Model")
	world.Name = WORLD.FolderName
	world:SetAttribute("WorldVersion", 2)
	world.Parent = Workspace

	local geometry = Instance.new("Folder")
	geometry.Name = "Geometry"
	geometry.Parent = world

	local decor = Instance.new("Folder")
	decor.Name = "Decor"
	decor.Parent = world

	local markers = Instance.new("Folder")
	markers.Name = "Markers"
	markers.Parent = world

	local presentation = Instance.new("Folder")
	presentation.Name = "Presentation"
	presentation:SetAttribute("VisualOnly", true)
	presentation.Parent = world

	local frozenLakeMilestones = Instance.new("Folder")
	frozenLakeMilestones.Name = "FrozenLakeMilestones"
	frozenLakeMilestones:SetAttribute("VisualOnly", true)
	frozenLakeMilestones.Parent = presentation

	buildLandingField(geometry, decor, frozenLakeMilestones)
	buildSummit(geometry, decor)
	buildCourse(world, geometry, decor, markers)

	print(string.format("[Frostline] V2 world generated (%d geometry parts)", #geometry:GetChildren()))
end

return WorldBuilder
