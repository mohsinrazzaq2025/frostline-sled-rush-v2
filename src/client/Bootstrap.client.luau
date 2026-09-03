--!strict

local RunController = require(script.Parent.Controllers.RunController)
local ResultController = require(script.Parent.Controllers.ResultController)

RunController.start()
ResultController.start()

print("[Frostline] Client bootstrap complete")
