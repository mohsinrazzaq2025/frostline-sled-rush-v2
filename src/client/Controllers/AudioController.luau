--!strict

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local AUDIO = GameConfig.Audio
local MUSIC = AUDIO.Music
local AUDIO_FOLDER_NAME = "FrostlineAudio"
local COIN_REWARD_DELAY_SECONDS = 0.28
local ROUTE_COIN_CUE_COOLDOWN_SECONDS = 0.08
local ROUTE_OBSTACLE_CUE_COOLDOWN_SECONDS = 0.35

type CueName =
	"BackgroundMusic"
	| "SledSnowSlide"
	| "CountdownBeep"
	| "LaunchWhoosh"
	| "TuckWhoosh"
	| "SnowImpact"
	| "CoinReward"
	| "Victory"
	| "Failure"
	| "UIButton"

type CueDefinition = {
	Asset: string,
	Volume: number,
	Looping: boolean,
}

type Cue = {
	Name: CueName,
	Player: AudioPlayer,
	Wire: Wire,
	BaseVolume: number,
	Looping: boolean,
	Disabled: boolean,
	Warned: boolean,
	Playing: boolean,
	StopGeneration: number,
	VolumeTween: Tween?,
}

type RunAudioState = {
	RunId: number,
	Phase: string,
	ReleaseAccepted: boolean,
	Tucking: boolean,
	LastTuckCueAt: number,
	LastSpeed: number,
	SeenCountdown: { [number]: boolean },
	LaunchPlayed: boolean,
	LandingPlayed: boolean,
	ResultPlayed: boolean,
	ButtonPlayed: boolean,
	TransientsSuppressed: boolean,
	LastRouteCoinCueAt: number,
	LastRouteObstacleCueAt: number,
}

local CUE_DEFINITIONS: { [CueName]: CueDefinition } = {
	BackgroundMusic = {
		Asset = AUDIO.Assets.BackgroundMusic,
		Volume = MUSIC.IdleTarget,
		Looping = true,
	},
	SledSnowSlide = {
		Asset = AUDIO.Assets.SledSnowSlide,
		Volume = AUDIO.Volumes.SledSnowSlide,
		Looping = true,
	},
	CountdownBeep = {
		Asset = AUDIO.Assets.CountdownBeep,
		Volume = AUDIO.Volumes.CountdownBeep,
		Looping = false,
	},
	LaunchWhoosh = {
		Asset = AUDIO.Assets.LaunchWhoosh,
		Volume = AUDIO.Volumes.LaunchWhoosh,
		Looping = false,
	},
	TuckWhoosh = {
		Asset = AUDIO.Assets.TuckWhoosh,
		Volume = AUDIO.Volumes.TuckWhoosh,
		Looping = false,
	},
	SnowImpact = {
		Asset = AUDIO.Assets.SnowImpact,
		Volume = AUDIO.Volumes.SnowImpact,
		Looping = false,
	},
	CoinReward = {
		Asset = AUDIO.Assets.CoinReward,
		Volume = AUDIO.Volumes.CoinReward,
		Looping = false,
	},
	Victory = {
		Asset = AUDIO.Assets.Victory,
		Volume = AUDIO.Volumes.Victory,
		Looping = false,
	},
	Failure = {
		Asset = AUDIO.Assets.Failure,
		Volume = AUDIO.Volumes.Failure,
		Looping = false,
	},
	UIButton = {
		Asset = AUDIO.Assets.UIButton,
		Volume = AUDIO.Volumes.UIButton,
		Looping = false,
	},
}

local TRANSIENT_CUE_NAMES: { CueName } = {
	"SledSnowSlide",
	"CountdownBeep",
	"LaunchWhoosh",
	"TuckWhoosh",
	"SnowImpact",
	"CoinReward",
	"Victory",
	"Failure",
	"UIButton",
}

local RESULT_CUE_NAMES: { CueName } = {
	"Victory",
	"Failure",
	"CoinReward",
}

local AudioController = {}

local started = false
local destroyed = false
local audioFolder: Folder? = nil
local deviceOutput: AudioDeviceOutput? = nil
local cues: { [CueName]: Cue } = {}
local connections: { RBXScriptConnection } = {}
local currentRun: RunAudioState? = nil
local latestRunId = 0
local latestResultRunId = 0
local resultGeneration = 0
local musicDuckGeneration = 0
local musicDuckUntil = 0
local musicPhase = RunPhase.Idle
local musicRequested = false
local musicStarted = false
local musicTargetVolume = MUSIC.IdleTarget

local function diagnostic(message: string)
	if AUDIO.DiagnosticsEnabled then
		print(string.format("[Frostline][Audio] %s", message))
	end
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isValidRunId(value: any): boolean
	return typeof(value) == "number" and value > 0 and value % 1 == 0
end

local function isKnownPhase(value: any): boolean
	return value == RunPhase.Idle
		or value == RunPhase.Countdown
		or value == RunPhase.Descent
		or value == RunPhase.Airborne
		or value == RunPhase.Landed
		or value == RunPhase.Results
		or value == RunPhase.Reset
end

local function isKnownOutcome(value: any): boolean
	return value == ResultTypes.Outcomes.CleanLanding
		or value == ResultTypes.Outcomes.Crashed
		or value == ResultTypes.Outcomes.Stalled
end

local function isCueCurrent(cue: Cue): boolean
	return started and not destroyed and cues[cue.Name] == cue and cue.Player.Parent ~= nil
end

local function cancelVolumeTween(cue: Cue)
	local tween = cue.VolumeTween
	cue.VolumeTween = nil
	if tween then
		tween:Cancel()
		tween:Destroy()
	end
end

local function stopCueImmediately(cue: Cue)
	cue.StopGeneration += 1
	cancelVolumeTween(cue)
	cue.Playing = false
	pcall(function()
		cue.Player:Stop()
		cue.Player.Volume = 0
	end)
end

local function disableCue(cue: Cue, reason: string)
	if cue.Disabled then
		return
	end

	cue.Disabled = true
	stopCueImmediately(cue)
	if not cue.Warned then
		cue.Warned = true
		warn(string.format("[Frostline][Audio] Disabled %s: %s", cue.Name, reason))
	end
end

local function tweenVolume(cue: Cue, targetVolume: number, duration: number)
	if cue.Disabled or not isCueCurrent(cue) then
		return
	end

	cancelVolumeTween(cue)
	local clampedTarget = math.max(0, targetVolume)
	if duration <= 0 then
		cue.Player.Volume = clampedTarget
		return
	end

	local tween = TweenService:Create(
		cue.Player,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Volume = clampedTarget }
	)
	cue.VolumeTween = tween
	tween.Completed:Once(function()
		if cue.VolumeTween == tween then
			cue.VolumeTween = nil
			tween:Destroy()
		end
	end)
	tween:Play()
end

local function playOneShot(cueName: CueName): boolean
	local cue = cues[cueName]
	if not cue or cue.Disabled or not isCueCurrent(cue) or not cue.Player.IsReady then
		return false
	end

	cue.StopGeneration += 1
	cancelVolumeTween(cue)
	local succeeded, failureReason = pcall(function()
		cue.Player:Stop()
		cue.Player.TimePosition = 0
		cue.Player.Volume = cue.BaseVolume
		cue.Player:Play()
	end)
	if not succeeded then
		disableCue(cue, string.format("play failed (%s)", tostring(failureReason)))
		return false
	end

	cue.Playing = true
	return true
end

local function playLoop(cue: Cue, targetVolume: number, fadeDuration: number): boolean
	if cue.Disabled or not isCueCurrent(cue) or not cue.Player.IsReady then
		return false
	end

	cue.StopGeneration += 1
	if not cue.Playing then
		cancelVolumeTween(cue)
		local succeeded, failureReason = pcall(function()
			cue.Player:Stop()
			cue.Player.TimePosition = 0
			cue.Player.Volume = 0
			cue.Player:Play()
		end)
		if not succeeded then
			disableCue(cue, string.format("play failed (%s)", tostring(failureReason)))
			return false
		end
		cue.Playing = true
	end

	tweenVolume(cue, targetVolume, fadeDuration)
	return true
end

local function fadeStopCue(cue: Cue, duration: number)
	if cue.Disabled or not cue.Playing then
		return
	end

	cue.StopGeneration += 1
	local stopGeneration = cue.StopGeneration
	tweenVolume(cue, 0, duration)
	task.delay(math.max(0, duration), function()
		if not isCueCurrent(cue) or cue.StopGeneration ~= stopGeneration then
			return
		end
		cue.Playing = false
		pcall(function()
			cue.Player:Stop()
		end)
	end)
end

local function musicTargetForPhase(phase: string): number
	if phase == RunPhase.Countdown then
		return MUSIC.CountdownTarget
	elseif phase == RunPhase.Descent then
		return MUSIC.DescentTarget
	elseif phase == RunPhase.Airborne then
		return MUSIC.AirborneTarget
	elseif phase == RunPhase.Landed then
		return MUSIC.LandedTarget
	elseif phase == RunPhase.Results then
		return MUSIC.ResultsTarget
	end
	return MUSIC.IdleTarget
end

local function isPriorityDuckActive(): boolean
	return os.clock() < musicDuckUntil
end

local function ensureMusicPlaying()
	if not musicRequested or musicStarted or destroyed then
		return
	end

	local cue = cues.BackgroundMusic
	if not cue or cue.Disabled or not cue.Player.IsReady then
		return
	end

	if playLoop(cue, musicTargetVolume, AUDIO.MusicFadeInSeconds) then
		musicStarted = true
		diagnostic("background music started")
	end
end

local function setMusicVolume(targetVolume: number, duration: number)
	local targetChanged = math.abs(targetVolume - musicTargetVolume) > 0.0001
	musicTargetVolume = targetVolume
	ensureMusicPlaying()
	if not musicStarted or not targetChanged then
		return
	end

	local cue = cues.BackgroundMusic
	if cue and not cue.Disabled then
		tweenVolume(cue, targetVolume, duration)
	end
end

local function slideTargetVolume(speed: number, landed: boolean): number
	local movingThreshold = AUDIO.SlideMovingThreshold
	local fullVolumeSpeed = math.max(movingThreshold + 0.001, AUDIO.SlideFullVolumeSpeed)
	local speedAlpha = math.clamp((speed - movingThreshold) / (fullVolumeSpeed - movingThreshold), 0, 1)
	local surfaceMultiplier = if landed then AUDIO.LakeSlideVolumeMultiplier else 1
	if isPriorityDuckActive() then
		surfaceMultiplier *= MUSIC.SlideDuckMultiplier
	end
	return AUDIO.Volumes.SledSnowSlide * speedAlpha * surfaceMultiplier
end

local function updateSlideForCurrentRun()
	local runState = currentRun
	local cue = cues.SledSnowSlide
	if not runState
		or not cue
		or runState.TransientsSuppressed
		or not runState.ReleaseAccepted
		or (runState.Phase ~= RunPhase.Descent and runState.Phase ~= RunPhase.Landed)
	then
		return
	end

	local targetVolume = slideTargetVolume(runState.LastSpeed, runState.Phase == RunPhase.Landed)
	if targetVolume <= 0 then
		fadeStopCue(cue, AUDIO.ShortFadeSeconds)
	else
		playLoop(cue, targetVolume, AUDIO.ShortFadeSeconds)
	end
end

local function applyMusicTarget(duration: number)
	local targetVolume = if isPriorityDuckActive()
		then MUSIC.PriorityCueDuckTarget
		else musicTargetForPhase(musicPhase)
	setMusicVolume(targetVolume, duration)
end

local function setMusicPhase(phase: string)
	musicPhase = phase
	applyMusicTarget(MUSIC.NormalReleaseSeconds)
end

local scheduleMusicRestoreForGeneration: (number) -> ()
scheduleMusicRestoreForGeneration = function(generation: number)
	local remaining = math.max(0, musicDuckUntil - os.clock())
	task.delay(remaining, function()
		if destroyed or generation ~= musicDuckGeneration then
			return
		end

		if os.clock() < musicDuckUntil then
			scheduleMusicRestoreForGeneration(generation)
			return
		end

		musicDuckUntil = 0
		applyMusicTarget(MUSIC.NormalReleaseSeconds)
		updateSlideForCurrentRun()
	end)
end

local function requestPriorityDuckUntil(deadline: number)
	local now = os.clock()
	if deadline <= now or deadline <= musicDuckUntil then
		return
	end

	musicDuckUntil = deadline
	musicDuckGeneration += 1
	local generation = musicDuckGeneration
	applyMusicTarget(MUSIC.DuckAttackSeconds)
	updateSlideForCurrentRun()
	scheduleMusicRestoreForGeneration(generation)
end

local function requestPriorityDuck(duration: number)
	requestPriorityDuckUntil(os.clock() + math.max(0, duration))
end

local function clearPriorityDuck()
	musicDuckGeneration += 1
	musicDuckUntil = 0
end

local function playDuckedOneShot(cueName: CueName, duration: number): boolean
	if not playOneShot(cueName) then
		return false
	end
	requestPriorityDuck(duration)
	return true
end

local function stopTransientInternal(suppressCurrentRun: boolean)
	resultGeneration += 1
	if currentRun then
		currentRun.LastRouteCoinCueAt = -math.huge
		currentRun.LastRouteObstacleCueAt = -math.huge
		if suppressCurrentRun then
			currentRun.TransientsSuppressed = true
		end
	end

	for _, cueName in TRANSIENT_CUE_NAMES do
		local cue = cues[cueName]
		if cue and not cue.Disabled then
			fadeStopCue(cue, AUDIO.ShortFadeSeconds)
		end
	end
end

local function makeRunState(runId: number, phase: string): RunAudioState
	return {
		RunId = runId,
		Phase = phase,
		ReleaseAccepted = false,
		Tucking = false,
		LastTuckCueAt = -math.huge,
		LastSpeed = 0,
		SeenCountdown = {},
		LaunchPlayed = false,
		LandingPlayed = false,
		ResultPlayed = false,
		ButtonPlayed = false,
		TransientsSuppressed = false,
		LastRouteCoinCueAt = -math.huge,
		LastRouteObstacleCueAt = -math.huge,
	}
end

local function beginPreload(cue: Cue)
	task.delay(AUDIO.PreloadTimeoutSeconds, function()
		if isCueCurrent(cue) and not cue.Disabled and not cue.Player.IsReady then
			disableCue(cue, "asset did not become ready before the preload timeout")
		end
	end)

	task.spawn(function()
		local succeeded, failureReason = pcall(function()
			ContentProvider:PreloadAsync({ cue.Player }, function(_contentId: string, status: Enum.AssetFetchStatus)
				if not isCueCurrent(cue) or cue.Disabled then
					return
				end
				if status ~= Enum.AssetFetchStatus.Success then
					disableCue(cue, string.format("asset preload returned %s", status.Name))
				end
			end)
		end)
		if not succeeded then
			diagnostic(string.format("%s preload request failed: %s", cue.Name, tostring(failureReason)))
		end
	end)
end

function AudioController.start()
	if started then
		return
	end
	started = true
	destroyed = false

	local previous = SoundService:FindFirstChild(AUDIO_FOLDER_NAME)
	if previous then
		previous:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = AUDIO_FOLDER_NAME
	folder.Parent = SoundService
	audioFolder = folder

	local output = Instance.new("AudioDeviceOutput")
	output.Name = "LocalDeviceOutput"
	output.Player = Players.LocalPlayer
	output.Parent = folder
	deviceOutput = output

	for cueName, definition in CUE_DEFINITIONS do
		local player = Instance.new("AudioPlayer")
		player.Name = cueName
		player.Asset = definition.Asset
		player.AutoLoad = true
		player.AutoPlay = false
		player.Looping = definition.Looping
		player.Volume = 0
		player.Parent = folder

		local wire = Instance.new("Wire")
		wire.Name = cueName .. "Wire"
		wire.SourceInstance = player
		wire.TargetInstance = output
		wire.Parent = folder

		local cue: Cue = {
			Name = cueName,
			Player = player,
			Wire = wire,
			BaseVolume = definition.Volume,
			Looping = definition.Looping,
			Disabled = false,
			Warned = false,
			Playing = false,
			StopGeneration = 0,
			VolumeTween = nil,
		}
		cues[cueName] = cue

		table.insert(connections, player.Ended:Connect(function()
			if isCueCurrent(cue) and not cue.Looping then
				cue.Playing = false
			end
		end))
		table.insert(connections, player:GetPropertyChangedSignal("IsReady"):Connect(function()
			if not player.IsReady or not isCueCurrent(cue) then
				return
			end
			if cue.Name == "BackgroundMusic" then
				ensureMusicPlaying()
			elseif cue.Name == "SledSnowSlide" then
				updateSlideForCurrentRun()
			end
		end))

		beginPreload(cue)
	end

	table.insert(connections, Players.LocalPlayer.CharacterRemoving:Connect(function(_character: Model)
		stopTransientInternal(true)
		clearPriorityDuck()
		setMusicPhase(RunPhase.Idle)
	end))
	table.insert(connections, script.Destroying:Connect(function()
		AudioController.destroy()
	end))

	musicPhase = RunPhase.Idle
	clearPriorityDuck()
	musicRequested = true
	musicTargetVolume = MUSIC.IdleTarget
	ensureMusicPlaying()
	diagnostic("controller ready")
end

function AudioController.presentRunState(
	phase: any,
	countdown: any,
	speed: any,
	runId: any,
	_tuckQueued: any,
	tucking: any,
	_outcome: any,
	releaseAccepted: any
)
	if not started
		or destroyed
		or not isKnownPhase(phase)
		or not isValidRunId(runId)
		or runId < latestRunId
	then
		return
	end

	local numericRunId = runId :: number
	local runState = currentRun
	if numericRunId > latestRunId or not runState or runState.RunId ~= numericRunId then
		stopTransientInternal(false)
		latestRunId = numericRunId
		resultGeneration += 1
		clearPriorityDuck()
		runState = makeRunState(numericRunId, phase :: string)
		currentRun = runState
	end
	if runState.ResultPlayed
		and phase ~= RunPhase.Results
		and phase ~= RunPhase.Reset
		and phase ~= RunPhase.Idle
	then
		return
	end
	if runState.TransientsSuppressed and phase ~= RunPhase.Reset and phase ~= RunPhase.Idle then
		return
	end

	local previousPhase = runState.Phase
	runState.Phase = phase :: string
	if phase == RunPhase.Reset or phase == RunPhase.Idle then
		clearPriorityDuck()
	end
	setMusicPhase(runState.Phase)
	if isFiniteNumber(speed) then
		runState.LastSpeed = math.max(0, speed :: number)
	end

	if phase == RunPhase.Countdown then
		if typeof(countdown) == "number"
			and countdown >= 1
			and countdown <= 3
			and countdown % 1 == 0
			and not runState.SeenCountdown[countdown]
			and not runState.TransientsSuppressed
		then
			runState.SeenCountdown[countdown] = true
			playDuckedOneShot("CountdownBeep", MUSIC.CountdownDuckSeconds)
		end
	elseif phase == RunPhase.Descent then
		if releaseAccepted == true and not runState.ReleaseAccepted then
			runState.ReleaseAccepted = true
			updateSlideForCurrentRun()
		end

		local acceptedTuck = tucking == true and runState.ReleaseAccepted
		if acceptedTuck
			and not runState.Tucking
			and not runState.TransientsSuppressed
			and os.clock() - runState.LastTuckCueAt >= AUDIO.TuckReplayCooldownSeconds
		then
			runState.LastTuckCueAt = os.clock()
			playDuckedOneShot("TuckWhoosh", MUSIC.TuckDuckSeconds)
		end
		runState.Tucking = acceptedTuck
		updateSlideForCurrentRun()
	elseif phase == RunPhase.Airborne then
		runState.Tucking = false
		if previousPhase ~= RunPhase.Airborne
			and not runState.LaunchPlayed
			and not runState.TransientsSuppressed
		then
			local slideCue = cues.SledSnowSlide
			if slideCue then
				fadeStopCue(slideCue, AUDIO.ShortFadeSeconds)
			end
			runState.LaunchPlayed = true
			playDuckedOneShot("LaunchWhoosh", MUSIC.LaunchDuckSeconds)
		end
	elseif phase == RunPhase.Landed then
		runState.Tucking = false
		if previousPhase ~= RunPhase.Landed
			and not runState.LandingPlayed
			and not runState.TransientsSuppressed
		then
			runState.LandingPlayed = true
			playDuckedOneShot("SnowImpact", MUSIC.ImpactDuckSeconds)
		end
		updateSlideForCurrentRun()
	elseif phase == RunPhase.Results then
		if previousPhase ~= RunPhase.Results then
			local slideCue = cues.SledSnowSlide
			if slideCue then
				fadeStopCue(slideCue, AUDIO.ShortFadeSeconds)
			end
		end
	elseif phase == RunPhase.Reset or phase == RunPhase.Idle then
		stopTransientInternal(true)
	end
end

function AudioController.presentRouteContent(runId: any, hasCoin: any, hasObstacle: any)
	if not started
		or destroyed
		or not isValidRunId(runId)
		or typeof(hasCoin) ~= "boolean"
		or typeof(hasObstacle) ~= "boolean"
		or (not hasCoin and not hasObstacle)
	then
		return
	end

	local runState = currentRun
	if not runState
		or runState.RunId ~= (runId :: number)
		or runState.Phase ~= RunPhase.Descent
		or not runState.ReleaseAccepted
		or runState.TransientsSuppressed
	then
		return
	end

	local now = os.clock()
	if hasCoin and now - runState.LastRouteCoinCueAt >= ROUTE_COIN_CUE_COOLDOWN_SECONDS then
		runState.LastRouteCoinCueAt = now
		playOneShot("CoinReward")
	end
	if hasObstacle and now - runState.LastRouteObstacleCueAt >= ROUTE_OBSTACLE_CUE_COOLDOWN_SECONDS then
		runState.LastRouteObstacleCueAt = now
		playOneShot("SnowImpact")
	end
end

function AudioController.presentResult(payload: ResultTypes.Payload)
	if not started
		or destroyed
		or typeof(payload) ~= "table"
		or payload.Version ~= ResultTypes.Version
		or not isValidRunId(payload.RunId)
		or not isKnownOutcome(payload.Outcome)
		or typeof(payload.FrostCoinsEarned) ~= "number"
		or payload.FrostCoinsEarned < 0
		or payload.FrostCoinsEarned % 1 ~= 0
		or payload.RunId < latestRunId
		or payload.RunId <= latestResultRunId
	then
		return
	end

	local runState = currentRun
	if not runState or runState.RunId ~= payload.RunId then
		stopTransientInternal(false)
		clearPriorityDuck()
		latestRunId = payload.RunId
		runState = makeRunState(payload.RunId, RunPhase.Results)
		currentRun = runState
	elseif runState.Phase == RunPhase.Reset or runState.Phase == RunPhase.Idle then
		return
	end
	if runState.ResultPlayed or runState.TransientsSuppressed then
		return
	end
	runState.Phase = RunPhase.Results
	runState.Tucking = false
	setMusicPhase(RunPhase.Results)
	local slideCue = cues.SledSnowSlide
	if slideCue then
		fadeStopCue(slideCue, AUDIO.ShortFadeSeconds)
	end

	latestResultRunId = payload.RunId
	runState.ResultPlayed = true
	local resultDuckDeadline = os.clock() + MUSIC.ResultDuckSeconds
	local stingerPlayed = false
	if payload.Outcome == ResultTypes.Outcomes.CleanLanding then
		stingerPlayed = playOneShot("Victory")
	else
		stingerPlayed = playOneShot("Failure")
	end
	if stingerPlayed then
		requestPriorityDuckUntil(resultDuckDeadline)
	end

	resultGeneration += 1
	local generation = resultGeneration
	if payload.FrostCoinsEarned > 0 then
		task.delay(COIN_REWARD_DELAY_SECONDS, function()
			local activeRun = currentRun
			if destroyed
				or generation ~= resultGeneration
				or not activeRun
				or activeRun ~= runState
				or activeRun.Phase ~= RunPhase.Results
				or activeRun.TransientsSuppressed
			then
				return
			end
			if playOneShot("CoinReward") then
				requestPriorityDuckUntil(resultDuckDeadline)
			end
		end)
	end
end

function AudioController.playAcceptedButton(runId: number)
	if not started or destroyed or not isValidRunId(runId) then
		return
	end

	local runState = currentRun
	if not runState
		or runState.RunId ~= runId
		or runState.Phase ~= RunPhase.Results
		or runState.ButtonPlayed
		or runState.TransientsSuppressed
	then
		return
	end

	runState.ButtonPlayed = true
	resultGeneration += 1
	for _, cueName in RESULT_CUE_NAMES do
		local cue = cues[cueName]
		if cue then
			fadeStopCue(cue, AUDIO.ShortFadeSeconds)
		end
	end
	playDuckedOneShot("UIButton", MUSIC.ButtonDuckSeconds)
end

function AudioController.stopTransient()
	if not started or destroyed then
		return
	end
	stopTransientInternal(true)
	clearPriorityDuck()
	applyMusicTarget(MUSIC.NormalReleaseSeconds)
end

function AudioController.destroy()
	if not started and destroyed then
		return
	end
	destroyed = true
	started = false
	resultGeneration += 1
	musicDuckGeneration += 1
	musicDuckUntil = 0
	musicPhase = RunPhase.Idle
	musicRequested = false
	musicStarted = false

	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	for _, cue in cues do
		stopCueImmediately(cue)
	end
	table.clear(cues)

	local folder = audioFolder
	audioFolder = nil
	deviceOutput = nil
	if folder then
		folder:Destroy()
	end

	currentRun = nil
	latestRunId = 0
	latestResultRunId = 0
end

return AudioController
