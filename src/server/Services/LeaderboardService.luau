--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local LEADERBOARD = GameConfig.Leaderboard
local WORLD = GameConfig.World
local MAXIMUM_SAFE_INTEGER = 9007199254740991
local WRITE_REQUEST_TYPES: { Enum.DataStoreRequestType } = {
	Enum.DataStoreRequestType.OrderedRead,
	Enum.DataStoreRequestType.OrderedWrite,
}
local READ_REQUEST_TYPES: { Enum.DataStoreRequestType } = {
	Enum.DataStoreRequestType.OrderedList,
}

type WriteEntry = {
	Acknowledged: number?,
	Deferred: number?,
	InFlight: boolean,
	Pending: number?,
	Queued: boolean,
	TouchedSequence: number,
}

type RawBoardEntry = {
	EncodedScore: number,
	UserId: number,
}

type BoardEntry = RawBoardEntry & {
	DisplayName: string,
}

type BoardRowRefs = {
	Frame: Frame,
	Rank: TextLabel,
	PlayerName: TextLabel,
	Distance: TextLabel,
}

type BoardRefs = {
	Content: Frame,
	Header: Frame,
	Rows: Frame,
	Status: TextLabel,
	RowRefs: { BoardRowRefs },
}

type UsernameCacheEntry = {
	AccessSequence: number,
	ExpiresAt: number,
	Username: string?,
}

type LookupBatch = {
	Open: boolean,
	RefreshGeneration: number,
	Remaining: number,
	Results: { [number]: string },
}

type LookupJob = {
	Batch: LookupBatch,
	RefreshGeneration: number,
	ServiceGeneration: number,
	UserId: number,
}

local LeaderboardService = {}

local orderedStore: OrderedDataStore? = nil
local started = false
local destroyed = false
local circuitOpen = false
local circuitWarningEmitted = false
local serviceGeneration = 0

local boardRefs: BoardRefs? = nil
local lastGoodEntries: { BoardEntry } = {}
local lastGoodUpdatedAt: number? = nil

local writeEntries: { [number]: WriteEntry } = {}
local writeEntryCount = 0
local writeTouchSequence = 0
local writeQueue: { [number]: number } = {}
local writeQueueHead = 1
local writeQueueTail = 0
local writeQueueCount = 0
local writeDrainActive = false
local lastWriteAttemptStartedAt = -math.huge

local refreshGeneration = 0
local refreshInFlight = false
local refreshAfterFlight = false
local refreshAfterFlightDelay = math.huge
local lastRefreshStartedAt = -math.huge
local refreshScheduleThread: thread? = nil
local periodicThread: thread? = nil
local startupThread: thread? = nil

local usernameCache: { [number]: UsernameCacheEntry } = {}
local usernameCacheCount = 0
local usernameAccessSequence = 0
local lookupQueue: { LookupJob } = {}
local lookupWorkersAlive = 0

local warningTimes: { [string]: number } = {}
local retryRandom = Random.new()

local scheduleWriteDrain: () -> ()
local scheduleRefresh: (number) -> ()
local ensureLookupWorkers: () -> ()

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isSafeInteger(value: any): boolean
	return isFiniteNumber(value)
		and value % 1 == 0
		and value >= -MAXIMUM_SAFE_INTEGER
		and value <= MAXIMUM_SAFE_INTEGER
end

local function isPositiveSafeInteger(value: any): boolean
	return isSafeInteger(value) and value > 0
end

local function isActiveGeneration(generation: number): boolean
	return started
		and not destroyed
		and not circuitOpen
		and orderedStore ~= nil
		and serviceGeneration == generation
end

local function isRefreshCurrent(generation: number, candidateRefreshGeneration: number): boolean
	return isActiveGeneration(generation) and refreshGeneration == candidateRefreshGeneration
end

local function warnRateLimited(category: string, message: string)
	if destroyed or circuitOpen then
		return
	end

	local now = os.clock()
	local previous = warningTimes[category]
	if previous ~= nil and now - previous < LEADERBOARD.WarningIntervalSeconds then
		return
	end
	warningTimes[category] = now
	warn(message)
end

local function cancelScheduledThread(scheduledThread: thread?)
	if scheduledThread == nil then
		return
	end
	pcall(function()
		task.cancel(scheduledThread)
	end)
end

local function resolveBoardRefs(): BoardRefs?
	local existing = boardRefs
	if existing ~= nil and existing.Content:IsDescendantOf(Workspace) then
		return existing
	end
	boardRefs = nil

	local world = Workspace:FindFirstChild(WORLD.FolderName)
	if world == nil then
		return nil
	end
	local presentation = world:FindFirstChild("Presentation")
	if presentation == nil then
		return nil
	end
	local leaderboards = presentation:FindFirstChild(LEADERBOARD.Board.FolderName)
	if leaderboards == nil then
		return nil
	end
	local board = leaderboards:FindFirstChild(LEADERBOARD.Board.ModelName)
	if board == nil then
		return nil
	end
	local backboard = board:FindFirstChild(LEADERBOARD.Board.BackboardName)
	if backboard == nil or not backboard:IsA("BasePart") then
		return nil
	end
	local surfaceGui = backboard:FindFirstChild(LEADERBOARD.Board.SurfaceGuiName)
	if surfaceGui == nil or not surfaceGui:IsA("SurfaceGui") then
		return nil
	end
	local content = surfaceGui:FindFirstChild("Content")
	if content == nil or not content:IsA("Frame") then
		return nil
	end
	local header = content:FindFirstChild("Header")
	local rows = content:FindFirstChild("Rows")
	local status = content:FindFirstChild("Status")
	if header == nil or not header:IsA("Frame") then
		return nil
	elseif rows == nil or not rows:IsA("Frame") then
		return nil
	elseif status == nil or not status:IsA("TextLabel") then
		return nil
	end

	local rowRefs: { BoardRowRefs } = {}
	for index = 1, LEADERBOARD.PageSize do
		local row = rows:FindFirstChild(string.format("Row_%02d", index))
		if row == nil or not row:IsA("Frame") then
			return nil
		end
		local rank = row:FindFirstChild("Rank")
		local playerName = row:FindFirstChild("PlayerName")
		local distance = row:FindFirstChild("Distance")
		if rank == nil or not rank:IsA("TextLabel") then
			return nil
		elseif playerName == nil or not playerName:IsA("TextLabel") then
			return nil
		elseif distance == nil or not distance:IsA("TextLabel") then
			return nil
		end
		table.insert(rowRefs, {
			Frame = row,
			Rank = rank,
			PlayerName = playerName,
			Distance = distance,
		})
	end

	local resolved: BoardRefs = {
		Content = content,
		Header = header,
		Rows = rows,
		Status = status,
		RowRefs = rowRefs,
	}
	boardRefs = resolved
	return resolved
end

local function publishStatus(message: string)
	local refs = resolveBoardRefs()
	if refs == nil then
		warnRateLimited("board", "[Frostline][Leaderboard] board presentation hierarchy is unavailable")
		return
	end

	refs.Content.Visible = false
	refs.Header.Visible = false
	refs.Rows.Visible = true
	for _, row in refs.RowRefs do
		row.Rank.Text = ""
		row.PlayerName.Text = ""
		row.Distance.Text = ""
		row.Frame.Visible = false
	end
	refs.Status.Text = message
	refs.Status.Visible = true
	refs.Content.Visible = true
end

local function publishEntries(entries: { BoardEntry })
	local refs = resolveBoardRefs()
	if refs == nil then
		warnRateLimited("board", "[Frostline][Leaderboard] board presentation hierarchy is unavailable")
		return
	end

	refs.Content.Visible = false
	for index, row in refs.RowRefs do
		local entry = entries[index]
		if entry == nil then
			row.Rank.Text = ""
			row.PlayerName.Text = ""
			row.Distance.Text = ""
			row.Frame.Visible = false
		else
			row.Rank.Text = string.format("%d.", index)
			row.PlayerName.Text = entry.DisplayName
			row.Distance.Text = string.format("%.1f m", entry.EncodedScore / LEADERBOARD.ScoreScale)
			row.Frame.Visible = true
		end
	end
	refs.Header.Visible = true
	refs.Rows.Visible = true
	refs.Status.Text = ""
	refs.Status.Visible = false
	refs.Content.Visible = true
end

local function publishLastGoodState()
	if lastGoodUpdatedAt == nil then
		publishStatus("LEADERBOARD TEMPORARILY UNAVAILABLE")
	elseif #lastGoodEntries == 0 then
		publishStatus("NO SCORES YET")
	else
		publishEntries(lastGoodEntries)
	end
end

local function invalidateLookupBatches()
	for _, job in lookupQueue do
		job.Batch.Open = false
	end
	lookupQueue = {}
end

local function stopScheduledWork()
	cancelScheduledThread(startupThread)
	startupThread = nil
	cancelScheduledThread(periodicThread)
	periodicThread = nil
	cancelScheduledThread(refreshScheduleThread)
	refreshScheduleThread = nil
	refreshAfterFlight = false
	refreshAfterFlightDelay = math.huge
	invalidateLookupBatches()
end

local function isStudioApiDisabledFailure(rawError: any): boolean
	if not RunService:IsStudio() then
		return false
	end

	local message = string.lower(tostring(rawError))
	if string.find(message, "studioaccesstoapisnotallowed", 1, true) ~= nil then
		return true
	end
	local explicitlyStudio = string.find(message, "studio", 1, true) ~= nil
	local explicitlyApi = string.find(message, "api", 1, true) ~= nil
	local explicitlyUnavailable = string.find(message, "not allowed", 1, true) ~= nil
		or string.find(message, "not enabled", 1, true) ~= nil
		or string.find(message, "disabled", 1, true) ~= nil
	return explicitlyStudio and explicitlyApi and explicitlyUnavailable
end

local function openStudioApiCircuit(rawError: any): boolean
	if circuitOpen or not isStudioApiDisabledFailure(rawError) then
		return circuitOpen
	end

	circuitOpen = true
	serviceGeneration += 1
	refreshGeneration += 1
	stopScheduledWork()
	if not circuitWarningEmitted then
		circuitWarningEmitted = true
		warn(string.format(
			"[Frostline][Leaderboard] disabled for this Studio server because API access is unavailable: %s",
			tostring(rawError)
		))
	end
	publishLastGoodState()
	return true
end

local function waitWhileActive(seconds: number, generation: number, deadline: number): boolean
	if not isActiveGeneration(generation) or os.clock() >= deadline then
		return false
	end
	local remaining = deadline - os.clock()
	if seconds > 0 and remaining > 0 then
		task.wait(math.min(seconds, remaining))
	end
	return isActiveGeneration(generation) and os.clock() < deadline
end

local function waitForBudgets(
	requestTypes: { Enum.DataStoreRequestType },
	generation: number,
	retryDeadline: number
): boolean
	local budgetDeadline = math.min(retryDeadline, os.clock() + LEADERBOARD.BudgetWaitMaximumSeconds)
	while isActiveGeneration(generation) and os.clock() < budgetDeadline do
		local hasBudget = true
		for _, requestType in requestTypes do
			if not isActiveGeneration(generation) then
				return false
			end
			local budgetSuccess, availableBudget = pcall(function(): number
				return DataStoreService:GetRequestBudgetForRequestType(requestType)
			end)
			if not isActiveGeneration(generation) then
				return false
			end
			if not budgetSuccess or availableBudget < 1 then
				hasBudget = false
				break
			end
		end
		if hasBudget then
			return true
		end

		local remaining = budgetDeadline - os.clock()
		if remaining <= 0 then
			break
		end
		task.wait(math.min(LEADERBOARD.BudgetPollIntervalSeconds, remaining))
		if not isActiveGeneration(generation) then
			return false
		end
	end
	return false
end

local function retryDelay(completedAttempts: number): number
	local exponential = LEADERBOARD.RetryBaseDelaySeconds * (2 ^ math.max(0, completedAttempts - 1))
	local withJitter = exponential + retryRandom:NextNumber(0, LEADERBOARD.RetryJitterSeconds)
	return math.min(LEADERBOARD.RetryMaximumDelaySeconds, withJitter)
end

local function monotonicTransform(candidate: number, currentValue: any): number?
	if currentValue == nil then
		return candidate
	elseif isSafeInteger(currentValue) then
		return math.max(currentValue, candidate)
	end
	return nil
end

local function performWriteSeries(
	userId: number,
	candidate: number,
	generation: number
): (string, number?, string)
	local store = orderedStore
	if store == nil or not isActiveGeneration(generation) then
		return "aborted", nil, "service inactive"
	end

	local deadline = os.clock() + LEADERBOARD.RetryDeadlineSeconds
	local attempts = 0
	local lastReason = "retry deadline reached"
	while attempts < LEADERBOARD.WriteMaximumAttempts and isActiveGeneration(generation) do
		if os.clock() >= deadline then
			break
		end

		if attempts > 0 and not waitWhileActive(retryDelay(attempts), generation, deadline) then
			return if isActiveGeneration(generation) then "exhausted" else "aborted", nil, lastReason
		end

		local spacing = LEADERBOARD.MinimumWriteIntervalSeconds - (os.clock() - lastWriteAttemptStartedAt)
		if spacing > 0 and not waitWhileActive(spacing, generation, deadline) then
			return if isActiveGeneration(generation) then "exhausted" else "aborted", nil, lastReason
		end
		if not waitForBudgets(WRITE_REQUEST_TYPES, generation, deadline) then
			lastReason = "ordered read/write budget was unavailable"
			break
		end
		if not isActiveGeneration(generation) or os.clock() >= deadline then
			return if isActiveGeneration(generation) then "exhausted" else "aborted", nil, lastReason
		end

		attempts += 1
		lastWriteAttemptStartedAt = os.clock()
		local callSucceeded, returnedValue = pcall(function()
			return store:UpdateAsync(LEADERBOARD.KeyPrefix .. tostring(userId), function(currentValue: any)
				return monotonicTransform(candidate, currentValue)
			end)
		end)
		if not isActiveGeneration(generation) then
			return "aborted", nil, "service became inactive"
		end

		if callSucceeded then
			if isSafeInteger(returnedValue) and returnedValue >= candidate then
				return "success", returnedValue, ""
			end
			lastReason = "ordered write returned an invalid acknowledgement"
		else
			lastReason = tostring(returnedValue)
			if openStudioApiCircuit(returnedValue) then
				return "aborted", nil, "Studio API access unavailable"
			end
		end
	end

	if not isActiveGeneration(generation) then
		return "aborted", nil, lastReason
	end
	return "exhausted", nil, lastReason
end

local function queuePush(userId: number): boolean
	if writeQueueCount >= LEADERBOARD.QueueCapacity then
		return false
	end
	writeQueueTail = (writeQueueTail % LEADERBOARD.QueueCapacity) + 1
	writeQueue[writeQueueTail] = userId
	writeQueueCount += 1
	return true
end

local function queuePop(): number?
	if writeQueueCount <= 0 then
		return nil
	end
	local userId = writeQueue[writeQueueHead]
	writeQueue[writeQueueHead] = nil
	writeQueueHead = (writeQueueHead % LEADERBOARD.QueueCapacity) + 1
	writeQueueCount -= 1
	return userId
end

local function touchWriteEntry(entry: WriteEntry)
	writeTouchSequence += 1
	entry.TouchedSequence = writeTouchSequence
end

local function makeWriteCapacity(): boolean
	if writeEntryCount < LEADERBOARD.QueueCapacity then
		return true
	end

	local oldestUserId: number? = nil
	local oldestSequence = math.huge
	for userId, entry in writeEntries do
		if not entry.InFlight and not entry.Queued then
			if entry.TouchedSequence < oldestSequence
				or (entry.TouchedSequence == oldestSequence and (oldestUserId == nil or userId < oldestUserId))
			then
				oldestSequence = entry.TouchedSequence
				oldestUserId = userId
			end
		end
	end
	if oldestUserId == nil then
		return false
	end
	writeEntries[oldestUserId] = nil
	writeEntryCount -= 1
	return true
end

local function getOrCreateWriteEntry(userId: number): WriteEntry?
	local existing = writeEntries[userId]
	if existing ~= nil then
		touchWriteEntry(existing)
		return existing
	end
	if not makeWriteCapacity() then
		return nil
	end

	local created: WriteEntry = {
		Acknowledged = nil,
		Deferred = nil,
		InFlight = false,
		Pending = nil,
		Queued = false,
		TouchedSequence = 0,
	}
	touchWriteEntry(created)
	writeEntries[userId] = created
	writeEntryCount += 1
	return created
end

local function enqueueEntry(userId: number, entry: WriteEntry): boolean
	if entry.Queued or entry.InFlight or entry.Pending == nil then
		return true
	end
	if not queuePush(userId) then
		return false
	end
	entry.Queued = true
	return true
end

local function completeWrite(
	userId: number,
	entry: WriteEntry,
	candidate: number,
	resultKind: string,
	acknowledged: number?,
	reason: string,
	generation: number
)
	entry.InFlight = false
	touchWriteEntry(entry)
	if not isActiveGeneration(generation) or writeEntries[userId] ~= entry then
		return
	end

	if resultKind == "success" and acknowledged ~= nil then
		local previousAcknowledged = entry.Acknowledged
		entry.Acknowledged = if previousAcknowledged == nil
			then acknowledged
			else math.max(previousAcknowledged, acknowledged)
		entry.Deferred = nil
		if entry.Pending ~= nil and entry.Pending > entry.Acknowledged then
			enqueueEntry(userId, entry)
		else
			entry.Pending = nil
		end
		if previousAcknowledged == nil or acknowledged > previousAcknowledged then
			scheduleRefresh(LEADERBOARD.RefreshDebounceSeconds)
		end
		return
	end

	if resultKind == "exhausted" then
		local laterCandidate = entry.Pending
		entry.Pending = nil
		if laterCandidate ~= nil and laterCandidate > candidate then
			entry.Pending = laterCandidate
			entry.Deferred = if entry.Deferred == nil
				then candidate
				else math.max(entry.Deferred, candidate)
			enqueueEntry(userId, entry)
		else
			local deferred = candidate
			if laterCandidate ~= nil then
				deferred = math.max(deferred, laterCandidate)
			end
			if entry.Deferred ~= nil then
				deferred = math.max(deferred, entry.Deferred)
			end
			entry.Deferred = deferred
		end
		warnRateLimited(
			"write",
			string.format("[Frostline][Leaderboard] ordered write exhausted bounded retries: %s", reason)
		)
	end
end

local function runWriteDrain(generation: number)
	while isActiveGeneration(generation) do
		local userId = queuePop()
		if userId == nil then
			break
		end
		local entry = writeEntries[userId]
		if entry ~= nil then
			entry.Queued = false
			local candidate = entry.Pending
			entry.Pending = nil
			if candidate ~= nil and (entry.Acknowledged == nil or candidate > entry.Acknowledged) then
				entry.InFlight = true
				local resultKind, acknowledged, reason = performWriteSeries(userId, candidate, generation)
				completeWrite(userId, entry, candidate, resultKind, acknowledged, reason, generation)
			end
		end
	end

	writeDrainActive = false
	if isActiveGeneration(generation) and writeQueueCount > 0 then
		scheduleWriteDrain()
	end
end

scheduleWriteDrain = function()
	if writeDrainActive or writeQueueCount <= 0 then
		return
	end
	local generation = serviceGeneration
	if not isActiveGeneration(generation) then
		return
	end
	writeDrainActive = true
	task.defer(function()
		if not isActiveGeneration(generation) then
			writeDrainActive = false
			return
		end
		local succeeded, failureReason = pcall(runWriteDrain, generation)
		if not succeeded then
			writeDrainActive = false
			warnRateLimited(
				"write-worker",
				string.format("[Frostline][Leaderboard] write worker failed: %s", tostring(failureReason))
			)
		end
	end)
end

local function fallbackDisplayName(userId: number): string
	return string.format("Player %d", userId)
end

local function removeUsernameCacheEntry(userId: number)
	if usernameCache[userId] ~= nil then
		usernameCache[userId] = nil
		usernameCacheCount -= 1
	end
end

local function makeUsernameCacheCapacity(userId: number)
	if usernameCache[userId] ~= nil or usernameCacheCount < LEADERBOARD.UsernameCacheCapacity then
		return
	end

	local oldestUserId: number? = nil
	local oldestSequence = math.huge
	for cachedUserId, cached in usernameCache do
		if cached.AccessSequence < oldestSequence
			or (cached.AccessSequence == oldestSequence and (oldestUserId == nil or cachedUserId < oldestUserId))
		then
			oldestSequence = cached.AccessSequence
			oldestUserId = cachedUserId
		end
	end
	if oldestUserId ~= nil then
		removeUsernameCacheEntry(oldestUserId)
	end
end

local function cacheUsername(userId: number, username: string?)
	makeUsernameCacheCapacity(userId)
	local wasPresent = usernameCache[userId] ~= nil
	usernameAccessSequence += 1
	usernameCache[userId] = {
		AccessSequence = usernameAccessSequence,
		ExpiresAt = os.clock()
			+ (if username == nil
				then LEADERBOARD.UsernameFailureCacheSeconds
				else LEADERBOARD.UsernamePositiveCacheSeconds),
		Username = username,
	}
	if not wasPresent then
		usernameCacheCount += 1
	end
end

local function getCachedDisplayName(userId: number): (boolean, string)
	local cached = usernameCache[userId]
	if cached == nil then
		return false, fallbackDisplayName(userId)
	end
	if cached.ExpiresAt <= os.clock() then
		removeUsernameCacheEntry(userId)
		return false, fallbackDisplayName(userId)
	end

	usernameAccessSequence += 1
	cached.AccessSequence = usernameAccessSequence
	if cached.Username == nil then
		return true, fallbackDisplayName(userId)
	end
	return true, "@" .. cached.Username
end

local function lookupJobIsCurrent(job: LookupJob): boolean
	return job.Batch.Open
		and job.Batch.RefreshGeneration == job.RefreshGeneration
		and isRefreshCurrent(job.ServiceGeneration, job.RefreshGeneration)
end

local function compactLookupQueue()
	local retained: { LookupJob } = {}
	for _, job in lookupQueue do
		if lookupJobIsCurrent(job) then
			table.insert(retained, job)
		else
			job.Batch.Open = false
		end
	end
	lookupQueue = retained
end

local function popLookupJob(): LookupJob?
	compactLookupQueue()
	if #lookupQueue == 0 then
		return nil
	end
	return table.remove(lookupQueue, 1)
end

local function finishLookupJob(job: LookupJob, displayName: string)
	if not lookupJobIsCurrent(job) then
		return
	end
	job.Batch.Results[job.UserId] = displayName
	job.Batch.Remaining = math.max(0, job.Batch.Remaining - 1)
end

local function runLookupWorker(firstJob: LookupJob)
	local nextJob: LookupJob? = firstJob
	while not destroyed and not circuitOpen do
		local job = nextJob
		if job == nil then
			break
		end
		if lookupJobIsCurrent(job) then
			local generation = job.ServiceGeneration
			local lookupSucceeded, username = pcall(function()
				return Players:GetNameFromUserIdAsync(job.UserId)
			end)
			if not isActiveGeneration(generation) then
				break
			end

			local validUsername: string? = nil
			if lookupSucceeded and typeof(username) == "string" and username ~= "" then
				validUsername = username
			elseif not lookupSucceeded then
				warnRateLimited(
					"username",
					string.format("[Frostline][Leaderboard] username lookup failed: %s", tostring(username))
				)
			end
			cacheUsername(job.UserId, validUsername)
			finishLookupJob(
				job,
				if validUsername == nil then fallbackDisplayName(job.UserId) else "@" .. validUsername
			)
		end
		nextJob = popLookupJob()
	end

end

local function runLookupWorkerSafely(firstJob: LookupJob)
	local succeeded, failureReason = pcall(runLookupWorker, firstJob)
	lookupWorkersAlive = math.max(0, lookupWorkersAlive - 1)
	if not succeeded then
		warnRateLimited(
			"username-worker",
			string.format("[Frostline][Leaderboard] username worker failed: %s", tostring(failureReason))
		)
	end
	if not destroyed and not circuitOpen and #lookupQueue > 0 then
		ensureLookupWorkers()
	end
end

ensureLookupWorkers = function()
	compactLookupQueue()
	while lookupWorkersAlive < LEADERBOARD.NameLookupConcurrency do
		local firstJob = popLookupJob()
		if firstJob == nil then
			break
		end
		lookupWorkersAlive += 1
		task.spawn(runLookupWorkerSafely, firstJob)
	end
end

local function resolveDisplayNames(
	rawEntries: { RawBoardEntry },
	generation: number,
	candidateRefreshGeneration: number
): { BoardEntry }?
	local displayNames: { [number]: string } = {}
	local unresolved: { number } = {}
	for _, entry in rawEntries do
		local cacheHit, displayName = getCachedDisplayName(entry.UserId)
		if cacheHit then
			displayNames[entry.UserId] = displayName
		else
			table.insert(unresolved, entry.UserId)
		end
	end

	if #unresolved > 0 then
		local batch: LookupBatch = {
			Open = true,
			RefreshGeneration = candidateRefreshGeneration,
			Remaining = #unresolved,
			Results = {},
		}
		compactLookupQueue()
		for _, userId in unresolved do
			table.insert(lookupQueue, {
				Batch = batch,
				RefreshGeneration = candidateRefreshGeneration,
				ServiceGeneration = generation,
				UserId = userId,
			})
		end
		ensureLookupWorkers()

		local lookupDeadline = os.clock() + LEADERBOARD.NameLookupBatchTimeoutSeconds
		while batch.Remaining > 0
			and isRefreshCurrent(generation, candidateRefreshGeneration)
			and os.clock() < lookupDeadline
		do
			task.wait(math.min(0.05, math.max(0, lookupDeadline - os.clock())))
			if not isRefreshCurrent(generation, candidateRefreshGeneration) then
				batch.Open = false
				return nil
			end
		end
		batch.Open = false
		for _, userId in unresolved do
			displayNames[userId] = batch.Results[userId] or fallbackDisplayName(userId)
		end
	end

	if not isRefreshCurrent(generation, candidateRefreshGeneration) then
		return nil
	end
	local resolved: { BoardEntry } = {}
	for _, entry in rawEntries do
		table.insert(resolved, {
			UserId = entry.UserId,
			EncodedScore = entry.EncodedScore,
			DisplayName = displayNames[entry.UserId] or fallbackDisplayName(entry.UserId),
		})
	end
	return resolved
end

local function parseUserIdKey(key: any): number?
	if typeof(key) ~= "string" then
		return nil
	end
	local escapedPrefix = string.gsub(LEADERBOARD.KeyPrefix, "(%W)", "%%%1")
	local userIdText = string.match(key, "^" .. escapedPrefix .. "(%d+)$")
	if userIdText == nil then
		return nil
	end
	local userId = tonumber(userIdText)
	if not isPositiveSafeInteger(userId) then
		return nil
	end
	return userId
end

local function validateSortedPage(rawPage: any): { RawBoardEntry }?
	if typeof(rawPage) ~= "table" then
		return nil
	end
	local entries: { RawBoardEntry } = {}
	local seenUserIds: { [number]: boolean } = {}
	for _, rawEntry in rawPage do
		if #entries >= LEADERBOARD.PageSize then
			break
		end
		if typeof(rawEntry) == "table" then
			local userId = parseUserIdKey(rawEntry.key)
			local encodedScore = rawEntry.value
			if userId ~= nil
				and not seenUserIds[userId]
				and isSafeInteger(encodedScore)
				and encodedScore >= LEADERBOARD.MinimumEncodedScore
				and encodedScore <= LEADERBOARD.MaximumEncodedScore
			then
				seenUserIds[userId] = true
				table.insert(entries, {
					UserId = userId,
					EncodedScore = encodedScore,
				})
			end
		end
	end
	table.sort(entries, function(left: RawBoardEntry, right: RawBoardEntry): boolean
		if left.EncodedScore == right.EncodedScore then
			return left.UserId < right.UserId
		end
		return left.EncodedScore > right.EncodedScore
	end)
	return entries
end

local function performReadSeries(generation: number): (string, { RawBoardEntry }?, string)
	local store = orderedStore
	if store == nil or not isActiveGeneration(generation) then
		return "aborted", nil, "service inactive"
	end

	local deadline = os.clock() + LEADERBOARD.RetryDeadlineSeconds
	local attempts = 0
	local lastReason = "retry deadline reached"
	while attempts < LEADERBOARD.ReadMaximumAttempts and isActiveGeneration(generation) do
		if os.clock() >= deadline then
			break
		end
		if attempts > 0 and not waitWhileActive(retryDelay(attempts), generation, deadline) then
			return if isActiveGeneration(generation) then "exhausted" else "aborted", nil, lastReason
		end
		if not waitForBudgets(READ_REQUEST_TYPES, generation, deadline) then
			lastReason = "ordered list budget was unavailable"
			break
		end
		if not isActiveGeneration(generation) or os.clock() >= deadline then
			return if isActiveGeneration(generation) then "exhausted" else "aborted", nil, lastReason
		end

		attempts += 1
		local callSucceeded, pageOrError = pcall(function()
			local pages = store:GetSortedAsync(
				false,
				LEADERBOARD.PageSize,
				LEADERBOARD.MinimumEncodedScore,
				LEADERBOARD.MaximumEncodedScore
			)
			return pages:GetCurrentPage()
		end)
		if not isActiveGeneration(generation) then
			return "aborted", nil, "service became inactive"
		end

		if callSucceeded then
			local validated = validateSortedPage(pageOrError)
			if validated ~= nil then
				return "success", validated, ""
			end
			lastReason = "ordered read returned a malformed page"
		else
			lastReason = tostring(pageOrError)
			if openStudioApiCircuit(pageOrError) then
				return "aborted", nil, "Studio API access unavailable"
			end
		end
	end

	if not isActiveGeneration(generation) then
		return "aborted", nil, lastReason
	end
	return "exhausted", nil, lastReason
end

local function runRefresh(generation: number, candidateRefreshGeneration: number)
	local resultKind, rawEntries, reason = performReadSeries(generation)
	if not isRefreshCurrent(generation, candidateRefreshGeneration) then
		return
	end
	if resultKind ~= "success" or rawEntries == nil then
		if resultKind == "exhausted" then
			warnRateLimited(
				"read",
				string.format("[Frostline][Leaderboard] ordered read exhausted bounded retries: %s", reason)
			)
			if lastGoodUpdatedAt == nil then
				publishStatus("LEADERBOARD TEMPORARILY UNAVAILABLE")
			end
		end
		return
	end

	local resolvedEntries = resolveDisplayNames(rawEntries, generation, candidateRefreshGeneration)
	if resolvedEntries == nil or not isRefreshCurrent(generation, candidateRefreshGeneration) then
		return
	end
	lastGoodEntries = resolvedEntries
	lastGoodUpdatedAt = os.time()
	if #resolvedEntries == 0 then
		publishStatus("NO SCORES YET")
	else
		publishEntries(resolvedEntries)
	end
end

local function finishRefresh(generation: number, candidateRefreshGeneration: number)
	local succeeded, failure = pcall(function()
		runRefresh(generation, candidateRefreshGeneration)
	end)
	if not succeeded and isRefreshCurrent(generation, candidateRefreshGeneration) then
		warnRateLimited(
			"refresh",
			string.format("[Frostline][Leaderboard] refresh pipeline failed: %s", tostring(failure))
		)
		if lastGoodUpdatedAt == nil then
			publishStatus("LEADERBOARD TEMPORARILY UNAVAILABLE")
		end
	end

	refreshInFlight = false
	if isActiveGeneration(generation) and refreshAfterFlight then
		local delaySeconds = refreshAfterFlightDelay
		refreshAfterFlight = false
		refreshAfterFlightDelay = math.huge
		scheduleRefresh(delaySeconds)
	end
end

scheduleRefresh = function(minimumDelay: number)
	if destroyed or circuitOpen or not started then
		return
	end
	if refreshInFlight then
		refreshAfterFlight = true
		refreshAfterFlightDelay = math.min(refreshAfterFlightDelay, minimumDelay)
		return
	end
	if refreshScheduleThread ~= nil then
		return
	end

	local generation = serviceGeneration
	if not isActiveGeneration(generation) then
		return
	end
	local earliestStart = math.max(
		os.clock() + math.max(0, minimumDelay),
		lastRefreshStartedAt + LEADERBOARD.MinimumRefreshIntervalSeconds
	)
	local delaySeconds = math.max(0, earliestStart - os.clock())
	refreshScheduleThread = task.delay(delaySeconds, function()
		refreshScheduleThread = nil
		if not isActiveGeneration(generation) or refreshInFlight then
			return
		end
		refreshInFlight = true
		lastRefreshStartedAt = os.clock()
		refreshGeneration += 1
		finishRefresh(generation, refreshGeneration)
	end)
end

local function runPeriodicRefresh(generation: number)
	while isActiveGeneration(generation) do
		task.wait(LEADERBOARD.RefreshIntervalSeconds)
		if not isActiveGeneration(generation) then
			break
		end
		scheduleRefresh(0)
	end
end

function LeaderboardService.enqueueVerifiedBest(userId: number, verifiedBestDistance: number)
	if destroyed or circuitOpen then
		return
	end
	if not isPositiveSafeInteger(userId) or not isFiniteNumber(verifiedBestDistance) then
		return
	end

	local candidate = math.round(verifiedBestDistance * LEADERBOARD.ScoreScale)
	if not isSafeInteger(candidate)
		or candidate < LEADERBOARD.MinimumEncodedScore
		or candidate > LEADERBOARD.MaximumEncodedScore
	then
		return
	end

	local entry = getOrCreateWriteEntry(userId)
	if entry == nil then
		warnRateLimited("capacity", "[Frostline][Leaderboard] write queue capacity reached; projection deferred")
		return
	end
	if entry.Acknowledged ~= nil and entry.Acknowledged >= candidate then
		return
	end

	local highestCandidate = candidate
	if entry.Pending ~= nil then
		highestCandidate = math.max(highestCandidate, entry.Pending)
	end
	if entry.Deferred ~= nil then
		highestCandidate = math.max(highestCandidate, entry.Deferred)
		entry.Deferred = nil
	end
	entry.Pending = highestCandidate
	touchWriteEntry(entry)
	if not entry.InFlight and not enqueueEntry(userId, entry) then
		entry.Deferred = entry.Pending
		entry.Pending = nil
		warnRateLimited("capacity", "[Frostline][Leaderboard] write queue capacity reached; projection deferred")
		return
	end
	if started then
		scheduleWriteDrain()
	end
end

function LeaderboardService.start()
	if started or destroyed or circuitOpen then
		return
	end

	local selectedStoreName = if RunService:IsStudio()
		then LEADERBOARD.StudioStoreName
		else LEADERBOARD.ProductionStoreName
	local acquired, storeOrError = pcall(function()
		return DataStoreService:GetOrderedDataStore(selectedStoreName, LEADERBOARD.Scope)
	end)
	if not acquired then
		publishStatus("LEADERBOARD TEMPORARILY UNAVAILABLE")
		if isStudioApiDisabledFailure(storeOrError) then
			openStudioApiCircuit(storeOrError)
			return
		end
		error(tostring(storeOrError))
	end
	orderedStore = storeOrError :: OrderedDataStore
	started = true
	serviceGeneration += 1
	local generation = serviceGeneration
	publishStatus("LOADING LEADERBOARD")

	game:BindToClose(function()
		LeaderboardService.destroy()
	end)

	startupThread = task.defer(function()
		startupThread = nil
		if not isActiveGeneration(generation) then
			return
		end
		scheduleWriteDrain()
		scheduleRefresh(0)
		periodicThread = task.spawn(function()
			runPeriodicRefresh(generation)
		end)
	end)
end

function LeaderboardService.destroy()
	if destroyed then
		return
	end
	destroyed = true
	started = false
	serviceGeneration += 1
	refreshGeneration += 1
	stopScheduledWork()
	orderedStore = nil
	writeQueue = {}
	writeQueueHead = 1
	writeQueueTail = 0
	writeQueueCount = 0
	writeEntries = {}
	writeEntryCount = 0
	writeDrainActive = false
	boardRefs = nil
end

return LeaderboardService
