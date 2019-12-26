--- File Name: system.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "misc"
require "rtos"
require "os"
require "ntp"
require "nvm"
require "config"
require "uartTask"
require "mqttMsg"
require "firmware"
require "mqttTask"

local waitHWSn = false
local DeviceHWSn = "gsl_"..misc.getImei() 
local waitFirmwareVersion = false
local FirmwareVersion = "unkown"

local statrsynctime = false
local update_retry = false

local update_retry_tick = 0
local update_hook = {update = false,version = 0,file_size = 0,send_size = 0}

local sim_registered = false
local NetState = uartTask.GISUNLINK_NETMANAGER_IDLE 
local TopicString = "/device_state/"..DeviceHWSn

function isSimRegistered() 
	return sim_registered
end

function isGetHWSnOk()
    return waitHWSn
end

function GetDeviceHWSn()
    return DeviceHWSn 
end

function GetFirmwareVersion()
    return FirmwareVersion 
end

function sntpOKCb()
	log.warn("System","TimeSync OK");
end

function subNetState()
	sys.subscribe("NET_STATUS_IND",         
	function ()
		log.warn("System","NET_STATUS_IND ---------------> NET_STATUS_IND")
	end)

	sys.subscribe("NET_STATE_REGISTERED",         
	function ()
		sim_registered = true
		NetState = uartTask.GISUNLINK_NETMANAGER_GSM_CONNECTED 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);	
	end)    

	sys.subscribe("NET_STATE_UNREGISTER",         
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_GSM_DISCONNECTED
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)    

	sys.subscribe("GISUNLINK_NETMANAGER_START",
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_START 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)

	sys.subscribe("GISUNLINK_NETMANAGER_CONNECTING",
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_CONNECTING 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)

	sys.subscribe("GISUNLINK_NETMANAGER_RECONNECTING",
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_RECONNECTING 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)
	
	sys.subscribe("GISUNLINK_NETMANAGER_DISCONNECTED",
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_DISCONNECTED 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)	

	sys.subscribe("GISUNLINK_NETMANAGER_CONNECTED_SER",         
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_CONNECTED_SER 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)    

	sys.subscribe("GISUNLINK_NETMANAGER_DISCONNECTED_SER",         
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_DISCONNECTED_SER
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
	end)    

	sys.subscribe("GSM_SIGNAL_REPORT_IND",         
	function (success, rssi)
		if rssi >= 2 or rssi <= 30 then
			uartTask.sendData(uartTask.GISUNLINK_NETWORK_RSSI,(rssi * 2) - 113);
		end
	end)    
end

local function getMSGID()
	local time = os.time()
	local clock = os.clock()
	local integer,remainder = math.modf(clock);
	remainder = tonumber(string.format("%.6f", remainder)) * 1000000
	return ((time%100000)*10000) + remainder 
end

local function postFirmwareUptdateState(behavior,msg) 
	local jsonTable = {
		id = getMSGID(), 
		act = "firmware_update",
		behavior = behavior,
		data = {			
			msg = msg
		},
		ctime = os.time(), 
	}	
	mqttMsg.sendMsg(TopicString,json.encode(jsonTable),0)
end

local function createQueryRawData(firmware) 

	local rawData = {}
	if not firmware or firmware == nil then return rawData end

	table.insert(rawData,bit.band(firmware.ver,255))
	table.insert(rawData,bit.band(bit.rshift(firmware.ver,8),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.ver,16),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.ver,24),255))

	table.insert(rawData,bit.band(firmware.size,255))
	table.insert(rawData,bit.band(bit.rshift(firmware.size,8),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.size,16),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.size,24),255))

	local md5 = firmware.md5
	if md5 and #md5 > 0 then 
		local index = 1
		while index <= #md5 do											
			table.insert(rawData,string.byte(md5,index))
			index = index + 1
		end
	end

	return rawData
end

local function firmware_query(firmware) 
	local send_num = 0;
	local ret = uartTask.GISUNLINK_TRANSFER_FAILED
	local uartData = string.char(unpack(createQueryRawData(firmware)))

	if not firmware or firmware == nil then return ret end
	if not uartData or uartData == nil then return ret end

	while true do 
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_INFO,uartData,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			if result.data ~= nil and #result.data then 
				local bytes = uartTask.getBytes(result.data,1)
				local status = bytes[1]
				ret = uartTask.GISUNLINK_DEVICE_TIMEOUT
				if status == uartTask.GISUNLINK_NEED_UPGRADE then 
					ret = uartTask.GISUNLINK_NEED_UPGRADE
				elseif status == uartTask.GISUNLINK_NO_NEED_UPGRADE then 
					ret = uartTask.GISUNLINK_NO_NEED_UPGRADE
				end
			end
			break
		else 
			send_num = send_num + 1
			log.error("firmware_query","send failed reason:"..result.reason,"retry:"..send_num)
		end
		if send_num == 5 then
			break
		end
	end

	if ret == uartTask.GISUNLINK_DEVICE_TIMEOUT then 
		update_retry_tick = 0;
		update_retry = true
	else
		update_retry = false
	end

	log.error("firmware_query",update_retry)

	return ret
end

local function createTransferRawData(offset, data) 
	local rawData = {}

	table.insert(rawData,bit.band(offset,255))
	table.insert(rawData,bit.band(bit.rshift(offset,8),255))

	table.insert(rawData,bit.band(#data,255))
	table.insert(rawData,bit.band(bit.rshift(#data,8),255))

	if data and #data > 0 then 
		local index = 1
		while index <= #data do											
			table.insert(rawData,string.byte(data,index))
			index = index + 1
		end
	end

	return rawData
end

local function firmware_transfer(offset,data) 
	local send_num = 0;
	local send_succeed = false
	local uartData = string.char(unpack(createTransferRawData(offset,data)))

	if not offset then return send_succeed end
	if not data or #data == 0 then return send_succeed end
	if not uartData or uartData == nil then return send_succeed end

	while true do 
		log.error("firmware_transfer","send firmware_transfer offset:"..offset.." len:"..#data)
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_TRANS,uartData,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			if result.data ~= nil and #result.data == 2 then 
				local bytes = uartTask.getBytes(result.data,2)
				local respond_offset = bytes[1] + bit.lshift(bytes[2],8)
				if respond_offset == offset then 
					send_succeed = true
				end
			end
			break
		else 
			send_num = send_num + 1
			log.error("firmware_transfer","send failed reason:"..result.reason,"retry:"..send_num)
		end
		if send_num == 5 then
			break
		end
	end
	return send_succeed 
end

local function firmware_chk()
	local ret = uartTask.GISUNLINK_TRANSFER_FAILED
	local send_num = 0;

	while true do 
		log.error("firmware_chk:","waiting the device check the firmware")
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_READY,nil,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			if result.data ~= nil and #result.data then 
				local bytes = uartTask.getBytes(result.data,1)
				local status = bytes[1]
				ret = uartTask.GISUNLINK_FIRMWARE_CHK_NO_OK
				if status == uartTask.GISUNLINK_FIRMWARE_CHK_OK then 
					ret = uartTask.GISUNLINK_FIRMWARE_CHK_OK
				end
			end
			break
		else 
			send_num = send_num + 1
			log.error("firmware_chk","send failed reason:"..result.reason,"retry:"..send_num)
		end
		if send_num == 5 then
			break
		end
	end
	return ret
end

local function uartTransferCb(exec)
	if not exec or exec == nil then return end
	if exec.cbfunparam then 
		local packet = exec.cbfunparam
		local successString = false
		if exec.send == uartTask.GISUNLINK_SEND_SUCCEED then 
			successString = true
		end
		local jsonTable =
		{
			id = getMSGID(), 
			act = GISUNLINK_UART_TRANSFER_RESULT,
			behavior = GISUNLINK_DEFAULT_BEHAVIOR,
			data = {
				req_id = packet.id,
				success = successString,
				msg = exec.reason
			},
			ctime = os.time(), 
		}
		mqttMsg.sendMsg(TopicString,json.encode(jsonTable),0)
	end
end

local function mqttRecvMsg(packet)
	if not packet or packet == nil then return end
	if packet.act == "transfer" then 
		if update_hook.update == true then  

			local jsonTable =
			{
				id = getMSGID(), 
				act = GISUNLINK_UART_TRANSFER_RESULT,
				behavior = GISUNLINK_DEFAULT_BEHAVIOR,
				data = {
					req_id = packet.id,
					success = false,
					msg = "system busy!"
				},
				ctime = os.time(), 
			}
			mqttMsg.sendMsg(TopicString,json.encode(jsonTable),0)
			return;
		end
		local data = crypto.base64_decode(packet.data,string.len(packet.data))

		if not data or #data <= 0 then
			local exec = {};
			exec.cbfunparam = packet;
			exec.send = uartTask.GISUNLINK_SEND_FAILED; 
			exec.reason = "decode data failed";
			uartTransferCb(exec);
		else
			local uartData = string.char(packet.behavior,string.byte(data,1,string.len(data)))
			uartTask.sendData(uartTask.GISUNLINK_TASK_CONTROL,uartData,true,uartTransferCb,packet);
		end
	elseif packet.act == "update_ver" then 
		firmware.download_new_firmware(packet.data)
	elseif packet.act == "device_info" and packet.behavior == GISUNLINK_GET_DEVICE_INFO then 

		local jsonTable =
		{
			id = getMSGID(), 
			act = "device_info",
			behavior = GISUNLINK_POST_DEVICE_INFO,
			info = {			
				imei = misc.getImei(),
				version = GetFirmwareVersion(),
				device_sn = GetDeviceHWSn(),
				sim = {
					ICCID = sim.getIccid(),
					IMEI = sim.getImsi(),
				},

				cellInfo = {
					ci = net.getCi(),
					Lac = net.getLac(),
					Mnc = net.getMnc(),
					Mcc = net.getMcc(),
					ta = net.getTa(),
					Ext = net.getCellInfoExt(),			
				}
			},
			ctime = os.time(), 
		}	
		mqttMsg.sendMsg(TopicString,json.encode(jsonTable),0)	
	end
end

local function uartRecvMsg(packet)
	if not packet or packet == nil then return end
	if packet.cmd == uartTask.GISUNLINK_TASK_CONTROL then 
		local data = packet.data
		if not data or #data > 0 then
			--log.error("uartRecvMsg:","data:",data:toHex(" "))
			local behavior = string.byte(data,1) 
			local mqtt_ack = string.byte(data,2) 

			local base64str = ""
			if #data > 3 then
				local enc_data = string.sub(data,3,-1)
				base64str = crypto.base64_encode(enc_data,#enc_data)
			end

			local jsonTable =
			{
				id = getMSGID(), 
				act = "transfer",
				behavior = behavior,
				data = base64str,
				ctime = os.time(), 
			}

			local jsonString = json.encode(jsonTable)
			if mqtt_ack == uartTask.MQTT_PUBLISH_NEEDACK then
				mqttMsg.sendMsg(TopicString,jsonString,2,pid)
			else
				mqttMsg.sendMsg(TopicString,jsonString,0)
			end
		end
	else
		if packet.cmd == uartTask.GISUNLINK_NETWORK_STATUS then 
			uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
		elseif packet.cmd == uartTask.GISUNLINK_DEV_SN then
			local DEV_SN = misc.getImei()
			uartTask.sendData(uartTask.GISUNLINK_DEV_SN,DEV_SN);
		end
	end
end

local function GetDeviceHWSnOrFirmwareVersion(action, respond_size, callback)
	local trynum = 0;

	if not action or not callback then 	
		return true
	end

	while true do 
		local result = uartTask.sendData(action,nil,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			if result.data ~= nil and #result.data >= respond_size then 
				if callback then 
					callback(uartTask.getBytes(result.data,respond_size))
				end
				break
			end
		else 
			trynum = trynum + 1		
			log.error("GetDeviceHWSnOrFirmwareVersion:","send failed reason:"..result.reason)
		end

		if trynum >= 5 then
			break;
		end

		sys.wait(200)
	end
	return true;
end

local function system_loop()
	while true do	
		if waitHWSn == false then 
			waitHWSn = GetDeviceHWSnOrFirmwareVersion(uartTask.GISUNLINK_HW_SN,12,function(bytes)				
				DeviceHWSn = ""				
				for index = 1,12 do
					DeviceHWSn = DeviceHWSn..string.format("%02x",bytes[index])
				end					
				TopicString = "/device_state/"..DeviceHWSn
			end)
		end

		if waitFirmwareVersion == false then
			waitFirmwareVersion = GetDeviceHWSnOrFirmwareVersion(uartTask.GISUNLINK_FIRMWARE_VERSION,12,function(bytes)				
				FirmwareVersion = ""				
				for index = 1,12 do
					FirmwareVersion = FirmwareVersion..string.format("%c",bytes[index])
				end					
			end)
		end 	

		if socket.isReady() and statrsynctime == false then
			statrsynctime = true;
			ntp.setServers({"ntp.yidianting.xin","cn.ntp.org.cn","hk.ntp.org.cn","tw.ntp.org.cn"}) 
			ntp.timeSync(24,sntpOKCb)
		end

		if update_retry == true then 
			update_retry_tick = update_retry_tick + 1
			if update_retry_tick >= 60 then 											
				update_retry_tick = 0;
				log.error("retry send firmware",update_retry_tick);
				firmware.system_start_signal()
			end
		end

		log.warn("system","rssi:"..(net.getRssi() * 2) - 113 ,"heap_size:"..rtos.get_fs_free_size(),"Time:"..os.time(),"update_retry:",update_retry,"retry_tick"..update_retry_tick);
		sys.wait(1000);
	end
end

nvm.init("config.lua") --初始化配置
subNetState() --网络状态
-- 注册MQTT消息回调
mqttMsg.regRecv(mqttRecvMsg)
--注册串口回调	
uartTask.regRecv(uartRecvMsg)

update_hook.query = firmware_query 
update_hook.transfer = firmware_transfer
update_hook.check = firmware_chk
update_hook.stateCb = postFirmwareUptdateState 

firmware.updateCb(update_hook) --升级回调

sys.taskInit(system_loop)
