--!strict

local WorldBuilder = require(script.Parent.Services.WorldBuilder)
local PlayerDataService = require(script.Parent.Services.PlayerDataService)
local RunManager = require(script.Parent.Services.RunManager)
local StoreService = require(script.Parent.Services.StoreService)

PlayerDataService.start(function(player: Player)
	StoreService.handlePlayerRemoving(player)
	RunManager.handlePlayerRemoving(player)
end)
WorldBuilder.build()
RunManager.start()
StoreService.start()

print("[Frostline] Server bootstrap complete")
