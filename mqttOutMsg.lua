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
end

local function PubHeartPerMinCb(result)
    log.error("mqttOutMsg.PubHeartPerMinCb",result,"alive","id:gsl_"..misc.getImei().." status:0")--打印心跳信息发送结果
    if result then sys.timerStart(PubHeartPerMin,55000) end	--如果发送正确，重启下一次心跳数据
end

function PubHeartPerMin()
    insertMsg("a","id:gsl_"..misc.getImei().." s:0",1,{cb=PubHeartPerMinCb})--每分钟心跳
end

function FilterRstCb(result)
    log.error("mqttOutMsg.FilterRst",result,"alive")--打印心跳信息发送结果
end

function FilterRst()
	insertMsg("a","id:gsl_"..misc.getImei().." r:1",1,{cb=FilterRstCb})
end	
	
--- 初始化“MQTT客户端数据发送”
-- @return 无
-- @usage mqttOutMsg.init()
function init()
    PubHeartPerMin()
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

--- MQTT客户端是否有数据等待发送
-- @return 有数据等待发送返回true，否则返回false
-- @usage mqttOutMsg.waitForSend()
function waitForSend()
    return #msgQuene > 0
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
        local result = mqttClient:publish(topic,outMsg.p,outMsg.q)
		log.error("MqttSendMsg:","Topic:"..topic.."  Qos:"..outMsg.q)
        if outMsg.user and outMsg.user.cb then outMsg.user.cb(result,outMsg.user.para) end
        if not result then return end
    end
    return true
end

