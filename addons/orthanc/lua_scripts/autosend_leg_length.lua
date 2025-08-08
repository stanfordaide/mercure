-- Helper function to check if any instance in the study has "OUTPUT" in StudyDescription
function hasOutputInDescription(instances)
    for _, instance in pairs(instances) do
        local instanceTags = ParseJson(RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify'))
        if instanceTags then
            local studyDescription = instanceTags['StudyDescription'] or ''
            if string.find(string.upper(studyDescription), 'OUTPUT') then
                print('   Found OUTPUT in StudyDescription: ' .. studyDescription)
                return true
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
        -- Get all instances in the study
        local instances = ParseJson(RestApiGet('/studies/' .. studyId .. '/instances'))
        
        -- Check if already processed
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
            print('   ⚠ Failed to queue some instances')
            print('AUTO-FORWARD PARTIAL: Some instances failed to send - Study: ' .. studyId)
        end
    end
end