-- Copyright (C) 2014 wang "membphis" 
local common     = require "lua.comm.common"
local beanstalkd = require 'resty.beanstalkd'
local json   = require(require("ffi").os=="Windows" and "resty.dkjson" or "cjson")

local _M = {}

_M.VERSION = "0.01"

local mt = {
    __index = _M,
    -- to prevent use of casual module global variables
    __newindex = function(table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end,
}

function _M.new(self, opts)
    local bean, err = beanstalkd:new()
    if not bean then
        return nil, err
    end

    opts = opts or {}

    local main_conf = common.get_main_json_config()
    main_conf = json.decode(main_conf or "{}")

    local timeout = (opts.timeout and opts.timeout*1000) or 1000
    local ip      = main_conf.work_job.ip
    local port    = main_conf.work_job.port

    bean:set_timeout(1000)
    local ok, err = bean:connect(ip, port)
    if not ok then
        return nil, err
    end

    return setmetatable({bean = bean, timeout = timeout, 
                            ip= main_conf.work_job.ip, port = main_conf.work_job.port}, mt)
end

function _M.put(channel, data, timeout)
    if nil == data then
        return false, "the data is nil"
    end

    local bean, err = beanstalkd:new()
    if not bean then
        return false, err
    end

    timeout = timeout or 1000
    bean:set_timeout(timeout)

    local main_conf = common.get_main_json_config()
    main_conf = json.decode(main_conf or "{}")

    local ok, err = bean:connect(main_conf.work_job.ip, main_conf.work_job.port)
    if not ok then
        return false, err
    end

    -- use tube
    local ok, err = bean:use(channel)
    if not ok then
        return false, err
    end

    -- put job
    local id, err = bean:put(data)
    if not id then
        return false, err
    end

    bean:set_keepalive(5000, 100)

    return true , nil , id
end

function _M.reserve(self, channel)
    local bean = self.bean
    bean:set_timeout(self.timeout)

    -- waitch
    local ok, err = bean:watch(channel)
    if not ok then
        return nil, nil, err
    end

    -- reserve
    local id, data = bean:reserve()
    if not id then
        return nil, nil, data
    end

    return id, data, nil
end

function _M.delete(self, id)
    local bean = self.bean
    bean:set_timeout(self.timeout)

    -- waitch
    local ok, err = bean:delete(id)
    if not ok then
        return false
    end

    return true
end


function _M.bury(self, id)
    local bean = self.bean
    bean:set_timeout(self.timeout)

    -- waitch
    local ok, err = bean:bury(id)
    if not ok then
        return false
    end

    return true
end

function _M.close(self)
    local bean = self.bean
    bean:close()
    self.bean = nil

    return true
end

function _M.keepalive(self)
    local bean = self.bean

    bean:set_keepalive(5000, 100)
    self.bean = nil

    return true
end

return _M