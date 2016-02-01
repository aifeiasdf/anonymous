local router = require 'resty.router'

--  如果需要启动代码动态加载 开启注释中的代码 并对 get_code_chunk 进行编码 
-- local cache = ngx.shared.cache_ngx
-- local redis = require "src.comm.redis-plus"
-- local red = redis:new()

-- local function get_code_chunk(opt)
--     -- body
--     local code_chunk, err = red:get("some_key")
--     return code_chunk
-- end

-- local opt = { func = get_code_chunk }

-- local rt = router:new(cache, opt)

local rt = router:new()

rt:map('/api/hello.json', 'src.hello')

rt:reload('/api/update.json')


rt:dispatch()