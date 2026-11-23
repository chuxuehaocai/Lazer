-- Atelier: a declarative skin example.
--
-- Host contract: https://lazer.naominet.dev/docs (docs/lua-plugins.md in the
-- app repository, "主题与页面布局").
--
-- A skin never returns Flutter widgets. It returns the same JSON-shaped token
-- tables the built-in themes use. The host clamps numbers, ignores unknown
-- fields and keeps ownership of widgets, focus, semantics and navigation.
--
-- This plugin deliberately declares no music provider: describe returns an
-- empty providers list, so enabling it changes the look of the app and nothing
-- else.

local skin = require("theme")

local function errorResult(message)
  return { error = { code = 400, message = message } }
end

return {
  call = function(operation, args)
    if operation == "describe" then
      -- `theme = true` asks the host to call the `theme` operation once after
      -- startup. Returning the bundle inline here would work too; using the
      -- operation keeps the token tables in a module and shows both halves of
      -- the contract.
      return {
        providers = {},
        theme = true,
      }
    end
    if operation == "theme" then
      return skin.bundle()
    end
    if operation == "skin" then
      return skin.bundle()
    end
    return errorResult("unsupported operation: " .. tostring(operation))
  end,
}