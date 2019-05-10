--- 模块功能：串口功能测试(非TASK版，串口帧有自定义的结构)
-- @author openLuat
-- @module uart.testUartTask
-- @license MIT
-- @copyright openLuat
-- @release 2018.05.24

module(...,package.seeall)

require "rtos"
require "os"
require "ntp"
require "nvm"
require "config"
require "uartTask"
require "mqttMsg"
require "firmware"

local timeSyncOk = false;
local isTimeSyncStart = false;

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

local function firmware_update(firmware_path) 
	local file,err = io.open(firmware_path,"r")
	if file then
		local offset = 0

		--这里先和下位机发送指令沟通

		--沟通完成开始发送数据
		while true do 
			local data = file:read(256)
			if data == nil then
				break	
			end
			--发送数据send data	
			log.error("firmware_update","offset:",offset," data:"..data:toHex(" "))
			offset = offset + 256
		end
		file:close()

		--发送写完数据命令
		--等待
	else
		log.error("firmware_update","open firmware file error:",err)
	end
end

local function getCodeString()
	local String = nvm.get("sn_code")
	local index = 1
	local bytes = {}
	while index <= string.len(String) do											--分解数据
		local byte = string.byte(String,index)
		if byte ~= 0x00 then
			bytes[index] = string.char(byte)
		end
		index = index + 1
	end
	return table.concat(bytes)
end

function uartTransferCb(exec)
	if not exec or exec == nil then return end
	if exec.cbfunparam then 
		local packet = exec.cbfunparam
		local code = getCodeString() 
		local id = os.time()
		local jsonTable =
		{
			id = id, 
			act = packet.act,
			behavior = packet.behavior,
			data = {
					req_id = packet.id,
					code = code,
					success = exec.result,
					msg = exec.reason
				},
		}
		mqttMsg.sendMsg("/point_switch_resp",json.encode(jsonTable),0)
	end
end

function mqttRecvMsg(packet)
	if not packet or packet == nil then return end
	if packet.act == "transfer" then --正常传输命令
		local data = crypto.base64_decode(packet.data,string.len(packet.data))
		if packet.behavior == 0x13 then --需要保存配置
			if string.len(data) >= 32 then 
				local sn_code = string.char(string.byte(data,1,32)) 
				nvm.set("sn_code",sn_code)
			end
		end
		local uartData = string.char(packet.behavior,string.byte(data,1,string.len(data)))
		log.error("mqttRecvMsg:",uartData:toHex(" "))
		uartTask.sendData(uartTask.GISUNLINK_TASK_CONTROL,uartData,true,uartTransferCb,packet);
	elseif packet.act == "update_ver" then --升级命令
		firmware.download_new_firmware(packet.data)
	end
end

function uartRecvMsg(packet)
	if not packet or packet == nil then return end
	if packet.cmd == uartTask.GISUNLINK_TASK_CONTROL then 

		log.error("uartRecvMsg:","PacketID:",packet.id,"DIR:",packet.dir,"CMD:",packet.cmd,"DATA:",packet.data:toHex(" "));
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
firmware.updateCb(firmware_update) --升级回调
--sys.timerLoopStart(System_loop,1000)
sys.taskInit(system_loop)
