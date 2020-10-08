--- File Name: mqttOutMsg.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

require "uartTask"

module(...,package.seeall)

--数据发送的消息队列
local msgQuene = {}

function insertMsg(topic,payload,qos,user)
	table.insert(msgQuene,{t=topic,p=payload,q=qos,user=user})
	sys.publish("APP_SOCKET_SEND_DATA")
end

--- 去初始化“MQTT客户端数据发送”
-- @return 无
-- @usage mqttOutMsg.unInit()
function unInit()
--    sys.timerStop(PubHeartPerMin)
    while #msgQuene > 0 do
        local outMsg = table.remove(msgQuene,1)
        if outMsg.user and outMsg.user.cb then outMsg.user.cb(false,outMsg.user.para) end
    end
end

--- MQTT客户端数据发送处理
-- @param mqttClient，MQTT客户端对象
-- @return 处理成功返回true，处理出错返回false
-- @usage mqttOutMsg.proc(mqttClient)
function proc(mqttClient,topic_flag)
    while #msgQuene>0 do
        local outMsg = table.remove(msgQuene,1)
		local topic = outMsg.t
		if outMsg.t  == "/power_run" then topic = outMsg.t.."/"..topic_flag end
		if outMsg.t  == "/firmware_update" then topic = outMsg.t.."/"..topic_flag end	
		if outMsg.t  == "/device" then topic = outMsg.t.."/"..topic_flag end	
		log.error("MqttSendMsg:","Topic:"..topic.."  Qos:"..outMsg.q)
		
        local result = mqttClient:publish(topic,outMsg.p,outMsg.q)
        if outMsg.user and outMsg.user.cb then outMsg.user.cb(result,outMsg.user.para) end
        if not result then return end
    end
    return true
end

