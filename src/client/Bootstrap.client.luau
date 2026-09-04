--!strict

local AudioController = require(script.Parent.Controllers.AudioController)
local VFXController = require(script.Parent.Controllers.VFXController)
local RunController = require(script.Parent.Controllers.RunController)
local ResultController = require(script.Parent.Controllers.ResultController)

AudioController.start()
RunController.start()
-- RunController waits for the server-created remotes, which means WorldBuilder's
-- Lighting and sled hierarchy are available before client VFX inspects them.
VFXController.start()
ResultController.start()

print("[Frostline] Client bootstrap complete")
