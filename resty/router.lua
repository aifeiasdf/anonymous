local common       = require "src.comm.common"
local setmetatable = setmetatable
local var          = ngx.var

local _M = { _VERSION = '0.01' }

local mt = { __index = _M }

function _M.new( self, shared, opt )
     -- body
     return setmetatable({router = {}, shared = shared, opt = opt}, mt)
end 

local function default( self )
    -- body do something
    return ngx.exit(ngx.HTTP_NOT_FOUND)
end

_M.default = default

local function _reload( self )
    -- body
    ngx.req.read_body()
    
    local mod_map = common.json_decode(ngx.req.get_body_data())

    if not mod_map then
        return ngx.log(ngx.ERR, "post wrong json format body.")
    end

    local shared = self.shared‘

    for mod, version in pairs(mod_map) do
        shared:set(mod, version)
    end

end

function _M.dispatch( self )
    -- body
    local uri        = var.uri
    local router     = self.router
    local shared     = self.shared
    local opt        = self.opt
    local reload_uri = self.reload_uri

    if reload_uri == uri then
        return _reload(self)
    end

    if nil == router[uri] then
        return self.default(self)        
    end

    -- 缓存、opt和重载uri地址
    if not shared or not opt or self.reload_uri then  
        local tmp = require (router[uri])
        return tmp.run()
    end

    -- version replace
    local _module   = router[uri]
    local _pack     = (require (_module))
    local _ver, err = shared:get(_module)

    if err then
        ngx.log(ngx.WARN, "get moduel ", _module, " version from shared err, err = ", err) 
    end

    ngx.log(ngx.ERR, _ver)
    if not _ver or _pack._VERSION == _ver then
        return _pack.run()
    else
        local code_chunk = opt.func(opt, _module)
        if pcall(loadstring(code_chunk)) then
            package.loaded[_module] = loadstring(code_chunk)()
            return (require (_module)).run()
        else 
            error("loadstring error, wrong lua code loaded")
        end
    end
end

function _M.reload( self, uri)
    self.reload_uri = uri
end

function _M.map( self, uri, pack )
    -- body
    local router = self.router

    if nil == router then
        error('router internal error') -- can not happen
    end

    router[uri] = pack  -- assign or cover
end

function _M.setdefault( self, func )
    -- body
    self.default = func
end

return _M


