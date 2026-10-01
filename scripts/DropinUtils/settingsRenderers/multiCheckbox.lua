---@diagnostic disable: missing-fields
---@omw-context menu
-- Part of Bor's Drop-in Utils project: https://github.com/OpenMW-Mod-Collection/DropinUtils
local I = require("openmw.interfaces")
local core = require("openmw.core")
local async = require("openmw.async")
local ui = require("openmw.ui")
local util = require("openmw.util")
local ambient = require("openmw.ambient")

-- ============================================================================
-- multiCheckbox renderer — a row of labeled checkboxes stored as one table
-- ============================================================================
-- USAGE (settings config entry):
--   {
--      key = 'MY_TOGGLES',
--      name = 'Feature Toggles',
--      description = 'Pick which features are active.',
--      renderer = 'multiCheckbox',
--      default = {
--         optionA = true,
--         optionB = false,
--         optionC = true,
--      },
--      argument = {
--         l10n = 'MyMod',   -- OPTIONAL, assumes argument.keys = l10n keys
--         keys = {          -- REQUIRED, keys not in defaults will be treated as false
--            'optionA',
--            'optionB',
--            'optionC',
--         },
--         colorful = false, -- OPTIONAL, default: false. Vanilla text colors vs green/red
--      },
--   },
--
-- RESULTING STORED VALUE:
--   { optionA = true, optionB = false, optionC = true }
-- ============================================================================

local CHECK_TEXTURE_ON = ui.texture({ path = "textures/menu_scroll_scroller_middle.dds" })
local CHECK_TEXTURE_OFF = ui.texture({ path = "textures/menu_scroll_scroller_middle.dds" })
local CHECKBOX_SIZE = 12

local colorFromGMST = function(gmst)
   local colorString = core.getGMST(gmst)
   local numberTable = {}
   for numberString in colorString:gmatch("([^,]+)") do
      if #numberTable == 3 then break end
      local number = tonumber(numberString:match("^%s*(.-)%s*$"))
      if number then
         table.insert(numberTable, number / 255)
      end
   end

   if #numberTable < 3 then error('Invalid color GMST name: ' .. gmst) end

   return util.color.rgb(table.unpack(numberTable))
end

local MORROWIND_TEXT_STATES = {
   disabled           = { color = colorFromGMST('fontcolor_color_disabled'), alpha = 0.75 },
   disabledHover      = { color = colorFromGMST('fontcolor_color_disabled_over'), alpha = 0.75 },
   disabledInteracted = { color = colorFromGMST('fontcolor_color_disabled_pressed'), alpha = 0.75 },
   enabled            = { color = colorFromGMST('fontcolor_color_normal'), alpha = 1.0 },
   enabledHover       = { color = colorFromGMST('fontcolor_color_normal_over'), alpha = 1.0 },
   enabledInteracted  = { color = colorFromGMST('fontcolor_color_normal_pressed'), alpha = 1.0 },
}
local MORROWIND_CHECK_STATES = {
   disabled           = { color = util.color.rgb(1, 1, 1), alpha = 0 },
   disabledHover      = { color = util.color.rgb(1, 1, 1), alpha = 0 },
   disabledInteracted = { color = util.color.rgb(1, 1, 1), alpha = 0 },
   enabled            = { color = util.color.rgb(1, 1, 1), alpha = 1.0 },
   enabledHover       = { color = util.color.rgb(1, 1, 1), alpha = 1.0 },
   enabledInteracted  = { color = util.color.rgb(1, 1, 1), alpha = 1.0 },
}
local COLORFUL_TEXT_STATES = {
   disabled           = { color = util.color.rgb(0.95, 0.35, 0.35), alpha = 1.0 },
   disabledHover      = { color = util.color.rgb(1.00, 0.55, 0.55), alpha = 1.0 },
   disabledInteracted = { color = util.color.rgb(1.00, 0.75, 0.75), alpha = 1.0 },
   enabled            = { color = util.color.rgb(0.50, 0.95, 0.40), alpha = 1.0 },
   enabledHover       = { color = util.color.rgb(0.75, 1.00, 0.75), alpha = 1.0 },
   enabledInteracted  = { color = util.color.rgb(0.95, 1.00, 0.95), alpha = 1.0 },
}
local COLORFUL_CHECK_STATES = {
   disabled           = { color = util.color.rgb(1, 1, 1), alpha = 0 },
   disabledHover      = { color = util.color.rgb(1, 1, 1), alpha = 0 },
   disabledInteracted = { color = util.color.rgb(1, 1, 1), alpha = 0 },
   enabled            = { color = util.color.rgb(1, 1, 1), alpha = 1.0 },
   enabledHover       = { color = util.color.rgb(1, 1, 1), alpha = 1.0 },
   enabledInteracted  = { color = util.color.rgb(1, 1, 1), alpha = 1.0 },
}

local padding = {
   template = I.MWUI.templates.padding
}
local interval = {
   template = I.MWUI.templates.interval
}

local function updateTextColor(state, textWidget)
   textWidget.layout.props.textColor = state.color
   textWidget.layout.props.alpha = state.alpha
   textWidget:update()
end

local function updateImageColor(state, imageWidget)
   imageWidget.layout.props.color = state.color
   imageWidget.layout.props.alpha = state.alpha
   imageWidget:update()
end

local function unpackStates(userData, defaultState)
   local function pick(name, fallbackColor, fallbackAlpha)
      local s = {}
      if userData ~= nil and userData[name] ~= nil then
         s.color = userData[name].color
         s.alpha = userData[name].alpha
      end
      s.color = s.color or fallbackColor
      s.alpha = s.alpha or fallbackAlpha
      return s
   end

   local states = {}
   states.disabled = pick('disabled', defaultState.color, 0.5)
   states.enabled = pick('enabled', defaultState.color, defaultState.alpha)
   states.disabledHover = pick('disabledHover', states.disabled.color, states.disabled.alpha)
   states.enabledHover = pick('enabledHover', states.enabled.color, states.enabled.alpha)
   states.disabledInteracted = pick('disabledInteracted', states.disabledHover.color, states.disabledHover.alpha)
   states.enabledInteracted = pick('enabledInteracted', states.enabledHover.color, states.enabledHover.alpha)

   return states
end

local function restingState(states, isChecked)
   if isChecked then return states.enabled else return states.disabled end
end

local function hoverState(states, isChecked)
   if isChecked then return states.enabledHover else return states.disabledHover end
end

local function interactedState(states, isChecked)
   if isChecked then return states.enabledInteracted else return states.disabledInteracted end
end

I.Settings.registerRenderer('multiCheckbox_V1', function(input, set, args)
   local buttonHeld = false

   if type(input) ~= "table" then input = {} end
   if args == nil then args = {} end
   if args.keys ~= nil then
      for _, text in ipairs(args.keys) do
         input[text] = input[text] or false
      end
   end

   local translate = args.l10n
       and core.l10n(args.l10n)
       or function(key) return key end

   local body = {
      type = ui.TYPE.Flex,
      props = {
         horizontal = false,
         arrange = ui.ALIGNMENT.End,
      },
      content = ui.content({}),
   }

   for _, key in ipairs(args.keys) do
      local label = translate(key)

      local labelText = ui.create({
         template = I.MWUI.templates.textNormal,
         props = {
            text = label,
            textAlignH = ui.ALIGNMENT.Start,
            textAlignV = ui.ALIGNMENT.Center,
         },
      })

      local checkMark = ui.create({
         type = ui.TYPE.Image,
         props = {
            resource = input[key] == true and CHECK_TEXTURE_ON or CHECK_TEXTURE_OFF,
            size = util.vector2(CHECKBOX_SIZE, CHECKBOX_SIZE),
         },
      })

      local labelDefault = {
         color = labelText.layout.props.textColor,
         alpha = labelText.layout.props.alpha or 1.0,
      }
      local checkDefault = {
         color = util.color.rgb(1.0, 1.0, 1.0),
         alpha = 1.0,
      }

      local textPalette = (args.colorful == true) and COLORFUL_TEXT_STATES or MORROWIND_TEXT_STATES
      local checkPalette = (args.colorful == true) and COLORFUL_CHECK_STATES or MORROWIND_CHECK_STATES
      local textStates = unpackStates(textPalette, labelDefault)
      local checkStates = unpackStates(checkPalette, checkDefault)

      updateTextColor(restingState(textStates, input[key] == true), labelText)
      updateImageColor(restingState(checkStates, input[key] == true), checkMark)

      local checkboxBox = {
         template = I.MWUI.templates.box,
         props = {
            size = util.vector2(CHECKBOX_SIZE, CHECKBOX_SIZE),
         },
         content = ui.content({
            {
               template = I.MWUI.templates.padding,
               content = ui.content({
                  {
                     template = I.MWUI.templates.padding,
                     content = ui.content({ checkMark })
                  }
               }),
            }
         }),
      }

      body.content:add(padding)
      body.content:add({
         type = ui.TYPE.Flex,
         props = {
            horizontal = true,
            propagateEvents = false,
            autoSize = true,
            arrange = ui.ALIGNMENT.Center,
         },
         content = ui.content({
            labelText,
            interval,
            interval,
            interval,
            checkboxBox,
         }),
         events = {
            mouseClick = async:callback(function()
               ambient.playSound('menu click', {})
            end),
            mousePress = async:callback(function()
               buttonHeld = true
               updateTextColor(interactedState(textStates, input[key] == true), labelText)
               updateImageColor(interactedState(checkStates, input[key] == true), checkMark)
            end),
            mouseRelease = async:callback(function()
               input[key] = input[key] == false
               checkMark.layout.props.resource = input[key] == true and CHECK_TEXTURE_ON or CHECK_TEXTURE_OFF
               checkMark:update()
               updateTextColor(hoverState(textStates, input[key] == true), labelText)
               updateImageColor(hoverState(checkStates, input[key] == true), checkMark)
               buttonHeld = false
            end),
            focusGain = async:callback(function()
               if buttonHeld == false then
                  updateTextColor(hoverState(textStates, input[key] == true), labelText)
                  updateImageColor(hoverState(checkStates, input[key] == true), checkMark)
               end
            end),
            focusLoss = async:callback(function()
               if buttonHeld == false then
                  updateTextColor(restingState(textStates, input[key] == true), labelText)
                  updateImageColor(restingState(checkStates, input[key] == true), checkMark)
               end
               set(input)
            end),
         },
      })
   end

   return {
      type = ui.TYPE.Flex,
      content = ui.content({
         body,
      }),
   }
end)
