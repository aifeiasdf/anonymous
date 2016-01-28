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

function _M.dispatch( self )
    -- body
    local uri = var.uri
    local router = self.router
    local shared = self.shared
    local opt    = self.opt

    if nil == router[uri] then
        return self.default(self)        
    end

    if not shared or not opt then
        return (require (router[uri])).run()
    end

    -- version replace
    local package = (require (router[uri]))

    if package._VERSION == shared:get(router[uri]) then
        return package.run()
    else
        local code_chunk = opt.func(opt)
        if pcall(loadstring(code_chunk)) then
            package.loaded[router[uri]] = loadstring(code_chunk) -- maybe wrong here
            return (require (router[uri])).run()
        else 
            error("loadstring error, wrong lua code loaded")
        end
    end
end

function _M.update( self, uri, module, version )
    -- body
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


