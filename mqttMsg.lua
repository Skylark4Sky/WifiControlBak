--- File Name: mqttMsg.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "utils"
require "sys"
require "mqttTask"
require "mqttOutMsg"

local Queue = {} --发送队列
local WaitAckQueue = {} --等待服务器回复队列
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


function SendRespondCb(result,publish_id)
	local resp_id = publish_id
		for k, v in ipairs(WaitAckQueue) do 
			local waitPacket = v
			if waitPacket.publish_id == resp_id and waitPacket.wb_del == false then
				if result == true then
					waitPacket.wb_del = true
				log.error("SendRespondCb:","PacketID:",waitPacket.publish_id,"wb_del:",waitPacket.wb_del);
				end				
			end
		end   
end

function sendMsg(topic,payload,qos,publish_id,user) 
	if mqttTask.isReady() == false then return end 
	if publish_id and publish_id ~= nil then 
		local item = {}
		item.topic = topic
		item.payload = payload
		item.retry = 2
		item.start_ticks = os.clock() 
		item.timeout_ticks = 12500--5500
		item.publish_id = publish_id
		item.qos = qos
		item.user = user
		item.wb_del = false
		table.insert(WaitAckQueue, item)
		log.error("MqttSendMsg:","publish_id:",publish_id,"Topic:"..topic)
		mqttOutMsg.insertMsg(topic,payload,qos,{cb=SendRespondCb,para=publish_id})
		
	else
		log.error("MqttSendMsg:","Topic:"..topic)	
		mqttOutMsg.insertMsg(topic,payload,qos,user)
	end
	--log.error("MqttSendMsg:","Topic:"..topic," jsonString:"..payload)
end

local function get_resp_id(resp) 
	local resp_id = 0
	if resp["req_id"] then 
		resp_id = resp["req_id"]
		--log.error("get_resp_id:","req_id:",resp_id);
	end
	return resp_id
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
		if packet.act == "resp" then
			local resp_id = get_resp_id(packet.data)
			for k, v in ipairs(WaitAckQueue) do 
				local waitPacket = v
				if waitPacket.publish_id == resp_id and waitPacket.wb_del == false then
					waitPacket.wb_del = true
					log.error("get_resp_id:","req_id:",resp_id);
				elseif waitPacket.publish_id == resp_id then 
					--log.error("WaitAckQueue:","PacketID:",waitPacket.publish_id,"wb_del:",waitPacket.wb_del);
				end
			end
			return nil
		end
		return packet
	end
	return nil
end

local function QueueProc() 
	local result,data
	while true do	
		result, data = sys.waitUntil("mqttMsgQueue_working", 2500) 
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

local function waitAckQueueOpt(Queue,key,value,hash_del) 
	if not Queue and not key and not value then return end
	local packet = value
	if packet and type(packet) == "table" then 
		local curTime = os.clock()
		if ((curTime - packet.start_ticks) * 1000) >= packet.timeout_ticks and packet.wb_del == false then  
			--如果重试次数未用完则再次发一次数据
			if packet.retry > 0 then 
				log.error("waitAckQueueOpt:","PacketID:",packet.publish_id,"start_ticks:",packet.start_ticks,"curTime:",curTime,"retry:",packet.retry);
				packet.retry = packet.retry - 1
				packet.start_ticks = os.clock() 
				packet.timeout_ticks = 5500--8500
				--mqttOutMsg.insertMsg(packet.topic,packet.payload,packet.qos,packet.user)
				mqttOutMsg.insertMsg(packet.topic,packet.payload,packet.qos,packet.user)
			else
				packet.wb_del = true
				--	table.insert(hash_del,packet.publish_id)
			end
		end
	end
end

local function clearWbDelWaitQueueItem(Queue)
	if not Queue then log.error("clearWbDelWaitQueueItem:","empty") return end
	for i=#Queue, 1 , -1 do
		local packet = Queue[i]
		if packet.wb_del == true then
			log.error("clearWbDelWaitQueueItem:","PacketID:",packet.publish_id,"wb_del:",packet.wb_del);
			table.remove(Queue, i)
		end
	end
end

local function WaitAckQueueProc() 
	while true do	
		sys.waitUntil("WaitAckQueue_working", 500) 
		if #WaitAckQueue > 0 then
			local hash_del = {};
			for k, v in ipairs(WaitAckQueue) do 
				waitAckQueueOpt(WaitAckQueue,k,v,hash_del)
			end
			--删除无用元素
			clearWbDelWaitQueueItem(WaitAckQueue)
		end
	end
end

sys.taskInit(QueueProc)
sys.taskInit(WaitAckQueueProc)
