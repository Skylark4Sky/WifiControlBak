--- 模块功能：MQTT客户端数据接收处理
-- @author openLuat
-- @module mqtt.mqttInMsg
-- @license MIT
-- @copyright openLuat
-- @release 2018.03.28
module(...,package.seeall)

require "uartTask"
require "mqttMsg"
require "mqttOutMsg"

--- MQTT客户端数据接收处理
-- @param mqttClient，MQTT客户端对象
-- @return 处理成功返回true，处理出错返回false
-- @usage mqttInMsg.proc(mqttClient)
function proc(mqttClient)
    local result,data
    while true do
        result,data = mqttClient:receive(2000)
		--uartTask.sendData(1,"aa")
        if result then
			mqttMsg.insertQueue(data.topic,data.payload)
			--log.error("mqttInMsg","payload:",data.payload)
            --如果mqttOutMsg中有等待发送的数据，则立即退出本循环
            if mqttOutMsg.waitForSend() then return true end
        else
            break
        end
    end
	
    return result or data=="timeout"
end
