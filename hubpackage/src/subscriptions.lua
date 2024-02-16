local log = require "log"

local function build_html(list)

  local html_list = ''

  for _, item in ipairs(list) do
    html_list = html_list .. '<tr><td>' .. item .. '</td></tr>\n'
  end

  local html =  {
                  '<!DOCTYPE html>\n',
                  '<HTML>\n',
                  '<HEAD>\n',
                  '<style>\n',
                  'table, td {\n',
                  '  border: 1px solid black;\n',
                  '  border-collapse: collapse;\n',
                  '  font-size: 12px;\n',
                  '  padding: 3px;\n',
                  '}\n',
                  '</style>\n',
                  '</HEAD>\n',
                  '<BODY>\n',
                  '<table>\n',
                  html_list,
                  '</table>\n',
                  '</BODY>\n',
                  '</HTML>\n'
                }
    
  return (table.concat(html))
end

local function determine_devices(targettopic)
  local targetlist = {}
  local devicelist = thisDriver:get_devices()

  for id, topic in pairs(SUBSCRIBED_TOPICS) do
    if topic == targettopic then

      for _, device in ipairs(devicelist) do

        if device.id == id then
          table.insert(targetlist, device)

        end
      end
    end
  end
  return targetlist
end

local function publish_message(device, payload, opt_topic, opt_qos)

    if client and (client_reset_inprogress==false) and payload then

        local pubtopic = opt_topic or device.preferences.pubtopic
        local pubqos = opt_qos or device.preferences.qos:match('qos(%d)$')

        assert(client:publish{
            topic = pubtopic,
            payload = payload,
            qos = tonumber(pubqos)
        })

        log.debug (string.format('Message "%s" published to topic %s with qos=%d', payload, pubtopic, tonumber(pubqos)))

    end

end

local function get_last_status_device(device)
    if device.device_network_id:find('Master', 1, 'plaintext') then
        log.info ('Unsupported Refresh action')
    else
        log.info('refresh normal device - request status refresh')
        if (device.preferences.getter) then
            log.info('device with getter enabled')
            if (device.preferences.getterFormat == 'json') or (device.preferences.getterFormat == nil) then
                log.info('getter json mode')
                publish_message(device, tostring('{ "'.. device.preferences.getterJsonElement ..'":""}'), device.preferences.getterTopic)
            else
                log.info('unsupported refresh payload')
            end
        end
    end
end

local function is_subscribed(qtopic)
  for _, topic in pairs(SUBSCRIBED_TOPICS) do
    if topic == qtopic then; return true; end
  end
  return false
end

local function unique_topic_list()
  local list = {}
  for _, topic in pairs(SUBSCRIBED_TOPICS) do
    local alreadyfound=false
    for _, item in ipairs(list) do
      if item == topic then; alreadyfound = true; end
    end
    if not alreadyfound then
      table.insert(list, topic)
    end
  end
  return list

end

local function subscribe_topic(device)
  if is_subscribed(device.preferences.subTopic) then
    log.debug ('Already subscribed to topic', device.preferences.subTopic)
    SUBSCRIBED_TOPICS[device.id] = device.preferences.subTopic
    device:emit_event(cap_status.status('Subscribed'))
    get_last_status_device(device)
  else
    SUBSCRIBED_TOPICS[device.id] = device.preferences.subTopic
    assert(client:subscribe{ topic=device.preferences.subTopic, qos=1, callback=function(suback)
        log.info(string.format("Device <%s> subscribed to %s: %s", device.label, device.preferences.subTopic, suback))
        creator_device:emit_event(cap_topiclist.topiclist(build_html(unique_topic_list())))
        device:emit_event(cap_status.status('Subscribed'))
        --handle request last status from device at mqttclient driver recreation
        get_last_status_device(device)
    end})
  end
end

local function subscribe_all()
  local devicelist = thisDriver:get_devices()
  for _, device in ipairs(devicelist) do
      if not device.device_network_id:find('Master', 1, 'plaintext') then
          if (device.preferences.subTopic ~= 'xxxxx/xxxxx') and (device.preferences.subTopic ~= nil) then
              subscribe_topic(device)
          end
      end
  end
end

local function unsubscribe(id, topic, delete_flag)
  local qty_check_val = 1                                 -- =1 if device changing subscription; =0 if device was deleted
  if delete_flag == true then; qty_check_val = 0; end

  if #determine_devices(topic) == qty_check_val then      -- unsubscribe only if no more devices using this topic

    local rc, err = client:unsubscribe{ topic=topic, callback=function(unsuback)
          log.info("\t\tUnsubscribe callback:", unsuback)
      end}
      
    if rc == false then
      log.debug ('\tUnsubscribe failed with err:', err)
    else
      log.debug (string.format('\tUnsubscribed from %s', topic))
      SUBSCRIBED_TOPICS[id] = nil
      creator_device:emit_event(cap_topiclist.topiclist(build_html(unique_topic_list())))
    end
  else
    log.debug (string.format('Subscription to <%s> still in use by another device', topic))
    SUBSCRIBED_TOPICS[id] = nil
  end
end

local function unsubscribe_all()
  local sublist = SUBSCRIBED_TOPICS

  for id, topic in pairs(sublist) do
    unsubscribe(id, topic)
  end

end

local function get_subscribed_topic(device)
  for id, topic in pairs(SUBSCRIBED_TOPICS) do
    if id == device.id then
      return id, topic
    end
  end
end

local function mqtt_check_is_subscribed(device)
    if client then
        local id, topic = get_subscribed_topic(device)
        if topic then
            return true, id, topic
        end
    end
    return false, nil, nil
end

local function mqtt_subscribe(device)
    if client then
        local subscribed, id, topic = mqtt_check_is_subscribed(device)
        if subscribed then
            log.debug (string.format('Unsubscribing device <%s> from %s', device.label, topic))
            unsubscribe(id, topic)
        end

        subscribe_topic(device)
    else
        log.debug (string.format('Client not running, Restarting Connection...'))
        creator_device:emit_event(cap_createdev.deviceType(' ', { visibility = { displayed = false } }))
        init_mqtt(nil)
    end
end

return	{
          determine_devices = determine_devices,
          subscribe_topic = subscribe_topic,
          subscribe_all = subscribe_all,
          mqtt_subscribe = mqtt_subscribe,
          unsubscribe = unsubscribe,
          unsubscribe_all = unsubscribe_all,
          get_subscribed_topic = get_subscribed_topic,
          get_last_status_device = get_last_status_device,
          publish_message = publish_message,
          mqtt_check_is_subscribed = mqtt_check_is_subscribed
}
