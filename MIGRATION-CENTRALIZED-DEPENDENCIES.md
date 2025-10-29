# Migration to Centralized Dependency Management

## What Changed

We've consolidated from multiple dependency files to a single, generated approach for better security and maintainability.

### Before (Multiple Files)
- `config/moodle/composer.json` (manual maintenance)
- `config/moodle/composer.generated.json` (for scanning)
- Various other dependency manifests

### After (Single Source of Truth) ✅
- `example.versions.env` (single source of truth for ALL dependency versions)
- `config/moodle/composer.json` (auto-generated for both production and Dependabot)
- All other manifests auto-generated from centralized versions

## Benefits

1. **No More Confusion**: Only one composer.json file to understand
2. **Centralized Security**: All versions controlled from example.versions.env
3. **Automated Generation**: Dependency manifests generated automatically
4. **Supply Chain Protection**: Fixed versions prevent malicious auto-updates
5. **Developer Experience**: Clear workflow for dependency management

## How to Use

### 1. Update Dependencies
```bash
# Edit versions in the central file
vim example.versions.env

# Generate all dependency manifests
./openshift/scripts/populate-dependency-manifests.sh

# Validate security
./openshift/scripts/validate-php-security.sh
```

### 2. Check for Issues
```bash
# Validate all dependencies and check for drift
./openshift/scripts/validate-php-security.sh

# View what files will be generated
./openshift/scripts/populate-dependency-manifests.sh --dry-run
```

### 3. Local Development
```bash
# Generate .env.generated for docker-compose
./openshift/scripts/populate-dependency-manifests.sh

# Use generated environment
docker-compose --env-file .env.generated up
```

## Important Notes

⚠️ **Never edit generated files manually** - they will be overwritten
✅ **Always update example.versions.env first** 
✅ **Run populate-dependency-manifests.sh after version changes**
✅ **All generated files are in .gitignore** (they're created during builds)

## Migration Steps Completed

1. ✅ Updated populate-dependency-manifests.sh to generate single composer.json
2. ✅ Modified validation scripts to work with consolidated approach
3. ✅ Added generated files to .gitignore
4. ✅ Updated documentation
5. ✅ Enhanced security validation with drift detection

## Next Steps

1. Test the generation script: `./openshift/scripts/populate-dependency-manifests.sh`
2. Validate security: `./openshift/scripts/validate-php-security.sh`  
3. Commit the changes to migrate to the new system
4. Remove the old `config/moodle/composer.json` from git tracking (it's now generated)

The system now provides enterprise-grade security with simplified maintenance!