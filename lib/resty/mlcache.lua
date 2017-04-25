-- vim: st=4 sts=4 sw=4 et:

local ffi        = require "ffi"
local cjson      = require "cjson.safe"
local lrucache   = require "resty.lrucache"
local resty_lock = require "resty.lock"


local type         = type
local pcall        = pcall
local error        = error
local shared       = ngx.shared
local ffi_str      = ffi.string
local ffi_cast     = ffi.cast
local setmetatable = setmetatable


ffi.cdef [[
    struct shm_string_table {
        unsigned int    serialized;
        unsigned int    len;
        unsigned char  *data;
    };
]]


local marshallers
local unmarshallers


local LOCK_KEY_PREFIX         = "lock:"
local CACHE_MISS_SENTINEL_SHM = "lua-resty-mlcache:miss"
local CACHE_MISS_SENTINEL_LRU = {}


do
    local str_const              = ffi.typeof("unsigned char *")
    local shm_string_table_const = ffi.typeof("const struct shm_string_table*")
    local shm_string_table_size  = ffi.sizeof("struct shm_string_table")
    local shm_string_table_cdata = ffi.new("struct shm_string_table")


    marshallers = {
        string_table = function(str, serialized)
            shm_string_table_cdata.serialized = serialized and 1 or 0
            shm_string_table_cdata.len        = #str
            shm_string_table_cdata.data       = ffi_cast(str_const, str)

            return ffi_str(shm_string_table_cdata, shm_string_table_size)
        end
    }


    unmarshallers = {
        string_table = function(encoded)
            local shm_string_table = ffi_cast(shm_string_table_const, encoded)

            return ffi_str(shm_string_table.data, shm_string_table.len),
                   shm_string_table.serialized == 1
        end
    }
end


local _M = {}
local mt = { __index = _M }


function _M.new(shm, opts)
    if type(shm) ~= "string" then
        return error("shm must be a string")
    end

    if opts then
        if type(opts) ~= "table" then
            return error("opts must be a table")
        end

        if opts.lru_size and type(opts.lru_size) ~= "number" then
            return error("opts.lru_size must be a number")
        end

        if opts.ttl and type(opts.ttl) ~= "number" then
            return error("opts.ttl must be a number")
        end

        if opts.neg_ttl and type(opts.neg_ttl) ~= "number" then
            return error("opts.neg_ttl must be a number")
        end

        if opts.ipc_shm and type(opts.ipc_shm) ~= "string" then
            return error("opts.ipc_shm must be a string")
        end

    else
        opts = {}
    end

    local dict = shared[shm]
    if not dict then
        return nil, "no such lua_shared_dict: " .. shm
    end

    local self  = {
        lru     = lrucache.new(opts.lru_size or 100),
        dict    = dict,
        shm     = shm,
        ttl     = opts.ttl     or 30,
        neg_ttl = opts.neg_ttl or 5
    }

    if opts.ipc_shm then
        local mlcache_ipc = require "resty.mlcache.ipc"

        local ipc, err = mlcache_ipc.new(opts.ipc_shm, opts.debug)
        if not ipc then
            return nil, "could not instanciate mlcache.ipc: " .. err
        end

        ipc:subscribe("invalidations", function(key)
            self.lru:delete(key)
        end)

        self.ipc = ipc
    end

    return setmetatable(self, mt)
end


local function set_lru(self, key, value, ttl)
    self.lru:set(key, value, ttl)

    return value
end


local function shmlru_get(self, key, ttl, neg_ttl)
    local v, err = self.dict:get(key)
    if err then
        return nil, "could not read from lua_shared_dict: " .. err
    end

    if v ~= nil then
        if type(v) ~= "string" then
            return set_lru(self, key, v, ttl)
        end

        if v == CACHE_MISS_SENTINEL_SHM then
            return set_lru(self, key, CACHE_MISS_SENTINEL_LRU, neg_ttl)
        end

        local is_table

        v, is_table = unmarshallers.string_table(v)

        if is_table then
            -- was a table, must decode
            local decoded, err = cjson.decode(v)
            if not decoded then
                return nil, "could not decode value: " .. err
            end

            v = decoded
        end

        return set_lru(self, key, v, ttl)
    end
end


local function shmlru_set(self, key, value, ttl, neg_ttl)
    if value == nil then
        -- we need to cache that this was a miss, and ensure cache hit for a
        -- nil value
        local ok, err = self.dict:set(key, CACHE_MISS_SENTINEL_SHM, neg_ttl)
        if not ok then
            return nil, "could not write to lua_shared_dict: " .. err
        end

        -- set our own worker's LRU cache

        self.lru:set(key, CACHE_MISS_SENTINEL_LRU, neg_ttl)

        return nil
    end

    -- encode tables as strings with a 'serialized' flag

    local shm_marshalled
    local value_type = type(value)

    if value_type == "string" then
        shm_marshalled = marshallers.string_table(value)

    elseif value_type == "table" then
        -- res was a table, needs encoding
        local encoded, err = cjson.encode(value)
        if not encoded then
            return nil, "could not encode callback result: " .. err
        end

        shm_marshalled = marshallers.string_table(encoded, true)

    else
        shm_marshalled = value
    end

    -- cache value in shm for currently-locked workers

    local ok, err = self.dict:set(key, shm_marshalled, ttl)
    if not ok then
        return nil, "could not write to lua_shared_dict: " .. err
    end

    -- set our own worker's LRU cache

    return set_lru(self, key, value, ttl)
end


local function unlock_and_ret(lock, res, err)
    local ok, lerr = lock:unlock()
    if not ok then
        return nil, "could not unlock callback: " .. lerr
    end

    return res, err
end


function _M:get(key, opts, cb, ...)
    if type(key) ~= "string" then
        return error("key must be a string")
    end

    if type(cb) ~= "function" then
        return error("callback must be a function")
    end

    -- opts validation

    local ttl
    local neg_ttl

    if opts then
        if type(opts) ~= "table" then
            return error("opts must be a table")
        end

        if opts.ttl and type(opts.ttl) ~= "number" then
            return error("opts.ttl must be a number")
        end

        if opts.neg_ttl and type(opts.neg_ttl) ~= "number" then
            return error("opts.neg_ttl must be a number")
        end

        ttl     = opts.ttl
        neg_ttl = opts.neg_ttl
    end

    if not ttl then
        ttl = self.ttl
    end

    if not neg_ttl then
        neg_ttl = self.neg_ttl
    end

    -- worker LRU cache retrieval

    local data = self.lru:get(key)
    if data == CACHE_MISS_SENTINEL_LRU then
        return nil
    end

    if data ~= nil then
        return data
    end

    -- not in worker's LRU cache, need shm lookup

    local err
    data, err = shmlru_get(self, key, ttl, neg_ttl)
    if err then
        return nil, err
    end

    if data == CACHE_MISS_SENTINEL_LRU then
        return nil
    end

    if data ~= nil then
        return data
    end

    -- not in shm either
    -- single worker must execute the callback

    local lock, err = resty_lock:new(self.shm)
    if not lock then
        return nil, "could not create lock: " .. err
    end

    local elapsed, err = lock:lock(LOCK_KEY_PREFIX .. key)
    if not elapsed then
        return nil, "could not aquire callback lock: " .. err
    end

    -- check for another worker's success at running the callback

    data = shmlru_get(self, key, ttl, neg_ttl)
    if data then
        return unlock_and_ret(lock, data)
    end

    -- still not in shm, we are responsible for running the callback

    local ok, err = pcall(cb, ...)
    if not ok then
        return unlock_and_ret(lock, nil, "callback threw an error: " .. err)
    end

    local value, err = shmlru_set(self, key, err, ttl, neg_ttl)
    if err then
        return unlock_and_ret(lock, nil, err)
    end

    return unlock_and_ret(lock, value)
end


function _M:delete(key)
    if type(key) ~= "string" then
        return error("key must be a string")
    end

    if not self.ipc then
        return nil, "no ipc to propagate deletion"
    end

    self.lru:delete(key)

    local ok, err = self.dict:delete(key)
    if not ok then
        return nil, "could not delete from shm: " .. err
    end

    local ok, err = self.ipc:broadcast("invalidations", key)
    if not ok then
        return nil, "could not broadcast deletion: " .. err
    end

    return true
end


function _M:update()
    if not self.ipc then
        return nil, "no ipc to update from"
    end

    local ok, err = self.ipc:poll()
    if not ok then
        return nil, "could not poll ipc events: " .. err
    end

    return true
end


return _M
