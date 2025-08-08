-- Safe REST API calls with error handling
function safeRestApiCall(method, uri, body)
    local success, result = pcall(function()
        if method == "GET" then
            return RestApiGet(uri)
        elseif method == "PUT" then
            return RestApiPut(uri, body)
        end
    end)
    
    if not success then
        print('REST API call failed: ' .. tostring(result))
        return nil
    end
    return result
end

-- Helper function to set processing metadata with error handling
function setProcessedMetadata(studyId, status, details)
    local metadata = {
        processed = true,
        status = status,  -- 'success', 'error', 'partial'
        timestamp = os.time(),
        details = details
    }
    
    -- Convert to JSON string with error handling
    local success, jsonMetadata = pcall(function()
        return DumpJson(metadata)
    end)
    
    if not success then
        print('Failed to convert metadata to JSON: ' .. tostring(jsonMetadata))
        return false
    end
    
    -- Set metadata using REST API
    local result = safeRestApiCall("PUT", '/studies/' .. studyId .. '/metadata/ProcessingStatus', jsonMetadata)
    return result ~= nil
end

-- Helper function to check if study was processed
function wasProcessed(studyId)
    local status = safeRestApiCall("GET", '/studies/' .. studyId .. '/metadata/ProcessingStatus')
    
    if status then
        local success, processedData = pcall(function()
            return ParseJson(status)
        end)
        
        if success and processedData then
            return processedData.processed
        end
    end
    
    return false
end

-- Helper function to check if any instance in the study has "OUTPUT" in StudyDescription
function hasOutputInDescription(instances)
    for _, instance in pairs(instances) do
        local instanceTags = safeRestApiCall("GET", '/instances/' .. instance['ID'] .. '/tags?simplify')
        if instanceTags then
            local success, tags = pcall(function()
                return ParseJson(instanceTags)
            end)
            
            if success and tags then
                local studyDescription = tags['StudyDescription'] or ''
                if string.find(string.upper(studyDescription), 'OUTPUT') then
                    print('   Found OUTPUT in StudyDescription: ' .. studyDescription)
                    return true
                end
            end
        end
    end
    return false
end

function OnStableStudy(studyId, tags, metadata, origin)
    -- Avoid processing our own modifications
    if origin and origin["RequestOrigin"] == "Lua" then
        print('Skipping processing of Lua-originated study')
        return
    end

    local studyDescription = tags['StudyDescription'] or ''
    
    -- Convert to uppercase for case-insensitive comparison
    local normalizedDescription = string.upper(studyDescription)
    local targetDescription = string.upper('LPCH XR EXTREMITY BILATERAL BONE LENGTH')
    
    -- First check if this is a bone length study
    if normalizedDescription == targetDescription then
        -- Get all instances in the study with error handling
        local instancesJson = safeRestApiCall("GET", '/studies/' .. studyId .. '/instances')
        if not instancesJson then
            print('Failed to get instances for study')
            return
        end
        
        local success, instances = pcall(function()
            return ParseJson(instancesJson)
        end)
        
        if not success or not instances then
            print('Failed to parse instances JSON')
            return
        end

        -- Then check if it's already been processed
        if hasOutputInDescription(instances) then
            print('   Study already has OUTPUT in description, skipping processing')
            return
        end

        local patientName = tags['PatientName'] or 'Unknown'
        local studyInstanceUID = tags['StudyInstanceUID'] or 'Unknown'
        
        print('🦴 PROCESSING NEW BONE LENGTH STUDY')
        print('   Study ID: ' .. studyId)
        print('   Patient: ' .. patientName)
        print('   Study UID: ' .. studyInstanceUID)
        print('   Original Description: ' .. studyDescription)
        
        print('   Found ' .. #instances .. ' instances in study')
        
        -- Process all instances
        local processedInstances = {}
        local failedInstances = {}
        local success = true
        local lastJob = nil
        
        for i, instance in pairs(instances) do
            local job = SendToModality(instance['ID'], 'MERCURE')
            if job then
                print('   ✓ Instance ' .. i .. ' queued for MERCURE (Job: ' .. job .. ')')
                table.insert(processedInstances, {
                    instanceId = instance['ID'],
                    jobId = job,
                    status = 'sent'
                })
                lastJob = job
            else
                print('   ✗ Failed to queue instance ' .. i)
                table.insert(failedInstances, instance['ID'])
                success = false
            end
        end
        
        -- Update processing status based on results
        if success then
            if setProcessedMetadata(studyId, 'success', {
                lastJob = lastJob,
                processedInstances = processedInstances,
                totalInstances = #instances,
                timestamp = os.time()
            }) then
                print('   ✓ All instances queued for MERCURE')
                print('AUTO-FORWARD: Bone length study forwarded to MERCURE - Patient: ' .. 
                          patientName .. ', Study: ' .. studyId .. ', Last Job: ' .. lastJob)
                
                -- Mark study as stable since we're done processing
                if SetStableStatus then  -- Check if function exists (Orthanc 1.12.9+)
                    SetStableStatus(studyId, true)
                end
            else
                print('   ⚠ Failed to update metadata after successful processing')
            end
        else
            if setProcessedMetadata(studyId, 'partial', {
                lastJob = lastJob,
                processedInstances = processedInstances,
                failedInstances = failedInstances,
                totalInstances = #instances,
                successfulInstances = #processedInstances,
                timestamp = os.time()
            }) then
                print('   ⚠ Failed to queue some instances')
                print('AUTO-FORWARD PARTIAL: Some instances failed to send - Study: ' .. studyId)
            else
                print('   ⚠ Failed to update metadata after partial processing')
            end
        end
    end
end