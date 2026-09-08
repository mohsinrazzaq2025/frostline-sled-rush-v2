--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CourseSelectionTypes = require(ReplicatedStorage.Shared.CourseSelectionTypes)

local COURSE_IDS = CourseSelectionTypes.CourseIds
local ACTIONS = CourseSelectionTypes.Actions
local STATUS = CourseSelectionTypes.StatusCodes
local RUN_PHASES = CourseSelectionTypes.RunPhases

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local MAXIMUM_SAFE_PRIMITIVE_STRING_LENGTH = 64

type CourseId = CourseSelectionTypes.CourseId
type Action = CourseSelectionTypes.Action
type StatusCode = CourseSelectionTypes.StatusCode
type RunPhase = CourseSelectionTypes.RunPhase
type Catalog = CourseSelectionTypes.Catalog

type AuthoritativeSnapshot = {
	SelectedCourseId: CourseId,
	CanSelect: boolean,
	RunPhase: RunPhase,
	Courses: Catalog,
}

type ServiceApi = {
	getCourseSelectionState: (Player) -> any,
	selectCourse: (Player, CourseId) -> any,
}

type ShapeDiscriminator = "ExactGetState" | "ExactSelect" | "InvalidShape"
type EnvelopeDisposition = "Valid" | "InvalidRequest" | "UnsupportedVersion"

type RepresentedRequest = {
	RequestId: string,
	ClientSequence: number,
	Action: Action,
	CourseId: CourseId?,
	Fingerprint: string,
	Shape: ShapeDiscriminator,
	Disposition: EnvelopeDisposition,
}

type TerminalSemantics = {
	Ok: boolean,
	StatusCode: StatusCode,
}

type CompletedRequest = {
	RequestId: string,
	ClientSequence: number,
	Action: Action,
	CourseId: CourseId?,
	Fingerprint: string,
	Ok: boolean,
	StatusCode: StatusCode,
}

type InFlightSelect = {
	RequestId: string,
	ClientSequence: number,
	Action: "Select",
	CourseId: CourseId,
	Fingerprint: string,
	PreSelectSnapshot: AuthoritativeSnapshot,
	ServiceGeneration: number,
}

type TokenBucket = {
	Tokens: number,
	LastRefillAt: number,
}

type PlayerRecord = {
	Generation: number,
	TransportBucket: TokenBucket,
	SelectBucket: TokenBucket,
	LastAcceptedClientSequence: number,
	ServerSequence: number,
	ServerSequenceExhaustedWarned: boolean,
	StateUnavailableWarned: boolean,
	DeliveryFailureWarned: boolean,
	CompletedByRequestId: { [string]: CompletedRequest },
	CompletedByClientSequence: { [number]: CompletedRequest },
	CompletedOrder: { CompletedRequest },
	InFlight: InFlightSelect?,
}

type IdentityClassification = "None" | "Same" | "Conflict"

local CourseSelectionService = {}

local records: { [Player]: PlayerRecord } = {}
local latestRecordGeneration = 0
local latestServiceGeneration = 0
local started = false
local destroyed = false
local activeServiceGeneration = 0
local activeRemote: RemoteEvent? = nil
local activeApi: ServiceApi? = nil
local activeGetState: ((Player) -> any)? = nil
local activeSelectCourse: ((Player, CourseId) -> any)? = nil
local requestConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil

local GET_STATE_KEYS = table.freeze({
	ProtocolVersion = true,
	RequestId = true,
	ClientSequence = true,
	Action = true,
})

local SELECT_KEYS = table.freeze({
	ProtocolVersion = true,
	RequestId = true,
	ClientSequence = true,
	Action = true,
	CourseId = true,
})

local SNAPSHOT_KEYS = table.freeze({
	SelectedCourseId = true,
	CanSelect = true,
	RunPhase = true,
	Courses = true,
})

local DESCRIPTOR_KEYS = table.freeze({
	CourseId = true,
	DisplayName = true,
	Available = true,
})

local API_KEYS = table.freeze({
	getCourseSelectionState = true,
	selectCourse = true,
})

local GET_STATE_FAILURES: { [StatusCode]: boolean } = table.freeze({
	[STATUS.InvalidRequest] = true,
	[STATUS.UnsupportedVersion] = true,
	[STATUS.RequestIdConflict] = true,
	[STATUS.RequestInProgress] = true,
	[STATUS.InternalError] = true,
})

local SELECT_FAILURES: { [StatusCode]: boolean } = table.freeze({
	[STATUS.InvalidRequest] = true,
	[STATUS.UnsupportedVersion] = true,
	[STATUS.RequestIdConflict] = true,
	[STATUS.RequestInProgress] = true,
	[STATUS.RateLimited] = true,
	[STATUS.Busy] = true,
	[STATUS.CourseUnavailable] = true,
	[STATUS.CharacterUnavailable] = true,
	[STATUS.TeleportFailed] = true,
	[STATUS.SafetyFallback] = true,
	[STATUS.InternalError] = true,
})

local SELECT_DOMAIN_STATUSES: { [string]: boolean } = table.freeze({
	[STATUS.Success] = true,
	[STATUS.AlreadySelected] = true,
	[STATUS.Busy] = true,
	[STATUS.CourseUnavailable] = true,
	[STATUS.CharacterUnavailable] = true,
	[STATUS.TeleportFailed] = true,
	[STATUS.SafetyFallback] = true,
})

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isBoundedInteger(value: any, minimum: number, maximum: number): boolean
	return isFiniteNumber(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function isKnownCourseId(value: any): boolean
	return value == COURSE_IDS.FrozenLakeV2 or value == COURSE_IDS.FrostTrailV1
end

local function isKnownAction(value: any): boolean
	return value == ACTIONS.GetState or value == ACTIONS.Select
end

local function isKnownRunPhase(value: any): boolean
	return value == RUN_PHASES.Idle
		or value == RUN_PHASES.Countdown
		or value == RUN_PHASES.Descent
		or value == RUN_PHASES.Airborne
		or value == RUN_PHASES.Landed
		or value == RUN_PHASES.Results
		or value == RUN_PHASES.Reset
end

local function isCanonicalLowercaseGuid(value: any): boolean
	if typeof(value) ~= "string" or #value ~= 36 then
		return false
	end
	for index = 1, 36 do
		local byte = string.byte(value, index)
		if index == 9 or index == 14 or index == 19 or index == 24 then
			if byte ~= 45 then
				return false
			end
		elseif byte == nil
			or not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102))
		then
			return false
		end
	end
	return true
end

local function hasExactKeys(value: { [any]: any }, allowed: { [string]: boolean }, expectedCount: number): boolean
	local count = 0
	for key in value do
		count += 1
		if count > expectedCount or typeof(key) ~= "string" or allowed[key] ~= true then
			return false
		end
	end
	return count == expectedCount
end

local function hasExactCourseArrayKeys(value: { [any]: any }): boolean
	local count = 0
	for key in value do
		count += 1
		if count > 2 or (key ~= 1 and key ~= 2) then
			return false
		end
	end
	return count == 2
end

local function encodeBoundedPrimitive(value: any, present: boolean): string?
	if not present then
		return "absent"
	elseif typeof(value) == "string" then
		if #value > MAXIMUM_SAFE_PRIMITIVE_STRING_LENGTH then
			return nil
		end
		return string.format("string:%d:%s", #value, value)
	elseif typeof(value) == "number" then
		if not isFiniteNumber(value)
			or value % 1 ~= 0
			or math.abs(value) > CourseSelectionTypes.MaximumClientSequence
		then
			return nil
		end
		return "number:" .. tostring(value)
	elseif typeof(value) == "boolean" then
		return if value then "boolean:true" else "boolean:false"
	end
	return nil
end

local function fingerprintParts(parts: { string }): string
	local encoded: { string } = table.create(#parts)
	for index, part in parts do
		encoded[index] = string.format("%d:%s", #part, part)
	end
	return table.concat(encoded, "|")
end

local function parseRepresentedRequest(rawRequest: any): RepresentedRequest?
	if typeof(rawRequest) ~= "table" then
		return nil
	end

	local requestId = rawget(rawRequest, "RequestId")
	local clientSequence = rawget(rawRequest, "ClientSequence")
	local actionValue = rawget(rawRequest, "Action")
	if not isCanonicalLowercaseGuid(requestId)
		or not isBoundedInteger(clientSequence, 1, CourseSelectionTypes.MaximumClientSequence)
		or not isKnownAction(actionValue)
	then
		return nil
	end

	local action = actionValue :: Action
	local courseValue = rawget(rawRequest, "CourseId")
	local coursePresent = courseValue ~= nil
	local courseId: CourseId? = nil
	if action == ACTIONS.Select then
		if not isKnownCourseId(courseValue) then
			return nil
		end
		courseId = courseValue :: CourseId
	end

	local protocolValue = rawget(rawRequest, "ProtocolVersion")
	local protocolPresent = protocolValue ~= nil
	local encodedProtocol = encodeBoundedPrimitive(protocolValue, protocolPresent)
	local encodedCourse = encodeBoundedPrimitive(courseValue, coursePresent)
	if encodedProtocol == nil or encodedCourse == nil then
		return nil
	end

	local exactShape = if action == ACTIONS.GetState
		then hasExactKeys(rawRequest, GET_STATE_KEYS, 4)
		else hasExactKeys(rawRequest, SELECT_KEYS, 5)
	local shape: ShapeDiscriminator = if exactShape
		then (if action == ACTIONS.GetState then "ExactGetState" else "ExactSelect")
		else "InvalidShape"

	local disposition: EnvelopeDisposition
	if not exactShape or not isBoundedInteger(protocolValue, 0, CourseSelectionTypes.MaximumClientSequence) then
		disposition = "InvalidRequest"
	elseif protocolValue ~= CourseSelectionTypes.ProtocolVersion then
		disposition = "UnsupportedVersion"
	else
		disposition = "Valid"
	end

	local fingerprint = fingerprintParts({
		encodedProtocol,
		requestId,
		tostring(clientSequence),
		action,
		if coursePresent then "present" else "absent",
		encodedCourse,
		shape,
	})

	return table.freeze({
		RequestId = requestId,
		ClientSequence = clientSequence,
		Action = action,
		CourseId = courseId,
		Fingerprint = fingerprint,
		Shape = shape,
		Disposition = disposition,
	}) :: RepresentedRequest
end

local function isExactRemote(remote: RemoteEvent): boolean
	if remote.Name ~= CourseSelectionTypes.RemoteName then
		return false
	end
	local folder = remote.Parent
	if not folder or not folder:IsA("Folder") or folder.Name ~= REMOTES_FOLDER_NAME or folder.Parent ~= ReplicatedStorage then
		return false
	end
	if ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME) ~= folder
		or folder:FindFirstChild(CourseSelectionTypes.RemoteName) ~= remote
	then
		return false
	end
	local matchingChildren = 0
	for _, child in folder:GetChildren() do
		if child.Name == CourseSelectionTypes.RemoteName then
			matchingChildren += 1
			if child ~= remote or not child:IsA("RemoteEvent") then
				return false
			end
		end
	end
	return matchingChildren == 1
end

local function isExactApi(api: any): boolean
	if typeof(api) ~= "table"
		or typeof(rawget(api, "getCourseSelectionState")) ~= "function"
		or typeof(rawget(api, "selectCourse")) ~= "function"
	then
		return false
	end
	return hasExactKeys(api, API_KEYS, 2)
end

local function createPlayerRecord(): PlayerRecord
	latestRecordGeneration += 1
	local now = os.clock()
	return {
		Generation = latestRecordGeneration,
		TransportBucket = {
			Tokens = CourseSelectionTypes.TransportRateBucketCapacity,
			LastRefillAt = now,
		},
		SelectBucket = {
			Tokens = CourseSelectionTypes.SelectRateBucketCapacity,
			LastRefillAt = now,
		},
		LastAcceptedClientSequence = 0,
		ServerSequence = 0,
		ServerSequenceExhaustedWarned = false,
		StateUnavailableWarned = false,
		DeliveryFailureWarned = false,
		CompletedByRequestId = {},
		CompletedByClientSequence = {},
		CompletedOrder = {},
		InFlight = nil,
	}
end

local function getOrCreatePlayerRecord(player: Player): PlayerRecord
	local existing = records[player]
	if existing then
		return existing
	end
	local created = createPlayerRecord()
	records[player] = created
	return created
end

local function consumeBucket(bucket: TokenBucket, rate: number, capacity: number): boolean
	local now = os.clock()
	local elapsed = math.max(0, now - bucket.LastRefillAt)
	bucket.Tokens = math.min(capacity, bucket.Tokens + elapsed * rate)
	bucket.LastRefillAt = now
	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

local function isServiceCurrent(player: Player, record: PlayerRecord): boolean
	local remote = activeRemote
	local api = activeApi
	return started
		and not destroyed
		and player.Parent == Players
		and records[player] == record
		and remote ~= nil
		and api ~= nil
		and activeGetState == api.getCourseSelectionState
		and activeSelectCourse == api.selectCourse
		and isExactRemote(remote)
end

local function warnStateUnavailable(player: Player, record: PlayerRecord)
	if record.StateUnavailableWarned then
		return
	end
	record.StateUnavailableWarned = true
	warn(string.format("[Frostline][CourseSelection] player=%s UserId=%d authoritative state unavailable", player.Name, player.UserId))
end

local function warnServerSequenceExhausted(player: Player, record: PlayerRecord)
	if record.ServerSequenceExhaustedWarned then
		return
	end
	record.ServerSequenceExhaustedWarned = true
	warn(string.format("[Frostline][CourseSelection] player=%s UserId=%d server sequence exhausted", player.Name, player.UserId))
end

local function warnDeliveryFailure(player: Player, record: PlayerRecord)
	if record.DeliveryFailureWarned then
		return
	end
	record.DeliveryFailureWarned = true
	warn(string.format("[Frostline][CourseSelection] player=%s UserId=%d response delivery failed", player.Name, player.UserId))
end

local function validateDescriptor(
	rawDescriptor: any,
	expectedCourseId: CourseId,
	expectedDisplayName: string
): CourseSelectionTypes.CourseDescriptor?
	if typeof(rawDescriptor) ~= "table"
		or not hasExactKeys(rawDescriptor, DESCRIPTOR_KEYS, 3)
		or rawDescriptor.CourseId ~= expectedCourseId
		or rawDescriptor.DisplayName ~= expectedDisplayName
		or typeof(rawDescriptor.Available) ~= "boolean"
	then
		return nil
	end
	return table.freeze({
		CourseId = expectedCourseId,
		DisplayName = expectedDisplayName,
		Available = rawDescriptor.Available,
	})
end

local function validateSnapshot(rawSnapshot: any): AuthoritativeSnapshot?
	if typeof(rawSnapshot) ~= "table"
		or not hasExactKeys(rawSnapshot, SNAPSHOT_KEYS, 4)
		or not isKnownCourseId(rawSnapshot.SelectedCourseId)
		or typeof(rawSnapshot.CanSelect) ~= "boolean"
		or not isKnownRunPhase(rawSnapshot.RunPhase)
		or typeof(rawSnapshot.Courses) ~= "table"
	then
		return nil
	end

	local rawCourses = rawSnapshot.Courses
	if not hasExactCourseArrayKeys(rawCourses) then
		return nil
	end
	local classic = validateDescriptor(rawCourses[1], COURSE_IDS.FrozenLakeV2, "CLASSIC DISTANCE")
	local frost = validateDescriptor(rawCourses[2], COURSE_IDS.FrostTrailV1, "FROST TRAIL")
	if classic == nil or frost == nil then
		return nil
	end
	local courses: Catalog = table.freeze({ classic, frost })
	return table.freeze({
		SelectedCourseId = rawSnapshot.SelectedCourseId :: CourseId,
		CanSelect = rawSnapshot.CanSelect,
		RunPhase = rawSnapshot.RunPhase :: RunPhase,
		Courses = courses,
	})
end

local function getAuthoritativeSnapshot(player: Player): AuthoritativeSnapshot?
	local getter = activeGetState
	if getter == nil then
		return nil
	end
	local succeeded, rawSnapshot = pcall(getter, player)
	if not succeeded then
		return nil
	end
	return validateSnapshot(rawSnapshot)
end

local function isResponseCombinationValid(request: RepresentedRequest, terminal: TerminalSemantics): boolean
	if request.Action == ACTIONS.GetState then
		if terminal.StatusCode == STATUS.State then
			return terminal.Ok
		end
		return not terminal.Ok and GET_STATE_FAILURES[terminal.StatusCode] == true
	end
	if terminal.StatusCode == STATUS.Success or terminal.StatusCode == STATUS.AlreadySelected then
		return terminal.Ok
	end
	return not terminal.Ok and SELECT_FAILURES[terminal.StatusCode] == true
end

local function emitResponse(
	player: Player,
	record: PlayerRecord,
	request: RepresentedRequest,
	terminal: TerminalSemantics,
	snapshot: AuthoritativeSnapshot
)
	if not isServiceCurrent(player, record) or not isResponseCombinationValid(request, terminal) then
		return
	end
	if request.Action == ACTIONS.Select then
		local responseCourseId = request.CourseId
		if responseCourseId == nil then
			return
		end
		if terminal.Ok and snapshot.SelectedCourseId ~= responseCourseId then
			return
		end
	end
	if record.ServerSequence >= CourseSelectionTypes.MaximumServerSequence then
		warnServerSequenceExhausted(player, record)
		return
	end

	local remote = activeRemote
	if remote == nil then
		return
	end
	record.ServerSequence += 1
	local response: any = {
		ProtocolVersion = CourseSelectionTypes.ProtocolVersion,
		CatalogVersion = CourseSelectionTypes.CatalogVersion,
		ServerSequence = record.ServerSequence,
		ResponseToRequestId = request.RequestId,
		ResponseClientSequence = request.ClientSequence,
		ResponseAction = request.Action,
		Ok = terminal.Ok,
		StatusCode = terminal.StatusCode,
		SelectedCourseId = snapshot.SelectedCourseId,
		CanSelect = snapshot.CanSelect,
		RunPhase = snapshot.RunPhase,
		Courses = snapshot.Courses,
	}
	if request.Action == ACTIONS.Select then
		response.ResponseCourseId = request.CourseId
	end
	table.freeze(response)
	local delivered = pcall(function()
		remote:FireClient(player, response)
	end)
	if not delivered and isServiceCurrent(player, record) then
		warnDeliveryFailure(player, record)
	end
end

local function createTerminal(ok: boolean, statusCode: StatusCode): TerminalSemantics
	return table.freeze({
		Ok = ok,
		StatusCode = statusCode,
	})
end

local function cacheTerminal(
	record: PlayerRecord,
	request: RepresentedRequest,
	terminal: TerminalSemantics
): CompletedRequest
	local completed: CompletedRequest = table.freeze({
		RequestId = request.RequestId,
		ClientSequence = request.ClientSequence,
		Action = request.Action,
		CourseId = request.CourseId,
		Fingerprint = request.Fingerprint,
		Ok = terminal.Ok,
		StatusCode = terminal.StatusCode,
	})
	record.CompletedByRequestId[completed.RequestId] = completed
	record.CompletedByClientSequence[completed.ClientSequence] = completed
	table.insert(record.CompletedOrder, completed)
	while #record.CompletedOrder > CourseSelectionTypes.CompletedRequestCacheCapacity do
		local oldest = table.remove(record.CompletedOrder, 1)
		if record.CompletedByRequestId[oldest.RequestId] == oldest then
			record.CompletedByRequestId[oldest.RequestId] = nil
		end
		if record.CompletedByClientSequence[oldest.ClientSequence] == oldest then
			record.CompletedByClientSequence[oldest.ClientSequence] = nil
		end
	end
	return completed
end

local function classifyCompleted(record: PlayerRecord, request: RepresentedRequest): (IdentityClassification, CompletedRequest?)
	local byRequestId = record.CompletedByRequestId[request.RequestId]
	local bySequence = record.CompletedByClientSequence[request.ClientSequence]
	if byRequestId == nil and bySequence == nil then
		return "None", nil
	end
	if byRequestId ~= nil
		and byRequestId == bySequence
		and byRequestId.Fingerprint == request.Fingerprint
	then
		return "Same", byRequestId
	end
	return "Conflict", nil
end

local function classifyInFlight(inFlight: InFlightSelect?, request: RepresentedRequest): IdentityClassification
	if inFlight == nil
		or (inFlight.RequestId ~= request.RequestId and inFlight.ClientSequence ~= request.ClientSequence)
	then
		return "None"
	end
	if inFlight.RequestId == request.RequestId
		and inFlight.ClientSequence == request.ClientSequence
		and inFlight.Fingerprint == request.Fingerprint
	then
		return "Same"
	end
	return "Conflict"
end

local function effectiveCachedTerminal(completed: CompletedRequest, snapshot: AuthoritativeSnapshot): TerminalSemantics
	if (completed.StatusCode == STATUS.Success or completed.StatusCode == STATUS.AlreadySelected) and completed.Ok then
		if completed.CourseId ~= nil and snapshot.SelectedCourseId == completed.CourseId then
			return completed
		end
		return createTerminal(false, STATUS.InternalError)
	elseif completed.StatusCode == STATUS.SafetyFallback then
		if snapshot.SelectedCourseId == COURSE_IDS.FrozenLakeV2 then
			return completed
		end
		return createTerminal(false, STATUS.InternalError)
	end
	return completed
end

local function respondWithFreshSnapshot(
	player: Player,
	record: PlayerRecord,
	request: RepresentedRequest,
	terminal: TerminalSemantics
)
	local snapshot = getAuthoritativeSnapshot(player)
	if not isServiceCurrent(player, record) then
		return
	end
	if snapshot == nil then
		warnStateUnavailable(player, record)
		return
	end
	emitResponse(player, record, request, terminal, snapshot)
end

local function completeNewWithoutRouting(
	player: Player,
	record: PlayerRecord,
	request: RepresentedRequest,
	terminal: TerminalSemantics,
	snapshot: AuthoritativeSnapshot?
)
	cacheTerminal(record, request, terminal)
	if snapshot == nil then
		warnStateUnavailable(player, record)
		return
	end
	emitResponse(player, record, request, terminal, snapshot)
end

local function isCurrentInFlightCompletion(
	player: Player,
	record: PlayerRecord,
	operation: InFlightSelect,
	serviceGeneration: number,
	remote: RemoteEvent,
	api: ServiceApi,
	getter: (Player) -> any,
	selector: (Player, CourseId) -> any
): boolean
	return player.Parent == Players
		and started
		and not destroyed
		and activeServiceGeneration == serviceGeneration
		and operation.ServiceGeneration == serviceGeneration
		and activeRemote == remote
		and activeApi == api
		and activeGetState == getter
		and activeSelectCourse == selector
		and api.getCourseSelectionState == getter
		and api.selectCourse == selector
		and records[player] == record
		and record.InFlight == operation
		and operation.RequestId ~= ""
		and operation.ClientSequence >= 1
		and operation.Fingerprint ~= ""
		and isExactRemote(remote)
end

local function processSelect(player: Player, record: PlayerRecord, request: RepresentedRequest, preSnapshot: AuthoritativeSnapshot)
	local courseId = request.CourseId
	local remote = activeRemote
	local api = activeApi
	local getter = activeGetState
	local selector = activeSelectCourse
	if courseId == nil or remote == nil or api == nil or getter == nil or selector == nil then
		completeNewWithoutRouting(player, record, request, createTerminal(false, STATUS.InternalError), preSnapshot)
		return
	end

	local operation: InFlightSelect = table.freeze({
		RequestId = request.RequestId,
		ClientSequence = request.ClientSequence,
		Action = ACTIONS.Select,
		CourseId = courseId,
		Fingerprint = request.Fingerprint,
		PreSelectSnapshot = preSnapshot,
		ServiceGeneration = activeServiceGeneration,
	})
	record.InFlight = operation
	local capturedServiceGeneration = activeServiceGeneration
	local operationSucceeded, returnedStatus = pcall(selector, player, courseId)

	if not isCurrentInFlightCompletion(
		player,
		record,
		operation,
		capturedServiceGeneration,
		remote,
		api,
		getter,
		selector
	) then
		return
	end

	local terminal: TerminalSemantics
	local snapshot: AuthoritativeSnapshot
	if not operationSucceeded or typeof(returnedStatus) ~= "string" or SELECT_DOMAIN_STATUSES[returnedStatus] ~= true then
		terminal = createTerminal(false, STATUS.InternalError)
		snapshot = preSnapshot
	else
		local currentSnapshot = getAuthoritativeSnapshot(player)
		if not isCurrentInFlightCompletion(
			player,
			record,
			operation,
			capturedServiceGeneration,
			remote,
			api,
			getter,
			selector
		) then
			return
		end
		if currentSnapshot == nil then
			warnStateUnavailable(player, record)
			terminal = createTerminal(false, STATUS.InternalError)
			snapshot = preSnapshot
		else
			snapshot = currentSnapshot
			local statusCode = returnedStatus :: StatusCode
			local ok = statusCode == STATUS.Success or statusCode == STATUS.AlreadySelected
			if ok and snapshot.SelectedCourseId ~= courseId then
				terminal = createTerminal(false, STATUS.InternalError)
			elseif statusCode == STATUS.SafetyFallback
				and snapshot.SelectedCourseId ~= COURSE_IDS.FrozenLakeV2
			then
				terminal = createTerminal(false, STATUS.InternalError)
			else
				terminal = createTerminal(ok, statusCode)
			end
		end
	end

	cacheTerminal(record, request, terminal)
	record.InFlight = nil
	emitResponse(player, record, request, terminal, snapshot)
end

local function onCourseSelectionRequest(player: Player, rawRequest: any)
	if not started or destroyed or player.Parent ~= Players then
		return
	end

	local record = getOrCreatePlayerRecord(player)
	if not consumeBucket(
		record.TransportBucket,
		CourseSelectionTypes.TransportRateTokensPerSecond,
		CourseSelectionTypes.TransportRateBucketCapacity
	) then
		return
	end
	if record.ServerSequence >= CourseSelectionTypes.MaximumServerSequence then
		warnServerSequenceExhausted(player, record)
		return
	end

	local parseSucceeded, parsedRequest = pcall(parseRepresentedRequest, rawRequest)
	if not parseSucceeded or parsedRequest == nil then
		return
	end
	local request = parsedRequest :: RepresentedRequest

	local inFlightClassification = classifyInFlight(record.InFlight, request)
	local completedClassification, completed = classifyCompleted(record, request)
	local hasConflict = inFlightClassification == "Conflict" or completedClassification == "Conflict"

	local inFlight = record.InFlight
	if inFlight ~= nil then
		local statusCode = if hasConflict then STATUS.RequestIdConflict else STATUS.RequestInProgress
		emitResponse(player, record, request, createTerminal(false, statusCode), inFlight.PreSelectSnapshot)
		return
	end

	if hasConflict then
		respondWithFreshSnapshot(player, record, request, createTerminal(false, STATUS.RequestIdConflict))
		return
	elseif completedClassification == "Same" and completed ~= nil then
		local snapshot = getAuthoritativeSnapshot(player)
		if not isServiceCurrent(player, record) then
			return
		end
		if snapshot == nil then
			warnStateUnavailable(player, record)
			return
		end
		emitResponse(player, record, request, effectiveCachedTerminal(completed, snapshot), snapshot)
		return
	end

	if request.ClientSequence <= record.LastAcceptedClientSequence
		or request.ClientSequence > math.min(
			record.LastAcceptedClientSequence + CourseSelectionTypes.MaximumClientSequenceJump,
			CourseSelectionTypes.MaximumClientSequence
		)
	then
		return
	end
	record.LastAcceptedClientSequence = request.ClientSequence

	if request.Disposition == "InvalidRequest" then
		local terminal = createTerminal(false, STATUS.InvalidRequest)
		local snapshot = getAuthoritativeSnapshot(player)
		if not isServiceCurrent(player, record) then
			return
		end
		completeNewWithoutRouting(player, record, request, terminal, snapshot)
		return
	elseif request.Disposition == "UnsupportedVersion" then
		local terminal = createTerminal(false, STATUS.UnsupportedVersion)
		local snapshot = getAuthoritativeSnapshot(player)
		if not isServiceCurrent(player, record) then
			return
		end
		completeNewWithoutRouting(player, record, request, terminal, snapshot)
		return
	elseif request.Action == ACTIONS.GetState then
		local snapshot = getAuthoritativeSnapshot(player)
		if not isServiceCurrent(player, record) then
			return
		end
		if snapshot == nil then
			completeNewWithoutRouting(player, record, request, createTerminal(false, STATUS.InternalError), nil)
		else
			completeNewWithoutRouting(player, record, request, createTerminal(true, STATUS.State), snapshot)
		end
		return
	end

	local preSnapshot = getAuthoritativeSnapshot(player)
	if not isServiceCurrent(player, record) then
		return
	end
	if preSnapshot == nil then
		completeNewWithoutRouting(player, record, request, createTerminal(false, STATUS.InternalError), nil)
		return
	end
	if not consumeBucket(
		record.SelectBucket,
		CourseSelectionTypes.SelectRateTokensPerSecond,
		CourseSelectionTypes.SelectRateBucketCapacity
	) then
		completeNewWithoutRouting(player, record, request, createTerminal(false, STATUS.RateLimited), preSnapshot)
		return
	end
	processSelect(player, record, request, preSnapshot)
end

local function onPlayerRemoving(player: Player)
	records[player] = nil
end

function CourseSelectionService.start(remoteValue: any, apiValue: any): (boolean, string)
	local remote: RemoteEvent? = if typeof(remoteValue) == "Instance" and remoteValue:IsA("RemoteEvent")
		then remoteValue :: RemoteEvent
		else nil
	local api: ServiceApi? = if isExactApi(apiValue) then apiValue :: ServiceApi else nil
	if destroyed then
		return false, "Destroyed"
	elseif started then
		if remote ~= nil and api ~= nil and activeRemote == remote and activeApi == api and isExactRemote(remote) then
			return true, "AlreadyStarted"
		end
		return false, "AlreadyStartedWithDifferentDependencies"
	elseif remote == nil or not isExactRemote(remote) then
		return false, "InvalidRemote"
	elseif api == nil then
		return false, "InvalidApi"
	end

	latestServiceGeneration += 1
	activeServiceGeneration = latestServiceGeneration
	activeRemote = remote
	activeApi = api
	activeGetState = api.getCourseSelectionState
	activeSelectCourse = api.selectCourse
	started = true

	local requestConnected, acquiredRequestConnection = pcall(function()
		return remote.OnServerEvent:Connect(onCourseSelectionRequest)
	end)
	if not requestConnected or acquiredRequestConnection == nil then
		started = false
		activeRemote = nil
		activeApi = nil
		activeGetState = nil
		activeSelectCourse = nil
		return false, "RequestConnectionFailed"
	end
	requestConnection = acquiredRequestConnection

	local removalConnected, acquiredRemovalConnection = pcall(function()
		return Players.PlayerRemoving:Connect(onPlayerRemoving)
	end)
	if not removalConnected or acquiredRemovalConnection == nil then
		acquiredRequestConnection:Disconnect()
		requestConnection = nil
		started = false
		activeRemote = nil
		activeApi = nil
		activeGetState = nil
		activeSelectCourse = nil
		return false, "PlayerRemovingConnectionFailed"
	end
	playerRemovingConnection = acquiredRemovalConnection
	return true, "Started"
end

function CourseSelectionService.destroy()
	if destroyed then
		return
	end
	destroyed = true
	started = false
	latestServiceGeneration += 1
	activeServiceGeneration = latestServiceGeneration
	if requestConnection ~= nil then
		requestConnection:Disconnect()
		requestConnection = nil
	end
	if playerRemovingConnection ~= nil then
		playerRemovingConnection:Disconnect()
		playerRemovingConnection = nil
	end
	table.clear(records)
	activeRemote = nil
	activeApi = nil
	activeGetState = nil
	activeSelectCourse = nil
end

return CourseSelectionService
