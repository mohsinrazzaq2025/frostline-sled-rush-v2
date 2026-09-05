--!strict

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local PRESENTATION = GameConfig.Presentation
local SNOWFALL = PRESENTATION.Snowfall
local TRAILS = PRESENTATION.Trails
local SNOW_SPRAY = PRESENTATION.SnowSpray
local TUCK_STREAKS = PRESENTATION.TuckStreaks
local BURSTS = PRESENTATION.Bursts
local WINTER_GRADE = PRESENTATION.WinterGrade

local EFFECTS_FOLDER_NAME = "FrostlineClientVFX"
local COLOR_GRADE_NAME = "FrostlineClientColorCorrection"
local BLOOM_NAME = "FrostlineBloom"
local NATIVE_PARTICLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SLED_RESOLVE_INTERVAL = 0.2
local GROUND_CHECK_INTERVAL = 0.05
local AMBIENT_UPDATE_INTERVAL = 1 / 15
local RUNNER_GLOW_FILL_COLOR = Color3.fromRGB(55, 225, 255)
local RUNNER_GLOW_OUTLINE_COLOR = Color3.fromRGB(215, 250, 255)
local RUNNER_GLOW_ACTIVE_FILL_TRANSPARENCY = 0.22
local RUNNER_GLOW_ACTIVE_OUTLINE_TRANSPARENCY = 0.2
local RUNNER_GLOW_ACTIVE_BRIGHTNESS = 2.25
local RUNNER_GLOW_RANGE = 9.5
local RUNNER_GLOW_FADE_IN_SECONDS = 0.11
local RUNNER_GLOW_FADE_OUT_SECONDS = 0.2

type BloomSnapshot = {
	Effect: BloomEffect,
	Owned: boolean,
	Enabled: boolean,
	Intensity: number,
	Size: number,
	Threshold: number,
}

type ColorCorrectionSnapshot = {
	Effect: ColorCorrectionEffect,
	Owned: boolean,
	Enabled: boolean,
	Brightness: number,
	Contrast: number,
	Saturation: number,
	TintColor: Color3,
}

type AmbientSnowLayer = {
	Part: Part,
	Emitter: ParticleEmitter,
	CameraOffset: Vector3,
}

type RunnerGlowTargetSpec = {
	PartName: string,
	SideName: string,
	SegmentName: string,
	HasSurfaceLight: boolean,
}

type RunnerGlowTarget = {
	Part: BasePart,
	SideName: string,
	SegmentName: string,
	HasSurfaceLight: boolean,
}

type RunnerGlow = {
	Runner: BasePart,
	Highlight: Highlight,
	Light: SurfaceLight?,
	FillTween: Tween?,
	OutlineTween: Tween?,
	BrightnessTween: Tween?,
	Active: boolean,
}

type SledEffects = {
	RunId: number,
	Model: Model,
	Root: BasePart,
	Trails: { Trail },
	Sprays: { ParticleEmitter },
	Streaks: ParticleEmitter,
	Bursts: { ParticleEmitter },
	RunnerGlows: { RunnerGlow },
	CreatedInstances: { Instance },
	Connections: { RBXScriptConnection },
	RaycastParams: RaycastParams,
	Grounded: boolean,
	NextGroundCheckAt: number,
	LastTrailEnabled: boolean,
	LastTrailStrength: number,
	LastSprayStrength: number,
	LastStreakEnabled: boolean,
	LastRunnerGlowActive: boolean,
}

local RUNNER_GLOW_TARGET_SPECS: { RunnerGlowTargetSpec } = {
	{
		PartName = "ClassicLeftRunnerRail",
		SideName = "Left",
		SegmentName = "Rail",
		HasSurfaceLight = true,
	},
	{
		PartName = "ClassicLeftRunnerUpturn",
		SideName = "Left",
		SegmentName = "Upturn",
		HasSurfaceLight = false,
	},
	{
		PartName = "ClassicLeftRunnerCurl",
		SideName = "Left",
		SegmentName = "Curl",
		HasSurfaceLight = false,
	},
	{
		PartName = "ClassicRightRunnerRail",
		SideName = "Right",
		SegmentName = "Rail",
		HasSurfaceLight = true,
	},
	{
		PartName = "ClassicRightRunnerUpturn",
		SideName = "Right",
		SegmentName = "Upturn",
		HasSurfaceLight = false,
	},
	{
		PartName = "ClassicRightRunnerCurl",
		SideName = "Right",
		SegmentName = "Curl",
		HasSurfaceLight = false,
	},
}

local VFXController = {}

local localPlayer = Players.LocalPlayer

local function shouldUseReducedQuality(): boolean
	if UserInputService.TouchEnabled then
		return true
	end

	local succeeded, savedQuality = pcall(function(): any
		local userGameSettings: any = UserSettings():GetService("UserGameSettings")
		return userGameSettings.SavedQualityLevel
	end)
	if not succeeded or typeof(savedQuality) ~= "EnumItem" then
		return false
	end

	local matchedQualityLevel = string.match(tostring(savedQuality), "QualityLevel(%d+)")
	if not matchedQualityLevel then
		return false
	end
	local qualityLevel = tonumber(matchedQualityLevel)
	return qualityLevel ~= nil and qualityLevel <= 3
end

local isReducedQuality = shouldUseReducedQuality()
local started = false
local controllerConnections: { RBXScriptConnection } = {}
local warned: { [string]: boolean } = {}
local effectsFolder: Folder? = nil
local ambientSnowLayers: { AmbientSnowLayer } = {}
local bloomSnapshot: BloomSnapshot? = nil
local colorCorrectionSnapshot: ColorCorrectionSnapshot? = nil
local activeSledEffects: SledEffects? = nil
local currentRunId: number? = nil
local currentPhase: string = RunPhase.Idle
local currentSpeed = 0
local currentTucking = false
local currentTuckQueued = false
local currentGlowTucking = false
local currentOutcome: string? = nil
local currentReleaseAccepted = false
local nextSledResolveAt = 0
local nextAmbientUpdateAt = 0
local landingBoostUntil = 0
local sawAirborne = false
local sawLanding = false
local pendingLaunchBurst = false
local pendingLandingBurst = false
local pendingCrashBurst = false
local crashBurstRunId: number? = nil
local sledEffectsDisabledRunId: number? = nil

local function diagnostic(message: string)
	if PRESENTATION.DiagnosticsEnabled then
		print(string.format("[Frostline][VFX] %s", message))
	end
end

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(string.format("[Frostline][VFX] %s", message))
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isKnownPhase(value: string): boolean
	return value == RunPhase.Idle
		or value == RunPhase.Countdown
		or value == RunPhase.Descent
		or value == RunPhase.Airborne
		or value == RunPhase.Landed
		or value == RunPhase.Results
		or value == RunPhase.Reset
end

local function isRunnerGlowPhase(value: string): boolean
	return value == RunPhase.Countdown
		or value == RunPhase.Descent
		or value == RunPhase.Airborne
end

local function isCompletedOutcome(value: any): boolean
	return value == ResultTypes.Outcomes.CleanLanding
		or value == ResultTypes.Outcomes.Crashed
		or value == ResultTypes.Outcomes.Stalled
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function destroyInstances(instances: { Instance })
	for index = #instances, 1, -1 do
		local instance = instances[index]
		pcall(function()
			instance:Destroy()
		end)
	end
	table.clear(instances)
end

local function findLightingEffect(className: string, preferredName: string): Instance?
	local preferred = Lighting:FindFirstChild(preferredName)
	if preferred and preferred.ClassName == className then
		return preferred
	end

	local fallback: Instance? = nil
	for _, child in Lighting:GetChildren() do
		if child.ClassName == className and child:GetAttribute("FrostlinePresentationGrade") == true then
			return child
		elseif child.ClassName == className and not fallback then
			fallback = child
		end
	end
	return fallback
end

local function configureWinterGrade()
	local bloomInstance = findLightingEffect("BloomEffect", BLOOM_NAME)
	local bloom: BloomEffect
	local ownsBloom = false
	if bloomInstance and bloomInstance:IsA("BloomEffect") then
		bloom = bloomInstance
	else
		bloom = Instance.new("BloomEffect")
		bloom.Name = BLOOM_NAME
		bloom:SetAttribute("FrostlinePresentationGrade", true)
		bloom.Parent = Lighting
		ownsBloom = true
	end
	bloomSnapshot = {
		Effect = bloom,
		Owned = ownsBloom,
		Enabled = bloom.Enabled,
		Intensity = bloom.Intensity,
		Size = bloom.Size,
		Threshold = bloom.Threshold,
	}
	if ownsBloom then
		bloom.Enabled = true
		bloom.Intensity = WINTER_GRADE.BloomIntensity
		bloom.Size = WINTER_GRADE.BloomSize
		bloom.Threshold = WINTER_GRADE.BloomThreshold
	end

	local colorInstance = findLightingEffect("ColorCorrectionEffect", COLOR_GRADE_NAME)
	local colorCorrection: ColorCorrectionEffect
	local ownsColorCorrection = false
	if colorInstance and colorInstance:IsA("ColorCorrectionEffect") then
		colorCorrection = colorInstance
	else
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = COLOR_GRADE_NAME
		colorCorrection:SetAttribute("FrostlinePresentationGrade", true)
		colorCorrection.Parent = Lighting
		ownsColorCorrection = true
	end
	colorCorrectionSnapshot = {
		Effect = colorCorrection,
		Owned = ownsColorCorrection,
		Enabled = colorCorrection.Enabled,
		Brightness = colorCorrection.Brightness,
		Contrast = colorCorrection.Contrast,
		Saturation = colorCorrection.Saturation,
		TintColor = colorCorrection.TintColor,
	}
	if ownsColorCorrection then
		colorCorrection.Enabled = true
		colorCorrection.Brightness = WINTER_GRADE.Brightness
		colorCorrection.Contrast = WINTER_GRADE.Contrast
		colorCorrection.Saturation = WINTER_GRADE.Saturation
		colorCorrection.TintColor = WINTER_GRADE.TintColor
	end
end

local function restoreWinterGrade()
	local bloomState = bloomSnapshot
	bloomSnapshot = nil
	if bloomState then
		if bloomState.Owned then
			bloomState.Effect:Destroy()
		end
	end

	local colorState = colorCorrectionSnapshot
	colorCorrectionSnapshot = nil
	if colorState then
		if colorState.Owned then
			colorState.Effect:Destroy()
		end
	end
end

local function createAmbientSnowLayer(
	parent: Instance,
	layerName: string,
	layerConfig: any,
	isNear: boolean
)
	local part = Instance.new("Part")
	part.Name = string.format("AmbientSnowfall%sRegion", layerName)
	part.Size = layerConfig.RegionSize
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
	part.Transparency = 1
	part.Parent = parent

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = string.format("AmbientSnowfall%s", layerName)
	emitter.Texture = NATIVE_PARTICLE_TEXTURE
	if isNear then
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(224, 246, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(177, 226, 250)),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.1, 0.14),
			NumberSequenceKeypoint.new(0.78, 0.34),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.18),
			NumberSequenceKeypoint.new(0.5, 0.36),
			NumberSequenceKeypoint.new(1, 0.1),
		})
		emitter.Lifetime = NumberRange.new(2.2, 3.4)
		emitter.Speed = NumberRange.new(5.5, 8.5)
		emitter.Acceleration = Vector3.new(1.4, -2, 0.6)
		emitter.Drag = 0.25
		emitter.SpreadAngle = Vector2.new(18, 18)
		emitter.RotSpeed = NumberRange.new(-85, 85)
		emitter.LightEmission = 0.24
		emitter.LightInfluence = 0.45
	else
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(229, 247, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(193, 231, 250)),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.14, 0.3),
			NumberSequenceKeypoint.new(0.8, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.07),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 0.05),
		})
		emitter.Lifetime = NumberRange.new(4.4, 6.2)
		emitter.Speed = NumberRange.new(2.5, 4.5)
		emitter.Acceleration = Vector3.new(0.55, -0.85, 0.3)
		emitter.Drag = 0.3
		emitter.SpreadAngle = Vector2.new(22, 22)
		emitter.RotSpeed = NumberRange.new(-38, 38)
		emitter.LightEmission = 0.18
		emitter.LightInfluence = 0.6
	end
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Rate = if isReducedQuality then layerConfig.MobileRate else layerConfig.DesktopRate
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LockedToPart = false
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Parent = part

	table.insert(ambientSnowLayers, {
		Part = part,
		Emitter = emitter,
		CameraOffset = layerConfig.CameraOffset,
	})
end

local function createAmbientSnowfall(parent: Instance)
	createAmbientSnowLayer(parent, "Far", SNOWFALL.Far, false)
	createAmbientSnowLayer(parent, "Near", SNOWFALL.Near, true)
end

local function updateAmbientSnowfall()
	local camera = Workspace.CurrentCamera
	if not camera then
		for _, layer in ambientSnowLayers do
			layer.Emitter.Enabled = false
		end
		return
	end

	for _, layer in ambientSnowLayers do
		if layer.Part.Parent and layer.Emitter.Parent then
			local targetPosition = (camera.CFrame * CFrame.new(layer.CameraOffset)).Position
			layer.Part.CFrame = CFrame.new(targetPosition)
			layer.Emitter.Enabled = true
		else
			layer.Emitter.Enabled = false
		end
	end
end

local function findActiveSledModel(): (Model?, BasePart?)
	local character = localPlayer.Character
	if not character then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil, nil
	end
	local seatPart = humanoid.SeatPart
	if not seatPart then
		return nil, nil
	end

	local world = Workspace:FindFirstChild(GameConfig.World.FolderName)
	local activeSleds = if world then world:FindFirstChild("ActiveSleds") else nil
	if not activeSleds or not activeSleds:IsA("Folder") then
		return nil, nil
	end

	local candidate: Instance? = seatPart.Parent
	while candidate and candidate ~= activeSleds do
		if candidate:IsA("Model") and candidate.Parent == activeSleds then
			local root = candidate:FindFirstChild("SledRoot")
			local driverSeat = candidate:FindFirstChild("DriverSeat")
			if root and root:IsA("BasePart") and driverSeat == seatPart then
				return candidate, root
			end
			return nil, nil
		end
		candidate = candidate.Parent
	end

	return nil, nil
end

local function findRunnerPair(model: Model, root: BasePart): (BasePart?, BasePart?)
	local leftRunner: BasePart? = nil
	local rightRunner: BasePart? = nil
	local namedLeft = model:FindFirstChild("ClassicLeftRunnerRail", true)
		or model:FindFirstChild("GoldLeftRunner", true)
	local namedRight = model:FindFirstChild("ClassicRightRunnerRail", true)
		or model:FindFirstChild("GoldRightRunner", true)
	if namedLeft and namedLeft:IsA("BasePart") and namedLeft ~= root then
		leftRunner = namedLeft
	end
	if namedRight and namedRight:IsA("BasePart") and namedRight ~= root then
		rightRunner = namedRight
	end
	if leftRunner and rightRunner and leftRunner ~= rightRunner then
		return leftRunner, rightRunner
	end

	local bestLeftScore = math.huge
	local bestRightScore = math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local lowerName = string.lower(descendant.Name)
			local isRunner = string.find(lowerName, "runner", 1, true) ~= nil
			local isSupport = string.find(lowerName, "support", 1, true) ~= nil
			if isRunner and not isSupport and descendant.Size.Z >= 6 then
				local localPosition = root.CFrame:PointToObjectSpace(descendant.Position)
				local score = math.abs(descendant.Size.Z - 12)
					+ math.abs(localPosition.Y + 0.42) * 0.25
				if localPosition.X < -0.25 and score < bestLeftScore then
					leftRunner = descendant
					bestLeftScore = score
				elseif localPosition.X > 0.25 and score < bestRightScore then
					rightRunner = descendant
					bestRightScore = score
				end
			end
		end
	end

	if leftRunner == rightRunner then
		return nil, nil
	end
	return leftRunner, rightRunner
end

local function findExactRunnerGlowTargets(model: Model): { RunnerGlowTarget }?
	local shell = model:FindFirstChild("FrostlineClassicVisual")
	if not shell or not shell:IsA("Model") then
		return nil
	end

	local targets: { RunnerGlowTarget } = {}
	for _, spec in RUNNER_GLOW_TARGET_SPECS do
		local instance = shell:FindFirstChild(spec.PartName)
		if not instance or not instance:IsA("BasePart") then
			return nil
		end
		table.insert(targets, {
			Part = instance,
			SideName = spec.SideName,
			SegmentName = spec.SegmentName,
			HasSurfaceLight = spec.HasSurfaceLight,
		})
	end

	return targets
end

local function trackCreated(created: { Instance }, instance: Instance)
	table.insert(created, instance)
end

local function createRunnerGlow(
	target: RunnerGlowTarget,
	created: { Instance }
): RunnerGlow
	local runner = target.Part
	local highlight = Instance.new("Highlight")
	highlight.Name = string.format(
		"Frostline%sRunner%sTuckHighlight",
		target.SideName,
		target.SegmentName
	)
	highlight.Adornee = runner
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = RUNNER_GLOW_FILL_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineColor = RUNNER_GLOW_OUTLINE_COLOR
	highlight.OutlineTransparency = 1
	highlight.Enabled = true
	highlight.Parent = runner
	trackCreated(created, highlight)

	local light: SurfaceLight? = nil
	if target.HasSurfaceLight then
		local surfaceLight = Instance.new("SurfaceLight")
		surfaceLight.Name = string.format("Frostline%sRunnerTuckLight", target.SideName)
		surfaceLight.Face = Enum.NormalId.Bottom
		surfaceLight.Color = RUNNER_GLOW_FILL_COLOR
		surfaceLight.Shadows = false
		surfaceLight.Brightness = 0
		surfaceLight.Range = RUNNER_GLOW_RANGE
		surfaceLight.Enabled = true
		surfaceLight.Parent = runner
		trackCreated(created, surfaceLight)
		light = surfaceLight
	end

	return {
		Runner = runner,
		Highlight = highlight,
		Light = light,
		FillTween = nil,
		OutlineTween = nil,
		BrightnessTween = nil,
		Active = false,
	}
end

local function createRunnerGlows(
	targets: { RunnerGlowTarget },
	created: { Instance }
): { RunnerGlow }
	local glows: { RunnerGlow } = {}
	for _, target in targets do
		table.insert(glows, createRunnerGlow(target, created))
	end
	return glows
end

local function cancelRunnerGlowTweens(glow: RunnerGlow)
	local fillTween = glow.FillTween
	glow.FillTween = nil
	if fillTween then
		fillTween:Cancel()
	end

	local outlineTween = glow.OutlineTween
	glow.OutlineTween = nil
	if outlineTween then
		outlineTween:Cancel()
	end

	local brightnessTween = glow.BrightnessTween
	glow.BrightnessTween = nil
	if brightnessTween then
		brightnessTween:Cancel()
	end
end

local function setRunnerGlowActive(glow: RunnerGlow, active: boolean)
	local light = glow.Light
	if not glow.Runner:IsDescendantOf(Workspace)
		or glow.Highlight.Parent ~= glow.Runner
		or (light ~= nil and light.Parent ~= glow.Runner)
	then
		cancelRunnerGlowTweens(glow)
		glow.Active = false
		return
	end
	if glow.Active == active then
		return
	end

	cancelRunnerGlowTweens(glow)

	glow.Active = active
	local duration = if active then RUNNER_GLOW_FADE_IN_SECONDS else RUNNER_GLOW_FADE_OUT_SECONDS
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fillTween = TweenService:Create(glow.Highlight, tweenInfo, {
		FillTransparency = if active then RUNNER_GLOW_ACTIVE_FILL_TRANSPARENCY else 1,
	})
	local outlineTween = TweenService:Create(glow.Highlight, tweenInfo, {
		OutlineTransparency = if active then RUNNER_GLOW_ACTIVE_OUTLINE_TRANSPARENCY else 1,
	})
	glow.FillTween = fillTween
	glow.OutlineTween = outlineTween
	fillTween:Play()
	outlineTween:Play()

	if light then
		local brightnessTween = TweenService:Create(light, tweenInfo, {
			Brightness = if active then RUNNER_GLOW_ACTIVE_BRIGHTNESS else 0,
		})
		glow.BrightnessTween = brightnessTween
		brightnessTween:Play()
	end
end

local function setRunnerGlowsActive(effects: SledEffects, active: boolean)
	if effects.LastRunnerGlowActive == active then
		return
	end
	effects.LastRunnerGlowActive = active
	for _, glow in effects.RunnerGlows do
		setRunnerGlowActive(glow, active)
	end
end

local function forceRunnerGlowsInactive(effects: SledEffects)
	effects.LastRunnerGlowActive = false
	for _, glow in effects.RunnerGlows do
		cancelRunnerGlowTweens(glow)
		glow.Active = false
		pcall(function()
			glow.Highlight.FillTransparency = 1
			glow.Highlight.OutlineTransparency = 1
			local light = glow.Light
			if light then
				light.Brightness = 0
			end
		end)
	end
end

local function shouldRunnerGlow(effects: SledEffects): boolean
	if not started
		or activeSledEffects ~= effects
		or effects.RunId ~= currentRunId
		or not effects.Model:IsDescendantOf(Workspace)
		or not effects.Root:IsDescendantOf(Workspace)
		or not isRunnerGlowPhase(currentPhase)
		or isCompletedOutcome(currentOutcome)
	then
		return false
	end

	local currentModel, currentRoot = findActiveSledModel()
	if currentModel ~= effects.Model or currentRoot ~= effects.Root then
		return false
	end

	if currentPhase == RunPhase.Countdown then
		return currentTuckQueued
	end
	return currentGlowTucking
end

local function reconcileRunnerGlows(effects: SledEffects)
	setRunnerGlowsActive(effects, shouldRunnerGlow(effects))
end

local function createRunnerTrailLayer(
	runner: BasePart,
	root: BasePart,
	sideName: string,
	layerName: string,
	width: number,
	created: { Instance }
): Trail
	local rearZ = math.max(0, runner.Size.Z * 0.5 - 0.2)
	local rootContactWorld = root.CFrame:PointToWorldSpace(Vector3.new(0, -root.Size.Y * 0.5 + 0.04, 0))
	local contactY = math.clamp(
		runner.CFrame:PointToObjectSpace(rootContactWorld).Y,
		-runner.Size.Y * 0.5,
		runner.Size.Y * 0.5
	)
	local halfWidth = math.min(width * 0.5, runner.Size.X * 0.5)
	local verticalOffset = if layerName == "Broad" then 0.015 else 0.04

	local attachment0 = Instance.new("Attachment")
	attachment0.Name = string.format("Frostline%s%sTrailEdgeA", sideName, layerName)
	attachment0.Position = Vector3.new(-halfWidth, contactY + verticalOffset, rearZ)
	attachment0.Parent = runner
	trackCreated(created, attachment0)

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = string.format("Frostline%s%sTrailEdgeB", sideName, layerName)
	attachment1.Position = Vector3.new(halfWidth, contactY + verticalOffset, rearZ)
	attachment1.Parent = runner
	trackCreated(created, attachment1)

	local trail = Instance.new("Trail")
	trail.Name = string.format("Frostline%sRunner%sTrail", sideName, layerName)
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	if layerName == "Broad" then
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 245, 252)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(172, 220, 241)),
		})
		trail.LightEmission = 0.12
		trail.LightInfluence = 0.68
		trail.Lifetime = TRAILS.BroadLifetime
	else
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(218, 246, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(143, 211, 239)),
		})
		trail.LightEmission = 0.16
		trail.LightInfluence = 0.58
		trail.Lifetime = TRAILS.HighlightLifetime
	end
	trail.Transparency = NumberSequence.new(1)
	trail.WidthScale = NumberSequence.new(0.5)
	trail.MinLength = 0.05
	trail.FaceCamera = false
	trail.Enabled = false
	trail.Parent = runner
	trackCreated(created, trail)
	return trail
end

local function createRunnerTrails(
	runner: BasePart,
	root: BasePart,
	sideName: string,
	created: { Instance }
): { Trail }
	return {
		createRunnerTrailLayer(runner, root, sideName, "Broad", TRAILS.BroadWidth, created),
		createRunnerTrailLayer(runner, root, sideName, "Highlight", TRAILS.HighlightWidth, created),
	}
end

local function createRunnerContactAttachment(
	runner: BasePart,
	root: BasePart,
	sideName: string,
	created: { Instance }
): Attachment
	local rootContactWorld = root.CFrame:PointToWorldSpace(Vector3.new(0, -root.Size.Y * 0.5 + 0.04, 0))
	local contactY = math.clamp(
		runner.CFrame:PointToObjectSpace(rootContactWorld).Y,
		-runner.Size.Y * 0.5,
		runner.Size.Y * 0.5
	)
	local attachment = Instance.new("Attachment")
	attachment.Name = string.format("Frostline%sRunnerContactEffects", sideName)
	local position = Vector3.new(
		0,
		contactY,
		math.max(0, runner.Size.Z * 0.5 - 0.2)
	)
	local sideDirection = if sideName == "Left" then -1 else 1
	local rearwardOutward = Vector3.new(sideDirection * 0.18, 0.12, 1).Unit
	attachment.CFrame = CFrame.lookAt(position, position - rearwardOutward, Vector3.yAxis)
	attachment.Parent = runner
	trackCreated(created, attachment)
	return attachment
end

local function createSprayEmitter(
	parent: Attachment,
	sideName: string,
	created: { Instance }
): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = string.format("Frostline%sSnowSpray", sideName)
	emitter.Texture = NATIVE_PARTICLE_TEXTURE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(231, 247, 253)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(164, 216, 239)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.62),
		NumberSequenceKeypoint.new(0.42, 0.78),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.36),
		NumberSequenceKeypoint.new(0.48, 0.92),
		NumberSequenceKeypoint.new(1, 0.16),
	})
	emitter.Lifetime = SNOW_SPRAY.Lifetime
	emitter.Speed = NumberRange.new(5, 10)
	emitter.Acceleration = Vector3.new(0, 4, 0)
	emitter.Drag = 1.8
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.SpreadAngle = Vector2.new(24, 18)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-80, 80)
	emitter.LightEmission = 0.18
	emitter.LightInfluence = 0.65
	emitter.LockedToPart = false
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = parent
	trackCreated(created, emitter)
	return emitter
end

local function createStreakEmitter(parent: Attachment, created: { Instance }): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "FrostlineTuckStreaks"
	emitter.Texture = NATIVE_PARTICLE_TEXTURE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(238, 252, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(131, 220, 250)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.34),
		NumberSequenceKeypoint.new(0.55, 0.58),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.55, 0.13),
		NumberSequenceKeypoint.new(1, 0.055),
	})
	emitter.Lifetime = TUCK_STREAKS.Lifetime
	emitter.Speed = NumberRange.new(22, 34)
	emitter.Drag = 0.8
	emitter.EmissionDirection = Enum.NormalId.Back
	emitter.SpreadAngle = Vector2.new(10, 7)
	emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
	emitter.Squash = NumberSequence.new(0.65)
	emitter.LightEmission = 0.35
	emitter.LightInfluence = 0.42
	emitter.LockedToPart = false
	emitter.Rate = if isReducedQuality then TUCK_STREAKS.MobileRate else TUCK_STREAKS.DesktopRate
	emitter.Enabled = false
	emitter.Parent = parent
	trackCreated(created, emitter)
	return emitter
end

local function createBurstEmitter(
	parent: Attachment,
	sideName: string,
	created: { Instance }
): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = string.format("Frostline%sSnowBurst", sideName)
	emitter.Texture = NATIVE_PARTICLE_TEXTURE
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(152, 224, 250)),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(0.6, 0.48),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.16),
		NumberSequenceKeypoint.new(0.45, 0.5),
		NumberSequenceKeypoint.new(1, 0.08),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.Speed = NumberRange.new(7, 17)
	emitter.Acceleration = Vector3.new(0, 2, 0)
	emitter.Drag = 1.8
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-110, 110)
	emitter.LightEmission = 0.3
	emitter.LightInfluence = 0.48
	emitter.LockedToPart = false
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = parent
	trackCreated(created, emitter)
	return emitter
end

local function createSledEffects(
	model: Model,
	root: BasePart,
	runId: number,
	runnerGlowTargets: { RunnerGlowTarget }
): (SledEffects?, string?)
	local leftRunner, rightRunner = findRunnerPair(model, root)
	if not leftRunner or not rightRunner then
		return nil, "validated left/right runner pair was not available"
	end

	local created: { Instance } = {}
	local succeeded, result = pcall(function(): SledEffects
		local runnerGlows = createRunnerGlows(runnerGlowTargets, created)
		local trails: { Trail } = {}
		for _, trail in createRunnerTrails(leftRunner, root, "Left", created) do
			table.insert(trails, trail)
		end
		for _, trail in createRunnerTrails(rightRunner, root, "Right", created) do
			table.insert(trails, trail)
		end

		local leftContact = createRunnerContactAttachment(leftRunner, root, "Left", created)
		local rightContact = createRunnerContactAttachment(rightRunner, root, "Right", created)

		-- Sled forward is local -Z, so local +Z is the rear emission side.
		local rearAttachment = Instance.new("Attachment")
		rearAttachment.Name = "FrostlineRearEffects"
		rearAttachment.Position = Vector3.new(0, -0.25, root.Size.Z * 0.5 - 0.2)
		rearAttachment.Parent = root
		trackCreated(created, rearAttachment)

		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		local character = localPlayer.Character
		raycastParams.FilterDescendantsInstances = if character then { model, character } else { model }
		raycastParams.IgnoreWater = true
		raycastParams.RespectCanCollide = true

		return {
			RunId = runId,
			Model = model,
			Root = root,
			Trails = trails,
			Sprays = {
				createSprayEmitter(leftContact, "Left", created),
				createSprayEmitter(rightContact, "Right", created),
			},
			Streaks = createStreakEmitter(rearAttachment, created),
			Bursts = {
				createBurstEmitter(leftContact, "Left", created),
				createBurstEmitter(rightContact, "Right", created),
			},
			RunnerGlows = runnerGlows,
			CreatedInstances = created,
			Connections = {},
			RaycastParams = raycastParams,
			Grounded = false,
			NextGroundCheckAt = 0,
			LastTrailEnabled = false,
			LastTrailStrength = -1,
			LastSprayStrength = -1,
			LastStreakEnabled = false,
			LastRunnerGlowActive = false,
		}
	end)

	if not succeeded then
		destroyInstances(created)
		return nil, tostring(result)
	end
	return result :: SledEffects, nil
end

local function disableSledEffects(effects: SledEffects)
	for _, trail in effects.Trails do
		trail.Enabled = false
		trail:Clear()
	end
	effects.LastTrailEnabled = false
	effects.LastTrailStrength = -1
	for _, spray in effects.Sprays do
		spray.Enabled = false
		spray.Rate = 0
		spray:Clear()
	end
	effects.LastSprayStrength = -1
	effects.Streaks.Enabled = false
	effects.Streaks:Clear()
	effects.LastStreakEnabled = false
end

local function destroyActiveSledEffects()
	local effects = activeSledEffects
	activeSledEffects = nil
	if not effects then
		return
	end

	forceRunnerGlowsInactive(effects)
	disconnectAll(effects.Connections)
	pcall(function()
		disableSledEffects(effects)
		for _, burst in effects.Bursts do
			burst:Clear()
		end
	end)
	destroyInstances(effects.CreatedInstances)
end

local function emitAcrossBursts(effects: SledEffects, totalCount: number)
	local emitterCount = #effects.Bursts
	if emitterCount == 0 then
		return
	end
	local baseCount = math.floor(totalCount / emitterCount)
	local remainder = totalCount - baseCount * emitterCount
	for index, burst in effects.Bursts do
		burst:Emit(baseCount + (if index <= remainder then 1 else 0))
	end
end

local function emitLaunchBurst(effects: SledEffects)
	for _, burst in effects.Bursts do
		burst.Lifetime = BURSTS.LaunchLifetime
		burst.Speed = NumberRange.new(10, 20)
		burst.Acceleration = Vector3.new(0, 3, 0)
		burst.Drag = 1.5
		burst.EmissionDirection = Enum.NormalId.Back
		burst.SpreadAngle = Vector2.new(52, 38)
		burst.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.18),
			NumberSequenceKeypoint.new(0.55, 0.54),
			NumberSequenceKeypoint.new(1, 1),
		})
		burst.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.32),
			NumberSequenceKeypoint.new(0.45, 0.88),
			NumberSequenceKeypoint.new(1, 0.1),
		})
	end
	emitAcrossBursts(effects, if isReducedQuality then BURSTS.MobileLaunch else BURSTS.DesktopLaunch)
end

local function emitLandingBurst(effects: SledEffects)
	landingBoostUntil = os.clock() + TRAILS.LandingBoostDuration
	for _, burst in effects.Bursts do
		burst.Lifetime = BURSTS.LandingLifetime
		burst.Speed = NumberRange.new(8, 19)
		burst.Acceleration = Vector3.new(0, 2, 0)
		burst.Drag = 1.7
		burst.EmissionDirection = Enum.NormalId.Top
		burst.SpreadAngle = Vector2.new(165, 125)
		burst.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.14),
			NumberSequenceKeypoint.new(0.58, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		burst.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.38),
			NumberSequenceKeypoint.new(0.45, 1.12),
			NumberSequenceKeypoint.new(1, 0.15),
		})
	end
	emitAcrossBursts(effects, if isReducedQuality then BURSTS.MobileLanding else BURSTS.DesktopLanding)
end

local function emitCrashBurst(effects: SledEffects)
	for _, burst in effects.Bursts do
		burst.Lifetime = BURSTS.CrashLifetime
		burst.Speed = NumberRange.new(12, 24)
		burst.Acceleration = Vector3.new(0, 1, 0)
		burst.Drag = 1.4
		burst.EmissionDirection = Enum.NormalId.Top
		burst.SpreadAngle = Vector2.new(180, 180)
		burst.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.6, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		burst.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.42),
			NumberSequenceKeypoint.new(0.45, 1.34),
			NumberSequenceKeypoint.new(1, 0.18),
		})
	end
	emitAcrossBursts(effects, if isReducedQuality then BURSTS.MobileCrash else BURSTS.DesktopCrash)
end

local function flushPendingBursts(effects: SledEffects)
	if activeSledEffects ~= effects
		or effects.RunId ~= currentRunId
		or not effects.Model:IsDescendantOf(Workspace)
		or not effects.Root:IsDescendantOf(Workspace)
	then
		return
	end

	if pendingLaunchBurst then
		if currentPhase == RunPhase.Airborne then
			pendingLaunchBurst = false
			emitLaunchBurst(effects)
		elseif currentPhase == RunPhase.Landed or currentPhase == RunPhase.Results then
			pendingLaunchBurst = false
		end
	end
	if pendingLandingBurst then
		if currentPhase == RunPhase.Landed then
			pendingLandingBurst = false
			emitLandingBurst(effects)
		elseif currentPhase == RunPhase.Results then
			pendingLandingBurst = false
		end
	end
	if pendingCrashBurst then
		if currentPhase == RunPhase.Results and crashBurstRunId == currentRunId then
			pendingCrashBurst = false
			emitCrashBurst(effects)
		elseif crashBurstRunId ~= currentRunId then
			pendingCrashBurst = false
		end
	end
end

local function tryResolveSled(): boolean
	local runId = currentRunId
	if runId == nil then
		return false
	end
	if sledEffectsDisabledRunId == currentRunId then
		return false
	end
	local existing = activeSledEffects
	if existing and existing.Model.Parent and existing.Root.Parent then
		return true
	elseif existing then
		destroyActiveSledEffects()
	end

	local model, root = findActiveSledModel()
	if not model or not root then
		return false
	end
	local runnerGlowTargets = findExactRunnerGlowTargets(model)
	if not runnerGlowTargets then
		return false
	end
	local effects, failureReason = createSledEffects(model, root, runId, runnerGlowTargets)
	if not effects then
		sledEffectsDisabledRunId = currentRunId
		warnOnce("sled-effects", string.format("Sled effects disabled: %s", failureReason or "unknown error"))
		return false
	end

	activeSledEffects = effects
	table.insert(effects.Connections, model.AncestryChanged:Connect(function()
		if activeSledEffects == effects and not model:IsDescendantOf(Workspace) then
			destroyActiveSledEffects()
		end
	end))
	local currentModel, currentRoot = findActiveSledModel()
	if not started
		or currentRunId ~= runId
		or activeSledEffects ~= effects
		or currentModel ~= model
		or currentRoot ~= root
	then
		destroyActiveSledEffects()
		return false
	end
	reconcileRunnerGlows(effects)
	flushPendingBursts(effects)
	diagnostic(string.format("attached sled effects RunId=%s", tostring(currentRunId)))
	return true
end

local function updateGrounded(effects: SledEffects, now: number): boolean
	if now < effects.NextGroundCheckAt then
		return effects.Grounded
	end
	effects.NextGroundCheckAt = now + GROUND_CHECK_INTERVAL
	local result = Workspace:Raycast(
		effects.Root.Position,
		Vector3.new(0, -SNOW_SPRAY.GroundRayDistance, 0),
		effects.RaycastParams
	)
	effects.Grounded = result ~= nil and result.Instance.CanCollide
	return effects.Grounded
end

local function normalizedSpeed(speed: number, minimum: number, full: number): number
	if full <= minimum then
		return if speed >= minimum then 1 else 0
	end
	return math.clamp((speed - minimum) / (full - minimum), 0, 1)
end

local function updateTrails(effects: SledEffects, enabled: boolean, strength: number)
	local strengthBucket = math.round(math.clamp(strength, 0, 1) * 20) / 20
	if effects.LastTrailEnabled == enabled and effects.LastTrailStrength == strengthBucket then
		return
	end
	effects.LastTrailEnabled = enabled
	effects.LastTrailStrength = strengthBucket

	for _, trail in effects.Trails do
		local isHighlight = string.find(trail.Name, "Highlight", 1, true) ~= nil
		trail.Enabled = enabled
		if isHighlight then
			trail.LightEmission = 0.14 + strengthBucket * 0.08
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.84 - strengthBucket * 0.3),
				NumberSequenceKeypoint.new(0.5, 0.92 - strengthBucket * 0.16),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.WidthScale = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.78 + strengthBucket * 0.12),
				NumberSequenceKeypoint.new(1, 0.12 + strengthBucket * 0.06),
			})
		else
			trail.LightEmission = 0.1 + strengthBucket * 0.08
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.58 - strengthBucket * 0.34),
				NumberSequenceKeypoint.new(0.5, 0.78 - strengthBucket * 0.25),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.WidthScale = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.92 + strengthBucket * 0.08),
				NumberSequenceKeypoint.new(1, 0.24 + strengthBucket * 0.1),
			})
		end
	end
end

local function updateSprays(effects: SledEffects, strength: number)
	local strengthBucket = math.round(math.clamp(strength, 0, 1) * 10) / 10
	if effects.LastSprayStrength == strengthBucket then
		return
	end
	effects.LastSprayStrength = strengthBucket

	local maximumCombinedRate = if isReducedQuality
		then SNOW_SPRAY.MobileMaximumRate
		else SNOW_SPRAY.DesktopMaximumRate
	local ratePerRunner = maximumCombinedRate * strengthBucket / math.max(1, #effects.Sprays)
	local leadingTransparency = 0.68 - strengthBucket * 0.38
	for _, spray in effects.Sprays do
		spray.Rate = ratePerRunner
		spray.Enabled = ratePerRunner > 0
		spray.Speed = NumberRange.new(5 + strengthBucket * 5, 9 + strengthBucket * 8)
		spray.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, leadingTransparency),
			NumberSequenceKeypoint.new(0.42, math.min(0.9, leadingTransparency + 0.3)),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
end

local function updateSledPresentation(now: number)
	local runId = currentRunId
	if runId == nil
		or currentPhase == RunPhase.Idle
		or currentPhase == RunPhase.Reset
	then
		return
	end

	if not activeSledEffects and now >= nextSledResolveAt then
		nextSledResolveAt = now + SLED_RESOLVE_INTERVAL
		tryResolveSled()
	end
	local effects = activeSledEffects
	if not effects or not effects.Model.Parent or not effects.Root.Parent then
		return
	end

	local speed = currentSpeed
	local grounded = false
	if currentPhase == RunPhase.Descent or currentPhase == RunPhase.Landed then
		grounded = updateGrounded(effects, now)
	end

	local trailStrength = normalizedSpeed(speed, TRAILS.MinimumSpeed, TRAILS.FullStrengthSpeed)
	if currentTucking then
		trailStrength = math.min(1, trailStrength + TRAILS.TuckStrengthBonus)
	elseif currentPhase == RunPhase.Landed then
		trailStrength *= TRAILS.LakeStrengthMultiplier
	end
	local inLandingBoost = currentPhase == RunPhase.Landed and now < landingBoostUntil
	local trailsEnabled = (currentPhase == RunPhase.Descent
		and currentReleaseAccepted
		and grounded
		and speed >= TRAILS.MinimumSpeed)
		or (currentPhase == RunPhase.Landed and grounded and speed >= TRAILS.MinimumSpeed)
	if inLandingBoost and trailsEnabled then
		trailStrength = 1
	end
	updateTrails(effects, trailsEnabled, trailStrength)

	local sprayStrength = 0
	local surfacePhase = (currentPhase == RunPhase.Descent and currentReleaseAccepted)
		or currentPhase == RunPhase.Landed
	if surfacePhase and grounded and speed >= SNOW_SPRAY.MinimumSpeed then
		sprayStrength = normalizedSpeed(speed, SNOW_SPRAY.MinimumSpeed, SNOW_SPRAY.FullRateSpeed)
	end
	updateSprays(effects, sprayStrength)

	local streaksEnabled = currentPhase == RunPhase.Descent
		and currentReleaseAccepted
		and currentTucking
	if effects.LastStreakEnabled ~= streaksEnabled then
		effects.LastStreakEnabled = streaksEnabled
		effects.Streaks.Enabled = streaksEnabled
		if not streaksEnabled then
			effects.Streaks:Clear()
		end
	end
end

local function resetRunPresentation(runId: number)
	destroyActiveSledEffects()
	currentRunId = runId
	currentPhase = RunPhase.Idle
	currentSpeed = 0
	currentTucking = false
	currentTuckQueued = false
	currentGlowTucking = false
	currentOutcome = nil
	currentReleaseAccepted = false
	nextSledResolveAt = 0
	nextAmbientUpdateAt = 0
	landingBoostUntil = 0
	sawAirborne = false
	sawLanding = false
	pendingLaunchBurst = false
	pendingLandingBurst = false
	pendingCrashBurst = false
	crashBurstRunId = nil
	sledEffectsDisabledRunId = nil
end

function VFXController.start()
	if started then
		return
	end
	started = true

	local existingFolder = Workspace:FindFirstChild(EFFECTS_FOLDER_NAME)
	if existingFolder then
		existingFolder:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = EFFECTS_FOLDER_NAME
	folder.Parent = Workspace
	effectsFolder = folder

	configureWinterGrade()
	createAmbientSnowfall(folder)
	table.insert(controllerConnections, RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now >= nextAmbientUpdateAt then
			nextAmbientUpdateAt = now + AMBIENT_UPDATE_INTERVAL
			updateAmbientSnowfall()
		end
		updateSledPresentation(now)
	end))
	table.insert(controllerConnections, localPlayer.CharacterRemoving:Connect(function()
		currentTuckQueued = false
		currentGlowTucking = false
		destroyActiveSledEffects()
	end))
	table.insert(controllerConnections, script.Destroying:Connect(function()
		VFXController.destroy()
	end))
	diagnostic(if isReducedQuality then "ready quality=reduced" else "ready quality=normal")
end

function VFXController.presentRunState(
	phase: any,
	_countdown: any,
	speed: any,
	runId: any,
	tuckQueued: any,
	tucking: any,
	outcome: any,
	releaseAccepted: any
)
	if not started then
		VFXController.start()
	end
	if typeof(phase) ~= "string"
		or not isKnownPhase(phase)
		or typeof(runId) ~= "number"
		or not isFiniteNumber(runId)
		or runId % 1 ~= 0
		or runId <= 0
	then
		return
	end

	local activeRunId = currentRunId
	if activeRunId and runId < activeRunId then
		return
	end
	if activeRunId ~= runId then
		resetRunPresentation(runId)
	end

	local previousPhase = currentPhase
	currentPhase = phase
	currentSpeed = if typeof(speed) == "number" and isFiniteNumber(speed) then math.max(0, speed) else 0
	currentReleaseAccepted = phase == RunPhase.Descent and releaseAccepted == true
	currentTuckQueued = tuckQueued == true
	currentGlowTucking = tucking == true
	currentTucking = phase == RunPhase.Descent and currentGlowTucking
	currentOutcome = if typeof(outcome) == "string" then outcome else nil

	if phase == RunPhase.Countdown or phase == RunPhase.Descent then
		tryResolveSled()
	end
	if phase == RunPhase.Airborne and previousPhase ~= RunPhase.Airborne and not sawAirborne then
		sawAirborne = true
		local effects = activeSledEffects
		if effects then
			emitLaunchBurst(effects)
		else
			pendingLaunchBurst = true
		end
	elseif phase == RunPhase.Landed and previousPhase ~= RunPhase.Landed and not sawLanding then
		sawLanding = true
		local effects = activeSledEffects
		if effects then
			emitLandingBurst(effects)
		else
			pendingLandingBurst = true
		end
	end
	local resolvedEffects = activeSledEffects
	if resolvedEffects then
		reconcileRunnerGlows(resolvedEffects)
		flushPendingBursts(resolvedEffects)
	end

	if phase == RunPhase.Airborne then
		local effects = activeSledEffects
		if effects then
			disableSledEffects(effects)
		end
	elseif phase == RunPhase.Results then
		local effects = activeSledEffects
		if effects then
			disableSledEffects(effects)
		end
	elseif phase == RunPhase.Reset or phase == RunPhase.Idle then
		destroyActiveSledEffects()
		pendingLaunchBurst = false
		pendingLandingBurst = false
		pendingCrashBurst = false
	end
end

function VFXController.presentResult(payload: ResultTypes.Payload)
	local runId = currentRunId
	if not started
		or runId == nil
		or payload.RunId ~= runId
		or currentPhase == RunPhase.Idle
		or currentPhase == RunPhase.Reset
	then
		return
	end
	currentTuckQueued = false
	currentGlowTucking = false
	currentOutcome = payload.Outcome
	local effects = activeSledEffects
	if effects then
		reconcileRunnerGlows(effects)
	end

	if payload.Outcome == ResultTypes.Outcomes.Crashed and crashBurstRunId ~= payload.RunId then
		crashBurstRunId = payload.RunId
		if effects then
			emitCrashBurst(effects)
		else
			pendingCrashBurst = true
		end
	end
end

function VFXController.clearResultPresentation()
	pendingCrashBurst = false
	currentTuckQueued = false
	currentGlowTucking = false
	local effects = activeSledEffects
	if effects then
		reconcileRunnerGlows(effects)
		disableSledEffects(effects)
		for _, burst in effects.Bursts do
			burst:Clear()
		end
	end
end

function VFXController.destroy()
	if not started then
		return
	end
	started = false
	disconnectAll(controllerConnections)
	destroyActiveSledEffects()
	restoreWinterGrade()

	table.clear(ambientSnowLayers)
	local folder = effectsFolder
	effectsFolder = nil
	if folder then
		folder:Destroy()
	end

	currentRunId = nil
	currentPhase = RunPhase.Idle
	currentSpeed = 0
	currentTucking = false
	currentTuckQueued = false
	currentGlowTucking = false
	currentOutcome = nil
	currentReleaseAccepted = false
	nextAmbientUpdateAt = 0
	landingBoostUntil = 0
	pendingLaunchBurst = false
	pendingLandingBurst = false
	pendingCrashBurst = false
	sledEffectsDisabledRunId = nil
end

return VFXController
