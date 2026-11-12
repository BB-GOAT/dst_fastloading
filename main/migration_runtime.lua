local _G = GLOBAL

-- modmain 早于 gamelogic 加载，等世界初始化后再安装原版迁移入口
AddSimPostInit(function()
    local required = {
        "MigrateToServer", "SimReset", "SerializeUserSession", "OnNetworkDisconnect",
        "IsMigrating", "DeactivateWorld", "DoRestart", "GetTimeRealSeconds", "InGamePlay",
    }
    for _, name in ipairs(required) do
        if type(_G.rawget(_G, name)) ~= "function" then
            print("[快速加载][快速穿越世界] 未安装：缺少原版入口 " .. name)
            return
        end
    end

    local ConnectingToGamePopup = require "screens/redux/connectingtogamepopup"
    local active
    local old_migrate = _G.MigrateToServer
    local old_reset = _G.SimReset
    local old_serialize = _G.SerializeUserSession
    local old_disconnect = _G.OnNetworkDisconnect
    local old_is_migrating = _G.IsMigrating
    local old_restart = _G.DoRestart

    local function Log(event, context)
        local elapsed = context and _G.GetTimeRealSeconds() - context.begin_time or 0
        print(string.format("[快速加载][快速穿越世界] %s elapsed=%.2fs", event, elapsed))
    end

    local function BeginConnection(context)
        local params = context.join_params
        if active ~= context or not params or context.in_migrate then
            return
        end
        -- 先消费待连接参数，避免原版同步回调或后续界面更新重复发起连接
        context.join_params = nil
        Log("start_client", context)
        local worked = _G.TheNet:StartClient(params.serverIp, params.serverPort,
            nil, params.serverPassword, params.serverNetId or "")
        if not worked and active == context and context.popup
            and context.popup.inst:IsValid() and not _G.SimTearingDown then
            Log("start_client_failed", context)
            _G.OnNetworkDisconnect("ID_DST_USER_CONNECTION_FAILED", true, false)
        end
    end

    local function PrepareConnection(context, params)
        context.join_params = params
        context.armed = true
        Log("skip_join_reset", context)

        -- 原版迁移入口已保存小地图；等待新地图时停用旧世界，保留对象至正常重建
        _G.DeactivateWorld()
        _G.ChatHistory:JoinServer()

        local frontend = _G.TheFrontEnd
        local popup = ConnectingToGamePopup()
        popup.black:SetTint(0, 0, 0, 1)
        context.popup = popup
        local old_update = popup.OnUpdate
        local old_destroy = popup.OnDestroy
        popup.OnUpdate = function(self, dt, ...)
            if context.popup ~= self or not self.inst:IsValid() or _G.SimTearingDown then
                return
            end
            -- PushScreen 会同步 Update(0)，连接留到原迁移调用栈退出后的正常帧
            if dt > 0 then
                BeginConnection(context)
            end
            if context.popup ~= self or not self.inst:IsValid() or _G.SimTearingDown then
                return
            end
            return old_update(self, dt, ...)
        end
        popup.OnDestroy = function(self, ...)
            context.popup, context.join_params = nil, nil
            return old_destroy(self, ...)
        end

        -- 取消按钮沿用原版 OnCancel；迁移身份确保关闭弹窗后仍能正常返回主菜单
        frontend:Fade(_G.FADE_IN, 0)
        frontend:PushScreen(popup)
        local hud = context.player and context.player.HUD
        if hud and hud.inst:IsValid() then
            hud:Hide()
            hud:Disable()
        end
    end

    _G.IsMigrating = function(...)
        if active and active.armed then
            return true
        end
        return old_is_migrating(...)
    end

    _G.SerializeUserSession = function(player, ...)
        local context = active
        if context and context.armed and player
            and (player == context.player or (_G.TheWorld == context.world and player == _G.ThePlayer)) then
            if not context.logged_save_block then
                context.logged_save_block = true
                Log("skip_old_player_save", context)
            end
            return
        end
        return old_serialize(player, ...)
    end

    _G.OnNetworkDisconnect = function(message, should_reset, force_immediate_reset, ...)
        if active and active.armed then
            -- 旧世界已停用，最终确认断线时应退出实例；重试和错误处理交给下游
            should_reset = true
        end
        return old_disconnect(message, should_reset, force_immediate_reset, ...)
    end

    _G.DoRestart = function(save, ...)
        local context = active
        if context and context.armed then
            context.join_params = nil
            Log("restart_without_old_save", context)
            return old_restart(false, ...)
        end
        return old_restart(save, ...)
    end

    _G.SimReset = function(params, ...)
        local context = active
        if context and context.in_migrate and not context.armed and params
            and params.reset_action == _G.RESET_ACTION.JOIN_SERVER then
            PrepareConnection(context, params)
            return
        end
        if context and context.armed then
            context.join_params = nil
            Log("final_reset_" .. tostring(params and params.reset_action or "frontend"), context)
        end
        return old_reset(params, ...)
    end

    local function FinishMigrateCall(context, ...)
        context.in_migrate = false
        if active == context and not context.armed then
            active = nil
            Log("original_migration", context)
        end
        return ...
    end

    _G.MigrateToServer = function(server_ip, server_port, server_password, server_net_id, ...)
        local world = _G.TheWorld
        -- 已经接管迁移时，后续重定向直接沿用原版，不再次拦截重建
        if active or not world or world.ismastersim or _G.TheNet:GetIsServer() or not _G.InGamePlay()
            or _G.SimTearingDown or not _G.TheFrontEnd then
            return old_migrate(server_ip, server_port, server_password, server_net_id, ...)
        end
        local context = {
            world = world,
            player = _G.ThePlayer,
            begin_time = _G.GetTimeRealSeconds(),
            in_migrate = true,
        }
        active = context
        Log("migration_received", context)
        return FinishMigrateCall(context,
            old_migrate(server_ip, server_port, server_password, server_net_id, ...))
    end

    Log("installed")
end)
