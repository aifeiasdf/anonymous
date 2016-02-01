local router = require 'resty.router'

--  如果需要启动代码动态加载 开启注释中的代码 并对 get_code_chunk 进行编码 
-- local cache = ngx.shared.cache_ngx
-- local redis = require "src.comm.redis-plus"
-- local red = redis:new()

-- local function get_code_chunk(opt, mod)
--     -- body
--     -- 可以通过其他任何 redis 操作或者数据库操作去获取相应的代码 
--     local code_chunk, err = red:hget("some_key", mod)
--     return code_chunk
-- end

-- local opt = { func = get_code_chunk }

-- local rt = router:new(cache, opt)

local rt = router:new()

rt:map('/api/hello.json', 'src.hello')

-- rt:reload('/api/update.json')

rt:dispatch()