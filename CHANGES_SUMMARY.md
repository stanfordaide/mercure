# Workflow Changes Summary

## What Was Changed

### 1. `mercure-manager.sh` - Management Script

**New Configuration:**
- Added `MERCURE_REPO` variable pointing to `/opt/projects/mercure`
- Auto-detects if running from repository directory
- OS detection for choosing correct install script

**New Commands:**
- `sync` - Quick deploy: sync docker files from repo → install and rebuild
- `info` - Show repository and installation information (versions, git status, etc.)

**Enhanced Commands:**
- `update` - Now automatically finds repo, shows version info, and uses correct install script for OS

**Help Update:**
- Clear workflow documentation in help text
- Examples showing the new workflow

### 2. `install_rhel_v2.sh` - RHEL Installation Script

**Enhanced Output:**
- Better formatted installation information
- Clear workflow explanation during install
- Detailed version information during updates
- Helpful completion message with next steps

**Improved Functions:**
- `setup_docker()` - Now copies entire docker directory structure and shows source/target paths
- `docker_update()` - Shows version comparison, better progress messages, syncs manager script

### 3. New Documentation

**`WORKFLOW_GUIDE.md`** - Complete reference guide including:
- Directory structure explanation
- Step-by-step development workflow
- All management commands with examples
- Quick reference section
- Troubleshooting tips

## The New Workflow

### Before (Old Way):
```
❌ No clear separation between repo and install
❌ Manual path management for updates
❌ Unclear where to make changes
❌ Rebuild required manual steps
```

### After (New Way):
```
✅ Clear repo (/opt/projects/mercure) vs install (/opt/mercure)
✅ Simple sync command for quick deployments
✅ Automatic path detection and OS detection
✅ One command to deploy changes: mercure-manager.sh sync
✅ Repository tracking with git info
```

## Typical Usage

```bash
# 1. Make changes in repo
cd /opt/projects/mercure
vim app/router.py

# 2. Deploy to runtime
sudo /opt/mercure/mercure-manager.sh sync

# 3. Monitor
sudo /opt/mercure/mercure-manager.sh logs router -f
```

## Files Modified

1. `/dataNAS/people/arogya/projects/mercure/mercure-manager.sh`
   - Added repo path configuration
   - New `sync_from_repo()` function
   - New `show_repo_info()` function
   - Enhanced `update_mercure()` with OS detection
   - Updated help and command routing

2. `/dataNAS/people/arogya/projects/mercure/install_rhel_v2.sh`
   - Enhanced output formatting
   - Better `setup_docker()` with full directory sync
   - Improved `docker_update()` with version tracking
   - Helpful completion message

3. `/dataNAS/people/arogya/projects/mercure/WORKFLOW_GUIDE.md` (NEW)
   - Complete workflow documentation

## Testing Status

✅ Bash syntax check passed for `mercure-manager.sh`
✅ Bash syntax check passed for `install_rhel_v2.sh`

## Next Steps

When you set up the actual environment:

1. Run initial install from repository:
   ```bash
   cd /opt/projects/mercure
   sudo ./install_rhel_v2.sh
   ```

2. Test the sync workflow:
   ```bash
   # Make a small change
   echo "# test" >> /opt/projects/mercure/README.md
   
   # Deploy it
   sudo /opt/mercure/mercure-manager.sh sync
   
   # Verify
   sudo /opt/mercure/mercure-manager.sh info
   ```

3. Test service management:
   ```bash
   sudo /opt/mercure/mercure-manager.sh status
   sudo /opt/mercure/mercure-manager.sh logs
   ```

## Benefits

1. **Faster Development** - `sync` command is much faster than full reinstall
2. **Clear Separation** - Source code in repo, runtime in install location
3. **Version Tracking** - Always know what version is installed vs in repo
4. **Git Integration** - Shows git status, branch, commit info
5. **OS Agnostic** - Automatically uses correct install script for your OS
6. **Less Error Prone** - No manual path management
7. **Better DX** - Clear commands, helpful output, comprehensive help

