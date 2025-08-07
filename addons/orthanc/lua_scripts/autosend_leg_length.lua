function OnStableStudy(studyId, tags, metadata)
    local studyDescription = tags['StudyDescription'] or ''
    
    -- Convert to uppercase for case-insensitive comparison
    local normalizedDescription = string.upper(studyDescription)
    local targetDescription = string.upper('LPCH XR EXTREMITY BILATERAL BONE LENGTH')
    
    -- You could also use pattern matching for partial matches:
    -- if string.find(normalizedDescription, 'LPCH.*XR.*EXTREMITY.*BILATERAL.*BONE.*LENGTH') then
    
    if normalizedDescription == targetDescription then
        local patientName = tags['PatientName'] or 'Unknown'
        local studyInstanceUID = tags['StudyInstanceUID'] or 'Unknown'
        
        print('🦴 BONE LENGTH STUDY AUTO-FORWARD')
        print('   Study ID: ' .. studyId)
        print('   Patient: ' .. patientName)
        print('   Study UID: ' .. studyInstanceUID)
        print('   Original Description: ' .. studyDescription)
        
        -- Get all instances in the study
        local instances = ParseJson(RestApiGet('/studies/' .. studyId .. '/instances'))
        print('   Found ' .. #instances .. ' instances in study')
        
        -- Send each instance to MERCURE
        local success = true
        local lastJob = nil
        for i, instance in pairs(instances) do
            local job = SendToModality(instance['ID'], 'MERCURE')
            if job then
                print('   ✓ Instance ' .. i .. ' queued for MERCURE (Job: ' .. job .. ')')
                lastJob = job
            else
                print('   ✗ Failed to queue instance ' .. i)
                success = false
            end
        end
        
        if success then
            print('   ✓ All instances queued for MERCURE')
            print('AUTO-FORWARD: Bone length study forwarded to MERCURE - Patient: ' .. 
                      patientName .. ', Study: ' .. studyId .. ', Last Job: ' .. lastJob)
        else
            print('   ✗ Failed to queue some instances')
            print('AUTO-FORWARD FAILED: Some instances failed to send - Study: ' .. studyId)
        end
    end
end