--
--  The Soil Management and Growth Control Project
--
-- @author  Decker_MMIV - fs-uk.com, forum.farming-simulator.com, modhoster.com
-- @date    2014-05-xx
--
-- @history
--  2014-May
--      0.1.0   - Initial experiments
--  2014-June
--      0.2.0   - Added to private map and tweaked.
--              - Lime now affects soil pH values.
--      0.2.1   - Event-messages for multiplayer added.
--      0.3.0   - Weed propagation added, so it spreads "randomly" every in-game minute.
--      0.3.1   - Code cleanup.
--      0.4.0   - Refactored, so script files are not embedded into the map-mod.
--  2014-July
--      0.5.0   - Renamed foliage-sub-layers due to possible conflict with other mod's layers.
--      0.5.4   - MP events can be sent to clients, before clients have begun running update().
--      0.6.0   - Removed addModEventListener() to make sure this mod is ONLY run when the correct
--                changes to SampleModMap.LUA have been made.
--                This should make it NOT conflict with other maps. 
--      0.6.1   - Bug fixes and tweaks for growth control.
--      ------
--  Revision history is now kept in GitHub repository.
--


fmcGrowthControl = {}
--
local modItem = ModsUtil.findModItemByModName(g_currentModName);
fmcGrowthControl.version = (modItem and modItem.version) and modItem.version or "?.?.?";
--

fmcGrowthControl.reduceWindrows         = true;
fmcGrowthControl.removeSprayMoisture    = true;
fmcGrowthControl.disableWithering       = false;
fmcGrowthControl.updateDelayMs          = 1000 / 16; -- Maximum number of cells that may be updated per second. Consider network-latency/-updates

--
fmcGrowthControl.hudFontSize = 0.025
fmcGrowthControl.hudPosX     = 0.5
fmcGrowthControl.hudPosY     = (1 - fmcGrowthControl.hudFontSize * 1.05)

fmcGrowthControl.active              = false
fmcGrowthControl.canActivate         = false
fmcGrowthControl.lastUpdateDay       = 0
fmcGrowthControl.cellSquaresMethod   = 0
fmcGrowthControl.cellSquareToUpdate  = 0
fmcGrowthControl.pctCompleted        = 0
fmcGrowthControl.weedCell            = 0

--
function fmcGrowthControl.setup(simplisticMode)

    fmcGrowthControl.simplisticMode = simplisticMode

    fmcGrowthControl.detectFruitSprayFillTypeConflicts()

    -- Get foliage-layers that contains visible graphics (i.e. has material that uses shaders)
    g_currentMission.fmcFoliageManure = g_currentMission:loadFoliageLayer("fmc_manure",     -5, -1, true, "alphaBlendStartEnd")
    g_currentMission.fmcFoliageSlurry = g_currentMission:loadFoliageLayer("fmc_slurry",     -5, -1, true, "alphaBlendStartEnd")
    g_currentMission.fmcFoliageWeed   = g_currentMission:loadFoliageLayer("fmc_weed",       -5, -1, true, "alphaBlendStartEnd")
    g_currentMission.fmcFoliageLime   = g_currentMission:loadFoliageLayer("fmc_lime",       -5, -1, true, "alphaBlendStartEnd")

    -- Get foliage-layers that are invisible (i.e. has viewdistance=0 and a material that is "blank")
    g_currentMission.fmcFoliageFertilizerOrganic    = getChild(g_currentMission.terrainRootNode, "fmc_fertilizerOrganic")
    g_currentMission.fmcFoliageFertilizerSynthetic  = getChild(g_currentMission.terrainRootNode, "fmc_fertilizerSynthetic")
    g_currentMission.fmcFoliageHerbicide            = getChild(g_currentMission.terrainRootNode, "fmc_herbicide")
    g_currentMission.fmcFoliageSoil_pH              = getChild(g_currentMission.terrainRootNode, "fmc_soil_pH")

    --
    local function verifyFoliage(foliageName, foliageId, reqChannels)
        if foliageId ~= nil and foliageId ~= 0 then
            local numChannels = getTerrainDetailNumChannels(foliageId)
            if numChannels == reqChannels then
                logInfo(("Foliage-layer check ok: '%s', id=%s, numChnls=%s"):format(tostring(foliageName),tostring(foliageId),tostring(numChannels)))
                return true
            end
        end;
        logInfo(("ERROR! Required foliage-layer '%s' either does not exist (foliageId=%s), or have wrong num-channels (%s)"):format(tostring(foliageName),tostring(foliageId),tostring(numChannels)))
        return false
    end

    local allOK = true
    allOK = verifyFoliage("fmc_manure"              ,g_currentMission.fmcFoliageManure              ,2) and allOK;
    allOK = verifyFoliage("fmc_slurry"              ,g_currentMission.fmcFoliageSlurry              ,1) and allOK;
    allOK = verifyFoliage("fmc_weed"                ,g_currentMission.fmcFoliageWeed                ,3) and allOK;
    allOK = verifyFoliage("fmc_lime"                ,g_currentMission.fmcFoliageLime                ,1) and allOK;
    allOK = verifyFoliage("fmc_fertilizerOrganic"   ,g_currentMission.fmcFoliageFertilizerOrganic   ,2) and allOK;
    allOK = verifyFoliage("fmc_fertilizerSynthetic" ,g_currentMission.fmcFoliageFertilizerSynthetic ,2) and allOK;
    allOK = verifyFoliage("fmc_herbicide"           ,g_currentMission.fmcFoliageHerbicide           ,2) and allOK;
    allOK = verifyFoliage("fmc_soil_pH"             ,g_currentMission.fmcFoliageSoil_pH             ,3) and allOK;

    if allOK then
        -- We need a different array of dynamic-foliage-layers, to be used in Utils.updateDestroyCommonArea()
        g_currentMission.fmcDynamicFoliageLayers = {}
        for _,foliageId in ipairs(g_currentMission.dynamicFoliageLayers) do
            if foliageId ~= 0 then
                if (   foliageId == g_currentMission.fmcFoliageManure
                    or foliageId == g_currentMission.fmcFoliageSlurry
                    or foliageId == g_currentMission.fmcFoliageWeed
                    or foliageId == g_currentMission.fmcFoliageLime
                    or foliageId == g_currentMission.fmcFoliageFertilizerOrganic
                    or foliageId == g_currentMission.fmcFoliageFertilizerSynthetic
                    or foliageId == g_currentMission.fmcFoliageHerbicide
                    or foliageId == g_currentMission.fmcFoliageSoil_pH ) then
                    -- ignore
                else
                    table.insert(g_currentMission.fmcDynamicFoliageLayers, foliageId)
                end
            end
        end
    end

    fmcGrowthControl.setupFoliageGrowthLayers()
    fmcGrowthControl.initialized = false;

    return allOK
end

--
function fmcGrowthControl.detectFruitSprayFillTypeConflicts()
--[[
    Fill-type can all be transported

    Fruit-type is also a fill-type
    Spray-type is also a fill-type

    Fruit-type should ONLY be used for crop foliage-layers, that can be seeded and harvested!
    - Unfortunately some mods register new fruit-types, which basically should ONLY have been a fill-type!
--]]

    -- Issue warnings if a fruit-type has no usable foliage-layer ids
    for fruitType,fruitDesc in pairs(FruitUtil.fruitIndexToDesc) do
        local fruitLayer = g_currentMission.fruits[fruitType]
        if fruitLayer == nil or fruitLayer == 0 then
            if fruitType == Fillable.FILLTYPE_CHAFF then
                -- Ignore, as FILLTYPE_CHAFF is one from the base scripts.
            else
                logInfo("WARNING. Fruit-type '"..tostring(fruitDesc.name).."' has no usable foliage-layer. If this type is still needed, consider registering '"..tostring(fruitDesc.name).."' only as a Fill-type or Spray-type!")
            end
        end
    end
end


--
FSCareerMissionInfo.saveToXML = Utils.prependedFunction(FSCareerMissionInfo.saveToXML, function(self)
    if self.isValid and self.xmlKey ~= nil then
        log("fmcGrowthControl saving -", 
            " lastUpdateDay=", fmcGrowthControl.lastUpdateDay, 
            " cellSquareToUpdate=", fmcGrowthControl.cellSquareToUpdate,
            " cellSquaresMethod=", fmcGrowthControl.cellSquaresMethod,
            " weedCell=", fmcGrowthControl.weedCell
        )
        setXMLInt(self.xmlFile, self.xmlKey..".customGrowthControl#day"    ,fmcGrowthControl.lastUpdateDay)
        setXMLInt(self.xmlFile, self.xmlKey..".customGrowthControl#cell"   ,fmcGrowthControl.cellSquareToUpdate)
        setXMLInt(self.xmlFile, self.xmlKey..".customGrowthControl#method" ,fmcGrowthControl.cellSquaresMethod)
        setXMLInt(self.xmlFile, self.xmlKey..".customGrowthControl#cell2"  ,fmcGrowthControl.weedCell)
    end
end);

--
function fmcGrowthControl.setupFoliageGrowthLayers()
    log("fmcGrowthControl.setupFoliageGrowthLayers()")

    g_currentMission.fmcFoliageGrowthLayers = {}
    for i = 1, FruitUtil.NUM_FRUITTYPES do
      local fruitDesc = FruitUtil.fruitIndexToDesc[i]
      local fruitLayer = g_currentMission.fruits[fruitDesc.index];
      if fruitLayer ~= nil and fruitLayer.id ~= 0 and fruitDesc.minHarvestingGrowthState >= 0 then
        -- Disable growth as this mod will take control of it!
        setEnableGrowth(fruitLayer.id, false);
        --
        local entry = {
          fruitId         = fruitLayer.id,
          windrowId       = fruitLayer.windrowId,
          minSeededValue  = 1,
          minMatureValue  = (fruitDesc.minPreparingGrowthState>=0 and fruitDesc.minPreparingGrowthState or fruitDesc.minHarvestingGrowthState) + 1,
          maxMatureValue  = (fruitDesc.maxPreparingGrowthState>=0 and fruitDesc.maxPreparingGrowthState or fruitDesc.maxHarvestingGrowthState) + 1,
        }
        
        ---- Can be withered?
        --local witheredState = (fruitDesc.maxPreparingGrowthState>=0 and fruitDesc.maxPreparingGrowthState or fruitDesc.maxHarvestingGrowthState) + 1
        --if witheredState ~= fruitDesc.cutState and witheredState ~= fruitDesc.preparedGrowthState and witheredState ~= fruitDesc.minPreparingGrowthState then
        --    if getGrowthNumStates(fruitLayer.id) == witheredState + 1 then
        --        entry.witheredValue = witheredState + 1
        --    end
        --end
        
        -- Needs preparing?
        if fruitDesc.maxPreparingGrowthState >= 0 then
          -- ...and can be withered?
          if fruitDesc.minPreparingGrowthState < fruitDesc.maxPreparingGrowthState then -- Assumption that if there are multiple stages for preparing, then it can be withered too.
            entry.witheredValue = entry.maxMatureValue + 1  -- Assumption that 'withering' is just after max-harvesting.
          end
        else
          -- Can be withered?
          if fruitDesc.cutState > fruitDesc.maxHarvestingGrowthState then -- Assumption that if 'cutState' is after max-harvesting, then fruit can be withered.
            entry.witheredValue = entry.maxMatureValue + 1  -- Assumption that 'withering' is just after max-harvesting.
          end
        end

        entry.herbicideAvoidance = nil
        if (not fmcGrowthControl.simplisticMode) and fruitDesc.fmcHerbicideAffected ~= nil then
          if     fruitDesc.fmcHerbicideAffected == Fillable.FILLTYPE_HERBICIDE  then entry.herbicideAvoidance = 1
          elseif fruitDesc.fmcHerbicideAffected == Fillable.FILLTYPE_HERBICIDE2 then entry.herbicideAvoidance = 2
          elseif fruitDesc.fmcHerbicideAffected == Fillable.FILLTYPE_HERBICIDE3 then entry.herbicideAvoidance = 3
          end
        end
        
        log(fruitDesc.name,"=", i, 
            ",id=", entry.fruitId,
            ",windrowId=", entry.windrowId,
            ",minSeededValue=", entry.minSeededValue,
            ",minMatureValue=", entry.minMatureValue,
            ",maxMatureValue=", entry.maxMatureValue,
            ",cutState=", fruitDesc.cutState,
            ",witheredValue=", entry.witheredValue,
            ",herbicideAvoidance=", entry.herbicideAvoidance
        )
        
        table.insert(g_currentMission.fmcFoliageGrowthLayers, entry);
      end
    end

    fmcGrowthControl.cells = 32
    --fmcGrowthControl.cellWH = math.floor(g_currentMission.fruitMapSize / fmcGrowthControl.cells);
    --fmcGrowthControl.cellWH = math.floor(g_currentMission.terrainDetailMapSize / fmcGrowthControl.cells);
    fmcGrowthControl.cellWH = math.floor(g_currentMission.terrainSize / fmcGrowthControl.cells);

    log("fmcGrowthControl -",
        " cellWH=",                 fmcGrowthControl.cellWH,
        ", updateDelayMs=",         fmcGrowthControl.updateDelayMs,
        ", terrainSize=",           g_currentMission.terrainSize,
        ", terrainDetailMapSize=",  g_currentMission.terrainDetailMapSize,
        ", fruitMapSize=",          g_currentMission.fruitMapSize
    )
        
end

function fmcGrowthControl:update(dt)
    if not fmcGrowthControl.initialized then
      fmcGrowthControl.initialized = true;

      if g_currentMission:getIsServer() then
        local fileName = g_currentMission.missionInfo.savegameDirectory .. "/careerSavegame.xml"

        local xmlFile = loadXMLFile("xml", fileName);
        if xmlFile ~= nil then
            fmcGrowthControl.lastUpdateDay       = Utils.getNoNil(getXMLInt(xmlFile, "careerSavegame.customGrowthControl#day")    ,0)
            fmcGrowthControl.cellSquareToUpdate  = Utils.getNoNil(getXMLInt(xmlFile, "careerSavegame.customGrowthControl#cell")   ,0)
            fmcGrowthControl.cellSquaresMethod   = Utils.getNoNil(getXMLInt(xmlFile, "careerSavegame.customGrowthControl#method") ,0)
            fmcGrowthControl.weedCell            = Utils.getNoNil(getXMLInt(xmlFile, "careerSavegame.customGrowthControl#cell2")  ,0)
            delete(xmlFile);

            fmcGrowthControl.active = fmcGrowthControl.cellSquareToUpdate > 0

            log("fmcGrowthControl -",
                " lastUpdateDay=", fmcGrowthControl.lastUpdateDay,
                ", cellSquareToUpdate=", fmcGrowthControl.cellSquareToUpdate,
                ", cellSquaresMethod=", fmcGrowthControl.cellSquaresMethod,
                ", weedCell=", fmcGrowthControl.weedCell,
                ", active=", fmcGrowthControl.active
            )
        end

        fmcGrowthControl.nextUpdateTime = g_currentMission.time + 0
        g_currentMission.environment:addHourChangeListener(self);

        if g_currentMission.fmcFoliageWeed ~= nil then
            g_currentMission.environment:addMinuteChangeListener(self);
        end
      end
    end

    --
    if g_currentMission:getIsServer() then
      if not fmcGrowthControl.active then
        if InputBinding.hasEvent(InputBinding.SOILMOD_GROWNOW) or fmcGrowthControl.canActivate then
          fmcGrowthControl.canActivate = false
          fmcGrowthControl.lastUpdateDay = g_currentMission.environment.currentDay;
          fmcGrowthControl.cellSquareToUpdate = (fmcGrowthControl.cells * fmcGrowthControl.cells);
          fmcGrowthControl.nextUpdateTime = g_currentMission.time + 0
          fmcGrowthControl.pctCompleted = 0
          fmcGrowthControl.active = true;
          log("fmcGrowthControl - Growth: Started")
        end

        if fmcGrowthControl.weedPropagation and g_currentMission.fmcFoliageWeed ~= nil then
            fmcGrowthControl.weedPropagation = false
            --
            fmcGrowthControl.weedCell = (fmcGrowthControl.weedCell + 1) % (fmcGrowthControl.cells * fmcGrowthControl.cells);
            fmcGrowthControl.updateWeedFoliage(self, fmcGrowthControl.weedCell)
        end
      else
        if g_currentMission.time > fmcGrowthControl.nextUpdateTime then
          fmcGrowthControl.nextUpdateTime = g_currentMission.time + fmcGrowthControl.updateDelayMs;
          --
          local totalCells = (fmcGrowthControl.cells*fmcGrowthControl.cells)
          local pctCompleted = ((totalCells - fmcGrowthControl.cellSquareToUpdate) / totalCells) + 0.01 -- Add 1% to get clients to render "Growth: %"
          local cellToUpdate = fmcGrowthControl.cellSquareToUpdate

          -- TODO - implement different methods (i.e. patterns) so the cells will not be updated in the same straight pattern every time.
          if fmcGrowthControl.cellSquaresMethod == 0 then
            -- North-West to South-East
            cellToUpdate = totalCells - cellToUpdate
          elseif fmcGrowthControl.cellSquaresMethod == 1 then
            -- South-East to North-West
            cellToUpdate = cellToUpdate - 1
          end

          fmcGrowthControl.updateFoliageCell(self, cellToUpdate, pctCompleted)
          --
          fmcGrowthControl.cellSquareToUpdate = fmcGrowthControl.cellSquareToUpdate - 1
          if fmcGrowthControl.cellSquareToUpdate <= 0 then
            fmcGrowthControl.active = false;
            fmcGrowthControl.updateFoliageCellXZWH(self, 0,0, 0, 0) -- Send "finished"
            log("fmcGrowthControl - Growth: Finished")
          end
        end
      end
    end
end;

--
function fmcGrowthControl:minuteChanged()
    fmcGrowthControl.weedPropagation = true
end

--
function fmcGrowthControl:hourChanged()
    if  not fmcGrowthControl.active -- Must not already be running
    and g_currentMission.environment.currentHour == 0 -- midnight hour
    and (g_currentMission.environment.currentDay + 1) ~= fmcGrowthControl.lastUpdateDay -- another day (apparently 'currentDay' is NOT incremented _before_ calling the hourChanged() callbacks)
    --and (g_currentMission.environment.currentDay + 1) > (fmcGrowthControl.lastUpdateDay + 3)
    then
        fmcGrowthControl.canActivate = true
    end
end

--
function fmcGrowthControl:updateWeedFoliage(cellSquareToUpdate)
  local weedPlaced = 0
  local tries = 5
  local x = math.floor(fmcGrowthControl.cellWH * math.floor(cellSquareToUpdate % fmcGrowthControl.cells))
  local z = math.floor(fmcGrowthControl.cellWH * math.floor(cellSquareToUpdate / fmcGrowthControl.cells))
  local sx,sz = (x-(g_currentMission.terrainSize/2)),(z-(g_currentMission.terrainSize/2))

  -- Repeat until a spot was found (weed seeded) or maximum-tries reached.
  repeat
    local xOff = fmcGrowthControl.cellWH * math.random()
    local zOff = fmcGrowthControl.cellWH * math.random()
    local r = 1 + 3 * math.random()
    -- Place 4 "patches" of weed.
    for i=0,3 do
        weedPlaced = weedPlaced + fmcGrowthControl.createWeedFoliage(self, math.ceil(sx + xOff), math.ceil(sz + zOff), math.ceil(r))
        if weedPlaced <= 0 then
            -- If first "patch" failed (i.e. "not in a field"), then do not bother with the rest.
            break
        end
        -- Pick a new spot that is a bit offset from the previous spot.
        local r2 = 1 + 3 * math.random()
        xOff = xOff + (Utils.sign(math.random()-0.5) * (r + r2) * 0.9)
        zOff = zOff + (Utils.sign(math.random()-0.5) * (r + r2) * 0.9)
        r = r2
    end
    tries = tries - 1
  until weedPlaced > 0 or tries <= 0
end

--
function fmcGrowthControl:createWeedFoliage(centerX,centerZ,radius, noEventSend)
    local sx,sy,  wx,wy,  hx,hy = centerX-radius,centerZ-radius,  radius*2,0,  0,radius*2

    local includeMask   = 2^g_currentMission.sowingChannel
                        + 2^g_currentMission.sowingWidthChannel
                        + 2^g_currentMission.cultivatorChannel
                        + 2^g_currentMission.ploughChannel;

    setDensityCompareParams(g_currentMission.fmcFoliageWeed, "equal", 0)
    setDensityMaskParams(g_currentMission.fmcFoliageWeed, "greater", -1,-1, includeMask, 0)
    local oldSum,pixelsMatch,newDelta =
    setDensityMaskedParallelogram(
        g_currentMission.fmcFoliageWeed,
        sx,sy,wx,wy,hx,hy,
        0, 3,
        g_currentMission.terrainDetailId, g_currentMission.terrainDetailTypeFirstChannel, g_currentMission.terrainDetailTypeNumChannels, -- mask
        4 -- set
    )
    setDensityMaskParams(g_currentMission.fmcFoliageWeed, "greater", -1)
    setDensityCompareParams(g_currentMission.fmcFoliageWeed, "greater", -1)

    --
    if pixelsMatch > 0 then
        CreateWeedEvent.sendEvent(centerX,centerZ,radius,noEventSend)
    end

    return pixelsMatch
end

function fmcGrowthControl:updateFoliageCell(cellSquareToUpdate, pctCompleted, noEventSend)
    local x = math.floor(fmcGrowthControl.cellWH * math.floor(cellSquareToUpdate % fmcGrowthControl.cells))
    local z = math.floor(fmcGrowthControl.cellWH * math.floor(cellSquareToUpdate / fmcGrowthControl.cells))
    local sx,sy = (x-(g_currentMission.terrainSize/2)),(z-(g_currentMission.terrainSize/2))

    fmcGrowthControl:updateFoliageCellXZWH(sx,sy, fmcGrowthControl.cellWH, pctCompleted, noEventSend)
end

function fmcGrowthControl:updateFoliageCellXZWH(x,z, wh, pctCompleted, noEventSend)
    fmcGrowthControl.pctCompleted = pctCompleted
    fmcGrowthControlEvent.sendEvent(x,z, wh, pctCompleted, noEventSend)
    
    -- Test for "magic number" indicating finished.
    if wh <= 0 then
        return
    end
    
--[[
Growth states

   Density value (from channels/bits)
   |  RegisterFruit value (for RegisterFruit)
   |  |
   0  -  nothing
   1  0  growth-1 (just seeded)
   2  1  growth-2
   3  2  growth-3
   4  3  growth-4
   5  4  harvest-1 / prepare-1
   6  5  harvest-2 / prepare-2
   7  6  harvest-3 / prepare-3
   8  7  withered
   9  8  cutted
  10  9  harvest (defoliaged)
  11 10  <unused>
  12 11  <unused>
  13 12  <unused>
  14 13  <unused>
  15 14  <unused>
--]]

    local sx,sy, wx,wy, hx,hy = x,z,  wh-0.5,0,  0,wh-0.5

    -- increase growth
    for _,v in pairs(g_currentMission.fmcFoliageGrowthLayers) do
      setDensityMaskParams(v.fruitId, "between", v.minSeededValue, v.maxMatureValue - ((fmcGrowthControl.disableWithering or v.witheredValue == nil) and 1 or 0))
      addDensityMaskedParallelogram(
        v.fruitId,
        sx,sy,wx,wy,hx,hy,
        0, g_currentMission.numFruitStateChannels,
        v.fruitId, 0, g_currentMission.numFruitStateChannels, -- mask
        1 -- add one
      )

      -- Herbicide may affect growth or cause withering...
      if g_currentMission.fmcFoliageHerbicide ~= nil then
        if v.herbicideAvoidance ~= nil and v.herbicideAvoidance >= 1 and v.herbicideAvoidance <= 3 then
          -- Herbicide affected fruit
          setDensityMaskParams(v.fruitId, "equals", v.herbicideAvoidance)
          -- When growing and affected by wrong herbicide, pause one growth-step
          setDensityCompareParams(v.fruitId, "between", v.minSeededValue+1, v.minMatureValue)
          addDensityMaskedParallelogram(
            v.fruitId,
            sx,sy,wx,wy,hx,hy,
            0, g_currentMission.numFruitStateChannels,
            g_currentMission.fmcFoliageHerbicide, 0, 2, -- mask
            -1 -- subtract one
          )
          -- When mature and affected by wrong herbicide, change to withered if possible.
          if v.witheredValue ~= nil then
            setDensityMaskParams(v.fruitId, "equals", v.herbicideAvoidance)
            setDensityCompareParams(v.fruitId, "between", v.minMatureValue, v.maxMatureValue)
            setDensityMaskedParallelogram(
                v.fruitId,
                sx,sy,wx,wy,hx,hy,
                0, g_currentMission.numFruitStateChannels,
                g_currentMission.fmcFoliageHerbicide, 0, 2, -- mask
                v.witheredValue  -- value
            )
          end
          --
          setDensityCompareParams(v.fruitId, "greater", -1)
        end
      end
      --
      setDensityMaskParams(v.fruitId, "greater", 0)

      if fmcGrowthControl.reduceWindrows then
        -- Reduce windrow (gone with the wind)
        if v.windrowId ~= nil and v.windrowId ~= 0 then
            setDensityMaskParams(v.windrowId, "greater", 0)
            addDensityMaskedParallelogram(
                v.windrowId,
                sx,sy,wx,wy,hx,hy,
                0, g_currentMission.numWindrowChannels,
                v.windrowId, 0, g_currentMission.numWindrowChannels,  -- mask
                -1  -- subtract one
            );
            setDensityMaskParams(v.windrowId, "greater", -1)
        end
      end
    end

    --
    if fmcGrowthControl.removeSprayMoisture then
        -- Remove moistness (spray)
        setDensityParallelogram(
            g_currentMission.terrainDetailId,
            sx,sy,wx,wy,hx,hy,
            g_currentMission.sprayChannel, 1,
            0  -- value
        );
    end

    --Lime/Kalk and soil pH
    if g_currentMission.fmcFoliageLime ~= nil then
        if g_currentMission.fmcFoliageSoil_pH ~= nil then
            -- Increase soil-pH, where lime is
            setDensityMaskParams(g_currentMission.fmcFoliageSoil_pH, "greater", 0);
            addDensityMaskedParallelogram(
                g_currentMission.fmcFoliageSoil_pH,
                sx,sy,wx,wy,hx,hy,
                0, 3,
                g_currentMission.fmcFoliageLime, 0, 1,
                2  -- increase
            );
            setDensityMaskParams(g_currentMission.fmcFoliageSoil_pH, "greater", -1);
        end

        -- Remove lime
        setDensityParallelogram(
            g_currentMission.fmcFoliageLime,
            sx,sy,wx,wy,hx,hy,
            0, 1,
            0  -- value
        );
    end

    -- Manure
    if g_currentMission.fmcFoliageManure ~= nil then
        -- Decrease solid manure
        addDensityParallelogram(
            g_currentMission.fmcFoliageManure,
            sx,sy,wx,wy,hx,hy,
            0, 2,
            -1  -- subtract one
        );
    end

    -- Slurry/LiquidManure
    if g_currentMission.fmcFoliageSlurry ~= nil then
        if g_currentMission.fmcFoliageFertilizerOrganic ~= nil then
            -- Set fertilizer(organic) at level-1 only.
            setDensityMaskParams(g_currentMission.fmcFoliageFertilizerOrganic, "greater", 0);
            setDensityMaskedParallelogram(
                g_currentMission.fmcFoliageFertilizerOrganic,
                sx,sy,wx,wy,hx,hy,
                0, 1,
                g_currentMission.fmcFoliageSlurry, 0, 1,  -- mask
                1 -- value
            );
            setDensityMaskParams(g_currentMission.fmcFoliageFertilizerOrganic, "greater", -1);
        end
        -- Remove liquid manure
        setDensityParallelogram(
            g_currentMission.fmcFoliageSlurry,
            sx,sy,wx,wy,hx,hy,
            0, 1,
            0
        );
    end

    -- Weed and herbicide
    if g_currentMission.fmcFoliageWeed ~= nil then
        -- Decrease "dead" weed
        setDensityCompareParams(g_currentMission.fmcFoliageWeed, "between", 1, 3)
        addDensityParallelogram(
            g_currentMission.fmcFoliageWeed,
            sx,sy,wx,wy,hx,hy,
            0, 3,
            -1  -- subtract
        );

        --
        if g_currentMission.fmcFoliageHerbicide ~= nil then
            -- Change to "dead" weed
            setDensityCompareParams(g_currentMission.fmcFoliageWeed, "greater", 0)
            setDensityMaskParams(g_currentMission.fmcFoliageWeed, "greater", 0)
            setDensityMaskedParallelogram(
                g_currentMission.fmcFoliageWeed,
                sx,sy,wx,wy,hx,hy,
                2, 1, -- affect only Most-Significant-Bit
                g_currentMission.fmcFoliageHerbicide, 0, 2, -- mask
                0 -- reset bit
            )
            setDensityMaskParams(g_currentMission.fmcFoliageWeed, "greater", -1)
        end

        -- Increase "alive" weed
        setDensityCompareParams(g_currentMission.fmcFoliageWeed, "between", 4, 6)
        addDensityParallelogram(
            g_currentMission.fmcFoliageWeed,
            sx,sy,wx,wy,hx,hy,
            0, 3,
            1  -- increase
        );

        --
        setDensityCompareParams(g_currentMission.fmcFoliageWeed, "greater", -1)
    end

    -- Herbicide and soil pH
    if g_currentMission.fmcFoliageHerbicide ~= nil then
        if g_currentMission.fmcFoliageSoil_pH ~= nil then
            -- Decrease soil-pH, where herbicide is
            setDensityMaskParams(g_currentMission.fmcFoliageSoil_pH, "greater", 0)
            addDensityMaskedParallelogram(
                g_currentMission.fmcFoliageSoil_pH,
                sx,sy,wx,wy,hx,hy,
                0, 3,
                g_currentMission.fmcFoliageHerbicide, 0, 2, -- mask
                -1  -- decrease
            );
            setDensityMaskParams(g_currentMission.fmcFoliageSoil_pH, "greater", -1)
        end

        -- Remove herbicide
        setDensityParallelogram(
            g_currentMission.fmcFoliageHerbicide,
            sx,sy,wx,wy,hx,hy,
            0, 2,
            0  -- value
        );
    end
end

--
function fmcGrowthControl:renderTextShaded(x,y,fontsize,txt,foreColor,backColor)
    if backColor ~= nil then
        setTextColor(unpack(backColor));
        renderText(x + (fontsize * 0.075), y - (fontsize * 0.075), fontsize, txt)
    end
    if foreColor ~= nil then
        setTextColor(unpack(foreColor));
    end
    renderText(x, y, fontsize, txt)
end

--
function fmcGrowthControl:draw()
    if fmcGrowthControl.pctCompleted > 0.00 and g_gui.currentGui == nil then
        local txt = (g_i18n:getText("GrowthPct")):format(fmcGrowthControl.pctCompleted * 100)
        setTextAlignment(RenderText.ALIGN_CENTER);
        setTextBold(false);
        self:renderTextShaded(fmcGrowthControl.hudPosX, fmcGrowthControl.hudPosY, fmcGrowthControl.hudFontSize, txt, {1,1,1,0.8}, {0,0,0,0.8})
        setTextAlignment(RenderText.ALIGN_LEFT);
        setTextColor(1,1,1,1)
    end
end;

-------
-------
-------

fmcGrowthControlEvent = {};
fmcGrowthControlEvent_mt = Class(fmcGrowthControlEvent, Event);

InitEventClass(fmcGrowthControlEvent, "GrowthControlEvent");

function fmcGrowthControlEvent:emptyNew()
    local self = Event:new(fmcGrowthControlEvent_mt);
    self.className="fmcGrowthControlEvent";
    return self;
end;

function fmcGrowthControlEvent:new(x,z, wh, pctCompleted)
    local self = fmcGrowthControlEvent:emptyNew()
    self.x = x
    self.z = z
    self.wh = wh
    self.pctCompleted = pctCompleted
    return self;
end;

function fmcGrowthControlEvent:readStream(streamId, connection)
    pctCompleted  = streamReadUInt8(streamId) / 100
    x             = streamReadInt16(streamId)
    z             = streamReadInt16(streamId)
    wh            = streamReadInt16(streamId)
    fmcGrowthControl.updateFoliageCellXZWH(fmcGrowthControl, x,z, wh, pctCompleted, true);
end;

function fmcGrowthControlEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, math.floor(self.pctCompleted * 100))
    streamWriteInt16(streamId, self.x)
    streamWriteInt16(streamId, self.z)
    streamWriteInt16(streamId, self.wh)
end;

function fmcGrowthControlEvent.sendEvent(x,z, wh, pctCompleted, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(fmcGrowthControlEvent:new(x,z, wh, pctCompleted), nil, nil, nil);
        end;
    end;
end;

-------
-------
-------

CreateWeedEvent = {};
CreateWeedEvent_mt = Class(CreateWeedEvent, Event);

InitEventClass(CreateWeedEvent, "CreateWeedEvent");

function CreateWeedEvent:emptyNew()
    local self = Event:new(CreateWeedEvent_mt);
    self.className="CreateWeedEvent";
    return self;
end;

function CreateWeedEvent:new(x,z,r)
    local self = CreateWeedEvent:emptyNew()
    self.centerX = x
    self.centerZ = z
    self.radius  = r
    return self;
end;

function CreateWeedEvent:readStream(streamId, connection)
    self.centerX = streamReadIntN(streamId, 16)
    self.centerZ = streamReadIntN(streamId, 16)
    self.radius  = streamReadIntN(streamId, 4)
    fmcGrowthControl:createWeedFoliage(self.centerX,self.centerZ,self.radius, true)
end;

function CreateWeedEvent:writeStream(streamId, connection)
    streamWriteIntN(streamId, self.centerX, 16)
    streamWriteIntN(streamId, self.centerZ, 16)
    streamWriteIntN(streamId, self.radius,  4)
end;

function CreateWeedEvent.sendEvent(x,z,r,noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(CreateWeedEvent:new(x,z,r), nil, nil, nil);
        end;
    end;
end;


print(string.format("Script loaded: fmcGrowthControl.lua (v%s)", fmcGrowthControl.version));
