local common    = require "lua.comm.common"
local redis_c   = require "resty.redis"
local json      = require(require("ffi").os=="Windows" and "resty.dkjson" or "cjson")
local win_platform = require("ffi").os == "Windows"


local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function (narr, nrec) return {} end
end

local _M = new_tab(0, 155)
_M._VERSION = '0.01'

local commands = {
    "append",            "auth",              "bgrewriteaof",
    "bgsave",            "bitcount",          "bitop",
    "blpop",             "brpop",
    "brpoplpush",        "client",            "config",
    "dbsize",
    "debug",             "decr",              "decrby",
    "del",               "discard",           "dump",
    "echo",
    "eval",              "exec",              "exists",
    "expire",            "expireat",          --[["flushall",]]
    --[["flushdb", ]]    "get",               "getbit",
    "getrange",          "getset",            "hdel",
    "hexists",           "hget",              "hgetall",
    "hincrby",           "hincrbyfloat",      "hkeys",
    "hlen",
    "hmget",              "hmset",      "hscan",
    "hset",
    "hsetnx",            "hvals",             "incr",
    "incrby",            "incrbyfloat",       "info",
    "keys",
    "lastsave",          "lindex",            "linsert",
    "llen",              "lpop",              "lpush",
    "lpushx",            "lrange",            "lrem",
    "lset",              "ltrim",             "mget",
    "migrate",
    "monitor",           "move",              "mset",
    "msetnx",            "multi",             "object",
    "persist",           "pexpire",           "pexpireat",
    "ping",              "psetex",            "psubscribe",
    "pttl",
    "publish",      --[[ "punsubscribe", ]]   "pubsub",
    "quit",
    "randomkey",         "rename",            "renamenx",
    "restore",
    "rpop",              "rpoplpush",         "rpush",
    "rpushx",            "sadd",              "save",
    "scan",              "scard",             "script",
    "sdiff",             "sdiffstore",
    "select",            "set",               "setbit",
    "setex",             "setnx",             "setrange",
    "shutdown",          "sinter",            "sinterstore",
    "sismember",         "slaveof",           "slowlog",
    "smembers",          "smove",             "sort",
    "spop",              "srandmember",       "srem",
    "sscan",
    "strlen",       --[[ "subscribe",  ]]     "sunion",
    "sunionstore",       "sync",              "time",
    "ttl",
    "type",         --[[ "unsubscribe", ]]    "unwatch",
    "watch",             "zadd",              "zcard",
    "zcount",            "zincrby",           "zinterstore",
    "zrange",            "zrangebyscore",     "zrank",
    "zrem",              "zremrangebyrank",   "zremrangebyscore",
    "zrevrange",         "zrevrangebyscore",  "zrevrank",
    "zscan",
    "zscore",            "zunionstore",       "evalsha"
}

local mt = { __index = _M }

local function is_redis_null( res )
    if type(res) == "table" then
        for k,v in pairs(res) do
            if v ~= ngx.null then
                return false
            end
        end
        return true
    elseif res == ngx.null then
        return true
    elseif res == nil then
        return true
    end

    return false
end

function _M.connect_mod( self, redis )

    local db_json = common.get_main_json_config()
    local db_config = json.decode(db_json or "{}")
    local db_info = db_config.redis_conn or {}
    
    redis:set_timeout(self.timeout)
    ngx.log(ngx.NOTICE, "redis:connect_mod")
    return redis:connect(db_info.ip, db_info.port)
end


function _M.set_keepalive_mod( redis )
    ngx.log(ngx.NOTICE, "redis:set_keepalive")
    return redis:set_keepalive(60*1000, 50) -- put it into the connection pool of size 50, with 10 seconds max idle time
end

function _M.init_pipeline( self )
    self._reqs = {}
end

function _M._commit_pipeline(self)
    local reqs = self._reqs

    if nil == reqs or 0 == #reqs then
        self._reqs = nil
        return {}, "no pipeline"
    else
        self._reqs = nil
    end

    local redis, err = redis_c:new()
    if not redis then
        return nil, err
    end

    local ok, err = self:connect_mod(redis)
    if not ok then
        return {}, err
    end

    redis:init_pipeline()
    for _, vals in ipairs(reqs) do
        local fun = redis[vals[1]]
        table.remove(vals , 1)

        fun(redis, unpack(vals))
    end

    local results, err = redis:commit_pipeline()
    if not results or err then
        return {}, err
    end

    if is_redis_null(results) then
        results = {}
        ngx.log(ngx.WARN, "is null")
    end
    -- table.remove (results , 1)
    
    self.set_keepalive_mod(redis)

    for i,value in ipairs(results) do
        if is_redis_null(value) then
            results[i] = nil
        end
    end

    return results, err
end

function _M.commit_pipeline( self )
    local res, err = self:limit_paralles(self._commit_pipeline, self)
    self._reqs = nil
    return res, err
end

function _M.subscribe( self, channel )
    local redis, err = redis_c:new()
    if not redis then
        return nil, err
    end

    local ok, err = self:connect_mod(redis)
    if not ok or err then
        return nil, err
    end

    local res, err = redis:subscribe(channel)
    if not res then
        return nil, err
    end

    local function do_read_func ( do_read )
        if do_read == nil or do_read == true then
            res, err = redis:read_reply()
            if not res then
                return nil, err
            end
            return res
        end

        redis:unsubscribe(channel)
        self.set_keepalive_mod(redis)
        return 
    end
    
    return do_read_func
end

function _M.do_command(self, cmd, ... )
    if self._reqs then
        table.insert(self._reqs, {cmd, ...})
        return
    end

    local redis, err = redis_c:new()
    if not redis then
        return nil, err
    end

    local ok, err = self:connect_mod(redis)
    if not ok or err then
        return nil, err
    end

    local fun = redis[cmd]
    local result, err = fun(redis, ...)
    if not result or err then
        -- ngx.log(ngx.ERR, "pipeline result:", result, " err:", err)
        return nil, err
    end

    if is_redis_null(result) then
        result = nil
    end
    
    self.set_keepalive_mod(redis)

    return result, err
end

function _M.limit_paralles( self, fn_command, ... )
    -- for linux, the limit do not need
    if not win_platform then
        return fn_command(...)
    end

    local ngx_share    = ngx.shared.ngx_redis
    local expired_time = ngx.now() + 1 -- dalay 10seconds
    local sleep_time   = 0.001
    local max_parallel = 80
    local redis_expire = 10 -- 10seconds for expire, redis timeout is 10sec now
    local keys = nil

    ngx_share:add("redis_index", 0)

    while true do
        if ngx.now() > expired_time then
          ngx.log(ngx.NOTICE, "waited too long for execute redis command")
          return nil, "waiting too long"
        end

        keys = ngx_share:get_keys(0)
        local count_key = #keys

        if count_key >= max_parallel then
            ngx.log(ngx.DEBUG, "redis key is full, hold on")
            sleep_time = sleep_time * 2
            ngx.sleep(sleep_time)
        else
            local new_index = ngx_share:incr("redis_index", 1)
            local succ, err = ngx_share:set(new_index, true, redis_expire)
            if not succ then
                ngx.log(ngx.DEBUG, "redis error:", err)
                return nil, err
            end
            local result, err = fn_command(...)
            ngx_share:delete(new_index)
            return result, err
        end
    end

    return nil, "nginx is existing"
end

function _M.new(self, opts)
    opts = opts or {}
    local timeout = (opts.timeout and opts.timeout * 1000 * 10) or 1000 * 10    -- default 10sec timeout
    local db_index= opts.db_index or 0

    
    for i = 1, #commands do
        local cmd = commands[i]
        _M[cmd] = 
            function (self, ...)
                return self:limit_paralles(self.do_command, self, cmd, ...)
            end
    end

    return setmetatable({ timeout = timeout, db_index = db_index, _reqs = nil }, mt)
end


return _M