local ffi = require "ffi"
local ffi_new = ffi.new
local ffi_cast = ffi.cast
local ffi_gc = ffi.gc
local ffi_copy = ffi.copy
local ffi_str = ffi.string
local C =   (ffi.os=="Windows" and ffi.load'libeay32' or ffi.C)
local setmetatable = setmetatable


local _M = { _VERSION = '0.09' }

local mt = { __index = _M }


local PADDING = {
    RSA_PKCS1_PADDING = 1,  -- RSA_size - 11
    RSA_SSLV23_PADDING = 2, -- RSA_size - 11
    RSA_NO_PADDING = 3,     -- RSA_size
    RSA_PKCS1_OAEP_PADDING = 4, -- RSA_size - 42
}
_M.PADDING = PADDING


ffi.cdef[[
typedef struct bio_st BIO;
typedef struct bio_method_st BIO_METHOD;
BIO_METHOD *BIO_s_mem(void);
BIO * BIO_new(BIO_METHOD *type);
int	BIO_puts(BIO *bp,const char *buf);
void BIO_vfree(BIO *a);

typedef struct rsa_st RSA;
int RSA_size(const RSA *rsa);
void RSA_free(RSA *rsa);
typedef int pem_password_cb(char *buf, int size, int rwflag, void *userdata);
RSA * PEM_read_bio_RSAPrivateKey(BIO *bp, RSA **rsa, pem_password_cb *cb,
								void *u);
RSA * PEM_read_bio_RSAPublicKey(BIO *bp, RSA **rsa, pem_password_cb *cb,
                                void *u);

int	RSA_public_encrypt(int flen, const unsigned char *from,
		unsigned char *to, RSA *rsa,int padding);
int	RSA_private_decrypt(int flen, const unsigned char *from,
		unsigned char *to, RSA *rsa,int padding);

int RSA_sign(int type, const unsigned char *m, unsigned int m_len,
        unsigned char *sigret, unsigned int *siglen, RSA *rsa);
int RSA_verify(int type, const unsigned char *m, unsigned int m_len,
        unsigned char *sigbuf, unsigned int siglen, RSA *rsa);

unsigned long ERR_get_error(void);
const char * ERR_reason_error_string(unsigned long e);
]]


local function err()
    local code = C.ERR_get_error()

    local err = C.ERR_reason_error_string(code)

    return nil, ffi_str(err)
end


function _M.new(self, key, is_pub, padding, password)
    local bio_method = C.BIO_s_mem()
    local bio = C.BIO_new(bio_method)
    ffi_gc(bio, C.BIO_vfree)

    local len = C.BIO_puts(bio, key)
    if len < 0 then
        return err()
    end

    local pass
    if password then
        local pl = #password
        pass = ffi_new("unsigned char[?]", pl + 1)
        ffi_copy(pass, password, pl)
    end

    local func = is_pub and C.PEM_read_bio_RSAPublicKey
                        or C.PEM_read_bio_RSAPrivateKey

    local rsa = func(bio, nil, nil, pass)
    if ffi_cast("void *", rsa) == nil then
        return err()
    end
    ffi_gc(rsa, C.RSA_free)

    local size = C.RSA_size(rsa)
    return setmetatable({
            public_rsa = is_pub and rsa,
            private_rsa = (not is_pub) and rsa,
            size = size,
            buf = ffi_new("unsigned char[?]", size),
            padding = padding or PADDING.RSA_PKCS1_PADDING
        }, mt)
end


function _M.decrypt(self, str)
    local rsa = self.private_rsa
    if not rsa then
        return nil, "not inited for decrypt"
    end

    local buf = self.buf
    local len = C.RSA_private_decrypt(#str, str, buf, rsa, self.padding)
    if len == -1 then
        return err()
    end

    return ffi_str(buf, len)
end


function _M.encrypt(self, str)
    local rsa = self.public_rsa
    if not rsa then
        return nil, "not inited for encrypt"
    end

    local buf = self.buf
    local len = C.RSA_public_encrypt(#str, str, buf, rsa, self.padding)
    if len == -1 then
        return err()
    end

    return ffi_str(buf, len)
end


function _M.sign(self, str, algorithm)
    local rsa = self.private_rsa
    if not rsa then
        return nil, "not inited for sign"
    end

    local typ = algorithm or 8
    local buf = self.buf
    local len = ffi_new("unsigned int[1]")
    local r = C.RSA_sign(typ, str, #str, buf, len, rsa)
    if r == 0 then
        return err()
    end

    return ffi_str(buf, len[0])
end


function _M.verify(self, str, sig, algorithm)
    local rsa = self.public_rsa
    if not rsa then
        return nil, "not inited for verify"
    end

    local typ = algorithm or 8
    local buf = self.buf
    ffi_copy(buf, sig, #sig)
    local r = C.RSA_verify(typ, str, #str, buf, #sig, rsa)
    if r == 0 then
        return err()
    end

    return true
end


return _M
