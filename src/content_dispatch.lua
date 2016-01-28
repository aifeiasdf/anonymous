
local router = require 'resty.router'

local cache = ngx.shared.cache_ngx

local function get_code(opt)
    -- body
    return [[

        local _M = { _VERSION = '0.02' }

        function _M.run( ... )
            -- body
            ngx.say('reload success')
        end

        return _M
    ]]
end

local rt = router:new(cache, opt)

local opt = { func = get_code }

rt:map('/api/hello.json', 'src.hello', opt)

rt:reload('/api/update.json')

rt:dispatch()