--- File Name: mqttTask.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "misc"
require "http"
require "mqtt"
require "system"
require "mqttOutMsg"
require "mqttInMsg"
require "firmware"

local ready = false

--- MQTT连接是否处于激活状态
-- @return 激活状态返回true，非激活状态返回false
-- @usage mqttTask.isReady()
function isReady()
    return ready
end

local function procRespond(jsonstring)
	local respond = {}
    local json,result,err = json.decode(jsonstring)
	log.info("procRespond:",jsonstring)
    if result and type(json) == "table" then
		if json["code"] then respond.code = json["code"] else log.error("procRespond","code") return nil end
		if json["data"] then respond.info = json["data"] else log.error("procRespond","data") return nil end

		if not respond.info["mqtt_host"] and not respond.info["mqtt_port"] then log.error("procRespond","data->sub") return nil end
		if not respond.info["username"] and not respond.info["password"] then log.error("procRespond","data->sub") return nil end

		return respond 
    end
	return nil
end

function getMqttSrvInfo()
	local server = nil 
	local Version = system.GetFirmwareVersion()
	local DeviceHWSn = system.GetDeviceHWSn()
	local requestConut = 0
	local errorString = "noError"
	local clientID = "gsl_"..misc.getImei()
	local bodyData = "{\"flag_number\":\""..clientID.."\",\"version\":\""..Version.."\",\"device_sn\":\""..DeviceHWSn.."\",\"ICCID\":\""..sim.getIccid().."\",\"IMEI\":\""..sim.getImsi().."\"}"		
	log.error("getMqttSrvInfo:","PostData:"..bodyData)
	
	while true do		
		sys.publish("GISUNLINK_NETMANAGER_CONNECTING")
		local urlHost = "http://power.fuxiangjf.com/device/mqtt_connect_info?"..clientID.."&timeStamp"..os.time().."&requestCount="..requestConut.."&errorString="..errorString
		http.request("POST",urlHost,nil,nil,bodyData,35000,
	    function (respond,statusCode,head,body)
			sys.publish("GET_SRV_INFO_OF",respond,statusCode,body)
		end)

		local _,result,statusCode,body = sys.waitUntil("GET_SRV_INFO_OF")

		if result and statusCode == "200" then
			server = procRespond(body)
			if server ~= nil and server.code == 20000 then
				requestConut = 0
				errorString = "noError"
				break;
			else
				errorString = "jsonError"
			end 
		else
			errorString = "statusCode"..statusCode
		end
		requestConut = requestConut + 1
		sys.wait(10000);
	end

	log.error("getMqttSrvInfo:","code:"..server.code.." host:"..server.info["mqtt_host"].." port:"..server.info["mqtt_port"].." user:"..server.info["username"].." password:"..server.info["password"])
	return server.info;
end

function RegistereDevice()
	local server = nil 
	local Version = system.GetFirmwareVersion()
	local DeviceHWSn = system.GetDeviceHWSn()

	local token = crypto.aes_encrypt("CBC","ZERO",misc.getImei(),"78hrey23y28ogs89","1234567890123456")
	local heads = {}
	
	heads["User-Agent"] = "gisunLink_iot"
	heads["Content-Type"] = "application/json"
	
	local bodyData = "{\"type\":1,\"deviceNo\":\""..DeviceHWSn.."\",\"token\":\""..string.toHex(token).."\",\"version\":\""..Version.."\"}"		
	while true do		
		local urlHost = "http://iot.gisunlink.com/api/device?clientID="..misc.getImei().."&module_version=".._G.PROJECT.."_".._G.VERSION
		log.error("RegistereDevice:","URL"..urlHost)
		log.error("RegistereDevice:","PostData:"..bodyData)
		http.request("POST",urlHost,nil,heads,bodyData,15000,
	    function (respond,statusCode,head,body)
			sys.publish("REG_IOT_SRV",respond,statusCode,body)
		end)

		local _,result,statusCode,body = sys.waitUntil("REG_IOT_SRV")

		if result and statusCode == "200" then
			--if server ~= nil and server.code == 20000 then
			--	requestConut = 0
			--	errorString = "noError"
				break;
			--end 
		end
		sys.wait(1000);
	end
end

local function ConnectToSrv()
	--阻塞式获取mqtt服务器信息
	local mqtt_server = getMqttSrvInfo()
	local clientID = "gsl_"..misc.getImei()
	--创建一个MQTT客户端
	local mqttClient = mqtt.client(clientID,300,mqtt_server["username"],mqtt_server["password"],0)
	--阻塞执行MQTT CONNECT动作，直至成功
	log.error("Begin connect MQTT Srv:",mqtt_server["mqtt_host"],"Port:",mqtt_server["mqtt_port"])
	if mqttClient:connect(mqtt_server["mqtt_host"],mqtt_server["mqtt_port"],"tcp") then
		retryConnectCnt = 0				
		ready = true
		RegistereDevice()
		--每次连接成功后给固件升级部分一个信号
		firmware.system_start_signal()
		sys.publish("GISUNLINK_NETMANAGER_CONNECTED_SER")
		log.error("GISUNLINK_NETMANAGER_CONNECTED_SER")		
		--订阅主题
		if mqttClient:subscribe({["/point_common"]=0, ["/point_common/"..system.GetDeviceHWSn()]=0, ["/point_switch/"..system.GetDeviceHWSn()]=0}) then			
			--循环处理接收和发送的数据
			while true do
				if not mqttInMsg.proc(mqttClient) then log.error("mqttTask.mqttInMsg.proc error") break end
				if not mqttOutMsg.proc(mqttClient,system.GetDeviceHWSn()) then log.error("mqttTask.mqttOutMsg proc error") break end
			end
			mqttOutMsg.unInit()
		end
		sys.publish("GISUNLINK_NETMANAGER_DISCONNECTED_SER")
		log.error("GISUNLINK_NETMANAGER_DISCONNECTED_SER")			
		ready = false
	end
	--断开MQTT连接
	mqttClient:disconnect()
end

--启动MQTT客户端任务
sys.taskInit(
function()
	local retryConnectCnt = 0

	while system.isSimRegistered() do
		sys.wait(500);
	end

	while system.isGetHWSnOk() == false do
		sys.wait(500);
	end

	while true do

		if not socket.isReady() then
			--等待网络环境准备就绪，超时时间是5分钟
			retryConnectCnt = 0
			sys.waitUntil("IP_READY_IND",300000)
		end

		if socket.isReady() then
			sys.publish("GISUNLINK_NETMANAGER_START")
			sys.wait(1000);
			
			ConnectToSrv()
			sys.wait(3000)	
			retryConnectCnt = retryConnectCnt + 1

			if retryConnectCnt >= 5 then 
				link.shut() 
				retryConnectCnt = 0 
			else
				--重连
				sys.publish("GISUNLINK_NETMANAGER_RECONNECTING")				
				sys.wait(3000)				
			end	
		else
			sys.publish("GISUNLINK_NETMANAGER_DISCONNECTED")			
			--进入飞行模式，10秒之后，退出飞行模式
			net.switchFly(true)
			sys.wait(10000)
			net.switchFly(false)
		end
	end
end
)
