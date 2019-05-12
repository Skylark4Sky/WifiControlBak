--- File Name: uartTask.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "utils"
require "pm"
require "bit"

--[[
帧结构如下：
AA 0B 00 3A 42 02 00 00 07 CC 6F FF BB
包头  GISUNLINK_PACKET_HEAD   0XAA
包尾  GISUNLINK_PACKET_TAIL   0XBB

GISUNLINK_RECV_HEAD,
GISUNLINK_RECV_LEN,
GISUNLINK_RECV_FLOW,
GISUNLINK_RECV_DIR,
GISUNLINK_RECV_CMD,
GISUNLINK_RECV_DATA,
GISUNLINK_RECV_CHECK_SUM,
GISUNLINK_RECV_TAIL,

local GISUNLINK_PACKET_HEAD_SIZE         = 1
local GISUNLINK_PACKET_LEN_SIZE          = 2
local GISUNLINK_PACKET_FLOW_SIZE         = 4
local GISUNLINK_PACKET_DIR_SIZE          = 1
local GISUNLINK_PACKET_CMD_SIZE          = 1
local GISUNLINK_PACKET_CHKSUM_SIZE       = 2
local GISUNLINK_PACKET_TAIL_SIZE         = 1

local GISUNLINK_PACKET_HEAD_TAIL_SIZE    = 2

]]

--串口ID,1对应uart1
local UART_ID = 1
--
--网络当前状态
GISUNLINK_NETWORK_STATUS = 0x05						
--重设置网络链接 (仅仅针对wifi模块)
GISUNLINK_NETWORK_RESET = 0x06						
--网络信号强度
GISUNLINK_NETWORK_RSSI = 0x07				            
--设备固件版本查询
GISUNLINK_DEV_FW_VER = 0x08					        
--设置固件升级版本
GISUNLINK_DEV_FW_INFO = 0x09						    
--固件数据传输
GISUNLINK_DEV_FW_TRANS = 0x0A							
--请求固件升级
GISUNLINK_DEV_FW_UPGRADE = 0x0B						
--网络数据透传
GISUNLINK_TASK_CONTROL = 0x0C							
--发送成功
GISUNLINK_SEND_SUCCEED = true
--发送超时
GISUNLINK_SEND_FAILED = false
--串口读到的数据缓冲区
local rdbuf = ""
--发送队列
local sendQueue = {} 
--确认队列
local ackQueue = {} 
--等待回复队列
local waitQueue = {} 
--接收队列
local recvQueue = {} 
--全局ID
local packet_id = 0

local MaxDataLen = 512
--GISUNLINK_PACKET_HEAD_TAIL_SIZE + GISUNLINK_PACKET_LEN_SIZE + GISUNLINK_PACKET_FLOW_SIZE + GISUNLINK_PACKET_DIR_SIZE + GISUNLINK_PACKET_CMD_SIZE + GISUNLINK_PACKET_CHKSUM_SIZE
local MinDataLen = 12 

local RecvCallback = nil

function regRecv(cbfun) 
	if cbfun then 
		RecvCallback = cbfun 
	end
end

local function getBytes(data,len)
	if not data or string.len(data) < len then return end
	local index = 1
	local bytes = {}

	while index <= len do											--分解数据
		bytes[index] = string.byte(data,index)
		index = index + 1
	end
	return bytes
end

local function parse_packet_uint8(data) 
	if not data or string.len(data) < 1 then return end
	local bytes = getBytes(data,1)
	return bytes[1],string.sub(data,2,-1) --当前域长度为1 所以从第2个字节开始返回
end

local function parse_packet_uint16(data) 
	if not data or string.len(data) < 2 then return end
	local bytes = getBytes(data,2)
	local value = bytes[1] + bit.lshift(bytes[2],8)
	return value,string.sub(data,3,-1)  --当前域长度为2 所以从第3个字节开始返回
end

local function parse_packet_uint32(data) 
	if not data or string.len(data) < 4 then return end
	local bytes = getBytes(data,4)
	local value = bytes[1] + bit.lshift(bytes[2],8) + bit.lshift(bytes[3],16) + bit.lshift(bytes[4],24)
	return value,string.sub(data,5,-1) --当前域长度为4 所以从第5个字节开始返回
end

local function parse_packet_char(data,len) 
	if not data or string.len(data) < len then return end
	local string = string.sub(data,1,len) 
	return string,string.sub(data,len + 1,-1)
end

local function parse_packet_crc(data) 
	local check_sum = 0;
	local data_len = string.len(data);
	local index = 1;
	while index <= data_len do 
		check_sum = check_sum + string.byte(data,index)
		index = index + 1
	end
	while bit.rshift(check_sum,16) > 0 do
		check_sum = bit.rshift(check_sum,16)  + bit.band(check_sum,65535)
	end
	return bit.band(bit.bnot(check_sum),65535)
end

local function checkPackeeCmd(cmd)
	if cmd == GISUNLINK_NETWORK_STATUS then return true end 
	if cmd == GISUNLINK_NETWORK_RESET then return true end 
	if cmd == GISUNLINK_NETWORK_RSSI then return true end 
	if cmd == GISUNLINK_DEV_FW_VER then return true end 
	if cmd == GISUNLINK_DEV_FW_INFO then return true end 
	if cmd == GISUNLINK_DEV_FW_TRANS then return true end 
	if cmd == GISUNLINK_DEV_FW_UPGRADE then return true end 
	if cmd == GISUNLINK_TASK_CONTROL then return true end 
	return false
end

local function createRawData(id,cmd,data,dir) 
	if not cmd then return false,"" end
	local rawData = {}
	local rawData_len = MinDataLen - 2

	if type(data) == "number" then 
		rawData_len = MinDataLen - 2 + 1;
	elseif type(data) == "string" then 
		rawData_len = MinDataLen - 2 + string.len(data);
	end

	if rawData_len > MaxDataLen then return false,"" end 

	--包长度
	table.insert(rawData,bit.band(rawData_len,255))
	table.insert(rawData,bit.band(bit.rshift(rawData_len,8),255))

	--包ID
	table.insert(rawData,bit.band(id,255))
	table.insert(rawData,bit.band(bit.rshift(id,8),255))
	table.insert(rawData,bit.band(bit.rshift(id,16),255))
	table.insert(rawData,bit.band(bit.rshift(id,24),255))

	-- 方向
	if not dir then 
		table.insert(rawData,0x00)
	else 
		table.insert(rawData,0x01)
	end

	--命令
	table.insert(rawData,cmd)

	--数据
	if type(data) == "number" then 
		table.insert(rawData,bit.band(data,255))
	elseif type(data) == "string" then 
		if data and string.len(data) then 
			local index = 1
			while index <= string.len(data) do											--分解数据
				table.insert(rawData,string.byte(data,index))
				index = index + 1
			end
		end
	end

	--CRC
	local crc_string = string.char(unpack(rawData))
	local crc_value = parse_packet_crc(crc_string)

	table.insert(rawData,bit.band(crc_value,255))
	table.insert(rawData,bit.band(bit.rshift(crc_value,8),255))

	--包头
	table.insert(rawData,1,0xAA)
	--包尾
	table.insert(rawData,0xBB)
	local uartData = string.char(unpack(rawData))
	return true,uartData
end

local function insertQueue(Queue,item,note) 
	table.insert(Queue, item)
	sys.publish(note)
end

--[[
函数名：sendData
功能  ：通过串口发送数据
参数  ：
cmd：命令
data：数据
async:是否异步
cbfun:回调函数
返回值：无
]]
function sendData(cmd,data,async,cbfun,cbfunparam)
	local o = {}
	if not cmd or not data then return end
	packet_id = packet_id + 1;
	local result,raw = createRawData(packet_id,cmd,data)
	if result == false then return end

	o.id = packet_id
	o.cmd = cmd
	o.retry = 3
	o.raw = raw
	o.data = data 
	o.async = async or false
	o.cbfun = cbfun or nil
	o.cbfunparam = cbfunparam or nil

	if not async and not cbfun then
	--	log.error("sendData","no ack Queue------------->")
		insertQueue(sendQueue,o,"uartSendQueue_working")
	else
		insertQueue(ackQueue,o,"uartAckQueue_working")
		--实时等待回复
		if not cbfun then
			local waitString = "wait"..o.id
	--		log.error("sendData","sync wait------------->",waitString)
			--最大等待5秒
			local result, data = sys.waitUntil(waitString,5000)
			if result then 
				return data
			else
				local res = {}
				res.send = GISUNLINK_SEND_FAILED
				res.reason = "send to device TimeOut"
				return res
			end
		else -- 异步等待回复
	--		log.error("sendData","async wait------------->")
			--不处理了
		end
	end
end

local function getFrame(data) 
	--没数据返回
	if not data then return end														 
	--识别数据帧头
	local Head = string.find(data,string.char(0xAA))				
	--未识别到帧头返回
	if not Head then return false,"" end											
	--从头部开始取数据
	local frameData = string.sub(data,Head,-1);										
	--检查是否满足最小帧要求
	if #frameData < MinDataLen then return false,frameData end			
	--识别数据包长度
	local packetLenString = string.sub(frameData,2,3)
	--整包长度需要加帧头帧尾的长度
	local packetLen = parse_packet_uint16(packetLenString) + 2
	--如果整包数据大于512 返回处理 
	if packetLen > MaxDataLen then return false,"" end
	--如处理的整包数据大于帧长度 从帧头开始返回
	if packetLen > #frameData then return false,frameData end
	--检查数据帧尾
	local frame = string.sub(frameData,Head,packetLen)
	local TAIL = string.find(frame,string.char(0xBB), -1)
	--找到帧尾 
	if TAIL and TAIL == packetLen then 
	--	log.error("getFrame:","insertData:"..#data);
		insertQueue(recvQueue,frame,"uartRecvQueue_working")
	else 
		log.error("getFrame","packetLen:",packetLen,"FrameLen:",#frameData)
		log.error("getFrame","not find the tail Data:"..frameData:toHex(" "))
	end

	if #frameData > packetLen then 
		local retString = string.sub(frameData,packetLen + 1,-1)
	--	log.error("getFrame","retString:"..retString:toHex(" "))
		return true,retString
	end
	return true,""
end

--[[
函数名：proc
功能  ：处理从串口读到的数据
参数  ：
data：当前一次从串口读到的数据
返回值：无
]]
local function proc(data)
	if not data or string.len(data) == 0 then return end
	--追加到缓冲区
	rdbuf = rdbuf..data    

	local result,unproc
	unproc = rdbuf
	--根据帧结构循环解析未处理过的数据
	while true do
		result,unproc = getFrame(unproc)
		if not unproc or unproc == "" or not result then
--			log.error("proc:over")
			break
		end
	end
	rdbuf = unproc or ""
end

--[[
函数名：read
功能  ：读取串口接收到的数据
参数  ：无
返回值：无
]]
local function read()
	local data = ""
	--底层core中，串口收到数据时：
	--如果接收缓冲区为空，则会以中断方式通知Lua脚本收到了新数据；
	--如果接收缓冲器不为空，则不会通知Lua脚本
	--所以Lua脚本中收到中断读串口数据时，每次都要把接收缓冲区中的数据全部读出，这样才能保证底层core中的新数据中断上来，此read函数中的while语句中就保证了这一点
	while true do        
		data = uart.read(UART_ID,"*l",0) --
		if not data or string.len(data) == 0 then break end
		proc(data)
	end
end

local function writeOk()
	--	log.info("Uart.writeOk")
end

local function parseFrame(frame) 
--	log.error("parseFrame","Data:"..frame:toHex(" "))
	if not frame then return end														--没数据返回 
	--识别数据帧头
	local Head = string.find(frame,string.char(0xAA))									
	--识别数据帧尾巴
	local TAIL = string.find(frame,string.char(0xBB), -1)
	--未识别到帧头返回
	if not Head then return end											
	--未识别到帧尾返回
	if not TAIL then return end											

	local packet = {}
	local next_fields = string.sub(frame,2,-1)

	--识别包长度
	packet.len,next_fields = parse_packet_uint16(next_fields)
	--识别包ID
	packet.id,next_fields = parse_packet_uint32(next_fields)					
	--识别包方向
	packet.dir,next_fields = parse_packet_uint8(next_fields)					
	--识别包命令
	packet.cmd,next_fields = parse_packet_uint8(next_fields)					

	if checkPackeeCmd(packet.cmd) == false then
		log.error("CMD:",packet.cmd," unknown")
		return
	end

	--识别包数据
	packet.data,next_fields = parse_packet_char(next_fields,#frame - MinDataLen)	
	--获取校验码
	packet.crc,next_fields = parse_packet_uint16(next_fields)
	--计算校验码
	local calc_crc = parse_packet_crc(string.sub(frame,2,#frame-3))	
	if packet.crc == calc_crc then 
		return packet
	else 
		log.error("parseUartData:","PacketID:"..packet_id.." crc false")
		return 
	end

	return 
end

local function sendAckPacket(packet)
	if not packet or packet == nil then return end
	local result,raw = createRawData(packet.id,packet.cmd,nil,0x01)
	if result == false then return end

	local o = {}
	o.id = packet.id
	o.cmd = packet.cmd 
	o.retry = 3
	o.raw = raw
	--log.error("sendAckPacket","Data:"..raw:toHex(" "))
	insertQueue(sendQueue,o,"uartSendQueue_working")
end

local function recvQueueProc()
	while true do	
		sys.waitUntil("uartRecvQueue_working", 5000) 
		if #recvQueue > 0 then
			local packet = parseFrame(table.remove(recvQueue, 1))
			if packet and packet.dir == 0x00 then 
				if RecvCallback and RecvCallback ~= nil then
					--回复请求包ACK
					sendAckPacket(packet)
					RecvCallback(packet)
				end
				
				if packet.cmd == GISUNLINK_TASK_CONTROL then 
			--		log.error("recvQueue:"..packet.data:toHex(" "))
				end
			elseif packet and packet.dir == 0x01 then
				log.error("recvQueueProc:","PacketID:"..packet.id)
				for k, v in ipairs(waitQueue) do 
					local waitPacket = v
					if waitPacket.id == packet.id and waitPacket.wb_del == false then
						waitPacket.wb_del = true

						local curTime = os.clock()
						local result = {}
						result.send = GISUNLINK_SEND_SUCCEED
						result.reason = "send to device succeed"
						result.data = packet.data
						result.startTime = waitPacket.startTime
						result.endTime = curTime 

						if waitPacket.cbfun then
							if waitPacket.cbfunparam then 
								result.cbfunparam = waitPacket.cbfunparam
							end
							waitPacket.cbfun(result)
						else
							local waitString = "wait"..waitPacket.id
							sys.publish(waitString,result)
						end
					elseif waitPacket.id == packet.id then 
						log.error("recvQueueProc:","PacketID:",waitPacket.id,"wb_del:",waitPacket.wb_del);
					end
				end
			end
		end
	end
end

local function sendQueueProc()
	while true do	
		sys.waitUntil("uartSendQueue_working", 5000) 
		if #sendQueue > 0 then
			local packet = table.remove(sendQueue, 1)
--			if packet.retry >= 2 then
				--log.error("sendQueueProc","PacketID:",packet.id,"CMD:",packet.cmd,"DATA:",packet.data,"RAW:",packet.raw:toHex(" "))
				--log.error("sendQueueProc","PacketID:",packet.id,"CMD:",packet.cmd)
--			end
			uart.write(UART_ID,packet.raw)
		end
	end
end

local function ackQueueProc()
	while true do	
		sys.waitUntil("uartAckQueue_working", 5000) 
		if #ackQueue > 0 then
			local packet = table.remove(ackQueue, 1)
			if packet then 
				if packet.retry > 0 then 
					packet.retry = packet.retry - 1
					packet.startTime = os.clock()
					insertQueue(sendQueue,packet,"uartSendQueue_working")
				end
				packet.wb_del = false
				--插入等待管理队列
				insertQueue(waitQueue,packet,"uartWaitQueue_working")
			end
		end
	end
end

local function waitQueueOpt(Queue,key,value,hash_del) 
	if not Queue and not key and not value then return end
	local packet = value
	if packet and type(packet) == "table" then 
		local curTime = os.clock()
		local diff_value = 200 --实际为0.2 乘1000为了消除工具提示错误
		if ((curTime - packet.startTime) * 1000) >= diff_value and packet.wb_del == false then  
			--如果重试次数未用完则再次发一次数据
			if packet.retry > 0 then 
				packet.retry = packet.retry - 1
				packet.startTime = os.clock()
				insertQueue(sendQueue,packet,"uartSendQueue_working")
			else
				local result = {}
				result.send = GISUNLINK_SEND_FAILED
				result.reason = "send to device TimeOut"
				result.startTime = packet.time
				result.endTime = curTime 
				if packet.cbfun then
					if packet.cbfunparam then 
						result.cbfunparam = packet.cbfunparam
					end
					--执行回调函数
					packet.cbfun(result)
				else 
					local waitString = "wait"..packet.id
					sys.publish(waitString,result)
				end
				packet.wb_del = true
				packet.endTime = curTime;
				table.insert(hash_del,packet.id)
			end
		end
	end
end

local function clearWbDelWaitQueueItem(Queue)
	for i=#Queue, 1 , -1 do
		local packet = Queue[i]
		if packet.wb_del == true then
--			log.error("clearWbDelWaitQueueItem","Del item PacketID:",packet.id)
			table.remove(Queue, i)
		end
	end
end

local function waitQueueProc()
	while true do	
		sys.waitUntil("uartWaitQueue_working", 100) 
		if #waitQueue > 0 then
			local hash_del = {};
			for k, v in ipairs(waitQueue) do 
				waitQueueOpt(waitQueue,k,v,hash_del)
			end
			--删除无用元素
			clearWbDelWaitQueueItem(waitQueue)
		end
	end
end

sys.taskInit(recvQueueProc)
sys.taskInit(sendQueueProc)
sys.taskInit(ackQueueProc)
sys.taskInit(waitQueueProc)

--保持系统处于唤醒状态，此处只是为了测试需要，所以此模块没有地方调用pm.sleep("testUart")休眠，不会进入低功耗休眠状态
--在开发“要求功耗低”的项目时，一定要想办法保证pm.wake("testUart")后，在不需要串口时调用pm.sleep("testUart")
pm.wake("Uart")
--注册串口的数据接收函数，串口收到数据后，会以中断方式，调用read接口读取数据
uart.on(UART_ID,"receive",read)
--注册串口的数据发送通知函数
uart.on(UART_ID,"sent",writeOk)

--配置并且打开串口
--uart.setup(UART_ID,9600,8,uart.PAR_NONE,uart.STOP_1)
--如果需要打开“串口发送数据完成后，通过异步消息通知”的功能，则使用下面的这行setup，注释掉上面的一行setup
uart.setup(UART_ID,9600,8,uart.PAR_NONE,uart.STOP_1,nil,1)
