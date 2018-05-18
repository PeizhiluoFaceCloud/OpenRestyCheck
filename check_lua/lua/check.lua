#!/usr/local/openresty/luajit/bin/luajit-2.1.0-alpha

-----------------代码规范说明-----------------
--[[
所有程序基本框架都是类似的
说明1>对错误应答的处理
	在processmsg函数中会调用各个处理分支，如果分支函数成功则其内部返回http应答
	如果返回失败，由processmsg判断返回值统一应答
说明2>对鉴权等常规共性的动作做好可以统一到脚本中去执行
说明3>HTTP应答头统一都是OK，这样便于查找是应用错误，还是系统错误
]]

--[设定搜索路径]
--将自定义包路径加入package的搜索路径中。也可以加到环境变量LUA_PATH中
--放到init_lus_path.lua中，不然的话，每一个请求处理的时候都会对全局变量
--package.path进行设置，导致

--[包含公共的模块]
local tableutils = require("common_lua.tableutils")		--打印工具
local cjson = require("cjson.safe")
local wanip_iresty = require("common_lua.wanip_iresty")
local http_iresty = require ("resty.http")
local redis_iresty = require("common_lua.redis_iresty")
local script_utils = require("common_lua.script_utils")

--[基本变量参数]
local redis_ip = nil
local redis_port = 6379
local udpsock_port = 5000

--发送应答数据报
function send_resp_table (status,resp)
	if not resp or type(resp) ~= "table" then
		ngx.log(ngx.ERR, "send_resp_table:type(resp) ~= table", type(resp))
		ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
	end
	--HTTP应答头统一都是OK，这样便于查找是应用错误，还是系统错误
	--ngx.status = status
	local resp_str = cjson.encode(resp)
	--ngx.log(ngx.NOTICE, "send_resp_table:", resp_str)
	ngx.header.content_length = string.len(resp_str)
	ngx.say(resp_str)
end
function send_resp_string(status,message_type,error_string)
	if not message_type or type(message_type) ~= "string" then
		ngx.log(ngx.ERR, "send_resp_string:type(message_type) ~= string", type(message_type))
		ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
	end
	if not error_string or type(error_string) ~= "string" then
		ngx.log(ngx.ERR, "send_resp_string:type(error_string) ~= string", type(error_string))
		ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
	end
	--HTTP应答头统一都是OK，这样便于查找是应用错误，还是系统错误
	--ngx.status = status
	local jrsp = {}
	jrsp["DDIP"] = {}
	jrsp["DDIP"]["Header"] = {}
	jrsp["DDIP"]["Header"]["Version"] = "1.0"
	jrsp["DDIP"]["Header"]["CSeq"] = "1"
	jrsp["DDIP"]["Header"]["MessageType"] = message_type
	jrsp["DDIP"]["Header"]["ErrorNum"] = string.format("%d",status)
	jrsp["DDIP"]["Header"]["ErrorString"] = error_string
	local resp_str = cjson.encode(jrsp)
	--ngx.log(ngx.NOTICE, "send_resp_string:", resp_str)
	ngx.header.content_length = string.len(resp_str)
	ngx.say(resp_str)
end

--对输入的参数做有效性检查，返回解码后的消息体对象json对象
function get_request_param()
	--ngx.log(ngx.NOTICE, "get_request_param:",ngx.var.request_body)
    local req_body, err = cjson.decode(ngx.var.request_body)
	if not req_body then
		ngx.log(ngx.ERR, "get_request_param:req body is not a json")
		return nil, "req body is not a json"
    end
    if not req_body["DDIP"]
        or not req_body["DDIP"]["Header"]
        or not req_body["DDIP"]["Header"]["Version"]
        or not req_body["DDIP"]["Header"]["CSeq"]
        or not req_body["DDIP"]["Header"]["MessageType"]
        or not req_body["DDIP"]["Body"]
        or type(req_body["DDIP"]["Header"]["Version"]) ~= "string"
        or type(req_body["DDIP"]["Header"]["CSeq"]) ~= "string"
        or type(req_body["DDIP"]["Header"]["MessageType"]) ~= "string"
		then
        ngx.log(ngx.ERR, "invalid args")
        return nil, "invalid protocol format args"
    end
    return req_body, "success"
end

-- 写入文件
local function writefile(filename, info)
	print("writefile--------->",filename)
    local wfile=io.open(filename, "w") --写入文件(w覆盖)
    assert(wfile)  		--打开时验证是否出错
    wfile:write(info)  	--写入传入的内容
    wfile:close()  		--调用结束后记得关闭
end

--向服务程序发送分析请求
local function send_to_face_server(method,filename,user_id,group_id)
    local sock = ngx.socket.udp()
	if not sock then
		ngx.log(ngx.ERR, "new ngx.socket.udp  failed")
		return false, "new ngx.socket.udp failed"
	end
	local ok, err = sock:setpeername("127.0.0.1",udpsock_port)
	if not ok then
		ngx.log(ngx.ERR,"failed to connect to the udp socket:"..udpsock_port, err)
		return false, "failed to connect to the udp socket:"..udpsock_port
	end
	--print("succ to connect to the udp socket: ", err)
	--调整一下消息格式
	local msgtable = {};
	msgtable["method"] = method
    msgtable["filename"] = filename
    msgtable["group_id"] = group_id
    msgtable["user_id"] = user_id
	local senddata = cjson.encode(msgtable)
	--print("sendmsg----------------->",senddata,"to ",udpsock_port)
	local ok, err = sock:send(senddata)
	if not ok then
		ngx.log(ngx.ERR,"failed to send data to the udp socket:"..udpsock_port, err)
		return false, "failed to send data to the udp socket:"..udpsock_port
	end
	sock:settimeout(5000)  -- one second timeout
	local recvdata, err = sock:receive(1024)
	if not recvdata then
		ngx.log(ngx.ERR,"read resp timeout")
		return false,"read resp from udpsocket timeout"
	end
	--ngx.log(ngx.NOTICE,"receive resp ...",recvdata)
    local rsq_body, err = cjson.decode(recvdata)
	if not rsq_body then
		ngx.log(ngx.ERR, "receive resp is not a json",recvdata)
		return false,"receive resp is not a json"
    end
	return true,rsq_body
end

--创建一个随机数
local function get_random()
	--math.randomseed(os.time())
	return string.format("%03x99%x99%03x",math.random(100),os.time(),math.random(100))
end

--从日期字符串中截取出年月日时分秒[0000-00-00 00:00:00]
local function string2time(timeString)  
    local Y = string.sub(timeString,1,4)  
    local M = string.sub(timeString,6,7)  
    local D = string.sub(timeString,9,10)  
    local H = string.sub(timeString,12,13)  
    local MM = string.sub(timeString,15,16)  
    local SS = string.sub(timeString,18,19)
    return os.time{year=Y,month=M, day=D, hour=H,min=MM,sec=SS}  
end

--处理注册消息
function do_check(jreq)
	--判断命令格式的有效性
	if not jreq["DDIP"]["Body"]["Project"]
		or type(jreq["DDIP"]["Body"]["Project"]) ~= "string"
		then
	    ngx.log(ngx.ERR, "do_check,invalid args")
	    return false,"do_check,invalid args"
	end

    --创建redis操作句柄
    local opt = {["redis_ip"]=redis_ip,["redis_port"]=redis_port,["timeout"]=3}
	local red_handler = redis_iresty:new(opt)
	if not red_handler then
	    ngx.log(ngx.ERR, "redis_iresty:new red_handler failed")
		return false,"redis_iresty:new red_handler failed"
	end
    --获取项目信息(验证一下,项目是否存在，以及是否在有效期内)
    local project_key = "project:"..jreq["DDIP"]["Body"]["Project"]..":info"
    local project_info, err = red_handler:hmget(project_key,"CheckBegin","CheckEnd")
    if not project_info then
	    ngx.log(ngx.ERR, "get project info failed : ", project_key,err,redis_ip)
		return false,"get project info failed"
	end
    --返回的排列顺序(key1,val1,key2,val2,key3,val3)，下标从1开始
    local CheckBegin = string2time(project_info[1])
    local CheckEnd = string2time(project_info[2])
    if(os.time() < CheckBegin) then
        ngx.log(ngx.ERR, "check begin time failed:",os.date("%Y-%m-%d %H:%M:%S"),project_info[1])
		return false,"check begin time failed:"
    end
    if(os.time() > CheckEnd) then
        ngx.log(ngx.ERR, "check end time failed:",os.date("%Y-%m-%d %H:%M:%S"),project_info[2])
		return false,"check end time failed:"
    end

    local check_user_id = nil
    --二维码校验
    if jreq["DDIP"]["Body"]["QRCode"] then
        local qr_code_key = "project:"..jreq["DDIP"]["Body"]["Project"]..":qrcode:"..jreq["DDIP"]["Body"]["QRCode"]
        local phonenumber, err = red_handler:get(qr_code_key)
        if not phonenumber then
            ngx.log(ngx.ERR, "qr_code not exit in redis", err)
            return false,"qr_code not exit in redis"
        end
        local user_key = "project:"..jreq["DDIP"]["Body"]["Project"]..":user:"..phonenumber
        local qr_code, err = red_handler:hget(user_key,"QRCode")
        if not qr_code then
            ngx.log(ngx.ERR, "get qr_code from redis failed", err)
            return false,"get qr_code from redis failed"
        end                    
        if jreq["DDIP"]["Body"]["QRCode"] ~= qr_code then
            ngx.log(ngx.ERR, "qr_code not match")
            return false,"qr_code not match"
        else
            check_user_id = phonenumber  --二维码校验通过
        end
    --人脸校验
    elseif jreq["DDIP"]["Body"]["Picture"] then
        --把照片保存到磁盘中(节省内存)
        --注意lua中的string不是一般理解的string，内部可以包括0的，所以不必担心。
        local picture_filename = ngx.var.images_root..get_random()..".check.jpg"
        writefile(picture_filename, ngx.decode_base64(jreq["DDIP"]["Body"]["Picture"]))
        ------------对接第三方AI库------------
        --调用人脸识别接口:
        local group_id = "group0"
        local ok, ackJson = send_to_face_server("identify",picture_filename,nil,group_id)
        if ok ~= true then
            ngx.log(ngx.ERR, "send_to_face_server failed")
            return false,"send_to_face_server failed"
        end
        if ackJson["ret"] ~= "ok" then
            ngx.log(ngx.ERR, "operate failed:",ackJson["ret"])
            return false,ackJson["ret"]
        else
            check_user_id = ackJson["user_id"]  --人脸校验通过
        end
    else
        ngx.log(ngx.ERR, "do_check,not QRCode and not Picture")
        return false,"do_check,not QRCode and not Picture"
    end
    
    local user_key = "project:"..jreq["DDIP"]["Body"]["Project"]..":user:"..check_user_id
    -----------用户状态------------
    local user_status, err = red_handler:hget(user_key,"Status")
    if not user_status then
        ngx.log(ngx.ERR, "user_status not exit in redis", err)
        return false,"user_status not exit in redis"
    end
    local CheckStatus = "CheckOK"
    if user_status == "Checked" then
        CheckStatus = "CheckRepeat"
    else
        local ok, err = red_handler:hmset(user_key,"Status","Checked","CheckTime",ngx.utctime())
        if not ok then
            ngx.log(ngx.ERR, "hset user Status to redis failed", err)
            return false,"hset user  Status to redis failed"
        end
    end

    -----------用户信息------------
    local register_pic, err = red_handler:hget(user_key,"RegisterPicture")
    if not register_pic then
        ngx.log(ngx.ERR, "RegisterPicture not exit in redis", err)
        return false,"RegisterPicture not exit in redis"
    end
    local user_name, err = red_handler:hget(user_key,"Name")
    if not user_name then
        ngx.log(ngx.ERR, "Name not exit in redis", err)
        return false,"Name not exit in redis"
    end
    
    --返回应答数据
	local jrsp = {}
	jrsp["DDIP"] = {}
	jrsp["DDIP"]["Header"] = {}
	jrsp["DDIP"]["Header"]["Version"] = "1.0"
	jrsp["DDIP"]["Header"]["CSeq"] = "1"
	jrsp["DDIP"]["Header"]["MessageType"] = "MSG_CHECK_RSP"
	jrsp["DDIP"]["Header"]["ErrorNum"] = "200"
	jrsp["DDIP"]["Header"]["ErrorString"] = "Success OK"
	jrsp["DDIP"]["Body"] = {}
	jrsp["DDIP"]["Body"]["CheckStatus"] = CheckStatus
	jrsp["DDIP"]["Body"]["PhoneNumber"] = check_user_id
	jrsp["DDIP"]["Body"]["Name"] = user_name
	jrsp["DDIP"]["Body"]["RegisterPicture"] = register_pic
	send_resp_table(ngx.HTTP_OK,jrsp)
	return true, "OK"
end

--消息处理函数入库
function process_msg()
	--获取请求对象
	local jreq, err = get_request_param()
	if not jreq then
		send_resp_string(ngx.HTTP_BAD_REQUEST,"any",err);
	    return
	end
	--分命令处理
	if(jreq["DDIP"]["Header"]["MessageType"] == "MSG_CHECK_REQ") then
		local ok, err = do_check(jreq);
		if not ok then
			send_resp_string(ngx.HTTP_BAD_REQUEST,"MSG_CHECK_RSP",err);
		end
	else
		ngx.log(ngx.ERR, "invalid MessageType",jreq["DDIP"]["Header"]["MessageType"])
		send_resp_string(ngx.HTTP_BAD_REQUEST,"any","invalid MessageType");
	end
	return
end


--加载Redis的地址信息(环境变量中配置)
local function load_ip_addr()
	redis_ip = ngx.shared.shared_data:get("RedisIP")
	if redis_ip == nil  then
		ngx.log(ngx.ERR,"get RedisIP failed ")
        return false
	end
	return true
end

--程序入口
--print("get request_body:"..ngx.var.request_body)
--print("=====================new request=======================\n")
--print("get server_port::::",ngx.var.server_port,type(ngx.var.server_port))
if(ngx.var.server_port == "8001") then			-->register.xxxxxx.xxxx:8000
	local ok = load_ip_addr()
	if not ok then
		ngx.log(ngx.ERR,"load_ip_addr failed ")
		return false
	end
else
	ngx.log(ngx.ERR,"invlaid ngx.var.server_port",ngx.var.server_port)
	return false
end

process_msg()

