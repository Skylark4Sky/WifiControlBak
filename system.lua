--- File Name: system.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "rtos"
require "os"
require "ntp"
require "nvm"
require "config"
require "uartTask"
require "mqttMsg"
require "firmware"
require "mqttTask"

local statrsynctime = false
local waitHWSn = false
local DeviceHWSn = nil 
local timeSyncOk = false
local isTimeSyncStart = false
local update_hook = {update = false,version = 0,file_size = 0,send_size = 0}
local update_retry = false
local update_retry_tick = 0

local NetState = uartTask.GISUNLINK_NETMANAGER_IDLE 

function isTimeSyncOk()
    return timeSyncOk
end

function isGetHWSnOk()
    return waitHWSn
end

function GetDeviceHWSn()
    return DeviceHWSn 
end

function sntpCb()
	log.warn("System","TimeSync OK");
	timeSyncOk = true;
	NetState = uartTask.GISUNLINK_NETMANAGER_TIME_SUCCEED
	uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
end

function subNetState()
	sys.subscribe("NET_STATUS_IND",         
	function ()
		log.warn("System","NET_STATUS_IND ---------------> NET_STATUS_IND")
	end)    

	sys.subscribe("NET_STATE_REGISTERED",         
	function ()
		if mqttTask.isReady() == false then 
			NetState = uartTask.GISUNLINK_NETMANAGER_GSM_CONNECTED 
			uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
		end
		if statrsynctime == false then
			statrsynctime = true;
			ntp.setServers({"ntp.yidianting.xin","cn.ntp.org.cn","hk.ntp.org.cn","tw.ntp.org.cn"}) --设置时间同步
			ntp.timeSync(24,sntpCb)
		end	
		--log.warn("System","NET_STATE_REGISTERED ---------------> GSM 网络发生变化 注册成功")
	end)    

	sys.subscribe("NET_STATE_UNREGISTER",         
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_GSM_DISCONNECTED
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
		--log.warn("System","NET_STATE_UNREGISTER ---------------> GSM 网络发生变化 未注册成功")
		--
	end)    

	sys.subscribe("GISUNLINK_NETMANAGER_CONNECTED_SER",         
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_CONNECTED_SER 
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
		--log.warn("System","NET_STATE_UNREGISTER ---------------> 已连上平台")
		--
	end)    

	sys.subscribe("GISUNLINK_NETMANAGER_DISCONNECTED_SER",         
	function ()
		NetState = uartTask.GISUNLINK_NETMANAGER_DISCONNECTED_SER
		uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
		--log.warn("System","NET_STATE_UNREGISTER ---------------> 已断开平台")
		--
	end)    

	sys.subscribe("GSM_SIGNAL_REPORT_IND",         
	function (success, rssi)
		if rssi >= 2 or rssi <= 30 then
			uartTask.sendData(uartTask.GISUNLINK_NETWORK_RSSI,(rssi * 2) - 113);
		else
			if mqttTask.isReady() == false then
				NetState = uartTask.GISUNLINK_NETMANAGER_CONNECTING
				uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
			else 
				uartTask.sendData(uartTask.GISUNLINK_NETWORK_RSSI,(rssi * 2) - 113);
			end
		end
	end)    
end

local function firmware_query(firmware) 
	--GISUNLINK_NEED_UPGRADE = 0x00,   GISUNLINK_NO_NEED_UPGRADE = 0x01,    GISUNLINK_DEVICE_TIMEOUT = 0x02
	local ret = uartTask.GISUNLINK_DEVICE_TIMEOUT
	if not firmware or firmware == nil then return ret end
	local rawData = {}

	--插入版本号
	table.insert(rawData,bit.band(firmware.ver,255))
	table.insert(rawData,bit.band(bit.rshift(firmware.ver,8),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.ver,16),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.ver,24),255))

	--插入文件大小
	table.insert(rawData,bit.band(firmware.size,255))
	table.insert(rawData,bit.band(bit.rshift(firmware.size,8),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.size,16),255))
	table.insert(rawData,bit.band(bit.rshift(firmware.size,24),255))

	local md5 = firmware.md5
	if md5 and #md5 > 0 then 
		local index = 1
		while index <= #md5 do											--分解数据
			table.insert(rawData,string.byte(md5,index))
			index = index + 1
		end
	end

	local uartData = string.char(unpack(rawData))
	if not uartData or uartData == nil then return ret end


	local send_num = 0;
	while true do 
		log.error("firmware_query","send firmware_ver:"..firmware.ver,"md5:"..firmware.md5,"size:"..firmware.size)
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_INFO,uartData,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			if result.data ~= nil and #result.data then 
				local bytes = uartTask.getBytes(result.data,1)
				local status = bytes[1]
				ret = uartTask.GISUNLINK_NO_NEED_UPGRADE
				if status == uartTask.GISUNLINK_NEED_UPGRADE then 
					ret = uartTask.GISUNLINK_NEED_UPGRADE
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

	--如果下位机返回设备超时需要置重试标志位
	if ret == uartTask.GISUNLINK_DEVICE_TIMEOUT then 
		update_retry = true
	else
		update_retry = false
	end

	update_retry_tick = 0;
	
	log.error("firmware_query",update_retry)

	return ret
end

local function firmware_transfer(offset,data) 
	local send_succeed = false
	if not offset then return send_succeed end
	if not data or #data == 0 then return send_succeed end

	local rawData = {}

	--插入偏移量
	table.insert(rawData,bit.band(offset,255))
	table.insert(rawData,bit.band(bit.rshift(offset,8),255))

	--插入数据长度
	table.insert(rawData,bit.band(#data,255))
	table.insert(rawData,bit.band(bit.rshift(#data,8),255))

	if data and #data > 0 then 
		local index = 1
		while index <= #data do											--分解数据
			table.insert(rawData,string.byte(data,index))
			index = index + 1
		end
	end

	local uartData = string.char(unpack(rawData))
	if not uartData or uartData == nil then return send_succeed end

	local send_num = 0;
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
	local ret = uartTask.GISUNLINK_DEVICE_TIMEOUT
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

function uartTransferCb(exec)
	if not exec or exec == nil then return end
	if exec.cbfunparam then 
		local packet = exec.cbfunparam

		local time = os.time()
		local clock = os.clock()
		local integer,remainder = math.modf(clock);
		remainder = tonumber(string.format("%.6f", remainder)) * 1000000
		local pid = ((time%100000)*10000) + remainder 
		local successString = false
		if exec.send == uartTask.GISUNLINK_SEND_SUCCEED then 
			successString = true
		end
		local jsonTable =
		{
			id = pid, 
			act = packet.act,
			behavior = packet.behavior,
			data = {
				req_id = packet.id,
				success = successString,
				msg = exec.reason
			},
		}
		mqttMsg.sendMsg("/point_switch_resp",json.encode(jsonTable),0)
	end
end

function mqttRecvMsg(packet)
	if not packet or packet == nil then return end
	if packet.act == "transfer" then --正常传输命令
		if update_hook.update == true then  
			local time = os.time()
			local clock = os.clock()
			local integer,remainder = math.modf(clock);
			remainder = tonumber(string.format("%.6f", remainder)) * 1000000
			local pid = ((time%10000)*100000) + remainder 
			local jsonTable =
			{
				id = pid, 
				act = packet.act,
				behavior = packet.behavior,
				data = {
					req_id = packet.id,
					success = false,
					msg = "system upgrade! ver:"..update_hook.version.." file_size:"..update_hook.file_size.." progress_size:"..update_hook.send_size
				},
			}
			mqttMsg.sendMsg("/point_switch_resp",json.encode(jsonTable),0)
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
	elseif packet.act == "update_ver" then --升级命令
		firmware.download_new_firmware(packet.data)
	end
end

function uartRecvMsg(packet)
	if not packet or packet == nil then return end
--	local clientID = "gsl_"..misc.getImei()
	--这里上传stm32发来的透传数据
	if packet.cmd == uartTask.GISUNLINK_TASK_CONTROL then 
		local data = packet.data
		if not data or #data > 0 then
			--log.error("uartRecvMsg:","data:",data:toHex(" "))
			local behavior = string.byte(data,1) 
			local mqtt_ack = string.byte(data,2) 
			local time = os.time()
			local clock = os.clock()
			local integer,remainder = math.modf(clock);
			remainder = tonumber(string.format("%.6f", remainder)) * 1000000
			local pid = ((time%100000)*10000) + remainder 
			local base64str = ""
			if #data > 3 then
				local enc_data = string.sub(data,3,-1)
				base64str = crypto.base64_encode(enc_data,#enc_data)
			end

			local jsonTable =
			{
				id = pid, 
				act = "transfer",
				behavior = behavior,
				data = base64str,
				ctime = time, 
			}

			local jsonString = json.encode(jsonTable)
--			local topic = "/power_run/"..clientID
			if mqtt_ack == uartTask.MQTT_PUBLISH_NEEDACK then
--				mqttMsg.sendMsg("/power_run/"..clientID,jsonString,2,pid)
				mqttMsg.sendMsg("/power_run",jsonString,2,pid)
			else
				mqttMsg.sendMsg("/power_run",jsonString,0)
--				mqttMsg.sendMsg("/power_run/"..clientID,jsonString,0)
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

function wait_hw_sn() 
	while true do 
		log.error("waiting the device sn")
		local result = uartTask.sendData(uartTask.GISUNLINK_HW_SN,nil,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			if result.data ~= nil and #result.data == 12 then 
				local bytes = uartTask.getBytes(result.data,12)
				DeviceHWSn = string.format("%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12])
				log.error("device sn:"..DeviceHWSn)
				break
			end
		else 
			log.error("waiting the device sn:","send failed reason:"..result.reason)
		end
	end
end

function system_loop()
	while true do	
		if waitHWSn == false then 
			--等设备串号
			wait_hw_sn()
			waitHWSn = true
		end
		if statrsynctime == true then 
			if ntp.isEnd() then
			
				--如果update_retry == true的时候，说明下位正再忙。。需要隔断时间尝试下发升级
				if update_retry == true then 
					update_retry_tick = update_retry_tick + 1
					if update_retry_tick >= 60 then 											
						update_retry_tick = 0;
						log.error("retry send firmware",update_retry_tick);
						--发送升级信号
						firmware.system_start_signal()
					end
				end
				log.warn("system","rssi:"..(net.getRssi() * 2) - 113 ,"heap_size:"..rtos.get_fs_free_size(),"Time:"..os.time(),"update_retry:",update_retry,"retry_tick"..update_retry_tick);
			else
				NetState = uartTask.GISUNLINK_NETMANAGER_TIME_FAILED
				uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,NetState);
				log.warn("system","rssi:",(net.getRssi() * 2) - 113,"heap_size:",rtos.get_fs_free_size());
			end
		else
			log.warn("system","rssi:",(net.getRssi() * 2) - 113,"heap_size:",rtos.get_fs_free_size());
		end
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

firmware.updateCb(update_hook) --升级回调

sys.taskInit(system_loop)
