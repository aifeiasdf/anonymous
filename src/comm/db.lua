module(..., package.seeall)
local config = require "lua.comm.config"
local redis = require "lua.db_redis.db_base"
local common = require "lua.comm.common"
local work_job = require "lua.comm.work_job"
local red = redis:new()

local UPGRADE_TYPES = {config.MAIN_VER_UPGRADE, config.VIRUS_LIBS_UPGRADE, config.LEAK_LIBS_UPGRADE} -- 控制相应的升级类型
local format = string.format

function add_proxy_query(need_query_cloud_md5s) --使用hash作为存储是因为有获取长度的api，list没有
    local need_query_cloud_data={}
    local htable="proxy_query"

    for index, t_info in pairs(need_query_cloud_md5s) do
      if #t_info.md5_sha1 then
        local file_info = common.json_encode(t_info)
        need_query_cloud_data[t_info.md5_sha1] = file_info
      end
    end
    if red:hlen(htable) > config.CLOUD_QUERY_REDIS_MAX then
      ngx.log(ngx.WARN, "redis   proxy_query  space overflow "..config.CLOUD_QUERY_REDIS_MAX)
      return false
    end
    local ok, err = red:hmset(htable, need_query_cloud_data)
    return ok
end

function push_to_pg_file(file_info)
  local res, err = red:rpush(config.FILE .. '_' .. config.NGX2PHP, common.json_encode(file_info))
  return res
end

function get_task_withid( client_mid, task_type, task_id )
    local task_info = {}
    task_info.id = tonumber(task_id)

    local key_task_id = config.TASK .. '_' .. task_id
    local info = red:hmget(key_task_id,
        'type', 'is_queue', 'feedback',
        'task_expire_time_relative', 'exec_expire_time_relative', 'detail')

    task_info.type      = tonumber(info[1])
    task_info.is_queue  = tonumber(info[2])
    task_info.feedback  = tonumber(info[3])
    task_info.task_expire_time_relative  = tonumber(info[4])
    task_info.exec_expire_time_relative  = tonumber(info[5])
    task_info.detail    = common.json_decode(info[6])

    if 0 == task_info.feedback then
      local red = redis:new()
      red:init_pipeline()
      red:zrem(config.TASK .. '_' .. task_type .. '_' .. client_mid, task_id) -- 不需要feedback的任务，直接清除
      red:hincrby(key_task_id, 'running', 1)
      red:hincrby(key_task_id, 'finished', 1)
      red:hget(key_task_id, "total")
      red:hget(key_task_id, "finished")
      local res_s, err = red:commit_pipeline()
      if not err and res_s[4] == res_s[5] then
        red:del(key_task_id)
        ngx.log(ngx.WARN, "read to delete data")
      end

      return task_info
    end

    local status = red:zscore(config.TASK .. '_' .. task_type .. '_' .. client_mid, task_id)
    ngx.log(ngx.WARN, "status:", status)
    if status ~= nil and tonumber(status) == 0 then --如果没有被获取过，就set状态为-1(状态默认为0，并且从小到大排序)，并且任务的running加1
      local red = redis:new()
      red:init_pipeline()
      red:zadd(config.TASK .. '_' .. task_type .. '_' .. client_mid, -1, task_id)
      red:hincrby(key_task_id, 'running', 1)
      red:commit_pipeline()
    end

    return task_info
end

function get_tasks(client_mid, task_type, task_ids)
  local task_infos = {}

  -- 获取等待执行的任务id
  if nil == task_ids or #task_ids == 0 then
      ngx.log(ngx.WARN, "not found:", config.TASK .. '_' .. task_type .. '_' .. client_mid)
      return task_infos
  else
      ngx.log(ngx.WARN, "found:", config.TASK .. '_' .. task_type .. '_' .. client_mid)
  end

  for _,task_id in ipairs(task_ids) do
    local value =  red:exists(config.TASK .. '_' .. task_id)
    if 0 == tonumber(value) then
        red:zrem(config.TASK .. '_' .. task_type .. '_' .. client_mid, task_id) -- 清理过期任务
        ngx.log(ngx.WARN, "expire task:", task_id)
    else
        local task = get_task_withid(client_mid, task_type, task_id)
        table.insert(task_infos, task)  -- 获取任务信息
        ngx.log(ngx.WARN, "got task:", task_id)

        if 1 == tonumber(task.is_queue) then
          ngx.log(ngx.WARN, "type is_queue, only can get one")
          break
        end
    end
  end

  return task_infos
end

function fn_delay_commit_callback( key, chan, type_s )
  local syn_full = 50
  local res, err = red:srandmember(key, syn_full)
  if err then
    ngx.log(ngx.ERR, "get task running status fail err:", err)
    return true
  end

  local status_json = res
   ngx.log(ngx.WARN, "start syn data:", common.json_encode(status_json))
  if 0 == #status_json then
    return true
  end

  ngx.log(ngx.WARN, "start syn data:", common.json_encode(status_json))

  local function work_job_put( status )
    local record_json = common.json_encode({channel=chan, type=type_s, data=status})
    local ok , err , id = work_job.put("work_queue_" .. config.NGX2PHP, record_json)
    ngx.log(ngx.WARN, "put the job info status:", ok , " err:", err , " id:", id, " data:", record_json:sub(1, 100))
  end

  local status = {}
  local total_size = 0
  local max_body = 1000*500
  for _,v in ipairs(status_json) do
    if #v > max_body then
      work_job_put({common.json_decode(v)})
    else
      total_size = total_size + #v
      table.insert(status, common.json_decode(v))
      if total_size > max_body then
        work_job_put(status)
        status = {}
        total_size = 0
      end
    end
  end

  if total_size > 0 then
    work_job_put(status)
  end

  red:srem(key, unpack(status_json))

  if #status < syn_full then
    return true
  end

  return false
end

function get_client_tasks(client_mid, task_types)
  local tasks_all = {}

  local red = redis:new()
  red:init_pipeline()
  for _,task_type in pairs(task_types) do
    red:zrange(config.TASK .. '_' .. task_type .. '_' .. client_mid, 0, 4)
  end
  local res_s, err = red:commit_pipeline()
  if err or not res_s then
    return tasks_all
  end

  for i,task_ids in pairs(res_s) do
    local tasks = get_tasks(client_mid, task_types[i], task_ids)
    for _,v in pairs(tasks) do
      table.insert(tasks_all, v)
    end
  end

  -- delay commit, save to redis at first
  local task_ids = {}
  for i,task in ipairs(tasks_all) do
    if 1 == task.feedback then
      table.insert(task_ids, task.id)
    end
  end

  if #task_ids > 0 then
    cache_and_delay_commit("task_running_status", 3,
      {mid=client_mid, task_ids=task_ids}, "task_status", "running_syn")
  end

  return tasks_all
end

function cache_and_delay_commit( key, msec, value, chan, type_s, tube)  -- key:缓存键值 chan:频道 type:类型 sec:缓存秒数
  -- key = "cache_delay_"..key  -- 暂时屏蔽延迟提交的使用，成熟后放开
  -- local id, err = red:sadd(key, common.json_encode(value))
  -- common.delay_commit(key, msec, fn_delay_commit_callback, chan, type_s)

  local record_json = common.json_encode({channel=chan, type=type_s, data={value}})
  local ok,err,id = work_job.put("work_queue_" .. (tube or config.NGX2PHP), record_json)
  ngx.log(ngx.WARN, "put the job info: ", record_json)

  return id, err
end

function finish_client_task(client_mid, task_id)
    -- 获取任务typchan
    local task_type, err = red:hget(config.TASK .. '_' .. task_id, 'type')
    if err then
      return false, "get the task's type failed. task_id:" .. task_id
    elseif nil == task_type then
      return false, "task_type is nil"
    end

    -- 清除掉终端绑定的任务id
    local count, err = red:zrem(config.TASK .. '_' .. task_type .. "_" .. client_mid, task_id) --删除任务
    if nil ~= err then
      return false, err
    elseif 0 == count then
      return false, 'task count is 0'
    end

    -- 计数加一
    red:hincrby(config.TASK .. '_' .. task_id, 'finished', 1) --计数加1, 具体结果控制台不需要，忽略掉

    return true
end

function check_client_need_query(mid)
  local rep_data = {}

  local red = redis:new()
  red:init_pipeline()
  red:hgetall("client_check_query_" .. mid)
  red:hgetall("client_check_query_" .. "all")

  local res_s, err = red:commit_pipeline()

  local res = res_s[1]
  if nil == err and res then
    local self_data = {type = "self"}
    local k, v = nil, nil
    for i=1,#res,2 do
      k = res[i]
      v = res[i+1]
      self_data[k] = v
    end

    table.insert(rep_data, self_data)
  end

  local res = res_s[2]
  if nil == err and res then
    local all_data = {type = "all"}
    local k, v = nil, nil
    for i=1,#res,2 do
      k = res[i]
      v = res[i+1]
      all_data[k] = v
    end

    table.insert(rep_data, all_data)
  end

  client_heartbeat(mid)
  return rep_data
end

function client_heartbeat( mid )
  local heartbeat_interval = get_heartbeat_interval(mid)

  local exp_time = ngx.time() + heartbeat_interval + 5 * 60
  local res, err = red:zadd("heartbeats", exp_time, mid)

  if nil == err and res > 0 then
    local MAX_LEN = 50 * 10000
    red:rpush("client_online", mid)             -- client from offline to online
    red:ltrim("client_online", 0, MAX_LEN)      -- control the length of the list
  end

  ngx.log(ngx.WARN, "hearbeat err:", err)
  return
end

function get_heartbeat_interval( mid )
  local MAX_INTERVAL = 30 * 60
  local MIN_INTERVAL = 10
  local heartbeat_interval = nil

  local ok, gid = get_gid(mid)
  gid = gid or "1"
  -- 1. get heartbeat interval from cache
  local json_res = common.get_data_with_cache({key="config_gid_"..gid.."_base_config",
                                          exp_time_succ=10,
                                          exp_time_fail=-1},
                                  red.hget, red, "config_gid_"..gid, "base_config")
  local base_config = common.json_decode(json_res) or {}
  if base_config and base_config.ping_time and base_config.ping_time.value then
    heartbeat_interval = tonumber(base_config.ping_time.value)
  end

  -- 2. check valid
  if not heartbeat_interval or heartbeat_interval < MIN_INTERVAL then
    heartbeat_interval = MIN_INTERVAL
  elseif heartbeat_interval > MAX_INTERVAL then
    heartbeat_interval = MAX_INTERVAL
  end

  return heartbeat_interval
end

function get_max_revoke_id()
  return red:incr(config.LEVEL_CHANGE_MAX_ID)
end

function get_max_revoke_id_admin()
  return red:incr(config.LEVEL_CHANGE_MAX_ID_ADMIN)
end

function update_revoke_version()
  red:hincrby("client_check_query_all", 'revoke', 1)
end

function update_revoke_version_admin()
  red:hincrby("client_check_query_all", 'revoke_admin', 1)
end

function custom_files_update(key,data)
  red:hmset(key,data)
end
function client_check_query_set( ... )
end

function set_revoke_records(data)
    local res = false
    local state = red:hmset(config.LEVEL_CHANGE, data)
    update_revoke_version()
    if state == 'OK' then
        res = true
    end
    return res
end

function set_revoke_records_admin(data)
    local res = false
    local state = red:hmset(config.LEVEL_CHANGE_ADMIN, data)
    update_revoke_version_admin()
    if state == 'OK' then
        res = true
    end
    return res
end

function get_revoked_file_info(begin_id)
    local revoked_file_info = {}

    local step =  500
    local max_id = tonumber((red:get(config.LEVEL_CHANGE_MAX_ID)) or 0)

    if max_id <= 0 then
      ngx.log(ngx.WARN, "begin:", begin_id, " max_id:", max_id)
      return revoked_file_info, false -- 没有数据
    end

    if 0 == begin_id then
      begin_id = max_id - 1
    end

    if max_id - begin_id > config.REVOKE_CLEAN_MAX then
      ngx.log(ngx.WARN, format("max_id[%s] - begin_id[%s] > %s client clear local cache. ", max_id, begin_id, config.REVOKE_CLEAN_MAX))
      return revoked_file_info, true  -- 历史记录大于3w，终端清缓存
    end

    if begin_id > max_id then
      ngx.log(ngx.WARN, format("begin_id[%s] > max_id[%s] client clear local cache", begin_id, max_id))
      return revoked_file_info, true  -- 服务端重新安装，客户端重新遍历吊销
    end

    local new_begin = (math.modf(begin_id/step))*step
    local ids = {}
    for i=new_begin+1, new_begin+step do
      table.insert(ids, i)
    end
    ngx.log(ngx.WARN, "get level_change begin:", new_begin+1, " end:", new_begin+step)

    local res, err = red:hmget(config.LEVEL_CHANGE,unpack(ids))
    if nil == err and res and #res > 0 then
      local id, values
      for i=1,#res do
        id     = ids[i]
        values = res[i]
        if values ~= ngx.null and tonumber(id) > tonumber(begin_id) then
          values = common.json_decode(values)
          if nil ~= values then
            table.insert(revoked_file_info, {id = tostring(id), md5 = values.md5, new_level = values.new_level,
              class = values.virus_name.class or '', name = values.virus_name.name or '', level_ex = values.level_ex})
          end
        end
      end
    end

    return revoked_file_info, false
end

function get_revoked_file_info_admin(begin_id)
    local revoked_file_info = {}

    local step =  500
    local max_id = tonumber((red:get(config.LEVEL_CHANGE_MAX_ID_ADMIN)) or 0)

    if max_id <= 0 then
      ngx.log(ngx.WARN, "begin:", begin_id, " max_id:", max_id)
      return revoked_file_info, false -- 没有数据
    end

    -- if 0 == begin_id then
    --   begin_id = 1
    -- end

    if max_id - begin_id > config.REVOKE_CLEAN_MAX then
      ngx.log(ngx.WARN, format("max_id[%s] - begin_id[%s] > %s client clear local cache. ", max_id, begin_id, config.REVOKE_CLEAN_MAX))
      return revoked_file_info, true  -- 历史记录大于3w，终端清缓存
    end

    if begin_id > max_id then
      ngx.log(ngx.WARN, format("begin_id[%s] > max_id[%s] client clear local cache", begin_id, max_id))
      return revoked_file_info, true  -- 服务端重新安装，客户端重新遍历吊销
    end

    local new_begin = (math.modf(begin_id/step))*step
    local ids = {}
    for i=new_begin+1, new_begin+step do
      table.insert(ids, i)
    end
    ngx.log(ngx.WARN, "get level_change begin:", new_begin+1, " end:", new_begin+step)

    local res, err = red:hmget(config.LEVEL_CHANGE_ADMIN,unpack(ids))
    if nil == err and res and #res > 0 then
      local id, values
      for i=1,#res do
        id     = ids[i]
        values = res[i]
        if values ~= ngx.null and tonumber(id) > tonumber(begin_id) then
          values = common.json_decode(values)
          if nil ~= values then
            if tonumber(values.new_level) >= 7010 then
              values.level_ex = 3
            end

            table.insert(revoked_file_info, {id = tostring(id), md5 = values.md5, new_level = values.new_level,
              class = values.virus_name.class or '', name = values.virus_name.name or '', level_ex = values.level_ex})
          end
        end
      end
    end

    return revoked_file_info, false
end

function  update_client_conf(mid, client_status)
    local client_status = common.json_decode(client_status)
    --local sql = [[ UPDATE client_conf SET client_file_monitor =]] .. client_status.file_monitor .. [[, client_u_monitor =]] .. client_status.u_disk_monitor .. [[ WHERE mid=']] .. mid .. [[']]
    --local state, res = common.query_from_db(sql)
    --chenyuduan
    -- 疑问：要不要把整个client_status 都存起来？ 如果要 就没有必要用client_data
    local state = false
    if red:get('client_conf'..mid) then
      local client_data = {}
      client_data["client_file_monitor"]=client_status.file_monitor
      client_data["client_u_monitor"]=client_status.u_disk_monitor
      state = red:hmset('client_conf'..mid, client_data)
    end
    return state
end

function client_uninstall(mid)
    local res, err = red:del('client_'..mid)
    red:del('check_mid_valid_'.. mid)

    if err or 0 == tonumber(res) then
      return false, "not found"
    end

    return true
end

function update_client_info(mid, args)
    local ht = 'client_'..mid
    local state = true
    local is_change = false
    local client_change_info = nil

    local client_data = {} --新建一个，防止终端上报多余的数据
    local keys = {'computer_name', 'user_name', 'mac', 'ip', 'group', 'os', 'osex', 'report_ip', 'sys_space', 'ie_ver'}
    for _,key in ipairs(keys) do
      client_data[key] = args[key]
    end


    local res,err = red:hgetall(ht)
    if nil == err and res then --如果redis已经存在，判断差异
      local rep_data = {}
      for i=1,#res,2 do
          local k = res[i]
          local v = res[i+1]
          rep_data[k] = v
      end

      for _, key in pairs(keys) do
          if rep_data[key] ~= tostring(client_data[key]) then
              if client_change_info == nil then
                  client_change_info = {}
              end
              client_change_info[key] = client_data[key]
          end
      end

      if client_change_info ~= nil then --如果终端信息和上次上报的对比有变化
          ngx.log(ngx.WARN, "have change", common.json_encode(client_change_info))
          local res, err = red:hmset(ht, client_change_info)
          if res then --redis设置成功
              is_change = true
          else
              state = false
              ngx.log(ngx.WARN, err)
          end
      end

      if not is_change and nil == rep_data['gid'] then  -- 如果终端的gid为空，则再次给后台推送
        is_change = true
      end

    else --如果redis不存在，全新终端
        local res, err = red:hmset(ht, client_data)
        if res then --redis设置成功
            is_change = true
             ngx.log(ngx.WARN, "not exit")
        else
            state = false
            ngx.log(ngx.WARN, err)
        end
    end

    return state, is_change

end

--------------------------------funcs for client_bd_version
function client_bd_version(mid, lib_version, sd_version)
    -- local sql = [[UPDATE t_user SET sdlibver = ]] .. ndk.set_var.set_quote_pgsql_str(lib_version) ..
    --                 [[, sdver = ]] .. ndk.set_var.set_quote_pgsql_str(sd_version) .. [[ WHERE mid = ]] .. ndk.set_var.set_quote_pgsql_str(mid)
    -- if lib_version == 0 and sd_version ~= '' then
    --     sql = [[UPDATE t_user SET sdver = ]] .. ndk.set_var.set_quote_pgsql_str(sd_version) .. [[ WHERE mid = ]] .. ndk.set_var.set_quote_pgsql_str(mid)
    -- elseif lib_version ~= 0 and sd_version == '' then
    --     sql = [[UPDATE t_user SET sdlibver = ]] .. ndk.set_var.set_quote_pgsql_str(lib_version) .. [[ WHERE mid = ]] .. ndk.set_var.set_quote_pgsql_str(mid)
    -- elseif lib_version == 0 and sd_version == '' then
    --     return
    -- end
    -- local state, res = common.query_from_db(sql)
  if mid == nil then
      return false
  end

  local field_values = {}
  local redkey = string.format("client_update_%s", mid)

  if lib_version then
      field_values.main_ver = lib_version
  end

  if sd_version then
     field_values.virus_lib_ver = sd_version
  end

  if _G.next(field_values) ~= nil then
      red:hmset(redkey, field_values)
  end

  return true
end

function check_mid_valid(mid, data)
    local server_key =''
    local valid = 1
    local client_mid_key = config.CHECK_MID_VALID .. mid

    local res = red:hget(client_mid_key, config.KEY)  --正式key
    if res then
        if res ~= data.key then
          valid = 0
          ngx.log(ngx.ERR, 'check mid INVALID! client mid is ' .. mid .. ', post data is ' .. common.json_encode(data) .. '. server key is ' .. res)
        else
          server_key = res
        end
    else
        res = {null, null, null}
        local res= red:hmget('client_'..mid, 'report_ip', 'mac', 'computer_name')
        if res and (res[1] ~= data.report_ip or res[2] ~= data.mac or res[3] ~= data.computer_name) then
            math.randomseed(ngx.now())
            server_key = ngx.md5('mid' .. ngx.now() .. math.random())
            red:hset(client_mid_key, config.WAITING_KEY, server_key) --候补key，等待终端确认后生效
            ngx.log(ngx.ERR, 'MAKE SERVER **WAITING** KEY : ' .. server_key .. ', client mid is ' .. mid)
            red:expire(client_mid_key, 60 * 60) --候补key一小时失效，终端需要一小时内调用确认接口
        end
    end

    return server_key, valid
end

function ack_client_key(mid, data)
    local client_key = data.key
    local client_mid_key = config.CHECK_MID_VALID .. mid

    local res = red:hget(client_mid_key, config.WAITING_KEY)
    if res and res == client_key and data.error_code == 0 then --终端key和服务端候补key一致，候补key升级为正式key，并删除候补key
        red:hset(client_mid_key, config.KEY, client_key)
        red:expire(client_mid_key, 60 * 60 * 24) --正式key会24小时失效，防止ghost系统复制了key
        red:hdel(client_mid_key, config.WAITING_KEY)
        ngx.log(ngx.ERR, 'ACK CLIENT KEY SUCCESS! TRUN WAITING KEY TO REAL KEY! NOW SERVER KEY IS ' .. client_key .. ' for client mid ' .. mid)
        return true
    end
    ngx.log(ngx.ERR, 'ACK CLIENT KEY FAIL! client error code is ' .. data.error_code ..
                     ',error info is ' .. data.error_info .. ',CLIENT KEY IS ' .. client_key ..
                     ', THE WAITING KEY IS ' .. (res or 'empty string') .. ' for client mid ' .. mid)
    return false
end


local function merge_table( base, add , sub_merge)
  if nil == base or nil == add then
    return base
  end

  if not sub_merge then
    ngx.log(ngx.WARN, "merge base:")
    ngx.log(ngx.WARN, common.json_encode(base))
    ngx.log(ngx.WARN, "merge add:")
    ngx.log(ngx.WARN, common.json_encode(add))
  end

  for k,v in pairs(add) do
    if "table" == type(v) then
         if "table" ~= type(base[k]) then
              base[k] = {}
         end
         merge_table(base[k], v, true)
    else
         base[k] = v
    end
  end

  return base
end


function get_config(mid, args)
  local configs = {}
  local res, err = red:hmget("client_".. mid, "tpl_id", "gid", "type", "is_virtual", "cvm")
  if err then
    return nil, "1", err
  end

  ngx.log(ngx.INFO, "get tpl and group id:", common.json_encode(res))
  res = res or {}
  local conf_tpl_id = res[1]
  if not conf_tpl_id or  ngx.null == conf_tpl_id then
    conf_tpl_id = nil
  end

  local gid = res[2]
  if not gid or ngx.null == gid then
    gid = "1"
  end
  ngx.log(ngx.INFO, "get tpl id:", conf_tpl_id, " gid:", gid)

  -- 类型标识 0-win_c 1-win_s 2-linux_c 3-linux_s
  local t_type = args["_type"] or res[3]
  if not t_type or ngx.null == t_type or 0 == tonumber(t_type) then
    t_type = ""
  else
    t_type = "_type_"..t_type
  end
  args["_type"] = nil
  ngx.log(ngx.INFO, "get t_type id:", t_type, " gid:", gid, " tpl_id:", conf_tpl_id)

  local is_virtual = tonumber(res[4]) or 0

  local cvmaddr = (ngx.null ~= res[5]) and get_vim_server_addr(res[5]) or ""

  configs.client_attribute = {
                            is_virtual=is_virtual,
                            cvm =  cvmaddr
                          }

  for main_c, version in pairs(args) do
    -- get self config
    local json_res = red:hget("config_"..mid, main_c)
    local self_conf= common.json_decode(json_res) or {}
    ngx.log(ngx.INFO, "self:", main_c, " json_res:", json_res)

    -- get value from template/group
    json_res = nil
    if conf_tpl_id and "0" ~= conf_tpl_id then
      json_res = red:hget("config_tpl_"..conf_tpl_id, main_c)
      ngx.log(ngx.INFO, "get tpl result:", json_res)
    end
    if nil == json_res then
      json_res = common.get_data_with_cache({key="config_gid_"..gid..t_type .. main_c,
                                          exp_time_succ=1,
                                          exp_time_fail=-1},
                                  red.hget, red, "config_gid_"..gid..t_type, main_c)
    end
    ngx.log(ngx.INFO, "main_c:", main_c, " json_res:", json_res)

    -- copy value
    local res = common.json_decode(json_res) or {}
    if 1 == tonumber(self_conf.independent) then
      res = self_conf
      res.independent = nil
    else
      res = merge_table(res, self_conf)
    end

    if version.conf_ver ~= res.conf_ver then
      configs[main_c] = res
    end

    -- if 0 == #subs_c then
    --   configs[main_c] = res
    -- end
  end

  -- 如果没有声明获取任何module，从分组中获取所有默认配置
  if next(args) == nil then
    local res = red:hgetall("config_gid_"..gid..t_type)
    local count = type(res) == "table" and #res or 0
    for i=1,count,2 do
      local main_c = res[i]
      local value  = common.json_decode(res[i+1])
      configs[main_c] = value
    end
  end

  return configs
end

function get_vim_server_addr( mid )
  if nil == mid then
    return ""
  end

  local res, err = red:hget("client_".. mid, "cloud_svr_addr")
  if err then
    return ""
  end

  return res or ""
end


function get_connect_method( mid )
  local configs, err = red:hget("svr_system_config", "svr_system_setting")
  if nil == configs then
    return 0
  end

  configs = common.json_decode(configs)
  if nil == configs then
    return 0
  end

  return tonumber(configs.network.net_mode)
end

function get_online_client_count(  )
  local count = red:zcount("heartbeats", ngx.time(), "+inf")
  return count or 0
end

function get_online_client_mids( mids )
  local red = redis:new()
  red:init_pipeline()
  for i, mid in ipairs(mids) do
    red:zscore("heartbeats", mid)
  end

  local res_s, err = red:commit_pipeline()

  local data = {}
  for i, mid in ipairs(mids) do
    local score = res_s[i]
    if score and tonumber(score) >= ngx.time() then
      table.insert(data, mid)
    end
  end

  return data
end

function set_import_time_with_cache( import_time )
  red:hset('cloud_import_info', 'import_time', import_time)
  common.set_cache('cloud_import_info_import_time', import_time, 300)
end

function get_import_time_with_cache()
  local value = common.get_cache('cloud_import_info_import_time')
  if not value then
      value = red:hget('cloud_import_info', 'import_time') or 0
      common.set_cache('cloud_import_info_import_time', value, 300)
  end
  return value
end

function get_deploy_html(  )
  return red:get("deploy_page_html")
end

function set_deploy_html(html, timeout)
    local timeout = timeout or 100 -- default 100s
    return red:set("deploy_page_html",html, timeout)
end

function get_file_attribute( langid, os_bit, os_ver, file_path )
  -- 操作系统白名单
  local attributes = { sys = 0, replace = 0 }
  local valid_lang = { a2052 = 1, a1028 = 1, a3076 = 1, a1033 = 1, a1046 = 1 }
  if nil == valid_lang["a" .. langid] then
      return attributes
  end

  -- 64bit添加特殊前缀
  local key_bit = ""
  if 64 == tonumber(os_bit) then
      key_bit = [[64\]]
  end
  local key_buff1 = key_bit .. os_ver .. string.lower(file_path)
  local short_os_ver = ngx.re.match(os_ver, [[(\d+[.]\d+[.]\d+).]])
  local key_buff2 = key_bit .. short_os_ver[1] .. string.lower(file_path)

  -- 尝试到redis中命中
  local red = redis:new()
  red:init_pipeline()
  red:hget("file_attribute", string.sub(ngx.md5(key_buff1), 1, 16))
  red:hget("file_attribute", string.sub(ngx.md5(key_buff2), 1, 16))
  local res_s, err = red:commit_pipeline()
  ngx.log(ngx.WARN, "redis reply:", common.json_encode(res_s))
  if res_s and type(res_s) == "table" then
    for i,v in ipairs(res_s) do
      if v and #v > 0 then
        local flag = ngx.decode_base64(v)
        attributes.sys      = math.fmod (flag, 2)
        attributes.replace  = math.modf (flag/ 2)
        return attributes
      end
    end
  end


  return attributes
end

function system_repair_fetch( path )
  local path_md5 = ngx.md5(path)
  local file_path= ngx.config.prefix() .. "../download/system_repair_cache/" .. path_md5
  local file = io.open(file_path, "rb")
  ngx.log(ngx.WARN, nil == file, " check file exist :", file_path)
  if file then file:close() end
  if file == nil then
    return nil
  end

  return "system_repair_cache/" .. path_md5
end

-- 缓存文件的存在探测 如果存在则返回一个路径
function cache_file_fetch( path )
  -- body
  local file = io.open(path, "r")
  if file then
    file.close()
  end

  ngx.log(ngx.WARN, nil == file, " check file exist: ", path)

  if nil == file then
    return false
  else
    return true
  end

end

-- 通过磁盘文件的形式缓存
function cache_file( path, data )
  -- body
  local f, err = io.open(path, "wb")
  if f then
    f:write(data)
    f:close()
  else
    ngx.log(ngx.ERR, "open file failed : ", path, "err: ", err)
  end
end

function system_repair_store( path, data )
  local path_md5 = ngx.md5(path)
  local file_path= ngx.config.prefix() .. "../download/system_repair_cache/" .. path_md5
  -- save the data to disk
  local f = io.open(file_path, "w")
  ngx.log(ngx.WARN, "cache file to :", file_path)
  if f then
    f:write(data)
    f:close()
  else
    ngx.log(ngx.WARN, "open file fail :", err)
    return false, err
  end


  local res, err = red:hset("system_repiar_files", path_md5, path)
  if err then
    return false, err
  end

  return true
end

function server_is_www_enable(  )
  local res, err = red:hget("svr_system_config", "public_cloud_visitable")
  if res then
    return 1 == tonumber(res)
  end

  return true
end

function get_dns_address(  )
  local res, err = red:hget("svr_system_config", "svr_system_setting")
  if err then
    return nil, err
  end

  local settings = common.json_decode(res)
  -- settings.network.dns = "10.16.0.222"
  if not settings or not settings.network or not settings.network.dns then
    return nil, "system dns is not config"
  end

  return settings.network.dns
end

function blpop_rpt_voucher_id( voucher_id )
  local red = redis:new({timeout=10}) -- in seconds
  local result, err = red:blpop( "rpt_" .. voucher_id, 10*1000 )  -- in milliseconds
  if not result then
      return nil, err
  end
  return result
end

function get_latest_secevent( gid )
    local result, err = red:lrange( "sec_event_of_gid_" .. gid, 0, 16 )
    if not result then
        return nil, err
    end
    return result
end

function subscribe_secevent( gid )
  local red         = redis:new({timeout=1000})  -- in seconds
  local channel     = "sec_event_notify_of_gid_" .. gid
  local cbfunc, err = red:subscribe( channel )
  if not cbfunc then
      return nil, err
  end
  return cbfunc
end


-- 从redis获取一个域名对应的转发规则
function get_proxy_type( host, req_uri )
  local location = ""
  local m, _ = ngx.re.match(req_uri, [[/(\S*?)/]])
  if nil == m then
    location = string.sub(req_uri, 2, string.len(req_uri))   -- 去掉 location前的 “/”符号
  else
    location = m[1]
  end

  -- 在url级别的匹配找到了转发规则 返回
  local res, err = common.get_data_with_cache({key="cache_url_proxy_type" .. host .. "/" .. location,
                                          exp_time_succ=5,
                                          exp_time_fail=0.1},
                                        red.hget, red, "cache_url_proxy_type", host .. "/" .. location)
  -- ngx.log(ngx.WARN, "RES:", res, " err:", err)
  if err then
    return nil, err
  end
  if res then
    return res
  end

  -- 在域名级别的匹配找到了转发规则 返回
  res, err = common.get_data_with_cache({key="cache_host_proxy_type" .. host,
                                          exp_time_succ=5,
                                          exp_time_fail=0.1},
                                  red.hget, red, "cache_host_proxy_type", host)
  if err then
    return nil, err
  end
  if res then
    return res
  end

  -- 在请求级别的匹配找到了转发规则 返回
  res, err = common.get_data_with_cache({key="cache_location_proxy_type" .. location,
                                          exp_time_succ=5,
                                          exp_time_fail=0.1},
                                  red.hget, red, "cache_location_proxy_type", location)
  if err then
    return nil, err
  end

  return res  -- not found
end

-- 缓存代理请求的返回数据
function cache_proxy_req_response( key, val )
  local res, err = red:hset("cache_proxy_req_response", key, val)
  if err then
    return nil, err
  end

  return res
end

-- 读取缓存
function get_cache_of_proxy_req_response( key )
  local res, err = red:hget("cache_proxy_req_response", key)
  if err then
    return nil, err
  end

  return res
end

function get_cloud_engine_proxy()
    local ip = ''
    local port = ''

    local res = get_svr_system_setting()
    if not res then
        return ip, port
    end

    local settings = common.json_decode(res)
    if  settings and settings.cloud and settings.cloud.cloud_engine_box
        and settings.cloud.cloud_engine_box.ip and settings.cloud.cloud_engine_box.port then
        ip = settings.cloud.cloud_engine_box.ip
        port = settings.cloud.cloud_engine_box.port
    end

    return ip, port
end

function query_cloud_engine_switch()
    local switch = 0
    local res = get_svr_system_setting()
    if not res then
        return switch
    end

    local settings = common.json_decode(res)
    if settings and settings.cloud and settings.cloud.cloud_engine_box
       and settings.cloud.cloud_engine_box.enable then
        switch = tonumber(settings.cloud.cloud_engine_box.enable)
    end

    return switch
end

function nonpe_file_query_switch()
    --非PE文件是否去外网云查，并插入到file表中。默认关闭,只对PE文件进行查询
    local switch = 0
    local res = get_svr_system_setting()
    if not res then
        return switch
    end

    local settings = common.json_decode(res)
    if settings and settings.cloud and settings.cloud.pe_file_query_enable and
        tonumber(settings.cloud.pe_file_query_enable) == 0 then
        switch = 1
    end

    return switch
end

function not_return_true_level_to_client_switch()
    --是否返回终端真实的level值，而不仅仅是10，40，70。 默认是返回
    local switch = 0
    local res = get_svr_system_setting()
    if not res then
        return switch
    end

    local settings = common.json_decode(res)
    if settings and settings.cloud and settings.cloud.lower_file_level_enable then
        switch = tonumber(settings.cloud.lower_file_level_enable)
    end

    return switch
end

function proxy_query_switch()
    local switch = 0
    local res = get_svr_system_setting()
    if not res then
        return switch
    end

    local settings = common.json_decode(res)
    if settings and settings.cloud and settings.cloud.proxy_query_enable then
        switch = tonumber(settings.cloud.proxy_query_enable)
    end

    return switch
end

-- 私有云盒子qvm查询的开关
function query_qvm_cloud_engine_switch()
    local switch = 0
    local res = get_svr_system_setting()
    if not res then
        return switch
    end

    local settings = common.json_decode(res)
    if settings and settings.cloud and settings.cloud.cloud_engine_box
        and settings.cloud.cloud_engine_box.qvm_engine then
        switch = tonumber(settings.cloud.cloud_engine_box.qvm_engine)
    end

    return switch
end

function get_svr_system_setting()
    local res = common.get_cache(config.SYS_CONFIG)
    if not res then
        local err = nil
        res, err = red:hget("svr_system_config", "svr_system_setting")
        if res and not err then
            common.set_cache(config.SYS_CONFIG, res, 10) --10s timeout
        end
    end
    return res
end

function get_plat_time()
  -- do -- for test
  --   local mm = red:time()
  --   red:hset("hardware", "red_time", mm[1])
  --   red:hset("hardware", "cur_time", os.time())
  -- end

  local red = redis:new()
  red:init_pipeline()
  red:time()
  red:hget("hardware", "red_time")
  red:hget("hardware", "cur_time")
  red:hget("hardware", "last_guess_time")
  local res, err = red:commit_pipeline()

  if err then
    return nil, err
  end
  if #res < 3 then
    return nil, "redis is not working normal"
  end

  -- get cache time
  local redis_time    = tonumber(res[1][1] or 0)
  local last_red_time = tonumber(res[2] or 0)
  local last_cur_time = tonumber(res[3] or 0)
  local last_guess_time = tonumber(res[4] or 0)
  if 0 == redis_time or 0 == last_red_time or 0 == last_cur_time then
      return nil, "redis is not working normal"
  end

  -- 如果超过30s不更新
  if math.abs(redis_time - last_red_time) > 30 then
    -- 第一次开始猜测，比较大的可能是redis时间被修改
    if 0 == last_guess_time then
      ngx.log(ngx.WARN, "first guess")
      red:hset("hardware", "last_guess_time", redis_time)
      return last_cur_time
    end

    -- 从第一次猜测开始超过30s没有变化，时间同步失败
    if math.abs(redis_time - last_guess_time) > 30 then
      ngx.log(ngx.WARN, "back guess")
      return last_cur_time + (redis_time - last_red_time)
    end

    ngx.log(ngx.WARN, "default guess")
    return last_cur_time
  end

  -- 正常获取，清空上一次猜想标记
  if 0 ~= last_guess_time then
    red:hset("hardware", "last_guess_time", 0)
  end

  -- 服务器时间应该在2015.7.1~2065.7.1之间
  local min_time = os.time{year = 2015, month = 7, day = 1}
  local max_time = os.time{year = 2065, month = 7, day = 1}
  if last_cur_time < min_time or last_cur_time > max_time then
    ngx.log(ngx.WARN, "cur_time invalid")
    return nil, "cur_time invalid"
  end

  ngx.log(ngx.WARN, "get the correct time")
  return last_cur_time
end


local function _read_limit_param_from_cache(  )
  local svr_system_setting, err = common.get_data_with_cache({key="svr_system_config" .. "svr_system_setting",
                                          exp_time_succ=3,
                                          exp_time_fail=-1},
                                  red.hget, red, "svr_system_config", "svr_system_setting")
  if err then
    ngx.log(ngx.ERR, "get_data_with_cache failed:", err, ". use the default value")
    return nil, err
  end
  ngx.log(ngx.WARN, "svr_system_setting: ", svr_system_setting)

  svr_system_setting = common.json_decode(svr_system_setting)

  if not common.check_args_template(svr_system_setting, 
          {network={server_bandwith_limit={limit_time_list={}}}}) then
    ngx.log(ngx.ERR, "svr_system_setting format not valid. use the default value")
    return nil, "network limit config data invalid"
  end

  local limit_info= svr_system_setting.network.server_bandwith_limit
  for _, node in ipairs(limit_info.limit_time_list) do
    ngx.log(ngx.WARN, "type:", node.cycle_type, " week:", node.week, " cur_week:", os.date("%w", ngx.time()))
    if node.cycle_type == "day" or 
     (node.cycle_type == "week" and tostring(node.week) == os.date("%w", ngx.time())) then

      local need_limit = false
      local cur_time = os.date("%H:%M", ngx.time())
      

      if node.start_time <= node.end_time then    -- 当天时间段
        if cur_time >= node.start_time and cur_time <= node.end_time then
          need_limit = true 
        end
      elseif node.start_time > node.end_time then -- 隔天时间段
        if cur_time >= node.start_time or cur_time < node.end_time then
          need_limit = true
        end
      end

      if need_limit then
        ngx.log(ngx.WARN, "cur_time:", cur_time, " start_time:", node.start_time, " end_time:", node.end_time, " comp:", node.start_time <= node.end_time)
        return {tonumber(limit_info.max_speed) or 0, tonumber(limit_info.max_concurrent) or 0}
      end
    end
  end

  return {0, 0} -- there is not limit config
end


function get_net_limit_param()
  local limit_con, _ = common.get_data_with_cache({key="get_net_limit_param",
                                          exp_time_succ=5,
                                          exp_time_fail=0.1},
                                  _read_limit_param_from_cache)
  ngx.log(ngx.WARN, "limit conn:", common.json_encode(limit_con))
  if err or "table" ~= type(limit_con) then
    return 0, 0
  end

  return limit_con[1] or 0, limit_con[2] or 0
end


function get_gid( mid )
    local res, err = red:hget("client_" .. mid, "gid") or "1"
    if err then
        ngx.log(ngx.ERR,"get client_", mid, "error: ", err)
        return false, nil
    end
    res = tostring(res) or "1"
    return true, res
end

function get_upgrade_setting( )
    -- 读取优先升级的设置
    local upgrade_setting_json, err = common.get_cache("upgrade_setting")
    if upgrade_setting_json == nil then -- 缓存中读取失败
        upgrade_setting_json, err = red:get("priority_upgrade_setting")
        if err or upgrade_setting_json == nil then
            local err_log = err or "upgrade_setting_json is nil"
            ngx.log(ngx.ERR,"error in get priority_upgrade_setting from redis: " .. err_log)
            return false, nil
        end
        common.set_cache("upgrade_setting", upgrade_setting_json, 10) -- 缓存10秒
    end

    local upgrade_setting = common.json_decode(upgrade_setting_json)
    if type(upgrade_setting) ~= 'table' then
        ngx.log(ngx.ERR,"the priority_upgrade_setting value is :" .. upgrade_setting_json .. " after decode ,the type is: " .. type(upgrade_setting) .. ',not table')
        common.del_cache("upgrade_setting") -- 有错误，清空缓存
        return false, nil
    end

    for k, v in pairs(UPGRADE_TYPES) do  -- 将全网升级开关状态转为布尔类型，若不为1，则是关：false
        if nil ~= upgrade_setting[v] then
            if tostring(upgrade_setting[v]) == '1' then
                upgrade_setting[v] = true
            else
                upgrade_setting[v] = false
            end
        end
    end

    return true, upgrade_setting
end

function check_mid_in_group( mid, groups)
    -- groups 是优先升级分组的table ,如{1,2,3}
    -- 查询mid是否在group及其子分组中
    local ok, gid = get_gid( mid )
    if not ok then --读取gid失败
        return false
    end

    local mid_in_group = false
    for k, v in pairs(groups) do -- 遍历table查找
        if tostring(v) == gid then
            mid_in_group = true
            break
        end
    end
    return mid_in_group
end


function query_able_upgrade( mid )
    local ok, upgrade_setting = get_upgrade_setting( )
    if not ok then
        return false
    end

    local upgrade_enable = false

    for k, v in pairs(UPGRADE_TYPES) do
        upgrade_enable = upgrade_setting[v]
        if upgrade_enable == true then
            break
        end
    end

    if upgrade_enable ~= true then
        upgrade_enable = check_mid_in_group(mid, upgrade_setting.priority_groups or { } )
    end

    return upgrade_enable
end

function get_upload_log_router( module_name )
  local res, err = common.get_data_with_cache({key="upload_client_log_router" .. module_name,
                                          exp_time_succ=3,
                                          exp_time_fail=0.1},
                                  red.hget, red, "upload_client_log_router", module_name)
  if err then
    return nil, err
  end

  return res  -- not found
end


function get_access_ips(sets_name)
    local res, err = red:smembers(sets_name)
    return res, err
end


function get_access_flag()
    return common.get_data_with_cache({key="access_ip_flag",
                                exp_time_succ=10,
                                exp_time_fail=0.1},
                                red.get, red, "access_ip_flag")
end

function get_console_addr()
  -- body
  return common.get_data_with_cache({key="nginx_console_addr",
                              exp_time_succ=5,
                              exp_time_fail=1},
                              red.get, red, "nginx_console_addr")
end

-- 获取 客户端/服务端 通信协议设置
function get_trans_protocols()
    local default_protocol = {"1.0"}
    local res = get_svr_system_setting()
    ngx.log(ngx.WARN, "get_svr_system_setting:", type(res))
    if not res then
        return default_protocol
    end

    local settings = common.json_decode(res)
    if common.check_args_template(settings, {network={net_protocol={}}}) then
        return settings.network.net_protocol
    end

    return default_protocol
end

-- to prevent use of casual module global variables
getmetatable(lua.db_redis.db).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end
