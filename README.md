# anonymous
api server framwork

anonymous 是一个用OpenResty搭建的 api server 工程

首先你需要安装OpenResty[http://www.openresty.org]

在启动nginx的时候 使用 -p 参数指定 anonymous 的路径

sudo ./nginx -p /Users/name/workspace/anonymous -c conf/nginx.conf

工程的默认入口是一个 resty-router[https://github.com/aifeiasdf/lua-resty-router]


main.lua
=========================
```lua
local router = require 'resty.router'

local rt = router:new()

rt:map('/api/hello.json', 'src.hello')
rt:map('/api/any.json', 'src.any')

rt:dispatch()
```


src.hello
=========================
```lua
local _M = { _VERSION = '0.01' }

function _M.run( ... )
    -- body
    ngx.say('hello my awesome anonymous')
end

return _M
```

为方便后期的代码热加载，所有目标 lua 都需要注册上版本信息， 如上 local _M = { _VERSION = '0.01' }


在 resty 和 src common 文件夹下有许多好用的resty包或者封装好的函数等你去发现。

TODO LIST
==================
1.让路由器支持代码热加载

2.添加src common 下函数的使用说明



OpenResty 下载和安装参考
====================
http://openresty.org/





