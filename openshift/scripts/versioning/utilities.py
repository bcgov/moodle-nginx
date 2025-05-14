import json
import re
import datetime
from pathlib import Path
from packaging import version
import docker
import requests
from github import Github

def load_versions_file(filename):
    if Path(filename).exists():
        with open(filename, 'r') as f:
            return json.load(f)
    return {"applications": {}, "containers": {}}

def save_versions_file(filename, data):
    with open(filename, 'w') as f:
        json.dump(data, f, indent=2)

def parse_env_file(filename):
    versions = {}
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                if '_URL=' in line:
                    key = line.split('=')[0].replace('_URL', '')
                    value = line.split('"')[1]
                    versions[key] = {'url': value}
                elif '_BRANCH_VERSION=' in line:
                    key = line.split('=')[0].replace('_BRANCH_VERSION', '')
                    value = line.split('=')[1].strip()
                    if key in versions:
                        versions[key]['branch'] = value
                elif '_IMAGE=' in line:
                    key = line.split('=')[0]
                    value = line.split('=')[1].strip()
                    versions[key] = {'image': value}
    return versions

def extract_version_from_branch(branch_name):
    moodle_match = re.match(r'MOODLE_(\d)(\d{2})_STABLE', branch_name)
    if moodle_match:
        major, minor = moodle_match.groups()
        return f"{major}.{minor[0]}.{minor[1]}"

    semver_match = re.search(r'v?(\d+\.\d+\.\d+)', branch_name)
    if semver_match:
        return semver_match.group(1)

    return branch_name

def get_latest_release_version(repo, default_branch):
    try:
        latest_release = repo.get_latest_release()
        return latest_release.tag_name.lstrip('v')
    except:
        try:
            tags = repo.get_tags()
            if tags.totalCount > 0:
                return tags[0].name.lstrip('v')
        except:
            return default_branch

def compare_versions(current, latest):
    try:
        return version.parse(current) < version.parse(latest)
    except version.InvalidVersion:
        return True

def get_docker_image_version(image_name, local=False):
    if local:
        client = docker.from_env()
        try:
            image = client.images.get(image_name)
            return image.tags[0].split(':')[-1], image.id
        except docker.errors.ImageNotFound:
            return None, None
    else:
        # For remote images, you'd typically use a registry API
        # This is a placeholder and would need to be implemented based on your registry
        pass

def check_versions(env_file, versions_file, local=False):
    current_time = datetime.datetime.utcnow().isoformat() + 'Z'
    current_versions = parse_env_file(env_file)
    versions_data = load_versions_file(versions_file)

    updates = {}
    invalid = {}

    g = Github(os.environ.get('GITHUB_TOKEN'))

    for key, info in current_versions.items():
        if 'url' in info and 'branch' in info:
            # Handle GitHub repositories
            repo_name = '/'.join(info['url'].split('/')[-2:])
            try:
                repo = g.get_repo(repo_name)
                branch = repo.get_branch(info['branch'])
                latest_commit = branch.commit.sha

                current_version = extract_version_from_branch(info['branch'])
                latest_version = get_latest_release_version(repo, info['branch'])

                if key in versions_data['applications']:
                    deployed_version = versions_data['applications'][key]['version']
                    if compare_versions(deployed_version, latest_version):
                        updates[key] = {
                            'version': latest_version,
                            'branch': info['branch'],
                            'commit': latest_commit,
                            'last_updated': current_time
                        }
                else:
                    updates[key] = {
                        'version': latest_version,
                        'branch': info['branch'],
                        'commit': latest_commit,
                        'last_updated': current_time
                    }

            except Exception as e:
                invalid[key] = str(e)

        elif 'image' in info:
            # Handle Docker images
            image_name = info['image']
            latest_version, latest_digest = get_docker_image_version(image_name, local)

            if latest_version:
                if key in versions_data['containers']:
                    deployed_version = versions_data['containers'][key]['version']
                    if compare_versions(deployed_version, latest_version):
                        updates[key] = {
                            'version': latest_version,
                            'digest': latest_digest,
                            'last_updated': current_time
                        }
                else:
                    updates[key] = {
                        'version': latest_version,
                        'digest': latest_digest,
                        'last_updated': current_time
                    }
            else:
                invalid[key] = f"Could not fetch version for {image_name}"

    return updates, invalid

def update_versions(env_file, versions_file, local=False):
    updates, _ = check_versions(env_file, versions_file, local)
    versions_data = load_versions_file(versions_file)

    for key, info in updates.items():
        if 'branch' in info:
            versions_data['applications'][key] = info
        else:
            versions_data['containers'][key] = info

    save_versions_file(versions_file, versions_data)
    return updates

def populate_versions(env_file, versions_file, local=False):
    current_versions = parse_env_file(env_file)
    versions_data = load_versions_file(versions_file)
    current_time = datetime.datetime.utcnow().isoformat() + 'Z'

    for key, info in current_versions.items():
        if 'url' in info and 'branch' in info:
            # Handle GitHub repositories
            repo_name = '/'.join(info['url'].split('/')[-2:])
            try:
                g = Github(os.environ.get('GITHUB_TOKEN'))
                repo = g.get_repo(repo_name)
                branch = repo.get_branch(info['branch'])
                latest_commit = branch.commit.sha

                versions_data['applications'][key] = {
                    'version': extract_version_from_branch(info['branch']),
                    'branch': info['branch'],
                    'commit': latest_commit,
                    'last_updated': current_time,
                    'deployed_date': current_time
                }
            except Exception as e:
                print(f"Error populating {key}: {str(e)}")

        elif 'image' in info:
            # Handle Docker images
            image_name = info['image']
            version, digest = get_docker_image_version(image_name, local)

            if version:
                versions_data['containers'][key] = {
                    'version': version,
                    'digest': digest,
                    'last_updated': current_time,
                    'deployed_date': current_time
                }
            else:
                print(f"Error populating {key}: Could not fetch version")

    save_versions_file(versions_file, versions_data)
    return versions_data

def query_versions(versions_file, app_name=None):
    versions_data = load_versions_file(versions_file)

    if app_name:
        if app_name in versions_data['applications']:
            info = versions_data['applications'][app_name]
            print(f"{app_name}:")
            print(f"  Version: {info['version']}")
            print(f"  Branch: {info['branch']}")
            print(f"  Last Updated: {info['last_updated']}")
            print(f"  Deployed: {info['deployed_date']}")
        elif app_name in versions_data['containers']:
            info = versions_data['containers'][app_name]
            print(f"{app_name}:")
            print(f"  Version: {info['version']}")
            print(f"  Digest: {info['digest']}")
            print(f"  Last Updated: {info['last_updated']}")
            print(f"  Deployed: {info['deployed_date']}")
        else:
            print(f"Application or container {app_name} not found")
    else:
        print("Deployed Applications:")
        for app, info in versions_data['applications'].items():
            print(f"{app}: {info['version']} ({info['branch']})")
        print("\nDeployed Containers:")
        for container, info in versions_data['containers'].items():
            print(f"{container}: {info['version']}")
