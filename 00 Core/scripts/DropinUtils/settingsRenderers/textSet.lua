---@diagnostic disable: missing-fields, redundant-return-value
---@omw-context menu
-- Part of Bor's Drop-in Utils project: https://github.com/OpenMW-Mod-Collection/DropinUtils
local I = require("openmw.interfaces")
local ui = require("openmw.ui")
local async = require("openmw.async")

-- ============================================================================
-- textSet renderer — a free-form, add/remove set of strings (e.g. an ID list)
-- ============================================================================
-- USAGE (settings config entry):
--   {
--      key = 'MY_BLACKLIST',
--      name = 'Blacklist NPC by ID',
--      description = 'Add NPC IDs to the blacklist.',
--      renderer = 'textSet',
--      default = {
--         ["caius cosades"] = true,
--         ["guar"] = true,
--         ["vivec"] = true,
--      },
--      argument = {
--         lower = true,   -- OPTIONAL, default: false. Default values don't get lowercased automatically
--      },
--   },
--
-- RESULTING STORED VALUE:
--   { ["caius cosades"] = true, ["guar"] = true, ["vivec"] = true }
-- ============================================================================


---@class TextSetArgs
---@field lower? boolean    OPTIONAL, Default: false
---                         If true, all input text will be lowered.
---                         It does not lower your default values due to how Lua API works.

I.Settings.registerRenderer('textSet_V1', function(input, set, arg)
    ---@type TextSetArgs
    arg = arg or {}
    local lower = arg.lower == true

    if not input then
        input = {}
        set(input)
    end

    local header = {
        type = ui.TYPE.Flex,
        props = {
            horizontal = true,
        },
        content = ui.content({}),
        external = {
            stretch = 1,
        },
    }

    local inputText = ''

    header.content:add {
        template = I.MWUI.templates.box,
        content = ui.content { {
            template = I.MWUI.templates.padding,
            content = ui.content { {
                template = I.MWUI.templates.textNormal,
                props = {
                    text = "Add",
                },
                events = {
                    mouseClick = async:callback(function()
                        -- no empty strings allowed
                        if inputText == "" then return end

                        -- no duplicates allowed (map key already true)
                        if input[inputText] then
                            set(input)
                            return
                        end

                        input[inputText] = true
                        set(input)
                    end),
                },
            } }
        } },
    }
    header.content:add {
        template = I.MWUI.templates.padding,
        external = {
            grow = 1,
        },
    }
    header.content:add {
        template = I.MWUI.templates.box,
        content = ui.content { {
            template = I.MWUI.templates.padding,
            content = ui.content { {
                template = I.MWUI.templates.textEditLine,
                events = {
                    textChanged = async:callback(function(text)
                        inputText = lower
                            and text:lower()
                            or text
                    end),
                } },
            } },
        },
    }

    local body = {
        type = ui.TYPE.Flex,
        content = ui.content({}),
    }

    local function remove(text)
        input[text] = nil
    end

    local sortedKeys = {}
    for text in pairs(input) do
        table.insert(sortedKeys, text)
    end
    table.sort(sortedKeys)

    for _, text in ipairs(sortedKeys) do
        body.content:add {
            template = I.MWUI.templates.padding,
        }
        body.content:add {
            type = ui.TYPE.Flex,
            props = {
                horizontal = true,
                arrange = ui.ALIGNMENT.Center,
            },
            content = ui.content {
                {
                    template = I.MWUI.templates.box,
                    content = ui.content { {
                        template = I.MWUI.templates.padding,
                        content = ui.content { {
                            template = I.MWUI.templates.textNormal,
                            props = {
                                text = "x",
                                textAlignV = ui.ALIGNMENT.Center,
                            },
                            events = {
                                mouseClick = async:callback(function()
                                    remove(text)
                                    set(input)
                                end),
                            },
                        } },
                    } },
                },
                {
                    template = I.MWUI.templates.padding,
                },
                {
                    template = I.MWUI.templates.textNormal,
                    props = { text = text },
                },
            },
        }
    end

    return {
        type = ui.TYPE.Flex,
        content = ui.content {
            header,
            body,
        },
    }
end)
