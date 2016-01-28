
local router = require 'resty.router'

local _M = { _VERSION = '0.0.1' }

router:map('/api/hello.json', 'src.hello')

return _M