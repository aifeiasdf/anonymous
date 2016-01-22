
local router = require 'resty.router'

local rt = router:new()

rt:map('/api/hello.json', 'src.hello')

rt:dispatch()