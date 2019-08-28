--- File Name: firmware.lua
-- System Environment: Darwin Johans-Mac-mini 18.2.0 Darwin Kernel Version 18.2.0: Mon Nov 12 20:24:46 PST 2018; root:xnu-4903.231.4~2/RELEASE_X86_64 x86_64
-- Created Time: 2019-04-28
-- Author: Johan
-- E-mail: Johaness@qq.com
-- Description: 

module(...,package.seeall)

require "rtos"
require "os"
require "io"
require "nvm"
require "http"
require "config"
require "uartTask"

local USER_DIR_PATH = "/gisunlink"
local UPD_FILE_PATH = "/gisunlink/download.bin"
local FW_FILE_PATH = "/gisunlink/firmware.bin"

local download = {}
download.enable = false
download.update_hook = nil

function updateCb(update_hook)
	if not update_hook or update_hook == nil then return end
	download.update_hook = update_hook  
end

function system_start_signal()
	if download.enable == false then
		log.error("system_start_signal","updateFirmware_working");
		sys.publish("updateFirmware_working")
	end
end

function download_new_firmware(firmware)
	if not firmware or type(firmware) ~= "table" then 
		log.error("firmware_update","error firmware data")
		return
	end
	
	if not firmware.url then log.error("download_new_firmware","firmware url error") return end
	if not firmware.md5 then log.error("download_new_firmware","firmware md5 error") return end
	if not firmware.size then log.error("download_new_firmware","firmware size error") return end
	if not firmware.ver then log.error("download_new_firmware","firmware ver error") return end
	if firmware.size <= 0 then log.error("download_new_firmware","firmware size <= 0") return end

	local last_download_task = nvm.get("download_task")
	local download_start = false

	--如果之前没有保存过 则启动下载项目
	if not last_download_task or last_download_task == nil then 
		download_start = true;
	else --否则判断版本信息 
		if last_download_task.md5 ~= firmware.md5 then 
			if firmware.ver >= last_download_task.ver then
				download_start = true;
			else 
				log.error("firmware_update","the last version >= new download_task")
			end
		else
			log.error("firmware_update","the md5 are the smae")
		end
	end

	if download_start == true then 
		local new_download_task = firmware	
		new_download_task.download_over = false
		nvm.set("download_task",new_download_task)
		log.error("firmware_update","has come a new version")
		--只有没开始下载的时候才对download赋值
		if download.enable == false then  
			download.enable = true;
			download.firmware = firmware;
			sys.publish("updateFirmware_working")
		end
	else	
		log.error("download_new_firmware","updateFirmware_not_working")
	end
	return 
end

local function downloadfirmware(firmware)
	local download_path = nil
	if not firmware or not firmware.url or not firmware.md5 then log.error("downloadfirmware","exit download task") return end
	local download_num = 0;
	local fileSize = 0;
	while true do
		os.remove(UPD_FILE_PATH)
		if firmware.size >= rtos.get_fs_free_size() then break end;
		fileSize = 0;
		download_path = nil;
		http.request("GET",firmware.url,nil,nil,nil,60000,function (respond,statusCode,head,filePath) 
			sys.publish("UPDATE_DOWNLOAD",respond,statusCode,head,filePath)
		end,UPD_FILE_PATH)

		local _,result,statusCode,head,filePath = sys.waitUntil("UPDATE_DOWNLOAD")

		if result then 
			if statusCode == "200" then
				fileSize = io.fileSize(UPD_FILE_PATH)
				if fileSize == firmware.size then 
					download_path = UPD_FILE_PATH					
					log.error("firmware_update","download finish")
					break
				else 
					log.error("firmware_update","download error the size not the same","dsize:"..fileSize.."size:"..firmware.size)
				end
			end
		else 
			download_num = download_num + 1
			if download_num == 3 then
				log.error("firmware_update","download_num > 3")
				break
			else
				log.error("downloadfirmware","download retry")
			end
		end
	end
	return download_path,fileSize
end

local function chk_md5(filePath,md5)
	local md5_value = nil;
	local file,err = io.open(filePath,"r")

	if file then  
		local md5Obj = crypto.flow_md5()
		while true do 
			local data = file:read(256)
			if data == nil then
				break	
			end
			md5Obj:update(data)
		end
		md5_value = string.lower(md5Obj:hexdigest())
		file:close()
	else
		log.error("firmware_update","chk_md5 open file:",filePath,"error")
	end

	if md5_value ~= nil and md5_value == md5 then 
		log.error("firmware_update","the md5 value are the same")
		return true
	else	
		log.error("firmware_update","the md5 value no the same","md5:"..md5.." clac md5:"..md5_value)
		return false
	end
end

local function new_firmware_download_proc(update_ctr)
	while update_ctr.enable == true do
		local filePath,fileSize =  downloadfirmware(update_ctr.firmware)
		local chk_md5_ok = false 

		if filePath and fileSize == update_ctr.firmware.size then
			if chk_md5(filePath,update_ctr.firmware.md5) == true then 
				chk_md5_ok = true
			end
		end 

		--检查是否有新的下载任务进来
		local new_download_task = nvm.get("download_task")
		if new_download_task.md5 == update_ctr.firmware.md5 then
			--检查md5校验是否成功
			if chk_md5_ok then
				os.remove(FW_FILE_PATH)
				os.rename(UPD_FILE_PATH,FW_FILE_PATH)
				local firmware = {}
				firmware.md5 = update_ctr.firmware.md5
				firmware.size = update_ctr.firmware.size
				firmware.ver = update_ctr.firmware.ver
				firmware.path = FW_FILE_PATH 
				firmware.transfer_over = false
				log.error("new_firmware_download_proc","save firmware info")
				nvm.set("firmware",firmware)
			end
			local task = update_ctr.firmware
			task.download_over = true
			log.error("exit download and save download_task")
			nvm.set("download_task",task)
			--退出下载
			update_ctr.enable = false
		else 
			--继续下载新的固件
			update_ctr.firmware = new_download_task;
			log.error("firmware_update","break current download task, because has a new version come in")
		end
	end
end

local function download_check(last_task)
	if not last_task then 
		log.error("download_check","no last_task")
		return true
	else
		if last_task.download_over and last_task.download_over == true then
			log.error("download_check","last_task.ver:"..last_task.ver," download_over:",last_task.download_over)
			return true
		end
	end
	return false
end

local function send_firmwareData_to_device(filePath,update_hook)
	if not filePath or not update_hook then return 0 end
	if not update_hook.transfer then return 0 end

	local file,err = io.open(filePath,"r")
	if file then
		local offset = 0
		--沟通完成开始发送数据
		while true do 
			local data = file:read(256)
			if data == nil then
				break	
			end
			--发送数据send data	
			offset = offset + 1
			if update_hook.transfer(offset,data) == true then
				update_hook.send_size = update_hook.send_size + #data
			else 
				break
			end
		end
		file:close()
	else
		log.error("firmware_update","open firmware file error:",err)
	end
	log.error("firmware_update","transfer size:"..update_hook.send_size)
	return update_hook.send_size
end

local function firmware_update(update_hook)
	local firmware = nvm.get("firmware")
	if not firmware or firmware.transfer_over == true then
		log.error("check local firmware file:","no think to do")
	else
		log.error("check local firmware file::","firmware:"..firmware.path," md5:"..firmware.md5," size:"..firmware.size)
		if update_hook and update_hook.query and update_hook.transfer and update_hook.check then 
			local transfer_over = false
			local clean_version = false
			--GISUNLINK_NEED_UPGRADE = 0x00,   GISUNLINK_NO_NEED_UPGRADE = 0x01,    GISUNLINK_DEVICE_TIMEOUT = 0x02
			local transfer = update_hook.query(firmware);
			if transfer == uartTask.GISUNLINK_NO_NEED_UPGRADE then 
				clean_version = true;
				log.error("local firmware file:","device no need to update firmware")
			elseif transfer == uartTask.GISUNLINK_DEVICE_TIMEOUT then
				log.error("local firmware file:","device is off-line")
			elseif transfer == uartTask.GISUNLINK_NEED_UPGRADE then
				update_hook.update = true
				update_hook.version = firmware.ver
				update_hook.send_size = 0
				update_hook.file_size = firmware.size
				if send_firmwareData_to_device(firmware.path,update_hook) == firmware.size then
					transfer_over = true
				end
			end

			if transfer_over == true then 
				log.error("local firmware file:","firmware transfer finish")
				local ret = update_hook.check();

				if ret == uartTask.GISUNLINK_FIRMWARE_CHK_OK then 
					clean_version = true
				elseif ret == uartTask.GISUNLINK_DEVICE_TIMEOUT then 
					log.error("local firmware file:","device is off-line")
				elseif ret == uartTask.GISUNLINK_FIRMWARE_CHK_NO_OK then
					clean_version = false
					log.error("local firmware file:","device check data error!")
				end
			else 
				log.error("local firmware file:","firmware transfer unfinished")
			end

			if clean_version == true then
				os.remove(firmware.path)
				firmware.transfer_over = true
				nvm.set("firmware",firmware)
				if transfer_over == true then
					log.error("local firmware file","device succeed receive data!")
				end
			end
		end
	end
	update_hook.update = false;
	update_hook.file_size = 0;
	update_hook.send_size = 0;
	update_hook.version = 0;
end

local function updateFirmware_Proc(update_ctr)
	while true do	
		local result = sys.waitUntil("updateFirmware_working") 
		if result == true then
			while true do 
				new_firmware_download_proc(update_ctr)
				local last_download_task = nvm.get("download_task")
				if download_check(last_download_task) then
					break;
				else 
					last_download_task.download_over = false
					update_ctr.firmware = last_download_task;
					update_ctr.enable = true
					log.error("firmware_update","the file:"..last_download_task.md5.." download unfinished now go continue download it")
				end
			end
			--检查是否有可升级固件文件
			firmware_update(update_ctr.update_hook)
		end
	end
end

rtos.make_dir(USER_DIR_PATH)
sys.taskInit(updateFirmware_Proc,download)
