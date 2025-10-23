#!/bin/bash

# Moodle Utilities Module
# Contains Moodle-specific operations including course management, cache operations, and content cleanup

# =============================================================================
# COURSE MANAGEMENT
# =============================================================================

# Function to find courses with specific tags
find_courses_with_tag() {
  local tag_name="$1"
  local moodle_pod="$2"
  local output_format="${3:-table}"  # table, csv, or json

  echo "🔍 Finding courses with tag: $tag_name"

  if [[ -z "$tag_name" || -z "$moodle_pod" ]]; then
    echo "❌ Usage: find_courses_with_tag <tag_name> <moodle_pod> [output_format]"
    return 1
  fi

  # Validate pod exists and is running
  if ! oc get pod "$moodle_pod" -n "$DEPLOY_NAMESPACE" &>/dev/null; then
    echo "❌ Pod not found: $moodle_pod"
    return 1
  fi

  local search_script="/tmp/find_courses_with_tag.php"

  # Create PHP script for course search
  cat > "$search_script" << 'EOF'
<?php
define('CLI_SCRIPT', true);
require_once('/bitnami/moodle/config.php');

$tag_name = $argv[1] ?? '';
$output_format = $argv[2] ?? 'table';

if (empty($tag_name)) {
    echo "Error: Tag name is required\n";
    exit(1);
}

global $DB;

$sql = "SELECT c.id, c.fullname, c.shortname, c.visible, c.category,
               cat.name as categoryname, t.rawname as tag_name
        FROM {course} c
        JOIN {tag_instance} ti ON ti.itemid = c.id AND ti.itemtype = 'course'
        JOIN {tag} t ON t.id = ti.tagid
        LEFT JOIN {course_categories} cat ON cat.id = c.category
        WHERE t.rawname = ?
        ORDER BY c.fullname";

$courses = $DB->get_records_sql($sql, [$tag_name]);

if (empty($courses)) {
    echo "No courses found with tag: $tag_name\n";
    exit(0);
}

switch ($output_format) {
    case 'csv':
        echo "ID,FullName,ShortName,Visible,Category,CategoryName,Tag\n";
        foreach ($courses as $course) {
            echo "{$course->id},\"{$course->fullname}\",\"{$course->shortname}\",{$course->visible},{$course->category},\"{$course->categoryname}\",\"{$course->tag_name}\"\n";
        }
        break;

    case 'json':
        echo json_encode(array_values($courses), JSON_PRETTY_PRINT) . "\n";
        break;

    default: // table
        printf("%-8s %-50s %-20s %-8s %-30s %-15s\n", "ID", "Full Name", "Short Name", "Visible", "Category", "Tag");
        echo str_repeat("-", 130) . "\n";
        foreach ($courses as $course) {
            printf("%-8s %-50s %-20s %-8s %-30s %-15s\n",
                $course->id,
                substr($course->fullname, 0, 48),
                substr($course->shortname, 0, 18),
                $course->visible ? 'Yes' : 'No',
                substr($course->categoryname ?? 'N/A', 0, 28),
                $course->tag_name
            );
        }
        break;
}

echo "\nFound " . count($courses) . " courses with tag: $tag_name\n";
EOF

  # Copy script to pod and execute
  oc cp "$search_script" "$DEPLOY_NAMESPACE/$moodle_pod:/tmp/find_courses.php"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php /tmp/find_courses.php "$tag_name" "$output_format"

  # Cleanup
  rm -f "$search_script"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- rm -f /tmp/find_courses.php
}

# Function to update course tags
update_course_tag() {
  local course_id="$1"
  local old_tag="$2"
  local new_tag="$3"
  local moodle_pod="$4"

  echo "🏷️ Updating course tag: Course $course_id, $old_tag → $new_tag"

  if [[ -z "$course_id" || -z "$old_tag" || -z "$new_tag" || -z "$moodle_pod" ]]; then
    echo "❌ Usage: update_course_tag <course_id> <old_tag> <new_tag> <moodle_pod>"
    return 1
  fi

  local update_script="/tmp/update_course_tag.php"

  # Create PHP script for tag update
  cat > "$update_script" << 'EOF'
<?php
define('CLI_SCRIPT', true);
require_once('/bitnami/moodle/config.php');

$course_id = intval($argv[1] ?? 0);
$old_tag = $argv[2] ?? '';
$new_tag = $argv[3] ?? '';

if (empty($course_id) || empty($old_tag) || empty($new_tag)) {
    echo "Error: All parameters are required\n";
    exit(1);
}

global $DB;

// Check if course exists
$course = $DB->get_record('course', ['id' => $course_id]);
if (!$course) {
    echo "Error: Course not found with ID: $course_id\n";
    exit(1);
}

// Get existing tags
$existing_tags = core_tag_tag::get_item_tags('core', 'course', $course_id);
$tag_names = [];
foreach ($existing_tags as $tag) {
    $tag_names[] = $tag->rawname;
}

echo "Course: {$course->fullname} (ID: $course_id)\n";
echo "Current tags: " . implode(', ', $tag_names) . "\n";

// Check if old tag exists
if (!in_array($old_tag, $tag_names)) {
    echo "Warning: Old tag '$old_tag' not found on course\n";
} else {
    // Remove old tag
    $key = array_search($old_tag, $tag_names);
    if ($key !== false) {
        unset($tag_names[$key]);
    }
}

// Add new tag if not already present
if (!in_array($new_tag, $tag_names)) {
    $tag_names[] = $new_tag;
}

// Update tags
core_tag_tag::set_item_tags('core', 'course', $course_id, context_course::instance($course_id), array_values($tag_names));

echo "Updated tags: " . implode(', ', $tag_names) . "\n";
echo "Success: Tag updated for course $course_id\n";
EOF

  # Copy script to pod and execute
  oc cp "$update_script" "$DEPLOY_NAMESPACE/$moodle_pod:/tmp/update_tag.php"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php /tmp/update_tag.php "$course_id" "$old_tag" "$new_tag"

  # Cleanup
  rm -f "$update_script"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- rm -f /tmp/update_tag.php
}

# Function to migrate courses between categories or apply bulk operations
migrate_courses() {
  local operation="$1"  # move, hide, show, backup
  local criteria="$2"   # tag, category, pattern
  local target="$3"     # target category ID or tag name
  local moodle_pod="$4"

  echo "📚 Migrating courses: $operation based on $criteria → $target"

  if [[ -z "$operation" || -z "$criteria" || -z "$target" || -z "$moodle_pod" ]]; then
    echo "❌ Usage: migrate_courses <operation> <criteria> <target> <moodle_pod>"
    echo "  operation: move, hide, show, backup"
    echo "  criteria: tag:tagname, category:id, pattern:searchtext"
    echo "  target: category_id (for move), tag_name (for tag operations)"
    return 1
  fi

  local migrate_script="/tmp/migrate_courses.php"

  # Create PHP script for course migration
  cat > "$migrate_script" << 'EOF'
<?php
define('CLI_SCRIPT', true);
require_once('/bitnami/moodle/config.php');

$operation = $argv[1] ?? '';
$criteria = $argv[2] ?? '';
$target = $argv[3] ?? '';

if (empty($operation) || empty($criteria) || empty($target)) {
    echo "Error: All parameters are required\n";
    exit(1);
}

global $DB;

// Parse criteria
$criteria_parts = explode(':', $criteria, 2);
$criteria_type = $criteria_parts[0];
$criteria_value = $criteria_parts[1] ?? '';

// Find courses based on criteria
$courses = [];
switch ($criteria_type) {
    case 'tag':
        $sql = "SELECT DISTINCT c.id, c.fullname, c.shortname, c.visible, c.category
                FROM {course} c
                JOIN {tag_instance} ti ON ti.itemid = c.id AND ti.itemtype = 'course'
                JOIN {tag} t ON t.id = ti.tagid
                WHERE t.rawname = ?";
        $courses = $DB->get_records_sql($sql, [$criteria_value]);
        break;

    case 'category':
        $courses = $DB->get_records('course', ['category' => intval($criteria_value)]);
        break;

    case 'pattern':
        $sql = "SELECT * FROM {course} WHERE " . $DB->sql_like('fullname', '?', false);
        $courses = $DB->get_records_sql($sql, ['%' . $criteria_value . '%']);
        break;

    default:
        echo "Error: Invalid criteria type. Use tag:, category:, or pattern:\n";
        exit(1);
}

if (empty($courses)) {
    echo "No courses found matching criteria: $criteria\n";
    exit(0);
}

echo "Found " . count($courses) . " courses matching criteria: $criteria\n";

// Apply operation
$success_count = 0;
$error_count = 0;

foreach ($courses as $course) {
    try {
        switch ($operation) {
            case 'move':
                // Validate target category exists
                $target_category = $DB->get_record('course_categories', ['id' => intval($target)]);
                if (!$target_category) {
                    echo "Error: Target category not found: $target\n";
                    continue 2;
                }

                $course->category = intval($target);
                $DB->update_record('course', $course);
                echo "Moved: {$course->fullname} (ID: {$course->id}) to category {$target}\n";
                break;

            case 'hide':
                $course->visible = 0;
                $DB->update_record('course', $course);
                echo "Hidden: {$course->fullname} (ID: {$course->id})\n";
                break;

            case 'show':
                $course->visible = 1;
                $DB->update_record('course', $course);
                echo "Shown: {$course->fullname} (ID: {$course->id})\n";
                break;

            case 'backup':
                // Create backup using Moodle's backup API
                echo "Backup: {$course->fullname} (ID: {$course->id}) - backup functionality would be implemented here\n";
                break;

            default:
                echo "Error: Unknown operation: $operation\n";
                continue 2;
        }
        $success_count++;
    } catch (Exception $e) {
        echo "Error processing course {$course->id}: " . $e->getMessage() . "\n";
        $error_count++;
    }
}

echo "\nMigration completed: $success_count successful, $error_count errors\n";
EOF

  # Copy script to pod and execute
  oc cp "$migrate_script" "$DEPLOY_NAMESPACE/$moodle_pod:/tmp/migrate.php"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php /tmp/migrate.php "$operation" "$criteria" "$target"

  # Cleanup
  rm -f "$migrate_script"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- rm -f /tmp/migrate.php
}

# =============================================================================
# CACHE MANAGEMENT
# =============================================================================

# Function to clear all Moodle caches
clear_moodle_cache() {
  local moodle_pod="$1"
  local cache_type="${2:-all}"  # all, theme, language, javascript, etc.

  echo "🧹 Clearing Moodle cache: $cache_type"

  if [[ -z "$moodle_pod" ]]; then
    echo "❌ Usage: clear_moodle_cache <moodle_pod> [cache_type]"
    return 1
  fi

  # Validate pod exists and is running
  if ! oc get pod "$moodle_pod" -n "$DEPLOY_NAMESPACE" &>/dev/null; then
    echo "❌ Pod not found: $moodle_pod"
    return 1
  fi

  case "$cache_type" in
    "all")
      echo "  Clearing all caches..."
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php /bitnami/moodle/admin/cli/purge_caches.php
      ;;
    "theme")
      echo "  Clearing theme cache..."
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php -r "
        define('CLI_SCRIPT', true);
        require_once('/bitnami/moodle/config.php');
        theme_reset_all_caches();
        echo 'Theme cache cleared\n';
      "
      ;;
    "language")
      echo "  Clearing language cache..."
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php -r "
        define('CLI_SCRIPT', true);
        require_once('/bitnami/moodle/config.php');
        get_string_manager()->reset_caches();
        echo 'Language cache cleared\n';
      "
      ;;
    "javascript")
      echo "  Clearing JavaScript cache..."
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php -r "
        define('CLI_SCRIPT', true);
        require_once('/bitnami/moodle/config.php');
        js_reset_all_caches();
        echo 'JavaScript cache cleared\n';
      "
      ;;
    *)
      echo "❌ Unknown cache type: $cache_type"
      echo "Available types: all, theme, language, javascript"
      return 1
      ;;
  esac

  echo "✅ Cache clearing completed: $cache_type"
}

# Function to rebuild course cache
rebuild_course_cache() {
  local moodle_pod="$1"
  local course_id="${2:-all}"

  echo "🔄 Rebuilding course cache"

  if [[ -z "$moodle_pod" ]]; then
    echo "❌ Usage: rebuild_course_cache <moodle_pod> [course_id]"
    return 1
  fi

  local rebuild_script="/tmp/rebuild_course_cache.php"

  # Create PHP script for cache rebuild
  cat > "$rebuild_script" << 'EOF'
<?php
define('CLI_SCRIPT', true);
require_once('/bitnami/moodle/config.php');

$course_id = $argv[1] ?? 'all';

global $DB;

if ($course_id === 'all') {
    echo "Rebuilding cache for all courses...\n";
    $courses = $DB->get_records('course', null, '', 'id, fullname');

    foreach ($courses as $course) {
        if ($course->id == SITEID) continue; // Skip site course

        rebuild_course_cache($course->id, true);
        echo "Rebuilt cache for: {$course->fullname} (ID: {$course->id})\n";
    }
    echo "Completed rebuilding cache for " . (count($courses) - 1) . " courses\n";
} else {
    $course_id = intval($course_id);
    $course = $DB->get_record('course', ['id' => $course_id]);

    if (!$course) {
        echo "Error: Course not found with ID: $course_id\n";
        exit(1);
    }

    rebuild_course_cache($course_id, true);
    echo "Rebuilt cache for: {$course->fullname} (ID: $course_id)\n";
}
EOF

  # Copy script to pod and execute
  oc cp "$rebuild_script" "$DEPLOY_NAMESPACE/$moodle_pod:/tmp/rebuild_cache.php"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php /tmp/rebuild_cache.php "$course_id"

  # Cleanup
  rm -f "$rebuild_script"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- rm -f /tmp/rebuild_cache.php

  echo "✅ Course cache rebuild completed"
}

# Function to check cache status and performance
check_cache_status() {
  local moodle_pod="$1"

  echo "📊 Checking Moodle cache status"

  if [[ -z "$moodle_pod" ]]; then
    echo "❌ Usage: check_cache_status <moodle_pod>"
    return 1
  fi

  local status_script="/tmp/cache_status.php"

  # Create PHP script for cache status
  cat > "$status_script" << 'EOF'
<?php
define('CLI_SCRIPT', true);
require_once('/bitnami/moodle/config.php');

global $CFG;

echo "=== Moodle Cache Configuration ===\n";
echo "Cache enabled: " . ($CFG->cachejs ? 'Yes' : 'No') . "\n";
echo "Theme designer mode: " . ($CFG->themedesignermode ?? false ? 'Yes' : 'No') . "\n";
echo "Cache directory: " . $CFG->cachedir . "\n";

// Check cache stores
$factory = cache_factory::instance();
$stores = $factory->get_stores();

echo "\n=== Cache Stores ===\n";
foreach ($stores as $name => $store) {
    echo "Store: $name\n";
    echo "  Type: " . get_class($store) . "\n";

    if (method_exists($store, 'get_stats')) {
        $stats = $store->get_stats();
        if ($stats) {
            echo "  Stats: " . json_encode($stats) . "\n";
        }
    }
}

// Check specific cache definitions
$definitions = $factory->get_definitions();
$important_caches = ['course', 'theme', 'string', 'javascript'];

echo "\n=== Important Cache Definitions ===\n";
foreach ($important_caches as $cache_name) {
    if (isset($definitions[$cache_name])) {
        $def = $definitions[$cache_name];
        echo "Cache: $cache_name\n";
        echo "  Component: " . $def['component'] . "\n";
        echo "  Area: " . $def['area'] . "\n";
        echo "  Mode: " . $def['mode'] . "\n";
    }
}

// Check cache directory size if accessible
if (is_dir($CFG->cachedir)) {
    $size = 0;
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($CFG->cachedir));
    foreach ($iterator as $file) {
        if ($file->isFile()) {
            $size += $file->getSize();
        }
    }
    echo "\nCache directory size: " . round($size / 1024 / 1024, 2) . " MB\n";
}
EOF

  # Copy script to pod and execute
  oc cp "$status_script" "$DEPLOY_NAMESPACE/$moodle_pod:/tmp/cache_status.php"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php /tmp/cache_status.php

  # Cleanup
  rm -f "$status_script"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- rm -f /tmp/cache_status.php
}

# =============================================================================
# CONTENT CLEANUP
# =============================================================================

# Function to fix mojibake (encoding issues) in uploaded files
fix_mojibake_files() {
  local moodle_pod="$1"
  local file_pattern="${2:-*.mbz}"
  local target_dir="${3:-/bitnami/moodledata/temp}"

  echo "🔧 Fixing mojibake in files: $file_pattern"

  if [[ -z "$moodle_pod" ]]; then
    echo "❌ Usage: fix_mojibake_files <moodle_pod> [file_pattern] [target_dir]"
    return 1
  fi

  local fix_script="/tmp/fix_mojibake.sh"

  # Create shell script for file fixing
  cat > "$fix_script" << 'EOF'
#!/bin/bash
file_pattern="$1"
target_dir="$2"

echo "Searching for files matching: $file_pattern in $target_dir"

find "$target_dir" -name "$file_pattern" -type f | while read -r file; do
    echo "Processing: $file"

    # Check if file contains mojibake characters
    if grep -q $'\xc2\xa0\|ï»¿\|\xef\xbb\xbf' "$file" 2>/dev/null; then
        echo "  Found mojibake in: $file"

        # Create backup
        cp "$file" "$file.backup"

        # Fix mojibake characters
        sed -i 's/\xc2\xa0/ /g; s/ï»¿//g; s/\xef\xbb\xbf//g' "$file"

        echo "  Fixed: $file (backup created)"
    else
        echo "  Clean: $file"
    fi
done

echo "Mojibake fixing completed"
EOF

  # Copy script to pod and execute
  oc cp "$fix_script" "$DEPLOY_NAMESPACE/$moodle_pod:/tmp/fix_mojibake.sh"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- chmod +x /tmp/fix_mojibake.sh
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- /tmp/fix_mojibake.sh "$file_pattern" "$target_dir"

  # Cleanup
  rm -f "$fix_script"
  oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- rm -f /tmp/fix_mojibake.sh

  echo "✅ Mojibake fixing completed"
}

# Function for comprehensive Moodle content cleanup
moodle_content_cleanup() {
  local moodle_pod="$1"
  local cleanup_type="${2:-standard}"  # standard, deep, or analysis

  echo "🧹 Moodle content cleanup: $cleanup_type"

  if [[ -z "$moodle_pod" ]]; then
    echo "❌ Usage: moodle_content_cleanup <moodle_pod> [cleanup_type]"
    return 1
  fi

  case "$cleanup_type" in
    "standard")
      echo "  Running standard cleanup..."
      clear_moodle_cache "$moodle_pod" "all"
      rebuild_course_cache "$moodle_pod" "all"
      ;;
    "deep")
      echo "  Running deep cleanup..."
      clear_moodle_cache "$moodle_pod" "all"
      fix_mojibake_files "$moodle_pod" "*.mbz" "/bitnami/moodledata/temp"
      fix_mojibake_files "$moodle_pod" "*.xml" "/bitnami/moodledata/temp"
      rebuild_course_cache "$moodle_pod" "all"
      ;;
    "analysis")
      echo "  Running analysis only..."
      check_cache_status "$moodle_pod"
      ;;
    *)
      echo "❌ Unknown cleanup type: $cleanup_type"
      echo "Available types: standard, deep, analysis"
      return 1
      ;;
  esac

  echo "✅ Moodle content cleanup completed: $cleanup_type"
}

# =============================================================================
# MAINTENANCE MODE
# =============================================================================

# Function to enable/disable Moodle maintenance mode
manage_moodle_maintenance() {
  local action="$1"      # enable, disable, status
  local moodle_pod="$2"
  local message="${3:-System maintenance in progress}"

  echo "🔧 Managing Moodle maintenance mode: $action"

  if [[ -z "$action" || -z "$moodle_pod" ]]; then
    echo "❌ Usage: manage_moodle_maintenance <enable|disable|status> <moodle_pod> [message]"
    return 1
  fi

  case "$action" in
    "enable")
      echo "  Enabling maintenance mode with message: $message"
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php -r "
        define('CLI_SCRIPT', true);
        require_once('/bitnami/moodle/config.php');
        set_config('maintenance_enabled', 1);
        set_config('maintenance_message', '$message');
        echo 'Maintenance mode enabled\n';
      "
      ;;
    "disable")
      echo "  Disabling maintenance mode..."
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php -r "
        define('CLI_SCRIPT', true);
        require_once('/bitnami/moodle/config.php');
        set_config('maintenance_enabled', 0);
        unset_config('maintenance_message');
        echo 'Maintenance mode disabled\n';
      "
      ;;
    "status")
      echo "  Checking maintenance mode status..."
      oc exec -n "$DEPLOY_NAMESPACE" "$moodle_pod" -- php -r "
        define('CLI_SCRIPT', true);
        require_once('/bitnami/moodle/config.php');
        \$enabled = get_config('core', 'maintenance_enabled');
        \$message = get_config('core', 'maintenance_message');
        echo 'Maintenance mode: ' . (\$enabled ? 'ENABLED' : 'DISABLED') . '\n';
        if (\$enabled && \$message) {
            echo 'Message: ' . \$message . '\n';
        }
      "
      ;;
    *)
      echo "❌ Unknown action: $action"
      echo "Available actions: enable, disable, status"
      return 1
      ;;
  esac

  echo "✅ Maintenance mode operation completed: $action"
}

# Legacy function names for backward compatibility
list_courses() {
  find_courses_with_tag "$@"
}

update_tag() {
  update_course_tag "$@"
}

migrate_course() {
  migrate_courses "$@"
}