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
        
        -- Send to MERCURE
        local job = SendToModality(studyId, 'MERCURE')
        
        if job then
            print('   ✓ Queued for MERCURE (Job: ' .. job .. ')')
            
            -- Log to Orthanc logs for audit trail
            PrintWarning('AUTO-FORWARD: Bone length study forwarded to MERCURE - Patient: ' .. 
                      patientName .. ', Study: ' .. studyId .. ', Job: ' .. job)
        else
            print('   ✗ FAILED to queue for MERCURE')
            PrintError('AUTO-FORWARD FAILED: Bone length study send failed - Study: ' .. studyId)
        end
    end
end