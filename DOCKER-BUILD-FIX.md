# 🔧 Docker Build Fix: Composer Dependency Resolution

## Issue Resolution

**Problem:** Docker build was failing with composer dependency resolution error:
```
Root composer.json requires maennchen/zipstream-php 2.4.1 (exact version match: 2.4.1 or 2.4.1.0), found maennchen/zipstream-php[...] but it does not match the constraint.
```

**Root Cause:** The Docker build was using a static `composer.json` file with outdated exact version `2.4.1` instead of the centralized version `^3.2.0` from `example.versions.env`.

## ✅ Solution Implemented

### 1. Updated Static File (Backup Fix)
- Updated `config/moodle/composer.json` to use `^3.2.0` instead of `2.4.1`
- Ensures compatibility if ephemeral generation fails

### 2. Enhanced Docker Build Process (Primary Fix)
- Modified `Moodle.Dockerfile` to generate ephemeral `composer.json` from centralized versions
- Uses `example.versions.env` as single source of truth during Docker builds
- Generated file includes metadata for tracking centralized management

### 3. Docker Build Changes
```dockerfile
# Old approach (static file)
COPY ./config/moodle/composer.json $MOODLE_APP_DIR/

# New approach (ephemeral generation)
COPY ./example.versions.env /tmp/example.versions.env
RUN . /tmp/example.versions.env && \
    cat > $MOODLE_APP_DIR/composer.json << EOF
{
  "require": {
    "maennchen/zipstream-php": "${ZIPSTREAM_PHP_VERSION}"
  },
  ...
}
EOF
```

## 🎯 Benefits

1. **Consistency**: Docker builds now use same versions as CI/CD pipeline
2. **Centralized Management**: Single source of truth in `example.versions.env`
3. **Supply Chain Security**: Centralized version control prevents drift
4. **Semantic Versioning**: Allows patch updates for security fixes (`^3.2.0`)
5. **Audit Trail**: Generated files include metadata for tracking

## 🔍 Technical Details

### Ephemeral Generation Process
1. Copy `example.versions.env` into Docker build context
2. Source the environment variables
3. Generate `composer.json` with current versions
4. Include metadata for tracking and validation
5. Install dependencies with security validation

### Version Management
- **Centralized**: `example.versions.env` → `ZIPSTREAM_PHP_VERSION=^3.2.0`
- **CI/CD**: Auto-generated via `populate-dependency-manifests.sh`
- **Docker**: In-line generation during build process
- **Validation**: Security audit and strict validation on all builds

## 🚀 Next Steps

1. **Test Build**: Verify Docker build completes successfully
2. **Monitor Security**: Check security validation passes with new version
3. **Update Documentation**: Update any references to static dependency files
4. **Version Updates**: Use `example.versions.env` for future version changes

## 📋 Related Files Modified

- `Moodle.Dockerfile`: Enhanced with ephemeral generation
- `config/moodle/composer.json`: Updated to match centralized version
- `example.versions.env`: Already contained correct version `^3.2.0`

---
*This fix ensures Docker builds stay synchronized with centralized version management*