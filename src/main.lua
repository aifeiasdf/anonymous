local router = require 'resty.router'

local cache = ngx.shared.cache_ngx


local redis = require "src.comm.redis-plus"
local red = redis:new()


local function get_code(opt)
    -- body
    local s, err = red:get("aifei")
    return s
end

local opt = { func = get_code }

local rt = router:new(cache, opt)
-- local rt = router:new()

rt:map('/api/hello.json', 'src.hello')

rt:reload('/api/update.json')


rt:dispatch()