--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local StoreTypes = require(ReplicatedStorage.Shared.StoreTypes)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RunManager = require(script.Parent.RunManager)

local DATA = GameConfig.PlayerData
local STORE = GameConfig.Store
local ACTIONS = StoreTypes.Actions
local STATUS = StoreTypes.StatusCodes
local PERSISTENCE = StoreTypes.PersistenceStates

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local REQUEST_REMOTE_NAME = "StoreRequest"
local STATE_REMOTE_NAME = "StoreState"
local MAXIMUM_SAFE_INTEGER = 9007199254740991

type StoreAction = StoreTypes.Action
type StoreStatusCode = StoreTypes.StatusCode
type StorePersistenceState = StoreTypes.PersistenceState
type StoreState = StoreTypes.StoreState
type StoreOperationToken = RunManager.StoreOperationToken
type StoreMutationResult = PlayerDataService.StoreMutationResult

type RequestMetadata = {
	RequestId: string,
	Action: StoreAction,
	SledId: string?,
}

type ValidatedRequest = RequestMetadata & {
	ExpectedRevision: number?,
	Fingerprint: string,
}

type PendingRequest = {
	Fingerprint: string,
	StartedAt: number,
}

type CompletedRequest = {
	Fingerprint: string,
	Metadata: RequestMetadata,
	Ok: boolean,
	StatusCode: StoreStatusCode,
	CompletedAt: number,
}

type PlayerRecord = {
	Generation: number,
	Tokens: number,
	LastRefillAt: number,
	LastMutationAttemptAt: number,
	LastLightweightResponseAt: number,
	LastWarningAt: number,
	ServerSequence: number,
	Pending: { [string]: PendingRequest },
	PendingCount: number,
	Completed: { [string]: CompletedRequest },
	CompletedOrder: { string },
	MutationRequestId: string?,
	ReservationToken: StoreOperationToken?,
}

local StoreService = {}

local records: { [Player]: PlayerRecord } = {}
local latestRecordGeneration = 0
local started = false
local destroyed = false
local remoteCollisionWarned = false
local requestRemote: RemoteEvent? = nil
local stateRemote: RemoteEvent? = nil
local requestConnection: RBXScriptConnection? = nil

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isSafeNonNegativeInteger(value: any): boolean
	return isFiniteNumber(value) and value >= 0 and value % 1 == 0 and value <= MAXIMUM_SAFE_INTEGER
end

local function isGuidWithoutBraces(value: any): boolean
	if typeof(value) ~= "string" or #value ~= 36 or #value > STORE.MaximumRequestIdLength then
		return false
	end
	return string.match(
		value,
		"^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
	) ~= nil
end

local function isKnownAction(value: any): boolean
	return value == ACTIONS.GetState or value == ACTIONS.Purchase or value == ACTIONS.Equip
end

local function safeMetadata(rawRequest: any): RequestMetadata
	local requestId = ""
	local action: StoreAction = ACTIONS.GetState
	local sledId: string? = nil
	if typeof(rawRequest) == "table" then
		if isGuidWithoutBraces(rawRequest.RequestId) then
			requestId = rawRequest.RequestId
		end
		if isKnownAction(rawRequest.Action) then
			action = rawRequest.Action
		end
		if typeof(rawRequest.SledId) == "string" and #rawRequest.SledId <= STORE.MaximumSledIdLength then
			sledId = rawRequest.SledId
		end
	end
	return {
		RequestId = requestId,
		Action = action,
		SledId = sledId,
	}
end

local function fingerprint(action: StoreAction, sledId: string?, expectedRevision: number?): string
	return string.format("%s|%s|%s", action, sledId or "", if expectedRevision == nil then "" else tostring(expectedRevision))
end

local function validateRequest(rawRequest: any): (ValidatedRequest?, StoreStatusCode, string, RequestMetadata)
	local metadata = safeMetadata(rawRequest)
	if typeof(rawRequest) ~= "table" then
		return nil, STATUS.InvalidRequest, "request is not a table", metadata
	elseif rawRequest.ProtocolVersion ~= StoreTypes.ProtocolVersion then
		return nil, STATUS.UnsupportedVersion, "protocol version is unsupported", metadata
	elseif not isGuidWithoutBraces(rawRequest.RequestId) then
		return nil, STATUS.InvalidRequest, "request ID is not a canonical GUID", metadata
	elseif not isKnownAction(rawRequest.Action) then
		return nil, STATUS.InvalidRequest, "request action is unknown", metadata
	end

	local action: StoreAction = rawRequest.Action
	local requestId: string = rawRequest.RequestId
	if action == ACTIONS.GetState then
		if rawRequest.SledId ~= nil or rawRequest.ExpectedRevision ~= nil then
			return nil, STATUS.InvalidRequest, "GetState contains mutation fields", metadata
		end
		return {
			RequestId = requestId,
			Action = action,
			SledId = nil,
			ExpectedRevision = nil,
			Fingerprint = fingerprint(action, nil, nil),
		}, STATUS.State, "", metadata
	end

	if typeof(rawRequest.SledId) ~= "string"
		or rawRequest.SledId == ""
		or #rawRequest.SledId > STORE.MaximumSledIdLength
	then
		return nil, STATUS.InvalidRequest, "sled ID is invalid", metadata
	elseif not isSafeNonNegativeInteger(rawRequest.ExpectedRevision) then
		return nil, STATUS.InvalidRequest, "expected revision is invalid", metadata
	end

	local sledId: string = rawRequest.SledId
	local expectedRevision: number = rawRequest.ExpectedRevision
	return {
		RequestId = requestId,
		Action = action,
		SledId = sledId,
		ExpectedRevision = expectedRevision,
		Fingerprint = fingerprint(action, sledId, expectedRevision),
	}, STATUS.State, "", metadata
end

local function createPlayerRecord(): PlayerRecord
	latestRecordGeneration += 1
	local now = os.clock()
	return {
		Generation = latestRecordGeneration,
		Tokens = STORE.TokenBucketCapacity,
		LastRefillAt = now,
		LastMutationAttemptAt = -math.huge,
		LastLightweightResponseAt = -math.huge,
		LastWarningAt = -math.huge,
		ServerSequence = 0,
		Pending = {},
		PendingCount = 0,
		Completed = {},
		CompletedOrder = {},
		MutationRequestId = nil,
		ReservationToken = nil,
	}
end

local function getPlayerRecord(player: Player): PlayerRecord
	local existing = records[player]
	if existing then
		return existing
	end
	local created = createPlayerRecord()
	records[player] = created
	return created
end

local function isRecordCurrent(player: Player, record: PlayerRecord): boolean
	return started
		and not destroyed
		and not PlayerDataService.isShuttingDown()
		and player.Parent == Players
		and records[player] == record
end

local function pruneCompleted(record: PlayerRecord, now: number)
	local index = 1
	while index <= #record.CompletedOrder do
		local requestId = record.CompletedOrder[index]
		local completed = record.Completed[requestId]
		if not completed or now - completed.CompletedAt > STORE.CompletedResponseRetentionSeconds then
			record.Completed[requestId] = nil
			table.remove(record.CompletedOrder, index)
		else
			index += 1
		end
	end
	while #record.CompletedOrder > STORE.CompletedResponseLimit do
		local oldestRequestId = table.remove(record.CompletedOrder, 1)
		record.Completed[oldestRequestId] = nil
	end
end

local function consumeToken(record: PlayerRecord, now: number): boolean
	local elapsed = math.max(0, now - record.LastRefillAt)
	record.Tokens = math.min(STORE.TokenBucketCapacity, record.Tokens + elapsed * STORE.TokenRefillPerSecond)
	record.LastRefillAt = now
	if record.Tokens < 1 then
		return false
	end
	record.Tokens -= 1
	return true
end

local function warnRequest(player: Player, record: PlayerRecord, metadata: RequestMetadata, reason: string)
	local now = os.clock()
	if now - record.LastWarningAt < STORE.InvalidWarningIntervalSeconds then
		return
	end
	record.LastWarningAt = now
	warn(
		string.format(
			"[Frostline][Store] player=%s UserId=%d requestId=%s action=%s reason=%s",
			player.Name,
			player.UserId,
			if metadata.RequestId == "" then "<invalid>" else metadata.RequestId,
			metadata.Action,
			reason
		)
	)
end

local function copyOwnedSleds(source: { [string]: boolean }): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	for sledId in DATA.KnownSledIds do
		if source[sledId] == true then
			owned[sledId] = true
		end
	end
	owned[DATA.DefaultSledId] = true
	return owned
end

local function buildState(
	player: Player,
	record: PlayerRecord,
	metadata: RequestMetadata,
	ok: boolean,
	statusCode: StoreStatusCode
): StoreState
	local snapshot = PlayerDataService.getStoreSnapshot(player)
	local persistenceState: StorePersistenceState = PERSISTENCE.Loading
	local dataRevision = 0
	local frostCoins = 0
	local ownedSleds: { [string]: boolean } = {
		[DATA.DefaultSledId] = true,
	}
	local equippedSledId = DATA.DefaultSledId
	if snapshot then
		persistenceState = snapshot.PersistenceState
		dataRevision = snapshot.DataRevision
		frostCoins = snapshot.FrostCoins
		ownedSleds = copyOwnedSleds(snapshot.OwnedSleds)
		equippedSledId = snapshot.EquippedSledId
	end

	local resolved = persistenceState == PERSISTENCE.Persistent
		or persistenceState == PERSISTENCE.SessionOnly
		or persistenceState == PERSISTENCE.SavePending
	local canBrowse = isRecordCurrent(player, record) and resolved and RunManager.canAccessStore(player)
	local canTransact = canBrowse
		and persistenceState == PERSISTENCE.Persistent
		and record.MutationRequestId == nil
		and record.ReservationToken == nil
		and not PlayerDataService.hasUnresolvedStoreSave(player)

	record.ServerSequence += 1
	return {
		ProtocolVersion = StoreTypes.ProtocolVersion,
		CatalogVersion = STORE.CatalogVersion,
		ServerSequence = record.ServerSequence,
		DataRevision = dataRevision,
		ResponseToRequestId = metadata.RequestId,
		ResponseAction = metadata.Action,
		ResponseSledId = metadata.SledId,
		Ok = ok,
		StatusCode = statusCode,
		CanBrowse = canBrowse,
		CanTransact = canTransact,
		PersistenceState = persistenceState,
		FrostCoins = frostCoins,
		OwnedSleds = ownedSleds,
		EquippedSledId = equippedSledId,
	}
end

local function sendState(
	player: Player,
	record: PlayerRecord,
	metadata: RequestMetadata,
	ok: boolean,
	statusCode: StoreStatusCode
): boolean
	if not isRecordCurrent(player, record) then
		return false
	end
	local remote = stateRemote
	if not remote or not remote.Parent then
		return false
	end
	remote:FireClient(player, buildState(player, record, metadata, ok, statusCode))
	return true
end

local function sendLightweightState(
	player: Player,
	record: PlayerRecord,
	metadata: RequestMetadata,
	ok: boolean,
	statusCode: StoreStatusCode
)
	local now = os.clock()
	if now - record.LastLightweightResponseAt < STORE.CachedResponseMinimumIntervalSeconds then
		return
	end
	record.LastLightweightResponseAt = now
	sendState(player, record, metadata, ok, statusCode)
end

local function removePending(record: PlayerRecord, requestId: string)
	if record.Pending[requestId] then
		record.Pending[requestId] = nil
		record.PendingCount = math.max(0, record.PendingCount - 1)
	end
end

local function completeRequest(
	player: Player,
	record: PlayerRecord,
	request: ValidatedRequest,
	ok: boolean,
	statusCode: StoreStatusCode
)
	if not isRecordCurrent(player, record) then
		return
	end
	if request.Action ~= ACTIONS.GetState and record.MutationRequestId == request.RequestId then
		record.MutationRequestId = nil
	end
	removePending(record, request.RequestId)
	record.Completed[request.RequestId] = {
		Fingerprint = request.Fingerprint,
		Metadata = {
			RequestId = request.RequestId,
			Action = request.Action,
			SledId = request.SledId,
		},
		Ok = ok,
		StatusCode = statusCode,
		CompletedAt = os.clock(),
	}
	table.insert(record.CompletedOrder, request.RequestId)
	pruneCompleted(record, os.clock())
	sendState(player, record, request, ok, statusCode)
end

local function beginPending(record: PlayerRecord, request: ValidatedRequest)
	record.Pending[request.RequestId] = {
		Fingerprint = request.Fingerprint,
		StartedAt = os.clock(),
	}
	record.PendingCount += 1
end

local function getMutationAvailability(player: Player, record: PlayerRecord): StoreStatusCode?
	if not isRecordCurrent(player, record) or not RunManager.canAccessStore(player) then
		return STATUS.StoreUnavailable
	end
	local snapshot = PlayerDataService.getStoreSnapshot(player)
	if not snapshot or snapshot.PersistenceState == PERSISTENCE.Loading then
		return STATUS.ProfileLoading
	elseif snapshot.PersistenceState == PERSISTENCE.SessionOnly then
		return STATUS.PersistenceUnavailable
	elseif snapshot.PersistenceState == PERSISTENCE.Releasing then
		return STATUS.StoreUnavailable
	elseif snapshot.PersistenceState == PERSISTENCE.SavePending
		or PlayerDataService.hasUnresolvedStoreSave(player)
	then
		return STATUS.SavePending
	elseif snapshot.PersistenceState ~= PERSISTENCE.Persistent then
		return STATUS.StoreUnavailable
	end
	return nil
end

local function processGetState(player: Player, record: PlayerRecord, request: ValidatedRequest)
	local snapshot = PlayerDataService.getStoreSnapshot(player)
	local expectedGeneration = if snapshot then snapshot.Generation else nil
	if snapshot and snapshot.PersistenceState == PERSISTENCE.Loading then
		PlayerDataService.waitForLoad(player, DATA.LoadWaitTimeoutSeconds)
	end

	if not isRecordCurrent(player, record) or record.Pending[request.RequestId] == nil then
		return
	end
	if expectedGeneration ~= nil and not PlayerDataService.isProfileGenerationCurrent(player, expectedGeneration) then
		removePending(record, request.RequestId)
		return
	end

	snapshot = PlayerDataService.getStoreSnapshot(player)
	local statusCode: StoreStatusCode = STATUS.State
	if not snapshot or snapshot.PersistenceState == PERSISTENCE.Loading then
		statusCode = STATUS.ProfileLoading
	elseif snapshot.PersistenceState == PERSISTENCE.Releasing or not RunManager.canAccessStore(player) then
		statusCode = STATUS.StoreUnavailable
	end
	completeRequest(player, record, request, statusCode == STATUS.State, statusCode)
end

local function releaseReservation(player: Player, record: PlayerRecord, token: StoreOperationToken)
	RunManager.endStoreOperation(player, token)
	if record.ReservationToken == token then
		record.ReservationToken = nil
	end
end

local function processMutation(player: Player, record: PlayerRecord, request: ValidatedRequest)
	local availability = getMutationAvailability(player, record)
	if availability then
		completeRequest(player, record, request, false, availability)
		return
	end

	local sledId = request.SledId
	local expectedRevision = request.ExpectedRevision
	if not sledId or expectedRevision == nil then
		completeRequest(player, record, request, false, STATUS.InvalidRequest)
		return
	end
	local catalogEntry = STORE.Catalog[sledId]
	if not catalogEntry or catalogEntry.SledId ~= sledId or DATA.KnownSledIds[sledId] ~= true then
		completeRequest(player, record, request, false, STATUS.UnknownSled)
		return
	end

	local token = RunManager.beginStoreOperation(player)
	if token == nil then
		completeRequest(player, record, request, false, STATUS.Busy)
		return
	end
	record.ReservationToken = token

	local expectedGeneration: number? = nil
	local operationSucceeded, mutationResult, earlyStatus = pcall(function(): (StoreMutationResult?, StoreStatusCode?)
		local snapshot = PlayerDataService.getStoreSnapshot(player)
		if not snapshot then
			return nil, STATUS.ProfileLoading
		end
		expectedGeneration = snapshot.Generation
		local function reservationIsCurrent(): boolean
			return isRecordCurrent(player, record)
				and record.Pending[request.RequestId] ~= nil
				and record.MutationRequestId == request.RequestId
				and record.ReservationToken == token
				and RunManager.isStoreOperationCurrent(player, token)
				and PlayerDataService.isProfileGenerationCurrent(player, snapshot.Generation)
		end

		if request.Action == ACTIONS.Purchase then
			return PlayerDataService.purchaseSledAndSave(
				player,
				sledId,
				expectedRevision,
				snapshot.Generation,
				reservationIsCurrent
			), nil
		end
		return PlayerDataService.equipSledAndSave(
			player,
			sledId,
			expectedRevision,
			snapshot.Generation,
			reservationIsCurrent
		), nil
	end)

	local wasCurrent = isRecordCurrent(player, record)
		and record.Pending[request.RequestId] ~= nil
		and record.MutationRequestId == request.RequestId
		and record.ReservationToken == token
		and RunManager.isStoreOperationCurrent(player, token)
		and (expectedGeneration == nil
			or PlayerDataService.isProfileGenerationCurrent(player, expectedGeneration))
	releaseReservation(player, record, token)
	if record.MutationRequestId == request.RequestId then
		record.MutationRequestId = nil
	end
	if not wasCurrent or not isRecordCurrent(player, record) then
		removePending(record, request.RequestId)
		return
	end

	if not operationSucceeded then
		warnRequest(player, record, request, "Store mutation worker failed")
		completeRequest(player, record, request, false, STATUS.InternalError)
		return
	end
	if earlyStatus ~= nil then
		completeRequest(player, record, request, false, earlyStatus)
		return
	end
	if mutationResult == nil then
		warnRequest(player, record, request, "Store mutation returned no result")
		completeRequest(player, record, request, false, STATUS.InternalError)
		return
	end

	local statusCode: StoreStatusCode = mutationResult.StatusCode
	if (statusCode == STATUS.InternalError
		or statusCode == STATUS.SavePending
		or statusCode == STATUS.PersistenceUnavailable)
		and mutationResult.InternalReason ~= nil
	then
		warnRequest(player, record, request, mutationResult.InternalReason)
	end
	local ok = statusCode == STATUS.Success
		or statusCode == STATUS.AlreadyOwned
		or statusCode == STATUS.AlreadyEquipped
	completeRequest(player, record, request, ok, statusCode)
end

local function handleValidatedRequest(player: Player, record: PlayerRecord, request: ValidatedRequest)
	if request.Action == ACTIONS.GetState then
		processGetState(player, record, request)
	else
		processMutation(player, record, request)
	end
end

local function onStoreRequest(player: Player, rawRequest: any)
	if not started or destroyed or PlayerDataService.isShuttingDown() or player.Parent ~= Players then
		return
	end

	local record = getPlayerRecord(player)
	local request, invalidStatus, invalidReason, metadata = validateRequest(rawRequest)
	local now = os.clock()
	pruneCompleted(record, now)
	if not consumeToken(record, now) then
		sendLightweightState(player, record, metadata, false, STATUS.RateLimited)
		return
	end
	if not request then
		warnRequest(player, record, metadata, invalidReason)
		sendLightweightState(player, record, metadata, false, invalidStatus)
		return
	end

	local pending = record.Pending[request.RequestId]
	if pending then
		local statusCode = if pending.Fingerprint == request.Fingerprint
			then STATUS.RequestInProgress
			else STATUS.RequestIdConflict
		sendLightweightState(player, record, request, false, statusCode)
		return
	end
	local completed = record.Completed[request.RequestId]
	if completed then
		if completed.Fingerprint ~= request.Fingerprint then
			sendLightweightState(player, record, request, false, STATUS.RequestIdConflict)
		else
			sendLightweightState(
				player,
				record,
				completed.Metadata,
				completed.Ok,
				completed.StatusCode
			)
		end
		return
	end

	if record.PendingCount >= STORE.TokenBucketCapacity then
		sendLightweightState(player, record, request, false, STATUS.Busy)
		return
	end
	if request.Action ~= ACTIONS.GetState then
		if record.MutationRequestId ~= nil then
			sendLightweightState(player, record, request, false, STATUS.Busy)
			return
		elseif now - record.LastMutationAttemptAt < STORE.MutationMinimumIntervalSeconds then
			sendLightweightState(player, record, request, false, STATUS.RateLimited)
			return
		end
		record.LastMutationAttemptAt = now
		record.MutationRequestId = request.RequestId
	end

	beginPending(record, request)
	-- OnServerEvent handlers may yield independently. Calling directly guarantees
	-- that a mutation acquires its run/store reservation before this thread yields.
	handleValidatedRequest(player, record, request)
end

local function warnRemoteCollision(name: string, expectedClassName: string, actualClassName: string)
	if remoteCollisionWarned then
		return
	end
	remoteCollisionWarned = true
	warn(
		string.format(
			"[Frostline][Store] Startup blocked: %s must be a %s, found %s",
			name,
			expectedClassName,
			actualClassName
		)
	)
end

local function getRemoteFolder(): Folder?
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not existing then
		local folder = Instance.new("Folder")
		folder.Name = REMOTES_FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	elseif not existing:IsA("Folder") then
		warnRemoteCollision(REMOTES_FOLDER_NAME, "Folder", existing.ClassName)
		return nil
	end
	return existing
end

local function getOrCreateRemote(folder: Folder, name: string): RemoteEvent?
	local existing = folder:FindFirstChild(name)
	if existing then
		if existing:IsA("RemoteEvent") then
			return existing
		end
		warnRemoteCollision(name, "RemoteEvent", existing.ClassName)
		return nil
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

function StoreService.handlePlayerRemoving(player: Player)
	local record = records[player]
	if not record then
		return
	end
	local token = record.ReservationToken
	if token ~= nil then
		RunManager.endStoreOperation(player, token)
		record.ReservationToken = nil
	end
	records[player] = nil
end

function StoreService.start(): boolean
	if started then
		return true
	elseif destroyed then
		return false
	end

	local folder = getRemoteFolder()
	if not folder then
		return false
	end
	local acquiredRequestRemote = getOrCreateRemote(folder, REQUEST_REMOTE_NAME)
	local acquiredStateRemote = getOrCreateRemote(folder, STATE_REMOTE_NAME)
	if not acquiredRequestRemote or not acquiredStateRemote then
		return false
	end

	requestRemote = acquiredRequestRemote
	stateRemote = acquiredStateRemote
	started = true
	requestConnection = acquiredRequestRemote.OnServerEvent:Connect(onStoreRequest)
	print("[Frostline] StoreService ready")
	return true
end

function StoreService.destroy()
	if destroyed then
		return
	end
	destroyed = true
	started = false
	if requestConnection then
		requestConnection:Disconnect()
		requestConnection = nil
	end
	for player, record in records do
		local token = record.ReservationToken
		if token ~= nil then
			RunManager.endStoreOperation(player, token)
		end
		records[player] = nil
	end
	requestRemote = nil
	stateRemote = nil
end

return StoreService
