--- 模块功能：串口功能测试(非TASK版，串口帧有自定义的结构)
-- @author openLuat
-- @module uart.testUartTask
-- @license MIT
-- @copyright openLuat
-- @release 2018.05.24

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
download.updateCb = nil

function updateCb(callback)
	if not callback or callback == nil then return end
	download.updateCb = callback
end

function system_start_signal()
	if download.enable == false then
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
			end
		else
			log.error("firmware_update","the version are the smae")
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
	end
	return 
end

local function downloadfirmware(firmware)
	local download_path = nil
	if not firmware or not firmware.url or not firmware.md5 then log.error("downloadfirmware","exit download task") return end
	local download_num = 0;
	while true do
		os.remove(UPD_FILE_PATH)
		if firmware.size >= rtos.get_fs_free_size() then break end;

		http.request("GET",firmware.url,nil,nil,nil,60000,function (respond,statusCode,head,filePath) 
			sys.publish("UPDATE_DOWNLOAD",respond,statusCode,head,filePath)
		end,UPD_FILE_PATH)

		local _,result,statusCode,head,filePath = sys.waitUntil("UPDATE_DOWNLOAD")

		if result then 
			if statusCode == "200" then
				local fileSize = io.fileSize(UPD_FILE_PATH)
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
			end
		end
	end
	return download_path
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
		local filePath =  downloadfirmware(update_ctr.firmware)
		local chk_md5_ok = false 

		if filePath then
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
				nvm.set("firmware",firmware)
			end
			local task = update_ctr.firmware
			task.download_over = true
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

local function download_check(firmware)
	if not firmware then 
		return true
	else
		if firmware.download_over and firmware.download_over == true then
			return true
		end
	end
	return false
end

local function firmware_update(updateCb)
	local firmware = nvm.get("firmware")
	if not firmware or firmware.transfer_over == true then
		log.error("firmware_update","no think to do")
	else
		if updateCb then 
			updateCb(firmware.path)
		end
		os.remove(firmware.path)
		firmware.transfer_over = true
		nvm.set("firmware",firmware)
		log.error("firmware_update","firmware update finish")
	end
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
			firmware_update(update_ctr.updateCb)
		end
	end
end

rtos.make_dir(USER_DIR_PATH)
sys.taskInit(updateFirmware_Proc,download)
