# Moodle for OpenShift / Doocker

## Explanation

This directory contains the docker setup to run an instance of Moodle 3.11. A number of containers are created as follows

* PHP 8.0-fpm to run the web instance of Moodle
* PHP 7.4-fpm (second instance) to run cron
* nginx as the web server
* redis for cache
* mariadb for database

Most relevent variables for versions, pod names, etc. can be found in example.env file.

The main configuration is setup in the file docker-compose.yml. Each service is a container and the compose file gives the various configuration details for that service. The volumes directives map paths inside the containers to local paths. Note that local paths are relative to the directory with the compose file. There are no absolute paths.

PHP is slightly more complicated. The default PHP image doesn't have all the extensions we need. We therefore have a
PHP.Dockerfile referenced by the compose file. This tells docker to build a new image using these instructions. As PHP
sits on a very limited Debian Linux instance most of this such be fairly obvious. Note that the confiuration files (e.g php.ini) are in the local folder and copied there on the build.

The Moodle program and data files are mapped to local directories under this folder so you can access them as normal
without worrying about the containers.

Network host names are the same as the service names (e.g. just 'redis')

## Set up

* Install Docker daemon and get running
* Stop any local instances of web server and mysql
* Make sure you have the docker-compose command installed
* Clone this repo somewhere suitable (everything else is relative to this folder)
* Creat subdirectories app/moodledata app/public.
* Clone/copy Moodle into app/public (not as a subdir, public itself)
* Copy config.php from here to that directory - modify as required
* app/moodledata should be chmod 0777
* docker-compose up --build -d
* You should then be able to access/install Moodle at http://localhost:8080

## Build / Run Moodle

docker-compose build --no-cache
docker-compose -p moodle up -d --env-file ./example.env

## Deployment

Deployment to OpenShift is handled using GitHub Actions. The workflow is defined in .github/workflows/deploy-branch.yml. Build / deploy notifications to Rocket.Chat are addressed in .github/workflows/notify-rocket-chat.yml.

## Test GitHub Actions deployment locally using Act

### Note: Act must be installed locally, or run in a container

act -s GITHUB_TOKEN="$(gh auth token)" --env-file example.env --secret-file example.secrets -W './.github/workflows/build-push-php-image.yml'

I'm mostly putting this here to kick off a redeployment to pull in new plugin code. I was going to try to fix the issue we have where our MariaDB cluster replicants are only getting 6gb PVC size applied but chickened out. I'm pretty sure the fix it [is this line of code in the openshift/mariadb.yml file](https://github.com/bcgov/moodle-nginx/blob/cc95f86b138c4e5bdf7a0cbf2655900a1cdd43c0/openshift/mariadb.yml#L17). But I'll get a consult on that before actually changing that value here.
Apparently the version bump in psaelmsync plugin didn't take and we deployed with the old version. I'm assuming that if I don't also bump the release number that it goes to the cached version. I've bumped the release and trying again here. I'm also getting intermittent database read fails right now. I know it can take some time for the deployment to settle but I don't recall having the issue last time I deployed here so I'm a tad worried.
