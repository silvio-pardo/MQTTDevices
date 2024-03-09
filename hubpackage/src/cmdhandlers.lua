local log = require "log"
local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local json = require "dkjson"
local subs = require "subscriptions"
local tools = require("mqtt.tools")

local function handle_refresh(driver, device, command)
  log.info ('Refresh requested')
  if device.device_network_id:find(connectorNetworkId, 1, 'plaintext') then
    creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
    init_mqtt(device)
  else
    local subscribed, id, topic = subs.mqtt_check_is_subscribed(device)
    if subscribed then
      log.info ('Refresh status device requested, request updated data from zigbee2mqtt')
      subs.get_last_status_device(device)
    else
      subs.mqtt_subscribe(device)
    end
  end
end

local function create_device(driver, dtype)

  if dtype then

    local PROFILE = typemeta[dtype].profile
    if PROFILE then
    
      local MFG_NAME = 'SmartThings Community'
      local MODEL = 'mqtttdev_' .. dtype
      local LABEL = 'MQTT ' .. dtype
      local ID = 'MQTT_' .. dtype .. '_' .. tostring(socket.gettime())

      log.info (string.format('Creating new device: label=<%s>, id=<%s>', LABEL, ID))
      if clearcreatemsg_timer then
        driver:cancel_timer(clearcreatemsg_timer)
      end

      local create_device_msg = {
                                  type = "LAN",
                                  device_network_id = ID,
                                  label = LABEL,
                                  profile = PROFILE,
                                  manufacturer = MFG_NAME,
                                  model = MODEL,
                                  vendor_provided_label = LABEL,
                                }

      assert (driver:try_create_device(create_device_msg), "failed to create device")
    end
  end
end

local function handle_createdevice(driver, device, command)

  log.debug("Device type selection: ", command.args.value)

  device:emit_event(cap_createdev.deviceType('Creating device...'))

  create_device(driver, command.args.value)

end

local function handle_switch(driver, device, command)

  log.info ('Switch triggered:', command.command)
  
  device:emit_event(capabilities.switch.switch(command.command))

  local dtype = device.device_network_id:match('MQTT_(.+)_+')
  if (dtype == 'Switch' or dtype == 'Dimmer' or dtype == 'DimmerTempVariable') and device.preferences.publish == true then
      
    local cmdmap = {
                      ['on'] = device.preferences.switchon,
                      ['off'] = device.preferences.switchoff
                   }
    if dtype == 'Dimmer' or dtype == 'DimmerTempVariable' then
      if device.preferences.swformat == 'json' then
        subs.publish_message(device, tostring('{ "'.. device.preferences.swjsonelement ..'":"'..cmdmap[command.command]..'"}'), device.preferences.pubswtopic)
      else
        subs.publish_message(device, cmdmap[command.command], device.preferences.pubswtopic)
      end
    else
      subs.publish_message(device, cmdmap[command.command])
    end

  end
end

local function handle_button(driver, device, command)

  log.info ('Button pressed:', command.command)
  
  device:emit_event(capabilities.button.button.pushed({state_change = true}))
  
  if device.preferences.publish == true then

    subs.publish_message(device, device.preferences.butpush)
      
  end
end

local function handle_alarm(driver, device, command)

  log.info ('Alarm triggered:', command.command)
  
  device:emit_event(capabilities.alarm.alarm(command.command))

  if device.preferences.publish == true then
    
    local payload
    
    local cmdmap = {
                      ['off'] = device.preferences.alarmoff,
                      ['siren'] = device.preferences.alarmsiren,
                      ['strobe'] = device.preferences.alarmstrobe,
                      ['both'] = device.preferences.alarmboth,
                   }

    subs.publish_message(device, cmdmap[command.command])

  end
end

local function handle_dimmer(driver, device, command)
  log.info ('Dimmer value changed to ', command.args.level)

  local dimmerlevel = command.args.level

  device:emit_event(capabilities.switchLevel.level(dimmerlevel))

  if device:supports_capability_by_id('switch') then
    if dimmerlevel > 0 then
      device:emit_event(capabilities.switch.switch('on'))
    else
      device:emit_event(capabilities.switch.switch('off'))
    end
  end

  if device.preferences.publish == true then
    if device.preferences.dimmermax then
      dimmerlevel = math.floor(math.abs((dimmerlevel * device.preferences.dimmermax) / 100))
    end
    log.info ('Dimmmer value calculated ', command.args.level)

    if device.preferences.format == 'json' then
      subs.publish_message(device, tostring('{ "'.. device.preferences.jsonelement ..'":"'..dimmerlevel..'"}'))
    else
      subs.publish_message(device, tostring(dimmerlevel))
    end
  end
end

local function handle_color_temp(driver, device, command)
  log.info ('Color Temp value changed to ', command.args.temperature)
  local valueTemperature = command.args.temperature

  device:emit_event(capabilities.colorTemperature.colorTemperature(valueTemperature))

  percentageTemp = math.floor(math.abs((valueTemperature / 30000) * 100))
  log.info ('color temperature percentage value:', percentageTemp)
  convertedValue = math.floor(math.abs((percentageTemp * device.preferences.temperaturemax) / 100)) + device.preferences.temperaturemin
  log.info ('color temperature converted value:', convertedValue)

  if device.preferences.publish == true then
    log.info ('send color temperature change...')
    if device.preferences.formatTemp == 'json' then
      subs.publish_message(device, tostring('{ "'.. device.preferences.tempjsonelement ..'":"'..convertedValue..'"}'))
    else
      subs.publish_message(device, tostring(convertedValue))
    end
  end
end

local function handle_fanspeed(driver, device, command)

  log.info ('Fan speed value changed to ', command.args.speed)
  
  device:emit_event(capabilities.fanSpeed.fanSpeed(command.args.speed))
  
  local minspeed, maxspeed = device.preferences.fanspeedrange:match('^(%d+)-(%d+)$')

  minspeed = tonumber(minspeed)
  maxspeed = tonumber(maxspeed)
  
  if (type(minspeed) == 'number') and (type(maxspeed) == 'number') then
  
    local pubspeedmap = { 
                          [0] = minspeed,
                          [1] = math.floor(maxspeed * .33),
                          [2] = math.floor(maxspeed * .50),
                          [3] = math.floor(maxspeed * .66),
                          [4] = maxspeed
                        }
  
    if device.preferences.publish == true then

      subs.publish_message(device, tostring(pubspeedmap[command.args.speed]))
      
    end
  else
    log.warn ('Invalid fan speed range configured:', device.preferences.fanspeedrange)
  end
end

local function handle_lock(driver, device, command)

  log.info ('Lock command received: ', command.command)
  
  local attrmap = { ['lock']   = 'locked',
                    ['unlock'] = 'unlocked'
                  }
  
  device:emit_event(capabilities.lock.lock(attrmap[command.command]))
  
  if device.preferences.publish == true then
    local cmdmap
    if device.preferences.locklock then
      cmdmap = {
                  ['lock'] = device.preferences.locklock,
                  ['unlock'] = device.preferences.lockunlock
               }
    else
      cmdmap = {
                  ['lock'] = device.preferences.locklocked,
                  ['unlock'] = device.preferences.lockunlocked
               }
    end

    subs.publish_message(device, cmdmap[command.command])
    
  end

end

local function handle_volume(driver, device, command)
  if command.args.volume < device.preferences.threshold then
    device:emit_event(capabilities.soundSensor.sound('not detected'))
  else
    device:emit_event(capabilities.soundSensor.sound('detected'))
  end
end

local function handle_tempset(driver, device, command)

  local tempunit = 'C'
  if device.preferences.dtempunit == 'fahrenheit' then
    tempunit = 'F'
  end
  
  device:emit_event(capabilities.temperatureMeasurement.temperature({value=command.args.temp, unit=tempunit}))
  device:emit_event(capabilities.setHeatingSetpoint.heatingSetpoint({value=command.args.temp, unit=tempunit}))
  
  if device.preferences.publish == true then
    subs.publish_message(device, tostring(command.args.temp))
  end

end

local function handle_humidityset(driver, device, command)

  device:emit_event(capabilities.relativeHumidityMeasurement.humidity(command.args.humidity))
  
  if device.preferences.publish == true then
    subs.publish_message(device, tostring(command.args.humidity))
  end

end

local function disptable(table, tab, maxlevels, currlevel)

	if not currlevel then; currlevel = 0; end
  currlevel = currlevel + 1
  for key, value in pairs(table) do
    if type(key) ~= 'table' then
      log.debug (tab .. '  ' .. key, value)
    else
      log.debug (tab .. '  ', key, value)
    end
    if (type(value) == 'table') and (currlevel < maxlevels) then
      disptable(value, '  ' .. tab, maxlevels, currlevel)
    end
  end
end

local function handle_custompublish(driver, device, command)

  --disptable(command, '  ', 8)

  log.debug (string.format('%s command Received; topic = %s; msg = %s; qos = %d (%s)', command.command, command.args.topic, command.args.message, command.args.qos, type(command.args.qos)))

  subs.publish_message(device, command.args.message, command.args.topic, command.args.qos)

end

local function handle_setnumeric(driver, device, command)

  if command.command == 'setNumber' then
    device:emit_event(cap_numfield.numberval(command.args.numberval))
  
    if device.preferences.publish == true then
      
      local sendmsg
      if device.preferences.format == 'json' then
        local msgobj = {}
      
        msgobj[device.preferences.jsonelement] = command.args.numberval
        msgobj[device.preferences.unitkey] = device.state_cache.main[cap_unitfield.ID].unittext.value
        
        sendmsg = json.encode(msgobj, { indent = false })
      
      else
        sendmsg = tostring(command.args.numberval) .. ' ' .. device.state_cache.main[cap_unitfield.ID].unittext.value
      
      end

      subs.publish_message(device, sendmsg)
    end
  
  elseif command.command == 'setUnit' then
    device:emit_event(cap_unitfield.unittext(command.args.unittext))

  end
end

local function handle_shade(driver, device, command)

  local cmdmap =  { 
                    ['open'] = {['attribute'] = 'open', ['pubval'] = device.preferences.shadeopen},
                    ['close'] = {['attribute'] = 'closed', ['pubval'] = device.preferences.shadeclose},
                    ['pause'] = {['attribute'] = 'partially open', ['pubval'] = device.preferences.shadepause},
                    ['setShadeLevel'] = {['attribute'] = command.args.shadeLevel, ['pubval'] = ''},
                  }

  if command.command == 'setShadeLevel' then
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(cmdmap[command.command].attribute))
    cmdmap['setShadeLevel'].pubval = tostring(command.args.shadeLevel)
    if command.args.shadeLevel == 0 then
      device:emit_event(capabilities.windowShade.windowShade('closed'))
    elseif command.args.shadeLevel == 100 then
      device:emit_event(capabilities.windowShade.windowShade('open'))
    else
      device:emit_event(capabilities.windowShade.windowShade('partially open'))
    end
    
  else
    device:emit_event(capabilities.windowShade.windowShade(cmdmap[command.command].attribute))
    if cmdmap[command.command].attribute == 'open' then
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(100))
    elseif cmdmap[command.command].attribute == 'closed' then
      device:emit_event(capabilities.windowShadeLevel.shadeLevel(0))
    end
  end
  
  if device.preferences.publish then
    subs.publish_message(device, cmdmap[command.command].pubval)
  end

end

local function handle_robot(driver, device, command)

  log.debug ('Robot cleaner command/mode:', command.command, command.args.mode)
  
  if command.command == 'setRobotCleanerCleaningMode' then
    device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode(command.args.mode))
    
    if command.args.mode == 'stop' then
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('idle'))
      if device.preferences.publish then
        subs.publish_message(device, device.preferences.robotstop)
      end
    elseif command.args.mode == 'auto' then
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('cleaning'))
      if device.preferences.publish then
        subs.publish_message(device, device.preferences.robotstart)
      end
    
    end
  
  elseif command.command == 'setRobotCleanerMovement' then
    if command.args.mode ~= 'charging' then
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement(command.args.mode))
    else
      device:emit_event(capabilities.robotCleanerMovement.robotCleanerMovement('homing'))
    end
    
    if command.args.mode == 'idle' then
      device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('manual'))
      if device.preferences.publish then
        subs.publish_message(device, device.preferences.robotpause)
      end
      
    elseif command.args.mode == 'cleaning' then
      device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('auto'))
      if device.preferences.publish then
        subs.publish_message(device, device.preferences.robotstart)
      end
    
    elseif (command.args.mode == 'charging') or (command.args.mode == 'homing') then
      device:emit_event(capabilities.robotCleanerCleaningMode.robotCleanerCleaningMode('manual'))
      if device.preferences.publish then
        subs.publish_message(device, device.preferences.robothome)
      end
    end
  end
  
end

--unused function
local function handle_reset_energy(driver, device, command)

  log.info ('Energy Meter History Reset')
  device:emit_event(capabilities.energyMeter.energy({value = 0, unit = "kWh" }))

end
local function handle_setenergy(driver, device, command)

  log.info (string.format('Energy value set to %s', command.args.energyval))
  device:emit_event(cap_setenergy.energyval({value = command.args.energyval, unit = device.preferences.eunitsset}))
  device:emit_event(capabilities.energyMeter.energy({value = command.args.energyval, unit=device.preferences.eunitsset}))

  if device.preferences.epublish == true then
    subs.publish_message(device, tostring(command.args.energyval), device.preferences.epubtopic)
  end

end
local function handle_setpower(driver, device, command)

  log.info (string.format('Power value set to %s', command.args.powerval))

  local disp_multiplier = 1
  if device.preferences.punitsset == 'mwatts' then
    disp_multiplier = .001
  elseif device.preferences.punitsset == 'kwatts' then
    disp_multiplier = 1000
  end
  device:emit_event(cap_setpower.powerval(command.args.powerval * disp_multiplier))
  device:emit_event(capabilities.powerMeter.power(command.args.powerval * disp_multiplier))

  if device.preferences.ppublish == true then
    subs.publish_message(device, tostring(command.args.powerval), device.preferences.ppubtopic)
  end

end
--end unused

return  {
          handle_refresh = handle_refresh,
          handle_createdevice = handle_createdevice,
          handle_switch = handle_switch,
          handle_button = handle_button,
          handle_alarm = handle_alarm,
          handle_dimmer = handle_dimmer,
          handle_lock = handle_lock,
          handle_volume = handle_volume,
          handle_tempset = handle_tempset,
          handle_humidityset = handle_humidityset,
          handle_custompublish = handle_custompublish,
          handle_setnumeric = handle_setnumeric,
          handle_shade = handle_shade,
          handle_robot = handle_robot,
          handle_fanspeed = handle_fanspeed,
          handle_color_temp = handle_color_temp
}