local variables = require("__debugadapter__/variables.lua")
local json_encode = require("__debugadapter__/json.lua").encode
local __DebugAdapter = __DebugAdapter
local debug = debug
local string = string
local print = print
local pcall = pcall -- capture pcall early before entrypoints wraps it
local xpcall = xpcall -- ditto
local setmetatable = setmetatable
local load = load
local pindex = variables.pindex

-- capture the raw object
local remote = remote and (type(remote)=="table" and rawget(remote,"__raw")) or remote

---@class DebugAdapter.Evaluate
local DAEval = {}

---Timed version of `pcall`. If `game.create_profiler()` is available, it will
---be used to measure the execution time of `f`. The timer or nil is added as an
---additional first return value, followed by `pcall`'s normal returns
---@param f function
---@return LuaProfiler|nil
---@return boolean
---@return ...
local function timedpcall(f)
  if game then
    ---@type LuaProfiler
    local t = game.create_profiler()
    local res = {pcall(f)}
    t.stop()
    return t,table.unpack(res)
  else
    return nil,pcall(f)
  end
end

---@param env table
---@param frameId? integer|false|nil
---@param alsoLookIn? table|nil
---@return table
local function evalmeta(env,frameId,alsoLookIn)
  local getinfo = debug.getinfo
  local getlocal = debug.getlocal
  local getupvalue = debug.getupvalue
  local em = {
    __closeframe = function ()
      frameId = false
    end,
    __debugtype = "DebugAdapter.EvalEnv",
    ---@param t table
    ---@param short boolean
    ---@return string
    __debugline = function(t,short)
      if short then
        return "<Eval Env>"
      end
      ---@type string|nil
      local envname
      if frameId == false then
        envname = (envname or " for") .. " closed frame"
      elseif frameId then
        envname = (envname or " for") .. " frame " .. frameId
      end
      if alsoLookIn then
        envname = (envname or " for") .. " " .. variables.describe(alsoLookIn,true)
      end

      return ("<Evaluate Environment%s>"):format(envname or "")
    end,
    ---@param t table
    ---@param k string
    ---@return any
    __index = function(t,k)
      -- go ahead and loop _ENV back...
      if k == "_ENV" then return t end
      -- but _G can force global only lookup, return the real global environment
      if k == "_G" then return env end

      if alsoLookIn then
        if k == "self" then
          return alsoLookIn
        end
        -- this might be a LuaObject and throw on bad lookups...
        local success,result = pindex(alsoLookIn,k)
        if success then
          return result
        end
      end

      if frameId then
        -- find how deep we are, if the expression includes defining new functions and calling them...
        -- if this table lives longer than the expression (by being returned),
        -- the frameId will be cleared and fall back to only the global lookups
        local i = 0
        ---@type integer|nil
        local offset
        while true do
          local info = getinfo(i,"f")
          if info then
            local func = info.func
            if func == DAEval.evaluateInternal then
              offset = i - 1
              break
            end
          else
            -- we got all the way up the stack without finding where the eval was happening
            -- probably outlived it, so go ahead and and clear the frame to stop looking...
            frameId = nil
            break
          end
          i = i + 1
        end
        if offset then
          local frame = frameId + offset
          --check for local at frameId
          i = 1
          ---@type boolean
          local islocal
          ---@type any
          local localvalue
          while true do
            local name,value = getlocal(frame,i)
            if not name then break end
            if name:sub(1,1) ~= "(" then
              if name == k then
                islocal,localvalue = true,value
              end
            end
            i = i + 1
          end
          if islocal then return localvalue end

          --check for upvalue at frameId
          local func = getinfo(frame,"f").func
          i = 1
          while true do
            local name,value = getupvalue(func,i)
            if not name then break end
            if name == k then return value end
            i = i + 1
          end
        end
      end

      --else forward to global lookup...
      return env[k]
    end,
    ---@param t table
    ---@param k string
    ---@param v any
    __newindex = function(t,k,v)
      -- don't allow setting _ENV or _G in evals
      if k == "_ENV" or k == "_G" then return end

      if alsoLookIn then
        if k == "self" then
          return -- don't allow setting `self`
        end
        -- this might be a LuaObject and throw on bad lookups...
        local success = pindex(alsoLookIn,k)
        if success then
          -- attempt to set, this may throw on bad assignment to LuaObject, but we want to pass that up usually
          alsoLookIn[k] = v
          return
        end
      end


      if frameId then
        -- find how deep we are, if the expression includes defining new functions and calling them...
        local i = 1
        ---@type integer|nil
        local offset
        while true do
          local info = getinfo(i,"f")
          if info then
            local func = info.func
            if func == DAEval.evaluateInternal then
              offset = i - 1
              break
            end
          else
            -- we got all the way up the stack without finding where the eval was happening
            -- probably outlived it, so go ahead and and clear the frame to stop looking...
            frameId = nil
            break
          end
          i = i + 1
        end
        if offset then
          local frame = frameId + offset
          --check for local at frameId
          i = 1
          ---@type integer|nil
          local localindex
          while true do
            local name = getlocal(frame,i)
            if not name then break end
            if name:sub(1,1) ~= "(" then
              if name == k then
                localindex = i
              end
            end
            i = i + 1
          end
          if localindex then
            debug.setlocal(frame,localindex,v)
            return
          end

          --check for upvalue at frameId
          local func = getinfo(frame,"f").func
          i = 1
          while true do
            local name = getupvalue(func,i)
            if not name then break end
            if not name == "_ENV" then
              if name == k then
                debug.setupvalue(func,i,v)
                return
              end
            end
            i = i + 1
          end
        end
      end

      --else forward to global...
      env[k] = v
    end
  }
  return __DebugAdapter.stepIgnore(em)
end
__DebugAdapter.stepIgnore(evalmeta)

---@class DebugAdapter.CountedResult: any[]
---@field n integer

---@param frameId integer|nil
---@param alsoLookIn table|nil
---@param context string|nil
---@param expression string
---@param timed nil|boolean
---@overload fun(frameId:integer|nil,alsoLookIn:table|nil,context:string|nil,expression:string,timed:true): LuaProfiler?,boolean,DebugAdapter.CountedResult|string?
---@overload fun(frameId:integer|nil,alsoLookIn:table|nil,context:string|nil,expression:string,timed?:false|nil): boolean,...
function DAEval.evaluateInternal(frameId,alsoLookIn,context,expression,timed)
  ---@type table
  local env = _ENV

  if frameId then
    -- if there's a function here, check if it has an active local or upval
    local i = 0
    local found
    while true do
      i = i+1
      local name,value = debug.getlocal(frameId,i)
      if not name then
        if found then
          goto foundenv
        else
          break
        end
      end
      if name == "_ENV" then
        env = value
        found = true
      end
    end
    i = 0
    local info = debug.getinfo(frameId,"f")
    local func = info.func
    while true do
      i = i+1
      local name,value = debug.getupvalue(func,i)
      if not name then break end
      if name == "_ENV" then
        env = value
        goto foundenv
      end
    end
  end
  ::foundenv::
  if frameId or alsoLookIn then
    env = setmetatable({},evalmeta(env,frameId,alsoLookIn))
  end
  local chunksrc = ("=(%s)"):format(context or "eval")
  local f, res = load('return '.. expression, chunksrc, "t", env)
  if not f then f, res = load(expression, chunksrc, "t", env) end

  if not f then
    -- invalid expression...
    if timed then
      return nil,false,res
    else
      return false,res
    end
  end
  ---@cast f function

  local pcall = timed and timedpcall or pcall
  local closeframe = timed and
    function(timer,success,...)
      if frameId then
        local mt = getmetatable(env)
        local __closeframe = mt and mt.__closeframe
        if __closeframe then __closeframe() end
      end
      return timer,success,table.pack(...)
    end
    or
    function(success,...)
      if frameId then
        local mt = getmetatable(env)
        local __closeframe = mt and mt.__closeframe
        if __closeframe then __closeframe() end
      end
      return success,...
    end
  return closeframe(pcall(f))
end

---@param str string
---@param frameId? integer
---@param alsoLookIn? table
---@param context? string
---@return string
---@return any[]
function DAEval.stringInterp(str,frameId,alsoLookIn,context)
  local sub = string.sub
  local evals = {}
  local evalidx = 1
  local result = string.gsub(str,"(%b{})",
    function(expr)
      if expr == "{[}" then
        evals[evalidx] = "{"
        evalidx = evalidx+1
        return "{"
      elseif expr == "{]}" then
        evals[evalidx] = "}"
        evalidx = evalidx+1
        return "}"
      elseif expr == "{...}" then
        -- expand a comma separated list of short described varargs
        if not frameId then
          evals[evalidx] = variables.error("no frame for `...`")
          evalidx = evalidx+1
          return "<error>"
        end
        local fId = frameId + 2
        local info = debug.getinfo(fId,"u")
        if info and info.isvararg then
          local i = -1
          local args = {}
          while true do
            local name,value = debug.getlocal(fId,i)
            if not name then break end
            args[#args + 1] = variables.describe(value,true)
            i = i - 1
          end
          local result = table.concat(args,", ")
          evals[evalidx] = setmetatable(args,{
            __debugline = "...",
            __debugtype = "vararg",
          })
          evalidx = evalidx+1
          return result
        else
          evals[evalidx] = variables.error("frame for `...` is not vararg")
          evalidx = evalidx+1
          return "<error>"
        end
      end
      expr = sub(expr,2,-2)
      local success,result = DAEval.evaluateInternal(frameId and frameId+3,alsoLookIn,context or "interp",expr)
      if success then
        evals[evalidx] = result
        evalidx = evalidx+1
        return variables.describe(result)
      else --[[@cast result string]]
        evals[evalidx] = variables.error(result)
        evalidx = evalidx+1
        return "<error>"
      end
    end)
    return result,evals
end

local evalresultmeta = {
  __debugline = function(t)
    local s = {}
    for i=1,t.n do
      s[i] = variables.describe(t[i])
    end
    return table.concat(s,", ")
  end,
  __debugtype = "DebugAdapter.EvalResult",
  __debugcontents = function (t)
    return
      function(t,k)
        if k == nil then
          return 1,t[1]
        end
        if k >= t.n then
          return
        end
        k = k +1
        return k,t[k]
      end,
      t
  end,
}

---@param frameId? integer
---@param context? string
---@param expression string
---@param seq integer
function DAEval.evaluate(frameId,context,expression,seq,formod)
  -- if you manage to do one of these fast enough for data, go for it...
  if not data and formod~=script.mod_name then
    local modname,rest = expression:match("^__(.-)__ (.+)$")
    if modname then
      expression = rest
      frameId = nil
    else
      if not frameId then
        modname = "level"
      end
    end
    if modname and modname~=script.mod_name then
      -- remote to named state if possible, else just error
      if __DebugAdapter.canRemoteCall() and remote.interfaces["__debugadapter_"..modname] then
        return remote.call("__debugadapter_"..modname,"evaluate",frameId,context,expression,seq,modname)
      else
        print("DBGeval: " .. json_encode({result = "`"..modname.."` not available for eval", type="error", variablesReference=0, seq=seq}))
        return
      end
    end
  end
  local info = not frameId or debug.getinfo(frameId,"f")

  -- Variable is close enough to EvaluateResult
  ---@type DebugProtocol.Variable
  local evalresult
  if info then
    local timer,success,result
    if context == "repl" then
      timer,success,result = DAEval.evaluateInternal(frameId and frameId+1,nil,context,expression,true)
    else
      success,result = DAEval.evaluateInternal(frameId and frameId+1,nil,context,expression)
    end
    ---@cast timer LuaProfiler
    ---@cast success boolean
    if success then
      if context == "repl" then
        ---@cast result DebugAdapter.CountedResult
        if result.n == 0 or result.n == 1 then
          result = result[1]
        else
          setmetatable(result,evalresultmeta)
        end
      end
      ---@cast result any
      evalresult = variables.create(nil,result,nil)
      evalresult.result = evalresult.value
      if context == "visualize" then
        local mtresult = getmetatable(result)
        if mtresult and mtresult.__debugvisualize then
          local function err(e) return debug.traceback("__debugvisualize error: "..e) end
          __DebugAdapter.stepIgnore(err)
          success,result = xpcall(mtresult.__debugvisualize,err,result)
        end
        evalresult.result = json_encode(result)
      end
      evalresult.seq = seq
    else
      if context == "repl" then
        ---@cast result DebugAdapter.CountedResult
        result = result[1]
      end
      ---@cast result any
      local outmesg = result
      local tmesg = type(result)
      if tmesg == "table" and (result--[[@as LuaObject]].object_name == "LuaProfiler" or (not getmetatable(result) and #result>=1 and type(result[1])=="string")) then
        outmesg = "{LocalisedString "..variables.translate(result).."}"
      elseif tmesg ~= "string" then
        outmesg = variables.describe(result)
      end
      evalresult = {result = outmesg, type="error", variablesReference=0, seq=seq}
    end
    if timer then
      evalresult.timer = variables.translate(timer)
    end
  else
    evalresult = {result = "Cannot Evaluate in Remote Frame", type="error", variablesReference=0, seq=seq}
  end
  print("DBGeval: " .. json_encode(evalresult))
end

return DAEval