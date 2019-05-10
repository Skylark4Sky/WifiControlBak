--- File Name: mqttMsg.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "utils"
require "sys"
require "mqttOutMsg"

local Queue = {} --发送队列
local callback = {}

function regRecv(cbfun)
	if cbfun then 
		callback = cbfun 
	end
end

function insertQueue(topic,payload)
	local item = {}
	item.topic = topic
	item.payload = payload
	table.insert(Queue, item)
	sys.publish("mqttMsgQueue_working")
end

function sendMsg(topic,payload,qos,user) 
	mqttOutMsg.insertMsg(topic,payload,qos,user)
end

local function procMsg(topic,payload)
	local packet = {}
    local json,result,err = json.decode(payload)
    if result and type(json) == "table" then
		packet.topic = topic
		if json["id"] then packet.id = json["id"] else log.error("procMsg","id error") return nil end
		if json["act"] then packet.act = json["act"] else log.error("procMsg","act error") return nil end
		if json["data"] then packet.data = json["data"] else log.error("procMsg","data error") return nil end
		if packet.act == "transfer" then
			if json["behavior"] then packet.behavior = json["behavior"] else log.error("procMsg","behavior error") return nil end
		end
		return packet
    end
	return nil
end

local function QueueProc() 
	local result,data
	while true do	
		result, data = sys.waitUntil("mqttMsgQueue_working", 5000) 
		if result == true then 
			if #Queue > 0 then
				local item = table.remove(Queue, 1)
				if item and item.topic and item.payload then
					local packet = procMsg(item.topic,item.payload)
					if packet and callback then 
						callback(packet)
					end
				end
			end
		end
	end
end

sys.taskInit(QueueProc)
