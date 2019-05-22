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

local timeSyncOk = false
local isTimeSyncStart = false
local update_hook = {update = false,version = 0,file_size = 0,send_size = 0}

function isTimeSyncOk()
    return timeSyncOk
end

function sntpCb()
	log.warn("System","TimeSync OK");
	timeSyncOk = true;
end

function subNetState()
	sys.subscribe("NET_STATUS_IND",         
		function ()
			log.warn("System","NET_STATUS_IND ---------------> NET_STATUS_IND")
		end)    

	sys.subscribe("NET_STATE_REGISTERED",         
		function ()
			uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,3);
			--log.warn("System","NET_STATE_REGISTERED ---------------> GSM 网络发生变化 注册成功")
		end)    

	sys.subscribe("NET_STATE_UNREGISTER",         
		function ()
			uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,4);
			--log.warn("System","NET_STATE_UNREGISTER ---------------> GSM 网络发生变化 未注册成功")
			--
		end)    

	sys.subscribe("GSM_SIGNAL_REPORT_IND",         
		function (success, rssi)
			if rssi == 0 then
				uartTask.sendData(uartTask.GISUNLINK_NETWORK_STATUS,2);
			else
				uartTask.sendData(uartTask.GISUNLINK_NETWORK_RSSI,rssi);
			end
		end)    
end

local function firmware_query(firmware) 
	--GISUNLINK_NEED_UPGRADE = 0x00,   GISUNLINK_NO_NEED_UPGRADE = 0x01,    GISUNLINK_DEVICE_TIMEOUT = 0x02
	local ret = 0x02
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
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_INFO,uartData,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			send_succeed = true
			ret = 0x00
			break
		else 
			send_num = send_num + 1
			log.error("firmware_query","send failed reason:"..result.reason,"retry:"..send_num)
		end
		if send_num == 5 then
			break
		end
	end
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
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_TRANS,uartData,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			send_succeed = true
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
	local device_ready = false
	log.error("firmware_chk:","waiting the device check the firmware")
	local send_num = 0;
	while true do 
		local result = uartTask.sendData(uartTask.GISUNLINK_DEV_FW_READY,nil,true)
		if result and result.send == uartTask.GISUNLINK_SEND_SUCCEED then
			device_ready = true
			break
		else 
			send_num = send_num + 1
			log.error("firmware_chk","send failed reason:"..result.reason,"retry:"..send_num)
		end
		if send_num == 5 then
			break
		end
	end
	return device_ready
end

function uartTransferCb(exec)
	if not exec or exec == nil then return end
	if exec.cbfunparam then 
		local packet = exec.cbfunparam
		local id = os.time()
		local successString = false
		if exec.send == uartTask.GISUNLINK_SEND_SUCCEED then 
			successString = true
		end
		local jsonTable =
		{
			id = id, 
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
			local id = os.time()
			local jsonTable =
			{
				id = id, 
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
		local uartData = string.char(packet.behavior,string.byte(data,1,string.len(data)))
		log.error("mqttRecvMsg:",uartData:toHex(" "))
		uartTask.sendData(uartTask.GISUNLINK_TASK_CONTROL,uartData,true,uartTransferCb,packet);
	elseif packet.act == "update_ver" then --升级命令
		firmware.download_new_firmware(packet.data)
	end
end

function uartRecvMsg(packet)
	if not packet or packet == nil then return end
	local clientID = "gsl_"..misc.getImei()
	--这里上传stm32发来的透传数据
	if packet.cmd == uartTask.GISUNLINK_TASK_CONTROL then 
		local data = packet.data
		if not data or #data > 0 then
			log.error("uartRecvMsg:","data:",data:toHex(" "))
			local behavior = string.byte(data,1) 
			local time = os.time()
			local clock = os.clock()
			local integer,remainder = math.modf(clock);
			remainder = tonumber(string.format("%.3f", remainder)) * 1000
			local base64str = ""
			if #data > 2 then
				local enc_data = string.sub(data,2,-1)
				base64str = crypto.base64_encode(enc_data,#enc_data)
			end

			local jsonTable =
			{
				id = tonumber(time..remainder), 
				act = "transfer",
				behavior = behavior,
				data = base64str,
				ctime = time, 
			}

			local jsonString = json.encode(jsonTable)
			local topic = "/power_run/"..clientID
			log.error("uartRecvMsg:","Topic:"..topic," jsonString:"..jsonString)
			mqttMsg.sendMsg("/power_run/"..clientID,jsonString,0)
		end
	else
		--		log.error("uartRecvMsg:","PacketID:",packet.id,"DIR:",packet.dir,"CMD:",packet.cmd,"DATA:",packet.data:toHex(" "));
	end
end

function system_loop()
	while true do	
		if ntp.isEnd() then
			log.warn("system","rssi:",net.getRssi(),"heap_size:",rtos.get_fs_free_size(),"Time:",os.time());
		else
			log.warn("system","rssi:",net.getRssi(),"heap_size:",rtos.get_fs_free_size());
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
ntp.setServers({"cn.ntp.org.cn","hk.ntp.org.cn","tw.ntp.org.cn"}) --设置时间同步
ntp.timeSync(24,sntpCb)

update_hook.query = firmware_query 
update_hook.transfer = firmware_transfer
update_hook.check = firmware_chk

firmware.updateCb(update_hook) --升级回调
--sys.timerLoopStart(System_loop,1000)
sys.taskInit(system_loop)
