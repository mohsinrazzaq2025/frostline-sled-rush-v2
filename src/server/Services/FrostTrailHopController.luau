--!strict

local FrostTrailConfig = require(script.Parent.FrostTrailConfig)

export type HopTuning = FrostTrailConfig.HopTuning

export type HopState = {
	LastSeenSequence: number,
	LastAcceptedAt: number,
	RateTokens: number,
	RateRefillAt: number,
	Active: boolean,
	SawSeparation: boolean,
	Invalidated: boolean,
}

type Api = {
	validateProfile: (any) -> (boolean, string),
	createState: (HopTuning, number) -> HopState,
	admitIntent: (HopState, HopTuning, number, number) -> boolean,
	isCloseGround: (HopTuning, BasePart, RaycastResult?) -> boolean,
	tryHop: (HopState, HopTuning, BasePart, number) -> boolean,
	updateActive: (HopState, HopTuning, BasePart, RaycastResult?) -> boolean,
	completeLanding: (HopState) -> (),
	invalidate: (HopState?) -> (),
}

local EXPECTED_PROFILE_KEYS: { [string]: boolean } = table.freeze({
	Enabled = true,
	VerticalDeltaVelocity = true,
	CooldownSeconds = true,
	StartLongitudinal = true,
	EndLongitudinal = true,
	MinimumHorizontalSpeed = true,
	GroundRayDistance = true,
	MaximumGroundHitDistance = true,
	MinimumGroundNormalY = true,
	MaximumAbsoluteGroundNormalSpeed = true,
	MaximumSequence = true,
	MaximumSequenceJump = true,
	ServerRateTokensPerSecond = true,
	ServerRateBucketCapacity = true,
})
local EXPECTED_PROFILE_KEY_COUNT = 14
local VECTOR_EPSILON = 1e-5

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isFinitePositiveNumber(value: number): boolean
	return isFiniteNumber(value) and value > 0
end

local function isFiniteVector3(value: Vector3): boolean
	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function hasExactProfileIdentity(profile: HopTuning): boolean
	return profile == FrostTrailConfig.Hop
		and table.isfrozen(FrostTrailConfig)
		and table.isfrozen(profile)
end

local function validateProfile(profileValue: any): (boolean, string)
	if typeof(profileValue) ~= "table" then
		return false, "Frost hop profile is unavailable"
	end

	local profile = profileValue :: any
	if profile ~= FrostTrailConfig.Hop
		or not table.isfrozen(FrostTrailConfig)
		or not table.isfrozen(profile)
	then
		return false, "Frost hop profile identity or freeze is invalid"
	end

	local observedKeyCount = 0
	for key in profile do
		if typeof(key) ~= "string" then
			return false, "Frost hop profile contains an unexpected field"
		end
		if EXPECTED_PROFILE_KEYS[key] ~= true then
			return false, "Frost hop profile contains an unexpected field"
		end
		observedKeyCount += 1
	end
	if observedKeyCount ~= EXPECTED_PROFILE_KEY_COUNT then
		return false, "Frost hop profile field set is incomplete"
	elseif profile.Enabled ~= true then
		return false, "Frost hop profile is not enabled"
	elseif typeof(profile.VerticalDeltaVelocity) ~= "number"
		or typeof(profile.CooldownSeconds) ~= "number"
		or typeof(profile.StartLongitudinal) ~= "number"
		or typeof(profile.EndLongitudinal) ~= "number"
		or typeof(profile.MinimumHorizontalSpeed) ~= "number"
		or typeof(profile.GroundRayDistance) ~= "number"
		or typeof(profile.MaximumGroundHitDistance) ~= "number"
		or typeof(profile.MinimumGroundNormalY) ~= "number"
		or typeof(profile.MaximumAbsoluteGroundNormalSpeed) ~= "number"
		or typeof(profile.MaximumSequence) ~= "number"
		or typeof(profile.MaximumSequenceJump) ~= "number"
		or typeof(profile.ServerRateTokensPerSecond) ~= "number"
		or typeof(profile.ServerRateBucketCapacity) ~= "number"
	then
		return false, "Frost hop profile contains a non-numeric value"
	end

	local hop = profile :: HopTuning
	if not isFinitePositiveNumber(hop.VerticalDeltaVelocity)
		or not isFinitePositiveNumber(hop.CooldownSeconds)
		or not isFiniteNumber(hop.StartLongitudinal)
		or not isFinitePositiveNumber(hop.EndLongitudinal)
		or not isFinitePositiveNumber(hop.MinimumHorizontalSpeed)
		or not isFinitePositiveNumber(hop.GroundRayDistance)
		or not isFinitePositiveNumber(hop.MaximumGroundHitDistance)
		or not isFinitePositiveNumber(hop.MinimumGroundNormalY)
		or not isFinitePositiveNumber(hop.MaximumAbsoluteGroundNormalSpeed)
		or not isFinitePositiveNumber(hop.MaximumSequence)
		or not isFinitePositiveNumber(hop.MaximumSequenceJump)
		or not isFinitePositiveNumber(hop.ServerRateTokensPerSecond)
		or not isFinitePositiveNumber(hop.ServerRateBucketCapacity)
	then
		return false, "Frost hop profile contains an invalid numeric value"
	elseif hop.MaximumSequence % 1 ~= 0
		or hop.MaximumSequenceJump % 1 ~= 0
		or hop.ServerRateBucketCapacity % 1 ~= 0
	then
		return false, "Frost hop integer fields are invalid"
	elseif hop.VerticalDeltaVelocity ~= 59.4
		or hop.CooldownSeconds ~= 0.10
		or hop.StartLongitudinal ~= -200
		or hop.EndLongitudinal ~= 6000
		or hop.MinimumHorizontalSpeed ~= 12
		or hop.GroundRayDistance ~= 5
		or hop.MaximumGroundHitDistance ~= 1.10
		or hop.MinimumGroundNormalY ~= 0.90
		or hop.MaximumAbsoluteGroundNormalSpeed ~= 8
		or hop.MaximumSequence ~= 2147483647
		or hop.MaximumSequenceJump ~= 32
		or hop.ServerRateTokensPerSecond ~= 6
		or hop.ServerRateBucketCapacity ~= 3
	then
		return false, "Frost hop profile constants are invalid"
	end

	local firstPathPoint = FrostTrailConfig.PathPoints[1]
	if not isFiniteVector3(firstPathPoint)
		or firstPathPoint.Z ~= -250
		or FrostTrailConfig.RampFreedomLongitudinal ~= 6100
		or FrostTrailConfig.LandingStartLongitudinal ~= 6350
		or hop.StartLongitudinal < firstPathPoint.Z
		or hop.StartLongitudinal >= hop.EndLongitudinal
		or hop.EndLongitudinal >= FrostTrailConfig.RampFreedomLongitudinal
		or hop.EndLongitudinal >= FrostTrailConfig.LandingStartLongitudinal
		or hop.GroundRayDistance ~= FrostTrailConfig.Steering.GroundRayDistance
		or hop.MaximumGroundHitDistance >= hop.GroundRayDistance
		or hop.MinimumGroundNormalY <= 0
		or hop.MinimumGroundNormalY > 1
		or hop.MaximumSequenceJump > hop.MaximumSequence
		or hop.ServerRateBucketCapacity > hop.ServerRateTokensPerSecond
	then
		return false, "Frost hop profile relationships are invalid"
	end

	return true, "ok"
end

local function createState(profile: HopTuning, now: number): HopState
	assert(hasExactProfileIdentity(profile), "Frost hop profile identity is invalid")
	assert(isFiniteNumber(now), "Frost hop state time is invalid")
	return {
		LastSeenSequence = 0,
		LastAcceptedAt = -math.huge,
		RateTokens = profile.ServerRateBucketCapacity,
		RateRefillAt = now,
		Active = false,
		SawSeparation = false,
		Invalidated = false,
	}
end

local function admitIntent(state: HopState, profile: HopTuning, sequence: number, now: number): boolean
	if state.Invalidated or not hasExactProfileIdentity(profile) or not isFiniteNumber(now) then
		return false
	elseif sequence <= state.LastSeenSequence
		or sequence - state.LastSeenSequence > profile.MaximumSequenceJump
	then
		return false
	end
	state.LastSeenSequence = sequence

	local elapsed = math.max(0, now - state.RateRefillAt)
	local tokens = math.min(
		profile.ServerRateBucketCapacity,
		state.RateTokens + elapsed * profile.ServerRateTokensPerSecond
	)
	state.RateRefillAt = now
	if tokens < 1 then
		state.RateTokens = tokens
		return false
	end
	state.RateTokens = tokens - 1

	if state.Active or now - state.LastAcceptedAt < profile.CooldownSeconds then
		return false
	end
	return true
end

local function isCloseGround(profile: HopTuning, root: BasePart, groundResult: RaycastResult?): boolean
	if not hasExactProfileIdentity(profile)
		or profile.GroundRayDistance ~= FrostTrailConfig.Steering.GroundRayDistance
		or groundResult == nil
	then
		return false
	end

	local distance = groundResult.Distance
	local normal = groundResult.Normal
	local velocity = root.AssemblyLinearVelocity
	if not isFiniteNumber(distance)
		or distance < 0
		or distance > profile.MaximumGroundHitDistance
		or not isFiniteVector3(normal)
		or normal.Magnitude <= VECTOR_EPSILON
		or not isFiniteVector3(velocity)
	then
		return false
	end

	local unitNormal = normal.Unit
	return unitNormal.Y >= profile.MinimumGroundNormalY
		and math.abs(velocity:Dot(unitNormal)) <= profile.MaximumAbsoluteGroundNormalSpeed
end

local function tryHop(
	state: HopState,
	profile: HopTuning,
	root: BasePart,
	now: number
): boolean
	local assemblyMass = root.AssemblyMass
	if state.Invalidated
		or state.Active
		or not hasExactProfileIdentity(profile)
		or not isFiniteNumber(now)
		or not isFinitePositiveNumber(assemblyMass)
	then
		return false
	end

	local succeeded = pcall(function()
		root:ApplyImpulse(Vector3.yAxis * root.AssemblyMass * profile.VerticalDeltaVelocity)
	end)
	if not succeeded then
		state.Active = false
		state.SawSeparation = false
		return false
	end

	state.LastAcceptedAt = now
	state.Active = true
	state.SawSeparation = false
	return true
end

local function completeLanding(state: HopState)
	state.Active = false
	state.SawSeparation = false
end

local function updateActive(
	state: HopState,
	profile: HopTuning,
	root: BasePart,
	groundResult: RaycastResult?
): boolean
	if state.Invalidated or not state.Active then
		return false
	elseif not hasExactProfileIdentity(profile) then
		state.Invalidated = true
		state.Active = false
		state.SawSeparation = false
		return false
	end

	local separated = groundResult == nil
	if groundResult then
		local distance = groundResult.Distance
		local normal = groundResult.Normal
		local velocity = root.AssemblyLinearVelocity
		if not isFiniteNumber(distance)
			or distance < 0
			or distance > profile.MaximumGroundHitDistance
			or not isFiniteVector3(normal)
			or normal.Magnitude <= VECTOR_EPSILON
			or not isFiniteVector3(velocity)
		then
			separated = true
		else
			local normalSpeed = velocity:Dot(normal.Unit)
			if not isFiniteNumber(normalSpeed)
				or math.abs(normalSpeed) > profile.MaximumAbsoluteGroundNormalSpeed
			then
				separated = true
			end
		end
	end

	if separated then
		state.SawSeparation = true
	elseif state.SawSeparation and isCloseGround(profile, root, groundResult) then
		completeLanding(state)
	end
	return state.Active
end

local function invalidate(state: HopState?)
	if state == nil then
		return
	end
	state.Invalidated = true
	state.Active = false
	state.SawSeparation = false
end

local api: Api = {
	validateProfile = validateProfile,
	createState = createState,
	admitIntent = admitIntent,
	isCloseGround = isCloseGround,
	tryHop = tryHop,
	updateActive = updateActive,
	completeLanding = completeLanding,
	invalidate = invalidate,
}

return table.freeze(api)
