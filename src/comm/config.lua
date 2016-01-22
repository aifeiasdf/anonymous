module("lua.comm.config", package.seeall)

WHITE = 10
HIGH_WHITE = 20
GRAY_WHITE = 30
GRAY = 40
LOW_S = 50 -- low suspicious
HIGH_S = 60 -- high suspicious
BLACK = 70

LEAK_DOWNLOAD_FAIL = 12
LEAK_REPIRE_OK = 0
LEAK_REPIRED = 1

HOST_WHITE = 1
HOST_GRAY = 0
HOST_BLACK = -1


NGX_DIC_NETSTAT = '#?_netstat#'
NGX_DIC_SQL		= '#?_SQL#'
NGX_DIC_NOSQL   = '#?_NOSQL#'
NGX_DIC_CONFIG  = '#?_CONFIG#'

--redis
FILE = 'file'
CLIENT = 'client'
TASK = 'task'
NGX2PHP = 'ngx2php'
NGX2TUBES = {
    csi="ngx2csi",  -- Client Security Inspect
}
PHP2NGX = 'php2ngx'

--revoke
LEVEL_CHANGE_LOG = 'level_change_log'
LEVEL_CHANGE = "level_change"
LEVEL_CHANGE_MAX_ID = "level_change_max_id"
LEVEL_CHANGE_ADMIN = "level_change_admin"
LEVEL_CHANGE_MAX_ID_ADMIN = "level_change_max_id_admin"

CLOUD_QUERY_REDIS_MAX = 100000  --redis hash proxy_query  max

REVOKE_CLEAN_MAX = 30000

-- offline tool
OFFLINE_TOOL_SIGN_MAGIC = '~$xYh^_^Ko%&~'


REVOKE_TYPE_CLOUD = 1
REVOKE_TYPE_ADMIN = 2

MD5_LEN = 32
SHA1_LEN = 40

SYS_CONFIG = 'svr_system_config#svr_system_setting'

CHECK_MID_VALID = 'check_mid_valid_'
KEY = 'key'
WAITING_KEY = 'waiting_key'

MAIN_VER_UPGRADE = 'main_ver_upgrade'
VIRUS_LIBS_UPGRADE = 'virus_libs_upgrade'
LEAK_LIBS_UPGRADE = 'leak_libs_upgrade'