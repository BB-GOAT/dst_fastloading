local _G = GLOBAL

-- modmain 早于 gamelogic 加载，等世界初始化后再安装原版迁移入口
AddSimPostInit(function()
    local required = {
        "MigrateToServer", "StartNextInstance", "SimReset", "LoadMapFile",
        "SerializeUserSession", "OnNetworkDisconnect", "IsMigrating",
        "DeactivateWorld", "DoRestart", "GetTimeRealSeconds", "InGamePlay",
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
    local old_load_map = _G.LoadMapFile
    local old_serialize = _G.SerializeUserSession
    local old_disconnect = _G.OnNetworkDisconnect
    local old_is_migrating = _G.IsMigrating
    local old_restart = _G.DoRestart

    local function Log(event, context)
        local elapsed = context and _G.GetTimeRealSeconds() - context.begin_time or 0
        print(string.format("[快速加载][快速穿越世界] %s phase=%s elapsed=%.2fs",
            event, context and context.phase or "idle", elapsed))
    end

    local function IsWaiting(context)
        return context.phase == "pending" or context.phase == "connecting"
    end

    local function ExitMigration(context, reason)
        if active ~= context or context.phase == "exiting" or context.phase == "resetting" then
            return
        end
        -- 退出仍保留上下文，防止断线回调将旧玩家保存进目标会话
        context.phase = "exiting"
        Log(reason, context)
        _G.TheNet:JoinServerResponse(true)
        _G.TheNet:Disconnect(false)
        _G.DoRestart(false)
    end

    local function FailMigration(context, reason)
        if active ~= context or not IsWaiting(context) then
            return
        end
        Log(reason, context)
        -- 走原版错误弹窗；包装入口会强制确认后完整重建退出
        _G.OnNetworkDisconnect("ID_DST_USER_CONNECTION_FAILED", true, false)
    end

    local function BeginConnection(context)
        if active ~= context or context.phase ~= "pending" or context.in_migrate then
            return
        end
        -- StartClient 可同步触发界面更新和断线回调，先改变状态防止重入
        context.phase = "connecting"
        Log("start_client", context)
        local params = context.join_params
        local worked = _G.TheNet:StartClient(params.serverIp, params.serverPort,
            nil, params.serverPassword, params.serverNetId or "")
        if active == context and context.phase == "connecting" and not worked then
            FailMigration(context, "start_client_failed")
        end
    end

    local function PrepareConnection(context, params)
        context.join_params = params
        context.armed = true
        context.phase = "pending"
        Log("skip_join_reset", context)

        -- 原版 MigrateToServer 已先保存本地小地图；从此禁止旧玩家重复保存
        _G.DeactivateWorld()
        _G.ChatHistory:JoinServer()

        local frontend = _G.TheFrontEnd
        local popup = ConnectingToGamePopup()
        -- 原版背景 alpha 为 0.75，旧世界保留期间需完全遮住场景
        popup.black:SetTint(0, 0, 0, 1)
        context.popup = popup
        local old_update = popup.OnUpdate
        local old_destroy = popup.OnDestroy

        popup.OnUpdate = function(self, dt, ...)
            -- PushScreen 内会同步 Update(0)，必须等原迁移调用栈退出后的正常帧
            if dt > 0 and not context.in_migrate then
                BeginConnection(context)
            end
            -- 同步连接失败可能已经销毁本弹窗，不再更新其中的 UI 实体
            if context.popup ~= self or not self.inst:IsValid() or _G.SimTearingDown then
                return
            end
            return old_update(self, dt, ...)
        end
        popup.OnCancel = function(self, ...)
            self:Disable()
            ExitMigration(context, "cancel")
        end
        popup.OnDestroy = function(self, ...)
            context.popup = nil
            -- 原版断线处理会先弹出本窗口，再显示错误；销毁窗口不代表结束迁移
            return old_destroy(self, ...)
        end

        -- PushScreen 会更新淡出状态，先清除旧动画回调，避免它在这里意外执行
        frontend:Fade(_G.FADE_IN, 0)
        -- 先切换焦点，再隐藏旧 HUD；保留对象给玩家的正常移除流程清理
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
        local context = active
        if not context or not context.armed then
            return old_disconnect(message, should_reset, force_immediate_reset, ...)
        end
        if context.phase == "failed" or context.phase == "exiting" or _G.SimTearingDown then
            return true
        end
        context.phase = "failed"
        Log("network_disconnect", context)
        -- 旧世界已停用，should_reset=false 只关弹窗会遗留无法操作的旧 HUD
        return old_disconnect(message, true, force_immediate_reset, ...)
    end

    _G.DoRestart = function(save, ...)
        local context = active
        if context and context.armed then
            if context.phase ~= "exiting" then
                context.phase = "exiting"
                Log("restart_without_old_save", context)
            end
            -- 原版强制断线会 DoRestart(true)，迁移时保留调用链但不再次保存旧世界
            return old_restart(false, ...)
        end
        return old_restart(save, ...)
    end

    _G.LoadMapFile = function(map_name, ...)
        local context = active
        if context and context.armed then
            if context.phase ~= "connecting" then
                Log("ignore_late_map", context)
                return
            end
            context.phase = "loading"
            Log("map_received", context)
        end
        return old_load_map(map_name, ...)
    end

    _G.SimReset = function(params, ...)
        local context = active
        if context and context.in_migrate and not context.armed and params
            and params.reset_action == _G.RESET_ACTION.JOIN_SERVER then
            PrepareConnection(context, params)
            return
        end
        if context and context.armed then
            context.phase = "resetting"
            Log("final_reset_" .. tostring(params and params.reset_action or "frontend"), context)
        end
        return old_reset(params, ...)
    end

    local function FinishMigrateCall(context, ...)
        -- 此后立刻返回原生调用者，让引擎完成迁移状态写入
        context.in_migrate = false
        if active == context and not context.armed then
            active = nil
            Log("original_migration", context)
        end
        return ...
    end

    _G.MigrateToServer = function(server_ip, server_port, server_password, server_net_id, ...)
        if active then
            if active.armed and active.phase == "connecting" and not active.in_migrate and not _G.SimTearingDown then
                -- 回档重连时，主世界可能在下发地图前再次将玩家转回洞穴
                active.phase = "redirecting"
                Log("redirect_via_original_migration", active)
                return old_migrate(server_ip, server_port, server_password, server_net_id, ...)
            end
            Log("ignore_duplicate_migration", active)
            return
        end
        local world = _G.TheWorld
        if not world or world.ismastersim or _G.TheNet:GetIsServer() or not _G.InGamePlay()
            or _G.SimTearingDown or not _G.TheFrontEnd then
            return old_migrate(server_ip, server_port, server_password, server_net_id, ...)
        end

        local context = {
            world = world,
            player = _G.ThePlayer,
            phase = "preparing",
            begin_time = _G.GetTimeRealSeconds(),
            in_migrate = true,
        }
        active = context
        Log("migration_received", context)
        -- 保留原版保存及 StartNextInstance 包装链，仅截断最后的 JOIN_SERVER 重建
        return FinishMigrateCall(context,
            old_migrate(server_ip, server_port, server_password, server_net_id, ...))
    end

    Log("installed")
end)
